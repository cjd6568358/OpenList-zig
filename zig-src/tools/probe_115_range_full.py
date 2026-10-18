"""115 WebDAV Range 403 全量取证：完整响应头 + body + 实例日志增量。

上一个实验（三种 UA 全 403、body 9 字节）说明不是客户端 UA 问题。
本脚本把 403 的完整响应（状态行/所有头/body）和 run.log 增量都打出来，
定位 403 究竟来自上游 CDN 还是本端链路。
"""
import base64
import json
import sys
import time

import paramiko

HOST, PORT, USER, PWD = "192.168.1.1", 10022, "root", "REDACTED"
BASE = "http://127.0.0.1:15399"
PW = "e2e-test-123456"


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, port=PORT, username=USER, password=PWD, timeout=20,
              look_for_keys=False, allow_agent=False)

    def sh(cmd, timeout=120):
        _, out, err = c.exec_command(cmd, timeout=timeout)
        return out.read().decode(errors="replace"), err.read().decode(errors="replace")

    def sq(s):
        return "'" + s.replace("'", "'\\''") + "'"

    o, _ = sh("curl -s -X POST %s/api/auth/login -H 'Content-Type: application/json' --data-binary %s"
              % (BASE, sq(json.dumps({"username": "admin", "password": PW}))))
    tok = (json.loads(o).get("data") or {}).get("token")
    AUTH = "-H 'Authorization: Bearer %s'" % tok
    basic = base64.b64encode(("admin:" + PW).encode()).decode()
    BAUTH = "-H 'Authorization: Basic %s'" % basic

    for i in range(60):
        o, _ = sh("curl -s -X POST %s/api/fs/list %s -H 'Content-Type: application/json' --data-binary %s"
                  % (BASE, AUTH, sq(json.dumps({"path": "/"}))))
        try:
            if (json.loads(o).get("data") or {}).get("content"):
                break
        except Exception:
            pass
        time.sleep(2)

    o, _ = sh("wc -c < /tmp/olz/run.log")
    mark = int(o.strip())

    tag = "olz-ua2-%d" % int(time.time())
    d = "/115/%s" % tag
    o, _ = sh("curl -s -X POST %s/api/fs/mkdir %s -H 'Content-Type: application/json' --data-binary %s"
              % (BASE, AUTH, sq(json.dumps({"path": d}))))
    print("mkdir:", o[:120])
    wp = "/dav%s/w.txt" % d
    o, _ = sh("curl -s -o /dev/null -w 'PUT %%{http_code}\\n' -X PUT %s %s --data-binary 'webdav payload'"
              % (BASE + wp, BAUTH))
    print("webdav put:", o.strip())

    # ① 普通 GET（无 Range）
    o, _ = sh("curl -s -D - %s %s -H 'User-Agent: Mozilla/5.0 115Browser/35.6.0.3' | head -40"
              % (BASE + wp, BAUTH))
    print("=== plain GET ===")
    print(o[:1500])

    # ② Range GET 完整响应
    o, _ = sh("curl -s -D - %s %s -H 'User-Agent: Mozilla/5.0 115Browser/35.6.0.3' -H 'Range: bytes=0-4' | head -40"
              % (BASE + wp, BAUTH))
    print("=== Range GET ===")
    print(o[:1500])

    # ③ 实例日志增量
    o, _ = sh("tail -c +%d /tmp/olz/run.log" % (mark + 1))
    print("=== run.log delta ===")
    for line in o.splitlines():
        if any(k in line for k in ("115", "proxy", "down", "dav", "uplb", "webapi")):
            print(line[:300])

    o, _ = sh("curl -s -X POST %s/api/fs/remove %s -H 'Content-Type: application/json' --data-binary %s"
              % (BASE, AUTH, sq(json.dumps({"dir": "/115", "names": [tag]}))))
    print("cleanup:", o[:120])
    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
