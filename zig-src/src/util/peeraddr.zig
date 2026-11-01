//! 取一条已建立连接的对端 IP。
//!
//! ## 为什么需要单独一个文件
//!
//! `std.Io.net.Stream` 只暴露 `socket.handle` 和一个「本地地址」字段，**没有**
//! 对端地址；`std.posix.getpeername` 在 Windows 上直接 `@compileError("use
//! std.Io instead")`，而 `std.Io` 并没有提供替代品（`Io/Threaded.zig` 的
//! `netAcceptWindows` 其实从 `AFD.WAIT_FOR_LISTEN` 拿到了 `RemoteAddress`，
//! 但在构造 `Socket` 时丢掉了）。所以想在 Windows 上拿到对端 IP，只能绕过
//! 标准库 —— 而 Zig 的 Windows socket 是通过 `\Device\Afd` 打开的设备句柄，
//! winsock 的 `getpeername` 对这类句柄不保证有效。
//!
//! 结论：**POSIX 上有，Windows 上明确没有**。调用方必须把 `null` 当成
//! 「拿不到」，退化到全局策略，而不是当成「没有对端」。
//!
//! ## 为什么只返回 IP、不带端口
//!
//! 认证失败计数要按来源分桶。上游 Go 版用 `IP:端口`，而扫描器的源端口每次
//! 都不同 ⇒ 每个端口一个桶 ⇒ 计数永远到不了阈值，限速形同虚设
//! （`docs/STATUS.md` §9）。这里刻意只输出地址部分 —— 注意 `std` 的
//! `Ip4Address.format` / `Ip6Address.format` 都会拼上 `:端口`，所以不能用
//! 它们，否则每个桶的键都长成 `1.2.3.4:0`。

const std = @import("std");
const builtin = @import("builtin");

/// 足够放下最长的 IPv6 文本（45 字符）+ 结尾 0。
pub const max_len: usize = 64;

/// 把 `stream` 的对端 IP 写进 `buf`，返回其切片；拿不到则返回 null
/// （Windows，或 socket 已断开）。
pub fn ipString(buf: []u8, stream: std.Io.net.Stream) ?[]const u8 {
    if (comptime builtin.os.tag == .windows) {
        return ipStringUnsupported(buf, stream);
    } else {
        return ipStringPosix(buf, stream.socket.handle);
    }
}

/// Windows：`std.Io` 没有对端地址，winsock 的 `getpeername` 又不对 AFD 句柄
/// 生效（见文件头）。明确返回 null，让调用方退化到全局桶。
fn ipStringUnsupported(_: []u8, _: std.Io.net.Stream) ?[]const u8 {
    return null;
}

fn ipStringPosix(buf: []u8, fd: std.posix.socket_t) ?[]const u8 {
    var storage: std.posix.sockaddr.storage = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    std.posix.getpeername(fd, @ptrCast(&storage), &len) catch return null;

    // 只认 IP 族。Unix domain socket 没有「来源 IP」，返回 null 让调用方
    // 退化到全局桶。
    return switch (storage.family) {
        std.posix.AF.INET => blk: {
            const sin: *const std.posix.sockaddr.in = @ptrCast(&storage);
            // `sin.addr` 在内存里就是网络序的 4 个字节，按内存序取即可；
            // 按整数读出来再转换会把字节序搞反（1.2.3.4 变成 4.3.2.1）。
            break :blk format4(buf, @as(*const [4]u8, @ptrCast(&sin.addr)).*);
        },
        std.posix.AF.INET6 => blk: {
            const sin6: *const std.posix.sockaddr.in6 = @ptrCast(&storage);
            break :blk format6(buf, sin6.addr);
        },
        else => null,
    };
}

/// `1.2.3.4` —— 拼不成（缓冲区太小）返回 null。
fn format4(buf: []u8, octets: [4]u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{d}.{d}.{d}.{d}", .{ octets[0], octets[1], octets[2], octets[3] }) catch return null;
    return w.buffered();
}

/// 标准压缩形式（`::1`、`fd00::1`），不带方括号、不带端口。
fn format6(buf: []u8, bytes: [16]u8) ?[]const u8 {
    const unresolved: std.Io.net.Ip6Address.Unresolved = .{ .bytes = bytes, .interface_name = null };
    var w = std.Io.Writer.fixed(buf);
    unresolved.format(&w) catch return null;
    return w.buffered();
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "peeraddr: 缓冲区足够容纳最长 IPv6 文本" {
    // "ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255" = 45 字节。
    // 缓冲区比它小的话 `format` 会返回 `error.WriteFailed`，调用方只能看到
    // null —— 完全静默的降级，所以这条算术固定下来。
    try testing.expect(max_len >= 46);
}

test "peeraddr: IPv4 按内存序取字节（不反转）" {
    // `sockaddr.in.addr` 是网络序（大端）存在一个 u32 里。按整数读出来再
    // 转成字符串，在小端机器上会得到 4.3.2.1 —— 而这个地址会变成限速的桶
    // 键，写错了不会有任何报错，只会让「同一个来源」看起来是每个包一个新
    // 来源。
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("1.2.3.4", format4(&buf, .{ 1, 2, 3, 4 }).?);
    try testing.expectEqualStrings("192.168.1.1", format4(&buf, .{ 192, 168, 1, 1 }).?);
}

test "peeraddr: IPv6 输出压缩形式且不带端口" {
    // 带上 `:0` 也能当桶键（仍然唯一），但日志里会很难看，而且和「纯 IP」
    // 这个约定不符 —— 万一以后要和别的来源对齐，键就对不上了。
    var buf: [max_len]u8 = undefined;

    var loopback: [16]u8 = @splat(0);
    loopback[15] = 1;
    try testing.expectEqualStrings("::1", format6(&buf, loopback).?);

    var global: [16]u8 = @splat(0);
    global[0] = 0xfd;
    global[15] = 0x01;
    try testing.expectEqualStrings("fd00::1", format6(&buf, global).?);
}

test "peeraddr: 缓冲区不够时返回 null 而不是截断" {
    var tiny: [4]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), format4(&tiny, .{ 192, 168, 1, 1 }));
}
