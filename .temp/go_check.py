import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-src", "tools"))

from remote import connect, sh

c = connect("10.0.0.4", 22)
try:
    o, e, rc = sh(c, "command -v go && go version; ls /usr/local/go/bin 2>/dev/null", timeout=30)
    print("rc=", rc)
    print("out=", o)
    print("err=", e)
finally:
    c.close()
