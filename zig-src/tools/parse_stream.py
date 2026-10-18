#!/usr/bin/env python3
"""重建指定 TCP 流的两个方向字节，按 seq 去重重传，解析 TLS 记录序列。"""
import struct
import sys
from collections import defaultdict


def read_pcap(path):
    data = open(path, "rb").read()
    endian, nano = "<", False
    if data[:4] == b"\xa1\xb2\xc3\xd4":
        endian = ">"
    elif data[:4] == b"\x4d\x3c\xb2\xa1":
        endian, nano = "<", True
    linktype = struct.unpack(endian + "I", data[20:24])[0]
    pkts = []
    off = 24
    while off + 16 <= len(data):
        ts_s, ts_u, incl, orig = struct.unpack(endian + "IIII", data[off:off + 16])
        off += 16
        pkts.append((ts_s + ts_u / (1e9 if nano else 1e6), data[off:off + incl]))
        off += incl
    return linktype, pkts


def parse_ip_tcp(pkt, linktype):
    if linktype == 113:
        proto = struct.unpack(">H", pkt[14:16])[0]
        ip = pkt[16:]
    else:
        proto = struct.unpack(">H", pkt[12:14])[0]
        ip = pkt[14:]
    if proto != 0x0800 or ip[9] != 6:
        return None
    ihl = (ip[0] & 0xF) * 4
    src = ".".join(str(b) for b in ip[12:16])
    dst = ".".join(str(b) for b in ip[16:20])
    tcp = ip[ihl:]
    sport, dport, seq = struct.unpack(">HHI", tcp[0:8])
    doff = (tcp[12] >> 4) * 4
    flags = tcp[13]
    return src, sport, dst, dport, seq, flags, tcp[doff:]


def main():
    path = sys.argv[1]
    want_port = int(sys.argv[2])
    linktype, pkts = read_pcap(path)
    c2s = {}  # seq -> payload (first seen wins)
    s2c = {}
    first_ts = None
    last_ts = None
    for ts, pkt in pkts:
        r = parse_ip_tcp(pkt, linktype)
        if not r:
            continue
        src, sport, dst, dport, seq, flags, payload = r
        # 同 seq 冲突时保留更长载荷（SYN/ACK 空载荷会与首个数据段同 seq）
        if sport == want_port:
            if seq not in c2s or len(payload) > len(c2s[seq]):
                c2s[seq] = payload
        elif dport == want_port:
            if seq not in s2c or len(payload) > len(s2c[seq]):
                s2c[seq] = payload
        else:
            continue
        if first_ts is None:
            first_ts = ts
        last_ts = ts

    def rebuild(d):
        if not d:
            return b""
        # 只取非空载荷段，按 seq 排序拼接（SYN 占位 1 字节会造成错位）
        items = [(s, p) for s, p in d.items() if p]
        items.sort()
        out = bytearray()
        expect = None
        for s, p in items:
            if expect is not None and s != expect:
                print("  !! seq gap: expected %d got %d (%d bytes missing)" % (expect, s, s - expect))
            out += p
            expect = s + len(p)
        return bytes(out)

    cdata = rebuild(c2s)
    sdata = rebuild(s2c)
    print("stream port %d: client->server %d bytes (%d segs), server->client %d bytes (%d segs), span %.1fs" % (
        want_port, len(cdata), len(c2s), len(sdata), len(s2c), (last_ts - first_ts)))

    def parse_tls(buf, label):
        print("\n--- %s TLS records ---" % label)
        off = 0
        n = 0
        while off + 5 <= len(buf):
            t = buf[off]
            v = buf[off + 1:off + 3].hex()
            ln = struct.unpack(">H", buf[off + 3:off + 5])[0]
            name = {0x14: "CCS", 0x15: "ALERT", 0x16: "HANDSHAKE", 0x17: "APPDATA"}.get(t, "?%02x" % t)
            print("  rec %2d @%6d: type=%s ver=%s len=%d" % (n, off, name, v, ln))
            off += 5 + ln
            n += 1
            if n > 40:
                print("  ... (more)")
                break
        if off != len(buf):
            print("  !! trailing %d bytes unparsed (off=%d len=%d)" % (len(buf) - off, off, len(buf)))

    parse_tls(cdata, "client->server")
    parse_tls(sdata, "server->client")
    return 0


if __name__ == "__main__":
    sys.exit(main())
