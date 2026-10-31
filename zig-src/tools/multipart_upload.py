#!/usr/bin/env python3
"""分片上传（/api/fs/multipart/*）的客户端 —— 大文件真机验收用。

为什么要单独一个脚本：网页端是唯一的分片客户端，而浏览器里没法做
「1 GB 顺序上传 + 逐片进度 + 服务端 RSS 采样」。这个脚本把前端
`Upload-*.js` 的四步（init → chunk → complete → status）按协议手写一遍，
用来验证服务端在**大文件**上的行为（本地零落盘、片大小回写、会话状态机）。

用法：

    # 用配置里的 zig.token 认证，传 1 GiB 到 /ecloud_self
    python tools/multipart_upload.py --config test.json \
        --path /ecloud_self/olz-1g.bin --size 1073741824

    # 传本地文件、传完校验大小并删除
    python tools/multipart_upload.py --base http://192.168.1.1:15399 \
        --token <zig.token> --file big.bin --path /ecloud_self/big.bin --delete-after

设计取舍：

* **顺序发片**（前端是 3 并发）。顺序上传才能让「服务端内存里同时只留一片」
  这条结论成立 —— 并发会把 `pending` 队列填满，测出来的 RSS 不是稳态。
* 片大小**以服务端 init 的 `chunk_size` 为准**（189 会按文件大小回写阶梯值，
  客户端请求的 8 MiB 会被抬到 10 MiB）。
* 正文是**按片现生成**的确定性数据（`i % 251`），不占内存也不落盘，
  所以 1 GiB 也不需要在客户端准备 1 GiB 空间。

⚠ 在 Git Bash 里跑要给 `--path` 关掉 MSYS 路径改写，否则 `/ecloud_self/x.bin`
会被替换成本机路径（服务端只会回一句 `storage not found`）：

    MSYS_NO_PATHCONV=1 python tools/multipart_upload.py --path /ecloud_self/x.bin ...
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

MIB = 1024 * 1024


def _request(base: str, method: str, path: str, token: str,
             headers: dict[str, str] | None = None, body: bytes = b"",
             timeout: float = 300.0):
    h = {"Authorization": token}
    if headers:
        h.update(headers)
    req = urllib.request.Request(base + path, data=body, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def _json(raw: bytes) -> dict:
    try:
        return json.loads(raw.decode())
    except Exception:
        return {"code": -1, "message": raw[:200].decode(errors="replace")}


def _fs_get(base: str, token: str, path: str) -> dict:
    """`/api/fs/get` 是 **POST + JSON body**（Go 的 `handles.FsGet` 同款）。

    用 GET + query 不会报错，但路径会被忽略、退回根目录（size 恒 0）——
    校验就会假失败，别用。
    """
    st, raw = _request(base, "POST", "/api/fs/get", token,
                       {"Content-Type": "application/json"},
                       json.dumps({"path": path}).encode())
    j = _json(raw)
    if st != 200 or j.get("code") != 200:
        raise SystemExit(f"fs/get failed: HTTP {st} {j.get('message') or raw[:200]!r}")
    return j["data"]


def _pattern_chunk(offset: int, length: int) -> bytes:
    """确定性数据：字节值 = 全局偏移 % 251。可用于跨端校验。"""
    return bytes((offset + i) % 251 for i in range(length))


def _file_chunk(path: str, offset: int, length: int) -> bytes:
    with open(path, "rb") as f:
        f.seek(offset)
        data = f.read(length)
    if len(data) != length:
        raise SystemExit(f"short read at {offset}: got {len(data)}, want {length}")
    return data


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://192.168.1.1:15399")
    ap.add_argument("--config", help="读 zig.token 当 Authorization（与 --token 二选一）")
    ap.add_argument("--token")
    ap.add_argument("--path", required=True, help="目标路径，含挂载点，如 /ecloud_self/x.bin")
    ap.add_argument("--size", type=int, help="文件字节数（生成确定性数据）")
    ap.add_argument("--file", help="上传本地文件（与 --size 二选一）")
    ap.add_argument("--chunk-size", type=int, help="建议片大小（服务端可回写更大的）")
    ap.add_argument("--delete-after", action="store_true")
    ap.add_argument("--verify-range", type=int, default=MIB,
                    help="下载首/尾这么多字节比对内容（0 = 跳过）")
    args = ap.parse_args()

    token = args.token
    if not token and args.config:
        token = (json.load(open(args.config)).get("zig") or {}).get("token") or ""
    if not token:
        raise SystemExit("需要 --token 或 --config 里的 zig.token")

    if args.file:
        size = os.path.getsize(args.file)
        reader = lambda off, ln: _file_chunk(args.file, off, ln)  # noqa: E731
    elif args.size:
        size = args.size
        reader = _pattern_chunk
    else:
        raise SystemExit("需要 --size 或 --file")
    if size <= 0:
        raise SystemExit("空文件走 /api/fs/put，不用分片")

    # ---- init ----
    hdr = {
        "File-Path": urllib.parse.quote(args.path),
        "X-File-Size": str(size),
        "Last-Modified": "0",
        "Content-Type": "application/octet-stream",
    }
    if args.chunk_size:
        hdr["X-Chunk-Size"] = str(args.chunk_size)
    st, raw = _request(args.base, "POST", "/api/fs/multipart/init", token, hdr)
    j = _json(raw)
    if st != 200 or j.get("code") != 200:
        print(f"init failed: HTTP {st} {j.get('message') or raw[:200]!r}")
        return 1
    d = j["data"]
    uid = d["upload_id"]
    chunk = int(d["chunk_size"])
    total = int(d["total_chunks"])
    print(f"init ok: upload_id={uid} size={size} chunk={chunk} chunks={total} "
          f"direct={'yes' if d.get('state') else '?'} resumed={j.get('resumed', d.get('resumed'))}")

    # ---- chunks ----
    t0 = time.time()
    done = 0
    for idx in range(total):
        off = idx * chunk
        ln = min(chunk, size - off)
        body = reader(off, ln)
        st, raw = _request(
            args.base, "PUT", "/api/fs/multipart/chunk", token,
            {"X-Upload-Id": uid, "X-Chunk-Index": str(idx),
             "Content-Type": "application/octet-stream"},
            body,
        )
        j = _json(raw)
        if st != 200 or j.get("code") != 200:
            print(f"\nchunk {idx} failed: HTTP {st} {j.get('message') or raw[:200]!r}")
            return 1
        done += ln
        el = max(time.time() - t0, 1e-6)
        pct = done * 100.0 / size
        rate = done / el / MIB
        sys.stdout.write(f"\r  {pct:5.1f}%  {done/MIB:8.1f} / {size/MIB:.1f} MiB  "
                         f"{rate:6.2f} MiB/s")
        sys.stdout.flush()
    print()

    # ---- complete ----
    st, raw = _request(args.base, "POST", "/api/fs/multipart/complete", token,
                       {"X-Upload-Id": uid})
    j = _json(raw)
    if st != 200 or j.get("code") != 200:
        print(f"complete failed: HTTP {st} {j.get('message') or raw[:200]!r}")
        return 1
    print(f"complete ok: state={j['data']['state']} elapsed={time.time()-t0:.1f}s")

    # ---- 校验：大小 + 首尾字节 ----
    info = _fs_get(args.base, token, args.path)
    got_size = info.get("size")
    ok = got_size == size
    print(f"size: server={got_size} local={size} -> {'OK' if ok else 'MISMATCH'}")

    if args.verify_range > 0 and ok:
        url = info.get("raw_url") or ""
        for label, off in (("head", 0), ("tail", size - args.verify_range)):
            ln = min(args.verify_range, size)
            if not url:
                print(f"  {label}: no raw_url, skip")
                continue
            req = urllib.request.Request(url, headers={"Range": f"bytes={off}-{off+ln-1}"})
            with urllib.request.urlopen(req, timeout=180) as r:
                seg = r.read()
            want = reader(off, ln)
            same = hashlib.md5(seg).digest() == hashlib.md5(want).digest()
            print(f"  {label} {ln} bytes: {'OK' if same else 'MISMATCH'}")
            ok = ok and same

    if args.delete_after:
        st, raw = _request(args.base, "POST", "/api/fs/remove", token,
                           {"Content-Type": "application/json"},
                           json.dumps({"dir": os.path.dirname(args.path),
                                       "names": [os.path.basename(args.path)]}).encode())
        print(f"remove: HTTP {st} {raw[:120].decode(errors='replace')}")

    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
