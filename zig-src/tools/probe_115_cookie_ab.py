"""对照实验：全量 cookie vs 重建四字段 cookie 打 115 files API。

动机：实例（发重建四字段 cookie）fs/list /115 恒 0 条，设备侧直抓
（发 470 字符全量 cookie）17 条。同一 URL、同一 UA/Referer，唯一差别
是 cookie 形态。本脚本在设备上复刻 fromCookie 的解析（last-wins），
分别用两种 cookie 打同一个 URL，对比响应。
"""
import sys

import paramiko

HOST, PORT, USER, PWD = "192.168.1.1", 10022, "root", "REDACTED"
UA = "Mozilla/5.0 115Browser/35.6.0.3"
URL = ("https://webapi.115.com/files?aid=1&cid=0&o=user_ptime&asc=1&offset=0"
       "&show_dir=1&limit=1000&snap=0&natsort=0&record_open_time=1&format=json&fc_mix=0")


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, port=PORT, username=USER, password=PWD, timeout=20,
              look_for_keys=False, allow_agent=False)

    def sh(cmd, timeout=90):
        _, out, err = c.exec_command(cmd, timeout=timeout)
        return out.read().decode(errors="replace"), err.read().decode(errors="replace")

    # 复刻 Zig fromCookie：split ';'，last-wins 取 UID/CID/SEID/KID
    rebuild = (
        "CK=$(grep -o 'cookie\\\\\":\\\\\"[^\\\\]*' /tmp/olz/cfg.json | tail -1 "
        "| sed 's/^cookie\\\\\":\\\\\"//'); "
        "UID=$(echo $CK | tr ';' '\\n' | grep -i '^UID=' | tail -1 | cut -d= -f2-); "
        "CID=$(echo $CK | tr ';' '\\n' | grep -i '^CID=' | tail -1 | cut -d= -f2-); "
        "SEID=$(echo $CK | tr ';' '\\n' | grep -i '^SEID=' | tail -1 | cut -d= -f2-); "
        "KID=$(echo $CK | tr ';' '\\n' | grep -i '^KID=' | tail -1 | cut -d= -f2-); "
        "echo \"rebuilt: UID=${#UID}B CID=${#CID}B SEID=${#SEID}B KID=${#KID}B\"; "
        "REBUILT=\"UID=$UID;CID=$CID;SEID=$SEID;KID=$KID\"; "
        "echo \"--- rebuilt cookie ---\"; "
        "curl -s -w '\\n[HTTP %{http_code} size=%{size_download}]\\n' '$URL' "
        "-H 'User-Agent: " + UA + "' -H \"Cookie: $REBUILT\" "
        "-H 'Referer: https://115.com/' "
        "| sed -e 's/\\(\"pc\":\"\\)[^\"]*/\\1<R>/g' | head -c 600; "
        "echo; echo \"--- full cookie ---\"; "
        "curl -s -w '\\n[HTTP %{http_code} size=%{size_download}]\\n' '$URL' "
        "-H 'User-Agent: " + UA + "' -H \"Cookie: $CK\" "
        "-H 'Referer: https://115.com/' "
        "| sed -e 's/\\(\"pc\":\"\\)[^\"]*/\\1<R>/g' | head -c 600; "
        "echo; echo \"--- full cookie, no referer ---\"; "
        "curl -s -w '\\n[HTTP %{http_code} size=%{size_download}]\\n' '$URL' "
        "-H 'User-Agent: " + UA + "' -H \"Cookie: $CK\" "
        "| sed -e 's/\\(\"pc\":\"\\)[^\"]*/\\1<R>/g' | head -c 300; "
        "echo"
    )
    o, e = sh(rebuild, timeout=120)
    c.close()
    print(o)
    if e.strip():
        print("stderr:", e[:300])
    return 0


if __name__ == "__main__":
    sys.exit(main())
