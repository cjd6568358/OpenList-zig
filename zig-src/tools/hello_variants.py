#!/usr/bin/env python3
"""TLS ClientHello 变体实验：找出 Zig std 的 ClientHello 被夸克 CDN 静默的原因。

做法：
1. 本地起一个 TCP 监听，让 openssl s_client 连上来 —— 抓到 OpenSSL 的
   真实 ClientHello 作为基准；
2. 按 std/crypto/tls/Client.zig（打过 ziglib 补丁的版本）逐字节复刻 Zig 的
   ClientHello，并生成若干变体（去 mlkem / 去 key_share / 只要 x25519 /
   空 session_id 等）；
3. 把每个变体发到 CDN，5s 内等响应，报告 ServerHello / Alert / EOF / 超时。

全程在本机完成，不依赖设备与构建机。
"""
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time

CDN = "dl-pc-zb.pds.quark.cn"
PORT = 443

SIG_ALGS = [
    0x0403, 0x0503, 0x0401, 0x0501, 0x0601,
    0x0804, 0x0805, 0x0806, 0x0809, 0x080a, 0x080b,
    0x0201, 0x0807,
]

# Zig 硬件 AES 分支 + ECDSA 补丁后的完整列表
ZIG_SUITES = [
    0x1307, 0x1306, 0x1301, 0xC02F, 0x1302, 0xC030, 0x1303, 0xCCA8,
    0xC02B, 0xC02C, 0xCCA9,
]


def u16(v):
    return struct.pack(">H", v)


def u24(v):
    return struct.pack(">I", v)[1:]


def ext(eid, body):
    return u16(eid) + u16(len(body)) + body


def sni_ext(host):
    body = u16(1 + 2 + len(host)) + b"\x00" + u16(len(host)) + host.encode()
    return ext(0x0000, body)


def build_hello(host, *, suites=None, groups=None, shares=None, sig_algs=None,
                versions=(0x0304, 0x0303), sid_len=32, sni_last=True,
                include_psk=True, extra_exts=None, random_bytes=None):
    """构造 ClientHello record。默认 = Zig std 的精确复刻。"""
    suites = suites if suites is not None else ZIG_SUITES
    groups = groups if groups is not None else [0x11EC, 0x0017, 0x0018, 0x001D]
    sig_algs = sig_algs if sig_algs is not None else SIG_ALGS
    rnd = random_bytes or bytes(range(32))

    exts = []
    # 1. supported_versions
    ver_body = bytes([len(versions) * 2]) + b"".join(u16(v) for v in versions)
    exts.append(ext(0x002B, ver_body))
    # 2. signature_algorithms
    sig_body = b"".join(u16(s) for s in sig_algs)
    exts.append(ext(0x000D, u16(len(sig_body)) + sig_body))
    # 3. supported_groups
    grp_body = b"".join(u16(g) for g in groups)
    exts.append(ext(0x000A, u16(len(grp_body)) + grp_body))
    # 4. psk_key_exchange_modes
    if include_psk:
        exts.append(ext(0x002D, b"\x01\x01"))
    # 5. key_share（None = 不带该扩展）
    if shares is not None:
        ks = b""
        for gid, klen in shares:
            ks += u16(gid) + u16(klen) + bytes((i * 31 + 7) & 0xFF for i in range(klen))
        exts.append(ext(0x0033, u16(len(ks)) + ks))
    # 6. server_name（Zig 放在最后）
    sni = sni_ext(host)
    if extra_exts:
        exts.extend(extra_exts)
    if sni_last:
        exts.append(sni)
    else:
        exts.insert(0, sni)

    body = u16(0x0303) + rnd
    body += bytes([sid_len]) + bytes((i * 7 + 13) & 0xFF for i in range(sid_len))
    body += u16(len(suites) * 2) + b"".join(u16(s) for s in suites)
    body += b"\x01\x00"
    ext_bytes = b"".join(exts)
    body += u16(len(ext_bytes)) + ext_bytes

    hs = b"\x01" + u24(len(body)) + body
    return b"\x16\x03\x01" + u16(len(hs)) + hs


def read_response(sock, timeout=5.0):
    """读 CDN 响应，分类：ServerHello / Alert / EOF / 超时 / RST。"""
    sock.settimeout(timeout)
    data = b""
    try:
        while len(data) < 4096:
            chunk = sock.recv(4096)
            if not chunk:
                return ("EOF", data)
            data += chunk
            break  # 第一段就够判断
    except socket.timeout:
        return ("TIMEOUT", data)
    except ConnectionResetError:
        return ("RST", data)
    if not data:
        return ("EOF", data)
    if data[0] == 0x16 and len(data) > 5 and data[5] == 0x02:
        # 解析协商版本与套件
        try:
            i = 5 + 4 + 2 + 32 + 1  # record hdr + handshake hdr + version + random + sid_len
            sid_len = data[i - 1]
            i += sid_len
            cipher = struct.unpack(">H", data[i:i + 2])[0]
            i += 2 + 1  # cipher + comp
            ext_len = struct.unpack(">H", data[i:i + 2])[0]
            i += 2
            end = i + ext_len
            ver = "?"
            while i + 4 <= min(end, len(data)):
                eid, elen = struct.unpack(">HH", data[i:i + 4])
                if eid == 0x002B and elen == 2:
                    v = struct.unpack(">H", data[i + 4:i + 6])[0]
                    ver = "TLS1.3" if v == 0x0304 else "TLS1.2"
                i += 4 + elen
            return ("SERVERHELLO", "ver=%s cipher=0x%04x" % (ver, cipher))
        except Exception:
            return ("SERVERHELLO", "parse-failed")
    if data[0] == 0x15 and len(data) >= 7:
        return ("ALERT", "level=%d desc=%d" % (data[5], data[6]))
    return ("OTHER", data[:20].hex())


def send_variant(name, hello):
    try:
        s = socket.create_connection((CDN, PORT), timeout=8)
    except Exception as e:
        print("%-22s CONNECT-FAIL %s" % (name, e))
        return
    t0 = time.time()
    try:
        s.sendall(hello)
        kind, info = read_response(s)
    except Exception as e:
        kind, info = "ERROR", str(e)
    finally:
        s.close()
    print("%-22s %-11s %-28s (%.2fs, hello=%dB)" % (name, kind, info, time.time() - t0, len(hello)))


def capture_openssl_hello():
    """本地监听，让 openssl s_client 连上来，抓它的 ClientHello。"""
    captured = {}

    def server():
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        captured["port"] = srv.getsockname()[1]
        srv.settimeout(10)
        conn, _ = srv.accept()
        conn.settimeout(5)
        data = b""
        try:
            while len(data) < 8192:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
                # ClientHello 一个 record 通常一次到齐；够了就停
                if len(data) > 200:
                    break
        except socket.timeout:
            pass
        captured["hello"] = data
        conn.close()
        srv.close()

    t = threading.Thread(target=server)
    t.start()
    time.sleep(0.3)
    port = captured.get("port")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=8),
                            server_hostname="dl-pc-zb.pds.quark.cn")
        s.close()
    except Exception:
        pass  # 假服务器不回应用握手，客户端必然报错；hello 已经抓到了
    t.join(timeout=5)
    return captured.get("hello", b"")


def main():
    host = CDN
    print("=== 0. OpenSSL 真实 ClientHello（本地抓包基准） ===")
    oh = capture_openssl_hello()
    print("openssl hello: %d bytes" % len(oh))
    if oh:
        print("  head:", oh[:80].hex())
    # 从 openssl hello 里提取套件与组，供后续构造参考
    print()

    print("=== 1. 变体实验（目标 %s） ===" % host)
    # Zig 精确复刻：4 组 + 4 key share（含 1216B mlkem 混合 share）+ 32B sid + sni 最后
    zig_shares = [(0x11EC, 1216), (0x0017, 65), (0x0018, 97), (0x001D, 32)]
    send_variant("zig-exact", build_hello(host, shares=zig_shares))
    # 不带 AEGIS（0x1306/0x1307），其余同 Zig
    send_variant("zig-no-aegis", build_hello(
        host, shares=zig_shares,
        suites=[s for s in ZIG_SUITES if s not in (0x1306, 0x1307)]))
    # 只留 TLS1.3 三件套 + ECDHE-RSA 1.2 三件套（OpenSSL 的最小交集）
    send_variant("std-suites-only", build_hello(
        host, shares=zig_shares,
        suites=[0x1301, 0x1302, 0x1303, 0xC02F, 0xC030, 0xCCA8]))
    # 只留 ECDHE-RSA AES128-GCM（OpenSSL 实际谈成的）
    send_variant("one-suite", build_hello(
        host, shares=zig_shares, suites=[0xC02F]))
    # 去 mlkem（组和 share 都去）
    send_variant("no-mlkem", build_hello(host, groups=[0x0017, 0x0018, 0x001D],
                                         shares=[(0x0017, 65), (0x0018, 97), (0x001D, 32)]))
    # 只有 x25519（OpenSSL 常见最小集）
    send_variant("x25519-only", build_hello(host, groups=[0x001D], shares=[(0x001D, 32)]))
    # 完全不带 key_share（TLS1.2 风格 hello，1.3 服务器会 HRR）
    send_variant("no-keyshare", build_hello(host, shares=None))
    # Zig 复刻但空 session_id
    send_variant("zig-empty-sid", build_hello(host, shares=zig_shares, sid_len=0))
    # Zig 复刻但 sni 放最前
    send_variant("zig-sni-first", build_hello(host, shares=zig_shares, sni_last=False))
    # Zig 复刻但去掉 sha1 签名算法
    send_variant("zig-no-sha1", build_hello(host, shares=zig_shares,
                                            sig_algs=[s for s in SIG_ALGS if s != 0x0201]))
    # 只提供 TLS 1.2（不带 1.3、不带 mlkem/keyshare）
    send_variant("tls12-only", build_hello(host, versions=(0x0303,), groups=[0x0017, 0x0018, 0x001D],
                                           shares=None, include_psk=False))
    # 只有 x25519 组且只 TLS1.2
    send_variant("tls12-x25519", build_hello(host, versions=(0x0303,), groups=[0x001D],
                                             shares=None, include_psk=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
