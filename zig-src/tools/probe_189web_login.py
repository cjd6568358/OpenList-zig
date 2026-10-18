#!/usr/bin/env python3
"""189Cloud(web) 登录链路探针：复刻 Go drivers/189/login.go 的四步流程，
逐步打印 **每一步的 Set-Cookie（只打名字+域）与最终 API 是否认账**。

目的：真机 `tools/test_189web.py` 显示登录成功但 listFiles 报
`InvalidSessionKey`（HTTP 400）。要回答的问题是：**会话 cookie 是哪一步
发的、发在了哪个域上、API 域名拿不拿得到**。

只用标准库（RSA 用纯 Python 实现 PKCS1v15：解析 SPKI → n/e → pow）。
凭据从测试实例配置借（同 test_189web.py），**不打印**。
"""
import base64
import http.cookiejar
import json
import sys
import time
import urllib.parse
import urllib.request

sys.path.insert(0, "tools")
import deploy_device as d  # noqa: E402

UA = "Mozilla/5.0 (Macintosh; Apple macOS 26_1_0) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/142.0.0.0 OpenList/425.6.30"


def b64tohex(s: str) -> str:
    """Go help.go 的 b64tohex：base64 → 大整数 → 十六进制串。"""
    b64map = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    ret = ""
    i = 0
    while i < len(s):
        h1 = b64map.index(s[i]) if s[i] != "=" else 0
        h2 = b64map.index(s[i + 1]) if i + 1 < len(s) and s[i + 1] != "=" else 0
        h3 = b64map.index(s[i + 2]) if i + 2 < len(s) and s[i + 2] != "=" else 0
        h4 = b64map.index(s[i + 3]) if i + 3 < len(s) and s[i + 3] != "=" else 0
        bits12 = (h1 << 2) | (h2 >> 4)
        bits6 = ((h2 & 15) << 4) | (h3 >> 2)
        bits2 = ((h3 & 3) << 6) | h4
        ret += "%02x" % bits12
        if s[i + 2] != "=" if i + 2 < len(s) else False:
            ret += "%02x" % bits6
        if s[i + 3] != "=" if i + 3 < len(s) else False:
            ret += "%02x" % bits2
        i += 4
    return ret


def rsa_encode(data: bytes, j_rsakey: str) -> str:
    """Go RsaEncode：SPKI 公钥 + PKCS1v15 + base64 + b64tohex。"""
    der = base64.b64decode(j_rsakey)
    # SPKI: SEQ { SEQ{OID rsaEncryption, NULL}, BIT STRING{ SEQ{n,e} } }
    def rd(b, off):
        # returns (tag, header_len, content)
        tag = b[off]
        i = off + 1
        ln = b[i]
        i += 1
        if ln & 0x80:
            nbytes = ln & 0x7F
            ln = int.from_bytes(b[i:i + nbytes], "big")
            i += nbytes
        return tag, i + ln, b[i:i + ln]   # 返回**内容结束**的偏移，供跳到下一个元素

    t, i, content = rd(der, 0)                      # outer SEQUENCE
    t, i2, alg = rd(content, 0)                     # AlgorithmIdentifier
    t, i3, bitstr = rd(content, i2)                 # BIT STRING（i2 已是内容结束偏移）
    keybits = bitstr[1:]                            # 跳过 unused-bits 字节
    t, j, inner = rd(keybits, 0)                    # inner SEQUENCE
    t, k, n_b = rd(inner, 0)
    t, k2, e_b = rd(inner, k)
    n = int.from_bytes(n_b, "big")
    e = int.from_bytes(e_b, "big")
    klen = (n.bit_length() + 7) // 8
    ps = b"\xff" * (klen - len(data) - 3)
    m = b"\x00\x02" + ps + b"\x00" + data
    c = pow(int.from_bytes(m, "big"), e, n)
    ct = c.to_bytes(klen, "big")
    # Go 的 b64tohex 等价于"密文字节 → 十六进制"（base64→大整数→hex），直接用
    # bytes.hex() 等价且不再受 base64 padding 的影响。
    return ct.hex()


def main():
    # 凭据只在内存
    c = d.connect()
    cfg = json.loads(d.sh(c, "cat /tmp/olz/cfg.json"))
    c.close()
    add = json.loads(next(s for s in cfg["storages"] if s["mount_path"] == "/ecloud_self")["addition"])
    user, pwd = add["username"].encode(), add["password"].encode()

    jar = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    op.addheaders = [("User-Agent", UA)]

    def show(tag):
        names = {}
        for ck in jar:
            names.setdefault(ck.domain, []).append(ck.name)
        print("%-14s cookies: %s" % (tag, {k: v for k, v in sorted(names.items())}))

    # 1) loginUrl.action —— 跟随重定向（与 resty 一致）
    url = "https://cloud.189.cn/api/portal/loginUrl.action?redirectURL=https%3A%2F%2Fcloud.189.cn%2Fmain.action"
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    hop, cur = 0, url
    while hop < 10:
        op2 = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect())
        op2.addheaders = [("User-Agent", UA)]
        try:
            r = op2.open(cur, timeout=30)
            break
        except urllib.error.HTTPError as e:
            if e.code not in (301, 302, 303, 307, 308):
                print("step1: HTTP", e.code)
                break
            loc = e.headers.get("Location")
            cur = urllib.parse.urljoin(cur, loc)
            show("step1 hop%d" % hop)
        hop += 1
    print("step1 最终 URL:", cur[:110])
    show("step1 末")

    q = urllib.parse.urlparse(cur).query
    lt = urllib.parse.parse_qs(q).get("lt", [""])[0]
    reqid = urllib.parse.parse_qs(q).get("reqId", [""])[0]
    appid = urllib.parse.parse_qs(q).get("appId", [""])[0]
    print("lt=%s reqId=%s appId=%s" % (lt[:8] + "..", reqid[:8] + "..", appid))

    hdrs = {"lt": lt, "reqid": reqid, "referer": cur, "origin": "https://open.e.189.cn"}

    def form(url_, data):
        body = urllib.parse.urlencode(data).encode()
        req = urllib.request.Request(url_, data=body, method="POST")
        for k, v in hdrs.items():
            req.add_header(k, v)
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
        req.add_header("Accept", "application/json;charset=UTF-8")
        with op.open(req, timeout=30) as resp:
            return resp.status, resp.read().decode(errors="replace")

    st, body = form("https://open.e.189.cn/api/logbox/oauth2/appConf.do",
                    {"version": "2.0", "appKey": appid})
    conf = json.loads(body)
    print("appConf: result=%s accountType=%s" % (conf.get("result"), conf["data"].get("accountType")))
    show("appConf")

    st, body = form("https://open.e.189.cn/api/logbox/config/encryptConf.do", {"appId": appid})
    enc = json.loads(body)
    pre, pubkey = enc["data"]["pre"], enc["data"]["pubKey"]
    print("encryptConf: pre=%s.. pubKey=%d 字符" % (pre[:6], len(pubkey)))
    show("encryptConf")

    login_data = {
        "version": "v2.0", "apToken": "", "appKey": appid,
        "accountType": conf["data"]["accountType"],
        "userName": pre + rsa_encode(user, pubkey),
        "epd": pre + rsa_encode(pwd, pubkey),
        "captchaType": "", "validateCode": "", "smsValidateCode": "", "captchaToken": "",
        "returnUrl": conf["data"]["returnUrl"], "mailSuffix": conf["data"]["mailSuffix"],
        "dynamicCheck": "FALSE", "clientType": str(conf["data"]["clientType"]),
        "cb_SaveName": "3", "isOauth2": str(conf["data"]["isOauth2"]).lower(),
        "state": "", "paramId": conf["data"]["paramId"],
    }
    st, body = form("https://open.e.189.cn/api/logbox/oauth2/loginSubmit.do", login_data)
    lr = json.loads(body)
    print("loginSubmit: result=%s msg=%s" % (lr.get("result"), str(lr.get("msg"))[:60]))
    print("loginSubmit 全文:", body[:900].replace(chr(10)," "))
    show("loginSubmit")

    # 5) API：cloud.189.cn 的 listFiles（与 Go/Zig 同一 URL）
    api = ("https://cloud.189.cn/api/open/file/listFiles.action?pageSize=60&pageNum=1"
           "&mediaType=0&folderId=-11&iconOption=5&orderBy=lastOpTime&descending=true"
           "&noCache=0.12345678901234567")
    req = urllib.request.Request(api)
    req.add_header("Accept", "application/json;charset=UTF-8")
    try:
        with op.open(req, timeout=30) as resp:
            print("listFiles: HTTP", resp.status, resp.read()[:160])
    except urllib.error.HTTPError as e:
        print("listFiles: HTTP", e.code, e.read()[:200])
    show("after-list")

    # 6) **关键实验**：登录成功后再走一次 loginUrl.action —— SSO 回跳应该
    #    会把会话种到 cloud.189.cn 域上（cookieUserSession）。这就是
    #    "loginSubmit 只在 e.189.cn 种 cookie，而 API 在 cloud.189.cn"缺的那环。
    # 6a) **GET toUrl** —— loginSubmit 的响应里就有它（callbackUnify.action），
    #     这是把会话种到 cloud.189.cn 的那一步。老版 Go 登录（util.go 注释里）
    #     有这一步，新版 login.go 把它弄丢了。
    tourl = lr.get("toUrl") or ""
    print("--- GET toUrl:", tourl[:90], "---")
    if tourl:
        cur3 = tourl
        hop = 0
        while hop < 10:
            op4 = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect())
            op4.addheaders = [("User-Agent", UA)]
            try:
                r4 = op4.open(cur3, timeout=30)
                print("  toUrl 链终点 200:", cur3[:90])
                break
            except urllib.error.HTTPError as e:
                if e.code not in (301, 302, 303, 307, 308):
                    print("  toUrl 终点 HTTP", e.code, cur3[:90])
                    break
                cur3 = urllib.parse.urljoin(cur3, e.headers.get("Location"))
            hop += 1
        show("toUrl 后")
        try:
            with op.open(urllib.request.Request(api, headers={"Accept": "application/json;charset=UTF-8"}),
                         timeout=30) as resp:
                print("listFiles(toUrl 后): HTTP", resp.status, resp.read()[:200])
        except urllib.error.HTTPError as e:
            print("listFiles(toUrl 后): HTTP", e.code, e.read()[:200])

    # 6b) 对照：登录后重走 loginUrl.action（SSO 回跳）
    cur2 = url
    hop = 0
    while hop < 10:
        op3 = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect())
        op3.addheaders = [("User-Agent", UA)]
        try:
            r3 = op3.open(cur2, timeout=30)
            print("  最终 200:", cur2[:90])
            break
        except urllib.error.HTTPError as e:
            if e.code not in (301, 302, 303, 307, 308):
                print("  终点 HTTP", e.code, cur2[:90])
                break
            cur2 = urllib.parse.urljoin(cur2, e.headers.get("Location"))
        hop += 1
    show("SSO 回跳后")
    try:
        with op.open(urllib.request.Request(api, headers={"Accept": "application/json;charset=UTF-8"}),
                     timeout=30) as resp:
            print("listFiles(再试): HTTP", resp.status, resp.read()[:200])
    except urllib.error.HTTPError as e:
        print("listFiles(再试): HTTP", e.code, e.read()[:200])
    show("最终")

    # 7) 会话稳定性：连续打 listFiles，看会不会中途变 HTML（WAF/会话失效）。
    #    真机现象：跑一轮 e2e 后 listFiles 恒回 HTML，驱动侧毫无线索。
    print("--- 连续 25 次 listFiles ---")
    import random as _rnd
    ok = 0
    for i in range(25):
        try:
            with op.open(urllib.request.Request(
                    api.replace("noCache=0.12345678901234567", "noCache=%.17g" % _rnd.random()),
                    headers={"Accept": "application/json;charset=UTF-8"}), timeout=30) as resp:
                body = resp.read()
                ok += 1
                print(" ", i, "HTTP", resp.status, "json" if b"res_code" in body[:60] else body[:60])
        except urllib.error.HTTPError as e:
            body = e.read()
            if body[:1] == b"<":
                print(" ", i, "HTTP", e.code, "HTML:", body[:260])
                break
            print(" ", i, "HTTP", e.code, body[:80])
        time.sleep(0.3)
    print("成功 %d/25" % ok)


if __name__ == "__main__":
    main()
