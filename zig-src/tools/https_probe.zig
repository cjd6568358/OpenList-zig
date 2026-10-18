//! Full HTTPS request probe — speaks raw TCP + `std.crypto.tls.Client`
//! (NOT `std.http.Client`) so every byte on the wire is under our control.
//!
//! Why this exists: the device's zig openlist proxies a Quark CDN download and
//! fails with `WriteFailed` in ~1s, while python/urllib from Windows against
//! the same URL + headers gets a clean 403 in 0.2s. Same cookie, same URL,
//! same network egress. Something about the request std.http.Client puts on
//! the wire makes the CDN reset the connection. This probe isolates it:
//!
//!   * hand-rolled request line/headers (byte-identical to what we intend)
//!   * `Connection: close` by default, `--keep-alive` to match std's default
//!   * prints negotiated TLS version and the raw response head
//!
//! Usage (on the device, aarch64):
//!     ./https_probe <host> <port> <path-with-query> [cookie] [referer] [ua] [timeout_s] [--keep-alive]
//!
//! Build (on the build host):
//!     zig build-exe https_probe.zig -O ReleaseSmall \
//!         -target aarch64-linux-musl -lc -femit-bin=https_probe

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    _ = args.next();
    const host = args.next() orelse return error.MissingHost;
    const port_s = args.next() orelse return error.MissingPort;
    const port = try std.fmt.parseInt(u16, port_s, 10);
    const path = args.next() orelse return error.MissingPath;
    const cookie = args.next() orelse "";
    const referer = args.next() orelse "";
    const ua = args.next() orelse "";
    var timeout_s: u32 = 20;
    var keep_alive = false;
    var family_arg: []const u8 = "any";
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "--keep-alive")) {
            keep_alive = true;
        } else if (std.mem.eql(u8, flag, "--family")) {
            family_arg = args.next() orelse "any";
        } else {
            timeout_s = std.fmt.parseInt(u32, flag, 10) catch 20;
        }
    }

    std.debug.print("probe {s}:{d} path_len={d} cookie_len={d} keep_alive={} timeout={d}s\n", .{
        host, port, path.len, cookie.len, keep_alive, timeout_s,
    });

    const hn = try std.Io.net.HostName.init(host);
    // 解析并打印所有地址，然后按 family 选择连接（默认 any = 并发连所有，
    // 谁先连上用谁 —— 设备上这可能选中 IPv6，而夸克 CDN 的 v6 路径会 RST）。
    var lookup_buf: [32]std.Io.net.HostName.LookupResult = undefined;
    var lookup_queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&lookup_buf);
    var family_opt: ?std.Io.net.IpAddress.Family = null;
    if (std.mem.eql(u8, family_arg, "ipv4")) family_opt = .ip4;
    if (std.mem.eql(u8, family_arg, "ipv6")) family_opt = .ip6;
    hn.lookup(init.io, &lookup_queue, .{ .port = port, .family = family_opt }) catch |e| {
        std.debug.print("DNS LOOKUP FAILED: {s}\n", .{@errorName(e)});
        return e;
    };
    var chosen: ?std.Io.net.IpAddress = null;
    while (true) {
        const res = lookup_queue.getOneUncancelable(init.io) catch break;
        switch (res) {
            .address => |addr| {
                std.debug.print("  resolved: {f}\n", .{addr});
                if (chosen == null) chosen = addr;
            },
            .canonical_name => |cn| std.debug.print("  canonical: {s}\n", .{cn.bytes}),
        }
    }
    const addr = chosen orelse {
        std.debug.print("no address resolved\n", .{});
        return error.UnknownHostName;
    };
    std.debug.print("connecting to {f} ...\n", .{addr});
    var stream = try addr.connect(init.io, .{ .mode = .stream });
    defer stream.close(init.io);
    const tv = std.posix.timeval{ .sec = @intCast(timeout_s), .usec = 0 };
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};

    // ⚠️ socket writer/reader 的 buffer 必须 >= std.crypto.tls.Client.min_buffer_len
    // （= max_ciphertext_record_len = 16640）。小于它，TLS flush 里的
    // `output.writableSliceGreedy(min_buffer_len)` 会走 `defaultRebase` ——
    // 那个 while 循环 drain 空数据、buffer 永不满，ReleaseSmall 下 assert
    // 被编译掉，结果就是 100% CPU 自旋（本探针第一版实测）。
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
        std.debug.print("TLS HANDSHAKE FAILED: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print("tls handshake OK, version={s}\n", .{@tagName(client.tls_version)});

    // Build the request by hand — byte-identical to what we intend on the wire.
    var req: std.ArrayList(u8) = .empty;
    const w = &req;
    try w.appendSlice(a, "GET ");
    try w.appendSlice(a, path);
    try w.appendSlice(a, " HTTP/1.1\r\nHost: ");
    try w.appendSlice(a, host);
    if (port != 443) try w.print(a, ":{d}", .{port});
    try w.appendSlice(a, "\r\n");
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
    try w.appendSlice(a, if (keep_alive) "Connection: keep-alive\r\n" else "Connection: close\r\n");
    try w.appendSlice(a, "\r\n");

    std.debug.print("--- request head ({d} bytes) ---\n", .{req.items.len});
    std.debug.print("{s}\n", .{req.items});
    std.debug.print("--- calling writeAll ---\n", .{});

    client.writer.writeAll(req.items) catch |e| {
        std.debug.print("WRITE FAILED: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print("--- writeAll done, calling flush ---\n", .{});
    client.writer.flush() catch |e| {
        std.debug.print("FLUSH FAILED: {s}\n", .{@errorName(e)});
        return e;
    };
    // ⚠️ 双层刷：TLS 的 flush() 只把密文写进**下游 stream writer 的缓冲**
    // （output.advance），不刷 socket。漏了这一步，请求会躺在 sock_wbuf 里
    // 永远发不出去，现象是「服务器静默 15s」——我们自己的数据没上线。
    // （2026-10-16 实测教训：probe v1/v2 都栽在这，产出过假结论。）
    sw.interface.flush() catch |e| {
        std.debug.print("SOCKET FLUSH FAILED: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print("--- flush done, reading response ---\n", .{});

    var total: usize = 0;
    var head_shown = false;
    while (total < 64 * 1024) {
        var buf: [16 * 1024]u8 = undefined;
        const n = client.reader.readSliceShort(&buf) catch |e| {
            std.debug.print("READ FAILED after {d} bytes: {s}\n", .{ total, @errorName(e) });
            return e;
        };
        if (n == 0) {
            std.debug.print("EOF after {d} bytes (clean)\n", .{total});
            return;
        }
        total += n;
        if (!head_shown) {
            const show = @min(n, 800);
            std.debug.print("--- first {d} response bytes ---\n{s}\n", .{ show, buf[0..show] });
            head_shown = true;
        }
    }
    std.debug.print("read {d} bytes (cap reached)\n", .{total});
}
