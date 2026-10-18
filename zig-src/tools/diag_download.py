#!/usr/bin/env python3
"""复现夸克下载失败并抓取阶段级日志。

流程：登录 -> fs/get 拿 sign -> GET /d/quark/sn.img?sign=... -> 从设备
run.log 提取这次请求的阶段日志（connected / sending bodiless /
request sent / receiveHead failed / got head），定位 WriteFailed
发生在哪一级。
"""
import json
from creds import root_pwd as _root_pwd
import sys
import urllib.request
import urllib.error

import paramiko

BASE = "http://192.168.1.1:15399"
USER, PASSWORD = "admin", "OlzDiag#2026"
MOUNT = "/quark"


def call(path, method="GET", token=None, body=None, headers=None, timeout=90):
    url = BASE + path
    data = json.dumps(body).encode() if body is not None else None
    hdrs = dict(headers or {})
    if data:
        hdrs["Content-Type"] = "application/json"
    if token:
        hdrs["Authorization"] = "Bearer " + token
    r = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)
    except Exception as e:
        return -1, str(e).encode(), {}


def main():
    st, txt, _ = call("/api/auth/login", "POST",
                     body={"username": USER, "password": PASSWORD})
    tok = (json.loads(txt).get("data") or {}).get("token")
    print("login:", st, "token:", bool(tok))
    if not tok:
        return 1

    # 列 /quark，挑 sn.img（历史失败样本）
    st, txt, _ = call("/api/fs/list", token=tok,
                      body={"path": MOUNT, "page": 1, "per_page": 100})
    names = [o["name"] for o in (json.loads(txt).get("data", {}) or {}).get("content", [])]
    print("list /quark:", st, len(names), "条:", names[:8])
    fname = "sn.img" if "sn.img" in names else next(
        (o["name"] for o in json.loads(txt)["data"]["content"] if not o["is_dir"]), None)
    if not fname:
        print("没有可下载文件")
        return 1

    target = MOUNT + "/" + fname
    st, txt, _ = call("/api/fs/get", token=tok, body={"path": target})
    d = (json.loads(txt).get("data") or {})
    sign = d.get("sign") or ""
    print("fs/get:", st, "size=%s sign=%s..." % (d.get("size"), sign[:24]))
    if not sign:
        print("没有 sign（sign_all 未开？）—— 仍试 token 下载")
        dl = "/d" + target
        tok_arg = tok
    else:
        dl = "/d" + target + "?sign=" + sign
        tok_arg = None

    print("触发下载（最长等 90s）:", dl[:80], "...")
    st, body, _ = call(dl, token=tok_arg, timeout=90)
    print("下载结果: HTTP %d, %d 字节" % (st, len(body)))
    if 200 <= st < 300 and len(body) > 0:
        print("*** 下载成功！夸克 CDN 放行了本次请求 ***")
        return 0

    # 抓设备日志
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("192.168.1.1", port=10022, username="root", password=_root_pwd(),
              timeout=20, look_for_keys=False, allow_agent=False)
    _, o, e = c.exec_command("cat /tmp/olz/run.log", timeout=30)
    log = o.read().decode(errors="replace")
    c.close()

    # 只打印与本次下载相关的行：client 阶段日志 + 最后的失败行
    lines = log.splitlines()
    keep = [l for l in lines if l.startswith("[INFO ] client:") or "failed" in l]
    print("\n--- run.log 阶段日志（最后 25 条相关行） ---")
    for l in keep[-25:]:
        print(l[:400])
    return 0 if st in (200, 206) else 2


if __name__ == "__main__":
    sys.exit(main())
