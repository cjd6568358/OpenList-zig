//! 分片上传（/api/fs/multipart/*）—— 自 api.zig 整体搬出（AUDIT-2026-11-27
//! 路线图 #15-M1）。搬出为纯移动：状态机、五个 handler、Fake 驱动与全部
//! 协议/回归测试逐行保持不变；api.zig 只留 App 的会话表字段与路由分发行。
//! App 与 Mount 以别名引用（api↔multipart 双向 import 与既有 api↔webdav
//! 同形，Zig 文件级依赖允许）。

const std = @import("std");
const http = @import("http.zig");
const model = @import("model.zig");
const driver = @import("driver.zig");
const json = @import("util/json.zig");
const rand = @import("util/random.zig");
const urlmod = @import("util/url.zig");
const peeraddr = @import("util/peeraddr.zig");
const config = @import("config.zig");
const log = @import("log.zig");
const client_mod = @import("client.zig");
const cookiejar = @import("cookiejar.zig");
const frontend_mod = @import("frontend.zig");
const webdav = @import("webdav.zig");
const archive = @import("archive.zig");
const hashmod = @import("util/hash.zig");
const Buf = @import("util/buf.zig").Buf;
const List = @import("util/buf.zig").List;
const rt = @import("rt.zig");
const api = @import("api.zig");
const router_mod = @import("router.zig");
const auth_mod = @import("auth.zig");

// api.zig 本地声明的别名（对应处已在 api.zig 加 pub，零行为变化）：
// 类型（App/Mount/ArchiveFileSource/Header）与零散业务/测试辅助。
const App = api.App;
const Mount = api.Mount;
const Header = api.Header;
const ArchiveFileSource = api.ArchiveFileSource;
const noRoute = router_mod.noRoute;
const mimeFor = api.mimeFor;
const mapDriverError = api.mapDriverError;
const notifyObjsUpdateAfterWrite = api.notifyObjsUpdateAfterWrite;
const doRequestWith = api.doRequestWith;
const doRequestJson = api.doRequestJson;
const expectApiCode = api.expectApiCode;
const mintTestToken = auth_mod.mintTestToken;
const routingApp = api.routingApp;
const ROUTING_SHELL = api.ROUTING_SHELL;
const testing = std.testing;

// ---------------------------------------------------------------------------
// 分片上传（/api/fs/multipart/*，2026-10-30 —— 设计与前端行为见 STATUS §57、
// §58）。协议对齐 Go `server/handles/multipart.go` +
// `internal/multipart/session.go` 的响应形状（SessionSnapshot 逐字段）。
//
// 两条路径，按驱动能力选择：
//   * **直传**（驱动有 mp_* 槽位，目前 = 189pc）：分片字节经 API 层直接推给
//     上游的 initMultiUpload 会话，本地**零落盘** —— 1 GB 文件也只占
//     `分片 × 并发` 的内存（189 本来就按 10 MiB 分片）。
//   * **回退**（其他驱动）：分片 pwrite 进 temp_dir 下的一个**稀疏文件**，
//     complete 时用 `ArchiveFileSource` 同款的随机读 Source 走一次 `driver.put`。
//     磁盘占用 = 文件大小 ⇒ 受 `zig.max_upload_mb` 约束（`App.mp_max_bytes`，
//     init 阶段就回 413），与 `fs/put` 是同一笔账。
//
// MD5 累计（直传路径）必须**按片序**喂 Md5Stream —— 前端 3 个并发 worker 的
// 到达顺序不定，早到的片挂在 `pending`（App 内存，上限 ≈ 并发数 × 分片），
// 攒齐前驱后按序消化。
// ---------------------------------------------------------------------------

const MpState = enum {
    receiving,
    completed,
    failed,
    aborted,

    fn str(self: MpState) []const u8 {
        return switch (self) {
            .receiving => "receiving",
            .completed => "completed",
            // 上游的 failed_retriable 依赖「重发 chunk 0 重开一轮」的流水线
            // 语义，本实现没有流水线 —— 失败一律按 permanent 处理，前端
            // 重传 = 重新 init（received 清零）。
            .failed => "failed_permanent",
            .aborted => "aborted",
        };
    }
};

/// Go `multipart.WindowSlots = 8`；这里只影响稀疏 spool 文件的预写入上界，
/// 实际磁盘占用恒 = 文件大小，故不设槽位。
const mp_min_chunk: i64 = 1 << 20; // Go multipartMinChunkSize
/// 与 `public_setting_defaults` 的 `multipart_chunk_size`（MiB）保持一致，
/// 有单测钉住两边。
const mp_ceiling_chunk_mib: i64 = 10;
const mp_ttl_ms: i64 = 30 * 60 * 1000; // Go defaultSessionTTL
/// 连续失败到这个数就把会话打成 failed（否则前端会对同一个片 429 重试到
/// 它自己的 400 次上限，约 8 分钟）。
const mp_max_chunk_fails: u32 = 10;

const MpChunk = struct {
    idx: i64,
    bytes: []u8,
    md5_upper: []const u8,
};

pub const MpSession = struct {
    id: []u8,
    /// `(user)=admin|path|size|last_modified` —— Go 的 sessionKey 少了 hash
    /// 证明；这里用 Last-Modified（浏览器 File 对象的毫秒时间戳）顶上：
    /// 同路径同大小的**不同**文件 mtime 不同，不会错误续传。
    key: []u8,
    mount_path: []u8,
    rel: []u8,
    name: []u8,
    mime: []const u8 = "",
    size: i64,
    chunk_size: i64,
    total: i64,
    /// 创建会话时的驱动实例指针 —— 挂载重建（存储编辑）后驱动会被替换，
    /// 句柄随之失效，必须在每次分片/complete 时比对。
    driver_ptr: *anyopaque,
    direct: bool,

    mu: std.Io.Mutex = .init,
    state: MpState = .receiving,
    err_msg: []const u8 = "",
    received: []bool = &.{},
    received_bytes: u64 = 0,
    /// AUDIT-2026-11-27 #1：会话引用计数。创建后 = 1（表持有的基准引用）；
    /// `mpAcquire` +1，`mpRelease` -1，归零才真正销毁 —— 修复「chunk/complete
    /// 在 `mp_mu` 解锁后拿着裸指针 touch，而 abort/sweep/init-stale 同一窗口
    /// 锁外 free」的 UAF（原生前端取消上传 = 3 worker 在飞 + abort 即触发）。
    /// 创建即为 1：init 失败路径（未入表）直接 `mpFreeSession` 不走计数。
    refs: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    /// 原子化：sweep 只持 mp_mu 读它，而写方（touch）从不在 s.mu/`mp_mu` 内——
    /// 旧代码「锁外写 vs 锁内读」属数据竞争。毫秒精度足够 TTL 判定。
    last_active: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    completing: bool = false,
    storage_pct: f64 = 0,

    // 直传路径
    drv_session: ?*anyopaque = null,
    md5: hashmod.Md5Stream = .{},
    /// 下一个要喂进 Md5Stream 的片号（0-based）。
    next_md5_idx: i64 = 0,
    slice_md5s: List([]const u8),
    pending: List(MpChunk),
    fail_count: u32 = 0,

    // 回退路径
    spool_path: []const u8 = "",

    fn chunkLen(self: *const MpSession, idx: i64) i64 {
        if (idx < 0 or idx >= self.total) return 0;
        if (idx == self.total - 1) return self.size - idx * self.chunk_size;
        return self.chunk_size;
    }

    fn touch(self: *MpSession) void {
        self.last_active.store(rt.nowMillis(), .release);
    }

    /// Go `SessionSnapshot.Received`：把 received 位图合并成 [[from,to],…]
    /// 的闭区间列表（空会话返回 `[]`，不是 null —— Go 显式初始化为空切片）。
    fn writeReceived(self: *const MpSession, b: *Buf) !void {
        try b.append("[");
        var i: i64 = 0;
        var first = true;
        while (i < self.total) {
            if (!self.received[@intCast(i)]) {
                i += 1;
                continue;
            }
            const from = i;
            while (i + 1 < self.total and self.received[@intCast(i + 1)]) i += 1;
            if (!first) try b.append(",");
            first = false;
            try b.print("[{d},{d}]", .{ from, i });
            i += 1;
        }
        try b.append("]");
    }

    fn frontier(self: *const MpSession) i64 {
        var i: i64 = 0;
        while (i < self.total and self.received[@intCast(i)]) i += 1;
        return i;
    }

    fn writeSnapshot(self: *MpSession, b: *Buf, a: std.mem.Allocator) !void {
        self.mu.lockUncancelable(rt.io());
        defer self.mu.unlock(rt.io());
        try b.append("{\"upload_id\":");
        try json.writeString(b, self.id);
        try b.print(",\"state\":\"{s}\",\"attempt\":0,\"path\":", .{self.state.str()});
        // path = mount_path + rel（mount_path 以 / 开头；rel 也以 / 开头）。
        // json.writeString 自带引号与转义 —— 别再手工包一层引号。
        const full_path = std.fmt.allocPrint(
            a,
            "/{s}{s}",
            .{ std.mem.trim(u8, self.mount_path, "/"), self.rel },
        ) catch self.rel;
        try json.writeString(b, full_path);
        try b.print(",\"size\":{d},\"chunk_size\":{d},\"total_chunks\":{d},\"received\":", .{ self.size, self.chunk_size, self.total });
        try self.writeReceived(b);
        try b.print(",\"received_bytes\":{d},\"frontier\":{d},\"storage_progress\":{d},\"error\":", .{
            self.received_bytes,
            self.frontier(),
            self.storage_pct,
        });
        try json.writeString(b, self.err_msg);
        try b.append("}");
    }
};

fn mpFreeSession(app: *App, s: *MpSession) void {
    const g = app.alloc;
    if (s.drv_session) |h| {
        // 只在「没走过 mpCommit」时才需要驱动释放；commit 内部已自毁并把
        // 槽位置空。abort/过期路径走这里。
        // ⚠ AUDIT-2026-11-27 #1：必须找**创建会话的那一个驱动实例**
        // （`s.driver_ptr`）—— 旧代码按 mount_path 找到的是「当前」驱动，
        // 存储被重载后那是另一个实例，把旧句柄喂给新驱动的 mpAbort 属于
        // 跨实例操作（找不到就放弃 abort，上游孤儿会话由上游自己过期回收）。
        for (app.mountsSnapshot()) |*m| {
            if (m.driver.ptr == s.driver_ptr) {
                var ctx = driver.Ctx{ .alloc = g, .tag = s.mount_path };
                m.driver.mpAbort(&ctx, h);
                break;
            }
        }
    }
    g.free(s.id);
    g.free(s.key);
    g.free(s.mount_path);
    g.free(s.rel);
    g.free(s.name);
    if (s.mime.len > 0) g.free(s.mime);
    if (s.received.len > 0) g.free(s.received);
    for (s.slice_md5s.slice()) |m| g.free(m);
    s.slice_md5s.deinit();
    for (s.pending.slice()) |pc| {
        g.free(pc.bytes);
        g.free(pc.md5_upper);
    }
    s.pending.deinit();
    if (s.err_msg.len > 0) g.free(s.err_msg);
    if (s.spool_path.len > 0) g.free(s.spool_path);
    g.destroy(s);
}

fn mpSetErr(app: *App, s: *MpSession, msg: []const u8) void {
    if (s.err_msg.len > 0) app.alloc.free(s.err_msg);
    s.err_msg = app.alloc.dupe(u8, msg) catch "";
}

// ---------------------------------------------------------------------------
// AUDIT-2026-11-27 #1：会话生命周期协议（引用计数）。
//
//   * 入表时 refs = 1（表的基准引用）；
//   * `mpAcquire`：持 mp_mu get 并 +1，返回后调用方拿的是**受保护的**指针，
//     销毁方随时摘表也不会把脚下的内存抽走；
//   * `mpRelease`：-1，归零者销毁。**归零制后 release 之后绝不能再碰 s**；
//   * 销毁路径（abort / sweep / init-stale）在把自己的引用 +1 之后，摘表
//     并连减两刀（表基准 + 自己那刀）—— 在途 chunk/complete 的引用不归零，
//     会话就活着，最后一刀才真正 free。
// ---------------------------------------------------------------------------

fn mpAcquire(app: *App, id: []const u8) ?*MpSession {
    const io = rt.io();
    app.mp_mu.lockUncancelable(io);
    defer app.mp_mu.unlock(io);
    const s = app.mp_sessions.get(id) orelse return null;
    _ = s.refs.fetchAdd(1, .acq_rel);
    return s;
}

fn mpRelease(app: *App, s: *MpSession) void {
    if (s.refs.fetchSub(1, .acq_rel) == 1) mpFreeSession(app, s);
}

/// 会话所属挂载还在不在、驱动实例还是不是创建时的那一个。此前同一段
/// 「按 mount_path 找 + 比对 driver_ptr」在 free/chunk/complete 抄了三份。
fn mpMountFor(app: *App, s: *MpSession) ?*Mount {
    for (app.mountsSnapshot()) |*m| {
        if (!std.mem.eql(u8, m.mount_path, s.mount_path)) continue;
        if (m.driver.ptr != s.driver_ptr) return null;
        return m;
    }
    return null;
}

fn mpSetState(app: *App, s: *MpSession, st: MpState, err_msg: []const u8) void {
    s.state = st;
    if (err_msg.len > 0) mpSetErr(app, s, err_msg);
}

/// 过期清扫（Go `Manager.gc`）：顺手在每次 init 时跑一遍，不开后台线程。
fn mpSweep(app: *App) void {
    const io = rt.io();
    const deadline = rt.nowMillis() - mp_ttl_ms;
    var victims = List(*MpSession).init(app.alloc);
    defer victims.deinit();
    {
        app.mp_mu.lockUncancelable(io);
        defer app.mp_mu.unlock(io);
        var it = app.mp_sessions.valueIterator();
        while (it.next()) |v| {
            if (v.*.last_active.load(.acquire) < deadline) {
                // AUDIT #1：先把手里的引用 +1 再摘出去锁外处理 —— 在途
                // chunk 持有的引用不归零，会话就不会在别人脚下被销毁。
                _ = v.*.refs.fetchAdd(1, .acq_rel);
                victims.append(v.*) catch {
                    _ = v.*.refs.fetchSub(1, .acq_rel);
                };
            }
        }
    }
    for (victims.slice()) |s| {
        app.mp_mu.lockUncancelable(io);
        s.mu.lockUncancelable(io);
        if (s.state == .receiving and !s.completing) {
            s.state = .aborted;
            mpSetErr(app, s, "multipart upload session expired");
        }
        const dead = s.state != .receiving;
        s.mu.unlock(io);
        const removed = if (dead) app.mp_sessions.remove(s.id) else false;
        app.mp_mu.unlock(io);
        if (dead) {
            if (s.spool_path.len > 0) std.Io.Dir.cwd().deleteFile(rt.io(), s.spool_path) catch {};
            // 表的基准引用：摘除成功才还（remove 失败 = 并发 abort 已摘）。
            if (removed) mpRelease(app, s);
        }
        // sweep 自己那份临时引用。
        mpRelease(app, s);
    }
}

fn mpNewId(app: *App) ![]u8 {
    var raw: [16]u8 = undefined;
    const rs = rand.randomString(&raw);
    // AUDIT-2026-11-27 #1：one-thread-per-connection 下并发 init 会同时执行
    // `+=`（数据竞争 UB），改原子自增。ID 唯一性另有 16 字节随机串兑底。
    const n = app.mp_seq.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(app.alloc, "mp-{s}-{d}", .{ rs, n });
}

/// AUDIT #1：init 发现同 key 旧会话不可续传（完成/失败/在收尾）时的摘除
/// 收尾。前提：旧会话已从表里 remove，且调用方已为其 +1 工作引用。这里连减
/// 两刀（表基准 + 调用方那一刀）—— 在途 chunk/complete 的引用不归零，
/// 会话就不会被销毁；spool 文件在两刀之前删（旧代码同序）。
fn mpStaleRetire(app: *App, prev: *MpSession) void {
    if (prev.spool_path.len > 0) std.Io.Dir.cwd().deleteFile(rt.io(), prev.spool_path) catch {};
    mpRelease(app, prev); // 表的基准引用
    mpRelease(app, prev); // 调用方（init）的工作引用
}

fn mpSessionKey(a: std.mem.Allocator, mount_path: []const u8, rel: []const u8, size: i64, mtime: []const u8) ![]u8 {
    const full = urlmod.joinPath(a, mount_path, rel) catch try a.dupe(u8, rel);
    return std.fmt.allocPrint(a, "admin|{s}|{d}|{s}", .{ full, size, mtime });
}

pub fn handleMultipart(app: *App, req: *http.Request, res: *http.Response, p: []const u8) !void {
    const prefix = "/api/fs/multipart";
    if (!std.mem.startsWith(u8, p, prefix)) return noRoute(app, req, res, p);
    const sub = p[prefix.len..]; // "/init" / "/chunk" / …
    if (std.mem.eql(u8, sub, "/init")) return handleMultipartInit(app, req, res);
    if (std.mem.eql(u8, sub, "/chunk")) return handleMultipartChunk(app, req, res);
    if (std.mem.eql(u8, sub, "/complete")) return handleMultipartComplete(app, req, res);
    if (std.mem.eql(u8, sub, "/status")) return handleMultipartStatus(app, req, res);
    if (std.mem.eql(u8, sub, "/abort")) return handleMultipartAbort(app, req, res);
    return noRoute(app, req, res, p);
}

fn mpChunkCeiling() i64 {
    return mp_ceiling_chunk_mib * (1 << 20);
}

fn handleMultipartInit(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const raw_path = req.header("File-Path") orelse
        return res.jsonError(400, "File-Path header is required");
    const path = urlmod.decode(a, raw_path) catch return res.jsonError(400, "bad File-Path");
    const r = app.resolve(path) orelse return res.jsonError(404, "storage not found");

    const size_hdr = req.header("X-File-Size") orelse
        return res.jsonError(400, "multipart upload requires a valid X-File-Size header");
    const size = std.fmt.parseInt(i64, size_hdr, 10) catch
        return res.jsonError(400, "multipart upload requires a valid X-File-Size header");
    if (size <= 0) return res.jsonError(400, "multipart upload requires a positive X-File-Size; upload empty files via /fs/put");

    // 上限 = `multipart_chunk_size` 设置（Go multipartChunkSize 的 ceiling 语义）；
    // 客户端只能建议更小的片，不能更大。空值 = 未带（Go 同款判定）。
    var chunk_size = mpChunkCeiling();
    if (req.header("X-Chunk-Size")) |v| {
        if (v.len > 0) {
            const requested = std.fmt.parseInt(i64, v, 10) catch
                return res.jsonError(400, "invalid X-Chunk-Size header");
            if (requested > 0 and requested < chunk_size) {
                chunk_size = @max(requested, mp_min_chunk);
            }
        }
    }
    const total = @divTrunc(size + chunk_size - 1, chunk_size);

    // Overwrite=false 且目标已存在 ⇒ 403（对齐 Go 的 "file exists"；Go 对
    // 目录同样拒绝 —— fs.Get 拿到任何对象都算存在）。
    if (std.ascii.eqlIgnoreCase(req.header("Overwrite") orelse "true", "false")) {
        var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
        var exists = true;
        if (r.mount.driver.details(&ctx, r.rel)) |_| {
            exists = true;
        } else |e| switch (e) {
            error.NotFound => exists = false,
            else => return mapDriverError(res, e, &ctx),
        }
        if (exists) return res.jsonError(403, "file exists");
    }

    const name = std.fs.path.basename(r.rel);
    const dir_rel = if (std.mem.lastIndexOfScalar(u8, r.rel, '/')) |i|
        (if (i == 0) "/" else r.rel[0..i])
    else
        "/";
    const mime = req.header("Content-Type") orelse mimeFor(name);
    const mtime = req.header("Last-Modified") orelse "0";

    const io = rt.io();
    const key = try mpSessionKey(a, r.mount.mount_path, r.rel, size, mtime);
    mpSweep(app);

    // 先在**无锁**状态下把新会话完整建好（含直传路径的 initMultiUpload 网络
    // 调用 / 回退路径的 spool 文件创建），再短锁做「续传 or 替换 or 插入」。
    // 持锁时零失败点 —— 任何 try 失败都不可能把 mp_mu 留在锁住状态。
    var fresh: ?*MpSession = null;
    {
        const id = try mpNewId(app);
        errdefer app.alloc.free(id);
        const s = try app.alloc.create(MpSession);
        errdefer app.alloc.destroy(s);
        s.* = .{
            .id = id,
            .key = try app.alloc.dupe(u8, key),
            .mount_path = try app.alloc.dupe(u8, r.mount.mount_path),
            .rel = try app.alloc.dupe(u8, r.rel),
            .name = try app.alloc.dupe(u8, name),
            .mime = if (mime.len > 0) try app.alloc.dupe(u8, mime) else "",
            .size = size,
            .chunk_size = chunk_size,
            .total = total,
            .driver_ptr = r.mount.driver.ptr,
            .direct = r.mount.driver.supportsMultipart(),
            .received = &.{},
            .slice_md5s = List([]const u8).init(app.alloc),
            .pending = List(MpChunk).init(app.alloc),
        };
        s.touch();

        if (s.direct) {
            // 向上游开分片会话（initMultiUpload，无 MD5 ⇒ 永不秒传）。
            // 驱动按上游约束回写生效片大小（189 的分片阶梯不接受任意值），
            // 前端按回写值切片。
            var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path, .err_detail = null };
            var effective = chunk_size;
            s.drv_session = r.mount.driver.mpBegin(&ctx, dir_rel, name, size, chunk_size, &effective) catch |e| {
                const detail = ctx.err_detail;
                mpFreeSession(app, s);
                return mapDriverError(res, e, if (detail != null) &ctx else null);
            };
            if (effective <= 0 or effective > size) effective = chunk_size;
            s.chunk_size = effective;
            s.total = @divTrunc(size + effective - 1, effective);
        } else {
            // 回退路径：稀疏 spool 文件（写哪个片补哪个洞，pwrite 自动扩洞）。
            // 落盘量 = 整份文件 ⇒ 先按 `zig.max_upload_mb` 拦一次：光猫的
            // temp_dir 是 tmpfs（220 MB，占 RAM），放行更大的文件只会把进程
            // OOM 掉或 ENOSPC 掐断连接（STATUS §56.1 的同一笔账）。
            if (app.mp_max_bytes > 0 and @as(u64, @intCast(size)) > app.mp_max_bytes) {
                mpFreeSession(app, s);
                const msg = std.fmt.allocPrint(
                    a,
                    "文件超过上传上限 {d} MiB（zig.max_upload_mb）：该存储不支持分片直传，整份文件要落到本机临时目录。请改用支持直传的存储、用网盘官方客户端，或将 temp_dir 指向更大存储后调高上限",
                    .{app.mp_max_bytes / (1024 * 1024)},
                ) catch "file exceeds zig.max_upload_mb and this storage cannot upload without spooling";
                try res.jsonError(413, msg);
                res.status = 413; // jsonError 恒写 200（对齐 Go 信封），这里要真实状态码
                return;
            }
            if (app.mp_dir.len == 0) {
                mpFreeSession(app, s);
                return res.jsonError(500, "multipart spool directory is not configured");
            }
            s.spool_path = std.fmt.allocPrint(app.alloc, "{s}/{s}.tmp", .{ app.mp_dir, s.id }) catch |e| {
                mpFreeSession(app, s);
                return e;
            };
            var f = std.Io.Dir.cwd().createFile(io, s.spool_path, .{}) catch |e| {
                const msg = std.fmt.allocPrint(a, "cannot create multipart spool file: {s}", .{@errorName(e)}) catch "cannot create multipart spool file";
                mpFreeSession(app, s);
                return res.jsonError(500, msg);
            };
            f.close(io);
        }
        s.received = try app.alloc.alloc(bool, @intCast(s.total));
        @memset(s.received, false);
        fresh = s;
    }

    var resumed = false;
    var s: *MpSession = fresh.?;
    var stale: ?*MpSession = null;
    // AUDIT #1：本 handler 对最终会话（fresh 或续传的 prev）的工作引用，
    // 函数收尾归还 —— 否则并发 abort 能在快照写出途中就把会话销毁。
    var held: ?*MpSession = null;
    defer if (held) |h| mpRelease(app, h);
    app.mp_mu.lockUncancelable(io);
    {
        // 同 key 的旧会话：receiving ⇒ 续传；其余 ⇒ 丢弃重建（Go 对 receiving
        // 还要求 hash 证明，这里以 Last-Modified 顶替，见 key 的注释）。
        var it = app.mp_sessions.valueIterator();
        var old: ?*MpSession = null;
        while (it.next()) |v| {
            if (std.mem.eql(u8, v.*.key, key)) {
                old = v.*;
                break;
            }
        }
        if (old) |prev| {
            // AUDIT #1：先拿引用再做事 —— 之后无论走 resume 还是 stale，
            // 别的线程都不能把这脚下的内存抽走。
            _ = prev.refs.fetchAdd(1, .acq_rel);
            prev.mu.lockUncancelable(io);
            const resume_ok = prev.state == .receiving and !prev.completing;
            prev.mu.unlock(io);
            if (resume_ok) {
                prev.touch();
                resumed = true;
                s = prev;
                held = prev; // defer 收尾时归还
            } else {
                stale = prev; // 锁外由 mpStaleRetire 连同两份引用一起归还
                _ = app.mp_sessions.remove(prev.id);
            }
        }
        if (!resumed) {
            app.mp_sessions.put(app.alloc, s.id, s) catch |e| {
                app.mp_mu.unlock(io);
                if (stale) |prev| mpStaleRetire(app, prev);
                mpFreeSession(app, s);
                return e;
            };
            // 表的基准引用之外，本函数再加一份工作引用。
            _ = s.refs.fetchAdd(1, .acq_rel);
            held = s;
        }
    }
    app.mp_mu.unlock(io);
    if (stale) |prev| mpStaleRetire(app, prev);
    if (resumed) {
        // 弃掉多余的全新会话。
        if (fresh.?.spool_path.len > 0) std.Io.Dir.cwd().deleteFile(io, fresh.?.spool_path) catch {};
        mpFreeSession(app, fresh.?);
    }

    log.info("multipart: init {s} size={d} chunks={d} resumed={} direct={}", .{
        r.rel, size, total, resumed, s.direct,
    });

    // Go 的 MultipartInitResp = SessionSnapshot + resumed。
    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":");
    try s.writeSnapshot(&b, a);
    try b.print(",\"resumed\":{}}}", .{resumed});
    try res.jsonOkRaw(b.slice());
}

fn handleMultipartChunk(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const io = rt.io();
    const id = req.header("X-Upload-Id") orelse return res.jsonError(404, "multipart session not found");
    const idx_hdr = req.header("X-Chunk-Index") orelse return res.jsonError(400, "invalid X-Chunk-Index header");
    const idx = std.fmt.parseInt(i64, idx_hdr, 10) catch return res.jsonError(400, "invalid X-Chunk-Index header");

    // AUDIT #1：拿引用而非裸指针 —— abort/sweep/init-stale 的摘除可与此处
    // 并发，refs 归零前 s 活着。
    const s = mpAcquire(app, id) orelse
        return res.jsonError(404, "multipart session not found");
    defer mpRelease(app, s);
    s.touch();

    s.mu.lockUncancelable(io);
    switch (s.state) {
        .completed => {
            // 幂等：收尾后的迟到分片按成功处理（对齐 Go）。
            s.mu.unlock(io);
            return mpRespondSnapshot(res, s, a);
        },
        .failed, .aborted => {
            const msg = if (s.err_msg.len > 0) s.err_msg else "multipart session is not receiving";
            s.mu.unlock(io);
            return res.jsonError(500, msg);
        },
        .receiving => {},
    }
    if (idx < 0 or idx >= s.total) {
        s.mu.unlock(io);
        return res.jsonError(400, "chunk index out of range");
    }
    const direct = s.direct;
    const drv_session = s.drv_session;
    const chunk_len = s.chunkLen(idx);
    const already = s.received[@intCast(idx)];
    s.mu.unlock(io);

    // 挂载可能在会话存活期间被重建（存储编辑）—— 句柄绑定旧驱动实例。
    const m = mpMountFor(app, s) orelse {
        s.mu.lockUncancelable(io);
        mpSetState(app, s, .failed, "storage was reloaded mid-upload; restart the upload");
        s.mu.unlock(io);
        return res.jsonError(500, "storage was reloaded mid-upload; restart the upload");
    };

    var body = req.body;
    if (body.len() != @as(u64, @intCast(chunk_len))) {
        return res.jsonError(400, "chunk length does not match the session's chunk size");
    }

    // 正文此时 ≤ chunk_size（10 MiB）≤ max_body_memory，是内存缓冲；
    // 兜底：万一正文被 spool 成文件（客户端不按 init 的片大小发），读进内存。
    const bytes: []const u8 = switch (body) {
        .none => &.{},
        .memory => |mm| mm,
        .file => blk: {
            const buf = try a.alloc(u8, @intCast(chunk_len));
            var src = body.source();
            _ = try src.readAllInto(0, buf);
            break :blk buf;
        },
    };

    if (direct) {
        var ctx = driver.Ctx{ .alloc = a, .tag = s.mount_path, .err_detail = null };
        const d = hashmod.md5(bytes);
        const md5_b64 = try hashmod.base64Std(a, &d);
        m.driver.mpPutChunk(&ctx, drv_session.?, idx + 1, md5_b64, bytes) catch |e| {
            // 上游拒绝这一片：前端对 429 会原片重试；连续失败到上限才判死。
            s.mu.lockUncancelable(io);
            s.fail_count += 1;
            const dead = s.fail_count >= mp_max_chunk_fails;
            if (dead) mpSetState(app, s, .failed, ctx.err_detail orelse @errorName(e));
            s.mu.unlock(io);
            if (dead) return res.jsonError(500, ctx.err_detail orelse @errorName(e));
            const msg = std.fmt.allocPrint(a, "chunk rejected, retry: {s}", .{ctx.err_detail orelse @errorName(e)}) catch "chunk rejected, retry";
            return res.jsonError(429, msg);
        };
        // 成功：把片挂进按序 MD5 消化队列（到达顺序不定，见模块头注释）。
        const d_upper = try hashmod.hexUpper(app.alloc, &d);
        const copy = try app.alloc.dupe(u8, bytes);
        s.mu.lockUncancelable(io);
        s.fail_count = 0;
        s.received[@intCast(idx)] = true;
        s.received_bytes += @intCast(chunk_len);
        s.pending.append(.{ .idx = idx, .bytes = copy, .md5_upper = d_upper }) catch |e| {
            app.alloc.free(copy);
            app.alloc.free(d_upper);
            s.mu.unlock(io);
            return e;
        };
        var md5_oom = false;
        while (true) {
            var found: ?usize = null;
            for (s.pending.slice(), 0..) |pc, i| {
                if (pc.idx == s.next_md5_idx) {
                    found = i;
                    break;
                }
            }
            const at = found orelse break;
            const pc = s.pending.slice()[at];
            s.md5.update(pc.bytes);
            // AUDIT-2026-11-27 #8：OM 时静默丢掉这一片的 slice MD5，
            // received_bytes 已计、next_md5_idx 已进，complete 拿残缺链去
            // mpCommit —— 上游秒传/校验语义被静默破坏且无日志。改为立即
            // 判死会话（重启上传是唯一诚实的结果），别静默丢片。
            s.slice_md5s.append(pc.md5_upper) catch {
                app.alloc.free(pc.md5_upper);
                mpSetState(app, s, .failed, "out of memory recording slice md5; restart the upload");
                md5_oom = true;
                break; // pending 里剩余条目由 mpFreeSession 统一回收
            };
            app.alloc.free(pc.bytes);
            mpPendingRemoveAt(&s.pending, at);
            s.next_md5_idx += 1;
        }
        s.mu.unlock(io);
        if (md5_oom) return res.jsonError(500, "out of memory recording slice md5; restart the upload");
        return mpRespondSnapshot(res, s, a);
    }

    // 回退路径：pwrite 进稀疏 spool 文件。
    var f = std.Io.Dir.cwd().openFile(io, s.spool_path, .{ .mode = .read_write }) catch |e| {
        return res.jsonError(500, @errorName(e));
    };
    defer f.close(io);
    std.Io.File.writePositionalAll(f, io, bytes, @as(u64, @intCast(idx * s.chunk_size))) catch |e| switch (e) {
        // temp_dir 写满：会话判死并回可读的 413，别让连接被静默掐断
        // （浏览器只会看到 network error，与 §55 的事故同一个坑）。
        error.NoSpaceLeft, error.DiskQuota => {
            s.mu.lockUncancelable(io);
            mpSetState(app, s, .failed, "temporary directory is full");
            s.mu.unlock(io);
            try res.jsonError(413, "本机临时目录空间不足（temp_dir）：分片落盘失败，请清理临时目录、或将 temp_dir 指向更大存储后重传");
            res.status = 413; // 同上：jsonError 恒写 200
            return;
        },
        else => {
            const msg = std.fmt.allocPrint(a, "cannot write chunk: {s}", .{@errorName(e)}) catch "cannot write chunk";
            return res.jsonError(500, msg);
        },
    };
    s.mu.lockUncancelable(io);
    if (!already) s.received_bytes += @intCast(chunk_len);
    s.received[@intCast(idx)] = true;
    s.mu.unlock(io);
    return mpRespondSnapshot(res, s, a);
}

fn handleMultipartComplete(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const io = rt.io();
    const id = req.header("X-Upload-Id") orelse return res.jsonError(404, "multipart session not found");

    // AUDIT #1：拿引用而非裸指针；complete 全程（含 mpCommit 的几秒网络）
    // 都受 refs 保护。
    const s = mpAcquire(app, id) orelse
        return res.jsonError(404, "multipart session not found");
    defer mpRelease(app, s);
    s.touch();

    s.mu.lockUncancelable(io);
    if (s.state == .completed) {
        s.mu.unlock(io);
        return mpRespondSnapshot(res, s, a);
    }
    if (s.state != .receiving or s.completing) {
        const msg = if (s.err_msg.len > 0) s.err_msg else "multipart session is not receiving";
        s.mu.unlock(io);
        return res.jsonError(500, msg);
    }
    if (s.received_bytes != @as(u64, @intCast(s.size))) {
        const msg = std.fmt.allocPrint(a, "cannot complete: {d} of {d} bytes received", .{ s.received_bytes, s.size }) catch "cannot complete: incomplete upload";
        s.mu.unlock(io);
        return res.jsonError(400, msg);
    }
    s.completing = true;
    const direct = s.direct;
    const drv_session = s.drv_session;
    s.mu.unlock(io);

    // 挂载可能在会话存活期间被重建（存储编辑）—— 句柄绑定旧驱动实例，
    // 那时只能让用户重传（新建会话会拿到新驱动）。
    const m = mpMountFor(app, s) orelse {
        s.mu.lockUncancelable(io);
        mpSetState(app, s, .failed, "storage was reloaded mid-upload; restart the upload");
        s.mu.unlock(io);
        return res.jsonError(500, "storage was reloaded mid-upload; restart the upload");
    };
    var ctx = driver.Ctx{
        .alloc = a,
        .tag = s.mount_path,
        .progress = mpStorageProgress,
        .progress_userdata = s,
    };

    if (direct) {
        // 把还没消化的 pending 全部排空（正常情况下最后一片响应返回时
        // 已排空；这里是防御）。
        s.mu.lockUncancelable(io);
        while (s.next_md5_idx < s.total) {
            var found: ?usize = null;
            for (s.pending.slice(), 0..) |pc, i| {
                if (pc.idx == s.next_md5_idx) {
                    found = i;
                    break;
                }
            }
            const at = found orelse break;
            const pc = s.pending.slice()[at];
            s.md5.update(pc.bytes);
            // AUDIT #8（同 chunk 路径）：排空阶段丢片同样判死，不能带着残缺链 commit。
            s.slice_md5s.append(pc.md5_upper) catch {
                app.alloc.free(pc.md5_upper);
                mpSetState(app, s, .failed, "out of memory recording slice md5; restart the upload");
                s.mu.unlock(io);
                return res.jsonError(500, "out of memory recording slice md5; restart the upload");
            };
            app.alloc.free(pc.bytes);
            mpPendingRemoveAt(&s.pending, at);
            s.next_md5_idx += 1;
        }
        if (s.next_md5_idx != s.total) {
            // 注：旧代码先 unlock 再 mpSetState —— 写 state/err_msg 在锁外，
            // 与读侧构成数据竞争；顺手修正为锁内置状态。
            mpSetState(app, s, .failed, "internal error: md5 chain incomplete");
            s.mu.unlock(io);
            return res.jsonError(500, "internal error: md5 chain incomplete");
        }
        const file_md5 = s.md5.finalHexUpper(a) catch |e| {
            s.mu.unlock(io);
            return e;
        };
        // 单片文件：sliceMd5 = 整文件 MD5（对齐 fastUpload / streamUpload）。
        const slice_md5: []const u8 = if (s.total > 1) mpJoinSliceMd5(a, s.slice_md5s.slice()) catch |e| {
            s.mu.unlock(io);
            return e;
        } else file_md5;
        s.mu.unlock(io);

        m.driver.mpCommit(&ctx, drv_session.?, file_md5, slice_md5) catch |e| {
            // 句柄已被 commit 自毁。
            s.mu.lockUncancelable(io);
            s.drv_session = null;
            mpSetState(app, s, .failed, ctx.err_detail orelse @errorName(e));
            s.mu.unlock(io);
            return mapDriverError(res, e, &ctx);
        };
        s.mu.lockUncancelable(io);
        s.drv_session = null;
        mpSetState(app, s, .completed, "");
        s.storage_pct = 100;
        s.mu.unlock(io);
        notifyObjsUpdateAfterWrite(app, a, m, mpParentOf(s.rel));
        return mpRespondSnapshot(res, s, a);
    }

    // 回退路径：整份文件已在稀疏 spool 里，用随机读 Source 走一次普通 put。
    var file = std.Io.Dir.cwd().openFile(io, s.spool_path, .{}) catch |e| {
        s.mu.lockUncancelable(io);
        s.completing = false;
        s.mu.unlock(io);
        return res.jsonError(500, @errorName(e));
    };
    defer file.close(io);
    var src_ctx = ArchiveFileSource{ .file = file, .size = @intCast(s.size) };
    var src = src_ctx.source();
    src.mime = s.mime;
    m.driver.put(&ctx, s.rel, src) catch |e| {
        s.mu.lockUncancelable(io);
        mpSetState(app, s, .failed, ctx.err_detail orelse @errorName(e));
        s.completing = false;
        s.mu.unlock(io);
        std.Io.Dir.cwd().deleteFile(io, s.spool_path) catch {};
        return mapDriverError(res, e, &ctx);
    };
    s.mu.lockUncancelable(io);
    mpSetState(app, s, .completed, "");
    s.storage_pct = 100;
    s.mu.unlock(io);
    std.Io.Dir.cwd().deleteFile(io, s.spool_path) catch {};
    notifyObjsUpdateAfterWrite(app, a, m, mpParentOf(s.rel));
    return mpRespondSnapshot(res, s, a);
}

fn mpStorageProgress(userdata: ?*anyopaque, percentage: u64) void {
    const s: *MpSession = @ptrCast(@alignCast(userdata orelse return));
    s.mu.lockUncancelable(rt.io());
    defer s.mu.unlock(rt.io());
    s.storage_pct = @floatFromInt(percentage);
}

fn handleMultipartStatus(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const id = req.queryGet("upload_id") orelse "";
    if (id.len == 0) return res.jsonError(400, "status lookup requires upload_id, or path and size");
    const s = mpAcquire(app, id) orelse
        return res.jsonError(404, "multipart session not found");
    defer mpRelease(app, s);
    s.touch();
    return mpRespondSnapshot(res, s, a);
}

fn handleMultipartAbort(app: *App, req: *http.Request, res: *http.Response) !void {
    const io = rt.io();
    const id = req.header("X-Upload-Id") orelse return res.jsonError(404, "multipart session not found");
    app.mp_mu.lockUncancelable(io);
    const s = app.mp_sessions.get(id) orelse {
        app.mp_mu.unlock(io);
        return res.jsonError(404, "multipart session not found");
    };
    _ = s.refs.fetchAdd(1, .acq_rel); // 本函数的工作引用
    s.mu.lockUncancelable(io);
    if (s.completing) {
        s.mu.unlock(io);
        app.mp_mu.unlock(io);
        mpRelease(app, s);
        return res.jsonError(409, "multipart session is completing");
    }
    mpSetState(app, s, .aborted, "aborted by client");
    s.mu.unlock(io);
    _ = app.mp_sessions.remove(s.id);
    app.mp_mu.unlock(io);
    // AUDIT #1：先删 spool（路径还在 s 里，此刻 s 必活），再连减两刀（表基
    // 准 + 本函数引用）。在途 chunk 持有的引用不归零，会话就活着 —— 修复
    // 「abort 锁外 free 踩到在途 chunk 的 s.touch()」的 UAF。
    if (s.spool_path.len > 0) std.Io.Dir.cwd().deleteFile(io, s.spool_path) catch {};
    mpRelease(app, s);
    mpRelease(app, s);
    try res.jsonOk("null");
}

fn mpPendingRemoveAt(l: *List(MpChunk), at: usize) void {
    const items = l.sliceMut();
    if (at >= items.len) return;
    if (at + 1 < items.len) std.mem.copyForwards(MpChunk, items[at .. items.len - 1], items[at + 1 ..]);
    l.len -= 1;
}

fn mpJoinSliceMd5(a: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var joined = Buf.init(a);
    for (parts, 0..) |m, i| {
        if (i > 0) try joined.appendByte('\n');
        try joined.append(m);
    }
    const d = hashmod.md5(joined.slice());
    return hashmod.hexUpper(a, &d);
}

fn mpRespondSnapshot(res: *http.Response, s: *MpSession, a: std.mem.Allocator) !void {
    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":");
    try s.writeSnapshot(&b, a);
    try b.append("}");
    try res.jsonOkRaw(b.slice());
}

/// `rel` 的父目录（“/x/y.txt” → “/x”；根级文件 → “/”）。
fn mpParentOf(rel: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return "/";
    return if (i == 0) "/" else rel[0..i];
}

// ---------------------------------------------------------------------------
// 分片上传的测试。FakeMpDriver 实现了 mp_* 四槽位（直传路径），Local 驱动
// 没有（回退路径）—— 两条路径都走一遍完整 init→chunk→complete。
// ---------------------------------------------------------------------------

const MpFakeDriver = struct {
    alloc: std.mem.Allocator,
    fail_put_chunk_times: u32 = 0,
    begun: usize = 0,
    aborted: usize = 0,
    committed: usize = 0,
    commit_file_md5: []const u8 = "",
    commit_slice_md5: []const u8 = "",
    put_parts: List(i64),
    put_bytes: List([]const u8),

    const Self = @This();

    fn as(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }
    fn drvName(_: *anyopaque) []const u8 {
        return "MpFake";
    }
    fn noopInit(_: *anyopaque, _: *driver.Ctx) anyerror!void {}
    fn noopDeinit(_: *anyopaque, _: *driver.Ctx) void {}
    fn emptyList(_: *anyopaque, _: *driver.Ctx, _: []const u8) anyerror![]model.Obj {
        return &.{};
    }
    fn fakeDetails(_: *anyopaque, _: *driver.Ctx, _: []const u8) anyerror!driver.File {
        return error.NotFound;
    }
    fn fakeLink(_: *anyopaque, _: *driver.Ctx, _: []const u8, _: driver.LinkArgs) anyerror!driver.Link {
        return error.NotSupported;
    }
    fn fakeMakeDir(_: *anyopaque, _: *driver.Ctx, _: []const u8) anyerror!void {}
    fn fakeMove(_: *anyopaque, _: *driver.Ctx, _: []const u8, _: []const u8) anyerror!void {}
    fn fakeRename(_: *anyopaque, _: *driver.Ctx, _: []const u8, _: []const u8) anyerror!void {}
    fn fakeRemove(_: *anyopaque, _: *driver.Ctx, _: []const u8, _: bool) anyerror!void {}
    fn fakePut(_: *anyopaque, _: *driver.Ctx, _: []const u8, _: model.Source) anyerror!void {}

    fn mpBegin(ptr: *anyopaque, _: *driver.Ctx, _: []const u8, _: []const u8, _: i64, chunk_size_in: i64, chunk_size_out: *i64) anyerror!*anyopaque {
        chunk_size_out.* = chunk_size_in;
        const self = as(ptr);
        self.begun += 1;
        const h = try self.alloc.create(u32);
        h.* = 1;
        return h;
    }
    fn mpPutChunk(ptr: *anyopaque, _: *driver.Ctx, session: *anyopaque, part: i64, _: []const u8, bytes: []const u8) anyerror!void {
        const self = as(ptr);
        const h: *u32 = @ptrCast(@alignCast(session));
        if (self.fail_put_chunk_times > 0) {
            self.fail_put_chunk_times -= 1;
            h.* += 1;
            return error.UpstreamHttp;
        }
        try self.put_parts.append(part);
        try self.put_bytes.append(try self.alloc.dupe(u8, bytes));
    }
    fn mpCommit(ptr: *anyopaque, _: *driver.Ctx, session: *anyopaque, file_md5: []const u8, slice_md5: []const u8) anyerror!void {
        const self = as(ptr);
        const h: *u32 = @ptrCast(@alignCast(session));
        self.alloc.destroy(h);
        self.committed += 1;
        self.commit_file_md5 = try self.alloc.dupe(u8, file_md5);
        self.commit_slice_md5 = try self.alloc.dupe(u8, slice_md5);
    }
    fn mpAbort(ptr: *anyopaque, _: *driver.Ctx, session: *anyopaque) void {
        const self = as(ptr);
        const h: *u32 = @ptrCast(@alignCast(session));
        self.alloc.destroy(h);
        self.aborted += 1;
    }

    pub const vtable = driver.Driver.VTable{
        .name = drvName,
        .init = noopInit,
        .deinit = noopDeinit,
        .list = emptyList,
        .details = fakeDetails,
        .link = fakeLink,
        .makeDir = fakeMakeDir,
        .move = fakeMove,
        .rename = fakeRename,
        .remove = fakeRemove,
        .put = fakePut,
        .mp_begin = mpBegin,
        .mp_put_chunk = mpPutChunk,
        .mp_commit = mpCommit,
        .mp_abort = mpAbort,
    };
};

fn mpTestApp(a: std.mem.Allocator, fe: frontend_mod.Frontend, mounts: []Mount) App {
    var app = routingApp(a, fe);
    app.mounts = mounts;
    return app;
}

// 分片上传 HTTP 级测试的公共脚手架：会话与请求共用**同一个 arena** ——
// 会话的成对 free 由 mpFreeSession 结构保证（生产 = gpa），测试里 arena
// 批量回收即可；逐项 free 在 Windows 的 page_allocator 上会触发
// VirtualFree 句柄语义问题（2026-10-30 实测挂死），不值得在测试里复刻。
test "multipart fallback round-trip through a local mount" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();

    var content_tmp = testing.tmpDir(.{});
    defer content_tmp.cleanup();
    var spool_tmp = testing.tmpDir(.{});
    defer spool_tmp.cleanup();
    const content_root = try std.Io.Dir.realPathFileAlloc(content_tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(content_root);
    const spool_root = try std.Io.Dir.realPathFileAlloc(spool_tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(spool_root);

    var local_drv = @import("drivers/local.zig").Local{ .alloc = a, .cfg = .{ .root_folder = content_root } };
    var app = mpTestApp(a, fe, try a.alloc(Mount, 0));
    const mounts = try a.alloc(Mount, 1);
    mounts[0] = .{
        .storage = .{ .id = 1, .mount_path = "/local", .driver = "Local", .addition = "{}" },
        .driver = driver.asDriver(@import("drivers/local.zig").Local, &local_drv),
        .mount_path = "/local",
        .label = "Local",
    };
    app.mounts = mounts;
    app.mp_dir = spool_root;

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});

    // ---- init（不带头 X-Chunk-Size ⇒ 用 1 MiB 的默认片）----
    const h2 = try a.alloc(Header, 4);
    h2[0] = .{ .name = "Authorization", .value = auth };
    h2[1] = .{ .name = "File-Path", .value = "%2Flocal%2Fmp_upload.bin" };
    h2[2] = .{ .name = "X-File-Size", .value = "12" };
    h2[3] = .{ .name = "Content-Type", .value = "text/plain" };
    const init_res = try doRequestWith(&app, a, "POST", "/api/fs/multipart/init", "", h2);
    try testing.expectEqual(@as(u16, 200), init_res.status);
    const init_j = try json.parse(a, init_res.buf.slice());
    try testing.expectEqual(@as(i64, 200), init_j.getPath("code").?.asInt().?);
    const upload_id = init_j.getPath("data.upload_id").?.asStr().?;
    try testing.expectEqual(@as(i64, mpChunkCeiling()), init_j.getPath("data.chunk_size").?.asInt().?);
    try testing.expectEqual(@as(i64, 1), init_j.getPath("data.total_chunks").?.asInt().?);
    try testing.expectEqualStrings("receiving", init_j.getPath("data.state").?.asStr().?);

    // ---- 唯一一片（12 字节 = 尾片长度）----
    {
        const ch = try a.alloc(Header, 3);
        ch[0] = .{ .name = "Authorization", .value = auth };
        ch[1] = .{ .name = "X-Upload-Id", .value = upload_id };
        ch[2] = .{ .name = "X-Chunk-Index", .value = "0" };
        const r = try doRequestJson(&app, a, "PUT", "/api/fs/multipart/chunk", "hello world!", ch);
        const j = try json.parse(a, r.buf.slice());
        try testing.expectEqual(@as(i64, 200), j.getPath("code").?.asInt().?);
        try testing.expectEqual(@as(i64, 12), j.getPath("data.received_bytes").?.asInt().?);
    }
    // 片长不对 ⇒ code 400。
    {
        const ch = try a.alloc(Header, 3);
        ch[0] = .{ .name = "Authorization", .value = auth };
        ch[1] = .{ .name = "X-Upload-Id", .value = upload_id };
        ch[2] = .{ .name = "X-Chunk-Index", .value = "0" };
        const r = try doRequestJson(&app, a, "PUT", "/api/fs/multipart/chunk", "x", ch);
        const j = try json.parse(a, r.buf.slice());
        try testing.expectEqual(@as(i64, 400), j.getPath("code").?.asInt().?);
    }
    // ---- complete ----
    {
        const ca = try a.alloc(Header, 2);
        ca[0] = .{ .name = "Authorization", .value = auth };
        ca[1] = .{ .name = "X-Upload-Id", .value = upload_id };
        const r = try doRequestJson(&app, a, "POST", "/api/fs/multipart/complete", "", ca);
        const j = try json.parse(a, r.buf.slice());
        try testing.expectEqual(@as(i64, 200), j.getPath("code").?.asInt().?);
        try testing.expectEqualStrings("completed", j.getPath("data.state").?.asStr().?);
    }
    // 目标文件内容正确。
    const got = try content_tmp.dir.readFileAlloc(rt.io(), "mp_upload.bin", a, .limited(1024));
    try testing.expectEqualStrings("hello world!", got);

    // ---- 未知会话 ⇒ code 404 信封 ----
    {
        const ch = try a.alloc(Header, 1);
        ch[0] = .{ .name = "Authorization", .value = auth };
        const r = try doRequestWith(&app, a, "GET", "/api/fs/multipart/status", "upload_id=x", ch);
        const j = try json.parse(a, r.buf.slice());
        try testing.expectEqual(@as(i64, 404), j.getPath("code").?.asInt().?);
    }
}

test "multipart fallback refuses files above zig.max_upload_mb" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();

    var content_tmp = testing.tmpDir(.{});
    defer content_tmp.cleanup();
    var spool_tmp = testing.tmpDir(.{});
    defer spool_tmp.cleanup();
    const content_root = try std.Io.Dir.realPathFileAlloc(content_tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(content_root);
    const spool_root = try std.Io.Dir.realPathFileAlloc(spool_tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(spool_root);

    var local_drv = @import("drivers/local.zig").Local{ .alloc = a, .cfg = .{ .root_folder = content_root } };
    var app = mpTestApp(a, fe, try a.alloc(Mount, 0));
    const mounts = try a.alloc(Mount, 1);
    mounts[0] = .{
        .storage = .{ .id = 1, .mount_path = "/local", .driver = "Local", .addition = "{}" },
        .driver = driver.asDriver(@import("drivers/local.zig").Local, &local_drv),
        .mount_path = "/local",
        .label = "Local",
    };
    app.mounts = mounts;
    app.mp_dir = spool_root;

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});

    const h = try a.alloc(Header, 4);
    h[0] = .{ .name = "Authorization", .value = auth };
    h[1] = .{ .name = "File-Path", .value = "%2Flocal%2Fbig.bin" };
    h[2] = .{ .name = "X-File-Size", .value = "12" };
    h[3] = .{ .name = "Content-Type", .value = "text/plain" };

    // 上限 8 字节 < 文件 12 字节 ⇒ 真实 413 + 信封：回退路径要整份落盘，
    // 与 `fs/put` 共用 `zig.max_upload_mb` 这笔账。
    app.mp_max_bytes = 8;
    const rejected = try doRequestWith(&app, a, "POST", "/api/fs/multipart/init", "", h);
    try testing.expectEqual(@as(u16, 413), rejected.status);
    const rj = try json.parse(a, rejected.buf.slice());
    try testing.expectEqual(@as(i64, 413), rj.getPath("code").?.asInt().?);
    try testing.expect(std.mem.indexOf(u8, rj.getPath("message").?.asStr().?, "zig.max_upload_mb") != null);

    // 0 = 不限（temp_dir 指到大容量存储时的配置）⇒ 放行。
    app.mp_max_bytes = 0;
    const ok = try doRequestWith(&app, a, "POST", "/api/fs/multipart/init", "", h);
    try testing.expectEqual(@as(u16, 200), ok.status);
}

test "multipart direct path accumulates MD5 across out-of-order chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();

    var fake = MpFakeDriver{ .alloc = a, .put_parts = List(i64).init(a), .put_bytes = List([]const u8).init(a) };
    var app = mpTestApp(a, fe, try a.alloc(Mount, 0));
    const mounts = try a.alloc(Mount, 1);
    mounts[0] = .{
        .storage = .{ .id = 1, .mount_path = "/mpd", .driver = "MpFake", .addition = "{}" },
        .driver = driver.asDriver(MpFakeDriver, &fake),
        .mount_path = "/mpd",
        .label = "MpFake",
    };
    app.mounts = mounts;

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});

    // ---- init：1 MiB 片 + 5 字节余数 ⇒ 两片 ----
    // 分片下限是 1 MiB（Go multipartMinChunkSize），小文件没法多片 ——
    // 用 1 MiB + 5 字节的文件逼出两片，再乱序发送。
    const chunk0_len: usize = 1 << 20;
    const chunk1_data = "world";
    const file_size: i64 = @intCast(chunk0_len + chunk1_data.len);
    const h2 = try a.alloc(Header, 4);
    h2[0] = .{ .name = "Authorization", .value = auth };
    h2[1] = .{ .name = "File-Path", .value = "%2Fmpd%2Fout_of_order.bin" };
    h2[2] = .{ .name = "X-File-Size", .value = try std.fmt.allocPrint(a, "{d}", .{file_size}) };
    h2[3] = .{ .name = "X-Chunk-Size", .value = "1048576" };
    const init_res = try doRequestWith(&app, a, "POST", "/api/fs/multipart/init", "", h2);
    const init_j = try json.parse(a, init_res.buf.slice());
    try testing.expectEqual(@as(i64, 200), init_j.getPath("code").?.asInt().?);
    const upload_id = init_j.getPath("data.upload_id").?.asStr().?;
    try testing.expectEqual(@as(usize, 1), fake.begun);
    try testing.expectEqual(@as(i64, 2), init_j.getPath("data.total_chunks").?.asInt().?);

    // ---- 乱序：先片 1 后片 0 ----
    const chunk0 = try a.alloc(u8, chunk0_len);
    @memset(chunk0, 0x41);
    const payload = [_][]const u8{ chunk0, chunk1_data };
    for ([_]usize{ 1, 0 }) |i| {
        const ch = try a.alloc(Header, 3);
        ch[0] = .{ .name = "Authorization", .value = auth };
        ch[1] = .{ .name = "X-Upload-Id", .value = upload_id };
        ch[2] = .{ .name = "X-Chunk-Index", .value = try std.fmt.allocPrint(a, "{d}", .{i}) };
        const r = try doRequestJson(&app, a, "PUT", "/api/fs/multipart/chunk", payload[i], ch);
        const j = try json.parse(a, r.buf.slice());
        try testing.expectEqual(@as(i64, 200), j.getPath("code").?.asInt().?);
    }

    // ---- complete：驱动收到的 MD5 必须与逐字节拼接后的一致 ----
    {
        const ca = try a.alloc(Header, 2);
        ca[0] = .{ .name = "Authorization", .value = auth };
        ca[1] = .{ .name = "X-Upload-Id", .value = upload_id };
        const r = try doRequestJson(&app, a, "POST", "/api/fs/multipart/complete", "", ca);
        const j = try json.parse(a, r.buf.slice());
        try testing.expectEqual(@as(i64, 200), j.getPath("code").?.asInt().?);
        try testing.expectEqualStrings("completed", j.getPath("data.state").?.asStr().?);
    }
    try testing.expectEqual(@as(usize, 1), fake.committed);
    // 片到达序（1,0）与 commit 的整文件 MD5（按字节序累计）互不干扰。
    try testing.expectEqual(@as(i64, 2), fake.put_parts.slice()[0]);
    try testing.expectEqual(@as(i64, 1), fake.put_parts.slice()[1]);

    // 整文件 MD5 = 拼接后（片 0 + 片 1）的 MD5 —— 分片乱序到达不影响累计。
    var joined = List(u8).init(a);
    try joined.appendSlice(chunk0);
    try joined.appendSlice(chunk1_data);
    const wd = hashmod.md5(joined.slice());
    const want_file = try hashmod.hexUpper(a, &wd);
    try testing.expectEqualStrings(want_file, fake.commit_file_md5);

    const m0 = hashmod.md5(payload[0]);
    const m1 = hashmod.md5(payload[1]);
    const h0 = try hashmod.hexUpper(a, &m0);
    const h1 = try hashmod.hexUpper(a, &m1);
    const want_slice = try mpJoinSliceMd5(a, &.{ h0, h1 });
    try testing.expectEqualStrings(want_slice, fake.commit_slice_md5);
}

test "multipart chunk size clamp mirrors Go's ceiling semantics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var fake = MpFakeDriver{ .alloc = a, .put_parts = List(i64).init(a), .put_bytes = List([]const u8).init(a) };
    var app = mpTestApp(a, fe, try a.alloc(Mount, 0));
    const mounts = try a.alloc(Mount, 1);
    mounts[0] = .{
        .storage = .{ .id = 1, .mount_path = "/mpd", .driver = "MpFake", .addition = "{}" },
        .driver = driver.asDriver(MpFakeDriver, &fake),
        .mount_path = "/mpd",
        .label = "MpFake",
    };
    app.mounts = mounts;
    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});

    const cases = [_]struct { req: ?[]const u8, want: i64 }{
        .{ .req = null, .want = mpChunkCeiling() }, // 未带 = ceiling
        .{ .req = "", .want = mpChunkCeiling() }, // 空值 = 未带（Go 同款）
        .{ .req = "33554432", .want = mpChunkCeiling() }, // 大于 ceiling 被夹回
        .{ .req = "2097152", .want = 2 * 1024 * 1024 }, // 更小的片被采纳
        .{ .req = "1024", .want = mp_min_chunk }, // 下限 1 MiB
    };
    for (cases, 0..) |c, ci| {
        var hdrs = List(Header).init(a);
        try hdrs.append(.{ .name = "Authorization", .value = auth });
        // 每个 case 独立路径：同 key 会续传旧会话（沿用其 chunk_size），
        // 那是正确行为，但会盖掉本 case 的断言目标。
        try hdrs.append(.{ .name = "File-Path", .value = try std.fmt.allocPrint(a, "%2Fmpd%2Fc{d}.bin", .{ci}) });
        try hdrs.append(.{ .name = "X-File-Size", .value = "104857600" });
        if (c.req) |v| try hdrs.append(.{ .name = "X-Chunk-Size", .value = v });
        const r = try doRequestWith(&app, a, "POST", "/api/fs/multipart/init", "", hdrs.sliceMut());
        const j = try json.parse(a, r.buf.slice());
        try testing.expectEqual(@as(i64, 200), j.getPath("code").?.asInt().?);
        try testing.expectEqual(@as(i64, c.want), j.getPath("data.chunk_size").?.asInt().?);
    }
}

test "multipart session basics: ranges, chunkLen, expiry state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s = MpSession{
        .id = @constCast("mp-x"),
        .key = @constCast("k"),
        .mount_path = @constCast("/m"),
        .rel = @constCast("/f.bin"),
        .name = @constCast("f.bin"),
        .size = 25,
        .chunk_size = 10,
        .total = 3,
        .driver_ptr = undefined,
        .direct = true,
        .received = try a.alloc(bool, 3),
        .slice_md5s = List([]const u8).init(a),
        .pending = List(MpChunk).init(a),
    };
    @memset(s.received, false);
    try testing.expectEqual(@as(i64, 10), s.chunkLen(0));
    try testing.expectEqual(@as(i64, 10), s.chunkLen(1));
    try testing.expectEqual(@as(i64, 5), s.chunkLen(2)); // 尾片 = 余数
    try testing.expectEqual(@as(i64, 0), s.chunkLen(3)); // 越界

    // received 位图 → Go 形状的区间列表。
    s.received[0] = true;
    s.received[1] = true;
    var b = Buf.init(a);
    try s.writeReceived(&b);
    try testing.expectEqualStrings("[[0,1]]", b.slice());
    s.received[2] = true;
    var b2 = Buf.init(a);
    try s.writeReceived(&b2);
    try testing.expectEqualStrings("[[0,2]]", b2.slice());

    // 片 0/2 到了、片 1 没到 ⇒ received_bytes 只算前两者，frontier = 2。
    s.received[2] = false;
    s.received_bytes = 20;
    var b3 = Buf.init(a);
    try s.writeSnapshot(&b3, a);
    const j = try json.parse(a, b3.slice());
    try testing.expectEqualStrings("receiving", j.getPath("state").?.asStr().?);
    try testing.expectEqual(@as(i64, 20), j.getPath("received_bytes").?.asInt().?);
    try testing.expectEqual(@as(i64, 2), j.getPath("frontier").?.asInt().?);
    try testing.expect(std.mem.indexOf(u8, b3.slice(), "[[0,1]]") != null);
}

// ---------------------------------------------------------------------------
// AUDIT-2026-11-27 #1：multipart 会话引用计数的回归测试。
// ★ `app.alloc` 一律用 testing.allocator（DebugAllocator）：会话的逐项
//   free 全程被跟踪，双 free / 野指针 free 立刻炸；请求/挂载仍走 arena。
// ---------------------------------------------------------------------------

test "AUDIT #1: abort cannot free a session an in-flight holder still uses" {
    // 修复前形态：chunk/status 在 `mp_mu` 解锁后仍持有会话指针并发 abort
    // 锁外 `mpFreeSession` 将其销毁 —— use-after-free。引用计数制下 abort
    // 只摘表，销毁落在最后一个引用的 release 上（本测试结尾那一刀）。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();

    var content_tmp = testing.tmpDir(.{});
    defer content_tmp.cleanup();
    var spool_tmp = testing.tmpDir(.{});
    defer spool_tmp.cleanup();
    const content_root = try std.Io.Dir.realPathFileAlloc(content_tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(content_root);
    const spool_root = try std.Io.Dir.realPathFileAlloc(spool_tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(spool_root);

    var local_drv = @import("drivers/local.zig").Local{ .alloc = a, .cfg = .{ .root_folder = content_root } };
    var app = routingApp(testing.allocator, fe);
    const mounts = try a.alloc(Mount, 1);
    mounts[0] = .{
        .storage = .{ .id = 1, .mount_path = "/local", .driver = "Local", .addition = "{}" },
        .driver = driver.asDriver(@import("drivers/local.zig").Local, &local_drv),
        .mount_path = "/local",
        .label = "Local",
    };
    app.mounts = mounts;
    app.mp_dir = spool_root;

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});

    const h = try a.alloc(Header, 4);
    h[0] = .{ .name = "Authorization", .value = auth };
    h[1] = .{ .name = "File-Path", .value = "%2Flocal%2Fuaf.bin" };
    h[2] = .{ .name = "X-File-Size", .value = "12" };
    h[3] = .{ .name = "Content-Type", .value = "text/plain" };
    const init_res = try doRequestWith(&app, a, "POST", "/api/fs/multipart/init", "", h);
    try expectApiCode(init_res, 200);
    const init_j = try json.parse(a, init_res.buf.slice());
    const upload_id = init_j.getPath("data.upload_id").?.asStr().?;

    // ① 模拟在途 chunk：拿一份引用。
    const s = (mpAcquire(&app, upload_id)) orelse return error.TestUnexpectedResult;

    // ② 并发 abort：摘表 + 置 aborted，**不得**销毁 s。
    const ah = try a.alloc(Header, 2);
    ah[0] = .{ .name = "Authorization", .value = auth };
    ah[1] = .{ .name = "X-Upload-Id", .value = upload_id };
    const abort_res = try doRequestWith(&app, a, "POST", "/api/fs/multipart/abort", "", ah);
    try expectApiCode(abort_res, 200);
    try testing.expectEqual(@as(u32, 0), app.mp_sessions.count());

    // ③ abort 返回后 s 必须仍然可用（旧代码这里是已释放内存）。
    try testing.expectEqualStrings(upload_id, s.id);
    try testing.expectEqual(MpState.aborted, s.state);
    try testing.expectEqualStrings("aborted by client", s.err_msg);
    // 只剩我们这一份引用（表基准已被 abort 归还）。
    try testing.expectEqual(@as(u32, 1), s.refs.load(.acquire));

    // ④ 最后一刀：归零销毁。DebugAllocator 会盯住每一次 free。
    mpRelease(&app, s);
    try testing.expectEqual(@as(u32, 0), app.mp_sessions.count());
    // 会话全销毁之后把表的桶数组也还回去（put 时分配、remove 不缩）。
    app.mp_sessions.deinit(app.alloc);
}

test "AUDIT #1: acquire/abort/release race stress keeps the session alive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();

    var content_tmp = testing.tmpDir(.{});
    defer content_tmp.cleanup();
    var spool_tmp = testing.tmpDir(.{});
    defer spool_tmp.cleanup();
    const content_root = try std.Io.Dir.realPathFileAlloc(content_tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(content_root);
    const spool_root = try std.Io.Dir.realPathFileAlloc(spool_tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(spool_root);

    var local_drv = @import("drivers/local.zig").Local{ .alloc = a, .cfg = .{ .root_folder = content_root } };
    var app = routingApp(testing.allocator, fe);
    const mounts = try a.alloc(Mount, 1);
    mounts[0] = .{
        .storage = .{ .id = 1, .mount_path = "/local", .driver = "Local", .addition = "{}" },
        .driver = driver.asDriver(@import("drivers/local.zig").Local, &local_drv),
        .mount_path = "/local",
        .label = "Local",
    };
    app.mounts = mounts;
    app.mp_dir = spool_root;

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});

    const h = try a.alloc(Header, 4);
    h[0] = .{ .name = "Authorization", .value = auth };
    h[1] = .{ .name = "File-Path", .value = "%2Flocal%2Frace.bin" };
    h[2] = .{ .name = "X-File-Size", .value = "12" };
    h[3] = .{ .name = "Content-Type", .value = "text/plain" };
    const init_res = try doRequestWith(&app, a, "POST", "/api/fs/multipart/init", "", h);
    try expectApiCode(init_res, 200);
    const init_j = try json.parse(a, init_res.buf.slice());
    const upload_id = init_j.getPath("data.upload_id").?.asStr().?;

    // 4 个 worker 反复 acquire/touch/release，与主线程的 abort 赛跑。
    // 修复前：abort 的锁外 free 与 worker 的 touch 并发 ≈ UAF（旧实现此
    // 形态真机可复现）；修复后：refs 不归零会话就活着。
    const Worker = struct {
        fn run(ap: *App, id: []const u8, rounds: usize) void {
            var i: usize = 0;
            while (i < rounds) : (i += 1) {
                if (mpAcquire(ap, id)) |s| {
                    s.touch();
                    mpRelease(ap, s);
                }
            }
        }
    };
    var ths: [4]std.Thread = undefined;
    for (&ths) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &app, upload_id, 200 });

    const hold = (mpAcquire(&app, upload_id)) orelse {
        for (&ths) |t| t.join();
        return error.TestUnexpectedResult;
    };
    const ah = try a.alloc(Header, 2);
    ah[0] = .{ .name = "Authorization", .value = auth };
    ah[1] = .{ .name = "X-Upload-Id", .value = upload_id };
    const abort_res = try doRequestWith(&app, a, "POST", "/api/fs/multipart/abort", "", ah);
    try expectApiCode(abort_res, 200);

    for (&ths) |t| t.join();
    // 会话内容在整场赛跑后仍完好（销毁从未发生）。
    try testing.expectEqualStrings(upload_id, hold.id);
    mpRelease(&app, hold);
    try testing.expectEqual(@as(u32, 0), app.mp_sessions.count());
    app.mp_sessions.deinit(app.alloc);
}
