#!/usr/bin/env python3
"""从设备 /tmp/olz/cfg.json 实时读取 Quark cookie。

**为什么必须这样做**：2026-10-16 排查时，本机 `%TEMP%/olz-cfg-merged.json`
里存的是旧会话的 cookie（`__puus` 前缀 85c0fddb），而用户早已在设备上更新为
新会话（099db75f）。脚本读旧副本 → CDN 回 403 `auth expired` → 得出了
「cookie 过期是主因」的**错误结论**，把整个排查带偏了半天。

教训：**调试脚本只认设备上的实时配置**，本机临时文件随时可能过期。
"""
import json
from creds import root_pwd as _root_pwd

HOST, PORT, USER, PASSWORD = "192.168.1.1", 10022, "root", _root_pwd()


def device_cfg():
    """拉取设备 /tmp/olz/cfg.json（返回 dict）。"""
    import paramiko
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, port=PORT, username=USER, password=PASSWORD, timeout=20,
              look_for_keys=False, allow_agent=False)
    try:
        sftp = c.open_sftp()
        with sftp.open("/tmp/olz/cfg.json", "r") as f:
            return json.load(f)
    finally:
        c.close()


def quark_cookie():
    """设备上 Quark 存储的 cookie（实时值）。"""
    cfg = device_cfg()
    for s in cfg["storages"]:
        if s.get("driver") == "Quark":
            return json.loads(s["addition"])["cookie"]
    raise RuntimeError("device cfg has no Quark storage")


if __name__ == "__main__":
    ck = quark_cookie()
    import re
    m = re.search(r"__puus=([0-9a-f]{8})", ck)
    print("cookie len=%d __puus=%s..." % (len(ck), m.group(1) if m else "?"))
