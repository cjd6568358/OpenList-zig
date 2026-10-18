"""115 WebDAV Range 403 归因实验：换 UA 打同一直链。

e2e「WebDAV Range（远程：第一跳）」在 115 上拿到 403。假设：115 CDN 按
UA 授权直链，e2e 客户端（Python-urllib）的 UA 被拒；驱动 link 时把客户端
UA 一并用于取链，Go 的 common.Proxy 也转发客户端 UA ⇒ Go 同结果。

实验：设备 loopback 上 WebDAV PUT 一个小文件，然后带 Range 分别用三种 UA
GET：curl 默认 / 115Browser（驱动同款）/ Python-urllib（e2e 同款）。
若只有 115Browser 成功 ⇒ 403 是上游 UA 策略，Go/Zig 行为一致。
"""
import base64
from creds import root_pwd as _root_pwd
import json
import sys
import time

import paramiko

HOST, PORT, USER, PWD = "192.168.1.1", 10022, "root", _root_pwd()
BASE = "http://127.0.0.1:15399"
PW = "e2e-test-123456"
UA_115 = "Mozilla/5.0 115Browser/35.6.0.3"


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

    # 登录拿 token（建目录/清理用）
    o, _ = sh("curl -s -X POST %s/api/auth/login -H 'Content-Type: application/json' --data-binary %s"
              % (BASE, sq(json.dumps({"username": "admin", "password": PW}))))
    tok = (json.loads(o).get("data") or {}).get("token")
    AUTH = "-H 'Authorization: Bearer %s'" % tok
    basic = base64.b64encode(("admin:" + PW).encode()).decode()
    BAUTH = "-H 'Authorization: Basic %s'" % basic

    # 等挂载点
    for i in range(60):
        o, _ = sh("curl -s -X POST %s/api/fs/list %s -H 'Content-Type: application/json' --data-binary %s"
                  % (BASE, AUTH, sq(json.dumps({"path": "/"}))))
        try:
            if (json.loads(o).get("data") or {}).get("content"):
                break
        except Exception:
            pass
        time.sleep(2)

    tag = "olz-ua-%d" % int(time.time())
    d = "/115/%s" % tag
    o, _ = sh("curl -s -X POST %s/api/fs/mkdir %s -H 'Content-Type: application/json' --data-binary %s"
              % (BASE, AUTH, sq(json.dumps({"path": d}))))
    print("mkdir:", o[:120])

    # WebDAV PUT 一个小文件
    wp = "/dav%s/w.txt" % d
    o, _ = sh("curl -s -o /dev/null -w 'PUT %%{http_code}\\n' -X PUT %s %s --data-binary 'webdav payload'"
              % (BASE + wp, BAUTH))
    print("webdav put:", o.strip())

    # 三种 UA 带 Range GET
    for label, ua in [("curl-default", "curl/7.81.0"),
                      ("115Browser", UA_115),
                      ("Python-urllib(e2e同款)", "Python-urllib/3.13")]:
        o, _ = sh("curl -s -o /dev/null -D - -w 'BODY%%{size_download}\\n' %s %s "
                  "-H 'Range: bytes=0-4' -H 'User-Agent: %s' | grep -iE '^HTTP/|^content-range|^accept-ranges|^BODY' "
                  % (BASE + wp, BAUTH, ua))
        print("--- %s ---" % label)
        print(o.strip())

    # 清理
    o, _ = sh("curl -s -X POST %s/api/fs/remove %s -H 'Content-Type: application/json' --data-binary %s"
              % (BASE, AUTH, sq(json.dumps({"dir": "/115", "names": [tag]}))))
    print("cleanup:", o[:120])
    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
