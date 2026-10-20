"""迅雷云盘驱动的真机探针：起一个独立实例 → 建存储 → 打印 init 结果。

在打包机（10.0.0.4）上跑，端口/配置目录都与构建用的目录隔离，不碰任何生产实例。

    export XL_USER=13800138000 XL_PASS=****        # 裸手机号，不要带 +86
    python3 /tmp/olz-thunder/probe.py [--keep] [--e2e] [--cleanup]

`--e2e`     额外种一个小文件并跑 tools/e2e_test.py（--mounts thunder --write-cloud）
`--cleanup` 清掉历次探针留在账号根目录的 olz-* 测试文件
`XL_WEB_PROXY=1` 建存储时打开「Web 代理」（/d/ 由服务端回源，Range 才能验）

退出码：0 = 存储 work；2 = init 失败（打印 error_msg 原文）；1 = 其它错误。

⚠ 首次登录必然 `review_panel`（新设备）：把 error_msg 里 `<code>{...}</code>`
的 JSON 拿去 https://i.xunlei.com/xlcaptcha/android.html 的控制台执行
`reviewCb({...})`，过短信验证后拿到的 `creditkey` 写进 `creditkey.txt` 再重跑。
"""
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:15944"
PORT = 15944
DIR = "/tmp/olz-thunder"
CFG = DIR + "/config.json"
BIN = "/tmp/olz-build/zig-out/bin/openlist"
ADMIN_PWD = "thunder-probe-2026"
# ⚠ 凭据**不入库**：跑之前 export XL_USER / XL_PASS（迅雷账号：裸手机号，不带 +86）
USERNAME = os.environ.get("XL_USER", "")
PASSWORD = os.environ.get("XL_PASS", "")
if not USERNAME or not PASSWORD:
    raise SystemExit("set XL_USER and XL_PASS (bare phone number, no +86)")
ADDITION = os.environ.get("XL_ADDITION", "")  # 覆盖 addition JSON
MOUNT = os.environ.get("XL_MOUNT", "/thunder")

_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def http(method, path, body=None, token=None, raw=None, headers=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    r = urllib.request.Request(BASE + path, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", token)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    try:
        with _OPENER.open(r, timeout=180) as resp:
            txt = resp.read().decode(errors="replace")
            try:
                return resp.status, json.loads(txt or "{}")
            except Exception:
                return resp.status, {"raw": txt}
    except urllib.error.HTTPError as e:
        txt = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(txt or "{}")
        except Exception:
            return e.code, {"raw": txt}


def stop():
    # 只按 pidfile 杀（绝不按命令行子串 —— 打包机上还有一个 Go 版实例在跑）
    pidf = DIR + "/server.pid"
    try:
        with open(pidf) as f:
            pid = int(f.read().strip())
        os.kill(pid, 15)
        for _ in range(40):
            try:
                os.kill(pid, 0)
            except OSError:
                break
            time.sleep(0.1)
    except Exception:
        pass
    try:
        os.unlink(pidf)
    except Exception:
        pass


def ensure_config():
    """生成默认配置并把端口改成独立端口（5244 被打包机上的 Go 实例占着）。"""
    if not os.path.exists(CFG):
        subprocess.run([BIN, "admin", "info", "-c", CFG],
                       capture_output=True, text=True)
    with open(CFG) as f:
        cfg = json.load(f)
    cfg.setdefault("scheme", {})["http_port"] = PORT
    with open(CFG, "w") as f:
        json.dump(cfg, f, indent=2)
    return cfg


def start():
    stop()
    ensure_config()
    log = open(DIR + "/server.log", "ab")
    env = dict(os.environ)
    # 首次启动建管理员（对齐 Go initAdmin：没有 admin 时只看这个环境变量）
    env["OPENLIST_ADMIN_PASSWORD"] = ADMIN_PWD
    p = subprocess.Popen(
        [BIN, "server", "--config", CFG],
        stdout=log, stderr=log, stdin=subprocess.DEVNULL, env=env,
    )
    with open(DIR + "/server.pid", "w") as f:
        f.write(str(p.pid))
    for _ in range(120):
        try:
            st, _j = http("GET", "/api/public/settings")
            if st == 200:
                return
        except Exception:
            pass
        time.sleep(0.5)
    raise SystemExit("server did not come up; see " + DIR + "/server.log")


def main():
    keep = "--keep" in sys.argv
    os.makedirs(DIR, exist_ok=True)

    start()
    st, j = http("POST", "/api/auth/login", {"username": "admin", "password": ADMIN_PWD})
    tok = (j.get("data") or {}).get("token")
    if not tok:
        raise SystemExit("login failed: %s %s" % (st, j))

    # 已有的 /thunder 先删掉，保证每次都是全新的 init
    st, j = http("GET", "/api/admin/storage/list", token=tok)
    for s in (j.get("data") or {}).get("content", []) or []:
        if s.get("mount_path") == MOUNT:
            # 接口签名是 `POST /api/admin/storage/delete?id=N`（query，不是 body）
            st, dj = http("POST", "/api/admin/storage/delete?id=%d" % s["id"], token=tok)
            print("delete old ->", st, json.dumps(dj, ensure_ascii=False)[:200])

    addition = ADDITION or json.dumps({"username": USERNAME, "password": PASSWORD})
    # 如果放了 creditkey.txt（验证后拿到的信任密钥），自动带进 addition
    ck_file = DIR + "/creditkey.txt"
    if os.path.exists(ck_file) and not ADDITION:
        ck = open(ck_file).read().strip()
        if ck:
            addition = json.dumps({"username": USERNAME, "password": PASSWORD, "credit_key": ck})
            print("using credit_key from creditkey.txt (len=%d)" % len(ck))
    body = {
        "mount_path": os.environ.get("XL_MOUNT", "/thunder"),
        "driver": os.environ.get("XL_DRIVER", "Thunder"),
        "addition": addition,
        "order": 0,
        "remark": "thunder probe",
        "cache_expiration": 0,
        "web_proxy": os.environ.get("XL_WEB_PROXY") == "1",
        "webdav_policy": "native_proxy",
        "disabled": False,
    }
    st, j = http("POST", "/api/admin/storage/create", body, token=tok)
    print("create ->", st, json.dumps(j, ensure_ascii=False)[:600])

    # init 是异步的（后台线程），等状态收敛
    state = None
    for _ in range(90):
        st, j = http("GET", "/api/admin/storage/list", token=tok)
        for s in (j.get("data") or {}).get("content", []) or []:
            if s.get("mount_path") == MOUNT:
                state = s
        if state and state.get("status") == "work":
            break
        if state and (state.get("error_msg") or ""):
            break
        time.sleep(1)

    print("\n=== storage ===")
    print(json.dumps({k: v for k, v in (state or {}).items()
                      if k in ("id", "mount_path", "driver", "status", "disabled")},
                     ensure_ascii=False, indent=2))
    print("status  :", (state or {}).get("status"))
    print("error   :", (state or {}).get("error_msg") or (state or {}).get("status"))

    if (state or {}).get("status") != "work":
        # 直接打服务端日志尾部（驱动把上游错误写进了日志）
        print("\n=== server.log tail ===")
        print(subprocess.run(["tail", "-n", "25", DIR + "/server.log"],
                             capture_output=True, text=True).stdout)
        if not keep:
            stop()
        return 2

    st, j = http("POST", "/api/fs/list", {"path": MOUNT, "page": 1, "per_page": 20, "refresh": True}, token=tok)
    print("\n=== fs/list /thunder ===")
    print("http", st, "code", j.get("code"), "msg", j.get("message"))
    data = j.get("data") or {}
    print("total:", data.get("total"))
    for o in (data.get("content") or [])[:10]:
        print("  %-40s dir=%-5s size=%-10s hash=%s" % (
            o.get("name"), o.get("is_dir"), o.get("size"), (o.get("hash_info") or {}).get("gcid")))

    if "--cleanup" in sys.argv:
        # 清掉历次探针在账号根目录留下的测试文件（含上游自动改名的 `(N)`）
        st, j = http("POST", "/api/fs/list", {"path": MOUNT, "page": 1, "per_page": 100, "refresh": True}, token=tok)
        junk = [o["name"] for o in ((j.get("data") or {}).get("content") or [])
                if o["name"].startswith(("olz-seed", "olz-raw-probe"))]
        if junk:
            st, j = http("POST", "/api/fs/remove", {"dir": "/thunder", "names": junk}, token=tok)
            print("\ncleanup ->", st, json.dumps(j, ensure_ascii=False)[:200], junk)
        else:
            print("\ncleanup -> nothing to remove")

    if "--e2e" in sys.argv:
        # 种一个可下载的小文件：e2e 的「详情/下载/Range/WebDAV 读」要靠它，
        # 而账号根目录下只有空文件夹。名字带时间戳，避免上游把重名改成 `(1)`。
        seed = "olz-seed-%d.txt" % int(time.time())
        payload = b"openlist-zig thunder seed\n"
        st, pj = http("POST", "/api/fs/put", raw=payload, token=tok,
                      headers={"File-Path": "/thunder/" + seed})
        print("\nseed upload ->", st, json.dumps(pj, ensure_ascii=False)[:200])
        st, j = http("POST", "/api/fs/list", {"path": MOUNT, "page": 1, "per_page": 20, "refresh": True}, token=tok)
        names = [o["name"] for o in ((j.get("data") or {}).get("content") or [])]
        print("seed visible:", seed in names)

        print("\n=== e2e_test.py --mounts thunder --write-cloud ===", flush=True)
        r = subprocess.run(
            ["python3", DIR + "/e2e_test.py", BASE,
             "--user", "admin", "--password", ADMIN_PWD,
             "--mounts", "thunder", "--write-cloud"],
            capture_output=True, text=True)
        print(r.stdout[-8000:])
        if r.stderr.strip():
            print("--- stderr ---\n" + r.stderr[-2000:])

        # 清理：本次种子 + 历史残留
        st, j = http("POST", "/api/fs/list", {"path": MOUNT, "page": 1, "per_page": 100, "refresh": True}, token=tok)
        junk = [o["name"] for o in ((j.get("data") or {}).get("content") or [])
                if o["name"].startswith(("olz-seed", "olz-raw-probe"))]
        if junk:
            st, j = http("POST", "/api/fs/remove", {"dir": "/thunder", "names": junk}, token=tok)
            print("\nseed cleanup ->", st, json.dumps(j, ensure_ascii=False)[:160], junk)

    if not keep:
        stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
