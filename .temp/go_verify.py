"""Sync the Go tree subset to the build host and run go vet/test/build for thunder_web.

    python .temp/go_verify.py pack     # tar + upload
    python .temp/go_verify.py run      # remote gofmt/vet/test/build
    python .temp/go_verify.py all      # both
"""
import io
import os
import sys
import tarfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(ROOT, "zig-src", "tools"))

from remote import connect, put, sh  # noqa: E402

HOST = "10.0.0.4"
WORK = "/tmp/olz-goweb"
TAR_LOCAL = os.path.join(ROOT, ".temp", "goweb-src.tar.gz")
TAR_REMOTE = "tmp/olz-goweb-src.tar.gz"  # 无前导斜杠（见 remote.py 的 MSYS 说明）

# 构建 drivers/（含 all.go 的注册集成）所需的最小集合。
PACK_DIRS = ["cmd", "internal", "pkg", "drivers", "server"]
PACK_FILES = ["go.mod", "go.sum"]


def skip(item: tarfile.TarInfo) -> tarfile.TarInfo | None:
    p = item.name.replace("\\", "/")
    for junk in ("/.git", "/node_modules"):
        if junk in p:
            return None
    return item


def pack():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name in PACK_FILES:
            tf.add(os.path.join(ROOT, name), arcname=name, filter=skip)
        for d in PACK_DIRS:
            tf.add(os.path.join(ROOT, d), arcname=d, filter=skip)
    data = buf.getvalue()
    with open(TAR_LOCAL, "wb") as f:
        f.write(data)
    print(f"packed {len(data)} bytes -> {TAR_LOCAL}")

    c = connect(HOST, 22)
    try:
        sh(c, f"rm -rf {WORK} {TAR_REMOTE and '/tmp/olz-goweb-src.tar.gz'} && mkdir -p {WORK}", timeout=30)
        print("upload via", put(c, TAR_LOCAL, TAR_REMOTE, 0o644))
    finally:
        c.close()


def run():
    c = connect(HOST, 22)
    try:
        cmd = (
            "set -e; cd {w} && tar xzf /tmp/olz-goweb-src.tar.gz && "
            "export PATH=/usr/local/go/bin:$PATH && "
            "export GOTOOLCHAIN=auto && "
            "export GOSUMDB=sum.golang.org && "
            "echo '--- gofmt check ---' && ".format(w=WORK) +
            "out=$(gofmt -l drivers/thunder_web); if [ -n \"$out\" ]; then echo \"gofmt needed: $out\"; exit 1; fi; echo gofmt ok && "
            "echo '--- go vet ---' && "
            "go vet ./drivers/thunder_web/ && "
            "echo '--- go test ---' && "
            "go test ./drivers/thunder_web/ && "
            "echo '--- build all drivers (all.go integration) ---' && "
            "go build ./drivers/ && "
            "echo ALL-OK"
        )
        o, e, rc = sh(c, cmd, timeout=1500)
        print(o)
        if e.strip():
            print("STDERR:", e, file=sys.stderr)
        print("rc=", rc)
        return rc
    finally:
        c.close()


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("pack", "all"):
        pack()
    if what in ("run", "all"):
        sys.exit(run())
