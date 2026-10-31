//! SFTP 会话状态：句柄表 + 虚拟路径归一化。
//!
//! 这一层同样不感知 SSH，也不感知具体驱动——它只回答两个问题：
//!
//!   1. 客户端发来的这条路径，归一化成虚拟路径之后是什么？
//!   2. 这个句柄 id 对应哪个路径、是文件还是目录？
//!
//! ## 为什么路径归一化是「纯词法」的
//!
//! OpenList 的路径是**虚拟路径**（`/quark/Movies`、`/189/backup`），背后是
//! 十几个异构驱动，没有统一的本地目录树。所以这里不能也不该去 `stat`：
//!
//!   - 一旦碰文件系统就会跟随符号链接，而符号链接正是绕过纯文本检查的通道；
//!   - 驱动本身可能是云盘 API，`stat` 一次就是一次网络往返，归一化不该有 I/O。
//!
//! 归一化只做字符串处理：折叠 `//`、消掉 `.`、用 `..` 回退，**不访问任何驱动**。
//!
//! ## `..` 越过根时钳到根，而不是报错
//!
//! 对本地文件系统，`/../etc/passwd` 必须拒绝——那是逃逸。但虚拟路径的 `/`
//! 就是虚拟根，`/../x` 归一化成 `/x` 之后仍在虚拟根之内，**不存在逃逸**。
//! 因此这里选择钳制（并记一个 `clamped` 标志供日志用），而不是拒绝：
//! 部分客户端（尤其 Windows 资源管理器）会发带 `..` 的冗余路径，拒绝它们
//! 只会造成「能用但莫名其妙失败」。
//!
//! 真正需要拒绝的是畸形输入：NUL 字节、超长路径。

const std = @import("std");
const Buf = @import("../util/buf.zig").Buf;
const List = @import("../util/buf.zig").List;

/// 与 `protocol.max_path_len` 保持一致。
pub const max_path_len: usize = 4096;

/// 单个会话同时打开的句柄上限。真实客户端（WinSCP / FileZilla / rclone）
/// 的并发句柄数是个位数；512 留了两个数量级的余量，同时挡住「开一万个句柄
/// 把内存吃光」这种构造输入。
pub const max_handles: usize = 512;

pub const PathError = error{
    PathTooLong,
    /// 路径里含 NUL。SFTP 的 `string` 类型允许任意字节，但含 NUL 的路径在
    /// 任何下游（日志、驱动 API、JSON）都会出问题，所以在入口就拒绝。
    InvalidPath,
    OutOfMemory,
};

/// 归一化结果。`path` 由调用方负责释放（或用 arena 一次性回收）。
pub const Normalized = struct {
    path: []u8,
    /// 是否发生过 `..` 越过根而被钳制。只用于日志，不影响语义。
    clamped: bool,
};

/// 把客户端路径归一化成以 `/` 开头、无 `.` / `..` / 重复斜杠的虚拟路径。
///
/// 空路径与 `"/"` 都归一化成 `"/"`（REALPATH 常见用法）。
pub fn normalize(alloc: std.mem.Allocator, requested: []const u8) PathError!Normalized {
    if (requested.len > max_path_len) return error.PathTooLong;
    if (std.mem.indexOfScalar(u8, requested, 0) != null) return error.InvalidPath;

    var out = Buf.init(alloc);
    // `toOwned` 是**复制**（见 util/buf.zig），所以临时缓冲必须自己释放。
    defer out.deinit();

    // 记录每一段前导 `/` 在 out 里的位置，`..` 时据此截断。
    var marks = List(usize).init(alloc);
    defer marks.deinit();

    var clamped = false;
    var it = std.mem.splitScalar(u8, requested, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (marks.len == 0) {
                // 已经在根上，再退就是钳制（不是错误，见文件头注）。
                clamped = true;
                continue;
            }
            const start = marks.slice()[marks.len - 1];
            marks.len -= 1;
            out.len = start; // 截断掉这一段（含它的前导 `/`）
            continue;
        }
        try marks.append(out.len);
        try out.appendByte('/');
        try out.append(seg);
    }

    // 全被消掉（`""`、`"/"`、`"/.."`）时落到虚拟根。
    if (out.len == 0) try out.appendByte('/');

    return .{ .path = try out.toOwned(), .clamped = clamped };
}

pub const HandleKind = enum { file, dir };

pub const Handle = struct {
    id: u32,
    /// 归一化后的虚拟路径。**Session 拥有这块内存**，`closeHandle` / `deinit`
    /// 时释放。
    path: []u8,
    kind: HandleKind,
    /// 上层（`sftp/handler.zig`）挂的私有状态：读句柄的 `link` 与窗口缓存、
    /// 目录的条目快照等。本文件**不认识**它的类型，只在关闭时回调 `release`
    /// 让上层自己释放 —— 这样会话层不必 import `model.zig` / `driver.zig`，
    /// 保持零依赖、可纯单测。
    extra: ?*anyopaque = null,
    release: ?*const fn (extra: *anyopaque, alloc: std.mem.Allocator) void = null,
};

/// 单条 SFTP 连接的会话状态。
///
/// 生命周期与连接一致；`alloc` 用连接级 allocator（不是请求级 arena），
/// 因为句柄要跨多个请求存活。
pub const Session = struct {
    alloc: std.mem.Allocator,
    handles: std.AutoHashMapUnmanaged(u32, Handle) = .empty,
    next_handle: u32 = 1,
    /// 客户端 `INIT` 被应答之前，任何请求都是协议违例。
    negotiated: bool = false,

    pub fn init(alloc: std.mem.Allocator) Session {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Session) void {
        self.clearHandles();
        self.handles.deinit(self.alloc);
        self.* = .{ .alloc = self.alloc };
    }

    /// 清空会话但保留 allocator —— 客户端重发 `INIT`（重新协商）时用。
    ///
    /// 协议允许客户端在连接中途重新 INIT。不处理的话，旧句柄会一直挂着，
    /// 直到连接断开才释放；对长连接（rsync 类工具）就是缓慢的内存泄漏。
    pub fn reset(self: *Session) void {
        self.clearHandles();
        self.handles.clearRetainingCapacity();
        self.next_handle = 1;
        self.negotiated = false;
    }

    /// 释放所有句柄的 path 与上层挂的 extra。`deinit` 与 `reset` 共用。
    fn clearHandles(self: *Session) void {
        var it = self.handles.valueIterator();
        while (it.next()) |h| {
            if (h.release) |f| {
                if (h.extra) |e| f(e, self.alloc);
                h.release = null;
                h.extra = null;
            }
            self.alloc.free(h.path);
        }
    }

    pub fn openCount(self: Session) usize {
        return self.handles.count();
    }

    /// 登记一个已打开的对象，**接管 `path` 的所有权**。
    pub fn addHandle(self: *Session, path: []u8, kind: HandleKind) !u32 {
        if (self.handles.count() >= max_handles) {
            self.alloc.free(path);
            return error.TooManyHandles;
        }
        // id 从 1 开始：0 在部分客户端里被当作无效句柄。
        const id = self.next_handle;
        self.next_handle +%= 1;
        if (self.next_handle == 0) self.next_handle = 1;
        errdefer self.alloc.free(path);
        try self.handles.put(self.alloc, id, .{ .id = id, .path = path, .kind = kind });
        return id;
    }

    pub fn getHandle(self: *Session, id: u32) ?*Handle {
        return self.handles.getPtr(id);
    }

    /// 给句柄挂上（或替换）上层私有状态。`release` 会在 `closeHandle` /
    /// `reset` / `deinit` 时被调用，且只在 `extra != null` 时调用。
    pub fn setExtra(
        self: *Session,
        id: u32,
        extra: ?*anyopaque,
        release: ?*const fn (extra: *anyopaque, alloc: std.mem.Allocator) void,
    ) void {
        if (self.getHandle(id)) |h| {
            h.extra = extra;
            h.release = release;
        }
    }

    /// 关闭句柄。未知 id 返回 `false` 而不是报错——客户端重复 close 是
    /// 常见行为，不该让服务端因此断开连接。
    pub fn closeHandle(self: *Session, id: u32) bool {
        if (self.handles.fetchRemove(id)) |kv| {
            if (kv.value.release) |f| {
                if (kv.value.extra) |e| f(e, self.alloc);
            }
            self.alloc.free(kv.value.path);
            return true;
        }
        return false;
    }

    /// 便利封装：归一化后返回虚拟路径。
    pub fn resolve(self: *Session, requested: []const u8) PathError!Normalized {
        return normalize(self.alloc, requested);
    }
};

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectNorm(input: []const u8, want: []const u8) !void {
    const got = try normalize(testing.allocator, input);
    defer testing.allocator.free(got.path);
    try testing.expectEqualStrings(want, got.path);
}

test "sftp/session: 归一化的基本形态" {
    try expectNorm("/", "/");
    try expectNorm("", "/");
    try expectNorm("/a", "/a");
    try expectNorm("a", "/a"); // 相对路径按根解析
    try expectNorm("/a/b/c", "/a/b/c");
    try expectNorm("/a//b", "/a/b"); // 折叠重复斜杠
    try expectNorm("/a/./b", "/a/b");
    try expectNorm("/a/b/", "/a/b"); // 去尾斜杠
    try expectNorm("//a//", "/a");
}

test "sftp/session: .. 在根内正常回退" {
    try expectNorm("/a/b/..", "/a");
    try expectNorm("/a/b/../c", "/a/c");
    try expectNorm("/a/b/../../c", "/c");
    try expectNorm("/a/./b/../b", "/a/b");
}

test "sftp/session: .. 越过根时钳到根并置 clamped" {
    const cases = [_][]const u8{ "/..", "/../..", "/../x", "/a/../../x", "..", "../.." };
    for (cases) |c| {
        const got = try normalize(testing.allocator, c);
        defer testing.allocator.free(got.path);
        try testing.expect(got.clamped);
        try testing.expect(got.path.len >= 1 and got.path[0] == '/');
        try testing.expect(std.mem.indexOf(u8, got.path, "..") == null);
    }

    // 具体值
    const a = try normalize(testing.allocator, "/../x");
    defer testing.allocator.free(a.path);
    try testing.expectEqualStrings("/x", a.path);

    const b = try normalize(testing.allocator, "/a/../../x");
    defer testing.allocator.free(b.path);
    try testing.expectEqualStrings("/x", b.path);
}

test "sftp/session: 根内回退不算 clamped" {
    const got = try normalize(testing.allocator, "/a/../b");
    defer testing.allocator.free(got.path);
    try testing.expect(!got.clamped);
    try testing.expectEqualStrings("/b", got.path);
}

test "sftp/session: 畸形输入被拒绝" {
    try testing.expectError(error.InvalidPath, normalize(testing.allocator, "/a\x00b"));

    var long: [max_path_len + 1]u8 = @splat('a');
    try testing.expectError(error.PathTooLong, normalize(testing.allocator, &long));
}

test "sftp/session: 含空格与中文的路径原样保留" {
    try expectNorm("/我的 电影/a b.mp4", "/我的 电影/a b.mp4");
}

test "sftp/session: 句柄生命周期" {
    var s = Session.init(testing.allocator);
    defer s.deinit();

    const p1 = try testing.allocator.dupe(u8, "/a.txt");
    const h1 = try s.addHandle(p1, .file);
    try testing.expectEqual(@as(usize, 1), s.openCount());

    const got = s.getHandle(h1).?;
    try testing.expectEqualStrings("/a.txt", got.path);
    try testing.expectEqual(HandleKind.file, got.kind);

    try testing.expect(s.closeHandle(h1));
    try testing.expectEqual(@as(usize, 0), s.openCount());
    try testing.expect(s.getHandle(h1) == null);
}

test "sftp/session: 重复 close 返回 false 而不是崩溃" {
    var s = Session.init(testing.allocator);
    defer s.deinit();

    const h = try s.addHandle(try testing.allocator.dupe(u8, "/x"), .dir);
    try testing.expect(s.closeHandle(h));
    try testing.expect(!s.closeHandle(h)); // 第二次
    try testing.expect(!s.closeHandle(9999)); // 从没存在过
}

test "sftp/session: 句柄 id 不复用、不为 0" {
    var s = Session.init(testing.allocator);
    defer s.deinit();

    const a = try s.addHandle(try testing.allocator.dupe(u8, "/a"), .file);
    _ = s.closeHandle(a);
    const b = try s.addHandle(try testing.allocator.dupe(u8, "/b"), .file);
    try testing.expect(a != b);
    try testing.expect(b != 0);
}

test "sftp/session: 句柄上限" {
    var s = Session.init(testing.allocator);
    defer s.deinit();

    var i: usize = 0;
    while (i < max_handles) : (i += 1) {
        _ = try s.addHandle(try testing.allocator.dupe(u8, "/f"), .file);
    }
    try testing.expectEqual(max_handles, s.openCount());

    // 第 513 个被拒绝，且传入的 path 已被释放（否则 testing.allocator 会报泄漏）
    try testing.expectError(error.TooManyHandles, s.addHandle(try testing.allocator.dupe(u8, "/f"), .file));
    try testing.expectEqual(max_handles, s.openCount());
}

test "sftp/session: deinit 释放所有句柄（泄漏由 testing.allocator 抓）" {
    var s = Session.init(testing.allocator);
    _ = try s.addHandle(try testing.allocator.dupe(u8, "/a"), .file);
    _ = try s.addHandle(try testing.allocator.dupe(u8, "/b"), .dir);
    s.deinit(); // 不手动 close，deinit 必须清干净
}

test "sftp/session: reset 清空句柄并允许重新协商" {
    var s = Session.init(testing.allocator);
    defer s.deinit();

    _ = try s.addHandle(try testing.allocator.dupe(u8, "/a"), .file);
    s.negotiated = true;
    s.reset();

    try testing.expectEqual(@as(usize, 0), s.openCount());
    try testing.expect(!s.negotiated);
    // reset 之后仍可继续用
    const h = try s.addHandle(try testing.allocator.dupe(u8, "/c"), .dir);
    try testing.expect(s.getHandle(h) != null);
}

test "sftp/session: resolve 走同一套归一化" {
    var s = Session.init(testing.allocator);
    defer s.deinit();

    const r = try s.resolve("/quark/../189/./backup");
    defer testing.allocator.free(r.path);
    try testing.expectEqualStrings("/189/backup", r.path);
    try testing.expect(!r.clamped);
}
