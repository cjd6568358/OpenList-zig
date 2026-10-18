#!/usr/bin/env python3
"""抓 openlist 实际下载失败的线路包：tcpdump(ppp0,443) + 触发 /d/quark 下载。"""
import json
import os
import sys
import time
import urllib.request

import paramiko

os.chdir(r"D:\workspace\OpenList-zig\zig-src")
BASE = "http://192.168.1.1:15399"


def call(path, method="GET", body=None, token=None, timeout=90):
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


def main():
    st, txt = call("/api/auth/login", "POST", {"username": "admin", "password": "OlzDiag#2026"})
    tok = json.loads(txt)["data"]["token"]
    st, txt = call("/api/fs/get", "POST", {"path": "/quark/sn.img"}, token=tok)
    sign = json.loads(txt)["data"]["sign"]

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("192.168.1.1", port=10022, username="root", password="REDACTED",
              timeout=20, look_for_keys=False, allow_agent=False)

    def sh(cmd, timeout=40):
        _, o, e = c.exec_command(cmd, timeout=timeout)
        return o.read().decode(errors="replace") + e.read().decode(errors="replace")

    # 先清 run.log 尾部位置，便于抓新日志
    print(sh("wc -l /tmp/olz/run.log"))
    sh("rm -f /tmp/probe/ol.pcap")
    # 起 tcpdump（nohup 后台），过滤 443
    sh("cd /tmp/probe && (nohup tcpdump -i ppp0 -s 0 -w ol.pcap 'port 443' >td2.out 2>td2.err </dev/null &) ; echo started")
    time.sleep(2.0)

    t0 = time.time()
    st, body = call("/d/quark/sn.img?sign=" + sign, timeout=90)
    print("download: HTTP %d, %d bytes, %.2fs" % (st, len(body), time.time() - t0))

    time.sleep(1.0)
    print(sh("pkill -f 'tcpdump -i ppp0'; sleep 1; ls -la /tmp/probe/ol.pcap; cat /tmp/probe/td2.err"))

    # 拉 pcap
    sftp = c.open_sftp()
    sftp.get("/tmp/probe/ol.pcap", "dist/ol.pcap")
    sftp.close()
    print("pcap:", os.path.getsize("dist/ol.pcap"), "bytes")
    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
