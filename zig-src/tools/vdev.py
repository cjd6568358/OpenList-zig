import sys, json, paramiko
from pathlib import Path
import os
# 本脚本现居 zig-src/tools/：parents[2] = 仓库根，不再依赖 cwd
LOCAL = Path(__file__).resolve().parents[2] / "zig-src" / "dist" / "openlist-aarch64.trimmed"
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("192.168.1.1", port=10022, username="root", password=os.environ.get("OLZ_ROOT_PWD", ""), timeout=20,
          look_for_keys=False, allow_agent=False)
sftp = c.open_sftp()
sftp.put(str(LOCAL), "tmp/olz/openlist.trimmed")
sftp.chmod("tmp/olz/openlist.trimmed", 0o755)
o,e,rc = sh = None, None, None
import subprocess
def sh(cmd):
    _, o, e = c.exec_command(cmd)
    return o.read().decode(errors="replace"), e.read().decode(errors="replace")
# 直接问二进制：--list-drivers 之类不存在，改用临时端口起服务再打接口
print(sh("cd /tmp/olz && (./openlist.trimmed server --config /tmp/olz/vcfg.json --port 15399 >/tmp/olz/trim.log 2>&1 &) ; sleep 3")[0])
out = sh("curl -s -m 10 http://127.0.0.1:15399/api/admin/driver/names || curl -s -m 10 http://127.0.0.1:15399/api/public/settings")
print(out[0][:1200])
print("ERR:", out[1][:300])
sftp.close(); c.close()
