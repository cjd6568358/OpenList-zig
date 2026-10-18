//! Raw TLS ClientHello probe — finds which part of Zig std's ClientHello
//! makes drive.quark.cn's CDN answer with a fatal `internal_error` alert.
//!
//! Background: `std.crypto.tls.Client` (Zig 0.17) hardcodes its ClientHello:
//! it offers `x25519_ml_kem768` (post-quantum hybrid) in supported_groups and
//! sends a key_share for FOUR groups (~1.3 KB of key material, ML-KEM alone
//! is 1184 bytes), puts the server_name extension LAST, and includes
//! `rsa_pkcs1_sha1` in signature_algorithms. cloud.189.cn accepts that hello
//! (TLS 1.3), but drive.quark.cn's terminator answers with alert 80
//! (internal_error) — before any certificate is sent.
//!
//! This probe speaks raw TCP and sends hand-built ClientHellos with knobs,
//! so the culprit can be isolated by bisection. `std.http.Client` offers no
//! way to influence these fields, so whatever we learn here decides whether
//! the Zig client can reach this host at all.
//!
//! Usage (on the device, aarch64):
//!     ./hello_probe drive.quark.cn 443 zig          # reproduce std's hello
//!     ./hello_probe drive.quark.cn 443 no-mlkem
//!     ./hello_probe drive.quark.cn 443 sni-first
//!     ./hello_probe drive.quark.cn 443 no-sha1
//!     ./hello_probe drive.quark.cn 443 minimal
//!     ./hello_probe cloud.189.cn   443 zig          # control
//!
//! Build (on the build host):
//!     zig build-exe hello_probe.zig -O ReleaseSmall \
//!         -target aarch64-linux-musl -lc -femit-bin=hello_probe

const std = @import("std");

const Opts = struct {
    /// Offer x25519_ml_kem768 + send its (1216-byte) key share.
    ml_kem: bool = true,
    /// Put the server_name extension first instead of last.
    sni_first: bool = false,
    /// Include rsa_pkcs1_sha1 (0x0201) in signature_algorithms.
    sha1: bool = true,
    /// Offer TLS 1.3 (in addition to 1.2).
    tls13: bool = true,
    /// Offer TLS 1.2.
    tls12: bool = true,
    /// Send key shares only for x25519 (minimal, OpenSSL-like).
    minimal_shares: bool = false,
    /// Offer AEGIS_128L/AEGIS_256 (0x1307/0x1306) like Zig std does.
    aegis: bool = false,
};

const Group = struct { id: u16, share_len: usize };

const g_mlkem = Group{ .id = 0x11EC, .share_len = 1216 }; // x25519_ml_kem768
const g_p256 = Group{ .id = 0x0017, .share_len = 65 };
const g_p384 = Group{ .id = 0x0018, .share_len = 97 };
const g_x25519 = Group{ .id = 0x001d, .share_len = 32 };

fn put16(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
    try buf.append(a, @intCast(v >> 8));
    try buf.append(a, @intCast(v & 0xff));
}
fn put24(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: usize) !void {
    try buf.append(a, @intCast((v >> 16) & 0xff));
    try buf.append(a, @intCast((v >> 8) & 0xff));
    try buf.append(a, @intCast(v & 0xff));
}

fn buildClientHello(a: std.mem.Allocator, host: []const u8, opts: Opts) ![]u8 {
    // -- server_name (0x0000) ---------------------------------------------
    var sni_ext: std.ArrayList(u8) = .empty;
    try put16(&sni_ext, a, @intCast(1 + 2 + host.len)); // server_name_list length
    try sni_ext.append(a, 0x00); // name_type: host_name
    try put16(&sni_ext, a, @intCast(host.len));
    try sni_ext.appendSlice(a, host);

    // -- supported_versions (0x002b) --------------------------------------
    // Extension body: versions<1..255> — one-byte length prefix.
    var ver: std.ArrayList(u8) = .empty;
    if (opts.tls13 and opts.tls12) {
        try ver.append(a, 4); // 2 versions * 2 bytes
        try put16(&ver, a, 0x0304);
        try put16(&ver, a, 0x0303);
    } else if (opts.tls13) {
        try ver.append(a, 2); // 1 version * 2 bytes — TLS 1.3 ONLY
        try put16(&ver, a, 0x0304);
    } else {
        try ver.append(a, 2); // 1 version * 2 bytes
        try put16(&ver, a, 0x0303);
    }

    // -- signature_algorithms (0x000d) ------------------------------------
    const sig_algs = [_]u16{
        0x0403, // ecdsa_secp256r1_sha256
        0x0503, // ecdsa_secp384r1_sha384
        0x0401, // rsa_pkcs1_sha256
        0x0501, // rsa_pkcs1_sha384
        0x0601, // rsa_pkcs1_sha512
        0x0804, // rsa_pss_rsae_sha256
        0x0805, // rsa_pss_rsae_sha384
        0x0806, // rsa_pss_rsae_sha512
        0x0809, // rsa_pss_pss_sha256
        0x080a, // rsa_pss_pss_sha384
        0x080b, // rsa_pss_pss_sha512
        0x0201, // rsa_pkcs1_sha1  (the one under test)
        0x0807, // ed25519
    };
    var sig: std.ArrayList(u8) = .empty;
    var sig_body: std.ArrayList(u8) = .empty;
    for (sig_algs) |sa| {
        if (sa == 0x0201 and !opts.sha1) continue;
        try put16(&sig_body, a, sa);
    }
    try put16(&sig, a, @intCast(sig_body.items.len));
    try sig.appendSlice(a, sig_body.items);

    // -- supported_groups (0x000a) ----------------------------------------
    // Extension body: named_group_list<2..2^16-1> — two-byte length prefix.
    var group_ids: std.ArrayList(u16) = .empty;
    if (opts.ml_kem) try group_ids.append(a, g_mlkem.id);
    try group_ids.append(a, g_p256.id);
    try group_ids.append(a, g_p384.id);
    try group_ids.append(a, g_x25519.id);
    var groups: std.ArrayList(u8) = .empty;
    try put16(&groups, a, @intCast(group_ids.items.len * 2));
    for (group_ids.items) |gid| try put16(&groups, a, gid);

    // -- key_share (0x0033) ------------------------------------------------
    var ks: std.ArrayList(u8) = .empty;
    var ks_body: std.ArrayList(u8) = .empty;
    var shares: std.ArrayList(Group) = .empty;
    if (opts.minimal_shares) {
        try shares.append(a, g_x25519);
    } else {
        if (opts.ml_kem) try shares.append(a, g_mlkem);
        try shares.append(a, g_p256);
        try shares.append(a, g_p384);
        try shares.append(a, g_x25519);
    }
    for (shares.items) |g| {
        try put16(&ks_body, a, g.id);
        try put16(&ks_body, a, @intCast(g.share_len));
        // Uncompressed EC points must start with 0x04; a strict server
        // (cloud.189.cn) rejects malformed points with illegal_parameter.
        // Zig sends real keys; we fake structurally-valid ones.
        var seed: u64 = 0x243F6A8885A308D3;
        var i: usize = 0;
        while (i < g.share_len) : (i += 1) {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            if (i == 0 and (g.id == 0x0017 or g.id == 0x0018)) {
                try ks_body.append(a, 0x04);
            } else {
                try ks_body.append(a, @intCast((seed >> 33) & 0xff));
            }
        }
    }
    try put16(&ks, a, @intCast(ks_body.items.len));
    try ks.appendSlice(a, ks_body.items);

    // -- psk_key_exchange_modes (0x002d) -----------------------------------
    // Extension body: ke_modes<1..255> — one-byte length prefix.
    const psk = [_]u8{ 0x01, 0x01 }; // len=1, psk_dhe_ke

    // -- assemble, in Zig std's order unless sni_first ----------------------
    // Zig order: supported_versions, signature_algorithms, supported_groups,
    //            psk_key_exchange_modes, key_share, server_name(LAST).
    const Ext = struct { id: u16, body: []const u8 };
    const exts_sni_last = [_]Ext{
        .{ .id = 0x002b, .body = ver.items },
        .{ .id = 0x000d, .body = sig.items },
        .{ .id = 0x000a, .body = groups.items },
        .{ .id = 0x002d, .body = &psk },
        .{ .id = 0x0033, .body = ks.items },
        .{ .id = 0x0000, .body = sni_ext.items },
    };
    const exts_sni_first = [_]Ext{
        .{ .id = 0x0000, .body = sni_ext.items },
        .{ .id = 0x002b, .body = ver.items },
        .{ .id = 0x000d, .body = sig.items },
        .{ .id = 0x000a, .body = groups.items },
        .{ .id = 0x002d, .body = &psk },
        .{ .id = 0x0033, .body = ks.items },
    };
    const exts = if (opts.sni_first) &exts_sni_first else &exts_sni_last;
    var ext: std.ArrayList(u8) = .empty;
    for (exts) |e| {
        try put16(&ext, a, e.id);
        try put16(&ext, a, @intCast(e.body.len));
        try ext.appendSlice(a, e.body);
    }

    // -- ClientHello body ---------------------------------------------------
    // Zig std's list (std/crypto/tls/Client.zig `cipher_suites`): AEGIS first
    // (0x1306/0x1307 — very new, unknown to many terminators), then the
    // standard 1.3 suites and ECDHE-RSA 1.2 suites (no ECDSA suites).
    var ciphers: std.ArrayList(u16) = .empty;
    if (opts.aegis) {
        try ciphers.append(a, 0x1307); // AEGIS_128L_SHA256
        try ciphers.append(a, 0x1306); // AEGIS_256_SHA512
    }
    for ([_]u16{
        0x1301, 0xc02f, 0x1302, 0xc030, 0x1303, 0xcca8, // TLS 1.3 + ECDHE-RSA
        0xc02b, 0xc02c, 0xcca9, // ECDHE-ECDSA (Zig omits these)
    }) |c| try ciphers.append(a, c);
    var ch: std.ArrayList(u8) = .empty;
    try ch.appendSlice(a, &.{ 0x03, 0x03 }); // legacy_version
    var i: usize = 0;
    while (i < 32) : (i += 1) try ch.append(a, @intCast(i *% 7 + 13)); // deterministic random
    try ch.append(a, 0x00); // session_id
    try put16(&ch, a, @intCast(ciphers.items.len * 2));
    for (ciphers.items) |c| try put16(&ch, a, c);
    try ch.append(a, 0x01);
    try ch.append(a, 0x00); // compression: null
    try put16(&ch, a, @intCast(ext.items.len));
    try ch.appendSlice(a, ext.items);

    // -- record -------------------------------------------------------------
    var rec: std.ArrayList(u8) = .empty;
    try rec.append(a, 0x16); // handshake
    try rec.appendSlice(a, &.{ 0x03, 0x01 }); // legacy record version
    try put16(&rec, a, @intCast(ch.items.len + 4)); // 4 = handshake header
    try rec.append(a, 0x01); // client_hello
    try put24(&rec, a, ch.items.len);
    try rec.appendSlice(a, ch.items);
    return rec.toOwnedSlice(a);
}

fn describe(buf: []const u8) void {
    if (buf.len < 5) {
        std.debug.print("  short response ({d} bytes)\n", .{buf.len});
        return;
    }
    const rec_type = buf[0];
    const len = (@as(usize, buf[3]) << 8) | buf[4];
    std.debug.print("  record type=0x{x:0>2} len={d} (have {d} bytes)\n", .{ rec_type, len, buf.len - 5 });
    if (rec_type == 0x15) { // alert
        if (buf.len >= 7) {
            std.debug.print("  ALERT level={s} description={d} ({s})\n", .{
                if (buf[5] == 1) "warning" else if (buf[5] == 2) "fatal" else "?",
                buf[6],
                switch (buf[6]) {
                    0 => "close_notify",
                    10 => "unexpected_message",
                    40 => "handshake_failure",
                    42 => "bad_certificate",
                    43 => "unsupported_certificate",
                    46 => "certificate_unknown",
                    47 => "illegal_parameter",
                    48 => "unknown_ca",
                    50 => "decode_error",
                    70 => "protocol_version",
                    71 => "insufficient_security",
                    80 => "internal_error",
                    86 => "inappropriate_fallback",
                    110 => "unsupported_extension",
                    112 => "unrecognized_name",
                    120 => "no_application_protocol",
                    else => "?",
                },
            });
        }
    } else if (rec_type == 0x16 and buf.len >= 6 and buf[5] == 0x02) { // server_hello
        const legacy: []const u8 = buf[6..8];
        std.debug.print("  SERVERHELLO legacy_version=0x{x:0>2}{x:0>2}\n", .{ legacy[0], legacy[1] });
        // scan extensions for supported_versions (0x002b)
        var i: usize = 5 + 2 + 32 + 1; // record hdr + version + random + sid_len
        if (i >= buf.len) return;
        const sid_len = buf[i - 1];
        i += sid_len + 2 + 1 + 2; // sid + cipher + comp + ext_len
        while (i + 4 <= buf.len) {
            const eid = (@as(usize, buf[i]) << 8) | buf[i + 1];
            const elen = (@as(usize, buf[i + 2]) << 8) | buf[i + 3];
            if (eid == 0x002b and elen == 2) {
                std.debug.print("  negotiated supported_version=0x{x:0>2}{x:0>2} ({s})\n", .{
                    buf[i + 4], buf[i + 5],
                    if (buf[i + 4] == 0x03 and buf[i + 5] == 0x04) "TLS 1.3" else "TLS 1.2",
                });
            }
            i += 4 + elen;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    _ = args.next();
    const host = args.next() orelse return error.MissingHost;
    const port_s = args.next() orelse return error.MissingPort;
    const port = try std.fmt.parseInt(u16, port_s, 10);
    var opts = Opts{};
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "zig")) {
            opts = .{}; // std's hello: ml_kem on, sha1 on, sni last, 1.3+1.2
        } else if (std.mem.eql(u8, flag, "no-mlkem")) {
            opts.ml_kem = false;
        } else if (std.mem.eql(u8, flag, "sni-first")) {
            opts.sni_first = true;
        } else if (std.mem.eql(u8, flag, "no-sha1")) {
            opts.sha1 = false;
        } else if (std.mem.eql(u8, flag, "tls12-only")) {
            opts.tls13 = false;
            opts.ml_kem = false;
        } else if (std.mem.eql(u8, flag, "tls13-only")) {
            opts.tls12 = false;
            opts.ml_kem = false;
        } else if (std.mem.eql(u8, flag, "minimal")) {
            opts = .{ .ml_kem = false, .sha1 = false, .sni_first = true, .minimal_shares = true };
        } else if (std.mem.eql(u8, flag, "aegis")) {
            opts.aegis = true;
        } else if (std.mem.eql(u8, flag, "zig-plus-aegis")) {
            opts = .{ .aegis = true };
        }
    }

    const hello = try buildClientHello(a, host, opts);
    std.debug.print("hello {s}:{d} ml_kem={} sha1={} sni_first={} tls13={} minimal_shares={} -> {d} bytes\n", .{
        host, port, opts.ml_kem, opts.sha1, opts.sni_first, opts.tls13, opts.minimal_shares, hello.len,
    });

    const hn = try std.Io.net.HostName.init(host);
    const stream = try hn.connect(init.io, port, .{ .mode = .stream });
    defer stream.close(init.io);
    // Bounded reads: after ServerHello a TLS 1.3 server waits for the client's
    // next flight, so a naive read would block forever.
    const tv = std.posix.timeval{ .sec = 5, .usec = 0 };
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    var w = stream.writer(init.io, &.{});
    try w.interface.writeAll(hello);
    try w.interface.flush();

    var r = stream.reader(init.io, &.{});
    var total: usize = 0;
    var got_alert = false;
    while (total < 16384) {
        var buf: [4096]u8 = undefined;
        const n = r.interface.readSliceShort(&buf) catch |e| {
            std.debug.print("  read failed: {s}\n", .{@errorName(e)});
            return e;
        };
        if (n == 0) {
            std.debug.print("  EOF after {d} bytes\n", .{total});
            return;
        }
        total += n;
        describe(buf[0..n]);
        if (buf[0] == 0x15) {
            got_alert = true;
            break;
        }
    }
    if (!got_alert) std.debug.print("  (no alert in first {d} bytes)\n", .{total});
}
