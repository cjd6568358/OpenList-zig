//! Random-string helpers shared by `main.zig`（首启生成 `zig.token`）与
//! `api.zig`（`/api/admin/setting/reset_token`）。
//!
//! 之前这三个函数是 main.zig 的私有实现；reset_token 也要用同一套生成规则
//! （Go 的 `random.Token()`），而 api 不能反向 import main（会成环），所以
//! 抽到这里。

const std = @import("std");
const rt = @import("../rt.zig");

/// 字母数字字符集，与 Go `pkg/utils/random/random.go` 的 `letterBytes` 逐字一致。
const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

/// Go `random.String(n)`：n 位字母数字，取自 CSPRNG。
/// Zig 0.17 移除了 `std.crypto.random`，熵从 `Io` 句柄取（`rt.io().random`，
/// ChaCha CSPRNG，种子来自 OS）—— 与 config.zig 的 `randomSecret` 同一套做法。
pub fn randomString(buf: []u8) []const u8 {
    var raw: [1]u8 = undefined;
    for (buf) |*c| {
        rt.io().random(&raw);
        c.* = letters[raw[0] % letters.len];
    }
    return buf;
}

/// RFC 4122 v4 UUID，小写带连字符 —— 与 Go `google/uuid` 的 `NewString()` 同形。
pub fn formatUuidV4(out: *[36]u8) void {
    var b: [16]u8 = undefined;
    rt.io().random(&b);
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // variant 10xx
    const hex = "0123456789abcdef";
    var i: usize = 0;
    var j: usize = 0;
    while (i < 16) : (i += 1) {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[j] = '-';
            j += 1;
        }
        out[j] = hex[b[i] >> 4];
        out[j + 1] = hex[b[i] & 0x0f];
        j += 2;
    }
}

/// Go `random.Token()` = `"openlist-" + uuid.NewString() + String(64)`。
/// `buf` 至少要 9 + 36 + 64 = 109 字节。
pub fn randomToken(buf: []u8) []const u8 {
    var uuid: [36]u8 = undefined;
    formatUuidV4(&uuid);
    const head = std.fmt.bufPrint(buf, "openlist-{s}", .{uuid}) catch return buf[0..0];
    const n = head.len;
    _ = randomString(buf[n .. n + 64]);
    return buf[0 .. n + 64];
}

test "randomToken has Go's exact shape: openlist-<uuid>+64 letters" {
    var buf: [128]u8 = undefined;
    const tok = randomToken(&buf);
    try std.testing.expectEqual(@as(usize, 9 + 36 + 64), tok.len);
    try std.testing.expect(std.mem.startsWith(u8, tok, "openlist-"));
    // UUID 段：8-4-4-4-12，小写十六进制
    const uuid = tok[9..45];
    try std.testing.expectEqual(@as(u8, '-'), uuid[8]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[13]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[18]);
    try std.testing.expectEqual(@as(u8, '-'), uuid[23]);
    for (uuid, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
    // 两次生成不同（CSPRNG）
    var buf2: [128]u8 = undefined;
    const tok2 = randomToken(&buf2);
    try std.testing.expect(!std.mem.eql(u8, tok, tok2));
}
