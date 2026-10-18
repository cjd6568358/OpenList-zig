"""拿新鲜夸克 URL 并在设备上跑 https_probe。URL 5 分钟过期，一步完成。"""
import json, os, subprocess, sys, urllib.request, urllib.error

os.chdir(r"D:\workspace\OpenList-zig\zig-src")
PY = r"C:\Users\Administrator\.workbuddy-ai\binaries\python\envs\default\Scripts\python.exe"
BASE = "http://192.168.1.1:15399"
TMP = r"C:\Users\Administrator\AppData\Local\Temp"

def req(path, method="GET", body=None, token=None, timeout=60):
    h = {}
    if token: h["Authorization"] = "Bearer " + token
    data = None
    if body is not None:
        data = json.dumps(body).encode(); h.setdefault("Content-Type", "application/json")
    r = urllib.request.Request(BASE + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")

def remote(*argv, timeout=180):
    r = subprocess.run([PY, "tools/remote.py", *argv], capture_output=True, text=True, timeout=timeout)
    return r.stdout + r.stderr

st, txt = req("/api/auth/login", "POST", {"username": "admin", "password": "OlzDiag#2026"})
tok = json.loads(txt)["data"]["token"]
import urllib.parse
st, txt = req("/api/fs/get", "POST", {"path": "/quark/sn.img"}, token=tok)
url = json.loads(txt)["data"]["raw_url"]
u = urllib.parse.urlsplit(url)
path = u.path + ("?" + u.query if u.query else "")
# cookie 从**设备实时配置**读 —— 本机临时文件可能过期（2026-10-16 被它坑过）。
import sys as _sys, os as _os
_sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
from device_cookie import quark_cookie
cookie = quark_cookie()
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
      "quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 "
      "Safari/537.36 Channel/pckk_other_ch")

mode = sys.argv[1] if len(sys.argv) > 1 else "close"
conn = "keep-alive" if mode == "keep-alive" else "close"
extra = ""
if mode == "keep-alive":
    extra = "--keep-alive"
elif mode == "ipv4":
    extra = "--family ipv4"
elif mode == "ipv6":
    extra = "--family ipv6"
script = ("/tmp/probe/https_probe dl-pc-zb.pds.quark.cn 443 '" + path + "' '" + cookie +
          "' 'https://pan.quark.cn' '" + UA + "' 25 " + extra + "\n")
open(os.path.join(TMP, "probe_run.sh"), "wb").write(script.encode())
print("mode:", conn, "path len:", len(path))
print(remote("192.168.1.1", "10022", "--put", os.path.join(TMP, "probe_run.sh"), "tmp/probe/run.sh", "755", timeout=60))
# 后台跑，避免 SSH 命令超时掩盖真实耗时
print(remote("192.168.1.1", "10022",
             "(sh /tmp/probe/run.sh > /tmp/probe/out.txt 2>&1 </dev/null &) ; echo started", timeout=30))
import time
time.sleep(35)
print("=== PROBE OUTPUT ===")
print(remote("192.168.1.1", "10022", "cat /tmp/probe/out.txt")[:4000])
