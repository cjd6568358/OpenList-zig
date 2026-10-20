#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""迅雷网页版全链路探针：refresh → captcha → files。

驱动（thunder_web）落地前的验证工具，也是排查线上问题的第一现场。

    python thunder_web_probe.py --refresh-token a1.xxx
    python thunder_web_probe.py            # 从 --state 文件里读上次轮换后的令牌

⚠️ refresh_token 是**一次性轮换**的：每跑一次 grant，旧的就作废。所以本脚本
会把新令牌写回 `--state`（默认 %TEMP%/xl_web_state.json），下次直接跑即可。

⚠️ 别在循环里反复跑：账号对登录/刷新有频率限制（见 STATUS §48）。
"""
from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from thunder_web_sign import CLIENT_ID, CLIENT_VERSION, PACKAGE_NAME, compute_sign  # noqa: E402

TOKEN_URL = "https://xluser-ssl.xunlei.com/v1/auth/token"
CAPTCHA_URL = "https://xluser-ssl.xunlei.com/v1/shield/captcha/init"
API = "https://api-pan.xunlei.com/drive/v1"
UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)
CTX = ssl.create_default_context()


def post(url: str, body: dict, headers: dict | None = None) -> tuple[int, dict | str]:
    data = json.dumps(body, separators=(",", ":")).encode()
    h = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/plain, */*",
        "Origin": "https://pan.xunlei.com",
        "Referer": "https://pan.xunlei.com/",
        "User-Agent": UA,
    }
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=data, method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=25, context=CTX) as r:
            text = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(text)
            except Exception:
                return r.status, text
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(text)
        except Exception:
            return e.code, text


def get(url: str, headers: dict) -> tuple[int, dict | str]:
    req = urllib.request.Request(url, method="GET", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=25, context=CTX) as r:
            text = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(text)
            except Exception:
                return r.status, text
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(text)
        except Exception:
            return e.code, text


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--refresh-token")
    p.add_argument("--device-id", default="28419a6fe0b7e47c355bbd8a95777fef")
    p.add_argument("--user-id", default="832926495")
    p.add_argument(
        "--state",
        default=os.path.join(os.environ.get("TEMP", "/tmp"), "xl_web_state.json"),
    )
    args = p.parse_args()

    rt = args.refresh_token
    if not rt and os.path.exists(args.state):
        rt = json.load(open(args.state, encoding="utf-8")).get("refresh_token")
        print(f"[state] 复用 {args.state} 里的 refresh_token")
    if not rt:
        print("缺少 refresh_token")
        return 2

    # ---- 1. refresh grant ----
    st, body = post(
        TOKEN_URL,
        {
            "client_id": CLIENT_ID,
            "client_secret": "",
            "grant_type": "refresh_token",
            "provider": "refresh_token",
            "refresh_token": rt,
        },
    )
    print(f"[1] refresh -> HTTP {st}")
    if st != 200 or not isinstance(body, dict) or not body.get("access_token"):
        print(json.dumps(body, ensure_ascii=False)[:600] if isinstance(body, dict) else str(body)[:600])
        return 1
    at = body["access_token"]
    new_rt = body.get("refresh_token", "")
    uid = body.get("user_id") or body.get("sub") or args.user_id
    print(f"    access_token {len(at)} chars, refresh_token {len(new_rt)} chars, user_id={uid}")
    if new_rt:
        json.dump({"refresh_token": new_rt, "user_id": uid}, open(args.state, "w", encoding="utf-8"))
        print(f"    [落盘] 新 refresh_token -> {args.state}")

    # ---- 2. captcha init ----
    ts = str(int(time.time() * 1000))
    sign = compute_sign(ts, args.device_id)
    st, body = post(
        CAPTCHA_URL,
        {
            "action": "get:/drive/v1/files",
            "client_id": CLIENT_ID,
            "device_id": args.device_id,
            "meta": {
                "username": "",
                "phone_number": "",
                "email": "",
                "package_name": PACKAGE_NAME,
                "client_version": CLIENT_VERSION,
                "captcha_sign": sign,
                "timestamp": ts,
                "user_id": str(uid),
            },
        },
    )
    print(f"[2] captcha -> HTTP {st}")
    ct = ""
    if isinstance(body, dict):
        ct = body.get("captcha_token", "")
        print(f"    captcha_token {len(ct)} chars, expires_in={body.get('expires_in')}")
    if not ct:
        print(json.dumps(body, ensure_ascii=False)[:600] if isinstance(body, dict) else str(body)[:600])
        return 1

    # ---- 3. 业务接口 ----
    h = {
        "Authorization": f"Bearer {at}",
        "X-Captcha-Token": ct,
        "X-Device-Id": args.device_id,
        "X-Client-Id": CLIENT_ID,
        "X-Client-Version": CLIENT_VERSION,
        "Accept": "application/json;charset=UTF-8",
        "Origin": "https://pan.xunlei.com",
        "Referer": "https://pan.xunlei.com/",
        "User-Agent": UA,
    }
    st, body = get(f"{API}/files?space=&limit=10&parent_id=", h)
    print(f"[3] files -> HTTP {st}")
    if isinstance(body, dict):
        files = body.get("files") or []
        print(f"    共 {len(files)} 项")
        for f in files[:10]:
            kind = "DIR " if f.get("kind") == "drive#folder" else "FILE"
            print(f"      {kind} {f.get('name')}  id={f.get('id')}")
        if not files:
            print("    " + json.dumps(body, ensure_ascii=False)[:400])
    else:
        print("    " + str(body)[:400])

    # ---- 4. about（另一个 action，验证签名按 action 变化仍有效）----
    ts = str(int(time.time() * 1000))
    st, body = post(
        CAPTCHA_URL,
        {
            "action": "get:/drive/v1/about",
            "client_id": CLIENT_ID,
            "device_id": args.device_id,
            "meta": {
                "package_name": PACKAGE_NAME,
                "client_version": CLIENT_VERSION,
                "captcha_sign": compute_sign(ts, args.device_id),
                "timestamp": ts,
                "user_id": str(uid),
            },
        },
    )
    ct2 = body.get("captcha_token", "") if isinstance(body, dict) else ""
    print(f"[4] captcha(about) -> HTTP {st}, token {len(ct2)} chars")
    h["X-Captcha-Token"] = ct2 or ct
    st, body = get(f"{API}/about", h)
    print(f"[5] about -> HTTP {st}")
    if isinstance(body, dict):
        print("    " + json.dumps(
            {k: body.get(k) for k in ("expires_at", "space_used", "space_total") if k in body},
            ensure_ascii=False,
        ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
