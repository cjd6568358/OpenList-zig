"""115 put 现场复现：在设备本机 loopback 上完整走 e2e 的上传流程，
抓 /api/fs/put 的完整响应体 + run.log 里的 [115-diag] 诊断行。

背景：e2e「上传 a.txt HTTP 200」但目录里没有 a.txt；手动探针曾见到
`{"code":500,"message":"InvalidResponse"}`（HTTP 200 信封），且 put 的
diag 日志没打出来 ⇒ 失败在 rapidUpload 之前。本脚本把「哪一步、什么错」
钉死。

用法： python tools/probe_115_put.py
"""
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

    def sh(cmd, timeout=180):
        _, out, err = c.exec_command(cmd, timeout=timeout)
        o = out.read().decode(errors="replace")
        e = err.read().decode(errors="replace")
        return o, e, out.channel.recv_exit_status()

    def curl(args, body=None):
        # 单引号包住整体，内部 JSON 的双引号原样传（远程 shell 是 busybox ash）
        cmd = "curl -s " + args
        if body is not None:
            cmd += " --data-binary " + _sq(body)
        o, e, rc = sh(cmd)
        if rc != 0:
            print("curl rc=%d stderr=%s" % (rc, e[:200]))
        return o

    def _sq(s):
        return "'" + s.replace("'", "'\\''") + "'"

    # 记录日志位置，之后只取增量
    o, _, _ = sh("wc -c < /tmp/olz/run.log")
    mark = int(o.strip())
    print("run.log mark = %d bytes" % mark)

    # 登录
    o = curl("-X POST %s/api/auth/login -H 'Content-Type: application/json' --data-binary %s"
             % (BASE, _sq(json.dumps({"username": "admin", "password": PW}))))
    tok = (json.loads(o).get("data") or {}).get("token")
    if not tok:
        print("LOGIN FAILED: %s" % o[:300])
        return 1
    AUTH = "-H 'Authorization: Bearer %s'" % tok
    print("login ok")

    # 等挂载点发布（重启后 12 个存储 init 要数秒~数十秒，2026-10-18 教训）
    for i in range(60):
        o = curl("-X POST %s/api/fs/list %s -H 'Content-Type: application/json' --data-binary %s"
                 % (BASE, AUTH, _sq(json.dumps({"path": "/"}))))
        try:
            mounts = [x["name"] for x in (json.loads(o).get("data") or {}).get("content", [])]
            if mounts:
                print("mounts ready (%d): %s" % (len(mounts), ",".join(sorted(mounts))))
                break
        except Exception:
            pass
        time.sleep(2)
    else:
        print("mounts not ready after 120s: %s" % o[:200])

    # 当前 /115 根列表
    o = curl("-X POST %s/api/fs/list %s -H 'Content-Type: application/json' --data-binary %s"
             % (BASE, AUTH, _sq(json.dumps({"path": "/115", "page": 1, "per_page": 100}))))
    try:
        j = json.loads(o)
        content = (j.get("data") or {}).get("content") or []
        print("/115 entries: %d" % len(content))
        for e in content:
            print("   %s %s" % ("d" if e.get("is_dir") else "-", e.get("name")))
    except Exception as ex:
        print("/115 list parse fail: %s / %s" % (ex, o[:200]))

    # 完整走一遍 e2e 上传流程
    tag = "olz-diag-%d" % int(time.time())
    d = "/115/%s" % tag
    o = curl("-X POST %s/api/fs/mkdir %s -H 'Content-Type: application/json' --data-binary %s"
             % (BASE, AUTH, _sq(json.dumps({"path": d}))))
    print("mkdir %s -> %s" % (d, o[:200]))

    content = b"openlist-zig e2e payload\n"
    o = curl("-X PUT %s/api/fs/put %s -H 'File-Path: %s/a.txt'" % (BASE, AUTH, d),
             body=content.decode())
    print("PUT /api/fs/put -> %s" % o[:500])

    # 列临时目录，看 a.txt 是否落地
    o = curl("-X POST %s/api/fs/list %s -H 'Content-Type: application/json' --data-binary %s"
             % (BASE, AUTH, _sq(json.dumps({"path": d, "page": 1, "per_page": 100}))))
    print("list %s -> %s" % (d, o[:300]))

    # 再试一次：根目录直接放一个文件（parent=root，只 walk 一层）
    o = curl("-X PUT %s/api/fs/put %s -H 'File-Path: /115/%s-root.txt'" % (BASE, AUTH, tag),
             body=content.decode())
    print("PUT root-level -> %s" % o[:500])

    # 抓日志增量
    o, _, _ = sh("tail -c +%d /tmp/olz/run.log" % (mark + 1))
    print("\n--- run.log delta (%d bytes) ---" % len(o))
    for line in o.splitlines():
        if "115" in line or "diag" in line:
            print(line[:400])

    # 清理：删临时目录 + 根级探针文件
    o = curl("-X POST %s/api/fs/remove %s -H 'Content-Type: application/json' --data-binary %s"
             % (BASE, AUTH, _sq(json.dumps({"dir": "/115", "names": [tag]}))))
    print("cleanup dir -> %s" % o[:150])
    o = curl("-X POST %s/api/fs/remove %s -H 'Content-Type: application/json' --data-binary %s"
             % (BASE, AUTH, _sq(json.dumps({"dir": "/115", "names": [tag + "-root.txt"]}))))
    print("cleanup root file -> %s" % o[:150])

    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
