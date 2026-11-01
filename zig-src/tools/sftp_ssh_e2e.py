#!/usr/bin/env python
"""SFTP 端到端回归（SSH 层）：认证闸门 + 真实客户端的 ls / get / put。

这个脚本走**真的 SSH-2** 端口（`--sftp-ssh` 或 `sftp.enable = true`），
覆盖传输层、连接层与收发流控 —— 那些「单测覆盖不到、手工又容易漏」的东西：

* 未认证直接开 channel 必须被拒（`channel.zig` 的 P0 闸门）；
* 错口令必须被拒；
* 大文件 `get` 必须逐字节一致 —— 这一条会走满 `sendData` 的分片与
  `waitForWindow` 的等待路径，是窗口流控唯一能自动回归的地方；
* 客户端主动重协商（rekey）后会话必须照常可用 —— OpenSSH 大约每 1 GB 或
  1 小时会自己发起一次，服务端不接就是「大文件传到一半掉线」。连做两次是为了
  抓「上次的 KEXINIT 存放在短命 allocator 里」这类悬垂引用；
* **服务端主动** rekey（`sftp.rekey_mb` 阈值）：客户端不动，服务端自己换密钥。
  这条路径要处理「两边同时发起」和「KEX 期间客户端继续发 CHANNEL_DATA」，
  是最容易写出「上传随机卡住」的地方；
* 断点续传：以 `r+b`（不带 TRUNC）打开已存在的文件，按 offset 覆盖写。

依赖：**paramiko**（本脚本必需；`sftp_interop.py` 只在不给 `--hostkey` 时用它
取指纹，属于可选）。安装到隔离环境：

    <python> -m venv <env> && <env>/Scripts/pip install paramiko

用法（先起服务，例如 `openlist server --sftp-ssh 15411`）：

    python tools/sftp_ssh_e2e.py --port 15411 --password <admin 口令>

退出码 0 = 全通过，1 = 有失败项。
"""

import argparse
import hashlib
import os
import sys
import tempfile

import paramiko
from paramiko.kex_curve25519 import KexCurve25519

# 服务端按 RFC 8731 只宣告 `curve25519-sha256`；paramiko 只认旧别名
# `curve25519-sha256@libssh.org`（算法完全相同，只是名字不同）。这里补一个
# 别名即可，不要为了迁就客户端去改服务端的算法宣告。
paramiko.Transport._kex_info["curve25519-sha256"] = KexCurve25519
paramiko.Transport._preferred_kex = ("curve25519-sha256",) + paramiko.Transport._preferred_kex

ok = True


def check(label, cond, extra=""):
    global ok
    print(("PASS " if cond else "FAIL ") + label + ((" | " + extra) if extra else ""))
    if not cond:
        ok = False


def md5(path):
    return hashlib.md5(open(path, "rb").read()).hexdigest()


def count_rekeys(transport):
    """数「对端发来 KEXINIT」的次数 —— 客户端没主动要求、却收到 KEXINIT，
    只可能是服务端发起的重协商。

    注意这里**不能**给实例属性 `transport._negotiate_keys` 赋值：paramiko 在
    `__init__` 里就把 `_handler_table` 建成 `{MSG_KEXINIT: self._negotiate_keys}`
    （存的是 bound method），分发表里留的是老引用，事后改实例属性完全无效 ——
    计数会一直是 0，看起来像「服务端没 rekey」。官方注释写明这张表就是为了
    per-instance 改写而搬到 init 里的，所以这里替换表里那一项。
    """
    counter = {"n": 0}
    orig = transport._handler_table[paramiko.common.MSG_KEXINIT]

    def wrapper(m):
        counter["n"] += 1
        return orig(m)

    transport._handler_table[paramiko.common.MSG_KEXINIT] = wrapper
    return counter


def connect(host, port, user, pw):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, port=port, username=user, password=pw,
              look_for_keys=False, allow_agent=False, timeout=15)
    return c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=15411)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", required=True, help="管理员口令")
    ap.add_argument("--dir", default="/local", help="要列出的目录（挂载点）")
    ap.add_argument("--expect-server-rekey", action="store_true",
                    help="服务端配了很小的 sftp.rekey_mb，断言它会主动换密钥")
    args = ap.parse_args()

    work = tempfile.mkdtemp(prefix="olz-sftp-e2e-")
    big = os.path.join(work, "big.bin")
    with open(big, "wb") as f:
        f.write(bytes(range(256)) * 1200)  # 300 KiB：跨多个 max_packet 分片

    # ---- 1) 正常认证 + 列目录 + get/put 往返 ----
    c = connect(args.host, args.port, args.user, args.password)
    sftp = c.open_sftp()
    check("认证通过（正确口令）", True)
    check("REALPATH .", sftp.normalize(".") == "/", sftp.normalize("."))
    roots = sorted(e.filename for e in sftp.listdir_attr("/"))
    check("列虚拟根非空", len(roots) > 0, str(roots))

    sftp.put(big, args.dir + "/e2e_big.bin")
    check("put 后可见",
          "e2e_big.bin" in [e.filename for e in sftp.listdir_attr(args.dir)])

    got = os.path.join(work, "got.bin")
    sftp.get(args.dir + "/e2e_big.bin", got)
    check("get 300KiB 逐字节一致（跨分片 + 窗口）",
          md5(got) == md5(big), f"{os.path.getsize(got)} B")

    small = os.path.join(work, "small.txt")
    with open(small, "w") as f:
        f.write("sftp-e2e\n")
    sftp.put(small, args.dir + "/e2e_small.txt")
    back = os.path.join(work, "back.txt")
    sftp.get(args.dir + "/e2e_small.txt", back)
    check("put/get 往返一致", md5(back) == md5(small))

    # ---- 1b) 客户端主动重协商（rekey）：只换密钥，会话继续 ----
    # 连续两次：第二次会复用上一次写进 Transport 的 KEXINIT 原文（算 H 要用）。
    # 如果那份内存挂在短命 arena 上，第二次重协商就会读到已释放的字节 ——
    # 症状是密钥算错、之后所有包 BadMac，而不是当场报错。
    try:
        for i in (1, 2):
            c.get_transport().renegotiate_keys()
            check(f"第 {i} 次 rekey 成功", c.get_transport().is_active())
    except Exception as e:  # noqa: BLE001
        check("rekey 成功", False, f"{type(e).__name__}: {e}")

    back2 = os.path.join(work, "back2.txt")
    sftp.get(args.dir + "/e2e_small.txt", back2)
    check("rekey 后 get 仍然一致", md5(back2) == md5(small))

    got2 = os.path.join(work, "got2.bin")
    sftp.get(args.dir + "/e2e_big.bin", got2)
    check("rekey 后 get 300KiB 仍然一致", md5(got2) == md5(big))

    # ---- 1c) 断点续传：不带 TRUNC 打开已存在的文件，按 offset 覆盖 ----
    # 服务端必须先把现有内容拉进 temp 再接受 WRITE，否则 offset 之前的那段
    # 会变成空洞：文件「上传成功」，内容却缺一块，而且客户端拿不到任何错误。
    try:
        p = args.dir + "/e2e_resume.bin"
        with sftp.open(p, "wb") as fh:
            fh.write(b"0123456789")
        with sftp.open(p, "r+b") as fh:
            fh.seek(10)
            fh.write(b"abc")
        with sftp.open(p, "rb") as fh:
            content = fh.read()
        check("断点续传保留原内容", content == b"0123456789abc", repr(content))
        sftp.remove(p)
    except Exception as e:  # noqa: BLE001
        check("断点续传保留原内容", False, f"{type(e).__name__}: {e}")

    # ---- 1d) 服务端主动 rekey ----
    # 只有服务端配了小阈值（`sftp.rekey_mb`）才会发生。这里传一大段数据，
    # 期间不调用 `renegotiate_keys()` —— 计数 >0 就是服务端发起的。
    if args.expect_server_rekey:
        try:
            tr = c.get_transport()
            counter = count_rekeys(tr)
            payload = os.urandom(3 * 1024 * 1024)
            p = args.dir + "/e2e_rekey.bin"
            with sftp.open(p, "wb") as fh:
                for i in range(0, len(payload), 32768):
                    fh.write(payload[i:i + 32768])
            back = os.path.join(work, "rekey_back.bin")
            sftp.get(p, back)
            same = open(back, "rb").read() == payload
            check("服务端主动发起 rekey", counter["n"] > 0, f"rekeys={counter['n']}")
            check("服务端 rekey 期间数据未损坏", same, f"{os.path.getsize(back)} B")
            sftp.remove(p)
        except Exception as e:  # noqa: BLE001
            check("服务端主动发起 rekey", False, f"{type(e).__name__}: {e}")

    for name in ("e2e_big.bin", "e2e_small.txt"):
        try:
            sftp.remove(args.dir + "/" + name)
        except OSError as e:
            print("     清理失败（可忽略）:", name, e)

    sftp.close()
    c.close()

    # ---- 2) 错口令必须被拒 ----
    try:
        connect(args.host, args.port, args.user, args.password + "-wrong")
        check("错口令被拒", False, "竟然连上了")
    except paramiko.AuthenticationException:
        check("错口令被拒", True)
    except Exception as e:  # noqa: BLE001
        check("错口令被拒", True, f"{type(e).__name__}: {e}")

    # ---- 3) 未认证不得开 channel（P0 回归）----
    t = paramiko.Transport((args.host, args.port))
    t.start_client()
    try:
        ch = t.open_session(timeout=10)
        ch.close()
        check("未认证开 channel 被拒", False, "竟然开成了")
    except Exception as e:  # noqa: BLE001
        check("未认证开 channel 被拒", True, f"{type(e).__name__}")
    finally:
        t.close()

    print("\n=== " + ("ALL PASS" if ok else "HAS FAILURE") + " ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
