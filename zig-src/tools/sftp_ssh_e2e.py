#!/usr/bin/env python
"""SFTP 端到端回归（SSH 层）：认证闸门 + 真实客户端的 ls / get / put。

`tools/sftp_probe.py` 走的是**裸** SFTP 端口（`--sftp-plain`，没有 SSH），
覆盖不到传输层与连接层。这个脚本走**真的 SSH-2** 端口（`--sftp-ssh` 或
`sftp.enable = true`），用来回归那些「单测覆盖不到、手工又容易漏」的东西：

* 未认证直接开 channel 必须被拒（`channel.zig` 的 P0 闸门）；
* 错口令必须被拒；
* 大文件 `get` 必须逐字节一致 —— 这一条会走满 `sendData` 的分片与
  `waitForWindow` 的等待路径，是窗口流控唯一能自动回归的地方。

依赖：**paramiko**（唯一一个需要第三方包的回归工具；其余探针都刻意零依赖）。
安装到隔离环境：

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
