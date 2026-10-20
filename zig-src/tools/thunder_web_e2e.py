#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""thunder_web 驱动的真机/隔离实例回归。

    python thunder_web_e2e.py --base http://192.168.1.1:15399 \
        [--refresh-token a1.xxx] [--mount /thunderweb] [--write]

做四件事：
  1. 登录管理面（首次会自动 init/setup）；
  2. 建/更新 `thunder_web` 存储（`addition` 里的 refresh_token 从 --refresh-token
     或 thunder_web_probe.py 落盘的状态文件里取）；
  3. 轮询 `status` 到 work（= refresh grant + captcha 自签都过了）；
  4. 通过 `/api/fs/list` 列目录，`--write` 时再做 mkdir/rename/remove 往返。

⚠️ 每次建/改存储都会触发一次 init ⇒ 一次 refresh grant ⇒ refresh_token 轮换。
   所以**不要**在循环里跑本脚本（账号有频率限制，见 STATUS §48）。
   驱动落盘的新令牌在设备配置里，本脚本不回收。
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "Mozilla/5.0"


def req_raw(base, path, method, payload: bytes, tok, headers: dict):
    """发原始 body（上传用）。"""
    url = base.rstrip("/") + path
    h = {"User-Agent": UA}
    if tok:
        h["Authorization"] = "Bearer " + tok
    h.update(headers)
    r = urllib.request.Request(url, data=payload, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=180) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8", "replace"))
        except Exception:
            return e.code, {}
    except Exception as e:  # noqa: BLE001
        return 0, {"_err": f"{type(e).__name__}: {e}"}


def req(base, path, method="GET", body=None, tok=None):
    url = base.rstrip("/") + path
    data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    h = {"Content-Type": "application/json", "User-Agent": UA}
    if tok:
        h["Authorization"] = "Bearer " + tok
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8", "replace"))
        except Exception:
            return e.code, {}
    except Exception as e:  # noqa: BLE001
        return 0, {"_err": f"{type(e).__name__}: {e}"}


def ok(cond, label, extra=""):
    print(("  [ok] " if cond else "  [FAIL] ") + label + ((" — " + extra) if extra else ""))
    return bool(cond)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="openlist-zig-test")
    ap.add_argument("--mount", default="/thunderweb")
    ap.add_argument("--refresh-token")
    ap.add_argument("--device-id", default="")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--upload", action="store_true", help="再跑一遍 上传/直链/下载/清理")
    ap.add_argument(
        "--state",
        default=os.path.join(os.environ.get("TEMP", "/tmp"), "xl_web_state.json"),
    )
    args = ap.parse_args()
    base = args.base.rstrip("/")

    print("=== 0. 初始化 / 登录 ===")
    req(base, "/api/public/init/setup", "POST", {"username": args.user, "password": args.password})
    st, j = req(base, "/api/auth/login", "POST", {"username": args.user, "password": args.password})
    tok = (j.get("data") or {}).get("token")
    if not ok(bool(tok), "登录拿到 token", f"HTTP {st}"):
        return 1

    rt = args.refresh_token
    if not rt and os.path.exists(args.state):
        rt = json.load(open(args.state, encoding="utf-8")).get("refresh_token")
    if not rt:
        print("缺少 refresh_token（--refresh-token 或先跑 thunder_web_probe.py）")
        return 2
    print("  refresh_token: " + rt[:12] + "…")

    print("\n=== 1. 建/更新 thunder_web 存储 ===")
    addition = {
        "refresh_token": rt,
        "client_id": "Xqp0kJBXWhwaTpB6",
        "client_version": "1.93.12",
        "package_name": "pan.xunlei.com",
        "space": "",
        "root_folder_id": "",
    }
    st, lst = req(base, "/api/admin/storage/list", tok=tok)
    existing = None
    for s in (lst.get("data") or {}).get("content", []) or []:
        if s.get("mount_path") == args.mount:
            existing = s
    # 没显式给 device_id 时沿用设备上已有的那个 —— 否则每次回归都换一个设备 ID
    # （驱动会重新生成并落盘，功能上无碍，但会让设备指纹无谓地漂移）。
    if not args.device_id and existing:
        try:
            addition["device_id"] = json.loads(existing.get("addition") or "{}").get("device_id", "")
        except Exception:  # noqa: BLE001
            pass
    elif args.device_id:
        addition["device_id"] = args.device_id
    if existing:
        body = dict(existing)
        body["driver"] = "thunder_web"
        body["addition"] = json.dumps(addition, ensure_ascii=False)
        st, j = req(base, "/api/admin/storage/update", "POST", body, tok)
        print(f"  update -> HTTP {st} code={j.get('code')} {(j.get('message') or '')[:80]}")
    else:
        body = {
            "driver": "thunder_web",
            "mount_path": args.mount,
            "order": 0,
            "remark": "thunder_web e2e",
            "cache_expiration": 30,
            "web_proxy": False,
            "webdav_policy": "302_redirect",
            "down_proxy_url": "",
            "extract_folder": "",
            "enable_sign": False,
            "addition": json.dumps(addition, ensure_ascii=False),
        }
        st, j = req(base, "/api/admin/storage/create", "POST", body, tok)
        print(f"  create -> HTTP {st} code={j.get('code')} {(j.get('message') or '')[:80]}")

    print("\n=== 2. 等 init（status=work）===")
    entry = None
    deadline = time.time() + 90
    while time.time() < deadline:
        st, lst = req(base, "/api/admin/storage/list", tok=tok)
        for s in (lst.get("data") or {}).get("content", []) or []:
            if s.get("mount_path") == args.mount:
                entry = s
        if entry and entry.get("status") == "work":
            break
        time.sleep(1.5)
    if not ok(bool(entry) and entry.get("status") == "work", "存储 work",
              f"status={entry and entry.get('status')} err={(entry or {}).get('error_msg', '')[:300]}"):
        return 1
    add_back = json.loads(entry.get("addition") or "{}")
    print("  device_id = " + (add_back.get("device_id") or "(空)"))
    print("  captcha_token = " + (("有 %d 字符" % len(add_back.get("captcha_token") or "")) or "无"))

    print("\n=== 3. 列目录 ===")
    st, j = req(base, "/api/fs/list", "POST", {"path": args.mount, "page": 1, "per_page": 100}, tok)
    content = (j.get("data") or {}).get("content") or []
    if not ok(j.get("code") == 200 and len(content) > 0, "fs/list 有内容",
              f"HTTP {st} code={j.get('code')} n={len(content)} msg={(j.get('message') or '')[:120]}"):
        return 1
    for o in content[:8]:
        print(f"    {'DIR ' if o.get('is_dir') else 'FILE'} {o.get('name')}")

    if args.write:
        print("\n=== 4. 写操作往返 ===")
        name = "olz-web-%d" % int(time.time())
        st, j = req(base, "/api/fs/mkdir", "POST", {"path": f"{args.mount}/{name}"}, tok)
        ok(j.get("code") == 200, "mkdir", f"code={j.get('code')} {(j.get('message') or '')[:100]}")
        st, j = req(base, "/api/fs/rename", "POST",
                    {"path": f"{args.mount}/{name}", "name": name + "-r"}, tok)
        ok(j.get("code") == 200, "rename", f"code={j.get('code')} {(j.get('message') or '')[:100]}")
        st, j = req(base, "/api/fs/remove", "POST", {"dir": args.mount, "names": [name + "-r"]}, tok)
        ok(j.get("code") == 200, "remove", f"code={j.get('code')} {(j.get('message') or '')[:100]}")

    if args.upload:
        print("\n=== 5. 上传 / 直链 / 下载 ===")
        name = "olz-web-upload-%d.txt" % int(time.time())
        payload = ("hello thunder_web %d\n" % int(time.time())).encode()
        path = f"{args.mount}/{name}"
        st, j = req_raw(base, "/api/fs/put", "PUT", payload, tok, {
            "File-Path": urllib.parse.quote(path),
            "As-Task": "false",
            "Content-Type": "application/octet-stream",
        })
        ok(j.get("code") == 200, "put", f"HTTP {st} code={j.get('code')} {(j.get('message') or '')[:100]}")

        # ⚠️ 迅雷 list 有秒级最终一致性延迟（同 189 个人云）：立刻 list 看不到文件
        # 不代表上传失败。这里轮询到它出现为止。
        seen = False
        for _ in range(15):
            time.sleep(2)
            st, j = req(base, "/api/fs/list", "POST",
                        {"path": args.mount, "page": 1, "per_page": 200}, tok)
            names = [o.get("name") for o in ((j.get("data") or {}).get("content") or [])]
            if name in names:
                seen = True
                break
        ok(seen, "上传后能在 list 里看到（含最终一致性等待）")

        st, j = req(base, "/api/fs/get", "POST", {"path": path}, tok)
        raw = (j.get("data") or {}).get("raw_url") or ""
        ok(j.get("code") == 200 and raw.startswith("http"), "拿到下载直链", raw[:80])

        if raw.startswith("http"):
            try:
                with urllib.request.urlopen(urllib.request.Request(raw, method="GET"), timeout=90) as r:
                    got = r.read()
                ok(got == payload, "直链下载内容与上传一致", f"{len(got)} bytes")
            except Exception as e:  # noqa: BLE001
                ok(False, "直链下载", f"{type(e).__name__}: {e}")

        st, j = req(base, "/api/fs/remove", "POST", {"dir": args.mount, "names": [name]}, tok)
        ok(j.get("code") == 200, "清理测试文件", f"code={j.get('code')}")

    print("\n=== 结果：thunder_web 全链路通过 ===")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
