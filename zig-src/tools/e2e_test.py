"""端到端全操作测试：对着真机上跑着的 openlist-zig 打真实的 HTTP 请求。

覆盖：列目录 / 详情 / 下载 / Range / 新建目录 / 上传 / 重命名 / 移动 / 复制 / 删除 /
      WebDAV(PROPFIND, GET, MKCOL, PUT, DELETE)。

**写操作默认只跑 Local 挂载点** —— 云盘上写东西会污染用户账号。
要测云盘写操作，显式加 `--write-cloud`，脚本会在一个明确命名的临时目录里做，
并在结束时清理。

copy 的两种预期（与 Go 逐驱动对齐）：
  * 支持 copy 的驱动（Local/WebDav/AliyundriveOpen）→ 200 且源文件保留；
  * 上游 NotSupport 的驱动（123Pan/Quark/itvsh）→ **必须 501**「明确说不支持」，
    而不是 500 / 崩溃 / 静默假成功（靠 `COPY_OK_MOUNTS` 白名单区分）。

用法：
    python tools/e2e_test.py http://192.168.1.1:15344 [--write-cloud]
        [--user admin] [--password ...]

退出码 0 = 全部通过；非 0 = 有失败项（明细打在 stdout）。
"""
import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request

PASS, FAIL, SKIP = [], [], []

# 支持 copy 的挂载点（白名单来自驱动源码审查：vtable 里有 `.copy` 槽的才在）。
#   local.zig / webdav.zig / aliyundrive.zig / cloud189pc.zig 有 copy；
#   quark.zig / pan123.zig / itvsh.zig 无（Go 同为 errs.NotSupport）。
# 名单之外的云盘一律断言「501 明确不支持」。
COPY_OK_MOUNTS = {"hikvision", "koofr", "jianguo", "aliyun", "ecloud_self", "ecloud_family",
                  # 115：Go `drivers/115/driver.go:138-143` 实现 Copy（WaitLimit +
                  # client.Copy → files/copy），Zig pan115.zig:595 同形同 URL。
                  # 2026-10-18 前漏了它，把真支持的挂载点断言成"必须 501"。
                  "115",
                  # WoPan 实现了 SDK 的 CopyFile（Go drivers/wopan/driver.go:134 同款），
                  # 2026-10-17 真机验证 copy 成功，移出"不支持"名单
                  "wo"}

# 上游**账号容量已满**、暂时不测「添加」（上传）的挂载点 —— 用户 2026-10-16
# 明确：quark 目前只需要测**读取和删除**，添加后面再说。
#
# 删除仍然要测：建目录不占容量（实测 mkdir success），所以删除的对象改成
# 刚建的临时目录本身。容量恢复后清空这个集合，写测即恢复全量。
NO_PUT_MOUNTS = {"quark"}

# ⚠️ 必须禁用系统代理（2026-10-18 踩坑）：`/d/` 对部分云盘（实测 wo）是
# **302 透传上游直链**（Go 的 common.Proxy 同形），urllib 跟随重定向到
# https 上游时会走 PC 上配的 HTTP 代理，CONNECT 被代理 502 ⇒ 脚本直接
# 崩在 traceback 上，把「本机代理问题」伪装成「回归炸了」。云盘直链本来
# 就可能从 PC 不可达（du.smartont.net:8445 实测连不上），这不是服务端
# 缺陷 —— 直链可达性由设备本机 loopback 探针负责（tools/dav_compare.py）。
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _open_noredir(r, timeout):
    """不跟随重定向、不走系统代理地打开一个请求。

    云盘直链（/d/ 对 wo 等是 302 透传上游，Go 的 common.Proxy 同形）从 PC
    往往不可达（du.smartont.net:8445 实测连不上），跟随它只会把「上游网络
    问题」误报成回归失败。断言第一跳即可。
    """
    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **kw):
            return None

    op = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
    return op.open(r, timeout=timeout)


def _open_req(r, timeout, noredir):
    """统一入口：noredir=True 走不跟随 302 的 opener。"""
    if noredir:
        return _open_noredir(r, timeout)
    return _OPENER.open(r, timeout=timeout)


def req(base, path, *, method="GET", token=None, body=None, headers=None, raw=False,
        timeout=90, retries=2, noredir=False):
    """发一个请求，返回 (状态码, 正文, 响应头dict)。

    `retries`：连接被重置时的尝试次数（默认 2）。本机到光猫的路由走
    easytier 隧道，relay 对**大响应**会偶发 RST（2026-10-17 抓包定位：
    光猫本机 loopback 同一请求 15/15 全过、服务端零错误日志，属链路传输层
    抖动，非实现问题）。WebDAV 那些请求它加多重试，别记成假失败
    —— 但重试次数必须**有界**，否则真挂死的请求会把回归拖成无限等待。

    `noredir`：不跟随 302。远程文件的 WebDAV Range 用第一跳断言 ——
    跟随 302 到云盘直链等于把「CDN 从 PC 的可达性」混进回归（天翼家庭云
    S3 实测：loopback 206、PC 403/400，全是链路态度，见 STATUS §40.3）。
    """
    url = base + path
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs.setdefault("Content-Type", "application/json")
    if token:
        hdrs["Authorization"] = "Bearer " + token
    r = urllib.request.Request(url, data=data, method=method, headers=hdrs)
    for attempt in range(1, retries + 1):
        try:
            with _open_req(r, timeout, noredir) as resp:
                payload = resp.read()
                return resp.status, (payload if raw else payload.decode(errors="replace")), dict(resp.headers)
        except urllib.error.HTTPError as e:
            payload = e.read()
            return e.code, (payload if raw else payload.decode(errors="replace")), dict(e.headers)
        except (ConnectionError, TimeoutError, OSError):
            if attempt == retries:
                raise
            time.sleep(1.0)


def put_raw(base, path, data, headers):
    """发一个带原始 body 的 PUT（上传用）。返回 (状态码, 响应体文本, 响应头)。

    三元组而不是二元组：WebDAV 的 PUT 语义要靠响应头验证（状态码恒 201 +
    必带 ETag，见 `server/webdav/webdav.go:414-423`），只看状态码分不出
    「回了 ETag」和「没回 ETag」。
    """
    import http.client
    import urllib.parse
    u = urllib.parse.urlparse(base)
    for attempt in (1, 2):
        conn = http.client.HTTPConnection(u.hostname, u.port, timeout=180)
        try:
            conn.request("PUT", path, body=data, headers=headers)
            r = conn.getresponse()
            body = r.read().decode(errors="replace")
            return r.status, body[:300], dict(r.getheaders())
        except (ConnectionError, TimeoutError, OSError):
            if attempt == 2:
                raise
            time.sleep(1.0)
        finally:
            conn.close()


def check(name, ok, detail=""):
    if ok:
        PASS.append(name)
        print("  ✅ %-46s %s" % (name, detail))
    else:
        FAIL.append(name)
        print("  ❌ %-46s %s" % (name, detail))


def api(base, path, token, body=None, method="POST"):
    """调一个 JSON 接口，返回 (status, dict)。

    Go 的 API 一律返回 `{"code":..,"message":..,"data":..}` 信封。如果服务端
    返回了别的形状（裸 null、非 JSON），这里归一成 `{"code": <status>}` 并保留
    原文，免得脚本自己崩掉、把「服务端不符合 Go」误报成「脚本出错」。
    """
    st, txt, _ = req(base, path, method=method, token=token, body=body)
    try:
        j = json.loads(txt)
    except Exception:
        return st, {"code": st, "_raw": txt[:200]}
    if not isinstance(j, dict):
        # 裸 `null` 之类 —— 记下原始形状，方便断言失败时一眼看出原因
        return st, {"code": st, "_raw_shape": repr(j)[:120], "_raw": txt[:200]}
    return st, j


def ls(base, token, path):
    st, j = api(base, "/api/fs/list", token, {"path": path, "page": 1, "per_page": 100})
    return (j.get("data", {}) or {}).get("content", []) if j.get("code") == 200 else None


def ls_eventually(base, token, path, pred, tries=30, delay=2.0):
    """写操作后轮询列表，直到 pred 满足或超时（默认窗口 60 秒）。

    189 个人云的 listFiles 实测有**秒级到十几秒**的最终一致性延迟：mkdir 返回
    成功后立刻 list 可能还看不到新目录（Go 驱动读同一个上游 API、MakeDir 也不
    sleep，行为完全相同）。所以「新建可见」这类检查必须轮询，不能一锤定音 ——
    18 秒 / 40 秒窗口实测都不够（1792166227、1792168459 两轮超时后 copy 直接
    not found），放宽到 60 秒。这不是在掩盖缺陷：延迟来自上游，与 Go 同
    （Go 的 189pc MakeDir 也不 sleep）。
    """
    last = []
    for _ in range(tries):
        last = ls(base, token, path) or []
        if pred(last):
            return last
        time.sleep(delay)
    return last


def op_retry(base, token, path, body, tries=4, delay=2.0):
    """对 "not found" 重试的写操作调用。

    189 的 listFiles 有秒级最终一致性延迟：刚 mkdir/上传/重命名的路径立刻去
    解析可能NotFound。Go 的前端/API 移动的是「已带 id 的对象」（从列表里来），
    天然回避这个窗口；我们这层收到的是路径、必须重新解析，所以重试。
    真失败只会晚几秒暴露，不会被掩盖。
    """
    last = {}
    for _ in range(tries):
        st, j = api(base, path, token, body)
        last = j
        if j.get("code") == 200:
            return j
        if "not found" not in str(j.get("message", "")):
            return j
        time.sleep(delay)
    return last


def post_raw(base, path, data, headers):
    """发一个带原始 body 的 POST（测「非法 JSON」这类输入用）。

    注意 `req()` 会对 body 做 `json.dumps`，所以**不能**用它发坏 JSON ——
    那样发过去的是一个合法 JSON 字符串，测不出服务端的解析防护。
    """
    import http.client
    import urllib.parse
    u = urllib.parse.urlparse(base)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=60)
    try:
        conn.request("POST", path, body=data, headers=headers)
        r = conn.getresponse()
        body = r.read().decode(errors="replace")
        return r.status, body[:200]
    finally:
        conn.close()


def pick_file(base, token, mounts, max_size=None):
    """在给定挂载点里挑一个非空（可选：不超过 max_size）的文件路径。"""
    for m in mounts:
        for o in (ls(base, token, "/" + m) or []):
            if o["is_dir"] or o["size"] <= 0:
                continue
            if max_size and o["size"] > max_size:
                continue
            return "/%s/%s" % (m, o["name"])
    return None


def download_check(base, token, path):
    """fs/get → 下载 → Range → 篡改 sign，一条链路打全。"""
    st, j = api(base, "/api/fs/get", token, {"path": path})
    d = j.get("data", {}) or {}
    check("fs/get %s" % path, j.get("code") == 200,
          "size=%s type=%s" % (d.get("size"), d.get("type")))
    check("fs/get 带 raw_url", bool(d.get("raw_url")), str(d.get("raw_url"))[:60])
    # 下载走 sign：`sign_all=true` 的部署（用户光猫上的真实配置）里 `/d/`
    # 只认 `?sign=`，带 token 也会 401 —— 与 Go 的 Down 中间件同形。
    # sign 从 `fs/get` 响应的 `sign` 字段来；为空说明服务端没开签名，
    # 那就回落 token。
    sign = d.get("sign") or ""
    dl = "/d" + path + ("?sign=" + sign if sign else "")
    # 第一跳即可：200 = 本端代理正文；302 = 透传上游直链（Go 的
    # common.Proxy 同形，Location 指向云盘 CDN，PC 未必可达，不跟随）。
    try:
        with _open_noredir(urllib.request.Request(base + dl), timeout=90) as resp:
            st1, body, hdrs1 = resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        st1, body, hdrs1 = e.code, e.read(), dict(e.headers)
    if st1 == 302:
        loc = hdrs1.get("Location", "")
        check("下载 /d%s" % path, loc.startswith("http"),
              "HTTP 302 -> 上游直链 %s" % loc[:60])
        # Range / 篡改 sign 在上游侧，本端管不着（Go 同形：Range 原样转发）。
        # 篡改 sign 仍要在本端验（sign 校验在重定向之前）。
        if sign:
            bad = sign[:-1] + ("x" if sign[-1] != "x" else "y")
            st_bad, _, _ = req(base, "/d" + path + "?sign=" + bad, raw=True)
            check("篡改的 sign 被拒", st_bad == 401, "HTTP %d" % st_bad)
        return
    # ⚠ 不要给 115 开口子（2026-10-18 曾错误地开过，STATUS §41.6）：
    # 当时把「Device 本机 curl 直链 403 invalid signature」判成上游拒签，
    # 后来 A/B 实证真因是 **WebDAV 的 link 调用没传请求头 ⇒ 115 直链签名
    # 绑定的 User-Agent 前后不一致**。修好后 115 与其他远程盘同形。
    check("下载 /d%s" % path, st1 == 200 and len(body) > 0,
          "HTTP %d, %d 字节%s" % (st1, len(body), " (sign)" if sign else " (token)"))
    st, body2, _ = req(base, dl, token=None if sign else token,
                       headers={"Range": "bytes=0-3"}, raw=True)
    check("Range 206", st == 206, "HTTP %d, %d 字节" % (st, len(body2)))
    if sign:
        # 签名必须绑定路径：拿别处的 sign 来下应当被拒。
        bad = sign[:-1] + ("x" if sign[-1] != "x" else "y")
        st_bad, _, _ = req(base, "/d" + path + "?sign=" + bad, raw=True)
        check("篡改的 sign 被拒", st_bad == 401, "HTTP %d" % st_bad)


def proxy_and_sign_check(base, tok):
    """5.0 /p/ 代理端点 + 签名过期/非法场景。

    行为基线（2026-10-17 真机探针钉死，对齐 Go down.go + pkg/sign/hmac.go）：
      * /p/ 准入 = `canProxy`（MustProxy || WebProxy || use_proxy_url ||
        proxy_types || text_types）—— 本地存储的 link 是 must_proxy，所以
        任意扩展名都 200；远程非代理挂载要靠 text_types 放行文本类。
      * /p/ 与 /d/ 一样**先过 sign**（sign_all=true 时 token 不认），
        sign 绑定路径：拿 A 文件的 sign 访问 B 路径（含目录、不存在的
        路径）一律 401。
      * verifySign 先查 expire 再验 HMAC：
          "xxx:1"   → 过期   → 401
          "nocolon" → expire missing → 401
          "xxx:abc" → expire invalid  → 401
        （过期测试不需要 jwt_secret：过期检查在 HMAC 之前。）
    """
    print("\n=== 5.0 /p/ 代理端点 + 签名过期 ===")
    # 造本地探针文件（local = must_proxy，任意扩展名可代理）
    put_raw(base, "/api/fs/put", b"proxy probe text\n",
            {"Authorization": "Bearer " + tok, "File-Path": "/hikvision/olz-p-proxy.txt"})
    put_raw(base, "/api/fs/put", b"BIN\x00\x01",
            {"Authorization": "Bearer " + tok, "File-Path": "/hikvision/olz-p-proxy.xyzunk"})
    time.sleep(1)

    def sign_of(p):
        st, j = api(base, "/api/fs/get", tok, {"path": p})
        return (j.get("data", {}) or {}).get("sign") or ""

    s = sign_of("/hikvision/olz-p-proxy.txt")
    if not s:
        check("/p/ 前置：fs/get 返回 sign（sign_all=true）", False, "sign 为空，跳过 /p/ 专项")
        return
    st, b, h = req(base, "/p/hikvision/olz-p-proxy.txt?sign=" + s, raw=True)
    check("/p/ 本地 txt → 200 + 正文", st == 200 and b.startswith(b"proxy probe"),
          "HTTP %d, %r" % (st, b[:20]))
    check("  Content-Type 是 text/*", str(h.get("Content-Type", "")).startswith("text/"),
          str(h.get("Content-Type")))
    st, b, _ = req(base, "/p/hikvision/olz-p-proxy.xyzunk?sign=" + s, raw=True)
    # ⚠ 用 txt 的 sign 访问另一文件路径 → sign 绑定路径 → 401。
    #    （本地存储 must_proxy=true，扩展名不影响准入；但 sign 不匹配先拦。）
    check("/p/ sign 绑定路径（跨文件 → 401）", st == 401, "HTTP %d" % st)
    s_bin = sign_of("/hikvision/olz-p-proxy.xyzunk")
    st, b, _ = req(base, "/p/hikvision/olz-p-proxy.xyzunk?sign=" + s_bin, raw=True)
    check("/p/ 本地未知扩展名 → 200（must_proxy）", st == 200 and b == b"BIN\x00\x01",
          "HTTP %d, %r" % (st, b[:10]))
    # 目录 / 不存在的路径（拿着有效 sign，路径不匹配 → 401）
    for label, p in (("目录", "/hikvision"), ("不存在", "/hikvision/no-such-olz-p.txt")):
        st, _, _ = req(base, "/p" + p + "?sign=" + s, raw=True)
        check("/p/ %s（sign 路径不匹配 → 401）" % label, st == 401, "HTTP %d" % st)
    # 签名过期/非法（401 + HTML 错误页，Go ErrorPage 语义）
    hmac_part = s.split(":")[0]
    for label, sg in (("过期（:1）", hmac_part + ":1"),
                      ("无冒号", "nocolon"),
                      ("非法 expire（:abc）", "xxx:abc")):
        st, _, _ = req(base, "/d/hikvision/olz-p-proxy.txt?sign=" + sg, raw=True)
        check("sign %s → 401" % label, st == 401, "HTTP %d" % st)
        st2, _, _ = req(base, "/p/hikvision/olz-p-proxy.txt?sign=" + sg, raw=True)
        check("  /p/ 同样拒绝", st2 == 401, "HTTP %d" % st2)
    # 清理探针
    api(base, "/api/fs/remove", tok, {"dir": "/hikvision",
                                      "names": ["olz-p-proxy.txt", "olz-p-proxy.xyzunk"]})


def auth_user(tok):
    return {"Authorization": "Bearer " + tok}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("--write-cloud", action="store_true")
    ap.add_argument("--mounts", default="", help="逗号分隔，只测这些挂载点")
    ap.add_argument("--extra-download", default="",
                    help="逗号分隔的挂载点：除全局那一次外，再各自做一次定向下载")
    ap.add_argument("--user", default="e2eadmin")
    ap.add_argument("--password", default="e2e-test-123456")
    args = ap.parse_args()
    base = args.base.rstrip("/")

    print("=== 0. 准备：初始化/登录 ===")
    u, p = args.user, args.password
    # Go **没有** `/api/auth/register`。首次建管理员用官方的 init/setup
    # （server/handles/setup.go）；已初始化时它会返回 400，忽略即可，
    # 直接用已有账号登录（凭据可用 --user/--password 覆盖）。
    req(base, "/api/public/init/setup", method="POST", body={"username": u, "password": p})
    st, txt, _ = req(base, "/api/auth/login", method="POST", body={"username": u, "password": p})
    tok = (json.loads(txt).get("data") or {}).get("token")
    check("登录拿到 token", bool(tok))
    if not tok:
        return 1

    # ---- 0.5 等挂载点发布 ----
    # ⚠️ 时序陷阱（2026-10-18 实测踩到）：进程先 listen、再同步 init 全部
    # 存储（要依次访问十几个云盘 API，数秒到数十秒），最后才 publish mounts。
    # `deploy_device.py restart` 返回后立刻跑本脚本 ⇒ fs/list 拿到**空**
    # content、后续「可下载文件」「可写挂载点」连锁失败，全是**假失败**
    # （服务本身没问题，稍后重跑 91/91 全过）。这里轮询到挂载点就绪，
    # 把「重启后马上跑」和「真回归失败」区分开。
    print("\n=== 0.5 等待存储初始化 ===")
    deadline = time.time() + 120
    mounts_ready = []
    while time.time() < deadline:
        st, j = api(base, "/api/fs/list", tok, {"path": "/"})
        mounts_ready = [o["name"] for o in (j.get("data", {}) or {}).get("content", [])] if j.get("code") == 200 else []
        if mounts_ready:
            break
        time.sleep(2.0)
    check("挂载点已发布", len(mounts_ready) > 0,
          ("%d 个: %s" % (len(mounts_ready), ", ".join(mounts_ready))) if mounts_ready else "120s 内未发布")
    if not mounts_ready:
        return 1

    # ---- 1. 列目录（所有挂载点）----
    print("\n=== 1. 列目录 ===")
    st, j = api(base, "/api/fs/list", tok, {"path": "/"})
    mounts = [o["name"] for o in (j.get("data", {}) or {}).get("content", [])] if j.get("code") == 200 else []
    check("虚拟根列出挂载点", len(mounts) > 0, "挂载: " + ", ".join(mounts))
    only = {x for x in args.mounts.split(",") if x.strip()}
    for m in mounts:
        if only and m not in only:
            continue
        c = ls(base, tok, "/" + m)
        check("list /%s" % m, c is not None, ("%d 条" % len(c)) if c is not None else "失败")

    # ---- 2. 详情 + 下载 + Range（挑一个真实文件）----
    print("\n=== 2. 详情 / 下载 / Range ===")
    target = pick_file(base, tok, mounts)
    if target:
        download_check(base, tok, target)
    else:
        check("找到可下载的文件", False, "所有挂载点都没有非空文件")

    # ---- 2b. 定向下载（--extra-download 指定的挂载点）----
    # 为什么需要：全局只挑**一个**文件下载，覆盖不到其余挂载点。quark 的下载
    # 链路正是出过 502 的那条（STATUS §30/§31），必须单独钉住 —— 而它现在
    # 只做「读取 + 删除」回归（账号容量满，添加暂不测，见 NO_PUT_MOUNTS）。
    if args.extra_download:
        print("\n=== 2b. 定向下载（%s）===" % args.extra_download)
        for m in [x.strip() for x in args.extra_download.split(",") if x.strip()]:
            if m not in mounts:
                continue
            t = pick_file(base, tok, [m], max_size=2 * 1024 * 1024)
            if not t:
                SKIP.append("定向下载 /%s（无 <2MB 文件，避免拖慢回归）" % m)
                print("  ⚠️ 跳过 %-46s 没有 <2MB 的文件" % ("定向下载 /" + m))
                continue
            download_check(base, tok, t)

    # ---- 3. WebDAV（读）----
    print("\n=== 3. WebDAV 读 ===")
    cred = base64.b64encode(("%s:%s" % (u, p)).encode()).decode()
    h = {"Authorization": "Basic " + cred, "Depth": "1"}
    st, txt, _ = req(base, "/dav/", method="PROPFIND", headers=h)
    check("PROPFIND /dav/", st == 207, "HTTP %d" % st)
    if target:
        st, txt, _ = req(base, "/dav" + target, method="PROPFIND", headers={"Authorization": "Basic " + cred, "Depth": "0"})
        check("PROPFIND %s" % target, st == 207, "HTTP %d" % st)
        # ⚠️ 大响应经测试链路（本机 → easytier 隧道 → 光猫）偶发被 relay RST：
        # 2026-10-17 抓包定位 —— 光猫本机 loopback 同一请求 15/15 全过、服务端
        # 无任何错误日志，RST 来自隧道 relay（PC 在 10.0.0.3 网、到
        # 192.168.1.1 的路由走 et_2_pmog）。属链路传输层抖动，非实现问题，
        # 给这一项独立多重试，别记成假失败。
        st, body = 0, b""
        for _ in range(3):
            try:
                st, body, _ = req(base, "/dav" + target, headers={"Authorization": "Basic " + cred}, raw=True)
                if st == 200 and len(body) > 0:
                    break
            except Exception:
                st = 0
            time.sleep(1)
        check("WebDAV GET", st == 200 and len(body) > 0, "HTTP %d, %d 字节" % (st, len(body)))

    # ---- 4. 写操作（Local 全测；云盘需 --write-cloud）----
    print("\n=== 4. 写操作 ===")
    writable = [m for m in mounts if m == "hikvision"]
    if args.write_cloud:
        writable = [m for m in mounts if m != "hikvision"] + writable
    # `--mounts` 必须同时约束写操作：否则只想测 itvsh/aliyun 时，会把没有写
    # 权限的挂载点（例如 189pc 的家庭云目录）也一起跑了，噪声淹掉真正的失败。
    if only:
        writable = [m for m in writable if m in only]
    if not writable:
        check("存在可写挂载点", False, "没找到 hikvision")
    for m in writable:
        tag = "olz-e2e-%d" % int(time.time())
        d = "/%s/%s" % (m, tag)
        print("  -- 挂载点 /%s（临时目录 %s）" % (m, tag))
        st, j = api(base, "/api/fs/mkdir", tok, {"path": d})
        check("mkdir", j.get("code") == 200, str(j.get("message", "")))
        if j.get("code") != 200:
            continue

        if m in NO_PUT_MOUNTS:
            # 账号容量满：不测添加。删除仍要测 —— 对象就是刚建的临时目录
            # （建目录不占容量）。等它可见再删，避免最终一致性造成的假失败。
            c = ls_eventually(base, tok, "/" + m, lambda c: any(x["name"] == tag for x in c))
            check("mkdir 后等可见（最终一致性）", any(x["name"] == tag for x in c))
            j = op_retry(base, tok, "/api/fs/remove", {"dir": "/" + m, "names": [tag]})
            check("删除目录（容量满：只测删除）", j.get("code") == 200, str(j.get("message", "")))
            c = ls_eventually(base, tok, "/" + m, lambda c: not any(x["name"] == tag for x in c))
            check("删除生效", not any(x["name"] == tag for x in c))
            continue

        # 上传：/api/fs/put 收的是**原始 body**（不是 JSON），所以用 http.client
        # 而不是上面的 JSON 包装。File-Path 头指定目标路径。
        content = b"openlist-zig e2e payload\n"
        st, put_body, _ = put_raw(base, "/api/fs/put", content,
                                  {"Authorization": "Bearer " + tok, "File-Path": d + "/a.txt"})
        # ⚠ 信封语义（2026-10-18 真机事故）：JSON API 恒回 HTTP 200，业务码在
        # body 的 code 里 —— 115 put 曾在 getOssToken 抛 InvalidResponse，
        # 响应是 HTTP 200 + {"code":500}，老断言只验状态码 ⇒ 假成功
        # （目录里根本没有 a.txt）。这里必须验 body code。
        try:
            put_code = json.loads(put_body).get("code")
        except Exception:
            put_code = None
        if st != 200 or put_code != 200:
            if "capacity limit" in put_body.lower():
                # 上游账号容量限制（实测：夸克 400 code 32003 "capacity limit"）。
                # 这是账号状态不是实现缺陷 —— 记 SKIP，并跳过该挂载点的文件级
                # 后续（否则会 cascade 一屏 "not found" 假失败）。
                SKIP.append("上传 a.txt @%s（上游容量限制）" % m)
                print("  ⚠️ 跳过 %-46s 上游容量限制（非实现问题）" % "上传 a.txt")
            else:
                check("上传 a.txt", False, "HTTP %d code=%s %s" % (st, put_code, put_body[:80]))
            # 尽力清掉刚建的临时目录
            api(base, "/api/fs/remove", tok, {"dir": "/" + m, "names": [tag]})
            continue
        check("上传 a.txt", True, "HTTP %d code=200" % st)

        c = ls_eventually(base, tok, d, lambda c: any(x["name"] == "a.txt" for x in c))
        check("上传后能看到 a.txt", any(x["name"] == "a.txt" for x in c), "%d 条" % len(c))

        # 子目录（copy 与 move 的目标）先建好；先等它**可见**再 copy ——
        # 189 等后端 mkdir 后 list 有秒级最终一致性，resolve 目录会 404
        # （实测 ecloud_self copy 因此假失败过一次）。
        st, j = api(base, "/api/fs/mkdir", tok, {"path": d + "/sub"})
        check("mkdir sub", j.get("code") == 200, str(j.get("message", "")))
        c = ls_eventually(base, tok, d, lambda c: any(x["name"] == "sub" for x in c))
        sub_ok = any(x["name"] == "sub" for x in c)
        if sub_ok:
            check("mkdir sub 后等可见（最终一致性）", True)
        else:
            # 60 秒同步窗口内仍未可见 —— 189 上游的最终一致性（Go 同样：它的
            # MakeDir 也不 sleep）。记为**跳过**而不是失败：不是实现缺陷，
            # 但依赖这个目录的 copy 也就无从验证了。
            SKIP.append("mkdir sub 未同步可见 @%s（189 上游最终一致性）" % m)
            print("  ⚠️ 跳过 %-46s 上游同步超时，copy 无从验证" % "mkdir sub 可见")

        # ---- copy：支持组 200 且源保留；NotSupport 组必须 501 ----
        if not sub_ok:
            pass  # 目标目录都不可见，copy 的结果（404）说明不了任何问题
        else:
            j = op_retry(base, tok, "/api/fs/copy",
                         {"src_dir": d, "dst_dir": d + "/sub", "names": ["a.txt"]})
            if m in COPY_OK_MOUNTS:
                check("copy a.txt -> sub/", j.get("code") == 200, str(j.get("message", "")))
                c2 = ls_eventually(base, tok, d + "/sub", lambda c: any(x["name"] == "a.txt" for x in c))
                check("copy 产物出现在 sub/", any(x["name"] == "a.txt" for x in c2))
                c2 = ls_eventually(base, tok, d, lambda c: any(x["name"] == "a.txt" for x in c))
                check("copy 后源文件保留", any(x["name"] == "a.txt" for x in c2))
            else:
                # 上游 NotSupport（Go `drivers/quark_uc/driver.go:117` 等）：必须
                # 「明确说不支持」而不是 500 / 崩溃 / 静默假成功（api.zig 映射 501）。
                msg = str(j.get("message", "")).lower()
                check("copy 明确不支持(501)", j.get("code") == 501 and "not support" in msg,
                      "code=%s msg=%s" % (j.get("code"), j.get("message")))

        j = op_retry(base, tok, "/api/fs/rename", {"path": d + "/a.txt", "name": "b.txt"})
        check("重命名 a.txt -> b.txt", j.get("code") == 200, str(j.get("message", "")))
        c = ls_eventually(base, tok, d, lambda c: any(x["name"] == "b.txt" for x in c))
        check("重命名生效", any(x["name"] == "b.txt" for x in c))

        j = op_retry(base, tok, "/api/fs/move",
                     {"src_dir": d, "dst_dir": d + "/sub", "names": ["b.txt"]})
        check("移动到 sub/", j.get("code") == 200, str(j.get("message", "")))
        c = ls_eventually(base, tok, d + "/sub", lambda c: any(x["name"] == "b.txt" for x in c))
        check("移动生效", any(x["name"] == "b.txt" for x in c))

        # b.txt 已经被移到 sub/ 了，要从 sub/ 删（这里原来写错了目录）
        j = op_retry(base, tok, "/api/fs/remove", {"dir": d + "/sub", "names": ["b.txt"]})
        check("删除文件", j.get("code") == 200, str(j.get("message", "")))
        c = ls_eventually(base, tok, d + "/sub", lambda c: not any(x["name"] == "b.txt" for x in c))
        check("删除生效", not any(x["name"] == "b.txt" for x in c))

        # WebDAV 写（同样是原始 body）
        st, _, put_hdrs = put_raw(base, "/dav" + d + "/w.txt", b"webdav payload",
                                  {"Authorization": "Basic " + cred})
        check("WebDAV PUT", st == 201, "HTTP %d" % st)
        c = ls_eventually(base, tok, d, lambda c: any(x["name"] == "w.txt" for x in c))
        check("WebDAV PUT 生效", any(x["name"] == "w.txt" for x in c))

        # ---- WebDAV 协议语义（逐条对标 Go server/webdav/webdav.go）----
        # 全是 2026-10-17 对账出来的偏离：状态码、Allow 三套值、DAV "1,2"、
        # MS-Author-Via、目录 HEAD/GET 的分野、401 realm、Etag、Range、304。
        wp = "/dav" + d + "/w.txt"
        wd = "/dav" + d + "/"
        auth = {"Authorization": "Basic " + cred}

        # PUT 必带 ETag（Go handlePut:422）；且**覆盖**也是 201 不是 204。
        #
        # ⚠ 云盘（尤其 189 个人云）的 `initMultiUpload` 在并发下会
        #   "Read timed out"（真机日志实证，不是本端问题），这里给一次重试 ——
        #   10 个挂载点连续上传时它偶发，单独重试必成。
        st2, _, h2 = put_raw(base, wp, b"webdav payload", auth)
        if st2 != 201:
            time.sleep(3)
            st2, _, h2 = put_raw(base, wp, b"webdav payload", auth)
        check("WebDAV PUT 覆盖 → 201", st2 == 201, "HTTP %d" % st2)
        # 头名是 Go 的大小写 `Etag`
        check("WebDAV PUT 带 Etag", bool(h2.get("Etag") or h2.get("etag")),
              str(h2.get("Etag") or h2.get("etag")))
        # 目标已存在的目录 ⇒ 405（不是 502）
        st2, _, _ = put_raw(base, "/dav" + d, b"nope", auth)
        check("WebDAV PUT 目录 → 405", st2 == 405, "HTTP %d" % st2)

        # OPTIONS：目录/文件两套 Allow + DAV "1, 2" + MS-Author-Via
        st2, _, h2 = req(base, wd, method="OPTIONS", headers=auth)
        check("WebDAV OPTIONS 目录", st2 == 200, "HTTP %d" % st2)
        check("  DAV: 1, 2", h2.get("DAV") == "1, 2", str(h2.get("DAV")))
        check("  MS-Author-Via: DAV", h2.get("MS-Author-Via") == "DAV",
              str(h2.get("MS-Author-Via")))
        check("  Allow(目录) 完整", h2.get("Allow") ==
              "OPTIONS, LOCK, DELETE, PROPPATCH, COPY, MOVE, UNLOCK, PROPFIND",
              str(h2.get("Allow")))
        st2, _, h2 = req(base, wp, method="OPTIONS", headers=auth)
        check("  Allow(文件) 完整", h2.get("Allow") ==
              "OPTIONS, LOCK, GET, HEAD, POST, DELETE, PROPPATCH, COPY, MOVE, UNLOCK, PROPFIND, PUT",
              str(h2.get("Allow")))

        # 未鉴权 → 401，realm 是固定小写 "openlist"
        st2, _, h2 = req(base, "/dav/", method="PROPFIND", headers={"Depth": "1"})
        check("WebDAV 未鉴权 → 401", st2 == 401, "HTTP %d" % st2)
        check("  WWW-Authenticate realm", h2.get("WWW-Authenticate") == 'Basic realm="openlist"',
              str(h2.get("WWW-Authenticate")))

        # 非法 Depth → 400（此前静默按 1 处理）
        st2, _, _ = req(base, wd, method="PROPFIND",
                        headers={"Authorization": "Basic " + cred, "Depth": "2"})
        check("WebDAV PROPFIND Depth=2 → 400", st2 == 400, "HTTP %d" % st2)

        # 目录：HEAD 200 + httpd/unix-directory；GET 405（此前两者都 404）
        st2, _, h2 = req(base, wd, method="HEAD", headers=auth)
        check("WebDAV HEAD 目录 → 200", st2 == 200, "HTTP %d" % st2)
        check("  Content-Type: httpd/unix-directory",
              h2.get("Content-Type") == "httpd/unix-directory", str(h2.get("Content-Type")))
        st2, _, _ = req(base, wd, method="GET", headers=auth)
        if m != "hikvision" and st2 == 404:
            # 远程：details() 底下的 PROPFIND 遇上游**瞬时**失败（404 / 连接
            # 抖动）时本端回 404 —— Go 的 `fs.Get` 出错同样一律 404
            # （webdav.go:242-245），行为对齐，不是实现缺陷。目录的存在已由
            # 上一行 HEAD 200 + mkdir 可见性证明，重试一次消歧「瞬时失败」
            # 与「真 404」（与上面 PUT 覆盖 → 201 的重试同型；2026-10-18
            # koofr 实测过一次：HEAD 200 之后 GET 404，重跑 65 次全 405）。
            time.sleep(2)
            st2, _, _ = req(base, wd, method="GET", headers=auth)
        check("WebDAV GET 目录 → 405", st2 == 405, "HTTP %d" % st2)

        # Range / 条件请求。
        #
        # ⚠ 两条分支的语义本来就不同（2026-10-17 对账，见 STATUS §35）：
        #   * **本地**（hikvision）走 Go `net.ServeHTTP` 那条：本端自己切
        #     Range（206 + Content-Range）、越界合成 416（带 `bytes */total`）、
        #     发 Etag/条件请求（304）。
        #   * **远程直链**走 `common.Proxy` 的透明代理：客户端的 Range 原样
        #     发给上游，**上游回什么就是什么** —— 上游不支持 Range 时回 200
        #     （Go 同样），本端既不切片也不合成 416，Etag 只在上游自己带了才
        #     有。所以下面这些断言按分支分开写，不能一律要求 206/416/304。
        is_local = (m == "hikvision")
        st2, b2, h2 = req(base, wp, headers=dict(auth, Range="bytes=0-4"), raw=True,
                          retries=4, noredir=True)
        if is_local:
            check("WebDAV Range → 206", st2 == 206, "HTTP %d" % st2)
            check("  Content-Range", h2.get("Content-Range") == "bytes 0-4/14",
                  str(h2.get("Content-Range")))
            check("  Accept-Ranges: bytes", h2.get("Accept-Ranges") == "bytes",
                  str(h2.get("Accept-Ranges")))
            check("  Range 正文 5 字节", len(b2) == 5, "%d 字节" % len(b2))
        else:
            # 远程：**第一跳**形态就是服务端的全部行为（2026-10-18 修，
            # STATUS §40.3）：webdav_policy=302_redirect ⇒ 302 透传直链
            # （Go `WebDAVAuth` 同形）；默认 ⇒ 本端代理流式输出，Range
            # 原样转发上游 —— 上游支持就 206、不支持就 200 整份，Zig
            # 照抄。跟随 302 打到云盘 CDN 只会把「PC→上游可达性」混进
            # 回归（天翼家庭云 S3 loopback 实测 206、PC 403/400）——
            # 与 /d/ 下载断言同构。
            # ⚠ 不要给 115 开口子（2026-10-18 曾错误地开过，STATUS §41.6）：
            # 当时判「上游 CDN 拒签，Go 同形」，A/B 实证是 WebDAV 的 link
            # 调用漏传请求头 ⇒ 115 的 UA 绑定签名前后不一致。已修，
            # 115 与其他远程盘同形断言。
            ok_first = st2 in (200, 206, 302)
            check("WebDAV Range（远程：第一跳 200/206/302）",
                  ok_first, "HTTP %d" % st2)
            if st2 == 302:
                loc = h2.get("Location") or ""
                check("  Location 指向上游直链", loc.startswith("http"), loc[:60])
            else:
                # 本端代理分支：Range 已转发上游，透传其状态；正文不断言
                # （可能是整份）。koofr 的 CDN 回 206 不带 Content-Range，
                # 那也是"照抄上游"。
                print("  ℹ️ 远程本端代理 Range → 上游说 %d（照抄，不断言）" % st2)

        st2, _, h2 = req(base, wp, headers=dict(auth, Range="bytes=999-"), retries=4,
                         noredir=True)
        if is_local:
            check("WebDAV Range 越界 → 416", st2 == 416, "HTTP %d" % st2)
            check("  416 带 Content-Range: bytes */14",
                  h2.get("Content-Range") == "bytes */14", str(h2.get("Content-Range")))
        else:
            # 远程：第一跳 302 透传时 Range 根本到不了上游（客户端自己带），
            # 本端代理 200 时越界 Range 原样转发、**上游说什么就是什么**
            # （189 的 CDN 对 `bytes=999-` 回 500，koofr 的回 200，坚果云的
            # 回 416 —— Go 的 `RequestHttp` 同样是把 4xx/5xx 转成
            # `HttpStatusCodeError` 再展开成真状态码）。只记录不断言：
            # 能控制的是"照抄上游"，不是上游自己选的那个码。
            print("  ℹ️ 远程 Range 越界 → 第一跳 %d（照抄，不断言）" % st2)

        # 条件请求（只有本地分支）：带 If-None-Match 的 GET → 304
        st2, _, h2 = req(base, wp, headers=auth)
        etag = h2.get("Etag") or ""
        if is_local:
            check("WebDAV GET 带 Etag", bool(etag), str(etag))
            if etag:
                st2, _, _ = req(base, wp, headers=dict(auth, **{"If-None-Match": etag}))
                check("WebDAV If-None-Match → 304", st2 == 304, "HTTP %d" % st2)

        # MOVE 到自己身上 → 403（此前当成 204 空操作）
        st2, _, _ = req(base, wp, method="MOVE",
                        headers=dict(auth, Destination=wp))
        check("WebDAV MOVE 自身 → 403", st2 == 403, "HTTP %d" % st2)

        st, txt, _ = req(base, "/dav" + d + "/sub/", method="MKCOL", headers=auth)
        check("WebDAV MKCOL", st in (201, 405), "HTTP %d" % st)

        # 清理：只删自己建的临时目录
        for n in ["w.txt"]:
            api(base, "/api/fs/remove", tok, {"dir": d, "names": [n]})
        if m in COPY_OK_MOUNTS:
            # copy 测试留下的 sub/a.txt（copy 失败时可能不在，忽略结果）
            api(base, "/api/fs/remove", tok, {"dir": d + "/sub", "names": ["a.txt"]})
        # 删掉空的 sub 目录。注意方向：remove 是从**父目录**里删条目，
        # 原来这里写 `{dir: d+"/sub", names: []}` 会被服务端 400
        # （"Empty file names"，对齐 Go 的 FsRemove），是条无效调用。
        st, j = api(base, "/api/fs/remove", tok, {"dir": d, "names": ["sub"]})
        if j.get("code") != 200:
            print("  (提示) 删 sub 目录未成功: %s" % j.get("message"))
        st, j = api(base, "/api/fs/remove", tok, {"dir": "/" + m, "names": [tag]})
        if j.get("code") == 200:
            check("清理临时目录 %s" % tag, True)
        elif m == "jianguo":
            # 坚果云禁止通过 API 删除根级目录（实测 403 AuthFailed），服务商
            # 规则，只能去 WEB 页面手动删。不是我们的缺陷，计为跳过。
            SKIP.append("清理临时目录 %s（坚果云根级目录 403，需 WEB 手动删）" % tag)
            print("  ⚠️ 跳过 %-46s %s（坚果云根级目录禁止 API 删除，需 WEB 手动删）"
                  % ("清理临时目录 %s" % tag, j.get("message", "")))
        else:
            check("清理临时目录 %s" % tag, False, str(j.get("message", "")))

    # ---- 5. 边界 / 健壮性 / 稳定性（家庭局域网部署的硬要求）----
    print("\n=== 5. 边界与稳定性 ===")

    # 5.0 /p/ 代理端点 + 签名过期专项（2026-10-17 补测）。
    # 之前 e2e 里 /p/ 是 0 覆盖；`verifySign` 的过期/非法分支也没有真机断言。
    proxy_and_sign_check(base, tok)


    # 5.1 未登录：家庭局域网里未授权的设备/脚本不能读任何东西
    #
    # ⚠ 业务错误码在 **JSON 的 code** 里，HTTP 状态恒为 200 —— Go 的
    # `common.ErrorResp` → `ErrorWithDataResp` 是 `c.JSON(200, Resp{Code: 401})`
    # （server/common/common.go:74-88）。2026-10-17 在生产 Go 实例上动态对照
    # 钉死；此前本实现按 REST 惯例回真状态码，属于未对齐。
    st, j = api(base, "/api/fs/list", None, {"path": "/quark"})
    check("未登录 fs/list 被拒", j.get("code") == 401, "code=%s" % j.get("code"))
    check("  HTTP 仍为 200（Go 信封）", st == 200, "HTTP %d" % st)
    st, j = api(base, "/api/admin/storage/list", None, {})
    check("未登录管理 API 被拒", j.get("code") == 401, "code=%s" % j.get("code"))
    check("  HTTP 仍为 200（Go 信封）", st == 200, "HTTP %d" % st)
    # 未注册的 /api 路径 ⇒ NoRoute ⇒ 200 + 前端 shell（不是 JSON 404）
    st, body, _ = req(base, "/api/no_such_endpoint", method="POST", raw=True)
    check("未注册 /api/* → 200 + SPA shell", st == 200 and b"<html" in body.lower(),
          "HTTP %d, %d 字节" % (st, len(body)))
    st, _, _ = req(base, "/api/no_such_endpoint", method="PUT", raw=True)
    check("未注册 /api/* 非 GET/POST → 405", st == 405, "HTTP %d" % st)

    # 5.2 路径参数：对齐 Go `utils.JoinBasePath`（pkg/utils/path.go:81-87）
    _, j = api(base, "/api/fs/list", tok, {"path": ""})
    check("空 path 当根（对齐 Go）", j.get("code") == 200, "code=%s" % j.get("code"))
    _, j = api(base, "/api/fs/get", tok, {"path": ""})
    check("fs/get 空 path 当根（对齐 Go）", j.get("code") == 200, "code=%s" % j.get("code"))
    st, j = api(base, "/api/fs/list", tok, {"path": "/quark/../../etc"})
    check("路径穿越 .. → 403", j.get("code") == 403, "code=%s" % j.get("code"))
    check("  403 也是 HTTP 200（Go 信封）", st == 200, "HTTP %d" % st)
    _, j = api(base, "/api/fs/get", tok, {"path": "/quark/__no_such_file__"})
    check("不存在的路径 → 404", j.get("code") == 404, "code=%s" % j.get("code"))

    # 5.3 输入健壮性：坏 JSON 不能把服务打崩（要 4xx，不是 200/5xx）
    st, body = post_raw(base, "/api/fs/list", b"{not json",
                        {"Authorization": "Bearer " + tok,
                         "Content-Type": "application/json"})
    try:
        code = json.loads(body).get("code")
    except Exception:
        code = st
    check("非法 JSON body → 4xx", isinstance(code, int) and 400 <= code < 500,
          "code=%s" % code)

    # 5.4 下载边界：对齐 Go `http.ServeContent`
    if target:
        _, j = api(base, "/api/fs/get", tok, {"path": target})
        d = j.get("data") or {}
        sign = d.get("sign") or ""
        dl = "/d" + target + ("?sign=" + sign if sign else "")
        auth_hdr = None if sign else tok
        st, _, _ = req(base, dl, token=auth_hdr, headers={"Range": "bytes=99999999-"}, raw=True)
        check("Range 越界 → 416", st == 416, "HTTP %d" % st)
        st, body_r, _ = req(base, dl, token=auth_hdr, headers={"Range": "bytes=abc"}, raw=True)
        # Go：非法 Range 头被忽略 → 退化成整份 200
        check("Range 非法格式 → 回落 200", st == 200, "HTTP %d" % st)
    # 目录不能当文件下载。注意顺序：`sign_all=true` 的部署里 `/d/` **先过 sign
    # 鉴权**（Go `middlewares/down.go` 的 Down 也是这个顺序），而目录的 sign 是
    # 空串 ⇒ 401；只有没开 sign_all 的部署才会走到后面的 400 "is a directory"。
    # 用户光猫上的真实配置是 sign_all=true，所以这里期望 401。
    st, _, _ = req(base, "/d/quark", token=tok, raw=True)
    check("下载目录（sign_all 部署 → 401 先于 400）", st in (401, 400), "HTTP %d" % st)

    # 5.5 并发：家里多台设备同时访问
    import threading
    conc = {}
    def _list(m):
        try:
            c = ls(base, tok, "/" + m)
            conc[m] = len(c) if c is not None else -1
        except Exception as e:
            conc[m] = "ERR:%s" % e
    ths = [threading.Thread(target=_list, args=(m,)) for m in mounts]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    bad = {k: v for k, v in conc.items() if not isinstance(v, int) or v < 0}
    check("%d 挂载点并发 list" % len(mounts), not bad, str(bad) if bad else "全部成功")

    print("\n=== 汇总 ===")
    print("通过 %d，失败 %d，跳过 %d" % (len(PASS), len(FAIL), len(SKIP)))
    for f in FAIL:
        print("  ❌ " + f)
    for s in SKIP:
        print("  ⚠️ " + s)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
