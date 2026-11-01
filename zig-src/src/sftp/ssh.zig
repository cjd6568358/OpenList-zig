//! SSH-2 传输层（RFC 4253）+ `curve25519-sha256` 密钥交换（RFC 8731）
//! + `ssh-ed25519` 主机密钥 + `aes128-ctr` / `hmac-sha2-256`。
//!
//! ## 范围
//!
//! 这一层只负责「把字节流变成可信的、加密的双向管道」：
//!
//!   - 版本交换（`SSH-2.0-...`）
//!   - 算法协商（KEXINIT），只宣告**本实现真的支持**的那一套
//!   - `curve25519-sha256` 密钥交换 + 主机签名
//!   - 二进制包协议（长度 / 填充 / 序列号 / MAC）
//!   - `NEWKEYS` 后的对称加密
//!
//! 认证（RFC 4252）与连接层（RFC 4254）不在这里，见下一层的 `auth.zig` /
//! `channel.zig`（待做）。刻意切开是因为：**传输层错一个字节，上面全部不可
//! 用**，而它的正确性可以独立验证（KEX 完成 + 加密通道收发一致）。
//!
//! ## 为什么只支持一套算法
//!
//! SSH 的算法协商是个矩阵，支持越多，出错的组合越多。这里只宣告：
//!
//! | 类别 | 唯一选项 | 理由 |
//! |---|---|---|
//! | KEX | `curve25519-sha256` | 现代客户端（OpenSSH 7.4+、WinSCP 5.13+、rclone）全支持 |
//! | 主机密钥 | `ssh-ed25519` | 不用 RSA，省掉 PKCS#1 与 DigestInfo |
//! | 加密 | `aes128-ctr` | std 有 AES，CTR 只需 20 行；避免 OpenSSH 私有的 chacha 变体 |
//! | MAC | `hmac-sha2-256` | 标准、简单 |
//! | 压缩 | `none` | 压缩与 SFTP 无关，开了只是多一条出错路径 |
//!
//! 协商失败时明确断连并说明原因，不静默降级 —— 降级意味着「你以为在用
//! curve25519，实际在用 group1-sha1」。
//!
//! ## 一个容易搞错的地方：MAC 覆盖的是**明文**包
//!
//! RFC 4253 §6.4：MAC 计算在加密之前，覆盖 `sequence_number || unencrypted_packet`
//! （含 4 字节长度字段）。先加密再算 MAC 是错的，会导致和对端永远对不上，
//! 而症状只是「连接建立后所有包都 BadMac」。

const std = @import("std");
const rt = @import("../rt.zig");
const log = @import("../log.zig");
const Buf = @import("../util/buf.zig").Buf;

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Ed25519 = std.crypto.sign.Ed25519;
const X25519 = std.crypto.dh.X25519;
const Aes128 = std.crypto.core.aes.Aes128;

// ---- 消息号（RFC 4253 §12）----
pub const MSG_DISCONNECT: u8 = 1;
pub const MSG_IGNORE: u8 = 2;
pub const MSG_UNIMPLEMENTED: u8 = 3;
pub const MSG_DEBUG: u8 = 4;
pub const MSG_SERVICE_REQUEST: u8 = 5;
pub const MSG_SERVICE_ACCEPT: u8 = 6;
pub const MSG_KEXINIT: u8 = 20;
pub const MSG_NEWKEYS: u8 = 21;
pub const MSG_KEX_ECDH_INIT: u8 = 30;
pub const MSG_KEX_ECDH_REPLY: u8 = 31;

// ---- 断开原因码（RFC 4253 §11.1），只列本实现会用到的 ----
pub const DISCONNECT_PROTOCOL_ERROR: u32 = 2;
pub const DISCONNECT_KEY_EXCHANGE_FAILED: u32 = 3;
pub const DISCONNECT_SERVICE_NOT_AVAILABLE: u32 = 7;

pub const server_version = "SSH-2.0-OpenList_0.1";

/// 单包上限。OpenSSH 默认 256 KiB；SFTP 的读块不会超过这个量级。
const max_packet: u32 = 256 * 1024;

// ---------------------------------------------------------------------------
// 小工具：SSH 的大端写入 / 读取
// ---------------------------------------------------------------------------

pub fn putU32(out: *Buf, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try out.append(&b);
}

pub fn putU64(out: *Buf, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .big);
    try out.append(&b);
}

/// SSH `string`：u32 长度 + 原始字节。
pub fn putString(out: *Buf, s: []const u8) !void {
    try putU32(out, @intCast(s.len));
    try out.append(s);
}

/// SSH `name-list`：逗号分隔的 `string`（空列表就是长度 0）。
pub fn putNameList(out: *Buf, s: []const u8) !void {
    try putString(out, s);
}

/// SSH `mpint`：大端二进制补码整数，最高位为 1 时要补一个 0x00。
pub fn putMpint(out: *Buf, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len and bytes[i] == 0) i += 1;
    const v = bytes[i..];
    if (v.len == 0) {
        try putU32(out, 0); // 零
        return;
    }
    if (v[0] & 0x80 != 0) {
        try putU32(out, @intCast(v.len + 1));
        try out.appendByte(0);
        try out.append(v);
    } else {
        try putU32(out, @intCast(v.len));
        try out.append(v);
    }
}

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn take(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.buf.len) return error.Truncated;
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }
    pub fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }
    pub fn u32v(self: *Reader) !u32 {
        const b = try self.take(4);
        return std.mem.readInt(u32, b[0..4], .big);
    }
    pub fn string(self: *Reader) ![]const u8 {
        return self.take(try self.u32v());
    }
};

// ---------------------------------------------------------------------------
// AES-128-CTR
// ---------------------------------------------------------------------------

/// 流式 CTR。SSH 的包长度字段也是加密的，所以必须能「先解 4 字节、再解剩
/// 下的」—— 分两次调用必须共用同一条 keystream，这就是为什么这里自己维护
/// 计数器与剩余位置，而不是每次调用重开一个流。
const CtrCipher = struct {
    ctx: std.crypto.core.aes.AesEncryptCtx(Aes128),
    counter: [16]u8,
    ks: [16]u8 = undefined,
    pos: usize = 16, // 16 = 需要生成下一块

    fn init(key: [16]u8, iv: [16]u8) CtrCipher {
        return .{ .ctx = Aes128.initEnc(key), .counter = iv };
    }

    fn xor(self: *CtrCipher, data: []u8) void {
        for (data) |*b| {
            if (self.pos == 16) {
                self.ctx.encrypt(&self.ks, &self.counter);
                // 128 位大端计数器 +1
                var i: usize = 15;
                while (true) {
                    self.counter[i] +%= 1;
                    if (self.counter[i] != 0) break;
                    if (i == 0) break;
                    i -= 1;
                }
                self.pos = 0;
            }
            b.* ^= self.ks[self.pos];
            self.pos += 1;
        }
    }
};

// ---------------------------------------------------------------------------
// 主机密钥
// ---------------------------------------------------------------------------

/// 私钥文件的权限：**只给属主读写**。
///
/// 文件里是 32 字节 ed25519 seed —— 拿到它就能冒充这台服务器（客户端只会
/// 看到「主机密钥已更改」，而用户通常直接按 yes）。默认 0666 & ~umask 在多数
/// 机器上落成 0644，同组/其他用户可读，所以必须显式收紧。
///
/// ⚠ Windows 没有 POSIX mode：`Permissions` 在那里只有只读属性，`fromMode`
/// 根本不存在。Windows 上要等价于 0600 得改 DACL（`SetNamedSecurityInfo`），
/// 而部署目标（光猫 / Linux）不需要；这里退化成默认权限并在调用点记一行
/// 日志，不假装已经保护好了。
const key_permissions: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
    .fromMode(0o600)
else
    .default_file;

pub const HostKey = struct {
    kp: Ed25519.KeyPair,
    /// `string "ssh-ed25519" || string pubkey` —— KEX 里原样发送。
    blob: []u8,

    pub fn deinit(self: *HostKey, alloc: std.mem.Allocator) void {
        alloc.free(self.blob);
    }

    /// 从文件加载 32 字节 seed；文件不存在就生成一个新的并写回。
    ///
    /// 主机密钥**必须稳定**：客户端会记住它（known_hosts），每次重启都换
    /// 一个会让所有人都看到「主机密钥已更改」的警告。所以宁可写文件失败时
    /// 只告警、退化成进程内临时密钥，也不静默生成新的。
    pub fn loadOrCreate(alloc: std.mem.Allocator, path: []const u8) !HostKey {
        const io = rt.io();
        var seed: [32]u8 = undefined;

        if (std.Io.Dir.cwd().openFile(io, path, .{})) |f| {
            defer f.close(io);
            const n = std.Io.File.readPositionalAll(f, io, &seed, 0) catch 0;
            if (n != seed.len) {
                log.warn("ssh: host key file {s} is short ({d} bytes); regenerating", .{ path, n });
                io.random(&seed);
                writeSeed(io, path, seed);
            } else {
                // 老版本写出来的是 0644：文件存在时权限不会因为 createFile 的
                // `permissions` 改变，必须显式收紧一次。
                tightenPermissions(io, f, path);
            }
        } else |_| {
            io.random(&seed);
            writeSeed(io, path, seed);
        }

        return fromSeed(alloc, seed);
    }

    fn writeSeed(io: std.Io, path: []const u8, seed: [32]u8) void {
        if (std.fs.path.dirname(path)) |dir| {
            // 0.17：`Dir.makePath` 改名 `createDirPath`。
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
        var f = std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = true,
            .permissions = key_permissions,
        }) catch |e| {
            log.warn("ssh: cannot write host key {s}: {s} (using an ephemeral key)", .{ path, @errorName(e) });
            return;
        };
        defer f.close(io);
        tightenPermissions(io, f, path);
        f.writeStreamingAll(io, &seed) catch |e| {
            log.warn("ssh: cannot write host key {s}: {s}", .{ path, @errorName(e) });
        };
    }

    /// 把已有文件的权限收到 0600。
    ///
    /// 失败不致命（文件已经能读），但要说出来：权限没收紧意味着私钥仍然对
    /// 其他用户可读，而这正是这个函数存在的唯一理由。
    fn tightenPermissions(io: std.Io, f: std.Io.File, path: []const u8) void {
        if (comptime !@hasDecl(std.Io.File.Permissions, "fromMode")) {
            log.debug("ssh: host key {s}: POSIX modes are unavailable on this platform; set the ACL by hand", .{path});
            return;
        }
        f.setPermissions(io, key_permissions) catch |e| {
            log.warn("ssh: cannot chmod 0600 {s}: {s}", .{ path, @errorName(e) });
        };
    }

    pub fn fromSeed(alloc: std.mem.Allocator, seed: [32]u8) !HostKey {
        const kp = Ed25519.KeyPair.generateDeterministic(seed) catch return error.BadHostKey;

        var blob = Buf.init(alloc);
        // `toOwned` 是复制，临时 Buf 必须自己释放（见 util/buf.zig）。
        defer blob.deinit();
        try putString(&blob, "ssh-ed25519");
        try putString(&blob, &kp.public_key.toBytes());

        return .{ .kp = kp, .blob = try blob.toOwned() };
    }

    /// 对 `msg` 签名，返回 SSH 签名 blob：`string "ssh-ed25519" || string sig`。
    pub fn sign(self: HostKey, alloc: std.mem.Allocator, msg: []const u8) ![]u8 {
        const sig = try self.kp.sign(msg, null);
        var out = Buf.init(alloc);
        defer out.deinit();
        try putString(&out, "ssh-ed25519");
        try putString(&out, &sig.toBytes());
        return out.toOwned();
    }
};

// ---------------------------------------------------------------------------
// 传输层
// ---------------------------------------------------------------------------

/// KEX 期间收到的非 KEX 包的暂存队列（见 `Transport.stash`）。
///
/// 两道上限都是为了让「恶意/异常客户端」只能撑爆连接、不能撑爆内存：
///
///   * `max_bytes` = 4 MiB，比我们宣告的 2 MiB 接收窗口宽一倍；
///   * `max_items` = 4096 —— **按最小可信包长反推**，不是拍脑袋。
///
/// ⚠ `max_items` 曾经是 256，注释写着「够 8 KiB 分片发满一个窗口」。**这个假设
/// 是错的**：PuTTY `psftp` 的 `WRITE` 是 ~4 KiB（实测 `incoming=4134`），2 MiB
/// 在飞窗口要 ~512 条 ⇒ 256 条在**只攒到 1 MiB** 时就撞上限，服务端直接断连，
/// 客户端看到的是 `Software caused connection abort`。症状只在「服务端主动
/// rekey + 大文件」时出现，单跑小文件、或者只让客户端发起 rekey 都测不出来。
/// 4096 条 × 512 字节 = 2 MiB，覆盖到窗口的四分之一粒度；真正的内存闸是
/// `max_bytes`，条数只是防「海量小包」把 slice 头撑爆。
///
/// 超限直接报错断连。静默丢弃是更坏的选择：客户端会一直等一个永远不会来的
/// 回复（上传卡死），而我们这边什么日志都没有。
pub const Stash = struct {
    items: std.ArrayListUnmanaged([]u8) = .empty,
    bytes: usize = 0,

    pub const max_bytes: usize = 4 * 1024 * 1024;
    pub const max_items: usize = 4096;

    pub fn deinit(self: *Stash, a: std.mem.Allocator) void {
        for (self.items.items) |it| a.free(it);
        self.items.deinit(a);
        self.* = .{};
    }

    pub fn len(self: *const Stash) usize {
        return self.items.items.len;
    }

    /// 复制一份 payload 存起来 —— `pkt.raw` 马上就会被释放，不能只存切片。
    pub fn push(self: *Stash, a: std.mem.Allocator, payload: []const u8) !void {
        if (self.items.items.len >= max_items or self.bytes + payload.len > max_bytes) {
            return error.TooManyPendingPackets;
        }
        const copy = try a.dupe(u8, payload);
        errdefer a.free(copy);
        try self.items.append(a, copy);
        self.bytes += copy.len;
    }

    /// 取出最早的一个（所有权转移给调用方，`a.free` 释放）。
    pub fn popFront(self: *Stash) ?[]u8 {
        if (self.items.items.len == 0) return null;
        const first = self.items.orderedRemove(0);
        self.bytes -= first.len;
        return first;
    }
};

pub const Transport = struct {
    alloc: std.mem.Allocator,
    rd: *std.Io.Reader,
    wr: *std.Io.Writer,

    seq_in: u32 = 0,
    seq_out: u32 = 0,

    enc_in: ?CtrCipher = null,
    mac_in: ?[32]u8 = null,
    enc_out: ?CtrCipher = null,
    mac_out: ?[32]u8 = null,

    client_version: []u8 = &.{},
    /// 我们发出的 KEXINIT payload（不含消息号以外的任何加工），算 H 用。
    kexinit_sent: []u8 = &.{},
    kexinit_recv: []u8 = &.{},
    session_id: ?[32]u8 = null,

    /// 上一次 KEX 完成之后进出的字节数（含 MAC，含长度字段）。
    ///
    /// 只为一个用途存在：决定**服务端**什么时候该主动换密钥。RFC 4253 §9
    /// 只说「该换」，具体阈值由实现定（OpenSSH 默认 1 GB / 1 小时，由客户端
    /// 发起）。没有这个计数，服务端就永远只能被动跟着客户端的节奏走。
    kex_bytes_in: u64 = 0,
    kex_bytes_out: u64 = 0,

    /// 服务端主动 rekey 时，KEX 期间收到的**非 KEX** 包暂存到这里。
    ///
    /// 为什么需要：我们发出 KEXINIT 之后，客户端还没看到它，仍可能继续发
    /// `CHANNEL_DATA`（RFC 4253 §9 只禁止「自己发完 KEXINIT 再发别的」，
    /// 不禁止对端）。这些包必须先收下来、等 NEWKEYS 完成后再交给连接层，
    /// 直接丢掉等于吞掉客户端的请求（表现为上传随机失败）。
    ///
    /// 为什么不会无限增长：我们宣告的接收窗口是 2 MiB，客户端最多再发这么多
    /// 就会被窗口卡住。`Stash` 按字节和条数双限，超了就断开而不是吃内存。
    stash: ?*Stash = null,

    pub fn bytesSinceKex(self: *const Transport) u64 {
        return self.kex_bytes_in + self.kex_bytes_out;
    }

    pub fn deinit(self: *Transport) void {
        if (self.client_version.len > 0) self.alloc.free(self.client_version);
        if (self.kexinit_sent.len > 0) self.alloc.free(self.kexinit_sent);
        if (self.kexinit_recv.len > 0) self.alloc.free(self.kexinit_recv);
    }

    /// 版本交换。客户端可以在 `SSH-` 行之前发任意多行（RFC 允许），跳过它们。
    pub fn exchangeVersion(self: *Transport) !void {
        try self.wr.writeAll(server_version ++ "\r\n");
        try self.wr.flush();

        var line: [256]u8 = undefined;
        var n: usize = 0;
        var lines: usize = 0;
        var one: [1]u8 = undefined;

        while (true) {
            self.rd.readSliceAll(&one) catch return error.ConnectionClosed;
            if (one[0] == '\n') {
                lines += 1;
                if (lines > 50) return error.TooManyPreambleLines;
                if (n > 0 and line[n - 1] == '\r') n -= 1;
                if (std.mem.startsWith(u8, line[0..n], "SSH-")) {
                    self.client_version = try self.alloc.dupe(u8, line[0..n]);
                    return;
                }
                n = 0;
                continue;
            }
            if (n >= line.len) return error.VersionTooLong;
            line[n] = one[0];
            n += 1;
        }
    }

    /// 读一个包，返回 payload（调用方的 `a` 拥有）。**不含** padding 与长度字段。
    ///
    /// ⚠ 返回值是整块分配的**子切片**（起点 +5 字节），**不能**直接 `free`：
    /// 长度和起点都对不上，`SafeAllocator` 会当成非法释放 panic。需要自己
    /// 释放时用 `readPacketOwned`。
    pub fn readPacket(self: *Transport, a: std.mem.Allocator) ![]const u8 {
        const p = try self.readPacketOwned(a);
        return p.payload;
    }

    /// 一块已分配的包：`raw` 是整个分配，`payload` 是去掉长度与 padding 的
    /// 子切片。连接级 allocator（首次 KEX、重协商）必须用这个版本才能正确
    /// 释放 —— 否则每条连接漏一个包。
    pub const OwnedPacket = struct {
        raw: []u8,
        payload: []const u8,

        pub fn deinit(self: OwnedPacket, a: std.mem.Allocator) void {
            a.free(self.raw);
        }
    };

    pub fn readPacketOwned(self: *Transport, a: std.mem.Allocator) !OwnedPacket {
        var lenbuf: [4]u8 = undefined;
        self.rd.readSliceAll(&lenbuf) catch return error.ConnectionClosed;
        if (self.enc_in) |*c| c.xor(&lenbuf);

        const len = std.mem.readInt(u32, &lenbuf, .big);
        if (len < 5 or len > max_packet) return error.BadPacketLength;

        const body = try a.alloc(u8, len);
        errdefer a.free(body);
        self.rd.readSliceAll(body) catch return error.ConnectionClosed;
        if (self.enc_in) |*c| c.xor(body);

        if (self.mac_in) |key| {
            var got: [32]u8 = undefined;
            self.rd.readSliceAll(&got) catch return error.ConnectionClosed;

            var h = HmacSha256.init(&key);
            var seqb: [4]u8 = undefined;
            std.mem.writeInt(u32, &seqb, self.seq_in, .big);
            h.update(&seqb);
            h.update(&lenbuf);
            h.update(body);
            var want: [32]u8 = undefined;
            h.final(&want);
            if (!std.crypto.timing_safe.eql([32]u8, want, got)) return error.BadMac;
        }

        const padlen = body[0];
        if (padlen < 4 or @as(usize, padlen) + 1 > len) return error.BadPadding;
        self.seq_in +%= 1;
        self.kex_bytes_in += 4 + len + (if (self.mac_in != null) @as(u64, 32) else 0);
        return .{ .raw = body, .payload = body[1 .. len - padlen] };
    }

    /// 发一个包。`payload` 的第一字节是消息号。
    pub fn writePacket(self: *Transport, payload: []const u8) !void {
        const block: usize = if (self.enc_out != null) 16 else 8;
        const base = 4 + 1 + payload.len;
        var pad: usize = block - (base % block);
        if (pad < 4) pad += block;
        const total = base + pad;

        const buf = try self.alloc.alloc(u8, total);
        defer self.alloc.free(buf);

        std.mem.writeInt(u32, buf[0..4], @intCast(total - 4), .big);
        buf[4] = @intCast(pad);
        @memcpy(buf[5..][0..payload.len], payload);
        rt.io().random(buf[5 + payload.len ..]);

        // ⚠ MAC 覆盖**明文**（含长度字段），必须在加密之前算。
        if (self.mac_out) |key| {
            var h = HmacSha256.init(&key);
            var seqb: [4]u8 = undefined;
            std.mem.writeInt(u32, &seqb, self.seq_out, .big);
            h.update(&seqb);
            h.update(buf);
            var mac: [32]u8 = undefined;
            h.final(&mac);

            if (self.enc_out) |*c| c.xor(buf);
            try self.wr.writeAll(buf);
            try self.wr.writeAll(&mac);
            self.kex_bytes_out += total + 32;
        } else {
            try self.wr.writeAll(buf);
            self.kex_bytes_out += total;
        }
        try self.wr.flush();
        self.seq_out +%= 1;
    }

    fn sendMsg(self: *Transport, msg: u8, body: []const u8) !void {
        var b = Buf.init(self.alloc);
        defer b.deinit();
        try b.appendByte(msg);
        try b.append(body);
        try self.writePacket(b.slice());
    }

    /// 协商失败时先发 `DISCONNECT` 说明原因，再把错误交给调用方。
    ///
    /// 只 close socket 是不够的：客户端只能看到「连接被对端关闭」，运维也就
    /// 无从区分「算法不匹配」和「服务进程崩了」。RFC 4253 §11.1 要求说明原因。
    /// 这里自己吞掉发送错误 —— 发送失败说明对端已经走了，原本那个 KEX 失败
    /// 才是要上报的根因。
    fn rejectKex(self: *Transport, e: anyerror) void {
        const info = kexFailInfo(e);
        sendDisconnect(self, info.code, info.desc) catch |se| {
            log.debug("ssh: cannot send DISCONNECT: {s}", .{@errorName(se)});
        };
    }
};

// ---------------------------------------------------------------------------
// 密钥交换
// ---------------------------------------------------------------------------

/// 从 `K || H || letter || session_id` 派生一段密钥（RFC 4253 §7.2）。
fn derive(k_mpint: []const u8, h_hash: [32]u8, letter: u8, session_id: [32]u8, out: []u8) void {
    var digest: [32]u8 = undefined;
    var hh = Sha256.init(.{});
    hh.update(k_mpint);
    hh.update(&h_hash);
    hh.update(&[_]u8{letter});
    hh.update(&session_id);
    hh.final(&digest);
    @memcpy(out[0..@min(out.len, 32)], digest[0..@min(out.len, 32)]);
    // 本实现只需要 <= 32 字节的密钥，无需继续 K2/K3。
}

/// KEX 失败对应的 `DISCONNECT` 原因码与说明。
const KexFail = struct { code: u32, desc: []const u8 };

fn kexFailInfo(e: anyerror) KexFail {
    return switch (e) {
        error.NoCommonKex => .{ .code = DISCONNECT_KEY_EXCHANGE_FAILED, .desc = "no common key exchange algorithm (server offers curve25519-sha256)" },
        error.NoCommonHostKey => .{ .code = DISCONNECT_KEY_EXCHANGE_FAILED, .desc = "no common host key algorithm (server offers ssh-ed25519)" },
        error.NoCommonCipher => .{ .code = DISCONNECT_KEY_EXCHANGE_FAILED, .desc = "no common cipher (server offers aes128-ctr)" },
        error.NoCommonMac => .{ .code = DISCONNECT_KEY_EXCHANGE_FAILED, .desc = "no common MAC (server offers hmac-sha2-256)" },
        else => .{ .code = DISCONNECT_PROTOCOL_ERROR, .desc = "malformed key exchange message" },
    };
}

/// KEX 期间读包：跳过 `IGNORE` / `DEBUG` / `UNIMPLEMENTED`，只返回 KEX 消息。
///
/// RFC 4253 §11.3 允许这几种消息插在任何两个包之间，且它们不占用 KEX 的
/// 消息序号。不跳过的话，一个发了 `IGNORE` 的客户端会让 KEX 直接失败。
/// 返回整块的所有权（`OwnedPacket`）—— 首次 KEX 走的是 gpa，调用方必须释放。
///
/// `stash` 非空（服务端主动 rekey）时，**非 KEX 的包**会被暂存而不是返回：
/// 我们发出 KEXINIT 后、对端看到它之前，仍可能继续发 `CHANNEL_DATA`。这些
/// 包必须在 NEWKEYS 之后补投，丢掉就是「上传到一半卡住」。
fn readKexPacket(t: *Transport, a: std.mem.Allocator, stash: ?*Stash) !Transport.OwnedPacket {
    // 「杂项预算」只数需要跳过的包（空包 / IGNORE / DEBUG / UNIMPLEMENTED）。
    //
    // ⚠ 进暂存队列的包**不占预算**：Stash 自带条数 + 字节两道上限，就是干
    // 这个的。曾经的写法把 stash 的包也计入 512 次循环预算，而合法最坏值
    // 恰好是 ~512 条（psftp 的 4 KiB WRITE × 2 MiB 在飞窗口）—— 预算正好
    // 压死它自己论证过的场景：高 BDP 链路上客户端在处理我们的 KEXINIT
    // 之前已经把整整一个窗口的数据发在飞，第 513 个包（KEXINIT）永远读
    // 不到，连接被断，客户端看到的又是 `Software caused connection abort`。
    // 局域网 BDP 小，48 次 rekey 全 PASS 也测不出来。
    var tries: usize = 0;
    while (true) {
        const p = try t.readPacketOwned(a);
        if (p.payload.len == 0) {
            p.deinit(a);
            tries += 1;
            if (tries >= 512) return error.TooManyGenericPackets;
            continue;
        }
        switch (p.payload[0]) {
            MSG_IGNORE, MSG_DEBUG, MSG_UNIMPLEMENTED => {
                p.deinit(a);
                tries += 1;
                if (tries >= 512) return error.TooManyGenericPackets;
            },
            MSG_DISCONNECT => {
                p.deinit(a);
                return error.PeerDisconnect;
            },
            // KEXINIT / NEWKEYS + 30..49（KEX 专用消息号段，RFC 4253 §12）。
            MSG_KEXINIT, MSG_NEWKEYS, 30...49 => return p,
            else => {
                if (stash) |s| {
                    s.push(t.alloc, p.payload) catch |e| {
                        // 两种上限共用一个错误码，不打日志就完全不知道是哪一种
                        // 触发的 —— 实测 psftp 上传 2 MiB 撞上时，光看
                        // `TooManyPendingPackets` 分不清是条数还是字节数。
                        log.warn("ssh: stash overflow: items={d}/{d} bytes={d}/{d} incoming={d}", .{
                            s.len(), Stash.max_items, s.bytes, Stash.max_bytes, p.payload.len,
                        });
                        p.deinit(a);
                        return e;
                    };
                    p.deinit(a);
                } else return p;
            },
        }
    }
}

pub const KexResult = struct {
    h: [32]u8,
    session_id: [32]u8,
    k_mpint: []u8, // 由调用方 alloc 拥有

    pub fn deinit(self: KexResult, alloc: std.mem.Allocator) void {
        alloc.free(self.k_mpint);
    }
};

/// 走完一次完整 KEX：协商 → ECDH → 签名 → NEWKEYS → 安装密钥。
///
/// `a` 是**连接级** allocator：`k_mpint` 要活到密钥派生结束。
/// 重协商时的非 KEX 包暂存见 `Transport.stash`。
pub fn kex(t: *Transport, host_key: HostKey, a: std.mem.Allocator) !KexResult {
    return kexInner(t, host_key, a, null);
}

/// 客户端已经发来 `KEXINIT` 时继续这次重协商（RFC 4253 §9）。
///
/// 与 `kex` 的唯一区别：客户端的 KEXINIT 已经由消息循环读掉，这里不再读一遍。
/// 其余完全一致 —— 包括**沿用首次的 `session_id`**（`t.session_id` 非空时
/// 不再取 H），这是 RFC 4253 §7.2 的要求，取错不会报错，只会让密钥不一致。
pub fn rekey(t: *Transport, host_key: HostKey, a: std.mem.Allocator, client_kexinit: []const u8) !KexResult {
    return kexInner(t, host_key, a, client_kexinit);
}

fn kexInner(
    t: *Transport,
    host_key: HostKey,
    a: std.mem.Allocator,
    /// 非空 = 客户端主动重协商，其 `KEXINIT` 已经读到了。
    pending_client_kexinit: ?[]const u8,
) !KexResult {
    // ---- 1. 发 KEXINIT ----
    {
        var b = Buf.init(a);
        defer b.deinit();
        try b.appendByte(MSG_KEXINIT);
        var cookie: [16]u8 = undefined;
        rt.io().random(&cookie);
        try b.append(&cookie);
        try putNameList(&b, "curve25519-sha256");
        try putNameList(&b, "ssh-ed25519");
        try putNameList(&b, "aes128-ctr");
        try putNameList(&b, "aes128-ctr");
        try putNameList(&b, "hmac-sha2-256");
        try putNameList(&b, "hmac-sha2-256");
        try putNameList(&b, "none");
        try putNameList(&b, "none");
        try putNameList(&b, "");
        try putNameList(&b, "");
        try b.appendByte(0); // first_kex_packet_follows
        try putU32(&b, 0);

        // 先 dupe 后 free：dupe 失败（OOM）时字段仍指向旧值，`Transport.deinit`
        // 还能正常释放；先 free 的话失败路径上字段就是悬垂，deinit 二次释放
        // —— 重协商让这条路径的执行频率不再是可以忽略的。
        const new_sent = try a.dupe(u8, b.slice());
        if (t.kexinit_sent.len > 0) a.free(t.kexinit_sent);
        t.kexinit_sent = new_sent;
        try t.writePacket(b.slice());
    }

    // ---- 2. 收客户端的 KEXINIT ----
    // 重协商时这份 KEXINIT 已经由消息循环读掉并传进来了（`rekey`），首次
    // KEX 才从线上读 —— 读到的包归本作用域，用完要释放（首次 KEX 用的
    // allocator 是连接级的 gpa，不释放就是每条连接一个泄漏）。
    if (pending_client_kexinit) |p| {
        const new_recv = try a.dupe(u8, p);
        if (t.kexinit_recv.len > 0) a.free(t.kexinit_recv);
        t.kexinit_recv = new_recv;
        checkKexInit(p) catch |e| {
            t.rejectKex(e);
            return e;
        };
    } else {
        const pkt = try readKexPacket(t, a, t.stash);
        defer pkt.deinit(a);
        if (pkt.payload.len < 1 or pkt.payload[0] != MSG_KEXINIT) return error.ExpectedKexInit;
        const new_recv = try a.dupe(u8, pkt.payload);
        if (t.kexinit_recv.len > 0) a.free(t.kexinit_recv);
        t.kexinit_recv = new_recv;
        checkKexInit(pkt.payload) catch |e| {
            t.rejectKex(e);
            return e;
        };
    }

    // ---- 3. 收 KEX_ECDH_INIT，拿 Q_C ----
    const q_c: []const u8 = blk: {
        const pkt = try readKexPacket(t, a, t.stash);
        defer pkt.deinit(a);
        if (pkt.payload.len < 1 or pkt.payload[0] != MSG_KEX_ECDH_INIT) return error.ExpectedEcdhInit;
        var r = Reader{ .buf = pkt.payload[1..] };
        const q = try r.string();
        if (q.len != 32) return error.BadEcdhKey;
        break :blk try a.dupe(u8, q);
    };
    defer a.free(q_c);

    // ---- 4. 临时密钥对 + 共享秘密 ----
    const eph = X25519.KeyPair.generate(rt.io());
    var q_c_arr: [32]u8 = undefined;
    @memcpy(&q_c_arr, q_c);
    const shared = X25519.scalarmult(eph.secret_key, q_c_arr) catch return error.BadEcdhKey;

    var k_mpint = Buf.init(a);
    // ⚠ `toOwned()` 是**复制**不是移交（`Buf.toOwned` 内部就是 dupe）：原件
    // 永远要自己释放。挂 `errdefer` 的话，成功路径就是每次 KEX 漏一份
    // （首握 + 每次重协商），ECDH 之后失败还会漏掉 `k_bytes` 这个孤儿。
    defer k_mpint.deinit();
    try putMpint(&k_mpint, &shared);
    const k_bytes = try k_mpint.toOwned();
    // 成功后所有权归 `KexResult`（调用方 `deinit`）；这之后任何一步失败
    // （签名 / 写包 / 等对端 NEWKEYS 时对端断连 —— 扫描器常见路径）都要
    // 把它交出来，否则就是泄漏。
    errdefer a.free(k_bytes);

    // ---- 5. H = SHA256(V_C || V_S || I_C || I_S || K_S || Q_C || Q_S || K) ----
    var hb = Buf.init(a);
    defer hb.deinit();
    try putString(&hb, t.client_version);
    try putString(&hb, server_version);
    try putString(&hb, t.kexinit_recv);
    try putString(&hb, t.kexinit_sent);
    try putString(&hb, host_key.blob);
    try putString(&hb, &q_c_arr);
    try putString(&hb, &eph.public_key);
    try hb.append(k_bytes);

    var h_hash: [32]u8 = undefined;
    Sha256.hash(hb.slice(), &h_hash, .{});

    const session_id = t.session_id orelse h_hash;

    // ---- 6. 签名并发 KEX_ECDH_REPLY ----
    const sig = try host_key.sign(a, &h_hash);
    defer a.free(sig);

    {
        var b = Buf.init(a);
        defer b.deinit();
        try b.appendByte(MSG_KEX_ECDH_REPLY);
        try putString(&b, host_key.blob);
        try putString(&b, &eph.public_key);
        try putString(&b, sig);
        try t.writePacket(b.slice());
    }

    // ---- 7. NEWKEYS 双向 ----
    try t.sendMsg(MSG_NEWKEYS, "");
    {
        const pkt = try readKexPacket(t, a, t.stash);
        defer pkt.deinit(a);
        if (pkt.payload.len < 1 or pkt.payload[0] != MSG_NEWKEYS) return error.ExpectedNewKeys;
    }

    // ---- 8. 安装密钥 ----
    // 服务端：c2s 用于接收，s2c 用于发送。
    var iv_c2s: [16]u8 = undefined;
    var iv_s2c: [16]u8 = undefined;
    var key_c2s: [16]u8 = undefined;
    var key_s2c: [16]u8 = undefined;
    var mac_c2s: [32]u8 = undefined;
    var mac_s2c: [32]u8 = undefined;
    derive(k_bytes, h_hash, 'A', session_id, &iv_c2s);
    derive(k_bytes, h_hash, 'B', session_id, &iv_s2c);
    derive(k_bytes, h_hash, 'C', session_id, &key_c2s);
    derive(k_bytes, h_hash, 'D', session_id, &key_s2c);
    derive(k_bytes, h_hash, 'E', session_id, &mac_c2s);
    derive(k_bytes, h_hash, 'F', session_id, &mac_s2c);

    t.enc_in = CtrCipher.init(key_c2s, iv_c2s);
    t.mac_in = mac_c2s;
    t.enc_out = CtrCipher.init(key_s2c, iv_s2c);
    t.mac_out = mac_s2c;
    t.session_id = session_id;

    // 计数归零：下一次「该换密钥了吗」从这一刻重新算。KEX 自身那几十个包
    // 不该算进去，否则阈值一低就会连续 rekey 直到连接抖动。
    t.kex_bytes_in = 0;
    t.kex_bytes_out = 0;

    return .{ .h = h_hash, .session_id = session_id, .k_mpint = k_bytes };
}

/// 校验客户端的 KEXINIT 里第一项是不是我们支持的那套。
///
/// 只比「首选算法」：RFC 允许客户端给一长串，但服务端的首选若不在其中，
/// 协商就该失败 —— 与其猜，不如断开并说清楚。
fn checkKexInit(payload: []const u8) !void {
    var r = Reader{ .buf = payload[1..] };
    _ = try r.take(16); // cookie
    const kex_names = try r.string();
    const hostkey_names = try r.string();
    const enc_c2s = try r.string();
    const enc_s2c = try r.string();
    const mac_c2s = try r.string();
    const mac_s2c = try r.string();

    if (!hasName(kex_names, "curve25519-sha256")) {
        log.warn("ssh: client kex list has no curve25519-sha256: {s}", .{kex_names});
        return error.NoCommonKex;
    }
    if (!hasName(hostkey_names, "ssh-ed25519")) {
        log.warn("ssh: client host-key list has no ssh-ed25519: {s}", .{hostkey_names});
        return error.NoCommonHostKey;
    }
    if (!hasName(enc_c2s, "aes128-ctr") or !hasName(enc_s2c, "aes128-ctr")) {
        log.warn("ssh: client cipher list has no aes128-ctr: {s}", .{enc_c2s});
        return error.NoCommonCipher;
    }
    if (!hasName(mac_c2s, "hmac-sha2-256") or !hasName(mac_s2c, "hmac-sha2-256")) {
        log.warn("ssh: client mac list has no hmac-sha2-256: {s}", .{mac_c2s});
        return error.NoCommonMac;
    }
}

fn hasName(list: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |n| {
        if (std.mem.eql(u8, n, want)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Zig 0.17 移除了 `**` 数组重复运算符，测试里统一用这个。
fn fill(comptime n: usize, v: u8) [n]u8 {
    var a: [n]u8 = undefined;
    @memset(&a, v);
    return a;
}

test "ssh: mpint 编码（最高位为 1 时补 0x00）" {
    var b = Buf.init(testing.allocator);
    defer b.deinit();

    // 0x80 开头 ⇒ 必须补一个前导 0，长度从 2 变 3
    try putMpint(&b, &[_]u8{ 0x80, 0x01 });
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, b.slice()[0..4], .big));
    try testing.expectEqual(@as(u8, 0), b.slice()[4]);
    try testing.expectEqual(@as(u8, 0x80), b.slice()[5]);
    try testing.expectEqual(@as(u8, 0x01), b.slice()[6]);

    // 前导零被剥掉
    var b2 = Buf.init(testing.allocator);
    defer b2.deinit();
    try putMpint(&b2, &[_]u8{ 0x00, 0x00, 0x7f });
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, b2.slice()[0..4], .big));
    try testing.expectEqual(@as(u8, 0x7f), b2.slice()[4]);

    // 全零 ⇒ 长度 0
    var b3 = Buf.init(testing.allocator);
    defer b3.deinit();
    try putMpint(&b3, &[_]u8{ 0, 0 });
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, b3.slice()[0..4], .big));
}

test "ssh: CTR 分两次调用与一次性调用等价" {
    const key = fill(16, 0x2b);
    const iv = fill(16, 0xf0);

    var whole = fill(64, 0);
    var c1 = CtrCipher.init(key, iv);
    c1.xor(&whole);

    var split = fill(64, 0);
    var c2 = CtrCipher.init(key, iv);
    c2.xor(split[0..4]); // 先解长度字段
    c2.xor(split[4..]); // 再解剩下的
    try testing.expectEqualSlices(u8, &whole, &split);

    // 再 XOR 一次应当还原（CTR 是对合）
    var back = whole;
    var c3 = CtrCipher.init(key, iv);
    c3.xor(&back);
    try testing.expectEqualSlices(u8, &fill(64, 0), &back);
}

test "ssh: hasName 精确匹配（不接受前缀）" {
    try testing.expect(hasName("a,curve25519-sha256,b", "curve25519-sha256"));
    try testing.expect(!hasName("curve25519-sha256@libssh.org", "curve25519-sha256"));
    try testing.expect(!hasName("", "curve25519-sha256"));
    try testing.expect(hasName("", ""));
}

test "ssh: 主机密钥 blob 结构" {
    const seed = fill(32, 7);
    var hk = try HostKey.fromSeed(testing.allocator, seed);
    defer hk.deinit(testing.allocator);

    var r = Reader{ .buf = hk.blob };
    try testing.expectEqualStrings("ssh-ed25519", try r.string());
    try testing.expectEqual(@as(usize, 32), (try r.string()).len);
    try testing.expectEqual(@as(usize, 0), r.buf.len - r.pos);
}

test "ssh: 同一 seed 的主机密钥稳定（known_hosts 不会天天变）" {
    const seed = fill(32, 9);
    var a = try HostKey.fromSeed(testing.allocator, seed);
    defer a.deinit(testing.allocator);
    var b = try HostKey.fromSeed(testing.allocator, seed);
    defer b.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, a.blob, b.blob);
}

test "ssh: 签名 blob 可被自身公钥验证" {
    const seed = fill(32, 3);
    var hk = try HostKey.fromSeed(testing.allocator, seed);
    defer hk.deinit(testing.allocator);

    const msg = "the quick brown fox";
    const blob = try hk.sign(testing.allocator, msg);
    defer testing.allocator.free(blob);

    var r = Reader{ .buf = blob };
    try testing.expectEqualStrings("ssh-ed25519", try r.string());
    const raw = try r.string();
    try testing.expectEqual(@as(usize, 64), raw.len);

    const sig = Ed25519.Signature.fromBytes(raw[0..64].*);
    try sig.verify(msg, hk.kp.public_key);
}

test "ssh: 密钥派生的六个方向互不相同" {
    const k = fill(32, 0xab);
    const h = fill(32, 0xcd);
    const sid = fill(32, 0xef);

    var iv_c2s: [16]u8 = undefined;
    var iv_s2c: [16]u8 = undefined;
    var key_c2s: [16]u8 = undefined;
    var key_s2c: [16]u8 = undefined;
    var mac_c2s: [32]u8 = undefined;
    var mac_s2c: [32]u8 = undefined;
    derive(&k, h, 'A', sid, &iv_c2s);
    derive(&k, h, 'B', sid, &iv_s2c);
    derive(&k, h, 'C', sid, &key_c2s);
    derive(&k, h, 'D', sid, &key_s2c);
    derive(&k, h, 'E', sid, &mac_c2s);
    derive(&k, h, 'F', sid, &mac_s2c);

    try testing.expect(!std.mem.eql(u8, &iv_c2s, &iv_s2c));
    try testing.expect(!std.mem.eql(u8, &key_c2s, &key_s2c));
    try testing.expect(!std.mem.eql(u8, &mac_c2s, &mac_s2c));
    try testing.expect(!std.mem.eql(u8, &key_c2s, &iv_c2s));
}

// ---------------------------------------------------------------------------
// 连接循环
// ---------------------------------------------------------------------------

/// 处理一条 SSH 连接：版本交换 → KEX → 消息循环。
///
/// 版本交换 + KEX。返回后 `t` 处于加密状态，可以开始收发应用层消息。
///
/// 连接循环（认证 / channel）不在这里 —— 见 `channel.zig`。切开是为了让传输层
/// 的正确性能独立验证：KEX 完成 + 加密通道收发一致，就说明这一层没问题。
pub fn handshake(t: *Transport, host_key: HostKey, alloc: std.mem.Allocator) !void {
    try t.exchangeVersion();
    log.info("ssh: client version {s}", .{t.client_version});

    const kr = try kex(t, host_key, alloc);
    defer kr.deinit(alloc);
    log.info("ssh: kex ok (curve25519-sha256 / ssh-ed25519 / aes128-ctr / hmac-sha2-256)", .{});
}

pub fn sendDisconnect(t: *Transport, reason: u32, desc: []const u8) !void {
    var b = Buf.init(t.alloc);
    defer b.deinit();
    try b.appendByte(MSG_DISCONNECT);
    try putU32(&b, reason);
    try putString(&b, desc);
    try putString(&b, "");
    try t.writePacket(b.slice());
}

// ---------------------------------------------------------------------------
// 测试：协商失败必须显式断开
// ---------------------------------------------------------------------------

test "ssh: 协商失败发 DISCONNECT（而不是静默关 socket）" {
    // 只回 UNIMPLEMENTED 或干脆 close 的话，客户端只会报「连接被对端关闭」，
    // 而运维看到的就是一个没有原因的断连。原因码是唯一能区分「算法不匹配」
    // 和「服务崩了」的东西，所以钉住它。
    var rd = std.Io.Reader.fixed(&.{});
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    var t = Transport{ .alloc = testing.allocator, .rd = &rd, .wr = &out.writer };
    defer t.deinit();

    t.rejectKex(error.NoCommonCipher);

    // 明文包：[len:4][padlen:1][msg:1][reason:4][desc...]
    const w = out.written();
    try testing.expect(w.len > 10);
    try testing.expectEqual(MSG_DISCONNECT, w[5]);
    try testing.expectEqual(DISCONNECT_KEY_EXCHANGE_FAILED, std.mem.readInt(u32, w[6..10], .big));
}

test "ssh: 畸形 KEXINIT 用 PROTOCOL_ERROR 断开" {
    // 解析失败（不是「没有共同算法」）属于协议错误，原因码必须是 2 ——
    // 报成 3 会让对端以为该换算法重试。
    try testing.expectEqual(DISCONNECT_PROTOCOL_ERROR, kexFailInfo(error.EndOfStream).code);
    try testing.expectEqual(DISCONNECT_KEY_EXCHANGE_FAILED, kexFailInfo(error.NoCommonKex).code);
    try testing.expectEqual(DISCONNECT_KEY_EXCHANGE_FAILED, kexFailInfo(error.NoCommonHostKey).code);
    try testing.expectEqual(DISCONNECT_KEY_EXCHANGE_FAILED, kexFailInfo(error.NoCommonMac).code);
}

test "ssh: KEX 失败路径不泄漏（读到的包必须释放）" {
    // 客户端发完 KEXINIT 就断线：kex 会走到「等 KEX_ECDH_INIT」时失败。
    // 这条路径上有三份堆内存：我们自己的 KEXINIT（存进 Transport）、客户端
    // KEXINIT 的原件（读完要释放）、以及 dup 进 Transport 的那份。
    // 用 testing.allocator 跑，漏任何一份都会在测试结束时炸出来 ——
    // 服务端用的是 gpa，这类泄漏在线上只能表现为「内存缓慢增长」。
    var payload = Buf.init(testing.allocator);
    defer payload.deinit();
    try payload.appendByte(MSG_KEXINIT);
    try payload.append(&fill(16, 0)); // cookie
    try putNameList(&payload, "curve25519-sha256");
    try putNameList(&payload, "ssh-ed25519");
    try putNameList(&payload, "aes128-ctr");
    try putNameList(&payload, "aes128-ctr");
    try putNameList(&payload, "hmac-sha2-256");
    try putNameList(&payload, "hmac-sha2-256");
    try putNameList(&payload, "none");
    try putNameList(&payload, "none");
    try putNameList(&payload, "");
    try putNameList(&payload, "");
    try payload.appendByte(0); // first_kex_packet_follows
    try putU32(&payload, 0);

    // 封成线上格式（[len:4][padlen:1][payload][padding]）—— 客户端发来的
    // 就是这个样子，直接喂裸 payload 的话 readPacket 会把它当成长度字段。
    var framed = std.Io.Writer.Allocating.init(testing.allocator);
    defer framed.deinit();
    {
        var no_in = std.Io.Reader.fixed(&.{});
        var tw = Transport{ .alloc = testing.allocator, .rd = &no_in, .wr = &framed.writer };
        try tw.writePacket(payload.slice());
    }

    var rd = std.Io.Reader.fixed(framed.written());
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    var t = Transport{ .alloc = testing.allocator, .rd = &rd, .wr = &out.writer };
    defer t.deinit();

    var hk = try HostKey.fromSeed(testing.allocator, fill(32, 9));
    defer hk.deinit(testing.allocator);

    // 客户端发完 KEXINIT 就断线：kex 在等 KEX_ECDH_INIT 时读到 EOF。
    try testing.expectError(error.ConnectionClosed, kex(&t, hk, testing.allocator));
    // 我们发出去的 KEXINIT 必须已经记在 Transport 上（否则 H 算出别的值）。
    try testing.expect(t.kexinit_sent.len > 0);
    try testing.expect(t.kexinit_recv.len > 0);
}

// ---------------------------------------------------------------------------
// 测试：服务端主动 rekey 的暂存队列
// ---------------------------------------------------------------------------

test "ssh: KEX 期间的非 KEX 包进暂存队列，KEX 包照常返回" {
    // 服务端主动换密钥时，客户端还没看到我们的 KEXINIT，仍可能继续发
    // CHANNEL_DATA。这些包必须收下来（NEWKEYS 之后补投），不能丢 —— 丢了
    // 就是「上传到一半卡住」，而且服务端没有任何日志。
    // 反过来，KEX 消息本身不能被吞进队列，否则密钥交换永远走不完。
    var wire = Buf.init(testing.allocator);
    defer wire.deinit();

    // 先写 CHANNEL_DATA（msg 94），再写 KEXINIT（msg 20）。
    {
        var sink = std.Io.Writer.Allocating.init(testing.allocator);
        defer sink.deinit();
        var no_in = std.Io.Reader.fixed(&.{});
        var tw = Transport{ .alloc = testing.allocator, .rd = &no_in, .wr = &sink.writer };

        var data_pkt = Buf.init(testing.allocator);
        defer data_pkt.deinit();
        try data_pkt.appendByte(94);
        try putU32(&data_pkt, 7); // recipient channel
        try putString(&data_pkt, "hello");
        try tw.writePacket(data_pkt.slice());

        var kex_pkt = Buf.init(testing.allocator);
        defer kex_pkt.deinit();
        try kex_pkt.appendByte(MSG_KEXINIT);
        try kex_pkt.append(&fill(16, 0));
        try putNameList(&kex_pkt, "curve25519-sha256");
        try putNameList(&kex_pkt, "ssh-ed25519");
        try putNameList(&kex_pkt, "aes128-ctr");
        try putNameList(&kex_pkt, "aes128-ctr");
        try putNameList(&kex_pkt, "hmac-sha2-256");
        try putNameList(&kex_pkt, "hmac-sha2-256");
        try putNameList(&kex_pkt, "none");
        try putNameList(&kex_pkt, "none");
        try putNameList(&kex_pkt, "");
        try putNameList(&kex_pkt, "");
        try kex_pkt.appendByte(0);
        try putU32(&kex_pkt, 0);
        try tw.writePacket(kex_pkt.slice());

        try wire.append(sink.written());
    }

    var rd = std.Io.Reader.fixed(wire.slice());
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    var st = Stash{};
    defer st.deinit(testing.allocator);

    var t = Transport{ .alloc = testing.allocator, .rd = &rd, .wr = &out.writer, .stash = &st };
    defer t.deinit();

    const pkt = try readKexPacket(&t, testing.allocator, t.stash);
    defer pkt.deinit(testing.allocator);

    try testing.expectEqual(MSG_KEXINIT, pkt.payload[0]);
    try testing.expectEqual(@as(usize, 1), st.len());

    // 补投时必须还是那条 CHANNEL_DATA，内容一字不差。
    const replayed = st.popFront().?;
    defer testing.allocator.free(replayed);
    try testing.expectEqual(@as(u8, 94), replayed[0]);
    var r = Reader{ .buf = replayed[1..] };
    try testing.expectEqual(@as(u32, 7), try r.u32v());
    try testing.expectEqualStrings("hello", try r.string());
    try testing.expectEqual(@as(usize, 0), st.len());
}

/// 测试用：往 `tw` 写一条完整的、协商能通过的 KEXINIT。
fn appendKexinitPacket(tw: *Transport) !void {
    var kex_pkt = Buf.init(testing.allocator);
    defer kex_pkt.deinit();
    try kex_pkt.appendByte(MSG_KEXINIT);
    try kex_pkt.append(&fill(16, 0));
    try putNameList(&kex_pkt, "curve25519-sha256");
    try putNameList(&kex_pkt, "ssh-ed25519");
    try putNameList(&kex_pkt, "aes128-ctr");
    try putNameList(&kex_pkt, "aes128-ctr");
    try putNameList(&kex_pkt, "hmac-sha2-256");
    try putNameList(&kex_pkt, "hmac-sha2-256");
    try putNameList(&kex_pkt, "none");
    try putNameList(&kex_pkt, "none");
    try putNameList(&kex_pkt, "");
    try putNameList(&kex_pkt, "");
    try kex_pkt.appendByte(0);
    try putU32(&kex_pkt, 0);
    try tw.writePacket(kex_pkt.slice());
}

test "ssh: 暂存的包不占杂项预算（512 预算压死合法窗口的回归）" {
    // 曾经 readKexPacket 把进 stash 的包也计入 512 次循环预算，而合法最坏值
    // （psftp 的 4 KiB WRITE × 2 MiB 在飞窗口）≈ 512 条：预算正好卡死它自己
    // 论证过的场景 —— 高 BDP 链路上客户端的 KEXINIT 排在第 513 个之后，
    // 永远读不到，连接被断。修法：stash 的包只受自己的双上限约束，预算只数
    // IGNORE / DEBUG 之类的杂项包。这里放 600 条数据包再放 KEXINIT：旧代码
    // 在第 512 条时就报 TooManyGenericPackets，新代码必须把 KEXINIT 读到。
    var wire = Buf.init(testing.allocator);
    defer wire.deinit();

    {
        var sink = std.Io.Writer.Allocating.init(testing.allocator);
        defer sink.deinit();
        var no_in = std.Io.Reader.fixed(&.{});
        var tw = Transport{ .alloc = testing.allocator, .rd = &no_in, .wr = &sink.writer };

        var data_pkt = Buf.init(testing.allocator);
        defer data_pkt.deinit();
        try data_pkt.appendByte(94);
        try putU32(&data_pkt, 7);
        try putString(&data_pkt, "hello");
        var i: usize = 0;
        while (i < 600) : (i += 1) try tw.writePacket(data_pkt.slice());

        try appendKexinitPacket(&tw);

        try wire.append(sink.written());
    }

    var rd = std.Io.Reader.fixed(wire.slice());
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    var st = Stash{};
    defer st.deinit(testing.allocator);

    var t = Transport{ .alloc = testing.allocator, .rd = &rd, .wr = &out.writer, .stash = &st };
    defer t.deinit();

    const pkt = try readKexPacket(&t, testing.allocator, t.stash);
    defer pkt.deinit(testing.allocator);
    try testing.expectEqual(MSG_KEXINIT, pkt.payload[0]);
    try testing.expectEqual(@as(usize, 600), st.len());
}

test "ssh: ECDH 之后断连不泄漏（toOwned 的孤儿缓冲）" {
    // 客户端发完 KEX_ECDH_INIT 就断线：kex 会走到「等对端 NEWKEYS」才失败。
    // 这时 `k_mpint.toOwned()` 已经复制出 `k_bytes` —— 曾经那里只挂了
    // `errdefer k_mpint.deinit()`，而 toOwned 是复制不是移交：原件在成功路径
    // 每次 KEX 漏一份，失败路径还漏掉 `k_bytes` 这个孤儿（约 34 B，但每次
    // KEX 都漏）。钉住失败路径这一种；成功路径那份只能靠完整握手（e2e 脚本）
    // 才测得到。用 testing.allocator，漏了就在测试结束时炸出来。
    var wire = Buf.init(testing.allocator);
    defer wire.deinit();

    {
        var sink = std.Io.Writer.Allocating.init(testing.allocator);
        defer sink.deinit();
        var no_in = std.Io.Reader.fixed(&.{});
        var tw = Transport{ .alloc = testing.allocator, .rd = &no_in, .wr = &sink.writer };

        try appendKexinitPacket(&tw);

        // KEX_ECDH_INIT（msg 30）：Q_C 是任意 32 字节 —— X25519 对任意
        // u 坐标都能算出共享秘密（只有低阶点报错，0x11 重复不在那个集合里）。
        var ecdh = Buf.init(testing.allocator);
        defer ecdh.deinit();
        try ecdh.appendByte(MSG_KEX_ECDH_INIT);
        try putString(&ecdh, &fill(32, 0x11));
        try tw.writePacket(ecdh.slice());

        try wire.append(sink.written());
    }

    var rd = std.Io.Reader.fixed(wire.slice());
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    var t = Transport{ .alloc = testing.allocator, .rd = &rd, .wr = &out.writer };
    defer t.deinit();

    var hk = try HostKey.fromSeed(testing.allocator, fill(32, 9));
    defer hk.deinit(testing.allocator);

    // 走完 KEXINIT / ECDH / 签名 / 发 NEWKEYS，在「等对端 NEWKEYS」时 EOF。
    try testing.expectError(error.ConnectionClosed, kex(&t, hk, testing.allocator));
}

test "ssh: 暂存队列有上限（超了报错而不是吃内存）" {
    // 一个窗口最多 2 MiB 的 CHANNEL_DATA；队列按字节封顶 4 MiB，所以正常
    // 客户端永远碰不到这个上限。恶意客户端会，那时必须断开而不是继续攒。
    var st = Stash{};
    defer st.deinit(testing.allocator);

    const chunk = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(chunk);
    @memset(chunk, 0xaa);

    var i: usize = 0;
    while (i < 4) : (i += 1) try st.push(testing.allocator, chunk);
    try testing.expectEqual(@as(usize, 4 * 1024 * 1024), st.bytes);
    try testing.expectError(error.TooManyPendingPackets, st.push(testing.allocator, chunk));
}

test "ssh: 暂存队列容得下 psftp 的 4 KiB 分片（服务端主动 rekey 回归）" {
    // 实测回归：`max_items` 曾经是 256，注释假设客户端按 8 KiB 分片。但 PuTTY
    // `psftp` 的 WRITE 是 ~4 KiB（服务端日志 `incoming=4134`），2 MiB 在飞窗口
    // 要 ~512 条 ⇒ 256 条在**只攒到 1 MiB** 时就撞上限，连接被断，客户端看到
    // 的是 `Software caused connection abort`。只有「服务端主动 rekey + 2 MiB
    // 上传」这一种组合能触发，小文件或客户端主动 rekey 都测不出来。
    var st = Stash{};
    defer st.deinit(testing.allocator);

    const chunk = try testing.allocator.alloc(u8, 4134);
    defer testing.allocator.free(chunk);
    @memset(chunk, 0x5a);

    var i: usize = 0;
    while (i < 512) : (i += 1) try st.push(testing.allocator, chunk);
    try testing.expectEqual(@as(usize, 512), st.len());
    try testing.expect(st.bytes > 2 * 1024 * 1024);
}

test "ssh: 读包计数会累加，KEX 完成后归零" {
    // 服务端主动 rekey 的触发依据就是这两个计数。不累加 ⇒ 永远不换密钥；
    // 不归零 ⇒ 阈值一到每轮循环都触发，连接直接抖死。
    var rd = std.Io.Reader.fixed(&.{});
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    var t = Transport{ .alloc = testing.allocator, .rd = &rd, .wr = &out.writer };
    defer t.deinit();

    try t.writePacket(&[_]u8{ 2, 0, 0, 0 });
    const after_one = t.bytesSinceKex();
    try testing.expect(after_one > 0);
    try testing.expectEqual(after_one, t.kex_bytes_out);

    t.kex_bytes_in = 0;
    t.kex_bytes_out = 0;
    try testing.expectEqual(@as(u64, 0), t.bytesSinceKex());
}

test "ssh: 主机密钥文件权限是 0600" {
    // 文件里是 32 字节 ed25519 seed：拿到它就能冒充这台服务器。默认权限
    // （0666 & ~umask）通常是 0644 —— 同组用户可读。这条测试同时钉住两件事：
    // 首次生成会落盘，且落盘后的 mode 是 0600。Windows 没有 POSIX mode，
    // 跳过。
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(root);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/host_ed25519", .{root});
    defer testing.allocator.free(path);

    var hk = try HostKey.loadOrCreate(testing.allocator, path);
    defer hk.deinit(testing.allocator);

    var f = try std.Io.Dir.cwd().openFile(rt.io(), path, .{});
    defer f.close(rt.io());
    const st = try f.stat(rt.io());
    // ⚠ 0.17 的 `Io.File.Stat` 没有 `mode` 字段，POSIX 权限在 `permissions`
    // （`enum(mode_t)`）里，取位用 `@intFromEnum` —— 与 `drivers/local.zig`
    // 的 mkdir_perm 测试同一写法。曾经这里写 `st.mode`：Windows 上被上面的
    // comptime 跳过（函数体后半段不分析）永远测不出来，**Linux 上一编译就
    // 炸**——打包机的测试闸门从 d41acfcc 起就是这么断的，直到 2026-11-02
    // 重建时才暴露。
    const mode: u32 = @intCast(@intFromEnum(st.permissions));
    try testing.expectEqual(@as(u32, 0o600), mode & 0o777);

    // 再加载一次必须是同一把密钥（known_hosts 不能天天变）。
    var again = try HostKey.loadOrCreate(testing.allocator, path);
    defer again.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, hk.blob, again.blob);
}
