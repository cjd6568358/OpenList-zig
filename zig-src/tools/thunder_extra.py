"""补测三块：分片上传（>5MiB 走 S3 MPU）、配额、ThunderExpert 变体。

    python3 extra.py
"""
import hashlib
import json
import os
import sys
import time

sys.path.insert(0, "/tmp/olz-thunder")
import probe  # noqa: E402  （复用它的 http/start/stop/登录）

http = probe.http
DIR = probe.DIR
DEVICE_ID = "0a226604e32c4d2532"  # 占位，下面从配置里读真实值
CK = open(DIR + "/creditkey.txt").read().strip()

probe.start()
st, j = http("POST", "/api/auth/login", {"username": "admin", "password": probe.ADMIN_PWD})
tok = (j.get("data") or {}).get("token")
assert tok, j

# 挂载是**异步发布**的：进程先 listen、再 init 各存储，最后才 publish。
# 不等这一步，put/list 会拿到 "storage not found"（不是驱动问题）。
for _ in range(120):
    st, j = http("POST", "/api/fs/list", {"path": "/"}, token=tok)
    names = [o["name"] for o in ((j.get("data") or {}).get("content") or [])]
    if "thunder" in names:
        break
    time.sleep(1)
print("mount published:", "thunder" in names)


def api(path, body):
    return http("POST", path, body, token=tok)


def ls(path):
    st, j = api("/api/fs/list", {"path": path, "page": 1, "per_page": 100, "refresh": True})
    return (j.get("data") or {}).get("content") or []


# 已挂载的 /thunder 里 addition 的 device_id（就是已验证的那个设备）
st, j = http("GET", "/api/admin/storage/list", token=tok)
thunder = None
for s in (j.get("data") or {}).get("content", []) or []:
    if s.get("mount_path") == "/thunder":
        thunder = s
add = json.loads(thunder["addition"])
DEVICE_ID = add.get("device_id") or ""
print("verified device_id =", DEVICE_ID)

# ---------------------------------------------------------------- 1) MPU
size = 6 * 1024 * 1024 + 12345          # > 5 MiB，强制走分片
payload = bytes(((i * 7) + 11) & 0xFF for i in range(size))
name = "olz-mpu-%d.bin" % int(time.time())
print("\n=== 1) 分片上传 %.2f MiB ===" % (size / 1048576))
st, pj = http("POST", "/api/fs/put", raw=payload, token=tok,
              headers={"File-Path": "/thunder/" + name})
print("put ->", st, json.dumps(pj, ensure_ascii=False)[:160])

got = None
for _ in range(30):
    for o in ls("/thunder"):
        if o["name"] == name:
            got = o
            break
    if got:
        break
    time.sleep(1)
print("listed:", bool(got), "size=", got and got["size"], "hash=", got and (got.get("hash_info") or {}).get("gcid"))

if got:
    # 下载回来逐字节比对（验证 CompleteMultipartUpload 真的拼对了）
    import urllib.request
    st, j = api("/api/fs/get", {"path": "/thunder/" + name})
    sign = (j.get("data") or {}).get("sign") or ""
    url = probe.BASE + "/d/thunder/" + name + (("?sign=" + sign) if sign else "")
    req = urllib.request.Request(url)
    if not sign:
        req.add_header("Authorization", "Bearer " + tok)
    with urllib.request.urlopen(req, timeout=180) as r:
        back = r.read()
    print("downloaded %d bytes, equal=%s" % (len(back), back == payload))
    st, j = api("/api/fs/remove", {"dir": "/thunder", "names": [name]})
    print("cleanup ->", st, json.dumps(j, ensure_ascii=False)[:120])

# ------------------------------------------------------- 2) ThunderExpert
print("\n=== 2) ThunderExpert 变体 ===")
for s in (j2 for j2 in (http("GET", "/api/admin/storage/list", token=tok)[1].get("data") or {}).get("content", [])):
    if s.get("mount_path") == "/thx":
        http("POST", "/api/admin/storage/delete?id=%d" % s["id"], token=tok)

expert_add = {
    "login_type": "user",
    "sign_type": "algorithms",
    "username": probe.USERNAME,
    "password": probe.PASSWORD,
    "device_id": DEVICE_ID,
    "credit_key": CK,
}
st, j = api("/api/admin/storage/create", {
    "mount_path": "/thx", "driver": "ThunderExpert",
    "addition": json.dumps(expert_add), "order": 1, "remark": "expert probe",
    "cache_expiration": 0, "web_proxy": False, "webdav_policy": "native_proxy", "disabled": False,
})
print("create ->", st, json.dumps(j, ensure_ascii=False)[:220])

state = None
for _ in range(60):
    st, j = http("GET", "/api/admin/storage/list", token=tok)
    for s in (j.get("data") or {}).get("content", []) or []:
        if s.get("mount_path") == "/thx":
            state = s
    if state and (state.get("status") == "work" or (state.get("error_msg") or "")):
        break
    time.sleep(1)
print("expert status:", (state or {}).get("status"), "|", ((state or {}).get("error_msg") or "")[:160])

if (state or {}).get("status") == "work":
    items = ls("/thx")
    print("expert list:", len(items), [o["name"] for o in items][:5])
    # 清理：删掉存储（不删用户云盘里的任何东西）
    http("POST", "/api/admin/storage/delete?id=%d" % state["id"], token=tok)
    print("expert storage removed")

probe.stop()
