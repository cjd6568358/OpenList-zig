"""STATUS §41.4 闭环实验：115 下载 403 的「Go 同结果」直接实证。

A/B 设计：
  A = Zig 实例（192.168.1.1:15399，现役修复产物）
  B = Go  实例（192.168.1.1:15398，/opt/sq/openlist/openlist 全新空库 + 同一 115 账号）
  同一个文件，分别从两个实例拿 115 直链，然后在**设备本机**（与两实例同源网络）
  curl 两个直链，对比状态码/正文。若两侧都 403 invalid signature ⇒ 上游拒签、
  与实现无关，演绎结论升级为实证；若 Go 侧 200 ⇒ Zig 有真 bug，需修。

只读使用生产二进制；不碰 15244 与 /tmp/olz；凭据不回显。
"""
import base64
import json
import time
import urllib.error
import urllib.request

import paramiko

DEV = ("192.168.1.1", 10022, "root", "REDACTED")
GO_BASE = "http://192.168.1.1:15398"
ZIG_BASE = "http://192.168.1.1:15399"
FILE = "olz-goab-ab.txt"
CONTENT = b"goab ab probe 115 direct link compare\n"

OP = urllib.request.build_opener(urllib.request.ProxyHandler({}))
OP_NOREDIR = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPRedirectHandler())


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):
        return None


OP_NOREDIR = urllib.request.build_opener(
    urllib.request.ProxyHandler({}), NoRedirect())


def http(url, method="GET", data=None, headers=None, opener=OP, timeout=120):
    r = urllib.request.Request(url, method=method, data=data,
                               headers=headers or {})
    try:
        with opener.open(r, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


def api(base, path, body, token=None):
    # ⚠ Go OpenList 的鉴权：Authorization 头直接放裸 token（不要 "Bearer " 前缀）
    # —— server/middlewares/auth.go:19,49 把整个头值丢给 ParseToken，
    # 带前缀会命中不了 GenerateToken 的缓存 ⇒ "token is invalidated"。
    h = {"Content-Type": "application/json"}
    if token:
        h["Authorization"] = token
    if body is None:
        st, hd, body = http(base + path, method="GET", headers=h)
    else:
        st, hd, body = http(base + path, method="POST",
                            data=json.dumps(body).encode(), headers=h)
    try:
        return json.loads(body.decode())
    except Exception:
        return {"code": st, "message": body[:120].decode("utf-8", "replace")}


# ---------- 1. 从 /tmp/olz/cfg.json 提取 115 addition ----------
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(*DEV[:2], username=DEV[2], password=DEV[3], timeout=20)
sftp = c.open_sftp()
with sftp.open("/tmp/olz/cfg.json", "r") as f:
    cfg = json.loads(f.read().decode("utf-8", "replace"))
sftp.close()
c.close()

add = None
for s in cfg.get("storages") or []:
    if str(s.get("driver", "")).strip() in ("115", "115 Cloud"):
        add = s.get("addition")
        break
if isinstance(add, str):
    add = json.loads(add)
go_add = {k: add[k] for k in ("cookie", "qrcode_token", "qrcode_source",
                              "page_size", "limit_rate", "root_folder_id")
          if add.get(k) not in (None, "")}
print("[1] 115 addition 提取完成（cookie <%d chars>）" % len(str(go_add.get("cookie", ""))))

# ---------- 2. Go 实例：登录 + 挂 115 ----------
j = api(GO_BASE, "/api/auth/login",
        {"username": "admin", "password": "goab-test-123456"})
go_tok = (j.get("data") or {}).get("token") or ""
print("[2] Go 登录 code=%s token=%d chars" % (j.get("code"), len(go_tok)))
if not go_tok:
    raise SystemExit("Go 登录失败")

j = api(GO_BASE, "/api/admin/storage/list", None, token=go_tok)
existing = [s for s in (j.get("data") or {}).get("content") or []
            if s.get("mount_path") == "/115"]
if existing:
    print("[2] Go /115 存储已存在（id=%s），复用" % existing[0].get("id"))
else:
    j = api(GO_BASE, "/api/admin/storage/create", {
        "mount_path": "/115", "order": 0, "remark": "goab-ab",
        "driver": "115 Cloud", "addition": json.dumps(go_add),
    }, token=go_tok)
    print("[2] Go storage/create code=%s msg=%s" % (j.get("code"), j.get("message")))
    if j.get("code") != 200:
        raise SystemExit("Go 挂载失败: %s" % json.dumps(j)[:200])

# 等 Go 侧 115 init（驱动 LoginCheck 等）
ok = False
for i in range(60):
    time.sleep(2)
    j = api(GO_BASE, "/api/fs/list", {"path": "/115", "refresh": False},
            token=go_tok)
    if j.get("code") == 200:
        ok = True
        print("[2] Go /115 就绪（%ds），条目 %d" % (
            (i + 1) * 2, len((j.get("data") or {}).get("content") or [])))
        break
if not ok:
    print("[2] Go /115 未就绪，最后响应:", json.dumps(j)[:200])

# ---------- 3. 建测试文件 ----------
# 用 Zig 实例建（e2e 已证 WebDAV PUT 201）。Go 实例的自动建号 admin 权限
# 0x71FF 缺 bit9（CanWebdavManage，model/user.go:175），PUT/MKCOL 会被
# webdav.go:120 直接 403 —— 与上传无关，测下载不需要它。
GO_DAV_AUTH = {"Authorization": "Basic " + base64.b64encode(
    b"admin:goab-test-123456").decode()}
ZIG_DAV_AUTH = {"Authorization": "Basic " + base64.b64encode(
    b"admin:e2e-test-123456").decode()}

st, hd, bd = http(ZIG_BASE + "/dav/115/" + FILE, method="PUT", data=CONTENT,
                  headers=ZIG_DAV_AUTH)
print("[3] Zig WebDAV PUT -> HTTP %d" % st)

# 等文件在 115 上对两侧可见（Zig 侧需要自己的 token）
j = api(ZIG_BASE, "/api/auth/login",
        {"username": "admin", "password": "e2e-test-123456"})
zig_tok = (j.get("data") or {}).get("token") or ""
print("[3] Zig 登录 code=%s token=%d chars" % (j.get("code"), len(zig_tok)))

seen = {"go": False, "zig": False}
for i in range(30):
    time.sleep(2)
    if not seen["go"]:
        j = api(GO_BASE, "/api/fs/list", {"path": "/115", "refresh": True},
                token=go_tok)
        names = [x.get("name") for x in (j.get("data") or {}).get("content") or []]
        seen["go"] = FILE in names
    if not seen["zig"]:
        j = api(ZIG_BASE, "/api/fs/list", {"path": "/115", "refresh": True},
                token=zig_tok)
        names = [x.get("name") for x in (j.get("data") or {}).get("content") or []]
        seen["zig"] = FILE in names
    if seen["go"] and seen["zig"]:
        print("[3] 两侧均可见（%ds）" % ((i + 1) * 2))
        break
if not (seen["go"] and seen["zig"]):
    print("[3] ⚠ 可见性 go=%s zig=%s，继续尝试" % (seen["go"], seen["zig"]))

# ---------- 4. A/B 拿直链（不跟随重定向） ----------
def direct_url(base, auth):
    st, hd, bd = http(base + "/dav/115/" + FILE, headers=auth,
                      opener=OP_NOREDIR, timeout=60)
    loc = hd.get("Location") or ""
    return st, loc


st_go, loc_go = direct_url(GO_BASE, GO_DAV_AUTH)
st_zig, loc_zig = direct_url(ZIG_BASE, ZIG_DAV_AUTH)
print("[4] Go  /dav GET -> HTTP %d, Location=%s" % (st_go, loc_go[:110]))
print("[4] Zig /dav GET -> HTTP %d, Location=%s" % (st_zig, loc_zig[:110]))
print("[4] 两直链完全相同: %s" % (loc_go == loc_zig and bool(loc_go)))

# ---------- 5. 设备本机同源 curl 两个直链 ----------
def dev_curl(url, tag):
    # URL 里的 & 在 sh -c 里安全（整体双引号）
    cmd = ("curl -s -o /tmp/goab_%s.body -w '%%{http_code}' --max-time 60 '%s'"
           % (tag, url))
    si, so, se = c.exec_command(cmd, timeout=90)
    code = so.read().decode().strip()
    si, so, se = c.exec_command("head -c 200 /tmp/goab_%s.body" % tag, timeout=30)
    body = so.read().decode("utf-8", "replace")
    return code, body


c2 = paramiko.SSHClient()
c2.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c2.connect(*DEV[:2], username=DEV[2], password=DEV[3], timeout=20)

if loc_go:
    code, body = dev_curl(loc_go, "go")
    print("[5] 设备本机 curl Go 直链  -> HTTP %s body=%s" % (code, body[:120]))
if loc_zig:
    code, body = dev_curl(loc_zig, "zig")
    print("[5] 设备本机 curl Zig 直链 -> HTTP %s body=%s" % (code, body[:120]))

# ---------- 6. PC 侧对照 ----------
for tag, loc in (("go", loc_go), ("zig", loc_zig)):
    if not loc:
        continue
    st, hd, bd = http(loc, timeout=60)
    print("[6] PC curl %s 直链 -> HTTP %d body=%s" % (tag, st, bd[:120].decode("utf-8", "replace")))

c2.close()
print("AB-DONE")
