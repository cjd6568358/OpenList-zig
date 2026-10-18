"""把 Go 备份里选定的存储**增量合并**进一份已在跑的 Zig 配置。

为什么需要它（2026-10-16）
--------------------------
设备上的 `/tmp/olz/cfg.json` 是现役测试配置：里面的 quark cookie 是用户后来
手动更新过的（旧备份里的 cookie 已过期）。全驱动回归需要把备份里其余存储
（123Pan / AliyundriveOpen / WebDav / Local / itvsh）也并进来 —— 但**绝不能**
用 `import_go_config.py` 整份重生成，那会把现役凭据退回备份时的旧值。

规则：
- 以现役 cfg 为基底，`zig`/`jwt_secret`/端口等全部保留；
- 用 `import_go_config.convert()` 转换备份里 `--only` 选定的存储（含 disabled 的）；
- `mount_path` 已存在的 → **保留设备版**（防凭据回退）；
- 不存在的 → 加入，且 `disabled` 强制改 `false`（回归测试要它们全跑）；
- 其余字段原样。

用法：
    python tools/merge_import.py <backup.json> <base_cfg.json> <out.json> \
        [--only 1,2,3] [--keep-disabled]

输出含真实凭据，写到临时路径，别进版本库。
"""
import argparse
import importlib.util
import json
import os
import sys


def _load_igc():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location(
        "import_go_config", os.path.join(here, "import_go_config.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("backup", help="Go 备份 JSON")
    ap.add_argument("base_cfg", help="已在跑的 Zig 配置（基底，凭据以此为准）")
    ap.add_argument("out", help="输出路径")
    ap.add_argument("--only", default="", help="逗号分隔的存储 id（默认全部）")
    ap.add_argument("--keep-disabled", action="store_true",
                    help="保留 Go 里的 disabled 状态（默认强制启用，供回归）")
    args = ap.parse_args()

    igc = _load_igc()
    only = {int(x) for x in args.only.split(",") if x.strip()} if args.only else set()

    backup = json.load(open(args.backup, encoding="utf-8"))
    base = json.load(open(args.base_cfg, encoding="utf-8"))

    scheme = (base.get("scheme") or {})
    port = scheme.get("http_port") or 15399
    conv, report, _ = igc.convert(
        backup, None, port, base.get("temp_dir", "/tmp/olz/temp"), only,
        include_disabled=True)

    for sid, driver, mount, status, why in report:
        print("  [%s] #%s %-14s %-18s %s" % (status, sid, mount or "?", driver or "?", why))

    existing = {s.get("mount_path") for s in base.get("storages", [])}
    kept, added = [], []
    for s in conv["storages"]:
        if s["mount_path"] in existing:
            kept.append("%s (#%s %s)" % (s["mount_path"], s["id"], s["driver"]))
            continue
        if not args.keep_disabled:
            s["disabled"] = False
        base["storages"].append(s)
        added.append("%s (#%s %s)" % (s["mount_path"], s["id"], s["driver"]))

    print()
    print("保留设备版（凭据不回退）: %s" % (", ".join(kept) if kept else "无"))
    print("新增: %s" % (", ".join(added) if added else "无"))
    print("最终挂载 %d 个: %s" % (
        len(base["storages"]),
        ", ".join(s["mount_path"] for s in base["storages"])))

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(base, f, ensure_ascii=False, indent=2)
    print("已写入 %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
