//! SFTP 的生产接线：把 `api.App` / `client.zig` 适配成 `handler` 的两个窄接口，
//! 并把 SSH-2 传输层、单 channel 与 SFTP 分发串起来。
//!
//! ## 唯一的端点
//!
//! `serveSsh`：SSH-2 传输层（`sftp/ssh.zig`）+ 单 channel（`sftp/channel.zig`）
//! + SFTP 分发（`sftp/handler.zig`）。认证走 `sshVerify`（管理员口令，与 HTTP
//! 登录共用同一份失败计数），所以可以绑非 loopback。
//!
//! ## 曾经的 `--sftp-plain`（2026-11-01 已删除）
//!
//! 那是一个**无认证**的裸 SFTP 监听，只绑 `127.0.0.1`、只存在于 CLI，专门用来
//! 在不信任传输层的时候单独验证「协议 + 会话 + 分发」。SSH 层落地、互通回归
//! （`tools/sftp_interop.py` + `tools/sftp_ssh_e2e.py`）跑通之后它就没有存在
//! 理由了：**无认证的端点不该长期留在二进制里**，哪怕默认不监听。
//!
//! 它连带删掉的还有 `connThread` / `serveStream`（那条路径专用的裸字节循环）
//! 和 `tools/sftp_probe.py`（只配它用的零依赖探针）。handler 的分发逻辑本来
//! 就有纯单测（内存驱动 + 内存 fetcher，不起服务、不联网），探针带来的覆盖是
//! 重复的。

const std = @import("std");
const api = @import("api.zig");
const model = @import("model.zig");
const client_mod = @import("client.zig");
const cookiejar = @import("cookiejar.zig");
const rt = @import("rt.zig");
const log = @import("log.zig");
const peeraddr = @import("util/peeraddr.zig");
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
        // 响应体上限（P1）：SFTP 的 Range 拉取一次最多一个读窗口（1 MiB），
        // 4 MiB 给足余量。不设的话，上游忽略 Range 回 200 时整份文件会先
        // 进内存 —— 以前只是注释里承认「大文件会先撜爆内存」，在光猫上就是
        // 确定性 OOM。超限以 `error.ResponseTooLarge` 明确失败，客户端看到
        // FAILURE，而不是把进程带走。
        self.cli = client_mod.Client.init(alloc, .{
            .max_response_bytes = 4 * 1024 * 1024,
        }, &self.jar);
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
// SSH 监听（传输层 + 认证 + channel）
// ---------------------------------------------------------------------------

/// 在 `address:port` 上跑 SSH-2 + SFTP。
///
/// `address` 必须是 **IP 字面量**（`0.0.0.0` / `::` / `127.0.0.1`）：
/// `std.Io.net.IpAddress.parse` 不做域名解析，写主机名会在启动时直接失败并
/// 说明原因，而不是静默绑错地址。
///
/// `rekey_limit` = 服务端主动换密钥的字节阈值，0 = 不主动发起（客户端仍可
/// 自己发起，那条路径一直支持）。
pub fn serveSsh(
    app: *api.App,
    address: []const u8,
    port: u16,
    host_key_path: []const u8,
    rekey_limit: u64,
) !void {
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

    // 连接闸门（P0-A，与 http.zig 的 `conn_sem` 同款）：满 64 条并发就停在
    // accept 上做背压，而不是无限 spawn —— 小内存设备上后一种会被并发连接
    // 打爆。以前 accept 无上限 × 零超时，未认证扫描器只要 TCP 连上就能各占
    // 一个线程加全套连接状态，公网可低成本拖死同进程的 HTTP。pre-auth 超时
    // （`channel.run` 里设置）保证占着坑的未认证连接最多活 30 秒，闸门不会
    // 被拖死。
    var conn_sem: std.Io.Semaphore = .{};
    conn_sem.permits = max_ssh_connections;

    log.info("sftp(ssh): listening on {s}:{d} (host key: {s})", .{ address, port, host_key_path });
    // 明确打出策略：rekey 阈值配错了（比如 `sftp.rekey_mb` 写成字符串）时，
    // 症状是「服务端从不换密钥」，而这一点在日志里必须一眼可见。
    if (rekey_limit > 0) {
        log.info("sftp(ssh): will initiate rekey after {d} bytes", .{rekey_limit});
    } else {
        log.info("sftp(ssh): server-initiated rekey disabled (clients may still initiate)", .{});
    }

    while (true) {
        const stream = listener.accept(io) catch |e| switch (e) {
            error.ConnectionAborted => continue,
            error.SocketNotListening => return,
            else => {
                log.warn("sftp(ssh): accept failed: {s}", .{@errorName(e)});
                continue;
            },
        };
        // 先占坑再 spawn：spawn 失败要把坑还回去，否则信号量被白吃一个。
        conn_sem.waitUncancelable(io);
        const t = std.Thread.spawn(.{}, sshConnThread, .{ app, hk, stream, rekey_limit, &conn_sem }) catch |e| {
            log.warn("sftp(ssh): spawn failed: {s}", .{@errorName(e)});
            stream.close(io);
            conn_sem.post(io);
            continue;
        };
        t.detach();
    }
}

/// SSH 并发连接上限。HTTP 侧的 `max_connections` 默认 0（不限、靠配置开启）；
/// SSH 侧直接给硬默认：每条连接一套线程 + Wire/Session 状态，而 SSH 端点
/// 面对的是公网扫描器，光猫的内存面前这个数不能再大。pre-auth 超时保证
/// 占坑的未认证连接 30 秒内必定吐出来，正常用户几乎不可能同时占满 64 条。
const max_ssh_connections: u32 = 64;

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
///
/// `peer` 是对端 IP（不带端口）。失败计数按它分桶 —— 全局计数意味着任何人都
/// 能靠 5 次错误把管理员锁 5 分钟。拿不到 IP 时传空串，退化回全局桶。
fn sshVerify(ctx: *anyopaque, a: std.mem.Allocator, user: []const u8, pw: []const u8, peer: []const u8) bool {
    const app: *api.App = @ptrCast(@alignCast(ctx));
    if (app.admin_hash.len == 0) return false; // 还没建管理员

    // 锁定期内直接拒绝，连哈希都不算（与 HTTP 登录的检查顺序一致）。
    // 锁定进入的那一下已经在 `api.recordFailure` 里告警过（带来源），
    // 这里只留 debug —— 逐次拒绝打日志，等于给扫描器一个刷日志的放大面。
    if (!api.authThrottleAllow(peer)) {
        log.debug("ssh: auth refused — account locked (from {s})", .{if (peer.len == 0) "unknown" else peer});
        return false;
    }

    if (!std.mem.eql(u8, user, app.admin_user)) {
        api.authThrottleFailure(peer);
        return false;
    }
    const h = api.twoHashPwd(a, pw, app.admin_salt) catch {
        api.authThrottleFailure(peer);
        return false;
    };
    // 与 HTTP 登录一致：用**恒定时间**比较。明文口令已经在客户端侧走完，
    // 这里比的是哈希，泄漏面比明文小得多，但没有理由和 HTTP 路径用两套。
    if (!api.ctEqual(h, app.admin_hash)) {
        api.authThrottleFailure(peer);
        return false;
    }
    api.authThrottleSuccess(peer);
    return true;
}

fn sshConnThread(app: *api.App, hk: sftp.ssh.HostKey, stream: std.Io.net.Stream, rekey_limit: u64, conn_sem: *std.Io.Semaphore) void {
    const gpa = rt.gpa();
    defer stream.close(rt.io());
    // 坑位归还：连接线程退出时释放一个并发名额（见 serveSsh 的闸门注释）。
    defer conn_sem.post(rt.io());

    // 对端 IP 每条连接查一次。缓冲区放在这里（连接级），传输层与认证都只在
    // 这条连接的生命周期内使用它。
    var peer_buf: [peeraddr.max_len]u8 = undefined;
    const peer = peeraddr.ipString(&peer_buf, stream) orelse "";

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
    const auth = sftp.channel.Auth{ .ctx = app, .verifyFn = sshVerify, .peer = peer };

    sftp.channel.run(gpa, stream, .{
        .host_key = hk,
        .handler = h,
        .auth = auth,
        .rekey_limit = rekey_limit,
    }) catch |e| {
        if (e != error.ConnectionClosed and e != error.BrokenPipe) {
            log.debug("sftp(ssh): connection ended: {s}", .{@errorName(e)});
        }
    };
}
