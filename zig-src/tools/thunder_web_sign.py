#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""迅雷网页版 pan.xunlei.com captcha_sign 参考实现 + 在线探针。

逆向结论（2026-10-20）见 docs/THUNDER_WEB_RE_2026-10-20.md。

签名 = "1." + MD5 链，链长 15，每轮把上一轮 32 位 hex 与固定盐拼接后再 MD5：
    h0 = clientId + clientVersion + host + deviceId + timestamp_ms
    hi = md5(h(i-1) + salt[i-1])      i = 1..15
    captcha_sign = "1." + h15

盐是构建期随机生成的（webpack 混淆产物），迅雷前端重新打包就会变。
失效时用 tools/thunder_web_sign.py --help 里的提取流程重抓。

用法：
    python thunder_web_sign.py golden              # 离线黄金对自检
    python thunder_web_sign.py sign --device-id X  # 打印当前时间戳对应的 sign
    python thunder_web_sign.py probe --device-id X # 打 captcha/init 验证服务端是否认
"""
from __future__ import annotations

import argparse
import hashlib
import json
import ssl
import sys
import time
import urllib.error
import urllib.request

# ---- pan.xunlei.com 网页端固定参数（来自 utils-initial 配置模块 32） ----
CLIENT_ID = "Xqp0kJBXWhwaTpB6"
CLIENT_VERSION = "1.93.12"
PACKAGE_NAME = "pan.xunlei.com"
HOST = "pan.xunlei.com"
ALG_VERSION = "1"

# ---- 15 个盐，按调用顺序（模块 22 的 pubIHrxR93yM8iZPRb1X2XWnkng0JpG8p3I 展开） ----
SALTS = [
    "QT5gqd1eSINZe+K",
    "9TafMwqVWgh45hLntDm6HLcOXE",
    "L0nOen58D2cCsOSRaRRYt1Mj+XTVM",
    "gu4CPVQhQU",
    "X/6jue5AUYt56MbqopFv",
    "EuBhpIhdLUh37zvuzrOA3t8HL2HBtlCw",
    "3LSRoSaxM6YKIbhtx7RxaBpf",
    "OOnBZYkw3kRrfGD8",
    "ytWf",
    "psUOt",
    "+0izM",
    "tF53Ovo+aqLG00zho+b",
    "OnrcYC9y8",
    "cv2tHyrFOPhJUFkk6KhecIHJDUKK",
    "NnkQ2lQy",
]

CAPTCHA_INIT_URL = "https://xluser-ssl.xunlei.com/v1/shield/captcha/init"

# 黄金对：浏览器 2026-10-20 18:19 实抓
GOLDEN = {
    "device_id": "28419a6fe0b7e47c355bbd8a95777fef",
    "timestamp": "1792491447693",
    "sign": "1.68270948a01b031830b45681bb1da55f",
}


def md5_hex(s: str) -> str:
    return hashlib.md5(s.encode("utf-8")).hexdigest()


def compute_sign(
    timestamp_ms: str,
    device_id: str,
    client_id: str = CLIENT_ID,
    client_version: str = CLIENT_VERSION,
    host: str = HOST,
) -> str:
    """复刻模块 1643 的 a()：返回 "1.<32hex>"。"""
    h = client_id + client_version + host + device_id + timestamp_ms
    for salt in SALTS:
        h = md5_hex(h + salt)
    return ALG_VERSION + "." + h


def cmd_golden(_args) -> int:
    assert md5_hex("hello") == "5d41402abc4b2a76b9719d911017c592", "md5 自检失败"
    got = compute_sign(GOLDEN["timestamp"], GOLDEN["device_id"])
    ok = got == GOLDEN["sign"]
    print("md5 自检      : OK")
    print("计算 sign     :", got)
    print("黄金对 sign   :", GOLDEN["sign"])
    print("结果          :", "MATCH" if ok else "MISMATCH")
    return 0 if ok else 1


def cmd_sign(args) -> int:
    ts = args.timestamp or str(int(time.time() * 1000))
    print(compute_sign(ts, args.device_id))
    print("timestamp =", ts, file=sys.stderr)
    return 0


def cmd_probe(args) -> int:
    ts = args.timestamp or str(int(time.time() * 1000))
    sign = compute_sign(ts, args.device_id)
    body = {
        "action": args.action,
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
            "user_id": args.user_id,
        },
    }
    data = json.dumps(body, separators=(",", ":")).encode()
    req = urllib.request.Request(
        CAPTCHA_INIT_URL,
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/plain, */*",
            "Origin": "https://pan.xunlei.com",
            "Referer": "https://pan.xunlei.com/",
            "User-Agent": args.ua,
            "x-client-id": CLIENT_ID,
            "x-client-version": CLIENT_VERSION,
            "x-device-id": args.device_id,
        },
    )
    ctx = ssl.create_default_context()
    print("sign =", sign, file=sys.stderr)
    try:
        with urllib.request.urlopen(req, timeout=20, context=ctx) as r:
            text = r.read().decode("utf-8", "replace")
            print("HTTP", r.status)
            print(text)
            try:
                j = json.loads(text)
            except Exception:
                return 0
            if j.get("captcha_token"):
                print("\n>>> 服务端认可签名，拿到 captcha_token")
                return 0
            print("\n>>> 未拿到 captcha_token，见上方错误体")
            return 1
    except urllib.error.HTTPError as e:
        print("HTTP", e.code)
        print(e.read().decode("utf-8", "replace"))
        return 1
    except Exception as e:  # noqa: BLE001
        print("请求失败:", type(e).__name__, e)
        return 1


def main() -> int:
    p = argparse.ArgumentParser(description="迅雷网页版 captcha_sign 参考实现")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("golden", help="离线黄金对自检").set_defaults(func=cmd_golden)

    ps = sub.add_parser("sign", help="打印指定时间戳的 sign")
    ps.add_argument("--device-id", required=True)
    ps.add_argument("--timestamp", help="毫秒时间戳，默认当前")
    ps.set_defaults(func=cmd_sign)

    pp = sub.add_parser("probe", help="POST captcha/init 验证服务端是否接受")
    pp.add_argument("--device-id", default=GOLDEN["device_id"])
    pp.add_argument("--timestamp", help="毫秒时间戳，默认当前")
    pp.add_argument("--user-id", default="832926495")
    pp.add_argument("--action", default="get:/drive/v1/about")
    pp.add_argument(
        "--ua",
        default=(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
        ),
    )
    pp.set_defaults(func=cmd_probe)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
