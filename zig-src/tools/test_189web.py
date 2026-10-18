#!/usr/bin/env python3
"""用 189PC 存储里现成的账号，把 **189Cloud（web 驱动）** 真实挂起来跑全矩阵。

背景（用户 2026-10-17："补全剩下的4个驱动完整测试"）：
  * UC / 115 Cloud / WoPan 需要用户提供的凭据（Cookie / refresh_token），
    用户配置与 Go 备份里都没有 —— 只能等凭据；
  * **189Cloud(web) 不一样**：它要的就是 `username + password`（RSA 登录），
    而测试实例的 `/ecloud_self`（189CloudPC）配置里就有这套账密 —— 直接
    借用即可真测。

⚠ 凭据安全：账密只在内存里流转（SSH 读 cfg.json → 直接塞进创建请求），
  **任何输出都不得打印凭据**（STATUS §20 的管理响应同样带明文凭据）。

流程：创建存储（挂载点 /ecloud_web）→ 等 init → `tools/e2e_test.py --mounts
ecloud_web --write-cloud` 跑全操作矩阵 → 删除存储（恢复 10 挂载原状）。
"""
import json
import sys
import time
import urllib.request

sys.path.insert(0, "tools")
import deploy_device as d  # noqa: E402

BASE = "http://192.168.1.1:15399"
MOUNT = "ecloud_web"


def call(path, body=None, token=None, method=None, retries=4):
    data = json.dumps(body).encode() if body is not None else None
    h = {"Content-Type": "application/json"} if data else {}
    if token:
        h["Authorization"] = "Bearer " + token
    m = method or ("POST" if data else "GET")
    r = urllib.request.Request(BASE + path, data=data, headers=h, method=m)
    for i in range(1, retries + 1):
        try:
            with urllib.request.urlopen(r, timeout=90) as resp:
                return json.loads(resp.read() or b"{}")
        except (ConnectionError, TimeoutError, OSError):
            # easytier 隧道偶发 RST（STATUS §34），有界重试
            if i == retries:
                raise
            time.sleep(1.5)


def main():
    # 1) 从设备配置里借账密（不打印）
    c = d.connect()
    cfg = json.loads(d.sh(c, "cat /tmp/olz/cfg.json"))
    c.close()
    src = next(s for s in cfg["storages"] if s["mount_path"] == "/ecloud_self")
    add = json.loads(src["addition"])
    user, pwd = add["username"], add["password"]
    print("已从 /ecloud_self 配置借到账密（%s / %d 字符）" % (user[:3] + "***", len(pwd)))

    token = call("/api/auth/login", {"username": "admin", "password": "e2e-test-123456"})["data"]["token"]

    # 2) 清掉上次残留
    lst = call("/api/admin/storage", token=token, method="GET")["data"]["content"]
    for s in lst:
        if s["mount_path"] == "/" + MOUNT:
            call("/api/admin/storage/delete?id=%s" % s["id"], token=token, method="POST")
            print("已删除残留存储 id=%s" % s["id"])
            time.sleep(2)

    # 3) 创建（Go 语义：行先建，init 失败 ⇒ 200 信封 + code 500 + data.id）
    j = call("/api/admin/storage/create", method="POST", token=token, body={
        "mount_path": "/" + MOUNT, "driver": "189Cloud",
        "addition": json.dumps({"username": user, "password": pwd}, ensure_ascii=False),
    })
    print("create: code=%s msg=%s data=%s" % (j.get("code"), str(j.get("message"))[:70], j.get("data")))
    if j.get("code") != 200:
        print("!! 上游登录失败：", str(j.get("message"))[:200])
        print("   （这正是上一轮卡住的『二次验证』—— 需要用户在 189 侧完成一次验证）")
        return 1

    # 4) 等挂载发布，然后跑全操作矩阵
    for _ in range(20):
        lst = call("/api/admin/storage", token=token, method="GET")["data"]["content"]
        row = next((s for s in lst if s["mount_path"] == "/" + MOUNT), None)
        if row and row["status"] == "work":
            break
        time.sleep(2)
    print("存储状态:", row and row["status"], row and row.get("error_msg"))
    if not row or row["status"] != "work":
        return 1

    import subprocess
    cmd = [sys.executable, "tools/e2e_test.py", BASE, "--write-cloud", "--user", "admin",
           "--password", "e2e-test-123456", "--mounts", MOUNT]
    print("跑全操作矩阵:", " ".join(cmd[2:]))
    rc = subprocess.run(cmd).returncode

    # 5) 清理：删掉测试存储，恢复原 10 挂载
    lst = call("/api/admin/storage", token=token, method="GET")["data"]["content"]
    for s in lst:
        if s["mount_path"] == "/" + MOUNT:
            call("/api/admin/storage/delete?id=%s" % s["id"], token=token, method="POST")
            print("已删除测试存储（恢复原挂载集）")
    return rc


if __name__ == "__main__":
    sys.exit(main())
