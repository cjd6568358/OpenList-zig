#!/usr/bin/env python3
"""对照实验：同一份请求（新鲜 URL + 完整 Cookie/Referer/UA），
分别打 Windows 默认解析的 IP（106.8.x.x）与设备解析的移动网段 IP
（116.132.x.x），看响应差异 —— 判定 502 是 TLS 栈问题还是边缘节点问题。
"""
import json
import subprocess
import sys
import urllib.request

BASE = "http://192.168.1.1:15399"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 "
      "Safari/537.36 Channel/pckk_other_ch")
# 设备（移动网段）解析到的 IP，来自 run_probe 实测
DEVICE_IPS = ["116.132.218.81", "116.132.255.195", "116.132.217.180"]


def get_fresh():
    def call(path, body=None, token=None):
        data = json.dumps(body).encode() if body is not None else None
        h = {"Content-Type": "application/json"} if data else {}
        if token:
            h["Authorization"] = "Bearer " + token
        r = urllib.request.Request(BASE + path, data=data, headers=h, method="POST" if body else "GET")
        with urllib.request.urlopen(r, timeout=30) as resp:
            return json.loads(resp.read())

    j = call("/api/auth/login", {"username": "admin", "password": "OlzDiag#2026"})
    tok = j["data"]["token"]
    d = call("/api/fs/get", {"path": "/quark/sn.img"}, tok)["data"]
    cfg = json.load(open(r"C:\Users\Administrator\AppData\Local\Temp\olz-cfg-merged.json"))
    add = json.loads([s for s in cfg["storages"] if s["driver"] == "Quark"][0]["addition"])
    return d["raw_url"], add["cookie"]


def curl(url, cookie, resolve=None, timeout=25):
    cmd = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code} %{size_download}B",
           "--max-time", str(timeout),
           "-H", "Referer: https://pan.quark.cn",
           "-H", "User-Agent: " + UA,
           "-H", "Cookie: " + cookie]
    if resolve:
        cmd += ["--resolve", resolve]
    cmd.append(url)
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 10)
        return out.stdout.strip() or ("ERR:" + out.stderr.strip()[:120])
    except subprocess.TimeoutExpired:
        return "TIMEOUT"


def curl_body(url, cookie, resolve=None, timeout=25):
    cmd = ["curl", "-s", "--max-time", str(timeout),
           "-H", "Referer: https://pan.quark.cn",
           "-H", "User-Agent: " + UA,
           "-H", "Cookie: " + cookie]
    if resolve:
        cmd += ["--resolve", resolve]
    cmd.append(url)
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 10)
        return (out.stdout or "")[:300] or ("ERR:" + out.stderr.strip()[:120])
    except subprocess.TimeoutExpired:
        return "TIMEOUT"


def main():
    url, cookie = get_fresh()
    print("fresh url ok, len:", len(url))
    host = "dl-pc-zb.pds.quark.cn"

    print("\n=== A. Windows 默认解析（106.8.x.x）===")
    print("  status:", curl(url, cookie))
    body = curl_body(url, cookie)
    print("  body:", body.replace("\n", " ")[:200])

    print("\n=== B. 强制设备同款 IP（116.132.x.x 移动网段）===")
    for ip in DEVICE_IPS:
        print("  %s -> %s" % (ip, curl(url, cookie, resolve="%s:443:%s" % (host, ip))))

    print("\n=== C. 设备 IP 上看响应体（第一个） ===")
    print(" ", curl_body(url, cookie, resolve="%s:443:%s" % (host, DEVICE_IPS[0])).replace("\n", " ")[:250])
    return 0


if __name__ == "__main__":
    sys.exit(main())
