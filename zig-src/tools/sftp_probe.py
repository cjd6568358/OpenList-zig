#!/usr/bin/env python3
"""裸 SFTP 探针：直接说 SFTP v3，不经过 SSH。

用途
----
`openlist --sftp-plain <port>` 在 127.0.0.1 上开一个**无认证**的 SFTP 端点。
SSH 传输层还没写，这是验证「协议层 + 会话层 + 分发层 + 驱动映射」的唯一
低成本手段：不用密钥、不用 sshd、不用真实客户端。

它检查的是**服务端行为**，不是客户端兼容性。兼容性要等 SSH 层落地后用
OpenSSH `sftp` / WinSCP / FileZilla / rclone 验。

用法
----
    python tools/sftp_probe.py 15399 --list / --stat /local/readme.txt
    python tools/sftp_probe.py 15399 --read /local/big.bin --read-len 4096
    python tools/sftp_probe.py 15399 --mkdir /local/tmp-probe --rmdir /local/tmp-probe

不依赖任何第三方库（`paramiko` 在本机装不上，也不该为这个装）。
"""

import argparse
import socket
import struct
import sys

# SSH_FXP_*
INIT = 1
VERSION = 2
OPEN = 3
CLOSE = 4
READ = 5
WRITE = 6
LSTAT = 7
FSTAT = 8
SETSTAT = 9
FSETSTAT = 10
OPENDIR = 11
READDIR = 12
REMOVE = 13
MKDIR = 14
RMDIR = 15
REALPATH = 16
STAT = 17
RENAME = 18
READLINK = 19
SYMLINK = 20
STATUS = 101
HANDLE = 102
DATA = 103
NAME = 104
ATTRS = 105

TYPE_NAMES = {
    INIT: "INIT", VERSION: "VERSION", OPEN: "OPEN", CLOSE: "CLOSE",
    READ: "READ", WRITE: "WRITE", LSTAT: "LSTAT", FSTAT: "FSTAT",
    SETSTAT: "SETSTAT", FSETSTAT: "FSETSTAT", OPENDIR: "OPENDIR",
    READDIR: "READDIR", REMOVE: "REMOVE", MKDIR: "MKDIR", RMDIR: "RMDIR",
    REALPATH: "REALPATH", STAT: "STAT", RENAME: "RENAME",
    READLINK: "READLINK", SYMLINK: "SYMLINK",
    STATUS: "STATUS", HANDLE: "HANDLE", DATA: "DATA", NAME: "NAME",
    ATTRS: "ATTRS",
}

STATUS_NAMES = {
    0: "OK", 1: "EOF", 2: "NO_SUCH_FILE", 3: "PERMISSION_DENIED",
    4: "FAILURE", 5: "BAD_MESSAGE", 6: "NO_CONNECTION",
    7: "CONNECTION_LOST", 8: "OP_UNSUPPORTED",
}

# SSH_FXF_*
FXF_READ = 0x01
FXF_WRITE = 0x02
FXF_APPEND = 0x04
FXF_CREAT = 0x08
FXF_TRUNC = 0x10
FXF_EXCL = 0x20

# SSH_FILEXFER_ATTR_*
ATTR_SIZE = 0x00000001
ATTR_UIDGID = 0x00000002
ATTR_PERMISSIONS = 0x00000004
ATTR_ACMODTIME = 0x00000008
ATTR_EXTENDED = 0x80000000


# ---------------------------------------------------------------------------
# 线格式
# ---------------------------------------------------------------------------

def u32(v):
    return struct.pack(">I", v)


def u64(v):
    return struct.pack(">Q", v)


def s(b):
    if isinstance(b, str):
        b = b.encode()
    return u32(len(b)) + b


def packet(ptype, body=b""):
    return u32(len(body) + 1) + bytes([ptype]) + body


class Reader:
    def __init__(self, buf):
        self.buf = buf
        self.pos = 0

    def take(self, n):
        if self.pos + n > len(self.buf):
            raise EOFError("truncated: want %d at %d of %d" % (n, self.pos, len(self.buf)))
        out = self.buf[self.pos:self.pos + n]
        self.pos += n
        return out

    def u8(self):
        return self.take(1)[0]

    def u32(self):
        return struct.unpack(">I", self.take(4))[0]

    def u64(self):
        return struct.unpack(">Q", self.take(8))[0]

    def string(self):
        return self.take(self.u32())

    def attrs(self):
        flags = self.u32()
        a = {"flags": flags}
        if flags & ATTR_SIZE:
            a["size"] = self.u64()
        if flags & ATTR_UIDGID:
            a["uid"] = self.u32()
            a["gid"] = self.u32()
        if flags & ATTR_PERMISSIONS:
            a["permissions"] = self.u32()
        if flags & ATTR_ACMODTIME:
            a["atime"] = self.u32()
            a["mtime"] = self.u32()
        if flags & ATTR_EXTENDED:
            n = self.u32()
            for _ in range(n):
                self.string()
                self.string()
        return a


# ---------------------------------------------------------------------------
# 连接
# ---------------------------------------------------------------------------

class Conn:
    def __init__(self, host, port, timeout=10.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.next_id = 1

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise EOFError("connection closed (wanted %d, got %d)" % (n, len(buf)))
            buf += chunk
        return buf

    def read_packet(self):
        ln = struct.unpack(">I", self._recv_exact(4))[0]
        if ln == 0:
            raise ValueError("zero-length packet")
        data = self._recv_exact(ln)
        return data[0], data[1:]

    def send(self, ptype, body=b""):
        self.sock.sendall(packet(ptype, body))
        return self.read_packet()

    def req(self, ptype, body):
        rid = self.next_id
        self.next_id += 1
        return self.send(ptype, u32(rid) + body)


def describe(ptype, body):
    """把回复包压成一行摘要。"""
    name = TYPE_NAMES.get(ptype, "0x%02x" % ptype)
    if ptype == STATUS:
        r = Reader(body)
        rid = r.u32()
        code = r.u32()
        msg = r.string()
        lang = r.string()
        text = STATUS_NAMES.get(code, "code=%d" % code)
        extra = (" msg=%r" % msg.decode("utf-8", "replace")) if msg else ""
        return "%s id=%d %s%s" % (name, rid, text, extra)
    if ptype == HANDLE:
        r = Reader(body)
        return "%s id=%d handle=%s" % (name, r.u32(), r.string().hex())
    if ptype == DATA:
        r = Reader(body)
        rid = r.u32()
        d = r.string()
        return "%s id=%d %d bytes: %r" % (name, rid, len(d), d[:60])
    if ptype == NAME:
        r = Reader(body)
        rid = r.u32()
        count = r.u32()
        lines = []
        for _ in range(count):
            fname = r.string().decode("utf-8", "replace")
            _long = r.string()
            a = r.attrs()
            kind = "d" if a.get("permissions", 0) & 0o040000 else "-"
            lines.append("%s %8s %s" % (kind, a.get("size", 0), fname))
        head = "%s id=%d count=%d" % (name, rid, count)
        return head + ("\n    " + "\n    ".join(lines) if lines else "")
    if ptype == ATTRS:
        r = Reader(body)
        rid = r.u32()
        return "%s id=%d %r" % (name, rid, r.attrs())
    if ptype == VERSION:
        r = Reader(body)
        return "%s %d" % (name, r.u32())
    return "%s %d bytes" % (name, len(body))


# ---------------------------------------------------------------------------
# 各操作
# ---------------------------------------------------------------------------

def do_init(c):
    ptype, body = c.send(INIT, u32(3))
    print("  INIT     -> %s" % describe(ptype, body))
    if ptype != VERSION:
        raise SystemExit("expected VERSION, got %s" % TYPE_NAMES.get(ptype, ptype))
    return ptype, body


def do_realpath(c, path):
    ptype, body = c.req(REALPATH, s(path))
    print("  REALPATH %-24s -> %s" % (path, describe(ptype, body)))


def do_stat(c, path, by_handle=None):
    if by_handle is not None:
        ptype, body = c.req(FSTAT, s(by_handle))
    else:
        ptype, body = c.req(STAT, s(path))
    print("  STAT     %-24s -> %s" % (path, describe(ptype, body)))
    return ptype, body


def do_opendir(c, path):
    ptype, body = c.req(OPENDIR, s(path))
    print("  OPENDIR  %-24s -> %s" % (path, describe(ptype, body)))
    if ptype != HANDLE:
        return None
    r = Reader(body)
    r.u32()  # request id
    return r.string()


def do_readdir(c, handle, max_pages=8):
    for page in range(max_pages):
        ptype, body = c.req(READDIR, s(handle))
        print("  READDIR  page %-19d -> %s" % (page + 1, describe(ptype, body)))
        if ptype != NAME:
            return


def do_read(c, path, length):
    ptype, body = c.req(OPEN, s(path) + u32(FXF_READ) + u32(0))
    print("  OPEN     %-24s -> %s" % (path, describe(ptype, body)))
    if ptype != HANDLE:
        return
    r = Reader(body)
    r.u32()
    handle = r.string()

    ptype, body = c.req(READ, s(handle) + u64(0) + u32(length))
    print("  READ     %-24s -> %s" % (path, describe(ptype, body)))

    ptype, body = c.req(CLOSE, s(handle))
    print("  CLOSE    %-24s -> %s" % (path, describe(ptype, body)))


def do_mkdir(c, path):
    ptype, body = c.req(MKDIR, s(path) + u32(0))
    print("  MKDIR    %-24s -> %s" % (path, describe(ptype, body)))


def do_rmdir(c, path):
    ptype, body = c.req(RMDIR, s(path))
    print("  RMDIR    %-24s -> %s" % (path, describe(ptype, body)))


def do_remove(c, path):
    ptype, body = c.req(REMOVE, s(path))
    print("  REMOVE   %-24s -> %s" % (path, describe(ptype, body)))


def do_rename(c, old, new):
    ptype, body = c.req(RENAME, s(old) + s(new))
    print("  RENAME   %-24s -> %s" % (old, describe(ptype, body)))


def do_write_unsupported(c, path):
    """写路径本轮明确不支持：必须回 OP_UNSUPPORTED，不能静默成功。"""
    ptype, body = c.req(OPEN, s(path) + u32(FXF_WRITE | FXF_CREAT | FXF_TRUNC) + u32(0))
    print("  OPEN(w)  %-24s -> %s" % (path, describe(ptype, body)))
    if ptype == STATUS:
        r = Reader(body)
        r.u32()
        code = r.u32()
        if code != 8:
            print("    !! expected OP_UNSUPPORTED(8), got %d" % code)


def do_setstat_size(c, path):
    """截断必须明确拒绝（回 OP_UNSUPPORTED），不能假装成功。"""
    ptype, body = c.req(SETSTAT, s(path) + u32(ATTR_SIZE) + u64(0))
    print("  SETSTAT  %-24s -> %s" % (path + " (size=0)", describe(ptype, body)))
    if ptype == STATUS:
        r = Reader(body)
        r.u32()
        code = r.u32()
        if code != 8:
            print("    !! expected OP_UNSUPPORTED(8), got %d" % code)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description="bare SFTP probe (no SSH)")
    ap.add_argument("port", type=int, help="port of `openlist --sftp-plain`")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--list", action="append", default=[], metavar="PATH",
                    help="OPENDIR + READDIR on PATH (repeatable)")
    ap.add_argument("--stat", action="append", default=[], metavar="PATH",
                    help="STAT PATH (repeatable)")
    ap.add_argument("--read", action="append", default=[], metavar="PATH",
                    help="OPEN(read) + READ 0..N + CLOSE (repeatable)")
    ap.add_argument("--read-len", type=int, default=64)
    ap.add_argument("--mkdir", action="append", default=[], metavar="PATH")
    ap.add_argument("--rmdir", action="append", default=[], metavar="PATH")
    ap.add_argument("--remove", action="append", default=[], metavar="PATH")
    ap.add_argument("--rename", nargs=2, action="append", default=[], metavar=("OLD", "NEW"))
    ap.add_argument("--check-write-unsupported", action="append", default=[], metavar="PATH")
    ap.add_argument("--check-truncate-unsupported", action="append", default=[], metavar="PATH")
    args = ap.parse_args()

    c = Conn(args.host, args.port)
    try:
        print("[init]")
        do_init(c)

        print("[realpath]")
        do_realpath(c, "/")

        if args.list:
            print("[list]")
            for p in args.list:
                h = do_opendir(c, p)
                if h is not None:
                    do_readdir(c, h)

        if args.stat:
            print("[stat]")
            for p in args.stat:
                do_stat(c, p)

        if args.read:
            print("[read]")
            for p in args.read:
                do_read(c, p, args.read_len)

        if args.mkdir or args.rmdir or args.remove or args.rename:
            print("[mutate]")
            for p in args.mkdir:
                do_mkdir(c, p)
            for p in args.rmdir:
                do_rmdir(c, p)
            for p in args.remove:
                do_remove(c, p)
            for old, new in args.rename:
                do_rename(c, old, new)

        if args.check_write_unsupported:
            print("[write must be unsupported]")
            for p in args.check_write_unsupported:
                do_write_unsupported(c, p)

        if args.check_truncate_unsupported:
            print("[truncate must be unsupported]")
            for p in args.check_truncate_unsupported:
                do_setstat_size(c, p)

    finally:
        c.close()


if __name__ == "__main__":
    try:
        main()
    except (EOFError, ConnectionError, OSError) as e:
        print("FAILED: %s" % e, file=sys.stderr)
        sys.exit(1)
