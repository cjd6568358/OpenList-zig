//! 挂载构建（启动 worker 与管理面增改删共用的唯一实现）—— 自 api.zig
//! 整体搬出（AUDIT-2026-11-27 路线图 #15-M4）。搬出为纯移动：
//! fixAndCleanPath/dupeStorage/InitFailure/BuiltMount/buildMountFromStorage/
//! buildMountsFromConfig/republishWithEdit/hasLiveMount 逐行未动；
//! App 与 Mount 以别名引用（api↔mounts 双向 import 与既有 api↔webdav 同形）。
//! mountLenDesc 为本文件私有比较器。

const std = @import("std");
const model = @import("model.zig");
const driver = @import("driver.zig");
const config = @import("config.zig");
const json = @import("util/json.zig");
const urlmod = @import("util/url.zig");
const log = @import("log.zig");
const rt = @import("rt.zig");
const List = @import("util/buf.zig").List;

const api = @import("api.zig");
const App = api.App;
const Mount = api.Mount;

// ---------------------------------------------------------------------------
// 挂载构建（启动 worker 与管理面增改删共用的唯一实现）
// ---------------------------------------------------------------------------

/// Go `utils.FixAndCleanPath`（pkg/utils/path.go:19-25）的等价实现，三步：
///   1. 反斜杠转正斜杠（Windows 风格写法）
///   2. 补前导 "/"
///   3. Clean（`.` / `..` / 重复斜杠）
/// 第 2 步由 `cleanPath` 保证（它恒以前导 / 输出，根为 "/" 而非 ""），
/// 所以这里只需补第 1 步。
///
/// 上游在同一个函数上做两类事，本工程也照用，不另起炉灶：
///   * 挂载路径归一（存储增删改 / import）
///   * **请求路径归一** —— `middlewares.PathParse`
///     （server/middlewares/down.go:18-22）在 `Down` 验签**之前**就把它套在
///     `/d/*path`、`/p/*path` 上，所以下载签名是对**清洗后**的路径计算的。
///     顺序不能反：先清洗再验签。
/// 名字沿用上游（`fixAndCleanPath`）；`drivers/strm.zig` 里另有一份同名的
/// 私有副本，两者行为一致。
pub fn fixAndCleanPath(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const folded = try a.dupe(u8, raw);
    for (folded) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    const cleaned = try urlmod.cleanPath(a, if (folded.len == 0) "/" else folded);
    return if (cleaned.len == 0) try a.dupe(u8, "/") else cleaned;
}

/// 深拷贝一条 Storage 记录（所有字符串归 `alloc` 所有）。
///
/// 为什么需要：`cfg.storages` 的元素会被两路并发写（驱动的 `persist` 回写
/// cookie、管理面字段替换），拿着指向元素的指针去做「构建驱动」这种长活，
/// 读到的字段可能在脚下被换掉。先在 `storages_mutex` 临界区里拷出快照，
/// 再拿着快照去 init，读写竞态就关掉了 —— Go 侧传值语义天然如此。
pub fn dupeStorage(alloc: std.mem.Allocator, s: *const model.Storage) !model.Storage {
    var out = s.*;
    out.mount_path = try alloc.dupe(u8, s.mount_path);
    out.driver = try alloc.dupe(u8, s.driver);
    out.status = try alloc.dupe(u8, s.status);
    out.addition = try alloc.dupe(u8, s.addition);
    out.remark = try alloc.dupe(u8, s.remark);
    out.error_msg = try alloc.dupe(u8, s.error_msg);
    return out;
}

/// `buildMountFromStorage` 的结果。init 失败的 `@errorName` 是静态串，可以安全
/// 存进结构体（调用方拿去写日志 / error_msg）。
pub const BuiltMount = union(enum) {
    ok: Mount,
    /// `driver.find` 精确查找失败 —— 配置里的驱动名与编译进来的不一致。
    no_driver,
    /// `addition` 不是合法 JSON。
    invalid_addition,
    /// `drv.init` 失败；记录 `@errorName`。调用方应经 `setStorageError` 把
    /// 它写回记录，让管理面能展示「errored」。
    ///
    /// 两段分开存（错误名 + 上游原文）而不是预拼成一条串：调用方的分配器
    /// 各不相同（启动路径是 gpa，管理面是请求 arena），预拼会让「谁释放」
    /// 说不清（2026-10-10 审计发现过一次 gpa 泄漏，就是这里拼出来的）。
    /// 需要文字时用 `initErrText()` 在**调用方的短命 arena** 上拼，
    /// 要落配置用 `Config.setStorageErrorParts()` 在配置 arena 上拼。
    init_failed: InitFailure,
};

/// `init` 失败的两段式原因。
pub const InitFailure = struct {
    /// `@errorName(e)` —— 指向静态常量，不需要释放。
    name: []const u8,
    /// 驱动写在 `ctx.err_detail` 里的上游原文；没有则为 null（或空串）。
    detail: ?[]const u8,
};

/// 把 `InitFailure` 拼成一条可读文字。⚠️ 结果活在 `a` 上 —— 只能在**短命
/// arena**（请求 arena）上调用，别传 gpa（那正是已修掉的泄漏）。
pub fn initErrText(a: std.mem.Allocator, f: InitFailure) ![]const u8 {
    const d = f.detail orelse "";
    return if (d.len == 0)
        f.name
    else
        try std.fmt.allocPrint(a, "{s}: {s}", .{ f.name, d });
}

/// 从**已拥有所有权**的 Storage 快照构建一个挂载（find → parse addition →
/// create → init → 归一路径）。启动 worker 与 `/api/admin/storage/*` 共用。
///
/// 内存契约：
///   * 驱动实例与 `mount_path` 归 `alloc`（生产 = gpa，测试 = 测试 arena）；
///   * `addition` 的 JSON 树在短命 arena 里解析 —— 所有驱动的 `Addition.parse`
///     都会把自己要保留的字段 dupe 进 `alloc`（见各驱动 create），树本体
///     出函数即回收，不给 gpa 留每存储一份的泄漏（main.zig 旧实现的已知问题）；
///   * `Mount.storage` 是快照的拷贝 —— 字符串仍指回快照的所有者，调用方
///     必须保证快照活得比挂载久（启动/管理面都是进程级或配置 arena，成立）。
pub fn buildMountFromStorage(alloc: std.mem.Allocator, s: *const model.Storage) anyerror!BuiltMount {
    const f = driver.find(s.driver) orelse return .no_driver;

    var add_arena = std.heap.ArenaAllocator.init(alloc);
    defer add_arena.deinit();
    const add_text = if (s.addition.len > 0) s.addition else "{}";
    const add_val = json.parse(add_arena.allocator(), add_text) catch return .invalid_addition;

    const drv = try f.create(alloc, s.id, &add_val);
    var init_ctx = driver.Ctx{ .alloc = alloc, .tag = s.mount_path };
    // 2026-10-24 面包屑：init 是整条链路里最重的一步（每个存储都要 TLS +
    // 上游登录，几十秒级），崩溃复盘时"死在哪个驱动的 init"只能靠最后一行
    // 日志推断。这里补一行"开始"，与调用方已有的成功/失败行构成完整链条。
    // RSS 一并记下：静默死亡时内存是不是元凶，从此不用猜。
    log.info("storage #{d} {s}: initializing (rss {d}KB)", .{ s.id, s.driver, rt.rssKb() });
    drv.init(&init_ctx) catch |e| {
        // S03：init 失败的驱动要释放，否则每次重载都漏一个（jar/client 都在 alloc 上）。
        drv.deinit(&init_ctx);
        // 把驱动写在 `ctx.err_detail` 里的**上游原文**带上。
        //
        // 对齐 Go：init 失败时 `GetStorage().SetStatus(fmt.Sprintf("%+v", err))`，
        // 管理面显示的是真原因，而不是一个错误名。对迅雷尤其关键 —— 它的
        // `review_panel` 报错正文是一段 JSON，用户要照着官方文档把它粘进
        // `reviewCb()` 换 credit_key；只剩 "NeedVerify" 就等于流程断了。
        if (init_ctx.err_detail) |detail| {
            if (detail.len > 0) {
                return .{ .init_failed = .{ .name = @errorName(e), .detail = detail } };
            }
        }
        return .{ .init_failed = .{ .name = @errorName(e), .detail = null } };
    };

    return .{ .ok = .{
        .storage = s.*,
        .driver = drv,
        .mount_path = try fixAndCleanPath(alloc, s.mount_path),
        .label = f.label,
    } };
}

/// 挂载排序：最长路径优先（`/nas/photos` 压过 `/nas`），与 main.zig 旧行为一致。
fn mountLenDesc(_: void, a: Mount, b: Mount) bool {
    return a.mount_path.len > b.mount_path.len;
}

/// 从 config 全量重建挂载表并一次性发布。启动 worker 与 `load_all` 用。
/// 调用方必须持有 `App.storage_ops_lock`（避免两次重建交错发布）。
///
/// 与 main.zig 旧实现语义一致：disabled 跳过；驱动缺失 / addition 非法 / init
/// 失败的记录不进挂载表，但 init 失败会经 `setStorageError` 写回记录（管理面
/// 从配置表渲染，所以失败项能以「errored」露面，与 Go 从 DB 渲染一致）；
/// 重复挂载路径后者跳过。
pub fn buildMountsFromConfig(alloc: std.mem.Allocator, app: *App, cfg: *config.Config) !void {
    // 先在临界区里拷出全部记录的快照，再拿快照构建 —— 构建期间（每驱动 init
    // 可达数十秒）不能占着 storages_mutex，那会把驱动自己的 `persist` 回写
    // （persist → storages_mutex）饿死。
    const snaps = blk: {
        config.lockStorages();
        defer config.unlockStorages();
        const out = try alloc.alloc(model.Storage, cfg.storages.len);
        for (cfg.storages, 0..) |*s, i| out[i] = try dupeStorage(alloc, s);
        break :blk out;
    };

    var mounts = List(Mount).init(alloc);
    var seen_paths = List([]const u8).init(alloc);

    for (snaps) |*s| {
        if (s.disabled) {
            log.info("storage #{d} {s}: disabled, skipping", .{ s.id, s.driver });
            continue;
        }
        const result = try buildMountFromStorage(alloc, s);
        const m = switch (result) {
            .ok => |m| m,
            .no_driver => {
                log.err("storage #{d}: no driver named {s} in this build (compiled in: see /api/fs/dirs)", .{ s.id, s.driver });
                continue;
            },
            .invalid_addition => {
                log.err("storage #{d} {s}: addition is not valid JSON", .{ s.id, s.driver });
                continue;
            },
            .init_failed => |ef| {
                // 一个存储坏不拖垮整个进程：记 errored 继续服务其余存储（对齐
                // Go 的行为，也见 main.zig 同款注释）。
                // ⚠️ 这里 `alloc` 是 gpa：**不要**在这里拼消息（旧实现正是
                //    这样每次 init 失败漏几百字节）。拼接交给
                //    `setStorageErrorParts` 在配置 arena 里做，只做一次。
                log.err("storage #{d} {s}: init failed: {s}{s}{s} — marking as errored", .{
                    s.id,                                                        s.driver,            ef.name,
                    if (ef.detail != null and ef.detail.?.len > 0) ": " else "", ef.detail orelse "",
                });
                cfg.setStorageErrorParts(s.id, ef.name, ef.detail);
                continue;
            },
        };
        for (seen_paths.slice()) |p| {
            if (std.mem.eql(u8, p, m.mount_path)) {
                log.err("storage #{d}: mount path {s} is already taken, skipping", .{ s.id, m.mount_path });
                break;
            }
        } else {
            try seen_paths.append(m.mount_path);
            try mounts.append(m);
            log.info("storage #{d} {s} -> {s} ({s})", .{ s.id, s.driver, m.mount_path, m.label });
        }
    }

    std.mem.sort(Mount, mounts.sliceMut(), {}, mountLenDesc);
    // T6：一次性发布。发布后内容永不再变，读方拿快照即可安全用（含调用驱动）。
    app.publishMounts(try mounts.toOwned());
}

/// 管理面单存储变更后的发布：**复制**所有未变更挂载（驱动实例原样复用，不
/// 重新 init —— itvsh/189 这类登录一次几十秒，每次改设置把全部存储重来一遍
/// 不可接受），替换/移除目标项，重排序后发布。
///
/// 被替换下来的旧驱动实例**刻意不 deinit**：请求线程可能还拿着旧快照在调用它
/// （snapshot 语义 = 读方可无锁使用），没有引用计数就无法安全判定「没人用了」。
/// 每次编辑泄漏一个驱动实例（jar + client，几 KB），编辑是低频管理操作，可
/// 接受；见 docs/STATUS.md 的已知偏差记录。
pub fn republishWithEdit(app: *App, alloc: std.mem.Allocator, edited_id: i64, replacement: ?Mount) !void {
    var mounts = List(Mount).init(alloc);
    for (app.mountsSnapshot()) |m| {
        if (m.storage.id == edited_id) continue;
        try mounts.append(m);
    }
    if (replacement) |m| try mounts.append(m);
    std.mem.sort(Mount, mounts.sliceMut(), {}, mountLenDesc);
    app.publishMounts(try mounts.toOwned());
}

/// 管理面渲染时判定「该记录有没有活的挂载」。mounts 快照不可变，锁外读安全。
pub fn hasLiveMount(mounts: []const Mount, id: i64) bool {
    for (mounts) |m| {
        if (m.storage.id == id) return true;
    }
    return false;
}
