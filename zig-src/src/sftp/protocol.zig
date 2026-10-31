//! SFTP v3 线协议编解码（`draft-ietf-secsh-filexfer-02`）。
//!
//! 这一层**刻意不感知 SSH**。SFTP 是「4 字节大端长度前缀 + 1 字节类型 + 负载」
//! 跑在任意可靠字节流上的协议，所以同一份代码可以被 SSH subsystem、裸 socket
//! 或单测缓冲驱动。解耦的收益很实际：协议编解码能直接单测，不需要活连接、
//! 不需要密钥、不需要起服务。
//!
//! ## 为什么 `parse` 用 `null` 表示「还要更多字节」
//!
//! 流式解析最常见的实现错误，是把「缓冲里还没有一个完整的包」当成格式错误。
//! 那样只要 TCP 分段恰好落在包中间，合法流量就会被当成坏数据丢掉。这里严格
//! 区分两种非成功状态：
//!
//!   - `null`    —— 数据还不够，攒着继续读（正常情况，不是错误）
//!   - `error.*` —— 真的坏了，连接应当断开
//!
//! ## 长度前缀必须在上限检查之后才可信
//!
//! 长度前缀是客户端可控的。`max_packet_len` 的检查必须发生在任何分配之前，
//! 否则一个 `0xFFFFFFFF` 前缀就能让服务端尝试申请 4 GiB。这里在 `parse`
//! 里先比长度再决定「等数据」还是「报错」，不会根据未校验的长度去分配。

const std = @import("std");
const Buf = @import("../util/buf.zig").Buf;

/// 本实现协商的协议版本。3 是 OpenSSH 实际使用的版本，也是互操作的事实标准。
pub const version: u32 = 3;

/// 长度前缀自身占 4 字节。
pub const length_prefix_len = 4;

/// 单包上限。OpenSSH 的 `sftp-server` 默认也是 256 KiB；超过这个值的包在
/// 真实客户端里不会出现，只可能是构造的恶意输入。
pub const max_packet_len: u32 = 256 * 1024;

/// 客户端路径长度上限（纯防御：归一化本身是线性的，但没必要为荒谬输入分配）。
pub const max_path_len: usize = 4096;

/// `SSH_FXP_*`。带 `_` 捕获未知值：将来客户端发来本实现不认识的新包类型时，
/// 应当回 `SSH_FX_OP_UNSUPPORTED` 而不是让枚举转换 panic。
pub const PacketType = enum(u8) {
    init = 1,
    version = 2,
    open = 3,
    close = 4,
    read = 5,
    write = 6,
    lstat = 7,
    fstat = 8,
    setstat = 9,
    fsetstat = 10,
    opendir = 11,
    readdir = 12,
    remove = 13,
    mkdir = 14,
    rmdir = 15,
    realpath = 16,
    stat = 17,
    rename = 18,
    readlink = 19,
    symlink = 20,
    status = 101,
    handle = 102,
    data = 103,
    name = 104,
    attrs = 105,
    extended = 200,
    extended_reply = 201,
    _,
};

/// `SSH_FX_*`。`ok` 是成功回复（不是错误），`eof` 是「读完了」——客户端靠它
/// 结束 `readdir` / `read` 循环，所以这两个值不能被折叠进 `failure`。
pub const Status = enum(u32) {
    ok = 0,
    eof = 1,
    no_such_file = 2,
    permission_denied = 3,
    failure = 4,
    bad_message = 5,
    no_connection = 6,
    connection_lost = 7,
    op_unsupported = 8,
};

/// `SSH_FXF_*` 打开标志。位序与线格式一致（bit0 = read）。
pub const OpenFlags = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    append: bool = false,
    creat: bool = false,
    trunc: bool = false,
    excl: bool = false,
    _pad: u26 = 0,

    pub fn fromInt(v: u32) OpenFlags {
        return @bitCast(v);
    }

    pub fn toInt(self: OpenFlags) u32 {
        return @bitCast(self);
    }
};

/// `SSH_FILEXFER_ATTR_*` 属性存在位。
///
/// ⚠ `extended` 是 **bit31**（0x80000000），不是 bit4 —— 它是后来追加的高位
/// 标志，中间留了 27 位空洞。用 `_pad: u27` 把它顶到最高位，这样 `@bitCast`
/// 出来的 u32 与线格式逐位一致，不需要手工移位。
pub const AttrFlags = packed struct(u32) {
    size: bool = false,
    uid_gid: bool = false,
    permissions: bool = false,
    acmodtime: bool = false,
    _pad: u27 = 0,
    extended: bool = false,

    pub fn fromInt(v: u32) AttrFlags {
        return @bitCast(v);
    }

    pub fn toInt(self: AttrFlags) u32 {
        return @bitCast(self);
    }
};

/// 一组可选的文件属性。`null` 表示「本包没带这一项」，而不是「值为 0」——
/// 这个区分很重要：`SETSTAT` 里 `size = 0` 表示把文件截断成 0 字节，
/// `size = null` 表示不动大小。
pub const Attributes = struct {
    size: ?u64 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    /// Unix `st_mode` 全 32 位（含文件类型位）。目录是 `0o040755`，
    /// 普通文件是 `0o100644`。
    permissions: ?u32 = null,
    atime: ?u32 = null,
    mtime: ?u32 = null,

    /// 从 flags 推导实际要编码的位。
    pub fn flagsFor(self: Attributes) AttrFlags {
        var f = AttrFlags{};
        if (self.size != null) f.size = true;
        if (self.uid != null or self.gid != null) f.uid_gid = true;
        if (self.permissions != null) f.permissions = true;
        if (self.atime != null or self.mtime != null) f.acmodtime = true;
        return f;
    }
};

pub const DecodeError = error{
    /// 长度前缀为 0（连类型字节都没有）。
    EmptyPacket,
    /// 长度前缀超过 `max_packet_len`。
    PacketTooLong,
    /// 包体内部声明的长度超过剩余字节。
    Truncated,
    /// 同一组属性里 `uid_gid` / `acmodtime` 只写了一半。
    MalformedAttrs,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Reader —— 只读游标，所有读取都做边界检查
// ---------------------------------------------------------------------------

/// 读游标。所有 `read*` 都在越界时返回 `error.Truncated`，绝不越界读。
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn remaining(self: Reader) usize {
        return self.buf.len - self.pos;
    }

    pub fn readBytes(self: *Reader, n: usize) DecodeError![]const u8 {
        if (n > self.remaining()) return error.Truncated;
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    pub fn readU8(self: *Reader) DecodeError!u8 {
        const b = try self.readBytes(1);
        return b[0];
    }

    pub fn readU32(self: *Reader) DecodeError!u32 {
        const b = try self.readBytes(4);
        return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) |
            (@as(u32, b[2]) << 8) | @as(u32, b[3]);
    }

    pub fn readU64(self: *Reader) DecodeError!u64 {
        const hi = try self.readU32();
        const lo = try self.readU32();
        return (@as(u64, hi) << 32) | @as(u64, lo);
    }

    /// `string` 线类型 = u32 长度 + 原始字节（**不保证** UTF-8、**不保证**有
    /// NUL 结尾）。长度在分配之前就与剩余字节比较，所以不会出现「声明 4 GB、
    /// 实际只有 10 字节」的分配。
    pub fn readString(self: *Reader) DecodeError![]const u8 {
        const n = try self.readU32();
        return self.readBytes(n);
    }

    /// 解一组属性。`extended` 对里我们读进来直接丢弃：v3 的 extended 对是
    /// 厂商自定义扩展，不认识的实现应当忽略而不是拒绝整包。
    pub fn readAttrs(self: *Reader) DecodeError!Attributes {
        const raw = try self.readU32();
        const f = AttrFlags.fromInt(raw);

        var a = Attributes{};
        if (f.size) a.size = try self.readU64();
        if (f.uid_gid) {
            a.uid = try self.readU32();
            a.gid = try self.readU32();
        }
        if (f.permissions) a.permissions = try self.readU32();
        if (f.acmodtime) {
            a.atime = try self.readU32();
            a.mtime = try self.readU32();
        }
        if (f.extended) {
            const count = try self.readU32();
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                _ = try self.readString();
                _ = try self.readString();
            }
        }
        return a;
    }
};

// ---------------------------------------------------------------------------
// Writer —— 追加到调用方的 Buf
// ---------------------------------------------------------------------------

/// 写游标。只是把大端编码收在一处，避免每个调用点各写一遍移位。
pub const Writer = struct {
    out: *Buf,

    pub fn init(out: *Buf) Writer {
        return .{ .out = out };
    }

    pub fn writeBytes(self: Writer, b: []const u8) !void {
        try self.out.append(b);
    }

    pub fn writeU8(self: Writer, v: u8) !void {
        try self.out.appendByte(v);
    }

    pub fn writeU32(self: Writer, v: u32) !void {
        var b: [4]u8 = undefined;
        b[0] = @truncate(v >> 24);
        b[1] = @truncate(v >> 16);
        b[2] = @truncate(v >> 8);
        b[3] = @truncate(v);
        try self.out.append(&b);
    }

    pub fn writeU64(self: Writer, v: u64) !void {
        try self.writeU32(@truncate(v >> 32));
        try self.writeU32(@truncate(v));
    }

    pub fn writeString(self: Writer, s: []const u8) !void {
        try self.writeU32(@intCast(s.len));
        try self.out.append(s);
    }

    pub fn writeAttrs(self: Writer, a: Attributes) !void {
        try self.writeU32(a.flagsFor().toInt());
        if (a.size) |v| try self.writeU64(v);
        if (a.uid != null or a.gid != null) {
            try self.writeU32(a.uid orelse 0);
            try self.writeU32(a.gid orelse 0);
        }
        if (a.permissions) |v| try self.writeU32(v);
        if (a.atime != null or a.mtime != null) {
            try self.writeU32(a.atime orelse 0);
            try self.writeU32(a.mtime orelse 0);
        }
    }
};

// ---------------------------------------------------------------------------
// 组包 / 解包
// ---------------------------------------------------------------------------

/// 解析出来的一个完整包。`body` **借用** 输入缓冲（零拷贝），调用方要么在
/// 同一生命周期内用完，要么自己复制。
pub const Packet = struct {
    packet_type: PacketType,
    body: []const u8,
    /// 本包在输入里占的总字节数（含 4 字节长度前缀），用于推进游标。
    consumed: usize,
};

/// 尝试从 `buf` 头部取出一个包。
///
/// 返回 `null` 表示「还不够一个整包」，调用方应当保留 `buf` 继续累积。
pub fn parse(buf: []const u8) DecodeError!?Packet {
    if (buf.len < length_prefix_len) return null;

    const len = (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) |
        (@as(u32, buf[2]) << 8) | @as(u32, buf[3]);

    // 长度 0 是坏包：长度前缀**包含**类型字节，所以最小值是 1。
    if (len == 0) return error.EmptyPacket;
    // 上限检查必须在「等数据」之前：否则一个超大前缀会让我们永远等下去。
    if (len > max_packet_len) return error.PacketTooLong;

    const total = length_prefix_len + @as(usize, len);
    if (buf.len < total) return null; // 还没收全，正常情况

    return .{
        .packet_type = @enumFromInt(buf[length_prefix_len]),
        .body = buf[length_prefix_len + 1 .. total],
        .consumed = total,
    };
}

/// 把 `(type, body)` 打包追加到 `out`（含长度前缀）。
pub fn frame(out: *Buf, packet_type: PacketType, body: []const u8) !void {
    const len = body.len + 1;
    if (len > max_packet_len) return error.PacketTooLong;
    var w = Writer.init(out);
    try w.writeU32(@intCast(len));
    try w.writeU8(@intFromEnum(packet_type));
    try w.writeBytes(body);
}

/// 追加一个 `SSH_FXP_STATUS` 回复。这是服务端最高频的写操作，单独抽出来
/// 是为了让所有错误路径走同一段代码——状态码拼错时只会在一个地方错。
pub fn writeStatus(out: *Buf, request_id: u32, status: Status) !void {
    var body = Buf.init(out.alloc);
    defer body.deinit();
    var w = Writer.init(&body);
    try w.writeU32(request_id);
    try w.writeU32(@intFromEnum(status));
    // v3 允许附带 message / language，空串即可（OpenSSH 也常发空）。
    try w.writeString("");
    try w.writeString("");
    try frame(out, .status, body.slice());
}

/// 追加一个 `SSH_FXP_HANDLE` 回复（`OPEN` / `OPENDIR` 的成功响应）。
pub fn writeHandle(out: *Buf, request_id: u32, handle: []const u8) !void {
    var body = Buf.init(out.alloc);
    defer body.deinit();
    var w = Writer.init(&body);
    try w.writeU32(request_id);
    try w.writeString(handle);
    try frame(out, .handle, body.slice());
}

/// 追加一个 `SSH_FXP_DATA` 回复（`READ` 的成功响应）。
pub fn writeData(out: *Buf, request_id: u32, data: []const u8) !void {
    var body = Buf.init(out.alloc);
    defer body.deinit();
    var w = Writer.init(&body);
    try w.writeU32(request_id);
    try w.writeString(data);
    try frame(out, .data, body.slice());
}

/// 追加一个 `SSH_FXP_ATTRS` 回复（`STAT` / `LSTAT` / `FSTAT` 的成功响应）。
pub fn writeAttrs(out: *Buf, request_id: u32, attrs: Attributes) !void {
    var body = Buf.init(out.alloc);
    defer body.deinit();
    var w = Writer.init(&body);
    try w.writeU32(request_id);
    try w.writeAttrs(attrs);
    try frame(out, .attrs, body.slice());
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "sftp/protocol: 帧往返（每种包类型都能原样取回）" {
    const cases = [_]PacketType{ .init, .version, .open, .read, .write, .status, .name, .extended };
    for (cases) |pt| {
        var out = Buf.init(testing.allocator);
        defer out.deinit();
        try frame(&out, pt, "payload");

        const p = (try parse(out.slice())).?;
        try testing.expectEqual(pt, p.packet_type);
        try testing.expectEqualStrings("payload", p.body);
        try testing.expectEqual(out.slice().len, p.consumed);
    }
}

test "sftp/protocol: 空负载的包也是合法包" {
    var out = Buf.init(testing.allocator);
    defer out.deinit();
    try frame(&out, .init, "");
    // 4 字节长度(=1) + 1 字节类型
    try testing.expectEqual(@as(usize, 5), out.slice().len);

    const p = (try parse(out.slice())).?;
    try testing.expectEqual(PacketType.init, p.packet_type);
    try testing.expectEqual(@as(usize, 0), p.body.len);
}

test "sftp/protocol: 截断返回 null 而不是错误（流式语义）" {
    var out = Buf.init(testing.allocator);
    defer out.deinit();
    try frame(&out, .open, "0123456789");

    // 前缀都没收全
    try testing.expectEqual(@as(?Packet, null), try parse(out.slice()[0..2]));
    // 前缀全了、包体缺一半
    try testing.expectEqual(@as(?Packet, null), try parse(out.slice()[0..8]));
    // 差最后一个字节
    try testing.expectEqual(@as(?Packet, null), try parse(out.slice()[0 .. out.slice().len - 1]));
    // 全了
    try testing.expect((try parse(out.slice())) != null);
}

test "sftp/protocol: 长度前缀 0 是坏包" {
    const bad = [_]u8{ 0, 0, 0, 0 };
    try testing.expectError(error.EmptyPacket, parse(&bad));
}

test "sftp/protocol: 超过上限的包在分配前就被拒绝" {
    // 0xFFFFFFFF 前缀：如果实现先按长度等数据/分配，这里会挂住或 OOM。
    const bad = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x01 };
    try testing.expectError(error.PacketTooLong, parse(&bad));
}

test "sftp/protocol: 多包连续解析靠 consumed 推进" {
    var out = Buf.init(testing.allocator);
    defer out.deinit();
    try frame(&out, .open, "a");
    try frame(&out, .close, "bb");

    var rest: []const u8 = out.slice();
    var seen: usize = 0;
    while (try parse(rest)) |p| {
        seen += 1;
        rest = rest[p.consumed..];
        if (seen == 1) try testing.expectEqualStrings("a", p.body);
        if (seen == 2) try testing.expectEqualStrings("bb", p.body);
    }
    try testing.expectEqual(@as(usize, 2), seen);
    try testing.expectEqual(@as(usize, 0), rest.len);
}

test "sftp/protocol: Reader 越界一律 Truncated，不越界读" {
    var r = Reader.init("abc");
    try testing.expectEqualStrings("abc", try r.readBytes(3));
    try testing.expectError(error.Truncated, r.readBytes(1));

    var r2 = Reader.init(&[_]u8{ 0, 0, 0, 9 }); // 声明 9 字节字符串，实际没有
    try testing.expectError(error.Truncated, r2.readString());
}

test "sftp/protocol: 属性往返（全字段）" {
    var out = Buf.init(testing.allocator);
    defer out.deinit();
    const want = Attributes{
        .size = 123456789,
        .uid = 1000,
        .gid = 1000,
        .permissions = 0o100644,
        .atime = 1_700_000_000,
        .mtime = 1_700_000_100,
    };
    var w = Writer.init(&out);
    try w.writeAttrs(want);

    var r = Reader.init(out.slice());
    const got = try r.readAttrs();
    try testing.expectEqual(want.size.?, got.size.?);
    try testing.expectEqual(want.uid.?, got.uid.?);
    try testing.expectEqual(want.gid.?, got.gid.?);
    try testing.expectEqual(want.permissions.?, got.permissions.?);
    try testing.expectEqual(want.atime.?, got.atime.?);
    try testing.expectEqual(want.mtime.?, got.mtime.?);
    try testing.expectEqual(@as(usize, 0), r.remaining());
}

test "sftp/protocol: 空属性只写 4 字节 flags" {
    var out = Buf.init(testing.allocator);
    defer out.deinit();
    var w = Writer.init(&out);
    try w.writeAttrs(.{});
    try testing.expectEqual(@as(usize, 4), out.slice().len);
    try testing.expectEqual(@as(u32, 0), (@as(u32, out.slice()[0]) << 24) |
        (@as(u32, out.slice()[1]) << 16) | (@as(u32, out.slice()[2]) << 8) | out.slice()[3]);
}

test "sftp/protocol: AttrFlags 位序与线格式一致（extended 在 bit31）" {
    // size = bit0, uid_gid = bit1, permissions = bit2, acmodtime = bit3,
    // extended = bit31。手工算出来对一遍，防止 packed struct 布局漂移。
    var f = AttrFlags{};
    f.size = true;
    try testing.expectEqual(@as(u32, 0x0000_0001), f.toInt());

    f = .{};
    f.uid_gid = true;
    try testing.expectEqual(@as(u32, 0x0000_0002), f.toInt());

    f = .{};
    f.permissions = true;
    try testing.expectEqual(@as(u32, 0x0000_0004), f.toInt());

    f = .{};
    f.acmodtime = true;
    try testing.expectEqual(@as(u32, 0x0000_0008), f.toInt());

    f = .{};
    f.extended = true;
    try testing.expectEqual(@as(u32, 0x8000_0000), f.toInt());

    // 反方向：0x80000001 必须解成 size + extended。
    const back = AttrFlags.fromInt(0x8000_0001);
    try testing.expect(back.size);
    try testing.expect(back.extended);
    try testing.expect(!back.uid_gid);
}

test "sftp/protocol: OpenFlags 位序" {
    const f = OpenFlags.fromInt(0x0000_0013); // read|write|trunc
    try testing.expect(f.read);
    try testing.expect(f.write);
    try testing.expect(f.trunc);
    try testing.expect(!f.creat);
    try testing.expectEqual(@as(u32, 0x13), f.toInt());
}

test "sftp/protocol: 未知的 extended 属性对被忽略而不是报错" {
    var out = Buf.init(testing.allocator);
    defer out.deinit();
    var w = Writer.init(&out);
    // flags = extended，然后 count=1，一对 (type, data)
    try w.writeU32(0x8000_0000);
    try w.writeU32(1);
    try w.writeString("vendor@example.com");
    try w.writeString("opaque");
    // 后面再跟一个正常的 size 属性？不 —— flags 决定顺序，extended 在最后。

    var r = Reader.init(out.slice());
    const a = try r.readAttrs();
    try testing.expectEqual(@as(?u64, null), a.size);
    try testing.expectEqual(@as(usize, 0), r.remaining());
}

test "sftp/protocol: uid_gid 只写一半时补 0（不产生畸形包）" {
    var out = Buf.init(testing.allocator);
    defer out.deinit();
    var w = Writer.init(&out);
    try w.writeAttrs(.{ .uid = 7 }); // gid 为 null

    var r = Reader.init(out.slice());
    const a = try r.readAttrs();
    try testing.expectEqual(@as(?u32, 7), a.uid);
    try testing.expectEqual(@as(?u32, 0), a.gid);
}

test "sftp/protocol: writeStatus 的包结构" {
    var out = Buf.init(testing.allocator);
    defer out.deinit();
    try writeStatus(&out, 0x11223344, .no_such_file);

    const p = (try parse(out.slice())).?;
    try testing.expectEqual(PacketType.status, p.packet_type);

    var r = Reader.init(p.body);
    try testing.expectEqual(@as(u32, 0x11223344), try r.readU32());
    try testing.expectEqual(@as(u32, 2), try r.readU32()); // no_such_file
    try testing.expectEqualStrings("", try r.readString());
    try testing.expectEqualStrings("", try r.readString());
}

test "sftp/protocol: writeHandle / writeData 的包结构" {
    var out = Buf.init(testing.allocator);
    defer out.deinit();
    try writeHandle(&out, 5, "h1");
    try writeData(&out, 6, "bytes");

    var rest: []const u8 = out.slice();
    const p1 = (try parse(rest)).?;
    try testing.expectEqual(PacketType.handle, p1.packet_type);
    var r1 = Reader.init(p1.body);
    try testing.expectEqual(@as(u32, 5), try r1.readU32());
    try testing.expectEqualStrings("h1", try r1.readString());
    rest = rest[p1.consumed..];

    const p2 = (try parse(rest)).?;
    try testing.expectEqual(PacketType.data, p2.packet_type);
    var r2 = Reader.init(p2.body);
    try testing.expectEqual(@as(u32, 6), try r2.readU32());
    try testing.expectEqualStrings("bytes", try r2.readString());
}

test "sftp/protocol: 二进制字符串不受 NUL 影响（READ 数据可以是任意字节）" {
    const payload = [_]u8{ 0x00, 0xFF, 0x00, 'a', 0x00 };
    var out = Buf.init(testing.allocator);
    defer out.deinit();
    try writeData(&out, 1, &payload);

    const p = (try parse(out.slice())).?;
    var r = Reader.init(p.body);
    _ = try r.readU32();
    const got = try r.readString();
    try testing.expectEqualSlices(u8, &payload, got);
}
