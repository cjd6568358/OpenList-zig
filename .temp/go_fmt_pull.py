"""Run gofmt -w on the remote tree, then pull the formatted files back."""
import os
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, os.path.join(ROOT, "zig-src", "tools"))

from remote import connect, sh  # noqa: E402

HOST = "10.0.0.4"
WORK = "/tmp/olz-goweb"
FILES = [
    "util.go",
    "types.go",
    "meta.go",
    "driver.go",
    "driver_test.go",
]

c = connect(HOST, 22)
try:
    o, e, rc = sh(c, f"export PATH=/usr/local/go/bin:$PATH && cd {WORK} && gofmt -l drivers/thunder_web && gofmt -w drivers/thunder_web && gofmt -l drivers/thunder_web && echo FMT-DONE", timeout=60)
    print(o, e, rc)
    if rc != 0:
        sys.exit(1)
    sftp = c.open_sftp()
    for f in FILES:
        remote = f"{WORK}/drivers/thunder_web/{f}"
        local = os.path.join(ROOT, "drivers", "thunder_web", f)
        sftp.get(remote, local)
        print("pulled", f)
    sftp.close()
finally:
    c.close()
print("PULL-DONE")
