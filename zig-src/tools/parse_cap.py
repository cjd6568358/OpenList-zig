#!/usr/bin/env python3
"""解析 dist/cap.pcap（LINUX_SLL），输出探针会话 vs curl 会话的逐包时间线 + TLS 记录序列。"""
import struct
import sys
from collections import defaultdict


def read_pcap(path):
    data = open(path, "rb").read()
    magic = data[:4]
    if magic == b"\xd4\xc3\xb2\xa1":
        endian, nano = "<", False
    elif magic == b"\xa1\xb2\xc3\xd4":
        endian, nano = ">", False
    elif magic == b"\x4d\x3c\xb2\xa1":
        endian, nano = "<", True
    else:
        sys.exit("unknown pcap magic %s" % magic.hex())
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
    """返回 (src, sport, dst, dport, flags, payload) 或 None。"""
    if linktype == 113:  # LINUX_SLL v1: 16-byte header
        proto = struct.unpack(">H", pkt[14:16])[0]
        ip = pkt[16:]
    elif linktype == 1:  # Ethernet
        proto = struct.unpack(">H", pkt[12:14])[0]
        ip = pkt[14:]
    else:
        return None
    if proto != 0x0800:  # IPv4
        return None
    ihl = (ip[0] & 0xF) * 4
    if ip[9] != 6:  # TCP
        return None
    src = ".".join(str(b) for b in ip[12:16])
    dst = ".".join(str(b) for b in ip[16:20])
    tcp = ip[ihl:]
    sport, dport = struct.unpack(">HH", tcp[0:4])
    doff = (tcp[12] >> 4) * 4
    flags = tcp[13]
    payload = tcp[doff:]
    return src, sport, dst, dport, flags, payload


FLAG = {0x02: "SYN", 0x10: "ACK", 0x18: "PSH-ACK", 0x11: "FIN-ACK", 0x14: "RST-ACK", 0x04: "RST", 0x01: "FIN"}


def tls_records(buf):
    """从字节流头部分解析连续的 TLS 记录，返回 [(type, len)] 和已消费长度。"""
    out = []
    off = 0
    while off + 5 <= len(buf):
        t, v, ln = buf[off], buf[off + 1:off + 3], struct.unpack(">H", buf[off + 3:off + 5])[0]
        if t not in (0x14, 0x15, 0x16, 0x17) or v[0] != 0x03:
            break
        out.append((t, ln))
        off += 5 + ln
    return out, off


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "dist/cap.pcap"
    linktype, pkts = read_pcap(path)
    print("linktype=%d packets=%d" % (linktype, len(pkts)))

    # 分流：按 (client_ip, client_port) 聚合；client = 主动发 SYN 方
    streams = defaultdict(list)
    for ts, pkt in pkts:
        r = parse_ip_tcp(pkt, linktype)
        if not r:
            continue
        src, sport, dst, dport, flags, payload = r
        # 用 ppp0 上设备的本地 IP 做参照不可靠；这里按「有 SYN 无 ACK 的方向为客户端」
        key_candidates = ((src, sport, dst, dport), (dst, dport, src, sport))
        if flags & 0x02 and not flags & 0x10:
            streams[(src, sport, dst, dport)].append((ts, "C", flags, payload, "SYN"))
        else:
            # 归属到已有流：先按 (src,sport) 匹配已知 client
            placed = False
            for (ci, cp, si, sp) in list(streams.keys()):
                if (src, sport) == (ci, cp) or (src, sport) == (si, sp):
                    streams[(ci, cp, si, sp)].append((ts, "C" if (src, sport) == (ci, cp) else "S", flags, payload, ""))
                    placed = True
                    break
            if not placed:
                streams[key_candidates[0]].append((ts, "C", flags, payload, "?"))

    if not streams:
        print("no TCP streams")
        return

    # 每条流打印时间线
    for i, (key, evs) in enumerate(sorted(streams.items(), key=lambda kv: kv[1][0][0])):
        ci, cp, si, sp = key
        print("\n=== stream %d: %s:%d -> %s:%d (%d pkts) ===" % (i + 1, ci, cp, si, sp, len(evs)))
        t0 = evs[0][0]
        # 各方向重组 payload 以解析 TLS 记录
        dir_buf = {"C": b"", "S": b""}
        for ts, d, flags, payload, note in evs:
            plen = len(payload)
            fl = FLAG.get(flags, "0x%02x" % flags)
            recs = ""
            if plen > 0:
                dir_buf[d] += payload
                rl, consumed = tls_records(dir_buf[d])
                if rl:
                    recs = " TLS:" + ",".join("t=%02x len=%d" % (t, l) for t, l in rl)
                    # 只解析已完整的记录并移除
                    redone = b""
                    off = 0
                    for t, l in rl:
                        if off + 5 + l <= len(dir_buf[d]):
                            off += 5 + l
                        else:
                            redone += dir_buf[d][off:]
                            break
                    dir_buf[d] = redone if redone else dir_buf[d][off:]
            print("  +%7.1fms %s %-8s len=%-5d%s %s" % ((ts - t0) * 1000, d, fl, plen, recs, note))
    return 0


if __name__ == "__main__":
    sys.exit(main())
