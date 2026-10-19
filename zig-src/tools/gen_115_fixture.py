#!/usr/bin/env python3
"""生成 src/drivers/115list_fixture.json —— pan115.zig P115-REG 单测的脱敏 fixture。

背景（2026-10-18 真机事故）：线上 fs/list /115 返回**空** content，而同 cookie、
同 URL 的 curl 直打有内容。单测要钉住
    json.parse -> basicOk -> arrAt("data") -> entryFrom
这条解析链路，就需要一份**入库**的响应体。真机原文（115list_sample.json）含真实
文件名/ID，按 gitignore 规则不能入库；CI 的 `zig build test` 在新克隆上又会因
@embedFile 缺文件而编译失败（该失败曾被 `| tail` 掩盖）。

本脚本自包含：不读任何真机样本，按真机原文的 schema（键集合、顺序、类型、条目
构成）合成全假数据，产出确定性 fixture：

- 顶层 39 键：state=true / errNo=0 / error="" / count == len(data)
- 目录条目 31 键（无 fid 键）：entryFrom 走 cid 分支 -> is_dir
- 文件条目 41 键（fid 非空）：走 fid 分支 -> is_dir=false
- 7 目录 + 7 文件 = 14 条（对齐真机原文的条目构成）

用法：
    python3 tools/gen_115_fixture.py            # 写 src/drivers/115list_fixture.json
    python3 tools/gen_115_fixture.py --check    # 只校验 schema，不写文件
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "src", "drivers", "115list_fixture.json")

AID_STR = "3100000000000000001"   # 目录条目里 aid 是字符串
AID_INT = 3100000000000000001     # 文件条目里 aid 是整数（真机原文即为两种类型）
UID = 900000001
ROOT_CID = "0"

# 顶层键集合与顺序（39 键，对齐真机原文）
TOP_KEYS = [
    "data", "count", "sys_count", "page_size", "aid", "cid", "is_asc", "star",
    "is_share", "type", "is_q", "r_all", "stdir", "cur", "min_size", "max_size",
    "record_open_time", "path", "fields", "order", "fc_mix", "cost_time_1",
    "natsort", "uid", "offset", "limit", "suffix", "last_utime", "use_cache",
    "cost_time_2", "cost_time_3", "cost_time_4", "cost_time_5", "cost_time_6",
    "cost_time_7", "cost_time_8", "state", "error", "errNo",
]
# 目录条目键集合与顺序（31 键，无 fid）
DIR_KEYS = [
    "cid", "aid", "pid", "n", "m", "star_time", "cc", "sh", "pc", "t", "te",
    "tu", "tp", "to", "e", "p", "ns", "u", "fc", "fdes", "hdf", "ispl", "fvs",
    "check_code", "check_msg", "fuuid", "ec", "fl", "issct", "score", "is_top",
]
# 文件条目键集合与顺序（41 键，fid 非空）
FILE_KEYS = [
    "fid", "uid", "aid", "cid", "n", "s", "sta", "pt", "pc", "fc", "p", "m",
    "star_time", "t", "te", "tp", "tu", "to", "d", "c", "sh", "e", "ico",
    "class", "fatr", "fdes", "sha", "q", "hdf", "et", "epos", "fvs",
    "check_code", "check_msg", "fuuid", "ec", "fl", "u", "issct", "score",
    "is_top",
]
# path[] 内层条目键集合与顺序（5 键）
PATH_KEYS = ["name", "aid", "cid", "pid", "isp"]

N_DIRS = 7
N_FILES = 7


def dir_entry(k: int) -> dict:
    """第 k 个（1 起）合成目录条目：值全假，类型与真机原文逐键一致。"""
    return {
        "cid": f"93{k:017d}",            # 19 位数字串，形似真机 cid 但全假
        "aid": AID_STR,
        "pid": ROOT_CID,
        "n": f"合成目录-{k:02d}",
        "m": 0,
        "star_time": 0,
        "cc": "",
        "sh": "0",
        "pc": "",
        "t": str(1760000000 + k * 86400),  # 目录 t 是 unix 时间戳的**字符串**
        "te": "",
        "tu": str(1789000000 + k * 3600),
        "tp": "",
        "to": 0,
        "e": "",
        "p": 0,
        "ns": "",
        "u": "",
        "fc": 0,
        "fdes": 0,
        "hdf": 0,
        "ispl": 0,
        "fvs": 0,
        "check_code": 0,
        "check_msg": "",
        "fuuid": 0,
        "ec": 0,
        "fl": [],
        "issct": 0,
        "score": 0,
        "is_top": 0,
    }


def file_entry(k: int) -> dict:
    """第 k 个（1 起）合成文件条目：fid 非空 -> entryFrom 走文件分支。"""
    ext = ("bin", "txt", "jpg", "mp4", "zip", "pdf", "iso", "md")[k - 1]
    return {
        "fid": f"35{k:017d}",             # 19 位数字串，全假
        "uid": UID,
        "aid": AID_INT,                   # 注意：文件条目 aid 是整数
        "cid": ROOT_CID,
        "n": f"合成文件-{k:02d}.{ext}",
        "s": 1024 * k + 2048,             # 非零体积，pin 住 size 解析
        "sta": 1,
        "pt": "",
        "pc": "",
        "fc": 0,
        "p": 0,
        "m": 0,
        "star_time": 0,
        "t": f"2026-10-17 {k:02d}:13",    # 文件 t 是 "YYYY-MM-DD HH:MM" 字符串
        "te": "",
        "tp": "",
        "tu": f"2026-10-17 {k:02d}:13",
        "to": 0,
        "d": 0,
        "c": 0,
        "sh": 1,
        "e": f".{ext}",
        "ico": "",
        "class": "0",
        "fatr": "0",
        "fdes": 0,
        "sha": f"{k:040x}",               # 40 位十六进制串，全假
        "q": 0,
        "hdf": 0,
        "et": 0,
        "epos": "",
        "fvs": 0,
        "check_code": 0,
        "check_msg": "",
        "fuuid": 0,
        "ec": 0,
        "fl": [],
        "u": "",
        "issct": 0,
        "score": 0,
        "is_top": 0,
    }


def build() -> dict:
    data = [dir_entry(k) for k in range(1, N_DIRS + 1)]
    data += [file_entry(k) for k in range(1, N_FILES + 1)]
    top = {
        "data": data,
        "count": len(data),
        "sys_count": len(data),
        "page_size": 1000,
        "aid": AID_STR,
        "cid": 0,
        "is_asc": 0,
        "star": 0,
        "is_share": 0,
        "type": 0,
        "is_q": 0,
        "r_all": 0,
        "stdir": 1,
        "cur": 1,
        "min_size": 0,
        "max_size": 0,
        "record_open_time": "2026-10-18 12:00:00",
        "path": [{"name": "合成根目录", "aid": AID_STR, "cid": ROOT_CID,
                  "pid": ROOT_CID, "isp": "0"}],
        "fields": "fid,n,pc,t,m,sha,s",
        "order": "file_name",
        "fc_mix": 0,
        "cost_time_1": 0.001,
        "natsort": 1,
        "uid": UID,
        "offset": 0,
        "limit": 1000,
        "suffix": "",
        "last_utime": 0,
        "use_cache": 1,
        "cost_time_2": 0.002,
        "cost_time_3": 0.003,
        "cost_time_4": 0.004,
        "cost_time_5": 0.005,
        "cost_time_6": 0.006,
        "cost_time_7": 0.007,
        "cost_time_8": 0.008,
        "state": True,
        "error": "",
        "errNo": 0,
    }
    return top


def check(doc: dict) -> int:
    bad = []
    if list(doc.keys()) != TOP_KEYS:
        bad.append(f"top-level key order mismatch: {list(doc.keys())}")
    for i, item in enumerate(doc["data"]):
        want = DIR_KEYS if i < N_DIRS else FILE_KEYS
        if list(item.keys()) != want:
            bad.append(f"data[{i}] key order mismatch: {list(item.keys())}")
    if list(doc["path"][0].keys()) != PATH_KEYS:
        bad.append("path[0] key order mismatch")
    if doc["count"] != len(doc["data"]):
        bad.append("count != len(data)")
    n_dir = sum(1 for it in doc["data"] if "fid" not in it)
    n_file = sum(1 for it in doc["data"] if it.get("fid"))
    if (n_dir, n_file) != (N_DIRS, N_FILES):
        bad.append(f"entry mix {n_dir}dir+{n_file}file != {N_DIRS}+{N_FILES}")
    for b in bad:
        print("FAIL:", b)
    return 1 if bad else 0


def main() -> int:
    doc = build()
    rc = check(doc)
    if "--check" in sys.argv:
        print("schema OK" if rc == 0 else "schema FAILED")
        return rc
    if rc != 0:
        print("refusing to write: schema check failed")
        return rc
    # 紧凑单行：贴近真机响应体原文形态；解析不关心格式。
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"wrote {OUT} ({os.path.getsize(OUT)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
