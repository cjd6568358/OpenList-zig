"""Import a Go OpenList export into a Zig `config.json` — losslessly where the
two formats actually overlap, and with an explicit report where they do not.

Why this was rewritten (2026-10-16)
-----------------------------------
The first version only carried `storages` across: settings, users and
`jwt_secret` were all dropped, so a migrated instance came up with default
branding, no sign_all/link_expiration, and a fresh secret. It also carried a
`SUPPORTED` name-mapping table, which is dead weight — the Zig factories'
`key` is byte-identical to Go's `driver.Config.Name` by rule, so the driver
string can be copied straight across.

What the two inputs are
-----------------------
* **backup** (what the admin UI's "导出" writes, and what `/api/admin/...`
  produces): `{settings, users, storages, metas, shares}`. No secrets that Go
  marks `json:"-"`, i.e. **no password hash / salt / pwd timestamp**.
* **config.json** (Go's own config file): `{site_url, cdn, jwt_secret,
  token_expires_in, scheme, ...}`. This is where the runtime knobs live.

This tool takes either or both. Pass `--go-config` alongside the backup to
also inherit `jwt_secret` / `site_url` / `cdn` / ports.

What cannot be migrated
-----------------------
`users[].password` is always empty in a backup and `PwdHash`/`Salt`/`PwdTS`
carry `json:"-"`, so they are **never exported**. The admin password therefore
cannot be carried over — set it with `openlist admin set <pw>` or via the
setup page. The username and permission bits *are* migrated.

Usage
-----
    python tools/import_go_config.py <backup.json> <out_config.json>
        [--go-config <go config.json>] [--port 15244] [--temp-dir /tmp/olz/temp]
        [--only id,id,...] [--include-disabled]

The output contains real credentials. Write it to a scratch path, never over a
live Go config or database.
"""
import argparse
import io
import json
import os
import sys

# 本构建注册的驱动 = Go 的 `driver.Config.Name`，逐字节相同（见 STATUS.md §26）。
# 这张表只用来**判定能不能导**，不做改名 —— 名字原样搬。
#
# `quarkuc.zig` 一个文件出两个驱动，所以 Quark 与 UC 都在。
SUPPORTED = {
    "Local",
    "WebDav",
    "Itvsh",
    "AliyundriveOpen",
    "189Cloud",
    "189CloudPC",
    "123Pan",
    "Quark",
    "UC",
    "115 Cloud",
    "WoPan",
    "Strm",
}

# 明确不支持的驱动 + 可查询的理由（不静默丢弃）。
UNSUPPORTED = {
    "BaiduNetdisk": "未移植（Go 树里有 drivers/baidu_netdisk）",
    "Onedrive": "未移植（Go 树里有 drivers/onedrive）",
    "S3": "本构建不提供 S3 服务",
    "FTP": "本构建不提供 FTP 服务",
    "SFTP": "本构建不提供 SFTP 服务（已 defer，见 docs/FEASIBILITY.md §5.3）",
    "MCP": "本构建不提供 MCP 服务",
}

# Go 的 setting key → Zig 的落点。
# 值形如 ("cfg_field", "zig_key")：既写 Zig 的 `zig.*` 块（重启后仍在），
# 也写运行期字段。`None` 表示本构建没有对应实现，进报告而不是静默丢。
SETTING_MAP = {
    "site_title": ("site_title", "site_title"),
    "logo": ("logo", "logo"),
    "favicon": ("favicon", "favicon"),
    "main_color": ("main_color", "main_color"),
    "customize_head": ("customize_head", "customize_head"),
    "customize_body": ("customize_body", "customize_body"),
    "sign_all": ("sign_all", "sign_all"),
    "link_expiration": ("link_expiration", "link_expiration"),
}

# Go 的 config.json 顶层字段 → Zig。`None` = 本构建没有该功能。
GO_CONFIG_MAP = {
    "site_url": "site_url",
    "cdn": "cdn",
    "jwt_secret": "jwt_secret",
    "token_expires_in": "token_expires_in",
    "temp_dir": "temp_dir",
    "dist_dir": "dist_dir",
    "max_connections": "max_connections",
    "max_concurrency": "max_concurrency",
    "tls_insecure_skip_verify": "tls_insecure_skip_verify",
}


def _as_bool(v):
    if isinstance(v, bool):
        return v
    return str(v).strip().lower() == "true"


def _as_int(v, default=0):
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return default


def convert(backup, go_config, port, temp_dir, only, include_disabled):
    report = []

    # ---- storages --------------------------------------------------------
    storages = []
    for s in backup.get("storages", []):
        sid = s.get("id")
        if only and sid not in only:
            continue
        if s.get("disabled") and not include_disabled:
            report.append((sid, s.get("driver"), s.get("mount_path"),
                           "SKIP", "Go 里就是 disabled，未导入（加 --include-disabled 可带上）"))
            continue
        driver = s.get("driver", "")
        if driver not in SUPPORTED:
            why = UNSUPPORTED.get(driver, "未知驱动名（不在本构建的注册表里）")
            report.append((sid, driver, s.get("mount_path"), "SKIP", why))
            continue

        addition = s.get("addition")
        if not isinstance(addition, str):
            # Go 存的是 JSON **字符串**，Zig 的 parseStorages 也按字符串读。
            addition = json.dumps(addition or {}, ensure_ascii=False)

        storages.append({
            "id": sid,
            "mount_path": s.get("mount_path") or "/",
            "order": s.get("order", 0),
            "driver": driver,           # 原样搬，不做映射
            "cache_expiration": s.get("cache_expiration", 0),
            "status": s.get("status", "work"),
            "addition": addition,
            "remark": s.get("remark", ""),
            "disabled": bool(s.get("disabled", False)),
            # 存储级「Web 代理」开关：Go 的 ShouldProxy 第一分支。直链绑定
            # 会话 cookie 的驱动（夸克/UC）靠它强制服务端回源，丢了就会在
            # CDN 侧拿到 require login 403 —— 用户的夸克存储就是 true。
            "web_proxy": bool(s.get("web_proxy", False)),
            # 创建/最近更新时间（Go `op.CreateStorage`/`UpdateStorage` 的
            # `storage.Modified = time.Now()`）。RFC3339 字符串原样搬，
            # 前端存储列表/编辑表单会显示它。
            "modified": s.get("modified", ""),
        })
        report.append((sid, driver, s.get("mount_path"), "OK", "原样导入"))

    # ---- settings --------------------------------------------------------
    zig = {"web_version": "rolling"}
    settings_seen = set()
    for item in backup.get("settings", []):
        key = item.get("key")
        val = item.get("value", "")
        settings_seen.add(key)
        if key in SETTING_MAP:
            _, zig_key = SETTING_MAP[key]
            # 布尔/数字按 Zig 的 JSON 类型落盘（Zig 用 asInt/asBool 读）。
            if key == "sign_all":
                zig[zig_key] = _as_bool(val)
            elif key == "link_expiration":
                zig[zig_key] = _as_int(val)
            else:
                zig[zig_key] = val
        # 其余 key 本构建没有实现，下面统一进报告。

    # ---- users -----------------------------------------------------------
    admin_user = "admin"
    admin_permission = 0x71FF  # Go InitSetup 的默认值
    for u in backup.get("users", []):
        if u.get("role") == 2:  # model.ADMIN
            admin_user = u.get("username") or "admin"
            admin_permission = _as_int(u.get("permission"), 0x71FF)
            if u.get("password"):
                report.append((u.get("id"), "user", admin_user, "WARN",
                               "备份里带了明文 password 字段，已忽略（Zig 存哈希不存明文）"))
            break
    zig["admin_user"] = admin_user
    zig["admin_permission"] = admin_permission

    # ---- go config.json (optional) --------------------------------------
    cfg = {
        "force": False,
        "site_url": "",
        "cdn": "",
        "dist_dir": "",
        "jwt_secret": "",
        "token_expires_in": 48,
        "scheme": {
            "address": "0.0.0.0",
            "http_port": port,
            "https_port": -1,
            "force_https": False,
            "cert_file": "",
            "key_file": "",
        },
        "temp_dir": temp_dir,
        "log": {"enable": True,
                "name": os.path.join(os.path.dirname(temp_dir), "log/log.log")},
        "max_connections": 0,
        "max_concurrency": 64,
        "tls_insecure_skip_verify": False,
        "zig": zig,
        "storages": storages,
    }
    if go_config:
        for gk, zk in GO_CONFIG_MAP.items():
            if gk in go_config:
                cfg[zk] = go_config[gk]
        sch = go_config.get("scheme") or {}
        for k in ("address", "http_port", "https_port", "force_https",
                  "cert_file", "key_file"):
            if k in sch:
                cfg["scheme"][k] = sch[k]
        log = go_config.get("log") or {}
        for k in ("enable", "name"):
            if k in log:
                cfg["log"][k] = log[k]

    return cfg, report, settings_seen


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src", help="Go backup JSON (settings/users/storages)")
    ap.add_argument("dst", help="Zig config.json to write")
    ap.add_argument("--go-config", default="",
                    help="Go 自己的 config.json，用来继承 jwt_secret/site_url/cdn/端口")
    ap.add_argument("--port", type=int, default=15244)
    ap.add_argument("--temp-dir", default="/tmp/olz/temp")
    ap.add_argument("--only", default="", help="comma separated storage ids")
    ap.add_argument("--include-disabled", action="store_true",
                    help="连 Go 里 disabled 的存储一起导（默认跳过）")
    args = ap.parse_args()

    only = {int(x) for x in args.only.split(",") if x.strip()} if args.only else set()

    backup = json.load(io.open(args.src, encoding="utf-8"))
    go_config = None
    if args.go_config:
        go_config = json.load(io.open(args.go_config, encoding="utf-8"))

    cfg, report, settings_seen = convert(
        backup, go_config, args.port, args.temp_dir, only, args.include_disabled)

    with io.open(args.dst, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)

    print(f"wrote {args.dst}")
    print(f"  storages : {len(cfg['storages'])}")
    print(f"  admin    : {cfg['zig']['admin_user']} "
          f"(permission {cfg['zig']['admin_permission']} = "
          f"0x{cfg['zig']['admin_permission']:X})")
    print(f"  settings : {sorted(k for k in cfg['zig'] if k in {v[1] for v in SETTING_MAP.values()})}")
    if not go_config:
        print("  ⚠ 未传 --go-config：jwt_secret 为空（重启会重新生成），"
              "site_url/cdn 用默认值")
    print()
    print(f"{'id':>4}  {'driver':<20} {'mount':<18} {'':<5} note")
    for sid, driver, mount, verdict, note in report:
        print(f"{sid if sid is not None else '-':>4}  {str(driver or ''):<20} "
              f"{str(mount or ''):<18} {verdict:<5} {note}")

    # 本构建没有实现的 setting，明确列出来（不静默丢）。
    # 运行时状态不是配置：`version` 是 Go 的构建号、`token` 是 CLI 用的
    # 一次性密钥、`index_progress` 是索引进度快照。这些不该出现在"缺实现"里。
    RUNTIME_STATE = {"version", "token", "index_progress"}
    missing = sorted(k for k in settings_seen
                     if k and k not in SETTING_MAP
                     and k not in RUNTIME_STATE
                     and not k.startswith(("sso_", "ldap_")))
    if missing:
        print()
        print(f"本构建没有对应实现的 setting（{len(missing)} 项，未导入）：")
        print("  " + ", ".join(missing))
    print()
    print("⚠ 密码无法迁移：Go 的 PwdHash/Salt/PwdTS 都是 json:\"-\"，导出里就没有。")
    print("  首次启动后用 `openlist admin set <新密码>` 或 setup 页面设置。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
