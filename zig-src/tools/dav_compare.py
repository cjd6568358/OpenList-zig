#!/usr/bin/env python3
"""WebDAV 响应头动态对照：光猫本机 loopback 上同时问生产 Go(15244) 与本工程(15399)。

为什么必须在**设备本机**上跑：PC 到光猫的路由走 easytier 隧道，大响应会
被 relay RST（2026-10-17 抓包定位，非实现问题），loopback 干净。

问的是 127.0.0.1，所以两个实例都拿不到对方的存储状态差异影响 —— 只比较
**不需要登录**的两类响应：

  1. OPTIONS（WebDAV 能力宣告）：上游 WebDAVAuth 对 OPTIONS 放行 guest，
     所以不需要凭据。比的是 DAV / Allow / MS-Author-Via 三个头 + 状态码。
  2. PROPFIND（未鉴权）：比 401 的 WWW-Authenticate realm 与正文长度。

要比较需要登录的语义（GET/PUT/MKCOL/MOVE/DELETE/Range/304），用
`tools/e2e_test.py`（那里有凭据，且断言写成了可回归的检查项）。

用法：
    python tools/dav_compare.py <mount>          # 例：hikvision
    python tools/dav_compare.py --list           # 只打印两边各自的头，不比较
"""
import sys

import deploy_device as dev

GO = "http://127.0.0.1:15244"      # 生产 Go（user_init 拉起）
ZIG = "http://127.0.0.1:15399"     # 本工程测试实例（/tmp/olz）


def curl(c, url, method, extra=()):
    """在设备上发一个请求，返回 (状态码, 原始响应头文本)。"""
    cmd = ("curl -sS -o /dev/null -D - -X %s %s %s" %
           (method, " ".join(extra), shell_q(url)))
    out = dev.sh(c, cmd)
    if "HTTP/" not in out:
        return None, out.strip()
    return parse_headers(out), out.strip()


def shell_q(s):
    return "'" + s.replace("'", "'\\''") + "'"


def parse_headers(raw):
    """把 `curl -D -` 的输出解析成 (状态行, {头名: 值})。"""
    lines = raw.replace("\r\n", "\n").split("\n")
    status = lines[0].strip() if lines else ""
    hdrs = {}
    for ln in lines[1:]:
        if not ln.strip() or ":" not in ln:
            continue
        k, v = ln.split(":", 1)
        hdrs[k.strip().lower()] = v.strip()
    return status, hdrs


def show(tag, status, hdrs, keys):
    print("  %-4s %s" % (tag, status))
    for k in keys:
        v = hdrs.get(k)
        if v is not None:
            print("       %-16s %s" % (k, v))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    mount = sys.argv[1].lstrip("/")
    c = dev.connect()

    print("=== OPTIONS /dav/%s（无需鉴权，两边都能问）===" % mount)
    g = curl(c, GO + "/dav/" + mount, "OPTIONS")
    z = curl(c, ZIG + "/dav/" + mount, "OPTIONS")
    keys = ["dav", "allow", "ms-author-via", "content-type"]
    for tag, r in (("Go", g), ("Zig", z)):
        show(tag, r[0][0] if r[0] else "(curl 失败: %s)" % r[1], r[0][1] if r[0] else {}, keys)
    if g[0] and z[0]:
        for k in keys:
            gv, zv = g[0][1].get(k), z[0][1].get(k)
            flag = "OK  " if gv == zv else "DIFF"
            print("  %s %-16s Go=%r Zig=%r" % (flag, k, gv, zv))

    print("\n=== PROPFIND /dav （未鉴权 → 401）===")
    for tag, base in (("Go", GO), ("Zig", ZIG)):
        c2 = curl(c, base + "/dav", "PROPFIND", ["-H", shell_q("Depth: 1")])
        if c2[0]:
            show(tag, c2[0][0], c2[0][1], ["www-authenticate", "content-type", "content-length"])
        else:
            print("  %s 请求失败: %s" % (tag, c2[1]))
    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
