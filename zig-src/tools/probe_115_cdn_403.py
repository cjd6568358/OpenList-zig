"""115 CDN 403 归因对照：刚上传的文件 vs 老文件。

上一实验：WebDAV PUT 后立刻 GET（带/不带 Range）⇒ cdnfhnfile.115cdn.net
403 Forbidden（纯文本）。假设：115 最终一致性 —— 新上传文件列表即时可见、
但 CDN 分发未就绪，直链 403；老文件不受影响。

对照：同一挂载点、同一代理路径，GET 一个 20 分钟前上传的文件。
老文件 200/206 + 新文件 403 ⇒ 上游同步延迟，Go 同样会中招
（e2e 的 PUT→GET 序列本身在跟上游赛跑）。
"""
import base64
import json
import sys
import time

import paramiko

HOST, PORT, USER, PWD = "192.168.1.1", 10022, "root", "REDACTED"
BASE = "http://127.0.0.1:15399"
PW = "e2e-test-123456"
UA_115 = "Mozilla/5.0 115Browser/35.6.0.3"
OLD_FILE = "/dav/115/olz-diag-1792295204-root.txt"  # 04:00 上传，已 15+ 分钟


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

    # 老文件：普通 GET + Range GET
    for label, extra in [("老文件 plain GET", ""), ("老文件 Range GET", "-H 'Range: bytes=0-4'")]:
        o, _ = sh("curl -s -o /dev/null -D - -w 'BODY%%{size_download}\\n' %s %s -H 'User-Agent: %s' %s "
                  "| grep -iE '^HTTP/|^content-range|^accept-ranges|^content-type|^BODY'"
                  % (BASE + OLD_FILE, BAUTH, UA_115, extra))
        print("--- %s ---" % label)
        print(o.strip())

    # 新文件：建目录 → WebDAV PUT → 立即 GET（复现 e2e 序列）
    tag = "olz-ua3-%d" % int(time.time())
    d = "/115/%s" % tag
    sh("curl -s -X POST %s/api/fs/mkdir %s -H 'Content-Type: application/json' --data-binary %s"
       % (BASE, AUTH, sq(json.dumps({"path": d}))))
    wp = "/dav%s/w.txt" % d
    sh("curl -s -o /dev/null -w 'PUT %%{http_code}\\n' -X PUT %s %s --data-binary 'webdav payload'"
       % (BASE + wp, BAUTH))
    for label, extra in [("新文件 立即 plain GET", ""), ("新文件 立即 Range GET", "-H 'Range: bytes=0-4'")]:
        o, _ = sh("curl -s -o /dev/null -D - -w 'BODY%%{size_download}\\n' %s %s -H 'User-Agent: %s' %s "
                  "| grep -iE '^HTTP/|^content-range|^BODY'"
                  % (BASE + wp, BAUTH, UA_115, extra))
        print("--- %s ---" % label)
        print(o.strip())

    # 等 60 秒后再试新文件
    print("等待 60 秒（115 CDN 同步窗口）…")
    time.sleep(60)
    for label, extra in [("新文件 60s后 plain GET", ""), ("新文件 60s后 Range GET", "-H 'Range: bytes=0-4'")]:
        o, _ = sh("curl -s -o /dev/null -D - -w 'BODY%%{size_download}\\n' %s %s -H 'User-Agent: %s' %s "
                  "| grep -iE '^HTTP/|^content-range|^BODY'"
                  % (BASE + wp, BAUTH, UA_115, extra))
        print("--- %s ---" % label)
        print(o.strip())

    o, _ = sh("curl -s -X POST %s/api/fs/remove %s -H 'Content-Type: application/json' --data-binary %s"
              % (BASE, AUTH, sq(json.dumps({"dir": "/115", "names": [tag]}))))
    print("cleanup:", o[:120])
    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
