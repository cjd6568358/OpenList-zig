#!/usr/bin/env python3
"""设备端 curl 对照实验：在光猫本机用 curl 打夸克 CDN 直链。

如果设备 curl 也失败 → 网络路径/边缘节点问题；
如果设备 curl 拿到 403（cookie 过期）→ Zig 栈问题，独有失败。

用 curl 配置文件（-K）承载 URL/头，规避 shell 引号与行长限制。
"""
import json
from creds import root_pwd as _root_pwd
import subprocess
import sys
import time
import urllib.request

import paramiko

BASE = "http://192.168.1.1:15399"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 "
      "Safari/537.36 Channel/pckk_other_ch")


def get_fresh():
    def call(path, body=None, token=None):
        data = json.dumps(body).encode() if body is not None else None
        h = {"Content-Type": "application/json"} if data else {}
        if token:
            h["Authorization"] = "Bearer " + token
        r = urllib.request.Request(BASE + path, data=data, headers=h,
                                   method="POST" if body else "GET")
        with urllib.request.urlopen(r, timeout=30) as resp:
            return json.loads(resp.read())

    j = call("/api/auth/login", {"username": "admin", "password": "OlzDiag#2026"})
    tok = j["data"]["token"]
    d = call("/api/fs/get", {"path": "/quark/sn.img"}, tok)["data"]
    # cookie 从**设备实时配置**读 —— 本机临时文件可能过期（2026-10-16 被它坑过：
    # 旧 __puus 导致 CDN 403，误判成「cookie 过期是主因」）。
    import sys as _sys
    import os as _os
    _sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
    from device_cookie import quark_cookie
    return d["raw_url"], quark_cookie()


def main():
    url, cookie = get_fresh()
    print("fresh url ok:", len(url), "bytes")

    # curl -K 配置文件：全部用引号包裹，免 shell 转义
    lines = [
        'url = "%s"' % url,
        'header = "Referer: https://pan.quark.cn"',
        'header = "User-Agent: %s"' % UA,
        'header = "Cookie: %s"' % cookie,
        'header = "Accept: */*"',
        'output = "/tmp/olz/curl_out.bin"',
        'write-out = "HTTP %%{http_code} size=%%{size_download} time=%%{time_total}s"',
        'max-time = "25"',
        'silent',
        'show-error',
    ]
    body = "\n".join(lines) + "\n"

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("192.168.1.1", port=10022, username="root", password=_root_pwd(),
              timeout=20, look_for_keys=False, allow_agent=False)
    sftp = c.open_sftp()
    with sftp.open("/tmp/olz/curl.cfg", "w") as f:
        f.write(body)
    sftp.close()

    def sh(cmd, timeout=60):
        _, o, e = c.exec_command(cmd, timeout=timeout)
        return o.read().decode(errors="replace") + e.read().decode(errors="replace")

    print("\n--- device curl (resolved by device DNS) ---")
    t0 = time.time()
    out = sh("cd /tmp/olz && curl -K curl.cfg ; echo ; echo exit=$?", timeout=60)
    print(out.strip())
    print("wall: %.1fs" % (time.time() - t0))

    print("\n--- response body head ---")
    print(sh("head -c 400 /tmp/olz/curl_out.bin 2>/dev/null | tr -d '\\000'", timeout=30))

    print("\n--- nslookup from device ---")
    print(sh("nslookup dl-pc-zb.pds.quark.cn 2>/dev/null | tail -8 || cat /etc/resolv.conf", timeout=30))

    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
