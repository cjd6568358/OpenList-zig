//! https_probe v2 — 精确计量 + errno + 请求头发送变体。
//!
//! v1 已证明：TCP/TLS 握手成功 → 请求头 writeAll 成功 → 读响应 ReadFailed。
//! 而 std.http.Client 路径（openlist 实际使用）是：握手成功 → sendBodiless
//! （写请求头）直接 WriteFailed。两条路径对不上，v2 用它来找差异：
//!
//!   * 每阶段毫秒计时（握手/写头/读首字节）；
//!   * 读失败后立刻用裸 recv 取真实 errno（ECONNRESET? ETIMEDOUT?）；
//!   * --head=std   发送 http.Client 会产生的头（无 Connection、头序不同）
//!   * --head=curl  发送 curl 风格头（带 Accept: */*）
//!   * --chunk=N    把请求头按 N 字节分多次写（模拟 http.Client 1024B TLS 写缓冲）
//!   * --delay-ms=N 握手后延迟 N ms 再写头（测服务器有无「握手后空闲超时」）
//!   * --read-poll  写完头后 poll() 观察 socket 何时可读/出错（RST 到来时刻）
//!
//! Build (on the build host):
//!   ZIG_LIB_DIR=/tmp/olz-build/ziglib zig build-exe tools/https_probe2.zig -lc \
//!       -O ReleaseSmall -target aarch64-linux-musl -femit-bin=https_probe2

const std = @import("std");

var g_io: std.Io = undefined;
var t_start_ms: i64 = 0;

fn ms() i64 {
    return std.Io.Clock.awake.now(g_io).toMilliseconds() - t_start_ms;
}

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    g_io = init.io;
    t_start_ms = std.Io.Clock.awake.now(init.io).toMilliseconds();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    _ = args.next();
    const host = args.next() orelse return error.MissingHost;
    const port = try std.fmt.parseInt(u16, args.next() orelse "443", 10);
    const path = args.next() orelse return error.MissingPath;
    const cookie = args.next() orelse "";
    const referer = args.next() orelse "";
    const ua = args.next() orelse "";
    var timeout_s: u32 = 20;
    var head_style: []const u8 = "probe";
    var chunk: usize = 0;
    var delay_ms: u64 = 0;
    var read_poll = false;
    while (args.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "--head=")) {
            head_style = flag["--head=".len..];
        } else if (std.mem.startsWith(u8, flag, "--chunk=")) {
            chunk = std.fmt.parseInt(usize, flag["--chunk=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, flag, "--delay-ms=")) {
            delay_ms = std.fmt.parseInt(u64, flag["--delay-ms=".len..], 10) catch 0;
        } else if (std.mem.eql(u8, flag, "--read-poll")) {
            read_poll = true;
        } else {
            timeout_s = std.fmt.parseInt(u32, flag, 10) catch 20;
        }
    }

    std.debug.print("[t={d}ms] probe2 {s}:{d} path_len={d} head={s} chunk={d} delay={d}ms\n", .{
        ms(), host, port, path.len, head_style, chunk, delay_ms,
    });

    // ---- 连接（enumerate 所有地址，取第一个） -----------------------------
    const hn = try std.Io.net.HostName.init(host);
    var lookup_buf: [32]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buf);
    hn.lookup(init.io, &lookup_queue, .{ .port = port }) catch |e| {
        std.debug.print("DNS FAILED: {s}\n", .{@errorName(e)});
        return e;
    };
    var chosen: ?std.Io.net.IpAddress = null;
    while (true) {
        const res = lookup_queue.getOneUncancelable(init.io) catch break;
        switch (res) {
            .address => |addr| {
                if (chosen == null) chosen = addr;
            },
            .canonical_name => {},
        }
    }
    const addr = chosen orelse return error.UnknownHostName;
    std.debug.print("[t={d}ms] dns done, connecting {f}\n", .{ ms(), addr });
    var stream = try addr.connect(init.io, .{ .mode = .stream });
    defer stream.close(init.io);
    std.debug.print("[t={d}ms] tcp connected\n", .{ms()});
    const tv = std.posix.timeval{ .sec = @intCast(timeout_s), .usec = 0 };
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};

    var sock_rbuf: [64 * 1024]u8 = undefined;
    var sock_wbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(init.io, &sock_rbuf);
    var sw = stream.writer(init.io, &sock_wbuf);

    var tls_rbuf: [32 * 1024]u8 = undefined;
    var tls_wbuf: [32 * 1024]u8 = undefined;
    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    std.Io.random(init.io, &entropy);

    var client = std.crypto.tls.Client.init(&sr.interface, &sw.interface, .{
        .host = .{ .explicit = host },
        .ca = .no_verification,
        .read_buffer = &tls_rbuf,
        .write_buffer = &tls_wbuf,
        .entropy = &entropy,
        .realtime_now = std.Io.Clock.real.now(init.io),
    }) catch |e| {
        std.debug.print("[t={d}ms] TLS HANDSHAKE FAILED: {s}\n", .{ ms(), @errorName(e) });
        return e;
    };
    std.debug.print("[t={d}ms] tls handshake OK, version={s}\n", .{ ms(), @tagName(client.tls_version) });

    // ---- 构造请求头 --------------------------------------------------------
    var req: std.ArrayList(u8) = .empty;
    const w = &req;
    try w.appendSlice(a, "GET ");
    try w.appendSlice(a, path);
    try w.appendSlice(a, " HTTP/1.1\r\nHost: ");
    try w.appendSlice(a, host);
    try w.appendSlice(a, "\r\n");
    if (std.mem.eql(u8, head_style, "std")) {
        // std.http.Client 的顺序：Host, User-Agent, Cookie, Referer,
        // Accept-Encoding: identity（我们 extra_headers 的顺序，无 Connection）。
        if (ua.len > 0) {
            try w.appendSlice(a, "User-Agent: ");
            try w.appendSlice(a, ua);
            try w.appendSlice(a, "\r\n");
        }
        if (cookie.len > 0) {
            try w.appendSlice(a, "Cookie: ");
            try w.appendSlice(a, cookie);
            try w.appendSlice(a, "\r\n");
        }
        if (referer.len > 0) {
            try w.appendSlice(a, "Referer: ");
            try w.appendSlice(a, referer);
            try w.appendSlice(a, "\r\n");
        }
        try w.appendSlice(a, "Accept-Encoding: identity\r\n");
    } else if (std.mem.eql(u8, head_style, "curl")) {
        if (ua.len > 0) {
            try w.appendSlice(a, "User-Agent: ");
            try w.appendSlice(a, ua);
            try w.appendSlice(a, "\r\n");
        }
        try w.appendSlice(a, "Accept: */*\r\n");
        if (referer.len > 0) {
            try w.appendSlice(a, "Referer: ");
            try w.appendSlice(a, referer);
            try w.appendSlice(a, "\r\n");
        }
        if (cookie.len > 0) {
            try w.appendSlice(a, "Cookie: ");
            try w.appendSlice(a, cookie);
            try w.appendSlice(a, "\r\n");
        }
    } else {
        // probe v1 的顺序
        if (ua.len > 0) {
            try w.appendSlice(a, "User-Agent: ");
            try w.appendSlice(a, ua);
            try w.appendSlice(a, "\r\n");
        }
        if (cookie.len > 0) {
            try w.appendSlice(a, "Cookie: ");
            try w.appendSlice(a, cookie);
            try w.appendSlice(a, "\r\n");
        }
        if (referer.len > 0) {
            try w.appendSlice(a, "Referer: ");
            try w.appendSlice(a, referer);
            try w.appendSlice(a, "\r\n");
        }
        try w.appendSlice(a, "Accept-Encoding: identity\r\n");
        try w.appendSlice(a, "Connection: close\r\n");
    }
    try w.appendSlice(a, "\r\n");
    std.debug.print("[t={d}ms] head built: {d} bytes\n", .{ ms(), req.items.len });

    if (delay_ms > 0) {
        try std.Io.sleep(init.io, std.Io.Duration.fromMilliseconds(@intCast(delay_ms)), .awake);
        std.debug.print("[t={d}ms] delay elapsed, writing\n", .{ms()});
    }

    // ---- 写请求头 ----------------------------------------------------------
    if (chunk == 0) {
        client.writer.writeAll(req.items) catch |e| {
            std.debug.print("[t={d}ms] WRITE FAILED: {s}\n", .{ ms(), @errorName(e) });
            dumpErrno(stream.socket.handle);
            return e;
        };
        std.debug.print("[t={d}ms] writeAll done ({d} bytes, single write)\n", .{ ms(), req.items.len });
    } else {
        var off: usize = 0;
        while (off < req.items.len) {
            const n = @min(chunk, req.items.len - off);
            client.writer.writeAll(req.items[off .. off + n]) catch |e| {
                std.debug.print("[t={d}ms] WRITE FAILED at offset {d}/{d}: {s}\n", .{ ms(), off, req.items.len, @errorName(e) });
                dumpErrno(stream.socket.handle);
                return e;
            };
            std.debug.print("[t={d}ms] wrote chunk {d}+{d}\n", .{ ms(), off, n });
            off += n;
        }
    }
    client.writer.flush() catch |e| {
        std.debug.print("[t={d}ms] FLUSH FAILED: {s}\n", .{ ms(), @errorName(e) });
        dumpErrno(stream.socket.handle);
        return e;
    };
    // ⚠️ 双层刷：TLS 的 flush() 只把密文写进下游 stream writer 缓冲，
    // 不刷 socket —— 漏了它请求永远不上线（v1/v2 实测教训，详见 STATUS §30.3）。
    sw.interface.flush() catch |e| {
        std.debug.print("[t={d}ms] SOCKET FLUSH FAILED: {s}\n", .{ ms(), @errorName(e) });
        dumpErrno(stream.socket.handle);
        return e;
    };
    std.debug.print("[t={d}ms] flushed, reading\n", .{ms()});

    // ---- 读（可先 poll 观察 RST 到达时刻） ---------------------------------
    if (read_poll) {
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        var waited: u64 = 0;
        while (waited < timeout_s * 1000) : (waited += 250) {
            const n = std.posix.poll(&fds, 250) catch |e| {
                std.debug.print("[t={d}ms] poll FAILED: {s}\n", .{ ms(), @errorName(e) });
                break;
            };
            if (n > 0) {
                const rev = fds[0].revents;
                std.debug.print("[t={d}ms] poll wake: revents=0x{x}", .{ ms(), rev });
                if (rev & std.posix.POLL.IN != 0) std.debug.print(" (IN/可读或EOF/RST)", .{});
                if (rev & std.posix.POLL.HUP != 0) std.debug.print(" (HUP)", .{});
                if (rev & std.posix.POLL.ERR != 0) std.debug.print(" (ERR)", .{});
                std.debug.print("\n", .{});
                break;
            }
        }
        if (waited >= timeout_s * 1000) std.debug.print("[t={d}ms] poll: no event within {d}s\n", .{ ms(), timeout_s });
    }

    var total: usize = 0;
    while (total < 64 * 1024) {
        var buf: [16 * 1024]u8 = undefined;
        const n = client.reader.readSliceShort(&buf) catch |e| {
            std.debug.print("[t={d}ms] READ FAILED after {d} bytes: {s}\n", .{ ms(), total, @errorName(e) });
            dumpErrno(stream.socket.handle);
            return e;
        };
        if (n == 0) {
            std.debug.print("[t={d}ms] EOF after {d} bytes (clean)\n", .{ ms(), total });
            return;
        }
        total += n;
        if (total == n) {
            const show = @min(n, 600);
            std.debug.print("[t={d}ms] first response bytes:\n{s}\n", .{ ms(), buf[0..show] });
        }
    }
    std.debug.print("[t={d}ms] read {d} bytes (cap)\n", .{ ms(), total });
}

/// 读失败后用裸 read 取真实 errno —— ReadFailed 把 errno 吞掉了。
fn dumpErrno(fd: std.posix.fd_t) void {
    var tmp: [1]u8 = undefined;
    const r = std.posix.read(fd, &tmp) catch |e| {
        std.debug.print("  raw read errno: {s}\n", .{@errorName(e)});
        return;
    };
    std.debug.print("  raw read returned {d} (unexpected, byte=0x{x})\n", .{ r, tmp[0] });
}
