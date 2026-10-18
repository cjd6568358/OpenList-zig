"""修复后验证：Zig WebDAV 115 下载（修复前恒 403）。

对照三组：
  1. WebDAV GET 整份 → 期望 200 + 正文 38 字节
  2. WebDAV Range → 期望 206 + Content-Range
  3. /d/ 下载 → 期望 200（修复前就好，防回归）
"""
import base64
import json
import time
import urllib.error
import urllib.request

BASE = "http://192.168.1.1:15399"
FILE = "/115/olz-goab-ab.txt"
UA = "olz-fix-verify/1.0"
OP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):
        return None


OP_NR = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

# 等实例 ready
for i in range(60):
    try:
        with OP.open(BASE + "/ping", timeout=5) as r:
            if r.status == 200:
                print("ready after %ds" % (i + 1))
                break
    except Exception:
        pass
    time.sleep(2)
else:
    raise SystemExit("实例未就绪")


def post(path, body, tok=None):
    h = {"Content-Type": "application/json", "User-Agent": UA}
    if tok:
        h["Authorization"] = "Bearer " + tok
    r = urllib.request.Request(BASE + path, method="POST",
                               data=json.dumps(body).encode(), headers=h)
    with OP.open(r, timeout=90) as resp:
        return json.loads(resp.read().decode())


def get(url, headers, opener=OP):
    # PC↔设备走 easytier 隧道，偶发 ConnectionResetError（已知链路抖动）—— 重试
    last = None
    for _ in range(4):
        r = urllib.request.Request(url, headers=headers)
        try:
            with opener.open(r, timeout=90) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers), e.read()
        except Exception as e:  # ConnectionResetError 等
            last = e
            time.sleep(1.5)
    raise last


tok = (post("/api/auth/login",
            {"username": "admin", "password": "e2e-test-123456"})
       .get("data") or {}).get("token")
auth = {"Authorization": "Basic " + base64.b64encode(
    b"admin:e2e-test-123456").decode(), "User-Agent": UA}

# 1) WebDAV GET 整份
st, hd, body = get(BASE + "/dav" + FILE, auth)
print("1) WebDAV GET      -> HTTP %d, %d 字节, body=%r" % (st, len(body), body[:40]))
ok1 = st == 200 and body == b"goab ab probe 115 direct link compare\n"
print("   期望 200 + 38 字节正文: %s" % ("PASS" if ok1 else "FAIL"))

# 2) WebDAV Range
st2, hd2, b2 = get(BASE + "/dav" + FILE, dict(auth, **{"Range": "bytes=0-9"}))
print("2) WebDAV Range    -> HTTP %d, %d 字节, Content-Range=%s" % (
    st2, len(b2), hd2.get("Content-Range")))
ok2 = st2 in (200, 206) and len(b2) > 0
print("   期望 200/206 且有正文: %s" % ("PASS" if ok2 else "FAIL"))

# 3) /d/ 下载
j = post("/api/fs/get", {"path": FILE, "password": ""}, tok)
sign = (j.get("data") or {}).get("sign") or ""
st3, hd3, b3 = get(BASE + "/d" + FILE + "?sign=" + sign,
                   {"User-Agent": UA}, OP_NR)
if st3 == 302:
    loc = hd3.get("Location") or ""
    st3b, _, b3b = get(loc, {"User-Agent": UA})
    print("3) /d/             -> HTTP 302 -> 直链 HTTP %d, %d 字节" % (st3b, len(b3b)))
    ok3 = st3b == 200 and len(b3b) == 38
else:
    print("3) /d/             -> HTTP %d, %d 字节" % (st3, len(b3)))
    ok3 = st3 == 200 and len(b3) == 38
print("   期望 200 + 38 字节: %s" % ("PASS" if ok3 else "FAIL"))

print("VERIFY:", "ALL-PASS" if (ok1 and ok2 and ok3) else "HAS-FAIL")
