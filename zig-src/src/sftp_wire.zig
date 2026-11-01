//! SFTP 的生产接线：把 `api.App` / `client.zig` 适配成 `handler` 的两个窄接口，
//! 并提供一个**仅供调试**的裸 TCP 监听。
//!
//! ## 两个端点
//!
//! * `serveSsh`（正式）：SSH-2 传输层（`sftp/ssh.zig`）+ 单 channel
//!   （`sftp/channel.zig`）+ SFTP 分发（`sftp/handler.zig`）。认证已接
//!   `sshVerify`，可以绑非 loopback。
//! * `servePlain`（调试）：**没有 SSH、没有认证**，客户端直接说 SFTP。
//!   它存在的唯一理由是能在不信任传输层的时候单独验证「协议 + 会话 +
//!   分发」在真实挂载上的行为，`tools/sftp_probe.py` 就是配它的客户端。
//!   传输层已经落地，这个端点只等一次清理（见 TODO）。
//!
//! ## 裸监听的安全边界（必须看清楚）
//!
//! 裸 SFTP **没有认证**：谁能连上端口，谁就是管理员。因此：
//!
//!   * 只绑 `127.0.0.1`，不绑 `0.0.0.0` —— 局域网也连不上；
//!   * 必须显式 `--sftp-plain <port>` 才启动，默认完全不监听；
//!   * 日志里每次启动都打一行警告，避免有人把它当成正式功能。
//!
//! 这三条是硬约束，不是建议。SSH 层落地后这个监听应当直接删掉。

const std = @import("std");
const api = @import("api.zig");
const model = @import("model.zig");
const client_mod = @import("client.zig");
const cookiejar = @import("cookiejar.zig");
const rt = @import("rt.zig");
const log = @import("log.zig");
const sftp = @import("sftp.zig");
const handler = sftp.handler;
const protocol = sftp.protocol;
const session = sftp.session;
const Buf = @import("util/buf.zig").Buf;

// ---------------------------------------------------------------------------
// Resolver：路径 → (驱动, 驱动内相对路径)
// ---------------------------------------------------------------------------

pub fn resolverFor(app: *api.App) handler.Resolver {
    return .{
        .ctx = app,
        .resolveFn = resolveFn,
        .listRootFn = listRootFn,
    };
}

fn resolveFn(ctx: *anyopaque, vpath: []const u8) ?handler.Target {
    const app: *api.App = @ptrCast(@alignCast(ctx));
    const r = app.resolve(vpath) orelse return null;
    return .{
        .driver = r.mount.driver,
        .rel = r.rel,
        .mount_path = r.mount.mount_path,
    };
}

/// 列出虚拟根的一级名字（挂载点的第一段，去重）。
///
/// 嵌套挂载（`/a/b`）在根下只暴露 `a`，而 `a` 本身不是挂载点 —— 客户端
/// `OPENDIR /a` 会拿到 `NO_SUCH_FILE`。这是已知限制：真实配置里挂载点基本
/// 都是一级（`/quark`、`/189`），为多层嵌套维护一棵合成目录树不值得。
fn listRootFn(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![][]u8 {
    const app: *api.App = @ptrCast(@alignCast(ctx));

    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |n| alloc.free(n);
        out.deinit(alloc);
    }

    for (app.mountsSnapshot()) |m| {
        const mp = std.mem.trim(u8, m.mount_path, "/");
        if (mp.len == 0) continue; // 根挂载本身不产生名字
        const first = if (std.mem.indexOfScalar(u8, mp, '/')) |i| mp[0..i] else mp;

        var dup = false;
        for (out.items) |e| {
            if (std.mem.eql(u8, e, first)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        try out.append(alloc, try alloc.dupe(u8, first));
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Fetcher：link → 一段字节
// ---------------------------------------------------------------------------

/// 一条 SFTP 连接的网络侧状态。
///
/// ⚠ 必须**就地**初始化（`initInPlace`），不能用「返回值」构造：`Client` 持有
/// `*Jar` 指针，返回结构体时地址会变，指针立刻悬垂。这是 Zig 里自引用结构体
/// 的经典坑，注释写在这里是为了下次不要重犯。
pub const Wire = struct {
    app: *api.App,
    alloc: std.mem.Allocator,
    jar: cookiejar.Jar,
    cli: client_mod.Client,

    pub fn initInPlace(self: *Wire, app: *api.App, alloc: std.mem.Allocator) void {
        self.app = app;
        self.alloc = alloc;
        self.jar = cookiejar.Jar.init(alloc);
        self.cli = client_mod.Client.init(alloc, .{}, &self.jar);
    }

    pub fn deinit(self: *Wire) void {
        self.cli.deinit();
        self.jar.deinit();
    }

    pub fn fetcher(self: *Wire) handler.Fetcher {
        return .{ .ctx = self, .fetchFn = fetchFn };
    }
};

fn fetchFn(
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    link: model.Link,
    offset: u64,
    len: u32,
) anyerror![]u8 {
    const self: *Wire = @ptrCast(@alignCast(ctx));
    if (len == 0) return alloc.alloc(u8, 0);
    if (link.local_path) |p| return readLocal(alloc, p, offset, len);
    if (link.url.len == 0) return error.NotSupported;
    return fetchHttp(self, alloc, link, offset, len);
}

/// 本地文件：`readPositionalAll` 是 0.17 里 `pread` 的写法（0.17 删掉了
/// `File.pread`），它自己会循环到读满或 EOF。
fn readLocal(alloc: std.mem.Allocator, path: []const u8, offset: u64, len: u32) ![]u8 {
    const io = rt.io();
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);

    const buf = try alloc.alloc(u8, len);
    errdefer alloc.free(buf);

    var got: usize = 0;
    while (got < buf.len) {
        const n = try std.Io.File.readPositionalAll(f, io, buf[got..], offset + got);
        if (n == 0) break; // EOF
        got += n;
    }
    if (got == 0) {
        alloc.free(buf);
        return error.EndOfStream;
    }
    if (got == buf.len) return buf;
    // 短读（文件比声明的小）：缩容，否则调用方 free 时会因长度不匹配而崩。
    return try alloc.realloc(buf, got);
}

fn fetchHttp(self: *Wire, alloc: std.mem.Allocator, link: model.Link, offset: u64, len: u32) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    // 驱动给的头（Referer / UA / 鉴权）必须原样带上，否则 CDN 会拒。
    var hdrs: std.ArrayListUnmanaged(model.Header) = .empty;
    for (link.header) |h| try hdrs.append(a, h);

    const end = offset + @as(u64, len) - 1;
    const range = try std.fmt.allocPrint(a, "bytes={d}-{d}", .{ offset, end });
    try hdrs.append(a, .{ .name = "Range", .value = range });

    const resp = try self.cli.send(a, .{ .url = link.url, .headers = hdrs.items });

    if (resp.status == 206) {
        // Partial Content：body 就是我们要的那一段。
        return alloc.dupe(u8, resp.body);
    }
    if (resp.status == 200) {
        // 上游忽略了 Range，body 是整份文件。只有它覆盖到目标区间时才能用。
        //
        // ⚠ 这时 `resp.body` 已经是整份文件了，大文件会先撑爆内存 —— 这是
        // 「上游不支持 Range」的固有代价，不是本函数能补救的。能做的只有：
        // 明确报错，让客户端知道「这个驱动不适合 SFTP 随机读」，而不是悄悄
        // 返回错位的数据。
        const start: usize = @intCast(offset);
        const stop = start + @as(usize, len);
        if (resp.body.len < stop) return error.NotSupported;
        return alloc.dupe(u8, resp.body[start..stop]);
    }
    log.debug("sftp: range fetch got HTTP {d} for {s}", .{ resp.status, link.url });
    return error.UpstreamError;
}

// ---------------------------------------------------------------------------
// 裸 TCP 监听（仅调试）
// ---------------------------------------------------------------------------

/// 在 `127.0.0.1:port` 上跑一个**无认证**的 SFTP 端点。见文件头的安全边界。
pub fn servePlain(app: *api.App, port: u16) !void {
    const io = rt.io();
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    log.warn("sftp(plain): listening on 127.0.0.1:{d} — NO AUTHENTICATION, debug only", .{port});

    while (true) {
        const stream = listener.accept(io) catch |e| switch (e) {
            error.ConnectionAborted => continue,
            error.SocketNotListening => return,
            else => {
                log.warn("sftp(plain): accept failed: {s}", .{@errorName(e)});
                continue;
            },
        };
        const t = std.Thread.spawn(.{}, connThread, .{ app, stream }) catch |e| {
            log.warn("sftp(plain): spawn failed: {s}", .{@errorName(e)});
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

fn connThread(app: *api.App, stream: std.Io.net.Stream) void {
    const gpa = rt.gpa();
    defer stream.close(rt.io());

    var wire: Wire = undefined;
    wire.initInPlace(app, gpa);
    defer wire.deinit();

    var sess = session.Session.init(gpa);
    defer sess.deinit();

    var ctx = handler.Context{
        .alloc = gpa,
        .resolver = resolverFor(app),
        .fetcher = wire.fetcher(),
        .temp_dir = app.mp_dir,
        .max_write_bytes = app.mp_max_bytes,
    };

    serveStream(&ctx, &sess, stream) catch |e| {
        if (e != error.ConnectionClosed and e != error.BrokenPipe) {
            log.debug("sftp(plain): connection ended: {s}", .{@errorName(e)});
        }
    };
}

/// 一条连接上的读写循环。抽成独立函数是为了将来 SSH 层能复用它 ——
/// 届时只需要把 `stream` 换成一个「已解密的字节流」。
fn serveStream(ctx: *handler.Context, sess: *session.Session, stream: std.Io.net.Stream) !void {
    const io = rt.io();
    const gpa = rt.gpa();

    var rbuf: [16 * 1024]u8 = undefined;
    var srd = stream.reader(io, &rbuf);
    const rd = &srd.interface;

    var wbuf: [16 * 1024]u8 = undefined;
    var swr = stream.writer(io, &wbuf);
    const wr = &swr.interface;

    // 累积缓冲：一个 TCP 分段可能只含半个包，也可能含好几个。
    var acc = Buf.init(gpa);
    defer acc.deinit();

    var chunk: [16 * 1024]u8 = undefined;

    while (true) {
        // 先把缓冲里能解的包全部处理掉，再去读 socket。
        while (true) {
            const maybe = protocol.parse(acc.slice()) catch |e| {
                log.debug("sftp(plain): bad packet: {s}", .{@errorName(e)});
                return e;
            };
            const pkt = maybe orelse break;

            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            var out = Buf.init(gpa);
            defer out.deinit();

            handler.dispatch(ctx, sess, arena.allocator(), pkt, &out) catch |e| {
                log.debug("sftp(plain): dispatch failed: {s}", .{@errorName(e)});
                return e;
            };
            if (out.len > 0) {
                try wr.writeAll(out.slice());
                try wr.flush();
            }

            // 消费掉这个包：把剩余字节前移。
            const rest = acc.len - pkt.consumed;
            std.mem.copyForwards(u8, acc.data[0..rest], acc.data[pkt.consumed..acc.len]);
            acc.len = rest;
        }

        // ⚠ 这里必须用 `readVec`（有多少拿多少），**不能**用 `readSliceShort`：
        // 后者的语义是「读满整个 buffer，除非 EOF」。传 16 KiB 的缓冲就意味
        // 着它会一直等到 16 KiB —— 而客户端发完一个 INIT 包（9 字节）就在等
        // 回复，双方当场死锁。这个 bug 在探针上表现为「连上了但 INIT 超时」。
        var iov = [_][]u8{&chunk};
        const n = rd.readVec(&iov) catch |e| switch (e) {
            error.EndOfStream => return error.ConnectionClosed,
            else => return error.ReadFailed,
        };
        if (n == 0) return error.ConnectionClosed;
        try acc.append(chunk[0..n]);
    }
}

// ---------------------------------------------------------------------------
// SSH 监听（传输层已验证；认证与 channel 待接）
// ---------------------------------------------------------------------------

/// 在 `address:port` 上跑 SSH-2 + SFTP。
///
/// `address` 必须是 **IP 字面量**（`0.0.0.0` / `::` / `127.0.0.1`）：
/// `std.Io.net.IpAddress.parse` 不做域名解析，写主机名会在启动时直接失败并
/// 说明原因，而不是静默绑错地址。
///
/// 认证（RFC 4252）已接真校验，所以可以绑非 loopback；但失败计数目前是
/// **全局**而非按 IP（`std.Io.net.Stream` 不暴露对端地址），任何人反复试错
/// 都能把管理员账户锁 5 分钟 —— 单管理员部署下可接受，见 TODO 第 1 条。
pub fn serveSsh(app: *api.App, address: []const u8, port: u16, host_key_path: []const u8) !void {
    const io = rt.io();
    const gpa = rt.gpa();

    var hk = try sftp.ssh.HostKey.loadOrCreate(gpa, host_key_path);
    defer hk.deinit(gpa);

    const addr = std.Io.net.IpAddress.parse(address, port) catch |e| {
        log.err("sftp(ssh): cannot parse listen address `{s}`: {s} (use an IP literal such as 0.0.0.0)", .{ address, @errorName(e) });
        return e;
    };
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    log.info("sftp(ssh): listening on {s}:{d} (host key: {s})", .{ address, port, host_key_path });

    while (true) {
        const stream = listener.accept(io) catch |e| switch (e) {
            error.ConnectionAborted => continue,
            error.SocketNotListening => return,
            else => {
                log.warn("sftp(ssh): accept failed: {s}", .{@errorName(e)});
                continue;
            },
        };
        const t = std.Thread.spawn(.{}, sshConnThread, .{ app, hk, stream }) catch |e| {
            log.warn("sftp(ssh): spawn failed: {s}", .{@errorName(e)});
            stream.close(io);
            continue;
        };
        t.detach();
    }
}

/// `channel.SftpHandler` 的上下文：一条连接一套 `Session` + `Context`。
const Bridge = struct {
    ctx: *handler.Context,
    sess: *session.Session,
};

fn bridgeHandle(
    c: *anyopaque,
    a: std.mem.Allocator,
    pkt: protocol.Packet,
    out: *Buf,
) anyerror!void {
    const b: *Bridge = @ptrCast(@alignCast(c));
    log.debug("sftp: pkt {s}", .{@tagName(pkt.packet_type)});
    return handler.dispatch(b.ctx, b.sess, a, pkt, out);
}

/// SSH 口令校验：与 HTTP 登录**完全同一套** —— `twoHashPwd(pw, admin_salt)`
/// 比对 `admin_hash`，并且共用同一份失败计数（换协议不能绕过限速）。
///
/// 用户名比对放在哈希之前，但**对外不区分**「用户名错」和「口令错」：两者都
/// 只回 `USERAUTH_FAILURE`，客户端看到的都是 "Permission denied"。
fn sshVerify(ctx: *anyopaque, a: std.mem.Allocator, user: []const u8, pw: []const u8) bool {
    const app: *api.App = @ptrCast(@alignCast(ctx));
    if (app.admin_hash.len == 0) return false; // 还没建管理员

    // 锁定期内直接拒绝，连哈希都不算（与 HTTP 登录的检查顺序一致）。
    // 必须记一条日志：否则用户输入正确口令也登不上，却没有任何线索。
    if (!api.authThrottleAllow()) {
        log.warn("ssh: auth refused — account locked after too many failed attempts", .{});
        return false;
    }

    if (!std.mem.eql(u8, user, app.admin_user)) {
        api.authThrottleFailure();
        return false;
    }
    const h = api.twoHashPwd(a, pw, app.admin_salt) catch {
        api.authThrottleFailure();
        return false;
    };
    // 与 HTTP 登录一致：用**恒定时间**比较。明文口令已经在客户端侧走完，
    // 这里比的是哈希，泄漏面比明文小得多，但没有理由和 HTTP 路径用两套。
    if (!api.ctEqual(h, app.admin_hash)) {
        api.authThrottleFailure();
        return false;
    }
    api.authThrottleSuccess();
    return true;
}

fn sshConnThread(app: *api.App, hk: sftp.ssh.HostKey, stream: std.Io.net.Stream) void {
    const gpa = rt.gpa();
    defer stream.close(rt.io());

    // 与裸 SFTP 端点完全相同的装配：一个 Wire（Client + Jar）、一个 Session、
    // 一个 Context。区别只在字节从哪儿来（加密 channel vs 裸 TCP）。
    var wire: Wire = undefined;
    wire.initInPlace(app, gpa);
    defer wire.deinit();

    var sess = session.Session.init(gpa);
    defer sess.deinit();

    var ctx = handler.Context{
        .alloc = gpa,
        .resolver = resolverFor(app),
        .fetcher = wire.fetcher(),
        .temp_dir = app.mp_dir,
        .max_write_bytes = app.mp_max_bytes,
    };
    var bridge = Bridge{ .ctx = &ctx, .sess = &sess };

    const h = sftp.channel.SftpHandler{ .ctx = &bridge, .handleFn = bridgeHandle };
    const auth = sftp.channel.Auth{ .ctx = app, .verifyFn = sshVerify };

    sftp.channel.run(gpa, stream, hk, h, auth) catch |e| {
        if (e != error.ConnectionClosed and e != error.BrokenPipe) {
            log.debug("sftp(ssh): connection ended: {s}", .{@errorName(e)});
        }
    };
}
