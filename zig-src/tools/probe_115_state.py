"""115 账号现状核查：fs/list /115 + 设备侧直抓 webapi files 原始响应。

背景：修复 getOssToken 后 PUT root-level 成功（code 200），但 /115 根列表
从 15 条变 0 条，且刚 mkdir 的目录 resolve 404。需要分清是「账号真空了」
还是「列表链路坏了」。
"""
import json
from creds import root_pwd as _root_pwd
import re
import sys
import time

import paramiko

HOST, PORT, USER, PWD = "192.168.1.1", 10022, "root", _root_pwd()
BASE = "http://127.0.0.1:15399"
UA = "Mozilla/5.0 115Browser/35.6.0.3"
PW = "e2e-test-123456"


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, port=PORT, username=USER, password=PWD, timeout=20,
              look_for_keys=False, allow_agent=False)

    def sh(cmd, timeout=90):
        _, out, err = c.exec_command(cmd, timeout=timeout)
        return out.read().decode(errors="replace"), err.read().decode(errors="replace")

    def curl(args):
        o, e = sh("curl -s " + args)
        if e.strip():
            print("stderr:", e[:200])
        return o

    def sq(s):
        return "'" + s.replace("'", "'\\''") + "'"

    o = curl("-X POST %s/api/auth/login -H 'Content-Type: application/json' --data-binary %s"
             % (BASE, sq(json.dumps({"username": "admin", "password": PW}))))
    tok = (json.loads(o).get("data") or {}).get("token")
    AUTH = "-H 'Authorization: Bearer %s'" % tok
    print("login ok")

    # 1) 实例视角：/115 根
    o = curl("-X POST %s/api/fs/list %s -H 'Content-Type: application/json' --data-binary %s"
             % (BASE, AUTH, sq(json.dumps({"path": "/115", "page": 1, "per_page": 100}))))
    try:
        j = json.loads(o)
        content = (j.get("data") or {}).get("content") or []
        print("fs/list /115: code=%s total=%s entries=%d" % (j.get("code"), (j.get("data") or {}).get("total"), len(content)))
        for e in content:
            print("   %s %s" % ("d" if e.get("is_dir") else "-", e.get("name")))
    except Exception as ex:
        print("fs/list parse fail:", ex, o[:300])

    # 2) 设备侧直抓 webapi files（绕过实例，看上游原始响应）
    raw = (
        "CK=$(grep -o 'cookie\\\\\":\\\\\"[^\\\\]*' /tmp/olz/cfg.json | tail -1 "
        "| sed 's/^cookie\\\\\":\\\\\"//'); "
        "curl -s -w '\\n---HTTP %{http_code} size=%{size_download}---\\n' "
        "'https://webapi.115.com/files?aid=1&cid=0&o=user_ptime&asc=1&offset=0&show_dir=1&limit=1000&snap=0&natsort=0&record_open_time=1&format=json&fc_mix=0' "
        "-H 'User-Agent: " + UA + "' -H \"Cookie: $CK\" "
        "-H 'Referer: https://115.com/'"
    )
    o, e = sh(raw, timeout=90)
    c.close()
    body = o.split("---HTTP", 1)[0]
    print("direct files API:", o.split("---HTTP", 1)[1].strip() if "---HTTP" in o else "")
    # 只打印结构：state/count/data 条数 + 前 300 字符
    try:
        j = json.loads(body)
        data = j.get("data") or []
        print("direct: state=%r count=%r data.len=%d" % (j.get("state"), j.get("count"), len(data)))
        print("direct head:", body[:300])
    except Exception as ex:
        print("direct not json:", ex, body[:200])
    return 0


if __name__ == "__main__":
    sys.exit(main())
