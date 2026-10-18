#!/usr/bin/env python3
"""Lint the built-in page's inline JavaScript.

Why this exists
---------------
On 2026-10-15 the `@zig-setup` page shipped with `&amp;&amp;` inside a `<script>`
block. `<script>` is a raw-text element, so HTML entities are *not* decoded:
the browser handed the literal `&amp;&amp;` to the JS parser, which choked on
`c.base_path & amp;` -> "Unexpected token ';'" -> **the whole script never ran**
-> the setup form never appeared.

Every check we had passed, because they all inspected the served HTML as a
string. None of them executed the JS. This script closes that gap: it extracts
the inline script and runs it through `node --check`.

Usage:
    python tools/check_builtin_js.py            # needs `node` on PATH
    python tools/check_builtin_js.py --quiet

Exit code 0 = clean, 1 = problem.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src", "frontend.zig")

# Zig multiline-string prefix: four spaces then two backslashes.
PREFIX = "    " + "\\" + "\\"


def extract_body_script(text):
    """Return the inline JS of the *body-level* script block.

    `BUILTIN_INDEX` has two `<script>` blocks (the `OPENLIST_CONFIG` literal in
    <head>, and the page logic at the end of <body>). Only the latter matters.
    """
    start = text.index("const BUILTIN_INDEX =")
    end = text.index("const UPSTREAM_INDEX_HTML =")
    block = text[start:end]

    body_at = block.index("  <body>")
    js_open = block.rindex("<script>", body_at)
    js_close = block.rindex("</script>", js_open)

    raw = block[js_open + len("<script>"):js_close]
    lines = []
    for ln in raw.split("\n"):
        if ln.startswith(PREFIX):
            lines.append(ln[len(PREFIX):])
        elif ln.strip() == "":
            lines.append("")
        else:
            lines.append(ln)
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    def say(*parts):
        if not a.quiet:
            print(*parts)

    if not os.path.exists(SRC):
        print(f"!! {SRC} not found", file=sys.stderr)
        return 1

    with open(SRC, encoding="utf-8") as f:
        js = extract_body_script(f.read())

    if not js.strip():
        print("!! extracted no JavaScript — did BUILTIN_INDEX move?", file=sys.stderr)
        return 1

    # 1) HTML entities must not appear in a raw-text element.
    ents = re.findall(r"&(?:amp|lt|gt|quot|apos|#\d+);", js)
    if ents:
        print(f"!! inline JS contains HTML entities {sorted(set(ents))}", file=sys.stderr)
        print("   <script> is raw text — entities are NOT decoded there.", file=sys.stderr)
        print("   Write `&&` directly, not `&amp;&amp;`.", file=sys.stderr)
        return 1
    say("entities: none ✓")

    # 2) Real syntax check.
    node = shutil.which("node")
    if not node:
        say("node not found — skipped the syntax check (entity check still ran)")
        return 0

    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False,
                                     encoding="utf-8", newline="\n") as f:
        f.write(js)
        tmp = f.name
    try:
        r = subprocess.run([node, "--check", tmp], capture_output=True, text=True)
        if r.returncode != 0:
            print("!! inline JS failed `node --check`:", file=sys.stderr)
            print((r.stderr or r.stdout).strip(), file=sys.stderr)
            return 1
    finally:
        os.unlink(tmp)
    say(f"syntax: ok ({len(js)} bytes) ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
