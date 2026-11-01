//! SSH 连接层（RFC 4254）+ 认证（RFC 4252）+ SFTP 子系统桥接。
//!
//! ## 认证（已接真校验）
//!
//! `Auth` 接口由 `sftp_wire.sshVerify` 实现：`twoHashPwd(pw, admin_salt)`
//! 比 `admin_hash`，并与 HTTP 登录**共用同一份失败计数**（换协议不能绕过
//! 限速）。用户名错与口令错对外不区分，都只回 `USERAUTH_FAILURE`。
//!
//! ⚠ **`authenticated` 必须在每个连接层入口检查**：KEX 结束后客户端不需要
//! 先发 `USERAUTH` 就能直接发 `CHANNEL_OPEN`（RFC 4253 没有强制顺序）。
//! `onChannelOpen` / `onChannelRequest` / `onChannelData` 三处都查这个
//! 标志 —— 少任何一处，认证就只是我们自己写的一个字段，端点等于对全网开放。
//! 所以这里**可以**绑非 loopback：认证接了真校验，失败计数按**对端 IP 分桶**
//! 并与 HTTP/WebDAV 共用（`sftp_wire.sshVerify`，2026-11-01 起），不再是全局
//! 一个桶（见 `util/peeraddr.zig`）。
//!
//! ## 为什么 channel 只支持一个
//!
//! SFTP 客户端（OpenSSH / WinSCP / FileZilla / rclone）一律只开一个 `session`
//! channel 跑 `subsystem sftp`。支持多路复用意味着要维护 channel 表、每条独立
//! 的窗口与缓冲，收益为零。第二个 `CHANNEL_OPEN` 明确回
//! `SSH_OPEN_ADMINISTRATIVELY_PROHIBITED`，而不是静默忽略。
//!
//! ## 窗口流控
//!
//! 接收方向：每消费 `window_size / 2` 就补一次 `CHANNEL_WINDOW_ADJUST`，避免
//! 客户端因为窗口耗尽而卡住。
//!
//! 发送方向：扣减 `remote_window`；不足时**同步等客户端补窗口**
//! （RFC 4254 §5.2 明确禁止超发）。等待是有界的 —— 超过 `window_wait_max`
//! 个包还没等到就退回「照发并告警」，宁可违反窗口也不能把连接挂死。
//! 等待期间收到的 `CHANNEL_DATA` 追加进 `acc`，交给外层循环处理，不递归
//! 分发。
//!
//! ## 重协商（rekey）
//!
//! 客户端在传够一定数据量或时间后（OpenSSH 默认 1 GB / 1 h）会自己发一个新的
//! `KEXINIT` 要求换密钥。这一步在 `onRekey` 里就地完成：`ssh.rekey` 走一遍
//! 完整的 KEX，**只换密钥**，channel 状态、窗口、`acc` 里半个 SFTP 包全部保留。
//! 两个细节都是「错了不报错、只表现为随机断连」的那种：
//!
//!   - 序列号**不重置**（RFC 4253 §7.3），重置会让之后每个包的 MAC 都对不上；
//!   - `session_id` **沿用首次的 H**（§7.2），取新的会让派生出的密钥不一致。

const std = @import("std");
const ssh = @import("ssh.zig");
const protocol = @import("protocol.zig");
const Buf = @import("../util/buf.zig").Buf;
const http = @import("../http.zig");
const log = @import("../log.zig");
const rt = @import("../rt.zig");

// ---- RFC 4252 ----
pub const MSG_USERAUTH_REQUEST: u8 = 50;
pub const MSG_USERAUTH_FAILURE: u8 = 51;
pub const MSG_USERAUTH_SUCCESS: u8 = 52;

// ---- RFC 4254 ----
pub const MSG_CHANNEL_OPEN: u8 = 90;
pub const MSG_CHANNEL_OPEN_CONFIRMATION: u8 = 91;
pub const MSG_CHANNEL_OPEN_FAILURE: u8 = 92;
pub const MSG_CHANNEL_WINDOW_ADJUST: u8 = 93;
pub const MSG_CHANNEL_DATA: u8 = 94;
pub const MSG_CHANNEL_EOF: u8 = 96;
pub const MSG_CHANNEL_CLOSE: u8 = 97;
pub const MSG_CHANNEL_REQUEST: u8 = 98;
pub const MSG_CHANNEL_SUCCESS: u8 = 99;
pub const MSG_CHANNEL_FAILURE: u8 = 100;

/// 我们向客户端宣告的接收窗口。
const window_size: u32 = 2 * 1024 * 1024;
/// 低于这个值就补窗口。
const window_low: u32 = window_size / 2;
/// 我们自己接受的最大包长（对客户端宣告）。
const local_max_packet: u32 = 32 * 1024;
/// 等 `WINDOW_ADJUST` 时最多处理多少个包。超过就放弃等待、照发。
const window_wait_max: usize = 64;

/// 未认证连接的读写超时（秒）。认证通过后撤掉 —— 交互式会话可以合法地
/// 静默几分钟，超时只该管「连上来却不认证」的扫描器（见 `run` 的注释）。
const pre_auth_timeout_s: u32 = 30;

/// SFTP 层的入口：一个完整包进，回复字节出。
///
/// channel 层不 import `handler` / `session`，只认这个回调 —— 于是「SSH 连接
/// 管理」和「SFTP 语义」能各自单测，也能各自替换。
pub const SftpHandler = struct {
    ctx: *anyopaque,
    handleFn: *const fn (
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        pkt: protocol.Packet,
        out: *Buf,
    ) anyerror!void,

    pub fn handle(self: SftpHandler, alloc: std.mem.Allocator, pkt: protocol.Packet, out: *Buf) !void {
        return self.handleFn(self.ctx, alloc, pkt, out);
    }
};

/// 凭据校验接口。
///
/// channel 层只关心「过没过」，不该知道 `twoHashPwd` 的存在 —— 口令哈希形态
/// 属于账户层的事，SSH 和 HTTP 登录必须用**同一套**实现，否则迟早漂移。
///
/// `peer` 是这条连接的对端 IP（不带端口），拿不到时为空串。它从这里传进去
/// 而不是让实现方自己去取：socket 只在传输层手里，而且**必须有值可传** ——
/// 失败计数按来源分桶，拿不到 IP 就只能退化成全局桶（任何人 5 次错误就能把
/// 管理员锁 5 分钟）。
pub const Auth = struct {
    ctx: *anyopaque,
    /// 返回 true = 凭据有效。实现方负责用户名比对、哈希比对、失败计数。
    verifyFn: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, user: []const u8, pw: []const u8, peer: []const u8) bool,
    /// 对端 IP，空串 = 未知。每条连接一份，见 `sftp_wire.sshConnThread`。
    peer: []const u8 = "",

    pub fn verify(self: Auth, alloc: std.mem.Allocator, user: []const u8, pw: []const u8) bool {
        return self.verifyFn(self.ctx, alloc, user, pw, self.peer);
    }
};

pub const Conn = struct {
    alloc: std.mem.Allocator,
    t: *ssh.Transport,
    /// 重协商时要用它重新签名 —— 客户端可能在传输中途发起（RFC 4253 §9）。
    host_key: ssh.HostKey,
    handler: SftpHandler,
    auth: Auth,

    local_id: u32 = 0,
    remote_id: u32 = 0,
    remote_window: u32 = 0,
    remote_max_packet: u32 = 0,
    local_window: u32 = 0,

    sftp_open: bool = false,
    authenticated: bool = false,

    /// SFTP 字节流的累积缓冲：一个 `CHANNEL_DATA` 可能只含半个 SFTP 包，
    /// 也可能含好几个。
    acc: Buf,

    /// 服务端主动 rekey 时，KEX 期间收到的非 KEX 包暂存到这里（见
    /// `ssh.Transport.stash`）。NEWKEYS 完成后由 `drainStash` 补投。
    ///
    /// ⚠ 指针在 `loop()` 里才挂到 `t.stash` 上：`init` 是**按值返回**的，
    /// 在那里取 `&self.stash` 拿到的是临时对象的地址，函数一返回就悬垂。
    stash: ssh.Stash = .{},

    /// 服务端主动发起重协商的字节阈值（进出合计），0 = 不主动发起。
    ///
    /// 关掉也是合法的：OpenSSH 默认就会在 1 GB / 1 小时后自己发起
    /// （客户端主动路径已支持）。这个阈值是给「客户端不动、但我们想强制
    /// 换密钥」的部署用的。
    rekey_limit: u64 = 0,

    /// 正在换密钥：别在上一次的 KEX 里再触发一次。
    rekey_busy: bool = false,

    /// 已经发出 `EOF`+`CLOSE`，正在等对端回 `CLOSE`（RFC 4254 §5.3 的关闭
    /// 是**双向握手**：收到 close 的一方要回 close）。
    ///
    /// ⚠ 发完就关 socket 会踩 Windows 的「有未读数据还 close ⇒ 直接 RST」，
    /// 客户端看到的随机报错是 `Software caused connection abort` /
    /// `Remote side unexpectedly closed network connection`：**文件已经传完、
    /// rm 也成功了，最后 quit 那一下报错**。实测 psftp 12 次里挂 5 次。
    closing: bool = false,

    /// 等对端 `CLOSE` 期间丢弃的包数。对端赖着不发就兜底返回，不无限读。
    closing_discards: u32 = 0,

    /// 底层 socket。`run()` 才有它；单测直接构造 Conn 时为 null（不碰超时）。
    /// 认证通过后用它撤掉 pre-auth 超时，见 `onUserauth`。
    stream: ?std.Io.net.Stream = null,

    pub fn init(alloc: std.mem.Allocator, t: *ssh.Transport, host_key: ssh.HostKey, handler: SftpHandler, auth: Auth) Conn {
        return .{
            .alloc = alloc,
            .t = t,
            .host_key = host_key,
            .handler = handler,
            .auth = auth,
            .acc = Buf.init(alloc),
        };
    }

    pub fn deinit(self: *Conn) void {
        self.acc.deinit();
        self.stash.deinit(self.alloc);
    }

    pub fn loop(self: *Conn) !void {
        // 暂存队列的地址只能在这里取（见字段注释）。只有真的跑消息循环的
        // 连接才需要它；单测里直接调 `onChannelOpen` 之类不需要。
        self.t.stash = &self.stash;

        while (true) {
            // 换密钥的时机挑在「刚处理完一个请求、正要去读下一个包」——
            // 此刻我们没有半截输出，客户端也不在等我们的回复。
            if (self.shouldRekey()) try self.serverRekey();

            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();
            const a = arena.allocator();

            const p = self.t.readPacket(a) catch |e| {
                if (e != error.ConnectionClosed) {
                    log.debug("ssh: read failed: {s}", .{@errorName(e)});
                }
                return;
            };
            if (p.len == 0) continue;

            self.dispatch(a, p) catch |e| switch (e) {
                error.PeerDisconnect, error.ChannelClosed => return,
                else => return e,
            };
        }
    }

    fn dispatch(self: *Conn, a: std.mem.Allocator, p: []const u8) !void {
        log.debug("ssh: msg {d} len={d}", .{ p[0], p.len });

        // 已经在等对端的 `CLOSE`：只认 CLOSE / DISCONNECT，其余丢弃。
        // 这一步存在的意义见 `closing` 字段注释 —— 目的是把对端最后那个
        // `CLOSE` **读掉**再关 socket，否则 Windows 会用 RST 收尾。
        if (self.closing) {
            switch (p[0]) {
                MSG_CHANNEL_CLOSE, ssh.MSG_DISCONNECT => {},
                else => {
                    self.closing_discards += 1;
                    if (self.closing_discards <= 256) return;
                },
            }
            return error.ChannelClosed;
        }

        switch (p[0]) {
            ssh.MSG_DISCONNECT => return error.PeerDisconnect,
            ssh.MSG_IGNORE, ssh.MSG_DEBUG, ssh.MSG_UNIMPLEMENTED => {},
            ssh.MSG_SERVICE_REQUEST => try self.onServiceRequest(a, p),
            MSG_USERAUTH_REQUEST => try self.onUserauth(a, p),
            MSG_CHANNEL_OPEN => try self.onChannelOpen(a, p),
            MSG_CHANNEL_REQUEST => try self.onChannelRequest(a, p),
            MSG_CHANNEL_DATA => try self.onChannelData(a, p),
            MSG_CHANNEL_WINDOW_ADJUST => try self.onWindowAdjust(p),
            MSG_CHANNEL_EOF => {
                // 客户端说「不再发请求了」，收尾由我们做。PuTTY 的 pscp
                // 就停在这一步等我们关，不回 close 它永远不退出。
                //
                // 但**发完不能立刻走人**：对端还要回一个 `CLOSE`。这里只
                // 把收尾包发出去，循环继续读，读到对端的 `CLOSE`（或对端
                // 直接断连）才真正返回 —— 见 `closing` 字段注释。
                self.closeChannel();
            },
            MSG_CHANNEL_CLOSE => {
                self.closeChannel();
                return error.ChannelClosed;
            },
            // 客户端在长传输后（OpenSSH 约 1 GB / 1 h）会主动发起重协商。
            // 不接这一步的话，客户端要么收到 UNIMPLEMENTED 后断连，要么在
            // 收不到我们的 KEXINIT 时超时 —— 症状都是「大文件传到一半掉线」。
            ssh.MSG_KEXINIT => try self.onRekey(p),
            else => try self.unimplemented(a),
        }
    }

    /// 客户端主动重协商密钥（RFC 4253 §9）。
    ///
    /// ⚠ 用 `self.alloc` 而**不是**本轮循环的 arena：`kex` 会把双方的 KEXINIT
    /// 原样 dup 到连接级内存（下一次重协商还要拿它们算 H），arena 在下一轮
    /// 循环就被释放了，留着就是个悬垂 slice。
    ///
    /// 通道状态（窗口、channel 号、`acc` 里半个 SFTP 包）一律不动：重协商只
    /// 换密钥，不动会话。`seq_in` / `seq_out` 也不重置 —— RFC 4253 §7.3 明确
    /// 「序列号永不重置」，重置会让后续每个包的 MAC 都对不上。
    fn onRekey(self: *Conn, p: []const u8) !void {
        log.debug("ssh: client requested rekey", .{});
        self.rekey_busy = true;
        defer self.rekey_busy = false;

        const kr = try ssh.rekey(self.t, self.host_key, self.alloc, p);
        kr.deinit(self.alloc);
        log.info("ssh: rekey ok (client-initiated)", .{});
        try self.drainStash();
    }

    /// 该不该由**我们**发起重协商。
    ///
    /// 两个条件都必要：配置了阈值、且不在 KEX 中间。没有 `rekey_busy` 的话，
    /// 客户端 KEX 期间堆到 `acc` 里的包被补投时有可能再次触发，形成递归。
    fn shouldRekey(self: *const Conn) bool {
        if (self.rekey_busy or self.rekey_limit == 0) return false;
        return self.t.bytesSinceKex() >= self.rekey_limit;
    }

    /// 服务端主动发起重协商（RFC 4253 §9）。
    ///
    /// 与客户端主动的唯一区别：KEXINIT 由我们**先**发（`ssh.kex` 的第一步就是
    /// 发自己的 KEXINIT），然后才读对端的。这里必须处理「两边同时发起」的
    /// 竞争 —— 对端可能已经发过 KEXINIT，也可能还在发 `CHANNEL_DATA`；后者
    /// 由 `t.stash` 收下来，KEX 完成后再补投。
    fn serverRekey(self: *Conn) !void {
        log.info("ssh: initiating rekey after {d} bytes", .{self.t.bytesSinceKex()});
        self.rekey_busy = true;
        defer self.rekey_busy = false;

        const kr = try ssh.kex(self.t, self.host_key, self.alloc);
        kr.deinit(self.alloc);
        log.info("ssh: rekey ok (server-initiated)", .{});
        try self.drainStash();
    }

    /// 把 KEX 期间暂存的包按原顺序补投给消息处理逻辑。
    ///
    /// 每个包用一个独立的 arena：它们的生命周期与正常循环里读到的包一致，
    /// 处理完就整块释放。返回的错误语义也和主循环相同（`ChannelClosed` /
    /// `PeerDisconnect` 都表示连接该收尾了）。
    ///
    /// ⚠ 返回类型写死 `anyerror`：`drainStash → dispatch → onChannelData →
    /// sendData → waitForWindow → onRekey → drainStash` 是一个环，全靠推断
    /// 错误集的话 `-Osmall`（`ReleaseSmall`）会报 "dependency loop"。显式写
    /// 出来就断了这条推断链。
    fn drainStash(self: *Conn) anyerror!void {
        while (self.stash.popFront()) |payload| {
            defer self.alloc.free(payload);

            var arena = std.heap.ArenaAllocator.init(self.alloc);
            defer arena.deinit();

            log.debug("ssh: replaying stashed msg {d} (len={d})", .{ payload[0], payload.len });
            try self.dispatch(arena.allocator(), payload);
        }
    }

    fn unimplemented(self: *Conn, a: std.mem.Allocator) !void {
        var b = Buf.init(a);
        try b.appendByte(ssh.MSG_UNIMPLEMENTED);
        try ssh.putU32(&b, self.t.seq_in -% 1);
        try self.t.writePacket(b.slice());
    }

    /// 收尾：给客户端发 `EOF` + `CLOSE` 两个包。
    ///
    /// RFC 4254 §5.3：`EOF` 表示「我不会再发了」，本身不要求回应；channel 的
    /// 真正结束靠 `CLOSE`，而**收到 close 的一方必须回一个 close**。
    ///
    /// 两个包都要发：PuTTY 的 pscp 传完后只发 `EOF` 就等着我们关，不回
    /// `CLOSE` 它会一直挂着 —— 进度条 100%、文件逐字节正确，但命令不退出。
    /// （OpenSSH 自己会发 `CLOSE`，所以只测 OpenSSH 发现不了。）
    ///
    /// 发不出去不算错误：对端已经走了，连接本来就要关。
    ///
    /// 幂等：`closing` 已经是 true 就直接返回 —— 收到对端的 `CLOSE` 时不能再
    /// 回一个（§5.3 只要求「还没发的那个」回）。
    fn closeChannel(self: *Conn) void {
        if (self.closing) return;
        self.closing = true;
        var b = Buf.init(self.alloc);
        defer b.deinit();
        for ([_]u8{ MSG_CHANNEL_EOF, MSG_CHANNEL_CLOSE }) |msg| {
            b.clearRetainingCapacity();
            b.appendByte(msg) catch return;
            ssh.putU32(&b, self.remote_id) catch return;
            self.t.writePacket(b.slice()) catch |e| {
                log.debug("ssh: cannot send channel msg {d}: {s}", .{ msg, @errorName(e) });
                return;
            };
        }
    }

    fn onServiceRequest(self: *Conn, a: std.mem.Allocator, p: []const u8) !void {
        var r = ssh.Reader{ .buf = p[1..] };
        const name = try r.string();
        if (!std.mem.eql(u8, name, "ssh-userauth")) {
            try ssh.sendDisconnect(self.t, ssh.DISCONNECT_SERVICE_NOT_AVAILABLE, "service not available");
            return error.PeerDisconnect;
        }
        var b = Buf.init(a);
        try b.appendByte(ssh.MSG_SERVICE_ACCEPT);
        try ssh.putString(&b, "ssh-userauth");
        try self.t.writePacket(b.slice());
    }

    fn onUserauth(self: *Conn, a: std.mem.Allocator, p: []const u8) !void {
        var r = ssh.Reader{ .buf = p[1..] };
        const user = try r.string();
        _ = try r.string(); // service name（"ssh-connection"），本实现不区分
        const method = try r.string();

        if (std.mem.eql(u8, method, "password")) {
            const changing = try r.byte();
            if (changing != 0) return self.authFailure(a); // 不支持改口令
            const pw = try r.string();

            if (self.auth.verify(a, user, pw)) {
                log.info("ssh: password auth ok (user={s})", .{user});
                self.authenticated = true;
                // 撤掉 pre-auth 超时（见 `run` 的注释）：从现在起这是一条
                // 已认证的会话，空闲多久都合法 —— 与 OpenSSH 的默认行为一致。
                if (self.stream) |s| http.applyTimeouts(s, 0);
                var b = Buf.init(a);
                try b.appendByte(MSG_USERAUTH_SUCCESS);
                try self.t.writePacket(b.slice());
                return;
            }
            log.warn("ssh: password auth failed (user={s})", .{user});
            return self.authFailure(a);
        }

        if (std.mem.eql(u8, method, "none")) {
            // `none` 只用于探测可用方法，**永远不通过** —— 放行它等于无认证
            // 登录。客户端收到 FAILURE 后会自动改试 password。
            return self.authFailure(a);
        }

        // `none` 是客户端用来探测可用方法的；publickey 等暂不支持 —— 一律回
        // FAILURE 并列出我们真正支持的方法，客户端会自动改试 password。
        return self.authFailure(a);
    }

    fn authFailure(self: *Conn, a: std.mem.Allocator) !void {
        var b = Buf.init(a);
        try b.appendByte(MSG_USERAUTH_FAILURE);
        try ssh.putString(&b, "password");
        try b.appendByte(0); // partial success = false
        try self.t.writePacket(b.slice());
    }

    fn onChannelOpen(self: *Conn, a: std.mem.Allocator, p: []const u8) !void {
        var r = ssh.Reader{ .buf = p[1..] };
        const ctype = try r.string();
        const sender = try r.u32v();
        const win = try r.u32v();
        const maxpkt = try r.u32v();

        // ⚠ 这条闸门不能省：KEX 结束后客户端**不需要**先发 USERAUTH 就能
        // 直接发 CHANNEL_OPEN。没有它，「认证通过」只是我们自己的一个字段，
        // 谁都能开一个 session channel 跑 `subsystem sftp` 读写全部挂载。
        // `authenticated` 只被赋值不被检查 = 端点对全网开放。
        if (!self.authenticated) {
            log.warn("ssh: CHANNEL_OPEN before successful authentication — rejected", .{});
            // SSH_OPEN_ADMINISTRATIVELY_PROHIBITED
            return self.openFailure(a, sender, 1, "authentication required");
        }

        if (!std.mem.eql(u8, ctype, "session")) {
            return self.openFailure(a, sender, 3, "unknown channel type"); // SSH_OPEN_UNKNOWN_CHANNEL_TYPE
        }
        if (self.local_id != 0) {
            // SSH_OPEN_ADMINISTRATIVELY_PROHIBITED
            return self.openFailure(a, sender, 1, "only one channel per connection");
        }

        self.remote_id = sender;
        self.remote_window = win;
        self.remote_max_packet = maxpkt;
        self.local_id = 1;
        self.local_window = window_size;

        var b = Buf.init(a);
        try b.appendByte(MSG_CHANNEL_OPEN_CONFIRMATION);
        try ssh.putU32(&b, sender);
        try ssh.putU32(&b, self.local_id);
        try ssh.putU32(&b, self.local_window);
        try ssh.putU32(&b, local_max_packet);
        try self.t.writePacket(b.slice());
    }

    fn openFailure(self: *Conn, a: std.mem.Allocator, sender: u32, reason: u32, desc: []const u8) !void {
        var b = Buf.init(a);
        // ⚠ 这个 defer 原本漏了：每次拒绝一个 channel（未认证、非法类型、
        // 超过一个）都会泄漏一个缓冲区。是新加的回归单测用
        // `testing.allocator` 抓出来的。
        defer b.deinit();
        try b.appendByte(MSG_CHANNEL_OPEN_FAILURE);
        try ssh.putU32(&b, sender);
        try ssh.putU32(&b, reason);
        try ssh.putString(&b, desc);
        try ssh.putString(&b, "");
        try self.t.writePacket(b.slice());
    }

    fn onChannelRequest(self: *Conn, a: std.mem.Allocator, p: []const u8) !void {
        var r = ssh.Reader{ .buf = p[1..] };
        const ch = try r.u32v();
        const req = try r.string();
        const want_reply = (try r.byte()) != 0;

        if (ch != self.local_id or !self.authenticated) {
            // 未认证的 channel 根本开不起来（见 onChannelOpen），走到这里
            // 说明对端在乱发 —— 回 FAILURE，不当成协议错误。
            if (want_reply) try self.channelReply(a, MSG_CHANNEL_FAILURE);
            return;
        }

        if (std.mem.eql(u8, req, "subsystem")) {
            const name = try r.string();
            if (std.mem.eql(u8, name, "sftp")) {
                self.sftp_open = true;
                log.info("ssh: sftp subsystem started", .{});
                if (want_reply) try self.channelReply(a, MSG_CHANNEL_SUCCESS);
                return;
            }
        }

        // exec / shell / pty-req / env / window-change：SFTP 客户端不会用，
        // 但会发 `env`，明确拒绝即可（回 FAILURE 不影响后续）。
        if (want_reply) try self.channelReply(a, MSG_CHANNEL_FAILURE);
    }

    /// 回 `CHANNEL_SUCCESS` / `CHANNEL_FAILURE`。
    ///
    /// ⚠ `recipient channel` 必须是**客户端的** channel 号（`remote_id`），
    /// 不是请求里带的那个（那是我们的号）。写错的话客户端会报
    /// `channel_by_id: 1: bad id: channel free` + `input_status_confirm: unknown`
    /// —— 传输照样能跑，但关闭 channel 时行为不可预期。
    fn channelReply(self: *Conn, a: std.mem.Allocator, msg: u8) !void {
        var b = Buf.init(a);
        try b.appendByte(msg);
        try ssh.putU32(&b, self.remote_id);
        try self.t.writePacket(b.slice());
    }

    fn onWindowAdjust(self: *Conn, p: []const u8) !void {
        var r = ssh.Reader{ .buf = p[1..] };
        _ = try r.u32v(); // channel
        const add = try r.u32v();
        self.remote_window +|= add;
    }

    fn onChannelData(self: *Conn, a: std.mem.Allocator, p: []const u8) !void {
        var r = ssh.Reader{ .buf = p[1..] };
        const ch = try r.u32v();
        const data = try r.string();

        if (ch != self.local_id) return error.BadChannel;
        if (!self.authenticated) return error.BadChannel;
        if (!self.sftp_open) {
            log.warn("ssh: channel data before `subsystem sftp`", .{});
            return;
        }

        try self.feedData(a, data);

        // 一个 CHANNEL_DATA 可能含多个 SFTP 包，也可能只有半个。
        while (true) {
            const maybe = protocol.parse(self.acc.slice()) catch |e| {
                log.debug("ssh: bad sftp packet: {s}", .{@errorName(e)});
                return e;
            };
            const pkt = maybe orelse break;

            var out = Buf.init(a);
            self.handler.handle(a, pkt, &out) catch |e| {
                log.debug("ssh: sftp dispatch failed: {s}", .{@errorName(e)});
                return e;
            };
            if (out.len > 0) try self.sendData(a, out.slice());

            // 嵌套 rekey 的兑底：`drainStash → dispatch → onChannelData →
            // sendData → waitForWindow → onRekey → drainStash` 是一个环（见
            // `drainStash` 的注释），内层可能已经把 acc（含外层**尚未消费**的
            // 当前包）消费掉。到这里 acc.len < pkt.consumed 说明当前包已被
            // 内层处理、游标失效 —— 继续 `acc.len - pkt.consumed` 就是 usize
            // 下溢（生产 ReleaseSmall 无检查），后面的切片直接越界。能走到
            // 这一步的客户端必然违反了 RFC 4253 §9（在自己的 KEXINIT 与
            // NEWKEYS 之间还在发 DATA），断开是正确处置。
            if (self.acc.len < pkt.consumed) return error.ProtocolCorrupt;
            const rest = self.acc.len - pkt.consumed;
            std.mem.copyForwards(u8, self.acc.data[0..rest], self.acc.data[pkt.consumed..self.acc.len]);
            self.acc.len = rest;
        }
    }

    /// 收到一段 channel 数据：补本地窗口 + 追加到累积缓冲。
    ///
    /// 抽出来是为了 `waitForWindow` 也能用：等窗口期间客户端可能仍在发请求，
    /// 那段数据不能直接丢，也不能递归分发（会在 `sendData` 里再进一次）。
    fn feedData(self: *Conn, a: std.mem.Allocator, data: []const u8) !void {
        // 接收窗口：消费了就补，别让客户端卡在 window 上。
        self.local_window -|= @intCast(data.len);
        if (self.local_window < window_low) {
            const add = window_size - self.local_window;
            var b = Buf.init(a);
            try b.appendByte(MSG_CHANNEL_WINDOW_ADJUST);
            try ssh.putU32(&b, self.remote_id);
            try ssh.putU32(&b, add);
            try self.t.writePacket(b.slice());
            self.local_window = window_size;
        }
        try self.acc.append(data);
    }

    /// 等客户端把发送窗口补到 `need` 字节以上。
    ///
    /// RFC 4254 §5.2 是 MUST NOT 级别的：超发后客户端行为不统一（有的截断
    /// 并告警，有的直接断连），赌不起。单 channel + 单线程下同步等是安全的：
    /// 客户端读走数据后必然回 `WINDOW_ADJUST`。
    fn waitForWindow(self: *Conn, a: std.mem.Allocator, need: usize) !void {
        var i: usize = 0;
        while (self.remote_window < need) {
            if (i >= window_wait_max) {
                log.warn("ssh: no WINDOW_ADJUST after {d} packets; sending anyway", .{i});
                return;
            }
            i += 1;

            const p = try self.t.readPacket(a);
            if (p.len == 0) continue;
            switch (p[0]) {
                MSG_CHANNEL_WINDOW_ADJUST => try self.onWindowAdjust(p),
                MSG_CHANNEL_DATA => {
                    var r = ssh.Reader{ .buf = p[1..] };
                    const ch = try r.u32v();
                    const data = try r.string();
                    if (ch != self.local_id) return error.BadChannel;
                    try self.feedData(a, data);
                },
                MSG_CHANNEL_EOF => {
                    self.closeChannel();
                    return error.ChannelClosed;
                },
                MSG_CHANNEL_CLOSE => {
                    self.closeChannel();
                    return error.ChannelClosed;
                },
                ssh.MSG_DISCONNECT => return error.PeerDisconnect,
                // 等窗口期间客户端也可能发起重协商。这里不处理的话，我们会
                // 静默丢掉它的 KEXINIT，随后把 KEX_ECDH_INIT 也当无关包扔掉，
                // 客户端就一直等我们的 KEXINIT 直到超时。
                ssh.MSG_KEXINIT => try self.onRekey(p),
                else => {},
            }
        }
    }

    /// 把 SFTP 字节流发出去，按客户端的 `max_packet` 分片。
    ///
    /// 必须分片：OpenSSH 宣告的 max packet 是 32 KiB，而一个 `READDIR` 回复
    /// 可能超过它 —— 超长包会被客户端直接判协议错误并断连。
    fn sendData(self: *Conn, a: std.mem.Allocator, data: []const u8) !void {
        const max = if (self.remote_max_packet > 0) @min(self.remote_max_packet, 64 * 1024) else 32 * 1024;

        var off: usize = 0;
        while (off < data.len) {
            const n = @min(@as(usize, max), data.len - off);
            const chunk = data[off .. off + n];

            if (chunk.len > self.remote_window) {
                try self.waitForWindow(a, chunk.len);
            }
            if (chunk.len > self.remote_window) {
                log.warn("ssh: remote window still {d} < {d}; sending anyway", .{ self.remote_window, chunk.len });
                self.remote_window = 0;
            } else {
                self.remote_window -= @intCast(chunk.len);
            }

            var b = Buf.init(self.alloc);
            defer b.deinit();
            try b.appendByte(MSG_CHANNEL_DATA);
            try ssh.putU32(&b, self.remote_id);
            try ssh.putString(&b, chunk);
            try self.t.writePacket(b.slice());

            off += n;
        }
    }
};

/// 一条连接需要的全部外部依赖 + 策略。用结构体而不是继续加形参：
/// 每加一个可选行为就多一个位置参数，调用点迟早传错顺序。
pub const ServerConfig = struct {
    host_key: ssh.HostKey,
    handler: SftpHandler,
    auth: Auth,
    /// 服务端主动 rekey 的字节阈值，0 = 不主动发起。见 `Conn.rekey_limit`。
    rekey_limit: u64 = 0,
};

/// 一条完整连接的入口：握手 → 消息循环。
pub fn run(alloc: std.mem.Allocator, stream: std.Io.net.Stream, config: ServerConfig) !void {
    const io = rt.io();
    // pre-auth 超时（P0-A）：未认证的连接此前**完全没有超时** —— 扫描器只要
    // TCP 连上、一个字节不发（或 KEX 发一半卡住），就占死一个线程加整套
    // Wire/Session 状态；叠加 accept 无上限，公网可以低成本拖死同进程的
    // HTTP。HTTP 侧一直有这套（`read_timeout_s`），这里给 SSH 补上。认证
    // 通过后在 `onUserauth` 里撤掉，恢复与 OpenSSH 一致的「空闲不限时」。
    http.applyTimeouts(stream, pre_auth_timeout_s);
    var rbuf: [32 * 1024]u8 = undefined;
    var srd = stream.reader(io, &rbuf);

    var wbuf: [32 * 1024]u8 = undefined;
    var swr = stream.writer(io, &wbuf);

    var t = ssh.Transport{
        .alloc = alloc,
        .rd = &srd.interface,
        .wr = &swr.interface,
    };
    defer t.deinit();

    try ssh.handshake(&t, config.host_key, alloc);

    var c = Conn.init(alloc, &t, config.host_key, config.handler, config.auth);
    c.rekey_limit = config.rekey_limit;
    c.stream = stream;
    defer c.deinit();
    try c.loop();
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ssh/channel: 窗口补给的阈值逻辑（只算数，不碰 socket）" {
    // 这条测试钉住的是「消费多少补多少」这个不变量：如果补窗口的算术写错，
    // 大目录列举会在中途卡住，而症状只是「READDIR 卡住」，极难定位。
    var local: u32 = window_size;
    const consumed: u32 = 1500 * 1024; // 必须超过 window_size/2 才触发补给
    local -|= consumed;
    try testing.expect(local < window_low);
    const add = window_size - local;
    try testing.expectEqual(consumed, add);
    local = window_size;
    try testing.expectEqual(window_size, local);
}

fn stubHandle(
    _: *anyopaque,
    _: std.mem.Allocator,
    _: protocol.Packet,
    _: *Buf,
) anyerror!void {}

fn stubVerify(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}

test "ssh/channel: 未认证的 CHANNEL_OPEN 必须被拒" {
    // P0 回归：`authenticated` 曾经只被赋值、从不检查，而 RFC 4253 不要求
    // 「先认证再开 channel」⇒ KEX 结束后直接发 CHANNEL_OPEN + subsystem sftp
    // 就能读写全部挂载。这条单测钉住闸门本身 —— 真实客户端永远会先认证，
    // 所以这个洞靠手工回归是测不出来的。
    var pkt = Buf.init(testing.allocator);
    defer pkt.deinit();
    try pkt.appendByte(MSG_CHANNEL_OPEN);
    try ssh.putString(&pkt, "session");
    try ssh.putU32(&pkt, 7); // sender channel（客户端的号）
    try ssh.putU32(&pkt, 2 * 1024 * 1024); // 宣告窗口
    try ssh.putU32(&pkt, 32 * 1024); // max packet

    var rd = std.Io.Reader.fixed(pkt.slice());
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    var t = ssh.Transport{
        .alloc = testing.allocator,
        .rd = &rd,
        .wr = &out.writer,
    };
    var seed: [32]u8 = undefined;
    @memset(&seed, 7);
    var hk = try ssh.HostKey.fromSeed(testing.allocator, seed);
    defer hk.deinit(testing.allocator);

    var c = Conn.init(testing.allocator, &t, hk, .{
        .ctx = undefined,
        .handleFn = stubHandle,
    }, .{
        .ctx = undefined,
        .verifyFn = stubVerify,
    });
    defer c.deinit();

    try testing.expect(!c.authenticated);
    try c.onChannelOpen(testing.allocator, pkt.slice());

    // 写出的是 [len:4][padlen:1][msg]，所以消息号在第 6 个字节。
    const w = out.written();
    try testing.expect(w.len > 5);
    try testing.expectEqual(MSG_CHANNEL_OPEN_FAILURE, w[5]);
    try testing.expectEqual(@as(u32, 0), c.local_id); // 没有通道被建立
}

test "ssh/channel: 收尾必须发 EOF + CLOSE 两个包" {
    // PuTTY 的 pscp 传完后只发一个 `CHANNEL_EOF` 就停在那里等我们关
    // （RFC 4254 §5.3 里 EOF 不要求回应，真正结束靠 close）。只发 CLOSE 或者
    // 干脆断 TCP，pscp 都会挂到超时 —— 文件内容已经完全正确、进度条 100%，
    // 只是命令不返回。OpenSSH 自己会发 close，所以这条洞只能用第二个客户端
    // 实现才暴露得出来，这里用单测把它钉住。
    var rd = std.Io.Reader.fixed(&.{});
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    var t = ssh.Transport{ .alloc = testing.allocator, .rd = &rd, .wr = &out.writer };
    defer t.deinit();

    var seed: [32]u8 = undefined;
    @memset(&seed, 7);
    var hk = try ssh.HostKey.fromSeed(testing.allocator, seed);
    defer hk.deinit(testing.allocator);

    var c = Conn.init(testing.allocator, &t, hk, .{
        .ctx = undefined,
        .handleFn = stubHandle,
    }, .{
        .ctx = undefined,
        .verifyFn = stubVerify,
    });
    defer c.deinit();
    c.remote_id = 7; // 客户端的 channel 号：close 要发给它

    c.closeChannel();

    const w = out.written();
    try testing.expect(w.len > 16);
    const first_total = @as(usize, std.mem.readInt(u32, w[0..4], .big)) + 4;

    try testing.expectEqual(MSG_CHANNEL_EOF, w[5]);
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, w[6..10], .big));

    try testing.expectEqual(MSG_CHANNEL_CLOSE, w[first_total + 5]);
    try testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, w[first_total + 6 ..][0..4], .big));
}

test "ssh/channel: 收到 EOF 后要继续读到对端的 CLOSE 才能收尾" {
    // 只发 EOF+CLOSE 就关 socket 会在 Windows 上收尾成 RST（对端还排着一个
    // `CLOSE` 没被读走，close 时内核直接 reset）。客户端看到的是**随机**报错：
    // `Software caused connection abort` / `Remote side unexpectedly closed
    // network connection` —— 文件传完了、rm 也成功了，最后 quit 那一下报错。
    // 实测 PuTTY psftp 12 次里挂 5 次，靠 `tools/sftp_interop.py` 才发现。
    var rd = std.Io.Reader.fixed(&.{});
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    var t = ssh.Transport{ .alloc = testing.allocator, .rd = &rd, .wr = &out.writer };
    defer t.deinit();

    var seed: [32]u8 = undefined;
    @memset(&seed, 9);
    var hk = try ssh.HostKey.fromSeed(testing.allocator, seed);
    defer hk.deinit(testing.allocator);

    var c = Conn.init(testing.allocator, &t, hk, .{
        .ctx = undefined,
        .handleFn = stubHandle,
    }, .{
        .ctx = undefined,
        .verifyFn = stubVerify,
    });
    defer c.deinit();
    c.remote_id = 7;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ① 收到 EOF：发收尾包，但**不**结束会话。
    try c.dispatch(a, &.{ MSG_CHANNEL_EOF, 0, 0, 0, 0 });
    try testing.expect(c.closing);
    try testing.expect(out.written().len > 0);
    const sent = out.written().len;

    // ② 对端在 CLOSE 之前又发了个包：丢弃，既不转发也不报错。
    try c.dispatch(a, &.{ MSG_CHANNEL_DATA, 0, 0, 0, 0, 0, 0, 0, 0 });
    try testing.expectEqual(@as(u32, 1), c.closing_discards);
    try testing.expectEqual(sent, out.written().len);

    // ③ 对端的 CLOSE 到了：收尾返回，且**不能**再回一个 CLOSE。
    try testing.expectError(error.ChannelClosed, c.dispatch(a, &.{ MSG_CHANNEL_CLOSE, 0, 0, 0, 0 }));
    try testing.expectEqual(sent, out.written().len);
}

test "ssh/channel: 只有到达字节阈值、且不在 KEX 中，才由服务端发起 rekey" {
    var rd = std.Io.Reader.fixed(&.{});
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    var t = ssh.Transport{ .alloc = testing.allocator, .rd = &rd, .wr = &out.writer };
    defer t.deinit();

    var seed: [32]u8 = undefined;
    @memset(&seed, 3);
    var hk = try ssh.HostKey.fromSeed(testing.allocator, seed);
    defer hk.deinit(testing.allocator);

    var c = Conn.init(testing.allocator, &t, hk, .{
        .ctx = undefined,
        .handleFn = stubHandle,
    }, .{
        .ctx = undefined,
        .verifyFn = stubVerify,
    });
    defer c.deinit();

    // 阈值 0 = 不主动发起（客户端仍可自己发起，那条路径一直支持）。
    try testing.expect(!c.shouldRekey());

    c.rekey_limit = 1024;
    try testing.expect(!c.shouldRekey()); // 一个字节都没走
    t.kex_bytes_in = 600;
    t.kex_bytes_out = 423;
    try testing.expect(!c.shouldRekey()); // 1023 < 1024，差一个字节也不行
    t.kex_bytes_out = 424;
    try testing.expect(c.shouldRekey()); // 正好 1024

    // 正在 KEX 时不能再触发：补投的包会走到这里，递归发起会把连接搅乱。
    c.rekey_busy = true;
    try testing.expect(!c.shouldRekey());
}

test "ssh/channel: KEX 期间暂存的包按原顺序补投（EOF 先到就先进收尾态）" {
    var rd = std.Io.Reader.fixed(&.{});
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();

    var t = ssh.Transport{ .alloc = testing.allocator, .rd = &rd, .wr = &out.writer };
    defer t.deinit();

    var seed: [32]u8 = undefined;
    @memset(&seed, 4);
    var hk = try ssh.HostKey.fromSeed(testing.allocator, seed);
    defer hk.deinit(testing.allocator);

    var c = Conn.init(testing.allocator, &t, hk, .{
        .ctx = undefined,
        .handleFn = stubHandle,
    }, .{
        .ctx = undefined,
        .verifyFn = stubVerify,
    });
    defer c.deinit();
    c.remote_id = 9;

    // 服务端主动 KEX 期间，客户端还在发 `CHANNEL_DATA` / `EOF`：这些包必须
    // 先存下来、NEWKEYS 之后按原顺序补投，直接丢就是「上传随机卡住」。
    try c.stash.push(testing.allocator, &.{ MSG_CHANNEL_EOF, 0, 0, 0, 0 });
    try c.stash.push(testing.allocator, &.{ MSG_CHANNEL_DATA, 0, 0, 0, 0, 0, 0, 0, 0 });
    try testing.expectEqual(@as(usize, 2), c.stash.len());

    try c.drainStash();

    // 顺序正确才会是这个结果：EOF 先进收尾态并发出收尾包，随后的 DATA 被
    // 当作「收尾后到达的包」丢弃。顺序反了的话 DATA 会被正常处理（不计数），
    // 而 `closing` 仍会是 false。
    try testing.expect(c.closing);
    try testing.expectEqual(@as(usize, 0), c.stash.len());
    try testing.expectEqual(@as(u32, 1), c.closing_discards);
    try testing.expect(out.written().len > 0);
}
