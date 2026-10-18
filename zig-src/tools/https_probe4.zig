//! probe4 = probe3 + openlist 独有的 applySocketTimeout（SO_RCVTIMEO/SNDTIMEO），
//! 验证「握手后设 socket 超时」是不是触发 16KB 畸形记录的开关。
//!
//! Usage: https_probe4 <url> <cookie> <referer> <ua> [--timeout=60] [--runs=N]
//!
//! Build (on the build host):
//!   ZIG_LIB_DIR=/tmp/olz-build/ziglib zig build-exe tools/https_probe4.zig -lc \
//!       -O ReleaseSmall -target aarch64-linux-musl -femit-bin=https_probe4

const std = @import("std");
const builtin = @import("builtin");

var g_io: std.Io = undefined;
var t0: i64 = 0;

fn ms() i64 {
    return std.Io.Clock.awake.now(g_io).toMilliseconds() - t0;
}

/// 与 openlist src/client.zig 的 applySocketTimeout 逐字节一致。
fn applySocketTimeout(conn: *std.http.Client.Connection, seconds: u32) void {
    if (seconds == 0) return;
    if (comptime builtin.os.tag == .windows) return;
    const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
    const handle = conn.stream_reader.stream.socket.handle;
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
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
    var timeout_s: u32 = 0; // 默认不设 —— 对照
    var runs: u32 = 1;
    while (args.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "--timeout=")) {
            timeout_s = std.fmt.parseInt(u32, flag["--timeout=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, flag, "--runs=")) {
            runs = std.fmt.parseInt(u32, flag["--runs=".len..], 10) catch 1;
        }
    }

    // SSLKEYLOG（runner 会在每次执行前删除文件；单次进程内顺序追加）
    var kfile = try std.Io.Dir.cwd().createFile(init.io, "/tmp/probe/keys4.log", .{ .truncate = false });
    var kbuf: [8 * 1024]u8 = undefined;
    var kw = kfile.writer(init.io, &kbuf);
    var key_log: std.crypto.tls.Client.SslKeyLog = .{
        .client_key_seq = 0,
        .server_key_seq = 0,
        .client_random = undefined,
        .writer = &kw.interface,
    };

    var run: u32 = 0;
    while (run < runs) : (run += 1) {
        std.debug.print("[t={d}ms] === run {d}/{d} timeout={d}s ===\n", .{ ms(), run + 1, runs, timeout_s });
        var client: std.http.Client = .{ .allocator = a, .io = init.io };
        client.ssl_key_log = &key_log;

        const uri = try std.Uri.parse(url);
        var hdrs = [_]std.http.Header{
            .{ .name = "Cookie", .value = cookie },
            .{ .name = "Referer", .value = referer },
            .{ .name = "User-Agent", .value = ua },
            .{ .name = "Accept-Encoding", .value = "identity" },
        };
        var req = client.request(.GET, uri, .{
            .extra_headers = &hdrs,
            .keep_alive = true,
            .redirect_behavior = .unhandled,
            .headers = .{ .user_agent = .omit, .accept_encoding = .omit },
        }) catch |e| {
            std.debug.print("[t={d}ms] run {d}: request FAILED: {s}\n", .{ ms(), run + 1, @errorName(e) });
            continue;
        };
        defer req.deinit();
        if (timeout_s > 0 and req.connection != null) applySocketTimeout(req.connection.?, timeout_s);
        std.debug.print("[t={d}ms] run {d}: connected, timeout_applied={}\n", .{ ms(), run + 1, timeout_s > 0 });

        req.sendBodiless() catch |e| {
            std.debug.print("[t={d}ms] run {d}: sendBodiless FAILED: {s}\n", .{ ms(), run + 1, @errorName(e) });
            continue;
        };
        std.debug.print("[t={d}ms] run {d}: sent, awaiting head\n", .{ ms(), run + 1 });

        var rbuf: [8 * 1024]u8 = undefined;
        var resp = req.receiveHead(&rbuf) catch |e| {
            std.debug.print("[t={d}ms] run {d}: receiveHead FAILED: {s}\n", .{ ms(), run + 1, @errorName(e) });
            continue;
        };
        std.debug.print("[t={d}ms] run {d}: status={d}\n", .{ ms(), run + 1, @intFromEnum(resp.head.status) });
        var trbuf: [16 * 1024]u8 = undefined;
        const r = resp.reader(&trbuf);
        var chunk: [16 * 1024]u8 = undefined;
        var total: usize = 0;
        while (total < 4096) {
            const n = r.readSliceShort(&chunk) catch break;
            if (n == 0) break;
            total += n;
        }
        std.debug.print("[t={d}ms] run {d}: body {d} bytes\n", .{ ms(), run + 1, total });
    }
    kw.interface.flush() catch {};
    kfile.close(init.io);
    std.debug.print("[t={d}ms] done\n", .{ms()});
}
