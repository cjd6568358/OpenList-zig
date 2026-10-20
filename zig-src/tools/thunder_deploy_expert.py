"""把设备上的 /thunder 换成 ThunderExpert + login_type=refresh_token。

网页版（pan.xunlei.com）登录不受风控，但驱动用的是旧安卓 SDK 端点、必被风控拦。
网页会话里的 refresh_token 可以在驱动同一个 /v1/auth/token 上换令牌（不过风控），
所以把 storage 换成专家变体 + refresh_token 登录。驱动的 refresh 调用会自动把
轮换后的新 token 写回配置 ⇒ 装一次长期自持。

    python tools/thunder_deploy_expert.py <refresh_token>

流程：下载设备配置 → 改 /thunder 条目 → 上传 → 重启 → 管理 API 验证 → 更新本地留档。
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOLS = os.path.join(ROOT, "zig-src", "tools")
REMOTE = [sys.executable, os.path.join(TOOLS, "remote.py")]
DEV = ["192.168.1.1", "10022"]
CFG = "/opt/armbian/bin/openlist/config.zig.json"
ARCHIVE = os.path.join(ROOT, "server", "armbian", "bin", "openlist")
BASE = "http://192.168.1.1:15244"

CLIENT_ID = "Xqp0kJBXWhwaTpB6"   # 网页版 client_id：网页 refresh_token 只认它（安卓 cid 报 invalid_grant）
CLIENT_SECRET = ""
# 2026-10-20 实测结论（STATUS §48.6.8）：
#   * refresh grant：网页 refresh_token 只认网页 client_id；
#   * captcha：网页 client 的 captcha_sign 强制校验且算法未知 ⇒ 驱动无法自签；
#   * 网页 captcha token 只活 ~10 分钟，且与 device_id 绑定。
#   ⇒ 本脚本能把登录打通（status=work），但 fs/list 仍 502（captcha_invalid）。
DEVICE_ID = "0a226604e32c4d2534c25db22fcc62b0"


def sh(*args, **kw):
    return subprocess.run(list(args), capture_output=True, text=True, **kw)


def main():
    rt = sys.argv[1].strip()
    assert rt.startswith("a1."), "refresh_token 形如 a1.xxxx"

    # 1) 下载设备配置
    r = sh(*REMOTE, *DEV, "cat " + CFG)
    cfg = json.loads(r.stdout)
    ent = None
    for s in cfg["storages"]:
        if s.get("mount_path") == "/thunder":
            ent = s
    assert ent, "设备配置里没有 /thunder"
    old = json.loads(ent["addition"])

    add = {
        "login_type": "refresh_token",
        "refresh_token": rt,
        "username": "",
        "password": "",
        "captcha_token": "",
        "device_id": DEVICE_ID,
        "credit_key": old.get("credit_key", ""),
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "client_version": "8.31.0.9726",
        "package_name": "ANDROID-com.xunlei.downloadprovider",
        "user_agent": "",
        "down_user_agent": "",
        "algorithms": "",
        "sign_type": "algorithms",
        "space": "",
        "root_folder_id": "",
    }
    ent["driver"] = "ThunderExpert"
    ent["addition"] = json.dumps(add, ensure_ascii=False)
    ent["web_proxy"] = True
    local = os.path.join(os.environ.get("TEMP", "."), "config.zig.new.json")
    json.dump(cfg, open(local, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("config prepared: driver=ThunderExpert, storages=%d" % len(cfg["storages"]))

    # 2) 上传 + 备份旧配置 + 切换 + 重启
    sh(*REMOTE, *DEV, "--put", local, "opt/armbian/bin/openlist/config.zig.json.new", "666")
    r = sh(*REMOTE, *DEV,
           "cd /opt/armbian/bin/openlist && cp -f config.zig.json config.zig.json.bak-rt && "
           "mv -f config.zig.json.new config.zig.json && "
           "/bin/sh /opt/script/openlist_start.sh stop; sleep 2; "
           "/bin/sh /opt/script/openlist_start.sh; sleep 8; "
           "netstat -ltn | grep -c 15244")
    print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr[-200:])

    # 3) 管理 API 验证（refresh 登录本身不过风控，但仍等 init 收敛）
    def post(path, body=None, token=None):
        d = json.dumps(body).encode() if body is not None else None
        rq = urllib.request.Request(BASE + path, data=d, method="POST")
        rq.add_header("Content-Type", "application/json")
        if token:
            rq.add_header("Authorization", token)
        with urllib.request.urlopen(rq, timeout=90) as resp:
            return json.loads(resp.read().decode())

    j = post("/api/auth/login", {"username": "admin", "password": "e2e-test-123456"})
    tok = j["data"]["token"]
    state = None
    for _ in range(60):
        for s in (post("/api/admin/storage/list", None, tok).get("data") or {}).get("content", []):
            if s.get("mount_path") == "/thunder":
                state = s
        if state and (state.get("status") == "work" or (state.get("error_msg") or "")):
            break
        time.sleep(1)
    print("status:", (state or {}).get("status"), (state or {}).get("error_msg") or "")
    if (state or {}).get("status") != "work":
        return 2

    j = post("/api/fs/list", {"path": "/thunder", "page": 1, "per_page": 20, "refresh": True}, tok)
    print("fs/list ->", j.get("code"), [o["name"] for o in ((j.get("data") or {}).get("content") or [])])

    # 4) 更新本地留档（只留最新一份）
    os.makedirs(ARCHIVE, exist_ok=True)
    r = sh(*REMOTE, *DEV, "cat " + CFG)
    open(os.path.join(ARCHIVE, "config.zig.json"), "w", encoding="utf-8").write(r.stdout)
    print("archive updated:", os.path.join(ARCHIVE, "config.zig.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
