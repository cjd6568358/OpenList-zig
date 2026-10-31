//! SFTP 请求分发：把 `PacketType` 映射到 `driver.Driver` vtable。
//!
//! ## 为什么这里用「窄接口」而不是直接拿 `*api.App`
//!
//! 分发逻辑真正需要的只有两件事：**路径 → (驱动, 驱动内相对路径)**，以及
//! **从 link 取一段字节**。直接依赖 `api.App` 会把整个 HTTP 栈（配置、鉴权、
//! 挂载锁）拖进单测，而这两件事都能用 20 行抽象表达清楚：
//!
//!   - `Resolver` —— 生产实现包 `App.resolve`，测试实现包一张内存文件表；
//!   - `Fetcher`  —— 生产实现包 `client.zig` 的 Range 请求，测试实现包一个
//!     内存切片。
//!
//! 于是「打开目录 / 读文件 / 改属性」这些路径全都能纯单测，不需要起服务、
//! 不需要网络、不需要真实凭据。
//!
//! ## 本轮的能力边界（诚实标注）
//!
//! | 已支持 | 说明 |
//! |---|---|
//! | `INIT` / `REALPATH` / `STAT` / `LSTAT` / `FSTAT` | 元数据 |
//! | `OPENDIR` / `READDIR` | 分页，每包最多 `readdir_page` 条 |
//! | `MKDIR` / `RMDIR` / `REMOVE` / `RENAME` | 目录与删除 |
//! | `OPEN`(只读) / `READ` / `CLOSE` | 读路径，带 1 MiB 窗口缓存 |
//! | `SETSTAT` 的权限/时间字段 | 虚拟路径无意义，**接受并忽略** |
//!
//! | 明确未支持（回 `SSH_FX_OP_UNSUPPORTED`） | 原因 |
//! |---|---|
//! | `OPEN` 写模式 / `WRITE` | 写需要「按 offset 攒进临时文件，CLOSE 时整份 `put`」，还要接 `temp_dir` 容量闸，单独一轮做 |
//! | `SETSTAT` 的 `size` | 截断是真实数据操作，不能假装成功 |
//! | `READLINK` / `SYMLINK` / `EXTENDED` | 虚拟路径没有符号链接；扩展未实现 |
//!
//! 「明确未支持」而不是「静默失败」是刻意的：客户端会显示清晰的错误，
//! 而不是让人对着一个没反应的操作猜。

const std = @import("std");
const model = @import("../model.zig");
const driver = @import("../driver.zig");
const protocol = @import("protocol.zig");
const session = @import("session.zig");
const Buf = @import("../util/buf.zig").Buf;
const rt = @import("../rt.zig");
const log = @import("../log.zig");

/// 一次挂载解析的结果：用哪个驱动、驱动内相对路径是什么。
pub const Target = struct {
    driver: driver.Driver,
    rel: []const u8,
    mount_path: []const u8,
};

/// 路径 → 挂载。生产实现：`App.resolve`（最长前缀匹配）。
pub const Resolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (ctx: *anyopaque, vpath: []const u8) ?Target,
    /// 列出**虚拟根**的一级子项（挂载点第一段，去重）。`null` = 不支持列根。
    ///
    /// 为什么需要它：OpenList 的 `/` 是合成出来的虚拟根，没有任何驱动拥有
    /// 它，所以 `resolve("/")` 必然失败。但 SFTP 客户端一上来就 `OPENDIR /`，
    /// 不支持的话用户看到的是一片空白 —— 比报错更难排查。
    listRootFn: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![][]u8 = null,

    pub fn resolve(self: Resolver, vpath: []const u8) ?Target {
        return self.resolveFn(self.ctx, vpath);
    }

    pub fn listRoot(self: Resolver, alloc: std.mem.Allocator) anyerror![][]u8 {
        const f = self.listRootFn orelse return error.NotSupported;
        return f(self.ctx, alloc);
    }
};

/// 从驱动返回的 link 取 `[offset, offset+len)` 字节。
///
/// 只有 `local_path` 与 `url` 两种 link 需要它；`text` 由 handler 自己切片
/// （见 `FileState`），因为内存源没有 I/O 可做。
pub const Fetcher = struct {
    ctx: *anyopaque,
    /// 返回的内存由 `alloc` 分配，**调用方接管所有权**。
    fetchFn: *const fn (
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        link: model.Link,
        offset: u64,
        len: u32,
    ) anyerror![]u8,

    pub fn fetch(self: Fetcher, alloc: std.mem.Allocator, link: model.Link, offset: u64, len: u32) ![]u8 {
        return self.fetchFn(self.ctx, alloc, link, offset, len);
    }
};

pub const Context = struct {
    /// **连接级** allocator（不是请求 arena）：句柄状态要跨请求存活。
    alloc: std.mem.Allocator,
    resolver: Resolver,
    /// 没有它时，`local_path` / `url` 型 link 的 READ 回 `op_unsupported`。
    fetcher: ?Fetcher = null,
    /// 写路径的落盘目录（生产 = `App.mp_dir` = `<temp_dir>/multipart`）。
    /// 为空时所有写操作回 `op_unsupported`。
    temp_dir: []const u8 = "",
    /// 单文件写入上限（生产 = `App.mp_max_bytes` = `zig.max_upload_mb`）。
    /// 0 = 不限。超限时 `WRITE` 直接失败，不等到把 tmpfs 写满。
    max_write_bytes: u64 = 0,
};

/// 读句柄的窗口缓存大小。SFTP 客户端典型读块是 32 KiB，1 MiB 窗口能覆盖
/// 连续读，把「每块一次 Range 请求」降到「每 32 块一次」。
const read_window: usize = 1024 * 1024;

/// 单个 `READDIR` 回复最多带多少条。取 64：按每条约 100 字节算约 6.4 KiB，
/// 远低于 `max_packet_len`，同时让大目录的往返次数保持在可接受范围。
const readdir_page: usize = 64;

/// `READ` 单次最多返回多少字节。留 1 KiB 余量给 id / 长度前缀 / 字符串头。
const max_read_len: usize = protocol.max_packet_len - 1024;

// ---------------------------------------------------------------------------
// 句柄私有状态
// ---------------------------------------------------------------------------

/// 打开的文件句柄。读和写是**两种完全不同的资源**，用 union 而不是一堆
/// 可空字段：读句柄有 link 和缓存，写句柄有 temp 文件，混在一起会让
/// 「读句柄被当成写句柄用」这种错误变成运行期才发现的空指针。
const FileState = union(enum) {
    read: ReadState,
    write: WriteState,

    /// ⚠ **忽略传入的 `alloc`**：那个 allocator 是 `Session` 的，而状态是用
    /// `Context.alloc` 建的。两者在生产里恰好都是 `rt.gpa()`，一旦不是同一个
    /// （测试里换成 arena 就会），`destroy` / `free` 就是 UB。所以每个变体
    /// 自带一份创建时的 allocator。
    fn release(ptr: *anyopaque, _: std.mem.Allocator) void {
        const self: *FileState = @ptrCast(@alignCast(ptr));
        const a = switch (self.*) {
            .read => |*r| blk: {
                r.release();
                break :blk r.alloc;
            },
            .write => |*w| blk: {
                w.release();
                break :blk w.alloc;
            },
        };
        a.destroy(self);
    }
};

/// 读句柄。`link` 已经**深拷贝**到 `Context.alloc`，可以跨请求使用。
const ReadState = struct {
    /// 创建这份状态用的 allocator，释放时**只认它**。
    alloc: std.mem.Allocator,
    link: model.Link,
    size: u64,
    /// 窗口缓存：`[cache_off, cache_off + cache_len)` 的字节。
    cache: []u8 = &.{},
    cache_off: u64 = 0,
    cache_len: usize = 0,

    fn release(self: *ReadState) void {
        if (self.cache.len > 0) self.alloc.free(self.cache);
        freeLink(self.alloc, self.link);
    }
};

/// 写句柄：SFTP 按 offset 随机写，而驱动只有「整份 `put`」，所以先在
/// `temp_dir` 里攒一个稀疏文件，`CLOSE` 时一次 `put` 上去。
///
/// ⚠ 落盘量 = 整份文件 ⇒ 与分片回退路径**同一笔账**，受 `max_write_bytes`
/// （= `zig.max_upload_mb`）约束。光猫的 `temp_dir` 是 tmpfs（吃 RAM），
/// 不设闸的话一个大文件就能把进程打死。
const WriteState = struct {
    /// 创建这份状态用的 allocator，释放时**只认它**（见 `FileState.release`）。
    alloc: std.mem.Allocator,
    file: std.Io.File,
    /// temp 文件的绝对/相对路径，`CLOSE` 后删除。
    tmp_path: []u8,
    /// 目标虚拟路径（`put` 用），深拷贝到连接级 alloc。
    vpath: []u8,
    /// 已写入的最高偏移 + 1（稀疏写时取最大值）。
    size: u64 = 0,
    /// `SSH_FXF_APPEND`：忽略客户端给的 offset，总是追加到末尾。
    append: bool = false,
    /// 是否出现过写入失败（容量闸拒绝 / 磁盘错误）。
    ///
    /// ⚠ 这个标志不能省：客户端在 `WRITE` 失败后**仍会发 `CLOSE`**。如果
    /// CLOSE 无条件 `put`，就会把一个被截断的文件（比如容量闸拦下的前 8 MiB）
    /// 当成完整文件传上去，甚至覆盖掉目标上的原文件。实测过：9 MiB 上传被
    /// 容量闸拒绝后，磁盘上留下了正好 8 MiB 的 `over.bin`。
    failed: bool = false,

    fn release(self: *WriteState) void {
        self.file.close(rt.io());
        // 删除失败不致命（temp 目录会被清理），但要在日志里留痕。
        std.Io.Dir.cwd().deleteFile(rt.io(), self.tmp_path) catch |e| {
            log.debug("sftp: cannot remove temp {s}: {s}", .{ self.tmp_path, @errorName(e) });
        };
        self.alloc.free(self.tmp_path);
        self.alloc.free(self.vpath);
    }
};

const DirEntry = struct {
    name: []u8,
    size: i64,
    is_dir: bool,
    modified: i64,
};

/// 目录句柄状态。`OPENDIR` 时一次性 `list` 并把需要的字段深拷贝，
/// `READDIR` 只按游标切片 —— 否则每次 READDIR 都要重新列一次上游目录。
const DirState = struct {
    /// 创建这份状态用的 allocator（与 `FileState` 同样的理由：release 回调
    /// 收到的 allocator 不是这一个）。
    alloc: std.mem.Allocator,
    entries: []DirEntry,
    cursor: usize = 0,

    fn release(ptr: *anyopaque, _: std.mem.Allocator) void {
        const self: *DirState = @ptrCast(@alignCast(ptr));
        const a = self.alloc;
        for (self.entries) |e| a.free(e.name);
        if (self.entries.len > 0) a.free(self.entries);
        a.destroy(self);
    }
};

/// 深拷贝一条 link。驱动返回的字符串活在**请求 arena** 里，句柄要跨请求
/// 存活，不拷贝就是悬垂指针。
fn dupLink(alloc: std.mem.Allocator, l: model.Link) !model.Link {
    var out = model.Link{
        .url = try alloc.dupe(u8, l.url),
        .proxy = l.proxy,
        .local_size = l.local_size,
    };
    errdefer alloc.free(out.url);

    if (l.local_path) |p| out.local_path = try alloc.dupe(u8, p);
    if (l.text) |t| out.text = try alloc.dupe(u8, t);

    if (l.header.len > 0) {
        const hs = try alloc.alloc(model.Header, l.header.len);
        var n: usize = 0;
        errdefer {
            for (hs[0..n]) |h| {
                alloc.free(h.name);
                alloc.free(h.value);
            }
            alloc.free(hs);
        }
        for (l.header) |h| {
            hs[n] = .{
                .name = try alloc.dupe(u8, h.name),
                .value = try alloc.dupe(u8, h.value),
            };
            n += 1;
        }
        out.header = hs;
    }
    return out;
}

fn freeLink(alloc: std.mem.Allocator, l: model.Link) void {
    if (l.url.len > 0) alloc.free(l.url);
    if (l.local_path) |p| alloc.free(p);
    if (l.text) |t| alloc.free(t);
    if (l.header.len > 0) {
        for (l.header) |h| {
            alloc.free(h.name);
            alloc.free(h.value);
        }
        alloc.free(l.header);
    }
}

// ---------------------------------------------------------------------------
// 分发
// ---------------------------------------------------------------------------

/// 处理一个已解析的包，把回复追加到 `out`。
///
/// `a` 是**请求级** arena（每次调用一个新）：驱动调用、临时字符串都从这里出，
/// 函数返回后统一回收。跨请求的状态一律走 `c.alloc`。
pub fn dispatch(
    c: *Context,
    sess: *session.Session,
    a: std.mem.Allocator,
    pkt: protocol.Packet,
    out: *Buf,
) !void {
    var r = protocol.Reader.init(pkt.body);
    switch (pkt.packet_type) {
        .init => try handleInit(sess, &r, out),
        .realpath => try handleRealpath(c, sess, a, &r, out),
        .stat, .lstat => try handleStat(c, sess, a, &r, out),
        .fstat => try handleFstat(c, sess, a, &r, out),
        .opendir => try handleOpenDir(c, sess, a, &r, out),
        .readdir => try handleReadDir(sess, a, &r, out),
        .open => try handleOpen(c, sess, a, &r, out),
        .read => try handleRead(c, sess, a, &r, out),
        .close => try handleClose(c, sess, a, &r, out),
        .write => try handleWrite(c, sess, a, &r, out),
        .mkdir => try handleMkdir(c, sess, a, &r, out),
        .rmdir => try handleRmdir(c, sess, a, &r, out),
        .remove => try handleRemove(c, sess, a, &r, out),
        .rename => try handleRename(c, sess, a, &r, out),
        .setstat, .fsetstat => try handleSetstat(c, sess, a, &r, out, pkt.packet_type == .fsetstat),
        else => {
            // 未知包：仍然要回一个带正确 id 的 STATUS，否则客户端会一直等。
            const id = r.readU32() catch return error.BadMessage;
            try protocol.writeStatus(out, id, .op_unsupported);
        },
    }
}

fn handleInit(sess: *session.Session, r: *protocol.Reader, out: *Buf) !void {
    // 客户端版本号我们不关心：v3 是唯一的互操作版本，低版本客户端也按 v3
    // 回（OpenSSH 的做法）。重发 INIT 时清空旧句柄。
    _ = r.readU32() catch 0;
    sess.reset();
    sess.negotiated = true;

    var body = Buf.init(out.alloc);
    defer body.deinit();
    var w = protocol.Writer.init(&body);
    try w.writeU32(protocol.version);
    // 不宣告任何扩展：宣告了就要实现，而 `posix-rename@openssh.com` 等
    // 扩展的语义（原子覆盖）在本工程里没有对应能力。
    try protocol.frame(out, .version, body.slice());
}

fn handleRealpath(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    _ = c;
    const id = try r.readU32();
    const raw = try r.readString();

    const n = sess.resolve(raw) catch {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    defer sess.alloc.free(n.path);

    // REALPATH 不要求目标存在（OpenSSH 的 sftp-server 也不检查），只做
    // 归一化并原样返回 —— 客户端靠它把相对路径变成绝对路径。
    try writeNameOne(out, a, id, n.path, 0, true, 0);
}

fn handleStat(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    const id = try r.readU32();
    const raw = try r.readString();

    const n = sess.resolve(raw) catch {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    defer sess.alloc.free(n.path);

    // 虚拟根没有驱动，但客户端一定会 STAT 它。
    if (isVirtualRoot(n.path)) {
        try protocol.writeAttrs(out, id, attrsOf(0, true, 0));
        return;
    }

    const t = c.resolver.resolve(n.path) orelse {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    var dctx = driver.Ctx{ .alloc = a, .tag = t.mount_path };
    const f = t.driver.details(&dctx, t.rel) catch |e| {
        try protocol.writeStatus(out, id, statusFor(e));
        return;
    };
    try protocol.writeAttrs(out, id, attrsOf(f.size, f.is_dir, f.modified));
}

fn handleFstat(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    const id = try r.readU32();
    const handle = try r.readString();

    const h = findHandle(sess, handle) orelse {
        try protocol.writeStatus(out, id, .failure);
        return;
    };
    const t = c.resolver.resolve(h.path) orelse {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    var dctx = driver.Ctx{ .alloc = a, .tag = t.mount_path };
    const f = t.driver.details(&dctx, t.rel) catch |e| {
        try protocol.writeStatus(out, id, statusFor(e));
        return;
    };
    try protocol.writeAttrs(out, id, attrsOf(f.size, f.is_dir, f.modified));
}

fn handleOpenDir(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    const id = try r.readU32();
    const raw = try r.readString();

    const n = sess.resolve(raw) catch {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    defer sess.alloc.free(n.path);

    // 虚拟根：没有驱动拥有它，列挂载点的一级名字。
    if (isVirtualRoot(n.path)) {
        const names = c.resolver.listRoot(a) catch |e| {
            try protocol.writeStatus(out, id, statusFor(e));
            return;
        };
        const entries = try c.alloc.alloc(DirEntry, names.len);
        var done: usize = 0;
        errdefer {
            for (entries[0..done]) |e| c.alloc.free(e.name);
            c.alloc.free(entries);
        }
        for (names) |nm| {
            entries[done] = .{
                .name = try c.alloc.dupe(u8, nm),
                .size = 0,
                .is_dir = true,
                .modified = 0,
            };
            done += 1;
        }
        try registerDir(c, sess, n.path, entries, id, out);
        return;
    }

    const t = c.resolver.resolve(n.path) orelse {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    var dctx = driver.Ctx{ .alloc = a, .tag = t.mount_path };
    const objs = t.driver.list(&dctx, t.rel) catch |e| {
        try protocol.writeStatus(out, id, statusFor(e));
        return;
    };

    // 深拷贝到连接级 alloc：`objs` 里的 name 活在请求 arena 里。
    const entries = try c.alloc.alloc(DirEntry, objs.len);
    var n_done: usize = 0;
    errdefer {
        for (entries[0..n_done]) |e| c.alloc.free(e.name);
        c.alloc.free(entries);
    }
    for (objs) |o| {
        entries[n_done] = .{
            .name = try c.alloc.dupe(u8, o.name),
            .size = o.size,
            .is_dir = o.is_dir,
            .modified = o.modified,
        };
        n_done += 1;
    }
    try registerDir(c, sess, n.path, entries, id, out);
}

/// 把一份已深拷贝的条目表登记成目录句柄并回 `HANDLE`。两个分支（虚拟根 /
/// 真实目录）共用，避免重复那段容易写错的所有权处理。
fn registerDir(
    c: *Context,
    sess: *session.Session,
    path: []const u8,
    entries: []DirEntry,
    id: u32,
    out: *Buf,
) !void {
    const st = try c.alloc.create(DirState);
    st.* = .{ .alloc = c.alloc, .entries = entries };

    const p = try sess.alloc.dupe(u8, path);
    const hid = sess.addHandle(p, .dir) catch |e| {
        // addHandle 失败时已经接管并释放了 p
        DirState.release(st, c.alloc);
        try protocol.writeStatus(out, id, statusFor(e));
        return;
    };
    sess.setExtra(hid, st, DirState.release);

    var hbuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &hbuf, hid, .big);
    try protocol.writeHandle(out, id, &hbuf);
}

fn handleReadDir(sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    const id = try r.readU32();
    const handle = try r.readString();

    const h = findHandle(sess, handle) orelse {
        try protocol.writeStatus(out, id, .failure);
        return;
    };
    if (h.kind != .dir) {
        try protocol.writeStatus(out, id, .failure);
        return;
    }
    const st: *DirState = @ptrCast(@alignCast(h.extra orelse {
        try protocol.writeStatus(out, id, .failure);
        return;
    }));

    if (st.cursor >= st.entries.len) {
        try protocol.writeStatus(out, id, .eof);
        return;
    }

    const end = @min(st.cursor + readdir_page, st.entries.len);
    const page = st.entries[st.cursor..end];
    st.cursor = end;

    var body = Buf.init(a);
    defer body.deinit();
    var w = protocol.Writer.init(&body);
    try w.writeU32(id);
    try w.writeU32(@intCast(page.len));
    for (page) |e| {
        try w.writeString(e.name);
        // `longname` 是给「人类看」的，RFC 明确客户端可以忽略；实际客户端
        // （OpenSSH / WinSCP / FileZilla / rclone）都只用 `filename`。
        // 生成 ls 风格需要日期格式化，收益为零，这里直接重复文件名。
        try w.writeString(e.name);
        try w.writeAttrs(attrsOf(e.size, e.is_dir, e.modified));
    }
    try protocol.frame(out, .name, body.slice());
}

fn handleOpen(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    const id = try r.readU32();
    const raw = try r.readString();
    const flags_raw = try r.readU32();
    _ = try r.readAttrs(); // 创建时的初始属性：虚拟路径无意义，丢弃
    const flags = protocol.OpenFlags.fromInt(flags_raw);

    const n = sess.resolve(raw) catch {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    defer sess.alloc.free(n.path);

    if (flags.write or flags.creat or flags.trunc or flags.append) {
        return openForWrite(c, sess, a, id, n.path, flags, out);
    }

    const t = c.resolver.resolve(n.path) orelse {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    var dctx = driver.Ctx{ .alloc = a, .tag = t.mount_path };
    const f = t.driver.details(&dctx, t.rel) catch |e| {
        try protocol.writeStatus(out, id, statusFor(e));
        return;
    };
    if (f.is_dir) {
        // 目录必须走 OPENDIR；用 OPEN 打开目录是客户端错误。
        try protocol.writeStatus(out, id, .failure);
        return;
    }

    const lk = t.driver.link(&dctx, t.rel, .{}) catch |e| {
        try protocol.writeStatus(out, id, statusFor(e));
        return;
    };
    const owned = try dupLink(c.alloc, lk);
    errdefer freeLink(c.alloc, owned);

    // 没有 text、也没有 fetcher 可用 ⇒ 这个 link 我们取不到字节。
    // 提前在 OPEN 就报错，而不是让每次 READ 都失败。
    if (owned.text == null and owned.local_path == null and owned.url.len == 0) {
        try protocol.writeStatus(out, id, .op_unsupported);
        return;
    }
    if (owned.text == null and c.fetcher == null) {
        try protocol.writeStatus(out, id, .op_unsupported);
        return;
    }

    const st = try c.alloc.create(FileState);
    st.* = .{ .read = .{
        .alloc = c.alloc,
        .link = owned,
        .size = if (f.size > 0) @intCast(f.size) else 0,
    } };
    if (owned.local_size > 0) st.read.size = owned.local_size;

    const path = try sess.alloc.dupe(u8, n.path);
    const hid = sess.addHandle(path, .file) catch |e| {
        FileState.release(st, c.alloc);
        try protocol.writeStatus(out, id, statusFor(e));
        return;
    };
    sess.setExtra(hid, st, FileState.release);

    var hbuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &hbuf, hid, .big);
    try protocol.writeHandle(out, id, &hbuf);
}

/// 写模式 `OPEN`：在 `temp_dir` 里建一个空文件，`WRITE` 往里 pwrite，
/// `CLOSE` 时一次 `put` 到目标驱动。
///
/// **不支持断点续传**：`write` 但没有 `trunc`、且目标已存在时，明确回
/// `op_unsupported`。真要支持得先把现有内容拉到 temp 再覆盖写 —— 那是另一条
/// 完整的下载路径，等有需求再做。主流客户端（rclone / WinSCP / FileZilla）
/// 上传都用 `write|creat|trunc`，不受影响。
fn openForWrite(
    c: *Context,
    sess: *session.Session,
    a: std.mem.Allocator,
    id: u32,
    vpath: []const u8,
    flags: protocol.OpenFlags,
    out: *Buf,
) !void {
    if (c.temp_dir.len == 0) {
        // 没配 temp_dir 就没法攒整份文件，写路径整体不可用。
        try protocol.writeStatus(out, id, .op_unsupported);
        return;
    }

    const t = c.resolver.resolve(vpath) orelse {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    var dctx = driver.Ctx{ .alloc = a, .tag = t.mount_path };

    const exists = if (t.driver.details(&dctx, t.rel)) |_| true else |_| false;

    if (flags.excl and exists) {
        try protocol.writeStatus(out, id, .failure); // O_EXCL 撞上已存在的文件
        return;
    }
    if (!flags.trunc and exists) {
        try protocol.writeStatus(out, id, .op_unsupported); // 续传未实现
        return;
    }

    // ⚠ 分配顺序是**刻意的**：所有可能失败的内存分配都排在 `createFile`
    // 之前。temp 文件一旦建起来，能收掉它的只有两条路径 —— `FileState.release`
    // （addHandle 失败）和 `CLOSE`（成功）。它之后若还有别的分配会失败，fd
    // 与 temp 文件就彻底没人管（temp_dir 在光猫上是 tmpfs，漏一份就吃一份
    // RAM）。所以 vpath、FileState、句柄路径先全部备好。
    const vpath_owned = try c.alloc.dupe(u8, vpath);
    errdefer c.alloc.free(vpath_owned);

    const st = try c.alloc.create(FileState);
    errdefer c.alloc.destroy(st);

    const p = try sess.alloc.dupe(u8, vpath);
    // ⚠ `p` 故意**不**注册 errdefer：所有权在 `addHandle` 调用那一刻就转移
    // 了（失败时它也自己释放），再挂 errdefer 就是二次释放。唯一不走
    // addHandle 的路径（createFile 失败）自己释放它。

    var rnd: [8]u8 = undefined;
    rt.io().random(&rnd);
    const tmp_path = try std.fmt.allocPrint(c.alloc, "{s}/sftp-{x}.tmp", .{ c.temp_dir, std.mem.readInt(u64, &rnd, .big) });
    // 同样不注册 errdefer：createFile 失败那条路径显式释放它；而那条路径回
    // 状态时若再失败，会走 error 返回，此时 errdefer 会造成二次释放。

    // ⚠ `read = true` 不能省：`CreateFileOptions.read` 默认 **false**（只写），
    // 而 CLOSE 时要用 `readPositionalAll` 把内容读出来交给 `put` —— 只写
    // 句柄读会得到 `AccessDenied`，症状是「上传完成但 close 报权限不足」。
    const f = std.Io.Dir.cwd().createFile(rt.io(), tmp_path, .{ .truncate = true, .read = true }) catch |e| {
        log.warn("sftp: cannot create temp {s}: {s}", .{ tmp_path, @errorName(e) });
        c.alloc.free(tmp_path);
        sess.alloc.free(p);
        // 回状态失败就向上抛：那时 vpath / st 由 errdefer 收尾，tmp 与 p
        // 已经手动释放过了，不会有任何人被释放两次。
        try protocol.writeStatus(out, id, .failure);
        return;
    };
    // createFile 之后**不再有**可能失败的分配。这个 errdefer 只在上面那条
    // `try writeStatus` 失败、且 `FileState.release` 还没被调用时才会跑。
    errdefer {
        f.close(rt.io());
        std.Io.Dir.cwd().deleteFile(rt.io(), tmp_path) catch {};
    }

    st.* = .{ .write = .{
        .alloc = c.alloc,
        .file = f,
        .tmp_path = tmp_path,
        .vpath = vpath_owned,
        .append = flags.append,
    } };

    const hid = sess.addHandle(p, .file) catch |e| {
        // 先回状态、再释放：回状态失败时走 error 返回，由 errdefer 收尾
        // fd / temp / vpath / st —— 避免「release 已 free、errdefer 再 free
        // 一次」的二次释放。
        try protocol.writeStatus(out, id, statusFor(e));
        FileState.release(st, c.alloc);
        return;
    };

    var hbuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &hbuf, hid, .big);
    try protocol.writeHandle(out, id, &hbuf);
    // 回完状态才把 st 交给会话：这之后若再失败（OOM），errdefer 与
    // `FileState.release` 不会同时跑到同一个 st 上。
    sess.setExtra(hid, st, FileState.release);
}

fn handleRead(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    const id = try r.readU32();
    const handle = try r.readString();
    const offset = try r.readU64();
    const want = try r.readU32();

    const h = findHandle(sess, handle) orelse {
        try protocol.writeStatus(out, id, .failure);
        return;
    };
    if (h.kind != .file) {
        try protocol.writeStatus(out, id, .failure);
        return;
    }
    const st: *FileState = @ptrCast(@alignCast(h.extra orelse {
        try protocol.writeStatus(out, id, .failure);
        return;
    }));
    // 写句柄不能读：SFTP 允许 `open` 同时带 read+write，但本实现只支持
    // 「要么读、要么写」，混用明确失败而不是返回垃圾。
    const rs = switch (st.*) {
        .read => |*x| x,
        else => {
            try protocol.writeStatus(out, id, .failure);
            return;
        },
    };

    if (offset >= rs.size) {
        try protocol.writeStatus(out, id, .eof);
        return;
    }
    var n: u64 = want;
    if (n > max_read_len) n = max_read_len;
    if (offset + n > rs.size) n = rs.size - offset;

    const data = readAt(c, a, rs, offset, @intCast(n)) catch |e| {
        try protocol.writeStatus(out, id, statusFor(e));
        return;
    };
    try protocol.writeData(out, id, data);
}

/// 从 `st` 的窗口缓存里取 `[offset, offset+len)`。未命中时拉一整个窗口。
fn readAt(c: *Context, a: std.mem.Allocator, st: *ReadState, offset: u64, len: usize) ![]const u8 {
    // 内存源：直接切片，不经过缓存（`text` 已经是连接级内存）。
    if (st.link.text) |t| {
        const start: usize = @intCast(offset);
        const end = @min(start + len, t.len);
        if (start >= t.len) return error.OutOfRange;
        return t[start..end];
    }

    // 缓存命中
    if (st.cache_len > 0 and offset >= st.cache_off and offset + len <= st.cache_off + st.cache_len) {
        const rel: usize = @intCast(offset - st.cache_off);
        return st.cache[rel .. rel + len];
    }

    const f = c.fetcher orelse return error.NotSupported;
    // 拉一整个窗口，但不超过文件末尾。
    var win: u64 = read_window;
    if (offset + win > st.size) win = st.size - offset;
    if (win < len) win = len;

    const got = try f.fetch(c.alloc, st.link, offset, @intCast(win));
    if (st.cache.len > 0) st.alloc.free(st.cache);
    st.cache = got;
    st.cache_off = offset;
    st.cache_len = got.len;

    if (got.len < len) return error.OutOfRange;
    _ = a;
    return got[0..len];
}

fn handleClose(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    const id = try r.readU32();
    const handle = try r.readString();

    const hid = handleId(handle) orelse {
        try protocol.writeStatus(out, id, .failure);
        return;
    };
    const h = sess.getHandle(hid) orelse {
        try protocol.writeStatus(out, id, .failure);
        return;
    };

    // 写句柄：**到 CLOSE 才真正上传**。SFTP 按 offset 随机写，驱动只有整份
    // `put`，所以这里必须先把 temp 文件交出去，再释放句柄。
    if (h.extra) |e| {
        const st: *FileState = @ptrCast(@alignCast(e));
        if (st.* == .write) {
            const w = &st.write;

            // 写入过程中失败过 ⇒ 绝不 `put`。否则会把截断的文件当成完整
            // 文件传上去（容量闸拦下前 N MiB 的场景实测过）。
            if (w.failed) {
                log.warn("sftp: discarding {s} — a previous write failed", .{w.vpath});
                _ = sess.closeHandle(hid);
                try protocol.writeStatus(out, id, .failure);
                return;
            }

            const t = c.resolver.resolve(w.vpath) orelse {
                _ = sess.closeHandle(hid);
                try protocol.writeStatus(out, id, .no_such_file);
                return;
            };
            var dctx = driver.Ctx{ .alloc = a, .tag = t.mount_path };

            var src = TempSource{ .file = w.file, .size = @intCast(w.size) };
            t.driver.put(&dctx, t.rel, src.source()) catch |er| {
                // 上传失败：temp 会在 closeHandle 里被删掉，不占空间。
                log.warn("sftp: put {s} failed: {s}", .{ w.vpath, @errorName(er) });
                _ = sess.closeHandle(hid);
                try protocol.writeStatus(out, id, statusFor(er));
                return;
            };
            log.info("sftp: uploaded {s} ({d} bytes)", .{ w.vpath, w.size });
        }
    }

    if (!sess.closeHandle(hid)) {
        try protocol.writeStatus(out, id, .failure);
        return;
    }
    try protocol.writeStatus(out, id, .ok);
}

fn handleWrite(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    _ = a;
    const id = try r.readU32();
    const handle = try r.readString();
    const offset = try r.readU64();
    const data = try r.readString();

    const h = findHandle(sess, handle) orelse {
        try protocol.writeStatus(out, id, .failure);
        return;
    };
    const st: *FileState = @ptrCast(@alignCast(h.extra orelse {
        try protocol.writeStatus(out, id, .failure);
        return;
    }));
    const w = switch (st.*) {
        .write => |*x| x,
        else => {
            try protocol.writeStatus(out, id, .failure);
            return;
        },
    };

    const at: u64 = if (w.append) w.size else offset;

    // 容量闸：与 `fs/put` / 分片回退路径同一笔账。超限立刻失败，不等把
    // tmpfs 写满 —— 写满时错误会变成 ENOSPC，客户端只看到含糊的 I/O 错误。
    if (c.max_write_bytes > 0 and at + data.len > c.max_write_bytes) {
        log.warn("sftp: write rejected: {d}+{d} > max_write_bytes {d}", .{ at, data.len, c.max_write_bytes });
        w.failed = true;
        try protocol.writeStatus(out, id, .failure);
        return;
    }

    // `writePositionalAll` 自己会循环到写满（0.17 的 `pwrite` 写法），
    // 返回 `!void` —— 不需要在调用方再套一层循环。
    std.Io.File.writePositionalAll(w.file, rt.io(), data, at) catch |e| {
        log.warn("sftp: write to temp failed: {s}", .{@errorName(e)});
        w.failed = true;
        try protocol.writeStatus(out, id, .failure);
        return;
    };
    if (at + data.len > w.size) w.size = at + data.len;

    try protocol.writeStatus(out, id, .ok);
}

fn handleMkdir(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    const id = try r.readU32();
    const raw = try r.readString();
    _ = try r.readAttrs();

    const n = sess.resolve(raw) catch {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    defer sess.alloc.free(n.path);

    const t = c.resolver.resolve(n.path) orelse {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    var dctx = driver.Ctx{ .alloc = a, .tag = t.mount_path };
    t.driver.makeDir(&dctx, t.rel) catch |e| {
        try protocol.writeStatus(out, id, statusFor(e));
        return;
    };
    try protocol.writeStatus(out, id, .ok);
}

fn handleRmdir(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    const id = try r.readU32();
    const raw = try r.readString();

    const n = sess.resolve(raw) catch {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    defer sess.alloc.free(n.path);

    const t = c.resolver.resolve(n.path) orelse {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    var dctx = driver.Ctx{ .alloc = a, .tag = t.mount_path };
    // RMDIR 只删空目录；上游驱动大多不区分，`is_dir = true` 是给 itvsh
    // 这类「文件和目录走不同上游方法」的驱动用的。
    t.driver.remove(&dctx, t.rel, true) catch |e| {
        try protocol.writeStatus(out, id, statusFor(e));
        return;
    };
    try protocol.writeStatus(out, id, .ok);
}

fn handleRemove(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    const id = try r.readU32();
    const raw = try r.readString();

    const n = sess.resolve(raw) catch {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    defer sess.alloc.free(n.path);

    const t = c.resolver.resolve(n.path) orelse {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    var dctx = driver.Ctx{ .alloc = a, .tag = t.mount_path };
    t.driver.remove(&dctx, t.rel, false) catch |e| {
        try protocol.writeStatus(out, id, statusFor(e));
        return;
    };
    try protocol.writeStatus(out, id, .ok);
}

fn handleRename(c: *Context, sess: *session.Session, a: std.mem.Allocator, r: *protocol.Reader, out: *Buf) !void {
    const id = try r.readU32();
    const raw_old = try r.readString();
    const raw_new = try r.readString();

    const o = sess.resolve(raw_old) catch {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    defer sess.alloc.free(o.path);
    const d = sess.resolve(raw_new) catch {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    defer sess.alloc.free(d.path);

    if (std.mem.eql(u8, o.path, "/")) {
        try protocol.writeStatus(out, id, .failure); // 不允许重命名根
        return;
    }

    const old_dir = std.fs.path.dirname(o.path) orelse "/";
    const new_dir = std.fs.path.dirname(d.path) orelse "/";
    const new_name = std.fs.path.basename(d.path);

    const to = c.resolver.resolve(o.path) orelse {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };
    // 目标要解析的是**目录**：vtable 的 `move` 第二个参数是目标目录，条目
    // 保持原名。传目标文件路径会让驱动拼出 `/dst/c.txt/a.txt` 这种东西。
    const td = c.resolver.resolve(new_dir) orelse {
        try protocol.writeStatus(out, id, .no_such_file);
        return;
    };

    // 跨存储的 RENAME 无法表达：move 只在同一驱动内有效。
    if (to.driver.ptr != td.driver.ptr) {
        try protocol.writeStatus(out, id, .op_unsupported);
        return;
    }

    var dctx = driver.Ctx{ .alloc = a, .tag = to.mount_path };

    if (std.mem.eql(u8, old_dir, new_dir)) {
        // 同目录改名：直接 rename（`new_name` 是裸名字）。
        to.driver.rename(&dctx, to.rel, new_name) catch |e| {
            try protocol.writeStatus(out, id, statusFor(e));
            return;
        };
    } else {
        // 跨目录：先 move（保持名字）再改名（如果名字也变了）。
        to.driver.move(&dctx, to.rel, td.rel) catch |e| {
            try protocol.writeStatus(out, id, statusFor(e));
            return;
        };
        const old_name = std.fs.path.basename(o.path);
        if (!std.mem.eql(u8, old_name, new_name)) {
            var dctx2 = driver.Ctx{ .alloc = a, .tag = td.mount_path };
            const moved_rel = try joinVirtual(a, td.rel, old_name);
            to.driver.rename(&dctx2, moved_rel, new_name) catch |e| {
                // 改名失败时源文件已经移动了。如实报错，不假装成功 ——
                // 客户端会看到一个部分完成的状态，这比静默吞掉更容易排查。
                try protocol.writeStatus(out, id, statusFor(e));
                return;
            };
        }
    }
    try protocol.writeStatus(out, id, .ok);
}

fn handleSetstat(
    c: *Context,
    sess: *session.Session,
    a: std.mem.Allocator,
    r: *protocol.Reader,
    out: *Buf,
    by_handle: bool,
) !void {
    _ = c;
    _ = a;
    const id = try r.readU32();

    if (by_handle) {
        // FSETSTAT：句柄存在即可，不需要路径（虚拟路径上没有可写的属性）。
        const handle = try r.readString();
        if (findHandle(sess, handle) == null) {
            try protocol.writeStatus(out, id, .failure);
            return;
        }
    } else {
        const raw = try r.readString();
        const n = sess.resolve(raw) catch {
            try protocol.writeStatus(out, id, .no_such_file);
            return;
        };
        sess.alloc.free(n.path);
    }

    const attrs = try r.readAttrs();
    // `size` 是真实数据操作（截断），不能假装成功；其余字段在虚拟路径上
    // 没有意义（没有 inode、没有属主），接受并忽略 —— 否则 `chmod` 类的
    // 客户端操作会莫名其妙失败。
    if (attrs.size != null) {
        try protocol.writeStatus(out, id, .op_unsupported);
        return;
    }
    try protocol.writeStatus(out, id, .ok);
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// 是不是**虚拟根**。OpenList 的 `/` 是合成的，没有驱动拥有它。
fn isVirtualRoot(vpath: []const u8) bool {
    return std.mem.eql(u8, vpath, "/");
}

/// 把 temp 文件包成 `driver.put` 要的 `model.Source`（随机读）。
const TempSource = struct {
    file: std.Io.File,
    size: i64,

    fn sizeFn(p: *anyopaque) i64 {
        const self: *TempSource = @ptrCast(@alignCast(p));
        return self.size;
    }

    fn readAtFn(p: *anyopaque, offset: u64, buf: []u8) anyerror!usize {
        const self: *TempSource = @ptrCast(@alignCast(p));
        return std.Io.File.readPositionalAll(self.file, rt.io(), buf, offset);
    }

    fn source(self: *TempSource) model.Source {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = model.Source.VTable{ .size = sizeFn, .readAt = readAtFn };
};

/// 拼一个**虚拟路径**（永远用 `/` 分隔）。
///
/// ⚠ 不能用 `std.fs.path.join`：它按宿主平台的分隔符拼，在 Windows 上会产出
/// `/dst\a.txt`。虚拟路径与宿主平台无关，一律 `/`。
fn joinVirtual(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, dir, "/")) return std.fmt.allocPrint(a, "/{s}", .{name});
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

/// 把句柄串（4 字节大端）还原成 id。
fn handleId(h: []const u8) ?u32 {
    if (h.len != 4) return null;
    return (@as(u32, h[0]) << 24) | (@as(u32, h[1]) << 16) |
        (@as(u32, h[2]) << 8) | @as(u32, h[3]);
}

fn findHandle(sess: *session.Session, h: []const u8) ?*session.Handle {
    const id = handleId(h) orelse return null;
    return sess.getHandle(id);
}

fn attrsOf(size: i64, is_dir: bool, modified: i64) protocol.Attributes {
    // 目录 0o040755，文件 0o100644 —— 与 OpenSSH 的默认呈现一致。权限位是
    // 装饰性的：本工程是单管理员，驱动层没有 chmod 概念。
    const mode: u32 = if (is_dir) 0o040755 else 0o100644;
    const ts: u32 = if (modified > 0) @intCast(@min(modified, 0xFFFF_FFFF)) else 0;
    return .{
        .size = if (size > 0) @intCast(size) else 0,
        .uid = 0,
        .gid = 0,
        .permissions = mode,
        .atime = ts,
        .mtime = ts,
    };
}

fn statusFor(e: anyerror) protocol.Status {
    return switch (e) {
        error.NotFound, error.FileNotFound, error.ObjectNotFound => .no_such_file,
        error.AccessDenied, error.PermissionDenied => .permission_denied,
        error.NotSupported, error.NotImplemented, error.TooManyHandles => .op_unsupported,
        error.OutOfMemory => .failure,
        else => .failure,
    };
}

/// `SSH_FXP_NAME` 带一条记录。`REALPATH` 用它回单条路径。
fn writeNameOne(
    out: *Buf,
    a: std.mem.Allocator,
    id: u32,
    name: []const u8,
    size: i64,
    is_dir: bool,
    modified: i64,
) !void {
    var body = Buf.init(a);
    defer body.deinit();
    var w = protocol.Writer.init(&body);
    try w.writeU32(id);
    try w.writeU32(1);
    try w.writeString(name);
    try w.writeString(name);
    try w.writeAttrs(attrsOf(size, is_dir, modified));
    try protocol.frame(out, .name, body.slice());
}

// ---------------------------------------------------------------------------
// 测试：内存驱动 + 内存 fetcher
// ---------------------------------------------------------------------------

const testing = std.testing;

const Entry = struct {
    path: []u8,
    data: []u8,
    is_dir: bool,
    modified: i64 = 1_700_000_000,
};

/// 最小内存文件系统，只实现 handler 用到的那几个 vtable 槽位。
/// 目录树用扁平数组表示（测试里最多百来个条目），路径都是绝对的。
const MemDriver = struct {
    alloc: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// `remove` 收到的 `is_dir` 参数，断言用。
    last_remove_is_dir: ?bool = null,
    /// true 时 `link` 返回 `url`（逼 handler 走 fetcher），否则返回 `text`。
    use_url: bool = false,

    fn deinit(self: *MemDriver) void {
        for (self.entries.items) |e| {
            self.alloc.free(e.path);
            self.alloc.free(e.data);
        }
        self.entries.deinit(self.alloc);
    }

    fn addDir(self: *MemDriver, path: []const u8) !void {
        try self.entries.append(self.alloc, .{
            .path = try self.alloc.dupe(u8, path),
            .data = try self.alloc.alloc(u8, 0),
            .is_dir = true,
        });
    }

    fn addFile(self: *MemDriver, path: []const u8, data: []const u8) !void {
        try self.entries.append(self.alloc, .{
            .path = try self.alloc.dupe(u8, path),
            .data = try self.alloc.dupe(u8, data),
            .is_dir = false,
        });
    }

    fn find(self: *MemDriver, path: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }

    fn asDriver(self: *MemDriver) driver.Driver {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = driver.Driver.VTable{
        .name = nameFn,
        .init = initFn,
        .deinit = deinitFn,
        .list = listFn,
        .details = detailsFn,
        .link = linkFn,
        .makeDir = makeDirFn,
        .move = moveFn,
        .rename = renameFn,
        .remove = removeFn,
        .put = putFn,
    };

    fn nameFn(_: *anyopaque) []const u8 {
        return "Mem";
    }
    fn initFn(_: *anyopaque, _: *driver.Ctx) anyerror!void {}
    fn deinitFn(_: *anyopaque, _: *driver.Ctx) void {}

    fn listFn(ptr: *anyopaque, ctx: *driver.Ctx, dir: []const u8) anyerror![]model.Obj {
        const self: *MemDriver = @ptrCast(@alignCast(ptr));
        var out: std.ArrayListUnmanaged(model.Obj) = .empty;
        for (self.entries.items) |e| {
            const parent = std.fs.path.dirname(e.path) orelse "/";
            if (!std.mem.eql(u8, parent, dir)) continue;
            try out.append(ctx.alloc, .{
                .name = std.fs.path.basename(e.path),
                .size = @intCast(e.data.len),
                .is_dir = e.is_dir,
                .modified = e.modified,
            });
        }
        return out.toOwnedSlice(ctx.alloc);
    }

    fn detailsFn(ptr: *anyopaque, ctx: *driver.Ctx, path: []const u8) anyerror!model.File {
        _ = ctx;
        const self: *MemDriver = @ptrCast(@alignCast(ptr));
        const e = self.find(path) orelse return error.NotFound;
        return .{
            .name = std.fs.path.basename(path),
            .size = @intCast(e.data.len),
            .is_dir = e.is_dir,
            .modified = e.modified,
        };
    }

    fn linkFn(ptr: *anyopaque, ctx: *driver.Ctx, path: []const u8, args: model.LinkArgs) anyerror!model.Link {
        _ = ctx;
        _ = args;
        const self: *MemDriver = @ptrCast(@alignCast(ptr));
        const e = self.find(path) orelse return error.NotFound;
        if (e.is_dir) return error.NotSupported;
        if (self.use_url) return .{ .url = path };
        // 内存源：handler 会 dup 一份，不依赖请求 arena 的生命周期。
        return .{ .text = e.data, .proxy = true };
    }

    fn makeDirFn(ptr: *anyopaque, ctx: *driver.Ctx, dir: []const u8) anyerror!void {
        _ = ctx;
        const self: *MemDriver = @ptrCast(@alignCast(ptr));
        if (self.find(dir) != null) return error.NotSupported;
        try self.addDir(dir);
    }

    fn moveFn(ptr: *anyopaque, ctx: *driver.Ctx, src: []const u8, dst_dir: []const u8) anyerror!void {
        _ = ctx;
        const self: *MemDriver = @ptrCast(@alignCast(ptr));
        const e = self.find(src) orelse return error.NotFound;
        const name = std.fs.path.basename(src);
        const fresh = try joinVirtual(self.alloc, dst_dir, name);
        self.alloc.free(e.path);
        e.path = fresh;
    }

    fn renameFn(ptr: *anyopaque, ctx: *driver.Ctx, src: []const u8, new_name: []const u8) anyerror!void {
        _ = ctx;
        const self: *MemDriver = @ptrCast(@alignCast(ptr));
        const e = self.find(src) orelse return error.NotFound;
        const parent = std.fs.path.dirname(src) orelse "/";
        const fresh = try joinVirtual(self.alloc, parent, new_name);
        self.alloc.free(e.path);
        e.path = fresh;
    }

    fn removeFn(ptr: *anyopaque, ctx: *driver.Ctx, path: []const u8, is_dir: bool) anyerror!void {
        _ = ctx;
        const self: *MemDriver = @ptrCast(@alignCast(ptr));
        self.last_remove_is_dir = is_dir;
        for (self.entries.items, 0..) |e, i| {
            if (!std.mem.eql(u8, e.path, path)) continue;
            self.alloc.free(e.path);
            self.alloc.free(e.data);
            _ = self.entries.orderedRemove(i);
            return;
        }
        return error.NotFound;
    }

    fn putFn(ptr: *anyopaque, ctx: *driver.Ctx, dst: []const u8, src: model.Source) anyerror!void {
        _ = ptr;
        _ = ctx;
        _ = dst;
        _ = src;
        return error.NotSupported; // 写路径本轮不接
    }
};

/// 内存 fetcher：按 `link.url` 找到条目再切一段。用于覆盖窗口缓存路径。
const MemFetcher = struct {
    mem: *MemDriver,
    calls: usize = 0,

    fn fetcher(self: *MemFetcher) Fetcher {
        return .{ .ctx = self, .fetchFn = fetchFn };
    }

    fn fetchFn(ctx: *anyopaque, alloc: std.mem.Allocator, link: model.Link, offset: u64, len: u32) anyerror![]u8 {
        const self: *MemFetcher = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const e = self.mem.find(link.url) orelse return error.NotFound;
        const start: usize = @intCast(offset);
        if (start >= e.data.len) return error.OutOfRange;
        const end = @min(start + len, e.data.len);
        return alloc.dupe(u8, e.data[start..end]);
    }
};

fn resolveFromMem(ctx: *anyopaque, vpath: []const u8) ?Target {
    const self: *MemDriver = @ptrCast(@alignCast(ctx));
    return .{ .driver = self.asDriver(), .rel = vpath, .mount_path = "/" };
}

/// 虚拟根在测试里固定只暴露一个名字 `mem`。
fn listRootFromMem(ctx: *anyopaque, alloc: std.mem.Allocator) anyerror![][]u8 {
    _ = ctx;
    const out = try alloc.alloc([]u8, 1);
    errdefer alloc.free(out);
    out[0] = try alloc.dupe(u8, "mem");
    return out;
}

/// 构造并发送一个请求，返回解析后的回复包。`out` 由调用方持有。
fn call(
    c: *Context,
    sess: *session.Session,
    a: std.mem.Allocator,
    pt: protocol.PacketType,
    body: []const u8,
    out: *Buf,
) !protocol.Packet {
    var wire = Buf.init(a);
    defer wire.deinit();
    try protocol.frame(&wire, pt, body);
    const pkt = (try protocol.parse(wire.slice())).?;
    try dispatch(c, sess, a, pkt, out);
    return (try protocol.parse(out.slice())).?;
}

fn expectStatus(pkt: protocol.Packet, want: protocol.Status) !void {
    try testing.expectEqual(protocol.PacketType.status, pkt.packet_type);
    var r = protocol.Reader.init(pkt.body);
    _ = try r.readU32();
    const code = try r.readU32();
    try testing.expectEqual(@intFromEnum(want), code);
}

/// 测试用固定夹具：一个内存驱动 + 一个会话 + 一个 arena。
const Fixture = struct {
    mem: MemDriver,
    sess: session.Session,
    c: Context,
    arena: std.heap.ArenaAllocator,

    fn init(use_url: bool) Fixture {
        return .{
            .mem = .{ .alloc = testing.allocator, .use_url = use_url },
            .sess = session.Session.init(testing.allocator),
            .c = undefined,
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
        };
    }

    fn start(self: *Fixture) void {
        self.c = .{
            .alloc = testing.allocator,
            .resolver = .{
                .ctx = &self.mem,
                .resolveFn = resolveFromMem,
                .listRootFn = listRootFromMem,
            },
        };
    }

    fn deinit(self: *Fixture) void {
        self.sess.deinit();
        self.mem.deinit();
        self.arena.deinit();
    }

    fn a(self: *Fixture) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// 发一个请求并在返回前把 arena 重置（回复内容在 `out` 里，`out` 也用
    /// 同一个 arena，所以调用方必须在 reset 之前读完）。
    fn send(self: *Fixture, pt: protocol.PacketType, body: []const u8, out: *Buf) !protocol.Packet {
        return call(&self.c, &self.sess, self.a(), pt, body, out);
    }
};

test "sftp/handler: INIT 回 VERSION 3 且不宣告扩展" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();

    var out = Buf.init(f.a());
    defer out.deinit();
    const pkt = try f.send(.init, &[_]u8{ 0, 0, 0, 3 }, &out);
    try testing.expectEqual(protocol.PacketType.version, pkt.packet_type);

    var r = protocol.Reader.init(pkt.body);
    try testing.expectEqual(@as(u32, 3), try r.readU32());
    try testing.expectEqual(@as(usize, 0), r.remaining()); // 没有扩展对
    try testing.expect(f.sess.negotiated);
}

test "sftp/handler: REALPATH 归一化且不要求目标存在" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();

    var body = Buf.init(testing.allocator);
    defer body.deinit();
    var w = protocol.Writer.init(&body);
    try w.writeU32(7);
    try w.writeString("/a/./b/../c");

    var out = Buf.init(f.a());
    defer out.deinit();
    const pkt = try f.send(.realpath, body.slice(), &out);
    try testing.expectEqual(protocol.PacketType.name, pkt.packet_type);

    var r = protocol.Reader.init(pkt.body);
    try testing.expectEqual(@as(u32, 7), try r.readU32());
    try testing.expectEqual(@as(u32, 1), try r.readU32());
    try testing.expectEqualStrings("/a/c", try r.readString());
    try testing.expectEqualStrings("/a/c", try r.readString()); // longname
}

test "sftp/handler: STAT 存在 / 不存在" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();
    try f.mem.addFile("/a.txt", "hello");

    {
        var body = Buf.init(testing.allocator);
        defer body.deinit();
        var w = protocol.Writer.init(&body);
        try w.writeU32(1);
        try w.writeString("/a.txt");

        var out = Buf.init(f.a());
        defer out.deinit();
        const pkt = try f.send(.stat, body.slice(), &out);
        try testing.expectEqual(protocol.PacketType.attrs, pkt.packet_type);
        var r = protocol.Reader.init(pkt.body);
        try testing.expectEqual(@as(u32, 1), try r.readU32());
        const attrs = try r.readAttrs();
        try testing.expectEqual(@as(u64, 5), attrs.size.?);
        try testing.expectEqual(@as(u32, 0o100644), attrs.permissions.?);
    }
    {
        var body = Buf.init(testing.allocator);
        defer body.deinit();
        var w = protocol.Writer.init(&body);
        try w.writeU32(2);
        try w.writeString("/missing");

        var out = Buf.init(f.a());
        defer out.deinit();
        try expectStatus(try f.send(.stat, body.slice(), &out), .no_such_file);
    }
}

test "sftp/handler: OPENDIR + READDIR 分页 + 末尾 eof" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();
    try f.mem.addDir("/d");
    var i: usize = 0;
    while (i < 70) : (i += 1) {
        const name = try std.fmt.allocPrint(testing.allocator, "/d/f{d}.txt", .{i});
        defer testing.allocator.free(name);
        try f.mem.addFile(name, "x");
    }

    var obody = Buf.init(testing.allocator);
    defer obody.deinit();
    var ow = protocol.Writer.init(&obody);
    try ow.writeU32(1);
    try ow.writeString("/d");

    var oout = Buf.init(f.a());
    defer oout.deinit();
    const opkt = try f.send(.opendir, obody.slice(), &oout);
    try testing.expectEqual(protocol.PacketType.handle, opkt.packet_type);
    var or_ = protocol.Reader.init(opkt.body);
    try testing.expectEqual(@as(u32, 1), try or_.readU32());
    const handle = try or_.readString();
    try testing.expectEqual(@as(usize, 4), handle.len);

    // 句柄串要复制出来：下面的请求会把 arena 重置。
    var hcopy: [4]u8 = undefined;
    @memcpy(&hcopy, handle);

    var rbody = Buf.init(testing.allocator);
    defer rbody.deinit();
    var rw = protocol.Writer.init(&rbody);
    try rw.writeU32(2);
    try rw.writeString(&hcopy);

    // 第一页 64 条
    {
        var rout = Buf.init(f.a());
        defer rout.deinit();
        const p = try f.send(.readdir, rbody.slice(), &rout);
        try testing.expectEqual(protocol.PacketType.name, p.packet_type);
        var r = protocol.Reader.init(p.body);
        _ = try r.readU32();
        try testing.expectEqual(@as(u32, 64), try r.readU32());
    }
    // 第二页 6 条
    {
        var rout = Buf.init(f.a());
        defer rout.deinit();
        const p = try f.send(.readdir, rbody.slice(), &rout);
        var r = protocol.Reader.init(p.body);
        _ = try r.readU32();
        try testing.expectEqual(@as(u32, 6), try r.readU32());
    }
    // 第三页 eof
    {
        var rout = Buf.init(f.a());
        defer rout.deinit();
        try expectStatus(try f.send(.readdir, rbody.slice(), &rout), .eof);
    }
}

test "sftp/handler: MKDIR / REMOVE / RMDIR 的 is_dir 传参" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();
    try f.mem.addFile("/gone.txt", "x");
    try f.mem.addDir("/emptydir");

    {
        var body = Buf.init(testing.allocator);
        defer body.deinit();
        var w = protocol.Writer.init(&body);
        try w.writeU32(1);
        try w.writeString("/newdir");
        try w.writeAttrs(.{});

        var out = Buf.init(f.a());
        defer out.deinit();
        try expectStatus(try f.send(.mkdir, body.slice(), &out), .ok);
        try testing.expect(f.mem.find("/newdir") != null);
    }
    {
        var body = Buf.init(testing.allocator);
        defer body.deinit();
        var w = protocol.Writer.init(&body);
        try w.writeU32(2);
        try w.writeString("/gone.txt");

        var out = Buf.init(f.a());
        defer out.deinit();
        try expectStatus(try f.send(.remove, body.slice(), &out), .ok);
        try testing.expectEqual(false, f.mem.last_remove_is_dir.?);
    }
    {
        var body = Buf.init(testing.allocator);
        defer body.deinit();
        var w = protocol.Writer.init(&body);
        try w.writeU32(3);
        try w.writeString("/emptydir");

        var out = Buf.init(f.a());
        defer out.deinit();
        try expectStatus(try f.send(.rmdir, body.slice(), &out), .ok);
        try testing.expectEqual(true, f.mem.last_remove_is_dir.?);
    }
}

test "sftp/handler: RENAME 同目录只换名字" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();
    try f.mem.addFile("/a.txt", "x");

    var body = Buf.init(testing.allocator);
    defer body.deinit();
    var w = protocol.Writer.init(&body);
    try w.writeU32(1);
    try w.writeString("/a.txt");
    try w.writeString("/b.txt");

    var out = Buf.init(f.a());
    defer out.deinit();
    try expectStatus(try f.send(.rename, body.slice(), &out), .ok);
    try testing.expect(f.mem.find("/a.txt") == null);
    try testing.expect(f.mem.find("/b.txt") != null);
}

test "sftp/handler: RENAME 跨目录（move + rename 两步）" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();
    try f.mem.addDir("/dst");
    try f.mem.addFile("/a.txt", "x");

    var body = Buf.init(testing.allocator);
    defer body.deinit();
    var w = protocol.Writer.init(&body);
    try w.writeU32(1);
    try w.writeString("/a.txt");
    try w.writeString("/dst/c.txt");

    var out = Buf.init(f.a());
    defer out.deinit();
    try expectStatus(try f.send(.rename, body.slice(), &out), .ok);
    try testing.expect(f.mem.find("/a.txt") == null);
    try testing.expect(f.mem.find("/dst/c.txt") != null);
}

test "sftp/handler: OPEN + READ（text 源）+ CLOSE + 关闭后失效" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();
    try f.mem.addFile("/a.txt", "hello world");

    // OPEN 只读
    var obody = Buf.init(testing.allocator);
    defer obody.deinit();
    var ow = protocol.Writer.init(&obody);
    try ow.writeU32(1);
    try ow.writeString("/a.txt");
    try ow.writeU32(0x0000_0001); // SSH_FXF_READ
    try ow.writeAttrs(.{});

    var oout = Buf.init(f.a());
    defer oout.deinit();
    const opkt = try f.send(.open, obody.slice(), &oout);
    try testing.expectEqual(protocol.PacketType.handle, opkt.packet_type);
    var or_ = protocol.Reader.init(opkt.body);
    _ = try or_.readU32();
    const handle = try or_.readString();
    var hcopy: [4]u8 = undefined;
    @memcpy(&hcopy, handle);

    // READ 0..5 → "hello"
    var rbody = Buf.init(testing.allocator);
    defer rbody.deinit();
    var rw = protocol.Writer.init(&rbody);
    try rw.writeU32(2);
    try rw.writeString(&hcopy);
    try rw.writeU64(0);
    try rw.writeU32(5);

    {
        var out = Buf.init(f.a());
        defer out.deinit();
        const pkt = try f.send(.read, rbody.slice(), &out);
        try testing.expectEqual(protocol.PacketType.data, pkt.packet_type);
        var r = protocol.Reader.init(pkt.body);
        try testing.expectEqual(@as(u32, 2), try r.readU32());
        try testing.expectEqualStrings("hello", try r.readString());
    }

    // READ offset 越界 → eof
    var ebody = Buf.init(testing.allocator);
    defer ebody.deinit();
    var ew = protocol.Writer.init(&ebody);
    try ew.writeU32(3);
    try ew.writeString(&hcopy);
    try ew.writeU64(100);
    try ew.writeU32(5);
    {
        var out = Buf.init(f.a());
        defer out.deinit();
        try expectStatus(try f.send(.read, ebody.slice(), &out), .eof);
    }

    // CLOSE
    var cbody = Buf.init(testing.allocator);
    defer cbody.deinit();
    var cw = protocol.Writer.init(&cbody);
    try cw.writeU32(4);
    try cw.writeString(&hcopy);
    {
        var out = Buf.init(f.a());
        defer out.deinit();
        try expectStatus(try f.send(.close, cbody.slice(), &out), .ok);
        try testing.expectEqual(@as(usize, 0), f.sess.openCount());
    }

    // 关闭后再 READ → failure
    {
        var out = Buf.init(f.a());
        defer out.deinit();
        try expectStatus(try f.send(.read, rbody.slice(), &out), .failure);
    }
}

test "sftp/handler: OPEN 写模式回 op_unsupported（明确不静默）" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();
    try f.mem.addFile("/a.txt", "x");

    var body = Buf.init(testing.allocator);
    defer body.deinit();
    var w = protocol.Writer.init(&body);
    try w.writeU32(1);
    try w.writeString("/new.txt");
    try w.writeU32(0x0000_001A); // WRITE|CREAT|TRUNC
    try w.writeAttrs(.{});

    var out = Buf.init(f.a());
    defer out.deinit();
    try expectStatus(try f.send(.open, body.slice(), &out), .op_unsupported);
}

test "sftp/handler: SETSTAT 拒绝 size、接受其余字段" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();
    try f.mem.addFile("/a.txt", "x");

    {
        var body = Buf.init(testing.allocator);
        defer body.deinit();
        var w = protocol.Writer.init(&body);
        try w.writeU32(1);
        try w.writeString("/a.txt");
        try w.writeAttrs(.{ .size = 0 });

        var out = Buf.init(f.a());
        defer out.deinit();
        try expectStatus(try f.send(.setstat, body.slice(), &out), .op_unsupported);
    }
    {
        var body = Buf.init(testing.allocator);
        defer body.deinit();
        var w = protocol.Writer.init(&body);
        try w.writeU32(2);
        try w.writeString("/a.txt");
        try w.writeAttrs(.{ .permissions = 0o600 });

        var out = Buf.init(f.a());
        defer out.deinit();
        try expectStatus(try f.send(.setstat, body.slice(), &out), .ok);
    }
}

test "sftp/handler: 未知包类型回 op_unsupported 且带正确 id" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();

    var body = Buf.init(testing.allocator);
    defer body.deinit();
    var w = protocol.Writer.init(&body);
    try w.writeU32(99);
    try w.writeString("/x");

    var out = Buf.init(f.a());
    defer out.deinit();
    const pkt = try f.send(.readlink, body.slice(), &out);
    try expectStatus(pkt, .op_unsupported);
    var r = protocol.Reader.init(pkt.body);
    try testing.expectEqual(@as(u32, 99), try r.readU32());
}

test "sftp/handler: 窗口缓存命中后 fetcher 不再被调用" {
    var f = Fixture.init(true); // use_url = true ⇒ 必须走 fetcher
    f.start();
    defer f.deinit();
    try f.mem.addFile("/big.bin", "0123456789abcdef");

    var mf = MemFetcher{ .mem = &f.mem };
    f.c.fetcher = mf.fetcher();

    // OPEN
    var obody = Buf.init(testing.allocator);
    defer obody.deinit();
    var ow = protocol.Writer.init(&obody);
    try ow.writeU32(1);
    try ow.writeString("/big.bin");
    try ow.writeU32(0x0000_0001);
    try ow.writeAttrs(.{});

    var oout = Buf.init(f.a());
    defer oout.deinit();
    const opkt = try f.send(.open, obody.slice(), &oout);
    try testing.expectEqual(protocol.PacketType.handle, opkt.packet_type);
    var or_ = protocol.Reader.init(opkt.body);
    _ = try or_.readU32();
    var hcopy: [4]u8 = undefined;
    @memcpy(&hcopy, try or_.readString());

    // 第一次 READ 0..8 → 拉整个 16 字节窗口
    var b1 = Buf.init(testing.allocator);
    defer b1.deinit();
    var w1 = protocol.Writer.init(&b1);
    try w1.writeU32(2);
    try w1.writeString(&hcopy);
    try w1.writeU64(0);
    try w1.writeU32(8);
    {
        var out = Buf.init(f.a());
        defer out.deinit();
        const pkt = try f.send(.read, b1.slice(), &out);
        var r = protocol.Reader.init(pkt.body);
        _ = try r.readU32();
        try testing.expectEqualStrings("01234567", try r.readString());
    }
    try testing.expectEqual(@as(usize, 1), mf.calls);

    // 第二次 READ 8..16 → 命中窗口，不再请求
    var b2 = Buf.init(testing.allocator);
    defer b2.deinit();
    var w2 = protocol.Writer.init(&b2);
    try w2.writeU32(3);
    try w2.writeString(&hcopy);
    try w2.writeU64(8);
    try w2.writeU32(8);
    {
        var out = Buf.init(f.a());
        defer out.deinit();
        const pkt = try f.send(.read, b2.slice(), &out);
        var r = protocol.Reader.init(pkt.body);
        _ = try r.readU32();
        try testing.expectEqualStrings("89abcdef", try r.readString());
    }
    try testing.expectEqual(@as(usize, 1), mf.calls);
}

test "sftp/handler: 虚拟根可 STAT 且可 OPENDIR（列挂载点）" {
    var f = Fixture.init(false);
    f.start();
    defer f.deinit();

    // STAT / → 目录属性
    {
        var body = Buf.init(testing.allocator);
        defer body.deinit();
        var w = protocol.Writer.init(&body);
        try w.writeU32(1);
        try w.writeString("/");

        var out = Buf.init(f.a());
        defer out.deinit();
        const pkt = try f.send(.stat, body.slice(), &out);
        try testing.expectEqual(protocol.PacketType.attrs, pkt.packet_type);
        var r = protocol.Reader.init(pkt.body);
        _ = try r.readU32();
        const attrs = try r.readAttrs();
        try testing.expectEqual(@as(u32, 0o040755), attrs.permissions.?);
    }

    // OPENDIR / → 只含一个挂载名
    var obody = Buf.init(testing.allocator);
    defer obody.deinit();
    var ow = protocol.Writer.init(&obody);
    try ow.writeU32(2);
    try ow.writeString("/");

    var oout = Buf.init(f.a());
    defer oout.deinit();
    const opkt = try f.send(.opendir, obody.slice(), &oout);
    try testing.expectEqual(protocol.PacketType.handle, opkt.packet_type);
    var or_ = protocol.Reader.init(opkt.body);
    _ = try or_.readU32();
    var hcopy: [4]u8 = undefined;
    @memcpy(&hcopy, try or_.readString());

    var rbody = Buf.init(testing.allocator);
    defer rbody.deinit();
    var rw = protocol.Writer.init(&rbody);
    try rw.writeU32(3);
    try rw.writeString(&hcopy);

    {
        var out = Buf.init(f.a());
        defer out.deinit();
        const pkt = try f.send(.readdir, rbody.slice(), &out);
        try testing.expectEqual(protocol.PacketType.name, pkt.packet_type);
        var r = protocol.Reader.init(pkt.body);
        _ = try r.readU32();
        try testing.expectEqual(@as(u32, 1), try r.readU32());
        try testing.expectEqualStrings("mem", try r.readString());
        _ = try r.readString(); // longname
        const a = try r.readAttrs();
        try testing.expectEqual(@as(u32, 0o040755), a.permissions.?);
    }
    // 第二页 EOF
    {
        var out = Buf.init(f.a());
        defer out.deinit();
        try expectStatus(try f.send(.readdir, rbody.slice(), &out), .eof);
    }
}
