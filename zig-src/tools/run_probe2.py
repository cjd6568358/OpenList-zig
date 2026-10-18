#!/usr/bin/env python3
"""跑 https_probe2 变体组：拿新鲜 URL → 部署 probe2 → 逐变体执行并收集输出。"""
import json
from creds import root_pwd as _root_pwd
import os
import subprocess
import sys
import time
import urllib.request

import paramiko

os.chdir(r"D:\workspace\OpenList-zig\zig-src")
PY = r"C:\Users\Administrator\.workbuddy-ai\binaries\python\envs\default\Scripts\python.exe"
BASE = "http://192.168.1.1:15399"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 "
      "Safari/537.36 Channel/pckk_other_ch")


def req(path, method="GET", body=None, token=None, timeout=60):
    h = {}
    if token:
        h["Authorization"] = "Bearer " + token
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    r = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def get_fresh():
    st, txt = req("/api/auth/login", "POST", {"username": "admin", "password": "OlzDiag#2026"})
    tok = json.loads(txt)["data"]["token"]
    st, txt = req("/api/fs/get", "POST", {"path": "/quark/sn.img"}, token=tok)
    url = json.loads(txt)["data"]["raw_url"]
    cfg = json.load(open(r"C:\Users\Administrator\AppData\Local\Temp\olz-cfg-merged.json"))
    add = json.loads([s for s in cfg["storages"] if s["driver"] == "Quark"][0]["addition"])
    return url, add["cookie"]


def fetch_binary():
    """从构建机用 SFTP 直接拉 https_probe2 —— 不能用 remote.py cat：
    它把输出 decode(errors='replace')，二进制必毁（实测 490200 → 806819）。"""
    if os.path.exists("dist/https_probe2"):
        os.remove("dist/https_probe2")
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("10.0.0.4", port=22, username="root", password=_root_pwd(),
              timeout=20, look_for_keys=False, allow_agent=False)
    sftp = c.open_sftp()
    sftp.get("/tmp/olz-build/https_probe2", "dist/https_probe2")
    sftp.close()
    c.close()
    n = os.path.getsize("dist/https_probe2")
    if n < 100000:
        sys.exit("probe2 too small: %d bytes" % n)
    print("probe2 fetched via sftp: %d bytes" % n)


def device(script):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("192.168.1.1", port=10022, username="root", password=_root_pwd(),
              timeout=20, look_for_keys=False, allow_agent=False)
    sftp = c.open_sftp()
    sftp.put("dist/https_probe2", "/tmp/probe/https_probe2")
    sftp.chmod("/tmp/probe/https_probe2", 0o755)
    with sftp.open("/tmp/probe/run2.sh", "w") as f:
        f.write(script)
    sftp.close()
    _, o, e = c.exec_command("(sh /tmp/probe/run2.sh > /tmp/probe/out2.txt 2>&1 </dev/null &) ; echo started",
                             timeout=30)
    o.read()
    time.sleep(75)
    _, o, e = c.exec_command("cat /tmp/probe/out2.txt", timeout=30)
    out = o.read().decode(errors="replace")
    c.close()
    return out


def main():
    url, cookie = get_fresh()
    u = url.split(".cn", 1)
    host_port = u[0] + ".cn"
    host = host_port.replace("https://", "").replace("http://", "")
    path = u[1]
    print("url ok; host=%s path_len=%d" % (host, len(path)))

    fetch_binary()

    import shlex
    q = shlex.quote
    base = "./https_probe2 %s 443 %s %s 'https://pan.quark.cn' %s 15" % (
        q(host), q(path), q(cookie), q(UA))

    variants = [
        ("A probe-head single-write", ""),
        ("B std-head single-write", "--head=std"),
        ("C std-head chunk=1024", "--head=std --chunk=1024"),
        ("D probe-head delay=400ms", "--delay-ms=400"),
        ("E std-head + read-poll", "--head=std --read-poll"),
    ]

    lines = ["cd /tmp/probe", "echo READY"]
    for name, flags in variants:
        lines.append("echo; echo '===== %s ====='" % name)
        lines.append("%s %s || true" % (base, flags))
    script = "\n".join(lines) + "\n"

    out = device(script)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
