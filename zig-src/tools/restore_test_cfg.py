"""光猫测试实例的配置恢复工具（设备重启后 /tmp 被清空时用）。

背景：测试实例跑在 `/tmp/olz`（tmpfs），光猫一重启就全没了。`cfg-restore-fixed.json`
是人工整理好的那份「12 挂载 + admin 口令已重置为 openlist-zig-test」的配置快照，
本脚本把它传回设备。

用法（重启后）：

    python tools/restore_test_cfg.py                 # 只上传配置
    python tools/deploy_device.py start --keep-config   # 再启动实例（保留刚传的 cfg）
    python tools/e2e_test.py http://192.168.1.1:15399 --write-cloud \
        --user admin --password openlist-zig-test   # 确认 13 挂载都发布

⚠ 会**覆盖**设备上的 `/tmp/olz/cfg.json`（并把同一份留成 `cfg-restore.json`）。
只用于测试实例；生产实例 `/opt/sq/openlist` 与本脚本无关，绝不要混用。

⚠ 2026-10-18 踩过：设备 21:07 重启后有人用**旧快照**恢复，导致 7 个存储
`disabled: true`、`/hikvision` 指向不存在的 `/media/camera/hikvision`。恢复后
务必跑一遍 `deploy_device.py status` + `e2e_test.py`，别只看进程在不在。
"""
import sys

sys.path.insert(0, "tools")
from remote import connect  # noqa: E402

ISOLATED = "/tmp/olz"
SNAPSHOT = "tools/cfg-restore-fixed.json"


def main():
    c = connect("192.168.1.1", 10022)
    sftp = c.open_sftp()
    try:
        sftp.mkdir(ISOLATED)
    except IOError:
        pass  # 已存在（重启后其实不存在，幂等）
    sftp.put(SNAPSHOT, f"{ISOLATED}/cfg.json")
    print("cfg uploaded:", sftp.stat(f"{ISOLATED}/cfg.json").st_size, "bytes")
    # 归档一份，和以前 /tmp/olz/cfg-restore.json 的习惯保持一致
    sftp.put(SNAPSHOT, f"{ISOLATED}/cfg-restore.json")
    sftp.close()
    c.close()
    print("next: python tools/deploy_device.py start --keep-config")


if __name__ == "__main__":
    main()
