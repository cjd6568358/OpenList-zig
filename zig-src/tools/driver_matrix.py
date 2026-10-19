#!/usr/bin/env python3
"""驱动覆盖测试：12 个注册驱动逐个过「添加 → init → 状态 → 删除」闭环。

背景（用户 2026-10-17 要求"每个驱动都要测上传/下载/删除/添加"）：
  * 有真实凭据并挂载的驱动，走 `tools/e2e_test.py`（全操作矩阵 + 云盘写）；
  * 本脚本不依赖真凭据：「添加」这条链路用哑凭据创建，期望**优雅失败**
    （HTTP 200 + code 500 的信封、"failed init storage but storage is
    already created"、行保留 + error_msg），再删掉。崩溃 / 挂死 / 整行消失
    才是真缺陷。
  * **覆盖现状（2026-10-18）**：12 个注册驱动已全部真机覆盖（含 UC / 115 Cloud /
    WoPan / 189Cloud web，见 STATUS §36A/§36B/§36.2），所以本脚本现在的定位是
    「无凭据回归」：注册表完整性 + 表单字段 + 哑凭据添加闭环，改驱动注册/表单
    时先跑它，不必碰真实账号。

为什么在创建后要等：`create` 是"先建行再 init"，init 是异步的（它就是
真机回归里那个"created but errored"路径，Go 同款语义）。

用法：
    python tools/driver_matrix.py --base http://192.168.1.1:15399 \
        --user admin --password e2e-test-123456
"""
import argparse
import base64
import json
import sys
import time
import urllib.error
import urllib.request

PASS, FAIL = [], []

# 哑凭据：只要能触发一次真实上游请求（→ 优雅的 init 失败）即可。
DUMMY = {
    "189Cloud":  {"username": "13800000000", "password": "olz-dummy-password"},
    "UC":        {"cookie": "__pus=olz-dummy; __puus=olz-dummy"},
    "115 Cloud": {"cookie": "UID=olz_dummy; CID=olz_dummy; SEID=olz_dummy; KID=olz_dummy"},
    "WoPan":     {"refresh_token": "olz-dummy-refresh-token"},
}


def req(base, path, *, method="GET", token=None, body=None, headers=None, retries=3):
    data = None
    hdrs = dict(headers or {})
    if body is not None:
        data = json.dumps(body).encode()
        hdrs.setdefault("Content-Type", "application/json")
    if token:
        hdrs["Authorization"] = "Bearer " + token
    r = urllib.request.Request(base + path, data=data, method=method, headers=hdrs)
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(r, timeout=60) as resp:
                payload = resp.read()
                return resp.status, json.loads(payload or b"{}")
        except urllib.error.HTTPError as e:
            payload = e.read()
            try:
                return e.code, json.loads(payload or b"{}")
            except Exception:
                return e.code, {"_raw": payload.decode(errors="replace")[:200]}
        except (ConnectionError, TimeoutError, OSError):
            # 本机到光猫走 easytier 隧道，relay 对大响应偶发 RST（见
            # STATUS §34：loopback 对照 15/15 全过 ⇒ 链路抖动，非服务端问题）。
            if attempt == retries:
                raise
            time.sleep(1.5)


def check(name, ok, detail=""):
    (PASS if ok else FAIL).append(name)
    print("  %s %-44s %s" % ("✅" if ok else "❌", name, detail))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", required=True)
    args = ap.parse_args()

    st, j = req(args.base, "/api/auth/login",
                method="POST", body={"username": args.user, "password": args.password})
    if j.get("code") != 200:
        print("登录失败:", j)
        return 2
    tok = j["data"]["token"]

    # ---- 1) 注册表完整性：编译进二进制的驱动清单 ----
    st, j = req(args.base, "/api/admin/driver/names", token=tok)
    names = j.get("data") or []
    print("=== 1. 注册表（/api/admin/driver/names）===")
    check("驱动清单非空", bool(names), "%d 个" % len(names))
    expect = {"Local", "WebDav", "Itvsh", "AliyundriveOpen", "189Cloud",
              "189CloudPC", "123Pan", "Quark", "UC", "115 Cloud", "WoPan", "Strm"}
    missing = expect - set(names)
    check("12 个注册驱动齐全", not missing, "缺: %s" % (sorted(missing) or "无"))

    # ---- 2) 逐驱动表单：/api/admin/driver/info 必须能渲染 ----
    print("\n=== 2. 驱动表单（admin/driver/info）===")
    for drv in sorted(expect):
        st, j = req(args.base, "/api/admin/driver/info?driver=" + urllib.request.quote(drv),
                    token=tok)
        ok = j.get("code") == 200 and (j.get("data") or {}).get("common") is not None
        check("表单 %s" % drv, ok, str(j.get("message", ""))[:40])

    # ---- 3) 无凭据驱动：哑凭据走「添加 → 优雅失败 → 删除」闭环 ----
    print("\n=== 3. 无凭据驱动：添加闭环（哑凭据 ⇒ 优雅失败）===")
    for drv, add in DUMMY.items():
        mp = "/olz-drvtest-%s" % drv.replace(" ", "").lower()
        st, j = req(args.base, "/api/admin/storage/create", method="POST",
                    token=tok, body={"mount_path": mp, "driver": drv,
                                     "addition": json.dumps(add, ensure_ascii=False)})
        # Go 语义：行**先建**，init 失败 ⇒ 200 信封 + code 500 + data.id（前端
        # 据此跳编辑页）；不删除行。
        ok = j.get("code") == 500 and "already created" in str(j.get("message", ""))
        check("%s 添加（哑凭据 → 优雅失败）" % drv, ok,
              "code=%s msg=%s" % (j.get("code"), str(j.get("message", ""))[:60]))
        sid = (j.get("data") or {}).get("id")

        time.sleep(4)
        st, j = req(args.base, "/api/admin/storage", token=tok)
        row = next((s for s in (j.get("data", {}) or {}).get("content", [])
                    if s["mount_path"] == mp), None)
        check("%s 行保留且 errored" % drv,
              bool(row) and row["status"] == "errored" and bool(row.get("error_msg")),
              "status=%s error_msg=%s" % (row and row["status"],
                                          row and str(row.get("error_msg"))[:40]))

        st, j = req(args.base, "/api/admin/storage/delete?id=%s" % sid, method="POST", token=tok)
        check("%s 删除" % drv, j.get("code") == 200, str(j.get("message", ""))[:40])

    print("\n=== 汇总 ===")
    print("通过 %d，失败 %d" % (len(PASS), len(FAIL)))
    for f in FAIL:
        print("  ❌ " + f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
