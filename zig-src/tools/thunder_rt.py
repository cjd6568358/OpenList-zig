"""在打包机实例上建一个 ThunderExpert（login_type=user）存储，等 init 成功后
从 config.json 里读回它**自动持久化**的 refresh_token。

原理：驱动在 expert 变体下会把轮换后的 refresh_token 写回 addition（对齐 Go
`ThunderExpert.SetTokenResp`），所以只要登录成功一次就能拿到长期令牌；
而 refresh_token 登录走 `/v1/auth/token`，**不过验证码**，适合 IP 被风控的设备。

    XL_USER=... XL_PASS=... python3 get_rt.py
"""
import json
import os
import sys
import time

sys.path.insert(0, "/tmp/olz-thunder")
import probe  # noqa: E402

http = probe.http
DIR = probe.DIR
CFG = probe.CFG

probe.start()
st, j = http("POST", "/api/auth/login", {"username": "admin", "password": probe.ADMIN_PWD})
tok = (j.get("data") or {}).get("token")
assert tok, j

# 等挂载发布
for _ in range(90):
    st, j = http("POST", "/api/fs/list", {"path": "/"}, token=tok)
    if "thunder" in [o["name"] for o in ((j.get("data") or {}).get("content") or [])]:
        break
    time.sleep(1)

# 删掉旧的 /thx
st, j = http("GET", "/api/admin/storage/list", token=tok)
for s in (j.get("data") or {}).get("content", []) or []:
    if s.get("mount_path") == "/thx":
        http("POST", "/api/admin/storage/delete?id=%d" % s["id"], token=tok)

ck = open(DIR + "/creditkey.txt").read().strip()
add = {
    "login_type": "user",
    "sign_type": "algorithms",
    "username": probe.USERNAME,
    "password": probe.PASSWORD,
    "credit_key": ck,
    "device_id": "0a226604e32c4d2534c25db22fcc62b0",
}
st, j = http("POST", "/api/admin/storage/create", {
    "mount_path": "/thx", "driver": "ThunderExpert",
    "addition": json.dumps(add), "order": 1, "remark": "rt probe",
    "cache_expiration": 0, "web_proxy": False, "webdav_policy": "native_proxy", "disabled": False,
}, token=tok)
print("create ->", st, json.dumps(j, ensure_ascii=False)[:200])

state = None
for _ in range(60):
    st, j = http("GET", "/api/admin/storage/list", token=tok)
    for s in (j.get("data") or {}).get("content", []) or []:
        if s.get("mount_path") == "/thx":
            state = s
    if state and (state.get("status") == "work" or (state.get("error_msg") or "")):
        break
    time.sleep(1)
print("status:", (state or {}).get("status"), "|", ((state or {}).get("error_msg") or "")[:120])

# 从落盘的 config.json 读 refresh_token（驱动已写回）
cfg = json.load(open(CFG))
rt = ""
for s in cfg.get("storages", []):
    if s.get("mount_path") == "/thx":
        rt = json.loads(s["addition"]).get("refresh_token", "")
print("refresh_token len:", len(rt), rt[:24])
if rt:
    open(DIR + "/refresh_token.txt", "w").write(rt)

probe.stop()
sys.exit(0 if rt else 3)
