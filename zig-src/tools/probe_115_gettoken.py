"""抓 115 gettoken.php 的真实响应体（设备本机直连，带驱动同款头）。

背景：put 走到 initupload status=1 后调 getOssToken，HTTP 200 但解析抛
InvalidResponse —— Zig 在 `AccessKeyID`/`AccessKeySecret` 缺失时抛错，
而 Go SDK 的 Err() 只查 StatusCode。需要看真实响应到底是「字段不在顶层」
还是「字段为空/改名」。

cookie 从 /tmp/olz/cfg.json 提取后只在设备侧 shell 变量里流转，不进本机；
响应体拉回本机后先脱敏再打印。
"""
import json
import re
import sys

import paramiko

HOST, PORT, USER, PWD = "192.168.1.1", 10022, "root", "REDACTED"
UA = "Mozilla/5.0 115Browser/35.6.0.3"  # pan115.zig app_ver


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, port=PORT, username=USER, password=PWD, timeout=20,
              look_for_keys=False, allow_agent=False)

    def sh(cmd, timeout=60):
        _, out, err = c.exec_command(cmd, timeout=timeout)
        return out.read().decode(errors="replace"), err.read().decode(errors="replace")

    # 1) 提取 cookie（设备侧变量，只回传长度与前缀形态）
    # ⚠ cfg.json 是单行，`grep -c cookie` 恒为 1；多个存储都有 cookie 字段，
    # 115 Cloud 是 storages 数组最后一个 ⇒ 取**最后**一个匹配。
    extract = (
        "CK=$(grep -o 'cookie\\\\\":\\\\\"[^\\\\]*' /tmp/olz/cfg.json | tail -1 "
        "| sed 's/^cookie\\\\\":\\\\\"//'); "
        "echo \"len=${#CK} prefix=$(echo $CK | cut -c1-4) parts=$(echo $CK | tr ';' '\\n' | wc -l)\""
    )
    o, e = sh(extract)
    print("cookie:", o.strip(), e.strip())

    # 2) 用驱动同款头打 gettoken.php（设备侧解析 DNS+建连，本机不直连外网）
    curl = (
        "CK=$(grep -o 'cookie\\\\\":\\\\\"[^\\\\]*' /tmp/olz/cfg.json | tail -1 "
        "| sed 's/^cookie\\\\\":\\\\\"//'); "
        "curl -s -w '\\n---HTTP %{http_code} size=%{size_download}---\\n' "
        "'https://uplb.115.com/3.0/gettoken.php' "
        "-H 'User-Agent: " + UA + "' -H \"Cookie: $CK\" "
        "-H 'Referer: https://115.com/' "
        "-H 'Content-Type: application/json;charset=UTF-8'"
    )
    o, e = sh(curl, timeout=60)
    c.close()

    body = o.split("---HTTP", 1)[0]
    meta = ("---HTTP" + o.split("---HTTP", 1)[1]) if "---HTTP" in o else ""
    print("gettoken.php:", meta.strip())
    dump(body, "gettoken")

    # 5) check/sso（init 的登录检查）：Go LoginResp.State 是 int（==0 成功），
    # Zig 用 intAt —— 需要确认线上 state 到底是数字还是布尔。
    c2 = paramiko.SSHClient()
    c2.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c2.connect(HOST, port=PORT, username=USER, password=PWD, timeout=20,
               look_for_keys=False, allow_agent=False)
    ms = int(__import__("time").time() * 1000)
    sso = (
        "CK=$(grep -o 'cookie\\\\\":\\\\\"[^\\\\]*' /tmp/olz/cfg.json | tail -1 "
        "| sed 's/^cookie\\\\\":\\\\\"//'); "
        "curl -s -w '\\n---HTTP %{http_code}---\\n' "
        "'https://passportapi.115.com/app/1.0/web/1.0/check/sso?_=" + str(ms) + "' "
        "-H 'User-Agent: " + UA + "' -H \"Cookie: $CK\" "
        "-H 'Referer: https://115.com/' "
        "-H 'Content-Type: application/json;charset=UTF-8'"
    )
    _, out2, _ = c2.exec_command(sso, timeout=60)
    o2 = out2.read().decode(errors="replace")
    c2.close()
    body2 = o2.split("---HTTP", 1)[0]
    print("check/sso:", o2.split("---HTTP", 1)[1].strip() if "---HTTP" in o2 else "")
    dump(body2, "sso")
    return 0


def dump(body, tag):
    # 3) 脱敏：三个敏感字段的值换成 <len:N>，其余原样
    def redact(m):
        return '"%s":"<len:%d>"' % (m.group(1), len(m.group(2)))

    red = re.sub(r'"(AccessKeyID|AccessKeySecret|SecurityToken)":"([^"]*)"', redact, body)
    print("%s body (redacted):" % tag, red[:1200])

    # 4) 结构摘要：顶层键 + data 子键（若有）
    try:
        j = json.loads(body)
        print("%s top-level keys:" % tag, sorted(j.keys()))
        if isinstance(j.get("data"), dict):
            print("%s data keys:" % tag, sorted(j["data"].keys()))
        for k in ("state", "code", "StatusCode", "errno", "message", "error"):
            if k in j:
                v = j[k]
                print("  %s = %r (%s)" % (k, v if not isinstance(v, str) or len(v) < 60 else v[:60] + "...", type(v).__name__))
    except Exception as ex:
        print("%s not json:" % tag, ex, body[:200])


if __name__ == "__main__":
    sys.exit(main())
