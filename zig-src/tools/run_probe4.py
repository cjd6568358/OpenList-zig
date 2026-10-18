#!/usr/bin/env python3
"""probe4 对照实验：timeout=0 vs timeout=60 各 3 次，抓包 + keys4.log。"""
import json
import os
import sys
import time
import urllib.request
from urllib.parse import urlsplit

import paramiko

os.chdir(r"D:\workspace\OpenList-zig\zig-src")
BASE = "http://192.168.1.1:15399"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 "
      "Safari/537.36 Channel/pckk_other_ch")


def call(path, method="GET", body=None, token=None, timeout=60):
    h = {}
    if token:
        h["Authorization"] = "Bearer " + token
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    r = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return json.loads(resp.read())


def main():
    j = call("/api/auth/login", "POST", {"username": "admin", "password": "OlzDiag#2026"})
    tok = j["data"]["token"]
    url = call("/api/fs/get", "POST", {"path": "/quark/sn.img"}, token=tok)["data"]["raw_url"]
    cfg = json.load(open(r"C:\Users\Administrator\AppData\Local\Temp\olz-cfg-merged.json"))
    cookie = json.loads([s for s in cfg["storages"] if s["driver"] == "Quark"][0]["addition"])["cookie"]
    host = urlsplit(url).hostname
    print("url ok host=%s len=%d" % (host, len(url)))

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("10.0.0.4", port=22, username="root", password="REDACTED",
              timeout=20, look_for_keys=False, allow_agent=False)
    sftp = c.open_sftp()
    sftp.get("/tmp/olz-build/https_probe4", "dist/https_probe4")
    sftp.close()
    c.close()

    import shlex
    q = shlex.quote

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("192.168.1.1", port=10022, username="root", password="REDACTED",
              timeout=20, look_for_keys=False, allow_agent=False)
    sftp = c.open_sftp()
    sftp.put("dist/https_probe4", "/tmp/probe/https_probe4")
    sftp.chmod("/tmp/probe/https_probe4", 0o755)

    script = "\n".join([
        "cd /tmp/probe",
        "rm -f p4.pcap keys4.log p4.out",
        "IPS=$(nslookup %s 2>/dev/null | grep -E '^Address: [0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' | awk '{print $2}' | head -4)" % host,
        "FILTER=$(echo $IPS | sed 's/ / or /g')",
        "echo \"filter: port 443 and (host $FILTER)\"",
        "tcpdump -i ppp0 -s 0 -w p4.pcap \"port 443 and (host $FILTER)\" >td4.out 2>td4.err &",
        "TD=$!",
        "sleep 2",
        "echo '=== A: timeout=0 x3 ==='",
        "./https_probe4 %s %s 'https://pan.quark.cn' %s --timeout=0 --runs=3 >> p4.out 2>&1 || true" % (
            q(url), q(cookie), q(UA)),
        "sleep 1",
        "echo '=== B: timeout=60 x3 ==='",
        "./https_probe4 %s %s 'https://pan.quark.cn' %s --timeout=60 --runs=3 >> p4.out 2>&1 || true" % (
            q(url), q(cookie), q(UA)),
        "sleep 1",
        "kill $TD 2>/dev/null",
        "sleep 1",
        "echo '--- p4.out ---'",
        "cat p4.out",
        "echo '--- files ---'",
        "ls -la p4.pcap keys4.log",
    ]) + "\n"

    with sftp.open("/tmp/probe/p4_run.sh", "w") as f:
        f.write(script)
    sftp.close()

    def sh(cmd, timeout=120):
        _, o, e = c.exec_command(cmd, timeout=timeout)
        return o.read().decode(errors="replace") + e.read().decode(errors="replace")

    sh("(sh /tmp/probe/p4_run.sh > /tmp/probe/p4_all.txt 2>&1 </dev/null &) ; echo started")
    time.sleep(45)
    print(sh("cat /tmp/probe/p4_all.txt"))

    sftp = c.open_sftp()
    for remote, local in (("/tmp/probe/p4.pcap", "dist/p4.pcap"),
                          ("/tmp/probe/keys4.log", "dist/keys4.log")):
        try:
            sftp.get(remote, local)
            print("pulled", local, os.path.getsize(local))
        except Exception as ex:
            print("pull failed", remote, ex)
    sftp.close()
    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
