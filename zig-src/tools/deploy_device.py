#!/usr/bin/env python3
"""Deploy the Zig build to the 光猫 for testing, isolated from production.

    python tools/deploy_device.py start  [<binary>] [--port 15399] [--keep-config]
    python tools/deploy_device.py status [--port 15399]
    python tools/deploy_device.py stop   [--port 15399]

`--keep-config`（start/restart 都适用）
---------------------------------------
默认 start() 会**用内置模板重写 cfg.json**（storages 为空）—— 这是给
「干净启动跑 e2e」设计的。但它对「配置了真实存储、要跑全驱动回归」的场景
是灾难：一次 restart 就把手工合并上传的 storages 全抹掉（2026-10-16 踩过，
表现为 `no usable storages configured` + 0 mount published）。

带 `--keep-config` 时不碰 cfg.json（要求它已存在，否则报错），其余照旧
（清 data/run.log、重启进程）。

Why this exists
---------------
The device already runs the **Go production instance** (pid ~307,
`/opt/sq/openlist/openlist`, config `/opt/armbian/bin/openlist/config.json`,
listening on 15244). This script never touches it: everything lands in
`/tmp/olz` (tmpfs, gone on reboot) on its own port, with its own config.

Isolation rules enforced here
-----------------------------
  * absolute path `/tmp/olz/...` only — the SSH default cwd is `/root`, so a
    relative `tmp/olz/x` would silently become `/root/tmp/olz/x`;
  * the sftp-server kills the session if the parent dir is missing, so it is
    created *before* the SFTP channel opens;
  * `/opt/sq/openlist` and the Go `config.json` / `data.db` are never written.

Backgrounding
-------------
`nohup ... </dev/null &` inside a subshell is required. Without `</dev/null`
the child inherits the SSH channel's stdout and paramiko's `read()` never sees
EOF (the script hangs). Verified: the process survives across sessions.

⚠⚠ Process selection — this is where a real incident happened ⚠⚠
---------------------------------------------------------------
An early version killed anything matching `ps | grep '[o]penlist server'`.
The production Go instance runs as

    /opt/sq/openlist/openlist server --config /opt/armbian/bin/openlist/config.json

which **also** contains "openlist server", so that grep killed production
(it was restarted a minute later, but it must never happen again).

The rule: never select a process by a pattern that production could match.
Only kill by (a) the recorded pidfile, and (b) a match on this script's own
isolated directory `/tmp/olz`. Never by a bare binary/command substring.

First run
---------
A fresh config has no administrator and no `cdn`, so the built-in placeholder
page is served — which is exactly the page carrying the first-run setup panel.
Open `http://<device>:<port>/` and use the form. (If you set `cdn`, the real
frontend loads instead and brings its own wizard; you'd then be testing that,
not this build's shell.)
"""
import argparse
from creds import root_pwd as _root_pwd
import json
import os
import sys

import paramiko

HOST = "192.168.1.1"
PORT = 10022
USER = "root"
PASSWORD = _root_pwd()
ISOLATED = "/tmp/olz"  # tmpfs; the only place this script writes
DEFAULT_BIN = "dist/openlist-aarch64"

# 首次创建管理员的口令。
#
# 为什么用环境变量而不是 web 向导：`openlist admin set` 在**还没有任何管理员**
# 时会报 `NoAdministrator`，所以首次只有两条路 ——
#   1) Web 安装向导：`POST /api/public/init/setup`（上游前端在未初始化时会
#      自己跳到安装页；内置占位页则用 `#setup` 面板）；
#   2) `OPENLIST_ADMIN_PASSWORD` 环境变量：首次启动时以 `admin` 为用户名建号，
#      口令打印到**控制台**（Go 明确要求不写进日志文件）。
# 调试时第 2 条最省事：不用在浏览器里点向导，起来就能登录。
DEFAULT_ADMIN_PASSWORD = "openlist-zig-test"

# 前端一律走 CDN —— **不要**在设备上部署一份前端副本。
#
# 这个 Zig 版不内嵌前端（存在的意义就是去掉那部分体积），所以 shell 必须从
# 外部拿。方案只有 cdn 一种：把页面外壳与 /assets/ /images/ /streamer/
# /static/ 四个前缀指向 CDN。
#
# 曾经为了绕开设备侧取 CDN 失败，改成"本机下载前端 → 上传到 /tmp/olz/dist →
# 配 dist_dir"。**这是错的**（用户明确否决）：那等于在设备上又养了一份前端，
# 正是这个项目要消除的东西；而且它掩盖了真正要解决的问题（设备为什么取不到
# CDN）。CDN 取不到就去查 CDN 取不到的原因，不要换方案。
#
# 本机与打包机（Linux）实测同一个 URL 都是 200/4363B，CDN 本身可用。
DEFAULT_CDN = ("https://cdn.jsdelivr.net/npm/"
               "@openlist-frontend/openlist-frontend@latest/dist")

# 备用 CDN。主 CDN 取不到时按顺序往下试，全失败才退出。
# 全部经打包机 curl 实测可达（2026-10-15）：
#   cdn.jsdelivr.net / fastly.jsdelivr.net / gcore.jsdelivr.net / unpkg.com  → 200
# 不可用的（不要加进来）：
#   registry.npmmirror.com → 451 Unavailable For Legal Reasons
#   jsdelivr.pai233.top    → 402 需付费
# 前三个是同一个 jsdelivr 的不同边缘域名，换域名有时能绕开单点故障；
# unpkg 是完全独立的实现，留它做最后一道。
DEFAULT_CDN_FALLBACKS = [
    "https://fastly.jsdelivr.net/npm/@openlist-frontend/openlist-frontend@latest/dist",
    "https://gcore.jsdelivr.net/npm/@openlist-frontend/openlist-frontend@latest/dist",
    "https://unpkg.com/@openlist-frontend/openlist-frontend@latest/dist",
]

# 完整配置：字段取自二进制自己生成的默认配置，只改 cdn / http_port / 路径。
# 为什么不用最小配置：字段缺失虽然多半能容错，但一旦某个字段是必需的，症状
# 会是"配置没生效、cdn 为空"，排查成本远高于多写几行。
#
# cdn 是关键项，dist_dir 必须留空（非空会让 CDN 分支失效、去读不存在的前端
# 然后 Fatal）。web_version=rolling 是 CDN 分支的硬要求（server/static/
# static.go 的 initIndex 要求它 ∈ {"", beta, dev, rolling}）。
CONFIG_TMPL = """{{
  "force": false,
  "site_url": "",
  "cdn": "{cdn}",
  "dist_dir": "",
  "jwt_secret": "",
  "token_expires_in": 48,
  "database": {{
    "type": "sqlite3",
    "host": "",
    "port": 0,
    "user": "",
    "password": "",
    "name": "",
    "db_file": "{isolated}/data/data.db",
    "table_prefix": "x_",
    "ssl_mode": ""
  }},
  "scheme": {{
    "address": "0.0.0.0",
    "http_port": {port},
    "https_port": -1,
    "force_https": false,
    "cert_file": "",
    "key_file": "",
    "unix_file": "",
    "unix_file_perm": "",
    "enable_h2c": false
  }},
  "temp_dir": "{isolated}/data/temp",
  "bleve_dir": "{isolated}/data/bleve",
  "log": {{
    "enable": true,
    "name": "{isolated}/data/log/log.log",
    "max_size": 10,
    "max_backups": 5,
    "max_age": 28,
    "compress": false
  }},
  "delayed_start": 0,
  "max_connections": 0,
  "max_concurrency": 64,
  "tls_insecure_skip_verify": false,
  "zig": {{
    "ca_bundle": "",
    "http_timeout": 60,
    "web_version": "rolling",
    "cdn_fallbacks": {fallbacks_json},
    "site_title": "OpenList (zig)",
    "main_color": "#1890ff",
    "logo": "https://res.oplist.org/logo/logo.svg",
    "favicon": "https://res.oplist.org/logo/logo.svg",
    "customize_head": "",
    "customize_body": "",
    "token": ""
  }},
  "storages": []
}}
"""


def connect():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, port=PORT, username=USER, password=PASSWORD, timeout=20,
              look_for_keys=False, allow_agent=False)
    return c


def sh(c, cmd, timeout=120):
    _, o, e = c.exec_command(cmd, timeout=timeout)
    return o.read().decode(errors="replace") + e.read().decode(errors="replace")


def start(binary, port, cdn, fallbacks, admin_pw, keep_config=False):
    if not os.path.exists(binary):
        sys.exit(f"binary not found: {binary}")
    c = connect()
    try:
        # mkdir must precede the SFTP channel: a missing parent kills the session.
        sh(c, f"mkdir -p {ISOLATED}")
        sftp = c.open_sftp()
        remote = f"{ISOLATED}/openlist"
        sftp.put(binary, remote)
        sftp.chmod(remote, 0o755)
        if keep_config:
            # 保留现役 cfg.json（含手工合并的 storages）。它必须已经存在 ——
            # 静默回落到模板会让"明明传了配置却 0 mount"再次发生。
            try:
                sz = sftp.stat(f"{ISOLATED}/cfg.json").st_size
            except FileNotFoundError:
                sys.exit(f"--keep-config 要求 {ISOLATED}/cfg.json 已存在（先不带它启动一次或手动上传）")
            print(f"keep-config: 保留现役 cfg.json（{sz} 字节），不写模板")
        else:
            # the config is written through SFTP too — no shell quoting hazards.
            cfg = CONFIG_TMPL.format(cdn=cdn, port=port, isolated=ISOLATED,
                                     fallbacks_json=json.dumps(fallbacks))
            with sftp.open(f"{ISOLATED}/cfg.json", "w") as f:
                f.write(cfg)
        sftp.close()
        # 清掉曾经错误部署到设备上的前端副本 —— 这个项目的前提就是前端不落盘。
        sh(c, f"rm -rf {ISOLATED}/dist")
        print(f"staged {os.path.getsize(binary)} bytes -> {remote}")
        print(f"cdn:       {cdn or '(empty — placeholder page, no login form)'}")
        print(f"fallbacks: {len(fallbacks)} -> {[f.split('/')[2] for f in fallbacks]}")
        print(f"admin:     admin / {admin_pw}   (仅首次启动创建，之后改 config 里的 hash)")

        out = sh(c, f"""
cd {ISOLATED}
# ★ 进程识别用 `--port {port}`，见 stop() 里的完整说明。要点：
#   - 不能用二进制路径：启动方式是 `cd /tmp/olz && ./openlist ...`，
#     cmdline 里根本没有 "/tmp/olz"，按目录匹配一个都杀不掉；
#   - 不能用裸 'openlist server'：生产实例也叫这个，会误杀；
#   - 必须循环杀到 0：SO_REUSEPORT 下同端口的残留进程平分连接，会制造
#     "时而占位页时而真前端"的假 bug。
if [ -f olz.pid ]; then kill -9 $(cat olz.pid) 2>/dev/null; rm -f olz.pid; fi
for i in 1 2 3 4 5; do
  n=$(ps | grep -- '--port {port}' | grep -v grep | wc -l)
  [ "$n" = "0" ] && break
  for p in $(ps | grep -- '--port {port}' | grep -v grep | awk '{{print $1}}'); do
    kill -9 $p 2>/dev/null
  done
  sleep 1
done
echo "remaining on port {port}: $(ps | grep -- '--port {port}' | grep -v grep | wc -l)"
# 只清运行时产物。cfg.json 是本脚本刚写好的（含 cdn），删了就白写 ——
# 二进制发现配置不存在会生成一份默认配置，cdn 为空，前端退回占位页。
rm -rf data run.log
# </dev/null is mandatory — see the module docstring.
(OPENLIST_ADMIN_PASSWORD='{admin_pw}' nohup ./openlist server     --config cfg.json --port {port} >run.log 2>&1 </dev/null &)
echo $! > olz.pid
sleep 4
echo '--- log ---'
tail -6 run.log
echo '--- isolation check (production must still be there) ---'
ps | grep 'sq/openlist/openlist' | grep -v grep || echo 'WARNING: production instance NOT running'
echo '--- port ---'
netstat -ltn 2>/dev/null | grep {port} || echo 'NOT LISTENING'
""")
        print(out.strip())
        print(f"\n浏览器打开： http://{HOST}:{port}/")
        if admin_pw:
            print(f"  用户名 admin   口令 {admin_pw}")
            print("  （admin 由启动时的 OPENLIST_ADMIN_PASSWORD 建，直接登录即可。）")
        else:
            print("  未初始化：没有任何管理员，去下面这个页面自己建（同上游安装向导流程）。")
        print(f"  内置安装/诊断页： http://{HOST}:{port}/@zig-setup")
        print("  （本实现独有，配了 CDN 也永远可用：未初始化时显示建号表单，")
        print("    已初始化时显示指路与改密码说明。CDN 挂掉时靠它排查。）")
        print(f"停止：       python tools/deploy_device.py stop --port {port}")
    finally:
        c.close()
    return 0


def status(port):
    c = connect()
    try:
        print(sh(c, f"""
echo '--- zig test instance (this script only) ---'
ps | grep -- '--port {port}' | grep -v grep || echo '(none running)'
echo '--- port {port} ---'
netstat -ltn 2>/dev/null | grep {port} || echo '(not listening)'
echo '--- {ISOLATED} ---'
ls -la {ISOLATED}
echo '--- production Go instance (must be untouched) ---'
ps | grep 'sq/openlist/openlist' | grep -v grep || echo '(not running)'
""").strip())
    finally:
        c.close()
    return 0


def stop(port):
    c = connect()
    try:
        print(sh(c, f"""
# Same isolation rule as start(): pidfile + directory match only. A bare
# 'openlist server' grep would kill the production instance.
cd {ISOLATED}
# ★ 进程识别用 `--port {port}`，**不能**用二进制路径。
#   启动方式是 `cd /tmp/olz && ./openlist ...`，所以 cmdline 是
#   `./openlist server --config cfg.json --port 15399` —— 里面根本没有
#   "/tmp/olz" 字样，按目录匹配一个都杀不掉（实测残留 3 个进程同时监听，
#   SO_REUSEPORT 平分连接，浏览器时而拿到占位页时而拿到真前端）。
#   端口是本脚本独有的（生产用 config 里的端口），所以它才是可靠的标识。
#   同样不能用裸 'openlist server' —— 生产实例也叫这个，会误杀。
for i in 1 2 3 4 5; do
  n=$(ps | grep -- '--port {port}' | grep -v grep | wc -l)
  [ "$n" = "0" ] && break
  for p in $(ps | grep -- '--port {port}' | grep -v grep | awk '{{print $1}}'); do
    kill -9 $p 2>/dev/null
  done
  sleep 1
done
echo "remaining on port {port}: $(ps | grep -- '--port {port}' | grep -v grep | wc -l)"
rm -rf data run.log  # cfg.json 是刚写好的，不能删
echo '--- remaining ---'
ls -A {ISOLATED} || true
netstat -ltn 2>/dev/null | grep {port} || echo 'port {port} free'
echo '--- production instance (must still be running) ---'
ps | grep 'sq/openlist/openlist' | grep -v grep || echo 'WARNING: production NOT running'
""").strip())
    finally:
        c.close()
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("action", choices=["start", "stop", "status", "restart"])
    ap.add_argument("binary", nargs="?", default=DEFAULT_BIN)
    ap.add_argument("--port", type=int, default=15399)
    ap.add_argument("--cdn", default=DEFAULT_CDN,
                    help="frontend CDN base URL; '' disables it (placeholder page)")
    ap.add_argument("--admin-password", default=DEFAULT_ADMIN_PASSWORD,
                    help="OPENLIST_ADMIN_PASSWORD for first boot; '' disables it "
                         "(then use the web setup wizard instead)")
    ap.add_argument("--no-fallbacks", action="store_true",
                    help="do not write zig.cdn_fallbacks (test single-CDN behaviour)")
    ap.add_argument("--keep-config", action="store_true",
                    help="start/restart 时不重写 cfg.json（保留手工准备的 storages 配置）")
    a = ap.parse_args()
    fallbacks = [] if a.no_fallbacks else DEFAULT_CDN_FALLBACKS

    if a.action == "start":
        return start(a.binary, a.port, a.cdn, fallbacks, a.admin_password,
                     keep_config=a.keep_config)
    if a.action == "status":
        return status(a.port)
    if a.action == "stop":
        return stop(a.port)
    stop(a.port)
    return start(a.binary, a.port, a.cdn, fallbacks, a.admin_password,
                 keep_config=a.keep_config)


if __name__ == "__main__":
    sys.exit(main())
