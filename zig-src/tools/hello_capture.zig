//! Capture the exact ClientHello bytes that `std.crypto.tls.Client` sends.
//!
//! Listens on 127.0.0.1:<port>, accepts one connection, hexdumps the first
//! bytes to stderr, then closes. Point `tls_probe` at it to record what the
//! real Zig TLS client puts on the wire — the ground truth for comparing
//! against hand-built hellos (see hello_probe.zig).
//!
//! Build: zig build-exe hello_capture.zig -O ReleaseSmall \
//!            -target aarch64-linux-musl -lc -femit-bin=hello_capture

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    _ = args.next();
    const port_s = args.next() orelse return error.MissingPort;
    const port = try std.fmt.parseInt(u16, port_s, 10);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try addr.listen(init.io, .{});
    defer server.deinit(init.io);
    std.debug.print("listening on 127.0.0.1:{d}\n", .{port});

    var stream: std.Io.net.Stream = undefined;
    while (true) {
        stream = server.accept(init.io) catch |e| {
            std.debug.print("accept failed: {s}\n", .{@errorName(e)});
            continue;
        };
        break;
    }
    defer stream.close(init.io);

    var r = stream.reader(init.io, &.{});
    var buf: [2048]u8 = undefined;
    const n = r.interface.readSliceShort(&buf) catch |e| {
        std.debug.print("read failed: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print("captured {d} bytes\n", .{n});
    var i: usize = 0;
    while (i < n) : (i += 16) {
        const end = @min(i + 16, n);
        std.debug.print("{d:0>4}  ", .{i});
        for (buf[i..end]) |b| std.debug.print("{x:0>2} ", .{b});
        std.debug.print("\n", .{});
    }
}
