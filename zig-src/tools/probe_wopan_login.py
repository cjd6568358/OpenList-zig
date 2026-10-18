#!/usr/bin/env python3
"""WoPan `AppRefreshToken` 探针：复刻 Zig 驱动的请求，看上游到底回了什么。

真机现象（用户 2026-10-17）：refresh_token `ce51c4af-…` 挂载失败，
`error_msg=InvalidResponse`。这个错误有两个来源：
  1. `post()` 里 `rsp_code != 00000` → warn 后回 InvalidResponse；
  2. 响应体根本不是 JSON（HTML/空）→ json.parse 失败。
探针把两种情况的原文都打出来。

协议（对齐 drivers/wopan + wopan-sdk-go）：
  POST https://panservice.mail.wo.cn/api-user/dispatcher
  body = {"header":{"key":md5(key+resTime+reqSeq+channel+version) 小写hex,
                    "resTime":毫秒, "reqSeq":1e5+rand(0..8999),
                    "channel":"api-user", "version":"1.0"},
          "body":{"param": base64(AES-128-CBC(明文, key=clientSecret, IV=wNSOYIB1k1DjY5lA))}}
  明文 = {"refreshToken":"…","clientSecret":"XFmi9GS2hzk98jGX"}
  头：Origin/Referer = https://pan.wo.cn
"""
import base64
import hashlib
import json
import random
import time
import urllib.request

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.padding import PKCS7

CLIENT_SECRET = "XFmi9GS2hzk98jGX"
IV = b"wNSOYIB1k1DjY5lA"
CHANNEL = "api-user"
VERSION = "1.0"
URL = "https://panservice.mail.wo.cn/api-user/dispatcher"


def aes_cbc_encrypt(plain: bytes, key: bytes) -> str:
    padder = PKCS7(128).padder()
    padded = padder.update(plain) + padder.finalize()
    enc = Cipher(algorithms.AES(key), modes.CBC(IV)).encryptor()
    return base64.b64encode(enc.update(padded) + enc.finalize()).decode()


def decrypt_resp(param_b64: str) -> bytes:
    dec = Cipher(algorithms.AES(CLIENT_SECRET.encode()), modes.CBC(IV)).decryptor()
    padded = dec.update(base64.b64decode(param_b64)) + dec.finalize()
    unpadder = PKCS7(128).unpadder()
    return unpadder.update(padded) + unpadder.finalize()


def call(refresh_token: str, i: int):
    # —— 逐字段按 SDK 组装（header.key = md5(key+resTime+reqSeq+channel+version)）——
    res_time = str(int(time.time() * 1000))
    req_seq = str(int(1e5 + random.randint(0, 8998)))
    header_key = hashlib.md5((CLIENT_SECRET + res_time + req_seq + CHANNEL + VERSION).encode()).hexdigest()
    body = {
        "header": {"key": header_key, "resTime": res_time, "reqSeq": req_seq,
                   "channel": CHANNEL, "version": VERSION},
        "body": {"param": aes_cbc_encrypt(
            json.dumps({"refreshToken": refresh_token, "clientSecret": CLIENT_SECRET},
                       separators=(",", ":")).encode(),
            CLIENT_SECRET.encode())},
    }
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Origin", "https://pan.wo.cn")
    req.add_header("Referer", "https://pan.wo.cn/")
    req.add_header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                                 "(KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36 Edg/114.0.1823.37")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            print("[%d] HTTP %d 原文: %s" % (i, resp.status, raw[:400]))
            try:
                v = json.loads(raw)
            except Exception:
                return None
            param = (v.get("body") or {}).get("param")
            if param:
                try:
                    print("[%d] 解密: %s" % (i, decrypt_resp(param)[:400]))
                except Exception as e:
                    print("[%d] 解密失败: %s" % (i, e))
            return v
    except urllib.error.HTTPError as e:
        print("[%d] HTTP %d: %s" % (i, e.code, e.read()[:300]))
        return None


if __name__ == "__main__":
    import sys
    sys.path.insert(0, "tools")
    import deploy_device as d
    c = d.connect()
    cfg = json.loads(d.sh(c, "cat /tmp/olz/cfg.json"))
    c.close()
    rt = next(s for s in cfg["storages"] if s["mount_path"] == "/wo")["addition"]
    rt = json.loads(rt)["refresh_token"] if isinstance(rt, str) else rt.get("refresh_token", "")
    print("refresh_token 长度:", len(rt))
    for i in range(3):
        v = call(rt, i)
        if v and v.get("RSP_CODE") == "00000":
            print("成功")
            break
        time.sleep(1)
