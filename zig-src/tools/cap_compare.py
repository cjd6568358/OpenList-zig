#!/usr/bin/env python3
"""抓包对比：探针（静默）vs curl（有响应）在同一 CDN 上的 TLS 记录序列。

设备上跑 tcpdump 抓 port 443 的完整包，两个会话在一份 pcap 里，
拉回本机解析：记录尺寸序列、服务器是否有任何回包（ACK 之外）、时序。
"""
import json
import os
import struct
import sys
import time
import urllib.request

import paramiko

os.chdir(r"D:\workspace\OpenList-zig\zig-src")
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
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return json.loads(resp.read())


def main():
    j = req("/api/auth/login", "POST", {"username": "admin", "password": "OlzDiag#2026"})
    tok = j["data"]["token"]
    d = req("/api/fs/get", "POST", {"path": "/quark/sn.img"}, token=tok)["data"]
    url, sign = d["raw_url"], d.get("sign", "")
    cfg = json.load(open(r"C:\Users\Administrator\AppData\Local\Temp\olz-cfg-merged.json"))
    cookie = json.loads([s for s in cfg["storages"] if s["driver"] == "Quark"][0]["addition"])["cookie"]
    print("url ok, sign:", bool(sign))

    # URL 拆 host/path（用 urlsplit，别拿 ".cn" 切 —— 会切在 host 中间的 qu[ark].cn 之前）
    from urllib.parse import urlsplit
    u = urlsplit(url)
    host = u.hostname
    path = u.path + ("?" + u.query if u.query else "")
    print("host:", host, "path_len:", len(path))

    import shlex
    q = shlex.quote

    curl_cfg = "\n".join([
        'url = "%s"' % url,
        'header = "Referer: https://pan.quark.cn"',
        'header = "User-Agent: %s"' % UA,
        'header = "Cookie: %s"' % cookie,
        'header = "Accept: */*"',
        'output = "/tmp/probe/curl_cap_out.bin"',
        'max-time = "20"',
        'silent',
        'show-error',
    ]) + "\n"

    script = "\n".join([
        "cd /tmp/probe",
        "cat > curl.cfg <<'CURLEOF'",
        curl_cfg.rstrip("\n"),
        "CURLEOF",
        "rm -f cap.pcap probe_cap.txt curl_cap.txt",
        "IPS=$(nslookup %s 2>/dev/null | grep -E '^Address: [0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$' | awk '{print $2}' | head -4)" % host,
        "FILTER=$(echo $IPS | sed 's/ / or /g')",
        "echo \"filter: port 443 and (host $FILTER)\"",
        "tcpdump -i ppp0 -s 0 -w cap.pcap \"port 443 and (host $FILTER)\" >td.out 2>td.err &",
        "TD=$!",
        "sleep 2",
        "echo '== probe run =='",
        "./https_probe2 %s 443 %s %s 'https://pan.quark.cn' %s 8 > probe_cap.txt 2>&1 || true" % (
            q(host), q(path), q(cookie), q(UA)),
        "sleep 1",
        "echo '== curl run =='",
        "curl -K curl.cfg > curl_cap.txt 2>&1 || true",
        "sleep 2",
        "kill $TD 2>/dev/null",
        "sleep 1",
        "echo '== files =='",
        "ls -la cap.pcap probe_cap.txt curl_cap.txt",
        "echo '== tcpdump err =='",
        "cat td.err",
        "echo '== probe tail =='",
        "tail -6 probe_cap.txt",
        "echo '== curl out =='",
        "head -c 300 curl_cap_out.bin 2>/dev/null; echo",
    ]) + "\n"

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("192.168.1.1", port=10022, username="root", password="REDACTED",
              timeout=20, look_for_keys=False, allow_agent=False)
    sftp = c.open_sftp()
    with sftp.open("/tmp/probe/cap_run.sh", "w") as f:
        f.write(script)
    print("script uploaded")

    _, o, e = c.exec_command("(sh /tmp/probe/cap_run.sh > /tmp/probe/cap_out.txt 2>&1 </dev/null &) ; echo started", timeout=30)
    o.read()
    time.sleep(38)
    _, o, e = c.exec_command("cat /tmp/probe/cap_out.txt", timeout=30)
    print(o.read().decode(errors="replace"))
    # 拉回 pcap
    try:
        sftp.get("/tmp/probe/cap.pcap", "dist/cap.pcap")
        print("pcap pulled:", os.path.getsize("dist/cap.pcap"), "bytes")
    except Exception as ex:
        print("pcap pull failed:", ex)
    sftp.close()
    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
