#!/usr/bin/env python
"""SFTP 互通回归：用**第三方客户端**（不是我们自己写的探针）跑 list / put / get / rm。

单测和 `sftp_ssh_e2e.py`（paramiko）覆盖的是「协议实现自洽」；这个脚本覆盖的是
另一个问题：**别人家的客户端能不能用**。两者的 bug 集合几乎不重叠 —— 都是实测
撞出来的：

* PuTTY `pscp` 只发 `CHANNEL_EOF` 就等 CLOSE，我们不回 `CLOSE` 它就永远不退出；
* WinSCP 见服务器不在它的「已知服务器」表里，会主动把 SFTP 降到 v3；
* rclone 拿不到 `posix-rename@openssh.com` 会退回 rename-then-delete 链路。

这三条自家客户端一条都测不出来。所以这个脚本只做一件事：把机器上能找到的
第三方客户端挨个跑一遍，逐字节比对，找不到的**明确报 SKIP 并说明原因**。

零第三方依赖（只要客户端本身在机器上）。唯一例外：给 rclone 生成 known_hosts
需要 paramiko（`sftp_ssh_e2e.py` 已经依赖它）；没有 paramiko 时 rclone 项退化成
SKIP，不会假装通过。

    python tools/sftp_interop.py --port 15411 --password test123 --dir /local
    python tools/sftp_interop.py --port 15411 --password test123 --only psftp,winscp

退出码 0 = 所有**跑到**的客户端全通过（SKIP 不算失败）；1 = 有失败项；
2 = 一个客户端都没跑到（全 SKIP）—— 单独一个码，免得 CI 把「什么都没验证」
当成「全通过」。
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

ok = True

# 默认 512 KiB：够大到跨多个 max_packet 分片、走满一次窗口补给，又不至于让
# 慢客户端（WinSCP 的 GUI 引擎）跑太久。`--kib` 可以调小，用来把「传输量」
# 这个变量从一次失败里摘出去（例如怀疑和服务端 rekey 阈值相关时）。
PAYLOAD_KIB = 512

SKIP = "SKIP"


def report(status, label, extra=""):
    global ok
    print(status + " " + label + ((" | " + extra) if extra else ""))
    if status == "FAIL":
        ok = False


def md5(path):
    with open(path, "rb") as f:
        return hashlib.md5(f.read()).hexdigest()


# ---------------------------------------------------------------- 客户端定位

def find(direct, name, extra_dirs=()):
    """按 显式路径 → PATH → 常见安装目录 的顺序找一个可执行文件。"""
    if direct:
        return direct if os.path.exists(direct) else None
    p = shutil.which(name)
    if p:
        return p
    for d in extra_dirs:
        cand = os.path.join(d, name)
        if os.path.exists(cand):
            return cand
    return None


def is_windows():
    return os.name == "nt"


PF = os.environ.get("ProgramFiles", r"C:\Program Files")
PF86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")


def win_path(p):
    """psftp / WinSCP 的脚本文本里要 Windows 路径，别混进 MSYS 的 `/c/...`。"""
    return os.path.abspath(p).replace("/", "\\") if is_windows() else p


def run(cmd, timeout=120):
    p = subprocess.run(cmd, capture_output=True, text=True,
                       timeout=timeout, errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


# ---------------------------------------------------------------- 各客户端

def test_psftp(exe, args, work, up, down):
    """PuTTY psftp（`-b` 批处理）。

    `-batch` 下 host key 没缓存就直接崩，所以先空跑一次把指纹从报错里捞出来
    再带上 `-hostkey` 重跑 —— 这比要求用户手抄指纹省事，也保证验的确实是
    这台服务器的 key。
    """
    hostkey = args.hostkey
    script = os.path.join(work, "psftp.txt")
    remote = args.dir.rstrip("/") + "/interop_psftp.bin"
    with open(script, "w", encoding="utf-8") as f:
        f.write(f"pwd\nls\ncd {args.dir}\nls\n"
                f"put \"{win_path(up)}\" {remote}\n"
                f"get {remote} \"{win_path(down)}\"\n"
                f"rm {remote}\nquit\n")

    base = [exe, "-batch", "-pw", args.password, "-l", args.user,
            "-P", str(args.port)]
    if not hostkey:
        rc, out = run(base + [args.host]
                      + ["-b", script], timeout=60)
        m = re.search(r"(SHA256:[A-Za-z0-9+/=]{20,})", out)
        if not m:
            return False, f"取不到 host key 指纹：{out.strip()[:200]}"
        hostkey = m.group(1)
    rc, out = run(base + ["-hostkey", hostkey, args.host, "-b", script])
    if rc != 0:
        return False, f"exit={rc} {(out.strip().splitlines() or [''])[-1][:200]}"
    return md5(up) == md5(down), f"{os.path.getsize(down)} B, hostkey={hostkey[:20]}…"


def test_winscp(exe, args, work, up, down):
    """WinSCP 的 `WinSCP.com /script=` 批处理模式。

    `/ini=nul` 让它不要读写用户的配置（否则会有上次的会话、代理、断点续传
    记录混进来），`-hostkey="*"` 是同一个意思：这里是回归测试，不做 pinning。
    """
    script = os.path.join(work, "winscp.txt")
    remote = args.dir.rstrip("/") + "/interop_winscp.bin"
    url = f"sftp://{args.user}:{args.password}@{args.host}:{args.port}/"
    with open(script, "w", encoding="utf-8") as f:
        f.write("option batch abort\noption confirm off\noption transfer binary\n")
        f.write(f'open {url} -hostkey="*" -timeout=30\n')
        f.write(f"pwd\nls /\ncd {args.dir}\nls\n")
        f.write(f'put -nopreservetime "{win_path(up)}" {remote}\n')
        f.write(f'get -nopreservetime {remote} "{win_path(down)}"\n')
        f.write(f"rm {remote}\nexit\n")
    rc, out = run([exe, "/ini=nul", f"/script={win_path(script)}"])
    if rc != 0:
        return False, f"exit={rc} {(out.strip().splitlines() or [''])[-1][:200]}"
    return md5(up) == md5(down), f"{os.path.getsize(down)} B"


def host_key_line(args):
    """生成一行 known_hosts：`[host]:port ssh-ed25519 AAAA...`。

    用 paramiko 直接问服务器要公钥 —— 比去读 `data/ssh_host_ed25519_key`
    再自己算 ed25519 公钥省事得多，而且验的是「服务器实际出示的那把」。
    """
    try:
        import paramiko
        from paramiko.kex_curve25519 import KexCurve25519
    except ImportError:
        return None
    # 服务端按 RFC 8731 只宣告 `curve25519-sha256`，paramiko 只认旧别名
    # `curve25519-sha256@libssh.org`（算法相同）。`sftp_ssh_e2e.py` 顶部是
    # 同一个补丁；这里重复两行是为了不 import 那个脚本（它会连带跑一堆初始化）。
    if "curve25519-sha256" not in paramiko.Transport._kex_info:
        paramiko.Transport._kex_info["curve25519-sha256"] = KexCurve25519
        paramiko.Transport._preferred_kex = ("curve25519-sha256",) + tuple(
            paramiko.Transport._preferred_kex)
    t = paramiko.Transport((args.host, args.port))
    t.start_client(timeout=15)
    key = t.get_remote_server_key()
    host = args.host if args.port == 22 else f"[{args.host}]:{args.port}"
    line = f"{host} {key.get_name()} {key.get_base64()}\n"
    t.close()
    return line


def test_rclone(exe, args, work, up, down):
    """rclone 的 `:sftp:` 后端（连接串式临时远端，不写配置文件）。

    口令必须先过 `rclone obscure` —— `--sftp-pass` 只收混淆值，直接给明文
    会在「解密」阶段报 base64 错，看起来像认证失败。
    同时把 `--sftp-shell-type=none` 显式钉住：rclone 默认会探测远端 shell，
    我们只提供 `subsystem sftp`，探测失败会白等一轮超时。
    """
    kh = os.path.join(work, "known_hosts")
    line = host_key_line(args)
    if line is None:
        return SKIP, "缺 paramiko，无法生成 known_hosts（pip install paramiko）"
    with open(kh, "w", encoding="utf-8") as f:
        f.write(line)

    rc, out = run([exe, "obscure", args.password], timeout=30)
    if rc != 0:
        return False, f"obscure 失败：{out.strip()[:120]}"
    obsc = out.strip()

    remote = f":sftp:{args.dir.rstrip('/')}"
    common = [exe, "--sftp-host", args.host, "--sftp-port", str(args.port),
              "--sftp-user", args.user, "--sftp-pass", obsc,
              "--sftp-known-hosts-file", win_path(kh),
              "--sftp-shell-type", "none", "--sftp-disable-hashcheck"]
    rc, out = run(common + ["lsd", remote])
    if rc != 0:
        return False, f"lsd exit={rc} {out.strip()[:200]}"
    rc, out = run(common + ["copyto", up, f"{remote}/interop_rclone.bin"])
    if rc != 0:
        return False, f"copyto exit={rc} {out.strip()[:200]}"
    rc, out = run(common + ["copyto", f"{remote}/interop_rclone.bin", down])
    if rc != 0:
        return False, f"回传 exit={rc} {out.strip()[:200]}"
    rc, out = run(common + ["deletefile", f"{remote}/interop_rclone.bin"])
    if rc != 0:
        # 以前这里丢弃了返回码 ⇒ `rm` 失败也报 PASS，与脚本自称的
        # 「ls / put / get / rm 往返」不符（psftp / WinSCP 两条都检查了）。
        return False, f"deletefile exit={rc} {out.strip()[:200]}"
    return md5(up) == md5(down), f"{os.path.getsize(down)} B"


def test_openssh(exe, args, work, up, down):
    """OpenSSH `sftp -b`。**没法自动化**：没有 sshpass 时它只从 tty 读口令，
    `SSH_ASKPASS` 在 Windows 上也不生效。这里只做存在性提示，不假装通过。"""
    return SKIP, "OpenSSH 需交互式口令（除非有 sshpass）；请手工跑一次"


CLIENTS = [
    # name,   默认查找名,          显式参数,        额外目录,                 测试函数
    ("psftp",  "psftp.exe" if is_windows() else "psftp", "psftp",
     [os.path.join(PF, "PuTTY"), os.path.join(PF86, "PuTTY")], test_psftp),
    ("winscp", "WinSCP.com", "winscp",
     [os.path.join(PF, "WinSCP"), os.path.join(PF86, "WinSCP")], test_winscp),
    ("rclone", "rclone.exe" if is_windows() else "rclone", "rclone",
     [os.path.join(PF, "rclone")], test_rclone),
    ("openssh", "sftp.exe" if is_windows() else "sftp", "openssh", [], test_openssh),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=15411)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", required=True)
    ap.add_argument("--dir", default="/local", help="远端目录（挂载点）")
    ap.add_argument("--only", default="", help="只跑这些，逗号分隔：psftp,winscp,rclone,openssh")
    ap.add_argument("--psftp"), ap.add_argument("--winscp")
    ap.add_argument("--rclone"), ap.add_argument("--openssh")
    ap.add_argument("--hostkey", default="",
                    help="psftp 的 host key 指纹；不给就自动从报错里取")
    ap.add_argument("--kib", type=int, default=PAYLOAD_KIB,
                    help="每个客户端往返的数据量（KiB）")
    args = ap.parse_args()

    only = {s.strip() for s in args.only.split(",") if s.strip()}

    work = tempfile.mkdtemp(prefix="olz-interop-")
    up = os.path.join(work, "up.bin")
    # 整 KiB 的数据：`bytes(range(256))` 重复 `kib*4` 次正好是 kib KiB
    # （256 字节 × 4 = 1 KiB）。
    payload = (bytes(range(256)) * (args.kib * 4))[: args.kib * 1024]
    assert len(payload) == args.kib * 1024, f"payload {len(payload)} != {args.kib} KiB"
    with open(up, "wb") as f:
        f.write(payload)

    ran = 0
    for name, default, opt, dirs, fn in CLIENTS:
        if only and name not in only:
            continue
        exe = find(getattr(args, opt), default, dirs)
        if not exe:
            report(SKIP, f"{name}: 没装", "用 --" + opt + " 指定路径")
            continue
        down = os.path.join(work, f"down_{name}.bin")
        try:
            res = fn(exe, args, work, up, down)
        except Exception as e:  # noqa: BLE001
            report("FAIL", f"{name}: 异常", f"{type(e).__name__}: {e}")
            continue
        if isinstance(res, tuple) and len(res) == 2 and isinstance(res[0], str):
            # SKIP 之类的短路径返回
            report(res[0], f"{name}", res[1])
            continue
        passed, detail = res
        ran += 1
        report("PASS" if passed else "FAIL", f"{name}: ls / put / get / rm 往返一致", detail)

    if ran == 0:
        print("\n没有跑到任何客户端 —— 至少装一个（PuTTY / WinSCP / rclone）再跑。")
        print("\n=== NOTHING RAN ===")
        # 退出码 2 而不是 0：全部 SKIP 时「什么都没验证」和「全通过」看起来一样，
        # CI 里就是一次静默的假通过。
        return 2
    print("\n=== " + ("ALL PASS" if ok else "HAS FAILURE") + " ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
