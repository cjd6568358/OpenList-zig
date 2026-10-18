#!/usr/bin/env python3
"""115 Cloud 写闭环专项：延长轮询（每步最长 10 分钟），逐项落日志。

115 的最终一致性是分钟级（§36A.2），全量 e2e 的 60 秒窗口等不到——
本脚本把每步的可见性窗口放宽到 600 秒，把「写闭环能否走通」与
「上游同步快慢」分开回答。
"""
import json
import sys
import time
import urllib.error
import urllib.request

BASE = "http://192.168.1.1:15399"
WINDOW = 600  # 每步可见性窗口（秒）


def raw(path, data=None, headers=None, method=None):
    r = urllib.request.Request(BASE + path, data=data, headers=dict(headers or {}),
                               method=method or ("POST" if data is not None else "GET"))
    try:
        with urllib.request.urlopen(r, timeout=90) as resp:
            return resp.status, resp.read(), dict(resp.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def call(path, body=None, token=None, raw_body=None, headers=None):
    data = raw_body if raw_body is not None else (json.dumps(body).encode() if body is not None else None)
    h = dict(headers or {})
    if raw_body is None and data is not None:
        h.setdefault("Content-Type", "application/json")
    if token:
        h["Authorization"] = "Bearer " + token
    st, b, hd = raw(path, data, h)
    try:
        return st, json.loads(b or b"{}"), hd
    except Exception:
        return st, b, hd


def wait_visible(tok, path, name, label):
    t0 = time.time()
    while time.time() - t0 < WINDOW:
        st, j, _ = call("/api/fs/list", {"path": path}, token=tok)
        names = [x["name"] for x in (j.get("data", {}) or {}).get("content", [])]
        if name in names:
            print("  ✅ %s（%.0f 秒后可见）" % (label, time.time() - t0))
            return True
        time.sleep(15)
    print("  ⏳ %s：%d 秒仍不可见（115 上游未同步）" % (label, WINDOW))
    return False


def main():
    st, j, _ = call("/api/auth/login", {"username": "admin", "password": "e2e-test-123456"})
    tok = j["data"]["token"]
    d0 = "/115/olz-closure-%d" % time.time()
    results = []

    def step(name, ok):
        results.append((name, ok))
        print("%s %s" % ("✅" if ok else "❌", name))

    print("== 115 写闭环（窗口 %ds）== " % WINDOW)
    st, j, _ = call("/api/fs/mkdir", {"path": d0}, token=tok)
    ok = j.get("code") == 200
    step("mkdir 请求", ok)
    ok = wait_visible(tok, "/115", d0.split("/")[-1], "目录可见")
    step("mkdir 可见", ok)
    if not ok:
        report(results)
        return

    content = ("closure-%d\n" % time.time()).encode()
    st, j, _ = call("/api/fs/put", token=tok, raw_body=content,
                    headers={"File-Path": d0 + "/a.txt", "Content-Type": "application/octet-stream"})
    step("上传请求", j.get("code") == 200)
    ok = wait_visible(tok, d0, "a.txt", "上传可见")
    step("上传可见", ok)

    if ok:
        st, j, _ = call("/api/fs/rename", {"path": d0 + "/a.txt", "name": "b.txt"}, token=tok)
        step("重命名请求", j.get("code") == 200)
        ok = wait_visible(tok, d0, "b.txt", "重命名可见")
        step("重命名可见", ok)
        st, j, _ = call("/api/fs/mkdir", {"path": d0 + "/sub"}, token=tok)
        wait_visible(tok, d0, "sub", "sub 可见")
        st, j, _ = call("/api/fs/move", {"src_dir": d0, "dst_dir": d0 + "/sub", "names": ["b.txt"]}, token=tok)
        step("移动请求", j.get("code") == 200)
        ok = wait_visible(tok, d0 + "/sub", "b.txt", "移动可见")
        step("移动可见", ok)
        # 下载走 /d/（sign）
        st, j, _ = call("/api/fs/get", {"path": d0 + "/sub/b.txt"}, token=tok)
        sign = (j.get("data", {}) or {}).get("sign") or ""
        if sign:
            st, b, _ = raw("/d" + d0 + "/sub/b.txt?sign=" + sign)
            step("下载回读字节一致", st == 200 and b == content)
        else:
            step("下载回读字节一致", False)
        st, j, _ = call("/api/fs/remove", {"dir": d0 + "/sub", "names": ["b.txt"]}, token=tok)
        step("删除文件请求", j.get("code") == 200)
    st, j, _ = call("/api/fs/remove", {"dir": "/115", "names": [d0.split("/")[-1]]}, token=tok)
    step("清理目录请求", j.get("code") == 200)
    report(results)


def report(results):
    ok = sum(1 for _, x in results if x)
    print("\n== 汇总：%d/%d ==" % (ok, len(results)))
    for n, x in results:
        if not x:
            print("  未达成:", n)


if __name__ == "__main__":
    main()
