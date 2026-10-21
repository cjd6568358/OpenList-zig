#!/usr/bin/env python3
"""Refresh the embedded frontend shell and its version pin in frontend.zig.

Grabs `dist/index.html` from the `@openlist-frontend/openlist-frontend`
release tarball, writes it as `src/frontend_shell_v<ver>.html` (the file
`frontend.zig` `@embedFile`s), repoints `@embedFile(...)` and
`embedded_shell_version` at it, and removes stale shell files.

Why the tarball and not a CDN files endpoint: registry.npmmirror.com's
`/files/` route serves .js/.css fine but 451s every .html
(`{"error":"blocked"}`; anti-abuse, not legal); jsdelivr/unpkg serve the file
but reachability from CN networks is intermittent. The `/-/<pkg>-<ver>.tgz`
route is a registry's core function — served byte-identical by npmjs and
npmmirror alike — so the shell always comes straight from the package.

Usage:
    python tools/fetch_frontend_shell.py            # re-fetch the current pin
    python tools/fetch_frontend_shell.py 4.2.7      # bump to a new release
"""

import io
import re
import sys
import tarfile
import urllib.request
from pathlib import Path

PACKAGE = "@openlist-frontend/openlist-frontend"
# frontend.zig 的渲染管线（renderShell）依赖的占位符集合；新增 needle 时这里
# 与 tests.zig 里 "embedded shell is the real built artefact" 的清单要同步。
MARKERS = (
    "window.OPENLIST_CONFIG",
    "cdn: undefined",
    "base_path: undefined",
    "main_color: undefined",
    'href="/manifest.json"',
    "https://res.oplist.org/logo/logo.svg",
    "https://res.oplist.org/logo/logo.png",
    "Loading...",
    "<!-- customize head -->",
    "<!-- customize body -->",
)
ROOT = Path(__file__).resolve().parent.parent  # zig-src/
SRC = ROOT / "src"
FRONTEND = SRC / "frontend.zig"
EMBED_RE = re.compile(r'@embedFile\("frontend_shell_v([0-9.]+)\.html"\)')
VER_RE = re.compile(r'pub const embedded_shell_version = "([^"]+)";')


def current_version() -> str:
    m = VER_RE.search(FRONTEND.read_text(encoding="utf-8"))
    if not m:
        sys.exit("!! cannot find embedded_shell_version in frontend.zig")
    return m.group(1)


def fetch_tarball(ver: str) -> bytes:
    name = PACKAGE.rsplit("/", 1)[1]
    hosts = ("https://registry.npmmirror.com", "https://registry.npmjs.org")
    last = None
    for host in hosts:
        url = f"{host}/{PACKAGE}/-/{name}-{ver}.tgz"
        try:
            with urllib.request.urlopen(url, timeout=60) as r:
                if r.status != 200:
                    raise RuntimeError(f"HTTP {r.status}")
                return r.read()
        except Exception as e:  # 换下一个镜像，最后统一报错
            last = e
            print(f"   {host} failed: {e}")
    sys.exit(f"!! could not download tarball for {ver}: {last}")


def extract_index_html(blob: bytes, ver: str) -> bytes:
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf:
        member = tf.extractfile("package/dist/index.html")
        if member is None:
            sys.exit(f"!! package/dist/index.html missing from the {ver} tarball")
        return member.read()


def validate(html: bytes) -> None:
    text = html.decode("utf-8")
    missing = [m for m in MARKERS if m not in text]
    if missing:
        sys.exit(f"!! shell missing expected placeholders: {missing}")
    if "/src/main.tsx" in text:
        sys.exit("!! looks like the dev index.html (references /src/main.tsx), not the built dist")
    if "/assets/" not in text:
        sys.exit("!! no /assets/ references — not a built dist shell?")


def patch_frontend_zig(old: str, new: str) -> None:
    text = FRONTEND.read_text(encoding="utf-8")
    text, n1 = EMBED_RE.subn(f'@embedFile("frontend_shell_v{new}.html")', text)
    text, n2 = VER_RE.subn(f'pub const embedded_shell_version = "{new}";', text)
    if n1 != 1 or n2 != 1:
        sys.exit(f"!! expected exactly one @embedFile and one version pin, got {n1}/{n2}")
    FRONTEND.write_text(text, encoding="utf-8")


def main() -> int:
    target = sys.argv[1] if len(sys.argv) > 1 else current_version()
    cur = current_version()
    print(f"embedded shell: v{cur} -> v{target}")

    html = extract_index_html(fetch_tarball(target), target)
    validate(html)
    print(f"   dist/index.html: {len(html)} bytes, all placeholders present")

    out = SRC / f"frontend_shell_v{target}.html"
    out.write_bytes(html)
    for stale in SRC.glob("frontend_shell_v*.html"):
        if stale != out:
            stale.unlink()
            print(f"   removed stale {stale.name}")

    if target != cur:
        patch_frontend_zig(cur, target)
        print(f"   frontend.zig: @embedFile + embedded_shell_version -> v{target}")
    print(f"ok: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
