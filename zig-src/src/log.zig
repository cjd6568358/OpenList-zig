//! Tiny leveled logger.
//!
//! Writes to stderr via `std.debug.print`, which is the one output path that
//! has not moved between Zig 0.11 and 0.17 (`std.io.getStdOut()` and
//! `File.writer()` both did). A 光猫 has no journald and the binary runs under
//! a supervisor that captures stderr, so stderr-only is also the right choice
//! operationally. File logging is done by the caller if it wants it.

const std = @import("std");
const builtin = @import("builtin");
const Buf = @import("util/buf.zig").Buf;
const rt = @import("rt.zig");
const time_util = @import("util/time.zig");

// ---------------------------------------------------------------------------
// 日志时间戳
//
// 为什么加：2026-10-24 生产实例在 `config/import` 后静默死亡，复盘时日志
// **没有时间戳**，最后一行之后发生了什么全靠猜——既无法与看门狗的 DOWN
// 记录对齐，也无法与 dmesg 对齐。上游 Go 每行都带时间戳
// （internal/bootstrap/log.go:16-21：`FullTimestamp: true` +
// `TimestampFormat: "2006-01-02 15:04:05"`），这是对齐上游，不是发明。
//
// 时区从哪来：Linux 上走 libc `localtime_r`——musl/glibc 都按 TZ 环境变量
// 或 /etc/localtime 解析，与 busybox `date` 同源，所以日志时间戳和设备上
// 其他工具（看门狗、user_init.log）用的是同一个时钟。其余平台（Windows
// 测试构建）退到 UTC：格式一致，只差时区，测试只钉固定偏移的纯路径。
// ---------------------------------------------------------------------------

const have_libc_localtime = builtin.os.tag == .linux;

/// musl/glibc 的 `struct tm`。只在 Linux 分支里真正使用。
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

// 声明无条件给出，但**只在 Linux 分支被引用** —— Zig 不为未引用的 extern
// 函数生成符号，Windows 测试构建不会因此链接失败。
extern "c" fn localtime_r(timep: *const i64, result: *Tm) ?*Tm;

/// 本地时间相对 UTC 的偏移（秒）。失败按 0（退化成 UTC）——时间戳帮助排障，
/// 不值得为它引入失败路径。
fn tzOffset(unix_s: i64) i64 {
    if (comptime !have_libc_localtime) return 0;
    var t = unix_s;
    var tm: Tm = undefined;
    const p = localtime_r(&t, &tm) orelse return 0;
    return p.tm_gmtoff;
}

/// 纯格式化：`2026-10-24 11:56:55`。`offset_s` 显式传入，便于测试钉死。
fn stampAt(buf: []u8, unix_s: i64, offset_s: i64) []const u8 {
    const local = unix_s + offset_s;
    const days = @divFloor(local, time_util.SECONDS_PER_DAY);
    const c = time_util.civilFromDays(days);
    const t = time_util.splitSeconds(@mod(local, time_util.SECONDS_PER_DAY));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(c.y)),
        @as(u32, @intCast(c.m)),
        @as(u32, @intCast(c.d)),
        @as(u32, @intCast(t.h)),
        @as(u32, @intCast(t.m)),
        @as(u32, @intCast(t.s)),
    }) catch "????-??-?? ??:??:??";
}

/// 本地时间戳（Linux 走 libc，其余 UTC）。
pub fn stamp(buf: []u8, unix_s: i64) []const u8 {
    return stampAt(buf, unix_s, tzOffset(unix_s));
}

pub const Level = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
    off = 4,

    pub fn parse(s: []const u8) Level {
        if (std.ascii.eqlIgnoreCase(s, "debug")) return .debug;
        if (std.ascii.eqlIgnoreCase(s, "info")) return .info;
        if (std.ascii.eqlIgnoreCase(s, "warn") or std.ascii.eqlIgnoreCase(s, "warning")) return .warn;
        if (std.ascii.eqlIgnoreCase(s, "error") or std.ascii.eqlIgnoreCase(s, "err")) return .err;
        if (std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "none")) return .off;
        return .info;
    }

    pub fn tag(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
            .off => "",
        };
    }
};

var g_level: Level = .info;
var g_lock: std.Io.Mutex = .init;

pub fn setLevel(l: Level) void {
    g_level = l;
}

pub fn level() Level {
    return g_level;
}

/// Comptime-format logging. Kept as a comptime-fmt API on purpose: it avoids
/// allocating on the hot path and matches `std.debug.print`'s contract.
pub fn log(comptime l: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(l) < @intFromEnum(g_level)) return;
    g_lock.lockUncancelable(rt.io());
    defer g_lock.unlock(rt.io());
    var tbuf: [20]u8 = undefined;
    std.debug.print("[{s}] [{s}] " ++ fmt ++ "\n", .{ stamp(&tbuf, rt.nowSeconds()), l.tag() } ++ args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

/// Runtime-format variant for call sites that build the message themselves
/// (e.g. forwarding an error string from a driver). Costs one stack buffer.
pub fn raw(l: Level, msg: []const u8) void {
    if (@intFromEnum(l) < @intFromEnum(g_level)) return;
    g_lock.lockUncancelable(rt.io());
    defer g_lock.unlock(rt.io());
    var tbuf: [20]u8 = undefined;
    std.debug.print("[{s}] [{s}] {s}\n", .{ stamp(&tbuf, rt.nowSeconds()), l.tag(), msg });
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "stampAt renders 2006-01-02 15:04:05 at an explicit offset" {
    var buf: [20]u8 = undefined;
    // 向量由 Python datetime 独立算出。
    // 1970-01-01 00:00:00 UTC 在 UTC+8 看是 08:00:00。
    try testing.expectEqualStrings("1970-01-01 08:00:00", stampAt(&buf, 0, 8 * 3600));
    // 零偏移 = UTC。
    try testing.expectEqualStrings("1970-01-01 00:00:00", stampAt(&buf, 0, 0));
    // 负纪元：divFloor/mod 必须向负无穷取整，否则会差一天。
    try testing.expectEqualStrings("1969-12-31 23:59:59", stampAt(&buf, -1, 0));
    try testing.expectEqualStrings("1970-01-01 07:59:59", stampAt(&buf, -1, 8 * 3600));
    // 崩溃复盘当天：2026-10-24 11:56:55 +08:00 == epoch 1792814215。
    try testing.expectEqualStrings("2026-10-24 11:56:55", stampAt(&buf, 1_792_814_215, 8 * 3600));
    // 补零/截断：单位数月日时分秒都要零填充。
    try testing.expectEqualStrings("2027-01-15 08:00:00", stampAt(&buf, 1_800_000_000, 0));
    // 缓冲区不够时退化成问号串，绝不 panic（日志路径不能炸）。
    try testing.expectEqualStrings("????-??-?? ??:??:??", stampAt(buf[0..4], 0, 0));
}

test "stamp() produces the same shape on this host" {
    var buf: [20]u8 = undefined;
    const s = stamp(&buf, rt.nowSeconds());
    // 形状检查：19 字节、数字与分隔符就位。值随本机 TZ 而变，不钉死。
    try testing.expectEqual(@as(usize, 19), s.len);
    try testing.expectEqual(@as(u8, '-'), s[4]);
    try testing.expectEqual(@as(u8, '-'), s[7]);
    try testing.expectEqual(@as(u8, ' '), s[10]);
    try testing.expectEqual(@as(u8, ':'), s[13]);
    try testing.expectEqual(@as(u8, ':'), s[16]);
    for (s, 0..) |c, i| {
        if (i == 4 or i == 7) continue;
        if (i == 10) continue;
        if (i == 13 or i == 16) continue;
        try testing.expect(std.ascii.isDigit(c));
    }
}
