"""不走 Web UI，直接从管理 API 拿 /thunder 的 review 验证 JSON。

用途：/​@manage 前端卡住时，用这个脚本拿到"报错里的 {…}"，粘到
https://i.xunlei.com/xlcaptcha/android.html 的控制台执行 reviewCb({…})，
过验证后把 credit_key 写回（本脚本也能写）。

    python thunder_review.py show                      # 打印验证 JSON
    python thunder_review.py set <creditkey>           # 写回 credit_key 并重启该存储

默认打 192.168.1.1:15244，账号 admin / e2e-test-123456（环境变量可覆盖：
XL_ADMIN_USER / XL_ADMIN_PASS / XL_BASE）。
"""
import json
import os
import sys
import urllib.error
import urllib.request

BASE = os.environ.get("XL_BASE", "http://192.168.1.1:15244")
USER = os.environ.get("XL_ADMIN_USER", "admin")
PASS = os.environ.get("XL_ADMIN_PASS", "e2e-test-123456")


def call(path, body=None, token=None, method="GET"):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", token)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return json.loads(e.read().decode() or "{}")


def login():
    j = call("/api/auth/login", {"username": USER, "password": PASS}, method="POST")
    tok = (j.get("data") or {}).get("token")
    if not tok:
        raise SystemExit("login failed: %s" % j.get("message"))
    return tok


def find(tok):
    for s in (call("/api/admin/storage/list", token=tok).get("data") or {}).get("content", []):
        if s.get("mount_path") == "/thunder":
            return s
    raise SystemExit("no /thunder storage")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "show"
    tok = login()
    st = find(tok)
    print("storage: id=%s driver=%s status=%s disabled=%s" % (
        st["id"], st["driver"], st.get("status"), st.get("disabled")))
    print("config keys:", sorted(json.loads(st["addition"]).keys()))

    if cmd == "show":
        msg = st.get("error_msg") or ""
        i = msg.find("<code>{")
        if i < 0:
            print("error_msg 里没有 <code>{…}</code>：")
            print("  ", msg[:200])
            # 触发一次重新初始化，让驱动把当前挑战写进 error_msg
            print("\n触发重新初始化（update）…")
            j = call("/api/admin/storage/update", token_put(st, tok), method="POST")
            print("update ->", j.get("code"), j.get("message"))
            st = find(tok)
            msg = st.get("error_msg") or ""
            i = msg.find("<code>{")
        if i >= 0:
            raw = msg[i + len("<code>"):msg.find("</code>", i)]
        else:
            # 纯文本格式（2026-10-20 起）：JSON 直接内嵌在 error_msg 里
            i = msg.find("{")
            if i < 0:
                print("status:", st.get("status"), msg[:200])
                return
            raw = msg[i:msg.rfind("}") + 1]
        try:
            d = json.loads(raw.replace("\\n", "\n"))
        except Exception as e:
            print("JSON 解析失败:", e)
            print(raw[:300])
            return
        one = json.dumps(d, ensure_ascii=False)
        print("\n=== 整行复制到浏览器控制台执行（%d 字符，别改任何内容）===" % len(one))
        print("reviewCb(" + one + ")")
        print("\n=== 分卷版（人眼看）===")
        print(json.dumps(d, ensure_ascii=False, indent=2))

    elif cmd == "set":
        ck = sys.argv[2]
        add = json.loads(st["addition"])
        add["credit_key"] = ck
        body = dict(st)
        body["addition"] = json.dumps(add, ensure_ascii=False)
        j = call("/api/admin/storage/update", body, token=tok, method="POST")
        print("update ->", j.get("code"), j.get("message"))
        st2 = find(tok)
        print("new status:", st2.get("status"), (st2.get("error_msg") or "")[:120])
        if st2.get("status") == "work":
            j = call("/api/fs/list", {"path": "/thunder", "page": 1, "per_page": 20, "refresh": True},
                     token=tok, method="POST")
            print("list ->", j.get("code"), [o["name"] for o in ((j.get("data") or {}).get("content") or [])])


def token_put(st, tok):
    # 原样提交一次（不改为 update，用 create 的等价物：直接 PUT 同 id 的完整记录）
    body = dict(st)
    body.pop("id", None)
    body.pop("mount_path", None)
    body.pop("driver", None)
    body["mount_path"] = "/thunder"
    body["driver"] = "Thunder"
    return body


if __name__ == "__main__":
    main()
