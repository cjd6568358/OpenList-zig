#!/usr/bin/env python3
"""AppRefreshToken 变体矩阵：找出联通 H5 的 refreshToken 到底接受哪种刷新请求。

背景：H5(wocloud_ai) 会话存储里的 refreshToken 过 AppRefreshToken 恒 8005
「登录失败」，而同一会话的 accessToken 过 AppQueryUser 是 0000。
H5 自身没有刷新逻辑（SMS 重登），方法名风格混用（appLoginBySms /
LoginByMobileV2），所以把可能的变体都试一遍。
"""
import base64
import hashlib
import json
import random
import sys
import time
import urllib.request

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.padding import PKCS7

CLIENT_SECRET = "XFmi9GS2hzk98jGX"
IV = b"wNSOYIB1k1DjY5lA"
RT = "ce51c4af-8bd8-4cab-8475-ca7a32de659d"
AT = "6f400b21-0387-4901-ba4c-8f5ba7dded20"
CID = "1001000021"


def aes_cbc(plain: bytes, key: bytes, encrypt: bool) -> bytes:
    if encrypt:
        p = PKCS7(128).padder()
        data = p.update(plain) + p.finalize()
        e = Cipher(algorithms.AES(key), modes.CBC(IV)).encryptor()
        return e.update(data) + e.finalize()
    d = Cipher(algorithms.AES(key), modes.CBC(IV)).decryptor()
    padded = d.update(base64.b64decode(plain)) + d.finalize()
    u = PKCS7(128).unpadder()
    return u.update(padded) + u.finalize()


def call(channel: str, key: str, param_obj: dict, aes_key: bytes):
    res_time = str(int(time.time() * 1000))
    req_seq = str(int(1e5 + random.randint(0, 8998)))
    sign = hashlib.md5((key + res_time + req_seq + channel).encode()).hexdigest()
    body = {
        "header": {"key": key, "resTime": res_time, "reqSeq": req_seq,
                   "channel": channel, "sign": sign, "version": ""},
        "body": {"clientId": CID, "secret": True,
                 "param": base64.b64encode(aes_cbc(
                     json.dumps(param_obj, separators=(",", ":")).encode(),
                     aes_key, True)).decode()},
    }
    req = urllib.request.Request(
        "https://panservice.mail.wo.cn/%s/dispatcher" % channel,
        data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Origin", "https://pan.wo.cn")
    req.add_header("Referer", "https://pan.wo.cn/")
    req.add_header("Accesstoken", AT)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
    except Exception as e:
        return None, str(e)
    try:
        v = json.loads(raw)
    except Exception:
        return None, raw[:120]
    rsp = v.get("RSP") or {}
    out = None
    data = rsp.get("DATA")
    if isinstance(data, str) and len(data) > 2:
        for k in (CLIENT_SECRET.encode(), aes_key):
            try:
                out = aes_cbc(data.encode(), k, False)
                break
            except Exception:
                continue
    return rsp.get("RSP_CODE"), "%s | 解密: %s" % (rsp.get("RSP_DESC"), (out or b"")[:120])


if __name__ == "__main__":
    cs = CLIENT_SECRET.encode()
    at16 = AT[:16].encode()
    variants = [
        ("原样 AppRefreshToken", "api-user", "AppRefreshToken",
         {"refreshToken": RT, "clientSecret": CLIENT_SECRET}, cs),
        ("param 内加 clientId", "api-user", "AppRefreshToken",
         {"refreshToken": RT, "clientSecret": CLIENT_SECRET, "clientId": CID}, cs),
        ("param 内加 accessToken", "api-user", "AppRefreshToken",
         {"refreshToken": RT, "clientSecret": CLIENT_SECRET, "accessToken": AT}, cs),
        ("camelCase refreshToken 方法", "api-user", "refreshToken",
         {"refreshToken": RT, "clientSecret": CLIENT_SECRET}, cs),
        ("RefreshTokenV2", "api-user", "RefreshTokenV2",
         {"refreshToken": RT, "clientSecret": CLIENT_SECRET}, cs),
        ("AES key=AT[:16]", "api-user", "AppRefreshToken",
         {"refreshToken": RT, "clientSecret": CLIENT_SECRET}, at16),
        ("wohome 通道", "wohome", "AppRefreshToken",
         {"refreshToken": RT, "clientSecret": CLIENT_SECRET}, cs),
    ]
    for name, ch, key, param, aes_key in variants:
        code, msg = call(ch, key, param, aes_key)
        print("%-24s -> %s | %s" % (name, code, str(msg)[:110]))
        time.sleep(0.5)
