import sys
sys.path.insert(0, "zig-src/tools")
from remote import connect, sh
W="/tmp/olz-build"
c=connect("10.0.0.4",22)
o,e,rc = sh(c, f"cd {W} && B=$(ls .zig-cache/o/*/test 2>/dev/null | head -1); echo BIN=$B; $B --seed=0x1 --listen=- > /tmp/t.log 2>&1; echo rc=$?; tail -25 /tmp/t.log; echo '--- counts ---'; grep -c 'OK$' /tmp/t.log; grep -n 'FAIL' /tmp/t.log | head")
print((o+e)[:6000])
c.close()
