//! probe3：用 std.http.Client 复刻 openlist 的代理回源调用（同样的
//! extra_headers / keep_alive / redirect 选项），并打开 SSLKEYLOG ——
//! 把 TLS 主密钥写到 /tmp/probe/keys.log，配合 tcpdump 解密线上流量，
//! 看清 http.Client 路径究竟往 CDN 发了什么。
//!
//! Usage: https_probe3 <url> <cookie> <referer> <ua>
//!
//! Build (on the build host):
//!   ZIG_LIB_DIR=/tmp/olz-build/ziglib zig build-exe tools/https_probe3.zig -lc \
//!       -O ReleaseSmall -target aarch64-linux-musl -femit-bin=https_probe3

const std = @import("std");

var g_io: std.Io = undefined;
var t0: i64 = 0;

fn ms() i64 {
    return std.Io.Clock.awake.now(g_io).toMilliseconds() - t0;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    g_io = init.io;
    t0 = std.Io.Clock.awake.now(init.io).toMilliseconds();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    _ = args.next();
    const url = args.next() orelse return error.MissingUrl;
    const cookie = args.next() orelse "";
    const referer = args.next() orelse "";
    const ua = args.next() orelse "";

    // SSLKEYLOG（NSS 格式：CLIENT_RANDOM <cr> <master_secret>）
    var kfile = try std.Io.Dir.cwd().createFile(init.io, "/tmp/probe/keys.log", .{});
    var kbuf: [8 * 1024]u8 = undefined;
    var kw = kfile.writer(init.io, &kbuf);
    var key_log: std.crypto.tls.Client.SslKeyLog = .{
        .client_key_seq = 0,
        .server_key_seq = 0,
        .client_random = undefined,
        .writer = &kw.interface,
    };

    var client: std.http.Client = .{ .allocator = a, .io = init.io };
    client.ssl_key_log = &key_log;

    const uri = try std.Uri.parse(url);
    var hdrs = [_]std.http.Header{
        .{ .name = "Cookie", .value = cookie },
        .{ .name = "Referer", .value = referer },
        .{ .name = "User-Agent", .value = ua },
        .{ .name = "Accept-Encoding", .value = "identity" },
    };

    std.debug.print("[t={d}ms] probe3 GET url_len={d}\n", .{ ms(), url.len });
    var req = client.request(.GET, uri, .{
        .extra_headers = &hdrs,
        .keep_alive = true, // 与 openlist 代理回源一致（skip_body=false）
        .redirect_behavior = .unhandled,
        .headers = .{ .user_agent = .omit, .accept_encoding = .omit },
    }) catch |e| {
        std.debug.print("[t={d}ms] request FAILED: {s}\n", .{ ms(), @errorName(e) });
        kw.interface.flush() catch {};
        kfile.close(init.io);
        return e;
    };
    defer req.deinit();
    std.debug.print("[t={d}ms] connected (handshake done, conn={s})\n", .{
        ms(), if (req.connection != null) "yes" else "pooled",
    });

    req.sendBodiless() catch |e| {
        std.debug.print("[t={d}ms] sendBodiless FAILED: {s}\n", .{ ms(), @errorName(e) });
        kw.interface.flush() catch {};
        kfile.close(init.io);
        return e;
    };
    std.debug.print("[t={d}ms] sendBodiless OK, awaiting head\n", .{ms()});

    var rbuf: [8 * 1024]u8 = undefined;
    var resp = req.receiveHead(&rbuf) catch |e| {
        std.debug.print("[t={d}ms] receiveHead FAILED: {s}\n", .{ ms(), @errorName(e) });
        kw.interface.flush() catch {};
        kfile.close(init.io);
        return e;
    };
    std.debug.print("[t={d}ms] got head, status={d}\n", .{ ms(), @intFromEnum(resp.head.status) });

    var trbuf: [16 * 1024]u8 = undefined;
    const r = resp.reader(&trbuf);
    var chunk: [16 * 1024]u8 = undefined;
    var total: usize = 0;
    while (total < 8192) {
        const n = r.readSliceShort(&chunk) catch |e| {
            std.debug.print("[t={d}ms] body read failed after {d}: {s}\n", .{ ms(), total, @errorName(e) });
            break;
        };
        if (n == 0) break;
        total += n;
    }
    std.debug.print("[t={d}ms] body {d} bytes\n", .{ ms(), total });
    if (total > 0) std.debug.print("--- body head ---\n{s}\n", .{chunk[0..@min(total, 400)]});

    kw.interface.flush() catch {};
    kfile.close(init.io);
    std.debug.print("[t={d}ms] done, keys.log written\n", .{ms()});
}
