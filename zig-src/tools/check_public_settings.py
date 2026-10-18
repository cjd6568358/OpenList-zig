"""Diff the Zig public-settings table against the upstream Go source of truth.

Why this exists: `GET /api/public/settings` is built from a hand-maintained
table in `src/api.zig` (`public_setting_defaults`). Upstream keeps the same
data in `internal/bootstrap/data/setting.go`, and it *does* change — the
`sso_postmessage_origin` key was added upstream and silently went missing here,
which is exactly the class of drift this script is meant to catch.

Usage (from the repo root of the Go tree, i.e. the parent of zig-src):

    python zig-src/tools/check_public_settings.py [--rev origin/main]

Exit code 0 when the key sets and defaults match, 1 otherwise. The `version`
key is exempted: upstream fills it from a build-time variable.
"""
import re
import subprocess
import sys

GO_ROOT = "D:/workspace/OpenList-zig"
ZIG_API = GO_ROOT + "/zig-src/src/api.zig"
# `version` is filled from a build-time variable upstream, so there is no
# constant to compare against.
EXEMPT = {"version"}
# Differences that are **deliberate and documented**, each with the reason.
# Anything not listed here and not matching upstream is a bug worth fixing.
DELIBERATE = {
    "announcement": (
        "上游默认是欢迎语，Zig 有意留空：本工程没有前台入口编辑公告，"
        "加回来用户会看到一段删不掉的文案（docs/STATUS.md §13.2）"
    ),
}


def git_show(rev_path):
    r = subprocess.run(["git", "show", rev_path], capture_output=True, cwd=GO_ROOT)
    if r.returncode != 0:
        sys.exit(f"cannot read {rev_path} from {GO_ROOT}: {r.stderr.decode()[:200]}")
    return r.stdout.decode("utf-8", "replace")


def skip_string(src, i):
    """src[i] is a quote/raw-quote opener; return the index just past it."""
    q = src[i]
    i += 1
    while i < len(src):
        if src[i] == "\\":
            i += 2
            continue
        if src[i] == q:
            return i + 1
        i += 1
    return len(src)


def scan_entries(src, start):
    """Every `{Key: ...}` struct literal from `start`, with brace matching."""
    out, i, n = [], start, len(src)
    while i < n:
        if not src.startswith("{Key:", i):
            i += 1
            continue
        depth, j = 0, i
        while j < n:
            c = src[j]
            if c in "\"`":
                j = skip_string(src, j)
                continue
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        out.append((i, src[i:j + 1]))
        i = j + 1
    return out


GO_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}


def unescape_go_double(s):
    """Decode the escapes Go allows in an interpreted string literal.

    Deliberately **not** `str.encode().decode("unicode_escape")`: that re-decodes
    the UTF-8 bytes and turns `home_icon`'s 🏠 into mojibake, which would make
    every non-ASCII default look like a difference.
    """
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            out.append(GO_ESCAPES.get(s[i + 1], "\\" + s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def field(entry, name):
    m = re.search(r"\b" + name + r":\s*", entry)
    if not m:
        return None
    i = m.end()
    if i < len(entry) and entry[i] in "\"`":
        j = skip_string(entry, i)
        raw = entry[i + 1:j - 1]
        return raw if entry[i] == "`" else unescape_go_double(raw)
    m2 = re.match(r"[^,}]+", entry[i:])
    return m2.group(0).strip() if m2 else None


def go_public(rev):
    """[(key, default)] for every entry whose Flag is PUBLIC/READONLY or absent.

    A missing `Flag:` means the zero value, which `model.PUBLIC` is.
    """
    setting = git_show(f"{rev}:internal/bootstrap/data/setting.go")
    consts = dict(re.findall(r"^\s*(\w+)\s*=\s*\"([^\"]*)\"",
                             git_show(f"{rev}:internal/conf/const.go"), re.M))
    fn = setting.index("func InitialSettings()")
    nxt = setting.find("\nfunc ", fn + 10)
    body = setting[fn:nxt] if nxt != -1 else setting[fn:]
    arr = body.index("[]model.SettingItem{")

    out = []
    for pos, e in scan_entries(body, arr):
        line_start = body.rfind("\n", 0, pos) + 1
        if body[line_start:pos].lstrip().startswith("//"):
            continue  # commented-out entry
        flag = field(e, "Flag")
        flag = flag.split(".")[-1] if flag else "PUBLIC"
        if flag not in ("PUBLIC", "READONLY"):
            continue
        key = field(e, "Key")
        if key and key.startswith("conf."):
            key = consts.get(key[5:], key)
        if key.startswith("test_"):
            continue  # fixtures for the settings unit test
        out.append((key, field(e, "Value") or ""))
    return out


def zig_public():
    src = open(ZIG_API, encoding="utf-8").read()
    start = src.index("const public_setting_defaults")
    body = src[start:src.index("};", start)]
    out = []
    for m in re.finditer(r"\.\{\s*\.key\s*=\s*\"([^\"]+)\",\s*\.value\s*=", body):
        i = m.end()
        while i < len(body) and body[i] in " \t\r\n":
            i += 1
        if i < len(body) and body[i] == '"':
            j = i + 1
            while j < len(body):
                if body[j] == "\\":
                    j += 2
                    continue
                if body[j] == '"':
                    break
                j += 1
            val = body[i + 1:j]
        elif i < len(body) and body[i] == "\\":  # zig multi-line string
            val = body[i + 2:body.index("\n", i)].rstrip()
        else:
            val = ""
        out.append((m.group(1), val))
    return out


def unescape_zig(s):
    return (s.replace("\\n", "\n").replace("\\t", "\t")
             .replace('\\"', '"').replace("\\\\", "\\"))


def main():
    rev = "origin/main"
    if "--rev" in sys.argv:
        rev = sys.argv[sys.argv.index("--rev") + 1]

    go = [(k, v) for k, v in go_public(rev) if k not in EXEMPT]
    zig = [(k, unescape_zig(v)) for k, v in zig_public() if k not in EXEMPT]
    go = [(k, v) for k, v in go if k not in DELIBERATE]
    zig = [(k, v) for k, v in zig if k not in DELIBERATE]

    gk = [k for k, _ in go]
    zk = [k for k, _ in zig]
    problems = []
    for k in gk:
        if k not in zk:
            problems.append(f"missing in Zig: {k}")
    for k in zk:
        if k not in gk:
            problems.append(f"extra in Zig:   {k}")
    if gk != zk and not problems:
        problems.append("key order differs")

    gm, zm = dict(go), dict(zig)
    for k in gk:
        if k not in zm:
            continue
        # `iframe_previews` is JSON either way: upstream writes it pretty-printed
        # in a raw string, the Zig table keeps it on one line. Comparing the
        # whitespace-stripped text keeps that from reading as a difference.
        if "".join(gm[k].split()) != "".join(zm[k].split()):
            problems.append(f"default differs for {k}:\n    go ={gm[k]!r}\n    zig={zm[k]!r}")

    print(f"go={len(go)} zig={len(zig)} (rev {rev})")
    for k, why in DELIBERATE.items():
        print(f"note: {k} deliberately differs — {why}")
    if problems:
        print("\n".join(problems))
        return 1
    print("OK: public settings match upstream")
    return 0


if __name__ == "__main__":
    sys.exit(main())
