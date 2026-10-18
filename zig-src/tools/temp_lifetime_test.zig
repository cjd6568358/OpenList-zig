//! 验证：`return &[_]T{...}`（运行时值）返回后在调用方是否仍然有效。
const std = @import("std");

const H = struct { name: []const u8, value: []const u8 };
const L = struct { header: []const H, url: []const u8 };

fn make(cookie: []const u8) L {
    return .{
        .url = "https://example.com/x",
        .header = &[_]H{
            .{ .name = "Cookie", .value = cookie },
            .{ .name = "Referer", .value = "https://pan.quark.cn" },
            .{ .name = "User-Agent", .value = "UA/1.0" },
        },
    };
}

fn pollute() void {
    var junk: [16384]u8 = undefined;
    @memset(&junk, 0xAA);
    std.mem.doNotOptimizeAway(&junk);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var cookie_buf: [1914]u8 = undefined;
    @memset(&cookie_buf, 'A');
    const cookie: []const u8 = &cookie_buf;
    var bad: usize = 0;
    var it: usize = 0;
    while (it < 8) : (it += 1) {
        const l = make(cookie);
        pollute();
        pollute();
        const h = l.header[0];
        const ok = std.mem.eql(u8, h.name, "Cookie") and
            h.value.len == 1914 and h.value[0] == 'A' and h.value[1913] == 'A';
        if (!ok) bad += 1;
        std.debug.print("iter {d}: ok={} name.len={d} value.len={d}\n", .{ it, ok, h.name.len, h.value.len });
    }
    std.debug.print("BAD={d}/8\n", .{bad});
}
