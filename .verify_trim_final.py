"""Verify the trimmed binary's driver list on the 光猫 (web setup + LAN probe).

Busybox `wget` here has no `--header`, so the authenticated call is made from
this machine over the LAN instead (the box is reachable — SSH runs on 10022).
Flow:
  1. stage the binary under /tmp/olz and cold-start it,
  2. `POST /api/public/init/setup` (web wizard) to create the admin,
  3. `POST /api/auth/login` to get a JWT,
  4. `GET /api/admin/driver/names` with the JWT — the endpoint the frontend's
     driver dropdown is rendered from,
  5. tear the process down and remove every staged file.

Isolation: writes ONLY under `/tmp/olz` (tmpfs). Never touches `/opt/sq/openlist`.
"""
import http.client
import json
import os
import sys
import time

import paramiko

HOST, PORT = "192.168.1.1", 10022
LOCAL = "D:/workspace/OpenList-zig/zig-src/dist/openlist-aarch64.trimmed"
LISTEN = 15399
USER = "admin"
PWD = "trimcheck-verify-2026"


def ssh_sh(c, cmd, timeout=240):
    _, o, e = c.exec_command(cmd, timeout=timeout)
    return o.read().decode(errors="replace") + e.read().decode(errors="replace")


def probe(path, token=None):
    conn = http.client.HTTPConnection(HOST, LISTEN, timeout=10)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    conn.request("GET", path, headers=headers)
    r = conn.getresponse()
    body = r.read().decode(errors="replace")
    conn.close()
    return r.status, body


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, port=PORT, username="root", password="REDACTED", timeout=20,
              look_for_keys=False, allow_agent=False)
    try:
        # 先清掉上一次可能残留的进程/文件：否则 SFTP put 会撞上仍被进程持有的
        # openlist.trimmed，报一个没有上下文的 OSError: Failure。
        ssh_sh(c, "mkdir -p /tmp/olz; kill -9 $(cat /tmp/olz/trim.pid 2>/dev/null) 2>/dev/null; "
                  "kill -9 $(ps | grep openlist.trimmed | grep -v grep | awk '{print $1}') 2>/dev/null; "
                  "sleep 1; cd /tmp/olz && rm -rf openlist.trimmed trim.log trim.pid trimcfg.json data")
        sftp = c.open_sftp()
        sftp.put(LOCAL, "/tmp/olz/openlist.trimmed")
        sftp.chmod("/tmp/olz/openlist.trimmed", 0o755)
        sftp.close()
        print(f"staged {os.path.getsize(LOCAL)} bytes in /tmp/olz")

        out = ssh_sh(c, f"""
cd /tmp/olz && rm -rf trim.log trim.pid trimcfg.json data
nohup ./openlist.trimmed server --config trimcfg.json --port {LISTEN} \\
      >/tmp/olz/trim.log 2>&1 &
echo $! >/tmp/olz/trim.pid
sleep 4
wget -q -O - -T 8 --post-data='{{"username":"{USER}","password":"{PWD}"}}' \\
     http://127.0.0.1:{LISTEN}/api/public/init/setup
""")
        print("setup:", out.strip()[:200])

        time.sleep(1)
        # login + names from this machine (busybox wget has no --header)
        conn = http.client.HTTPConnection(HOST, LISTEN, timeout=10)
        conn.request("POST", "/api/auth/login",
                     json.dumps({"username": USER, "password": PWD}),
                     {"Content-Type": "application/json"})
        tok = json.loads(conn.getresponse().read().decode())["data"]["token"]
        conn.close()
        print("login: ok, token", tok[:24] + "...")

        st, names = probe("/api/admin/driver/names", tok)
        print(f"driver/names [{st}]: {names[:400]}")
        d = json.loads(names)["data"]
        print("parsed:", d)
        # quarkuc 一个文件注册两个 factory（Quark + UC），所以 4 个驱动文件 => 5 项
        assert st == 200 and d == ["Local", "WebDav", "Quark", "UC", "Strm"], d

        st2, st3 = probe("/api/public/settings")
        print(f"public/settings [{st2}]: {st3[:120]}")

        print("--- cleanup ---")
        print(ssh_sh(c, f"kill -9 $(cat /tmp/olz/trim.pid) 2>/dev/null; "
                        f"sleep 1; cd /tmp/olz && rm -rf openlist.trimmed trim.log "
                        f"trim.pid trimcfg.json data; echo residue:; ls -A /tmp/olz; "
                        f"netstat -ltn 2>/dev/null | grep {LISTEN} || echo 'port free'"))
    finally:
        try:
            ssh_sh(c, "cd /tmp/olz && kill -9 $(cat trim.pid 2>/dev/null) 2>/dev/null; "
                       "rm -rf openlist.trimmed trim.log trim.pid trimcfg.json data")
        except Exception:
            pass
        c.close()
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
