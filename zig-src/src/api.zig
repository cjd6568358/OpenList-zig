//! HTTP API surface, shaped to match OpenList's `/api/*` so the existing web
//! frontend works against this binary unchanged.
//!
//! Implemented (the subset the frontend actually calls for browsing,
//! downloading and uploading):
//!   GET  /ping                         liveness
//!   GET  /api/public/settings          site config + whether setup is done
//!   POST /api/auth/login               -> JWT
//!   GET  /api/public/init_status       whether the system is initialised
//!   POST /api/public/init/setup        first-run admin creation
//!   POST /api/fs/list                  browse a directory
//!   POST /api/fs/get                   stat a path
//!   POST /api/fs/dirs                  list subdirectories of a path (bare array)
//!   POST /api/fs/mkdir                 create a directory
//!   POST /api/fs/rename                rename in place
//!   POST /api/fs/move                  move across directories
//!   POST /api/fs/remove                delete
//!   PUT  /api/fs/put                   upload (body = raw bytes, File-Path header)
//!   GET  /d/* and /p/*                 download / proxied download (Range-aware)
//!
//! Admin surface (single-admin build: every authenticated user is the admin):
//!   GET  /api/me                       current user
//!   GET  /api/admin/storage[/list]     all configured storages (settings UI)
//!   GET  /api/admin/storage/get?id=     one record (edit form)
//!   POST /api/admin/storage/create      add a storage, init it, persist cfg.json
//!   POST /api/admin/storage/update      edit one (driver immutable), re-init
//!   POST /api/admin/storage/delete?id=  remove one, persist cfg.json
//!   POST /api/admin/storage/enable|disable?id=  flip `disabled`
//!   POST /api/admin/storage/load_all    rebuild every mount in the background
//!   GET  /api/admin/driver/list         per-driver form metadata (Go Info shape)
//!   GET  /api/admin/driver/names        driver keys for the selector
//!   GET  /api/admin/driver/info?driver= one driver's form metadata
//!   GET  /api/admin/setting/{list,get,default}
//!   POST /api/admin/setting/{save,delete}  persist / reset config-backed settings
//!   GET  /api/task/<kind>/{undone,done} empty lists (no job queue in this build)
//!   GET  /api/admin/setting + PUT      compact compatibility alias
//!
//! Storage 增改删的持久化模型：本工程没有数据库，`storages` 表就是 config.json
//! 顶层的 `storages` 数组；每次管理操作改完内存副本后立即 `cfg.save()` 落盘
//! （tmp + rename 原子写）。挂载表（App.mounts）则用「复制未变更项 + 重建变更项
//! + 一次性发布」的方式热更新，见 `republishWithEdit`。
//!
//! Deliberately absent, with reasons in docs/STATUS.md: search (needs
//! bleve), share links, and the full task-centre CRUD (the tasks listed above
//! are read-only admin lookups; there is no background job queue yet). SSO
//! admin, archives browsing, and offline download are also not implemented.
//! (A WebDAV server is served at /dav — see webdav.zig.)

const std = @import("std");
const http = @import("http.zig");
const model = @import("model.zig");
const driver = @import("driver.zig");
const json = @import("util/json.zig");
const rand = @import("util/random.zig");
const urlmod = @import("util/url.zig");
const config = @import("config.zig");
const log = @import("log.zig");
const client_mod = @import("client.zig");
const cookiejar = @import("cookiejar.zig");
const frontend_mod = @import("frontend.zig");
const webdav = @import("webdav.zig");
const archive = @import("archive.zig");
const Buf = @import("util/buf.zig").Buf;
const List = @import("util/buf.zig").List;
const rt = @import("rt.zig");

pub const Header = model.Header;

/// M17：`reloadAdminCredentials` 换下来的旧凭据最多留存几代才回收。
/// 见 `App.retired_creds` 的说明（立刻释放会踩到在途请求的 UAF）。
const retired_creds_cap = 8;

/// One configured storage, paired with its live driver instance.
pub const Mount = struct {
    storage: model.Storage,
    driver: driver.Driver,
    /// Normalised: always starts with '/', never ends with one (except "/").
    mount_path: []const u8,
    /// Human-readable driver label (logs / diagnostics; no longer an API field).
    label: []const u8,
};

pub const App = struct {
    alloc: std.mem.Allocator,
    /// T6：mounts 由**后台线程一次性发布**（对齐 Go 的 LoadStorages goroutine
    /// + 立即监听），所以读写需要闸门。契约：
    ///   * 写方（main.zig 的 buildMountsWorker）只做**整 slice 替换**，
    ///     替换前完成所有驱动 init，替换后内容永不再变；
    ///   * 读方只取**快照**（持锁拷一个 slice 头，16 字节）；
    ///   * 拿到快照后**绝不持锁调用驱动** —— 那会串行化所有请求。
    /// 0.17：`std.Thread.Mutex` 并入 `std.Io.Mutex`，lock/unlock 都要 io。
    mounts_lock: std.Io.Mutex = .init,
    mounts: []Mount,
    /// 串行化「挂载重建 + 发布」类操作（启动 worker、storage 增改删/启停、
    /// load_all）。没有它，两次重建交错时后发布者会覆盖前者刚建好的驱动，
    /// 或者把对方刚发布出去的 slice 覆盖成旧视图。
    ///
    /// 与 `config.storages_mutex` 是两把不同的锁：这把的临界区里可以短暂
    /// 拿那把（拿配置表快照），但驱动 init 这种长临界区**不要**拿着它跑。
    storage_ops_lock: std.Io.Mutex = .init,
    /// `sha256(sha256(pw + "-" + StaticHashSalt) + "-" + salt)` —— 与 Go
    /// `User.PwdHash` 同形（`model.TwoHashPwd`）。空 = 还没建管理员。
    admin_hash: []const u8,
    /// 每用户随机 salt（Go `User.Salt`）；没有它就算不出 PwdHash。
    /// 给默认值是为了让那些只关心路由的测试构造（`App{...}`）不必逐个补字段。
    admin_salt: []const u8 = "",
    admin_user: []const u8,
    /// A03：口令版本时间戳。签发令牌时写进 claim，校验时比对；改密就把它推到
    /// 当前时间，于是所有旧令牌立刻失效。对应 Go 的 `model.User.PwdTS`
    /// （server/common/auth.go:19 与 server/middlewares/auth.go:62-66）。
    admin_pwd_ts: i64,
    /// 权限位图，对应 Go `model.User.Permission`。Go 建 admin 时写死
    /// `0x71FF`（= 29183，`server/handles/setup.go:60`），前端按这些位决定
    /// 显不显示某些操作按钮 —— 返回 0 会让界面把功能全禁掉。
    /// 位定义见 `internal/model/user.go:48-64`。
    admin_permission: i64 = 0x71FF,
    /// M17：换下来的旧凭据（user/salt/hash 三元组）按代次留存，超代才释放。
    /// 见 `reloadAdminCredentials` —— 立刻 free 会踩到在途请求的 UAF。
    retired_creds: [retired_creds_cap][3][]const u8 = undefined,
    retired_creds_count: usize = 0,
    retired_creds_next: usize = 0,
    jwt_secret: []const u8,
    /// 下载签名（/d/ /p/ 与 fs/get 的 sign）用的 HMAC 密钥。
    ///
    /// ⚠ Go 用的是 **`token` 设置**（`internal/sign/sign.go:39`
    /// `sign.NewHMACSign([]byte(setting.GetStr(conf.Token)))`），不是
    /// jwt_secret —— 所以 Go 的 `admin/setting/reset_token` 会顺带作废
    /// 所有已发下载链接。本工程对应 `zig.token`（CLI 认证与签名共用一个串）。
    /// 空串 = 回退 jwt_secret（测试里只设 jwt_secret 的构造走这条）。
    sign_secret: []const u8 = "",
    site_url: []const u8,
    cdn: []const u8,
    token_expires_in_hours: i64,
    /// Frontend serving: the SPA shell, the four asset prefixes and the PWA
    /// manifest. Built once during `init`, so a CDN misconfiguration fails at
    /// startup rather than on the first page load.
    frontend: frontend_mod.Frontend,

    pub fn init(alloc: std.mem.Allocator) !App {
        const cfg = config.get();

        var app = App{
            .alloc = alloc,
            .mounts = &.{},
            .admin_hash = try readSecret(alloc, cfg, "admin_password_hash"),
            .admin_user = try readSecretDefault(alloc, cfg, "admin_user", "admin"),
            .admin_salt = try readSecret(alloc, cfg, "admin_salt"),
            .admin_pwd_ts = readSecretInt(cfg, "admin_pwd_ts", 0),
            // 缺省 0x71FF：对齐 Go `server/handles/setup.go:60` 建 admin 时写的
            // `Permission: 0x71FF`。前端按这些位控制按钮，返回 0 会把功能全禁掉。
            .admin_permission = readSecretInt(cfg, "admin_permission", 0x71FF),
            .jwt_secret = try alloc.dupe(u8, cfg.jwt_secret),
            .sign_secret = try alloc.dupe(u8, if (cfg.raw("zig.token")) |v| (v.asStr() orelse "") else ""),
            .site_url = try alloc.dupe(u8, cfg.site_url),
            .cdn = try alloc.dupe(u8, cfg.cdn),
            .token_expires_in_hours = cfg.token_expires_in,
            // Assigned immediately below; `Frontend` owns a pointer, so the
            // struct cannot be built inline in the literal.
            .frontend = undefined,
        };
        app.frontend = try frontend_mod.init(alloc, .{
            .site_url = cfg.site_url,
            .cdn = cfg.cdn,
            .cdn_fallbacks = cfg.cdn_fallbacks,
            .dist_dir = cfg.dist_dir,
            .web_version = cfg.web_version,
            .settings = .{
                .site_title = cfg.site_title,
                .main_color = cfg.main_color,
                .logo = cfg.logo,
                .favicon = cfg.favicon,
                .customize_head = cfg.customize_head,
                .customize_body = cfg.customize_body,
            },
        });
        return app;
    }

    /// 从磁盘重读 config.json，只把管理员凭据（user / hash / pwd_ts）换成新值。
    ///
    /// 供 `/api/admin/user/del_cache` 用：CLI（`openlist admin set` / `admin random`）
    /// 是**独立进程**，它只写配置文件；在线服务的凭据是启动时读进内存的副本，
    /// 不重载的话改完密码旧令牌照样能用。对齐 Go 的 `DelAdminCacheOnline`
    /// （`cmd/user.go:15`：改完库再 HTTP 通知在线服务清缓存）。
    pub fn reloadAdminCredentials(self: *App) !void {
        const cfg = config.get();
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const a = arena.allocator();
        const text = try std.Io.Dir.cwd().readFileAlloc(rt.io(), cfg.path, a, .limited(8 * 1024 * 1024));
        const doc = try json.parse(a, text);
        const zig = doc.getPath("zig") orelse return error.MalformedConfig;

        const user = if (zig.getPath("admin_user")) |v| (v.asStr() orelse "admin") else "admin";
        const salt = if (zig.getPath("admin_salt")) |v| (v.asStr() orelse "") else "";
        const hash = if (zig.getPath("admin_password_hash")) |v| (v.asStr() orelse "") else "";
        const pwd_ts = if (zig.getPath("admin_pwd_ts")) |v| (v.asInt() orelse 0) else 0;

        // M17（审计）：先把三个新值都备齐（任何一步失败都不会留下半新半旧），
        // 再一次性发布。以前是 `dupe` 一个就赋一个 —— 请求线程无锁读这三个
        // 字段，中间态是「新 hash 配旧 salt」，恰好跨越的那次登录必然失败。
        const new_user = try self.alloc.dupe(u8, user);
        errdefer self.alloc.free(new_user);
        const new_salt = try self.alloc.dupe(u8, salt);
        errdefer self.alloc.free(new_salt);
        const new_hash = try self.alloc.dupe(u8, hash);
        errdefer self.alloc.free(new_hash);

        const old = [3][]const u8{ self.admin_user, self.admin_salt, self.admin_hash };
        self.admin_user = new_user;
        self.admin_salt = new_salt;
        self.admin_hash = new_hash;
        self.admin_pwd_ts = pwd_ts;
        // 旧值不能当场 free：正在处理的请求可能还持有那几个切片（鉴权在请求
        // 线程上无锁读）。按代次留存，超过 `retired_creds_cap` 代才释放最老的
        // 一代 —— 请求是秒级的，8 代远超任何在途请求的生命周期。
        self.retireCreds(old);
    }

    /// M17：换下来的旧凭据按代次留存后回收（见 `reloadAdminCredentials`）。
    fn retireCreds(self: *App, old: [3][]const u8) void {
        if (self.retired_creds_count < retired_creds_cap) {
            self.retired_creds[self.retired_creds_count] = old;
            self.retired_creds_count += 1;
            return;
        }
        const victim = self.retired_creds[self.retired_creds_next];
        self.retired_creds[self.retired_creds_next] = old;
        self.retired_creds_next = (self.retired_creds_next + 1) % retired_creds_cap;
        for (victim) |s| self.alloc.free(s);
    }

    /// Releases the frontend arena. The remaining fields are process-lifetime
    /// and are deliberately not tracked; this exists so the largest single
    /// allocation is still accounted for when the server shuts down.
    pub fn deinit(self: *App) void {
        self.frontend.deinit();
        // M17：退役代次里的旧凭据也要还回去（进程退出路径，此时无在途请求）。
        var i: usize = 0;
        while (i < self.retired_creds_count) : (i += 1) {
            for (self.retired_creds[i]) |s| self.alloc.free(s);
        }
        self.retired_creds_count = 0;
    }

    /// Strm 驱动的 fs 回调桥（Go 侧直接调 `internal/fs` + `op.Link` +
    /// `sign.Sign` + `common.GetApiUrl`）。在 `main.zig` 的 App 构造后调用；
    /// 测试里也可以对局部 App 调用（bridge 只借 ctx 指针，不持有）。
    pub fn installFsBridge(self: *App) void {
        driver.fs_bridge = .{
            .ctx = self,
            .get = bridgeGet,
            .list = bridgeList,
            .link = bridgeLink,
            .sign = bridgeSign,
            .site_url = bridgeSiteUrl,
        };
    }

    /// T6：取当前 mounts 快照。只锁「拷 slice 头」这一下，绝不拿着锁做别的。
    pub fn mountsSnapshot(self: *App) []Mount {
        const io = rt.io();
        self.mounts_lock.lockUncancelable(io);
        defer self.mounts_lock.unlock(io);
        return self.mounts;
    }

    /// T6：后台初始化线程专用的发布入口。整 slice 替换，替换前所有驱动的
    /// init 都已完成；替换之后 `mounts` 内容永不再变（只读快照才安全）。
    pub fn publishMounts(self: *App, mounts: []Mount) void {
        const io = rt.io();
        self.mounts_lock.lockUncancelable(io);
        defer self.mounts_lock.unlock(io);
        self.mounts = mounts;
    }

    /// Longest-prefix mount lookup. Mounts are matched at segment boundaries:
    /// `/nas` matches `/nas` and `/nas/a` but NOT `/nas2`.
    ///
    /// T6：返回的指针指向**已发布**的 slice —— 发布后内容永不再变，所以
    /// 调用方可以安全地拿着它去调驱动（不在持锁状态下）。后台初始化完成前
    /// 这里返回 null（请求拿到 404，与 Go 的「存储还没加载完」行为一致）。
    pub fn resolve(self: *App, path: []const u8) ?struct { mount: *Mount, rel: []const u8 } {
        var best: ?*Mount = null;
        var best_len: usize = 0;
        for (self.mountsSnapshot()) |*m| {
            const mp = m.mount_path;
            if (!std.mem.startsWith(u8, path, mp)) continue;
            const boundary = path.len == mp.len or mp.len == 1 or path[mp.len] == '/';
            if (!boundary) continue;
            // `>=` so that a later mount wins ties; config order is the
            // tie-breaker, which is what OpenList does too.
            if (mp.len >= best_len) {
                best = m;
                best_len = mp.len;
            }
        }
        const m = best orelse return null;
        // The root mount passes the whole path through unchanged.
        if (std.mem.eql(u8, m.mount_path, "/")) return .{ .mount = m, .rel = path };
        var rel = path[m.mount_path.len..];
        if (rel.len == 0) rel = "/";
        return .{ .mount = m, .rel = rel };
    }
};

// ---------------------------------------------------------------------------
// 挂载构建（启动 worker 与管理面增改删共用的唯一实现）
// ---------------------------------------------------------------------------

/// 归一挂载路径：cleanPath + 兜底 `/`。从 main.zig 迁来，两个调用方共用。
pub fn normalizeMountPath(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    // 对齐 Go `utils.FixAndCleanPath`（pkg/utils/path.go:19-25），三步：
    //   1. 反斜杠转正斜杠（Windows 风格写法）
    //   2. 补前导 "/"
    //   3. Clean
    // 第 2 步由 `cleanPath` 保证（它恒以前导 / 输出，根为 "/" 而非 ""），
    // 所以这里只需补第 1 步。
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
fn dupeStorage(alloc: std.mem.Allocator, s: *const model.Storage) !model.Storage {
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
    init_failed: []const u8,
};

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
    drv.init(&init_ctx) catch |e| {
        // S03：init 失败的驱动要释放，否则每次重载都漏一个（jar/client 都在 alloc 上）。
        drv.deinit(&init_ctx);
        return .{ .init_failed = @errorName(e) };
    };

    return .{ .ok = .{
        .storage = s.*,
        .driver = drv,
        .mount_path = try normalizeMountPath(alloc, s.mount_path),
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
            .init_failed => |msg| {
                // 一个存储坏不拖垮整个进程：记 errored 继续服务其余存储（对齐
                // Go 的行为，也见 main.zig 同款注释）。
                log.err("storage #{d} {s}: init failed: {s} — marking as errored", .{ s.id, s.driver, msg });
                cfg.setStorageError(s.id, msg);
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
fn republishWithEdit(app: *App, alloc: std.mem.Allocator, edited_id: i64, replacement: ?Mount) !void {
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
fn hasLiveMount(mounts: []const Mount, id: i64) bool {
    for (mounts) |m| {
        if (m.storage.id == id) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Strm 的 fs 桥实现（Go `internal/fs` 的最小等价面）。
fn bridgeCtx(ctx: *anyopaque) *App {
    return @ptrCast(@alignCast(ctx));
}

fn bridgeGet(ctx: *anyopaque, alloc: std.mem.Allocator, path: []const u8) !driver.File {
    const app = bridgeCtx(ctx);
    const r = app.resolve(path) orelse return error.NotFound;
    var c = driver.Ctx{ .alloc = alloc, .tag = r.mount.mount_path };
    return r.mount.driver.details(&c, r.rel);
}

fn bridgeList(ctx: *anyopaque, alloc: std.mem.Allocator, path: []const u8) ![]model.Obj {
    const app = bridgeCtx(ctx);
    const r = app.resolve(path) orelse return error.NotFound;
    var c = driver.Ctx{ .alloc = alloc, .tag = r.mount.mount_path };
    return r.mount.driver.list(&c, r.rel);
}

fn bridgeLink(ctx: *anyopaque, alloc: std.mem.Allocator, path: []const u8, args: driver.LinkArgs) !driver.Link {
    const app = bridgeCtx(ctx);
    const r = app.resolve(path) orelse return error.NotFound;
    var c = driver.Ctx{ .alloc = alloc, .tag = r.mount.mount_path };
    return r.mount.driver.link(&c, r.rel, args);
}

fn bridgeSign(ctx: *anyopaque, alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    const app = bridgeCtx(ctx);
    // Go `sign.Sign(path)` = SignWithExpire(path, 0)（永不过期）。
    return signValue(alloc, signKey(app), path, 0);
}

/// 下载签名密钥：`zig.token`（Go 的 `token` 设置），空串时回退 jwt_secret。
/// 单独一个函数是为了让所有签名/验签点**只有一处**取密钥 —— 换密钥（
/// reset_token）时不会漏掉某条路径。
fn signKey(app: *const App) []const u8 {
    return if (app.sign_secret.len > 0) app.sign_secret else app.jwt_secret;
}

fn bridgeSiteUrl(ctx: *anyopaque) []const u8 {
    return bridgeCtx(ctx).site_url;
}

/// 取虚拟路径的父目录（Go `stdpath.Dir`）。
fn dirnameRel(path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    if (idx == 0) return "/";
    return path[0..idx];
}

/// Go `internal/op/hook.go` 的写后钩子开关：settings 表的
/// `handle_hook_after_writing`（默认 false）。本工程没有 settings 表，
/// 落到 `zig.handle_hook_after_writing`。
fn hookAfterWritingEnabled() bool {
    const cfg = config.getOpt() orelse return false;
    const v = cfg.raw("zig.handle_hook_after_writing") orelse return false;
    const s = v.asStr() orelse return false;
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1");
}

/// Go `op.objsUpdateHook`：写操作成功后重列目标目录并广播。
/// 失败只记日志 —— 钩子永远不能让写操作本身报错（Go 在 goroutine 里做）。
fn notifyObjsUpdateAfterWrite(app: *App, a: std.mem.Allocator, mount: *Mount, parent_rel: []const u8) void {
    _ = app;
    if (!hookAfterWritingEnabled()) return;
    var c = driver.Ctx{ .alloc = a, .tag = mount.mount_path };
    const objs = mount.driver.list(&c, parent_rel) catch return;
    const parent = urlmod.joinPath(a, if (std.mem.eql(u8, mount.mount_path, "/")) "" else mount.mount_path, parent_rel) catch return;
    driver.notifyObjsUpdate(a, parent, objs);
}

pub fn handle(app: *App, req: *http.Request, res: *http.Response) !void {
    // CORS preflight, so the frontend can be served from another origin.
    if (std.mem.eql(u8, req.method, "OPTIONS")) {
        try setCors(req, res);
        const p = req.path;
        // WebDAV capability advertisement needs the DAV header and must not be
        // collapsed into the generic 204 preflight answer.
        if (std.mem.eql(u8, p, "/dav") or std.mem.startsWith(u8, p, "/dav/")) {
            return webdav.options(app, req, res);
        }
        res.setStatus(204);
        return;
    }
    try setCors(req, res);

    const p = req.path;

    if (std.mem.eql(u8, p, "/ping")) return handlePing(res);
    if (std.mem.eql(u8, p, "/api/public/settings")) return handlePublicSettings(app, res);
    // Go 路由把这个接口放在 public 组；即使 Zig 当前没有离线下载任务管理器，
    // 也必须返回成功的空工具列表，不能把前端能力探测打成 404。
    if (std.mem.startsWith(u8, p, "/api/public/offline_download_tools")) return res.jsonOk("[]");
    if (std.mem.eql(u8, p, "/api/public/archive_extensions")) return res.jsonOk("[\"zip\",\"tar\"]");
    // Go 用 `/public/init_status` + `/public/init/setup` 做首次安装向导
    // （server/router.go:105-106），**没有** `/auth/register`。前端 App.tsx
    // 靠 `init_status` 决定是否跳 `/@init`，缺了它永远不会引导注册。
    if (std.mem.eql(u8, p, "/api/public/init_status")) return handleInitStatus(app, req, res);
    if (std.mem.eql(u8, p, "/api/public/init/setup")) return handleInitSetup(app, req, res);
    if (std.mem.eql(u8, p, "/api/auth/login")) return handleLogin(app, req, res);
    if (std.mem.eql(u8, p, "/api/auth/login/hash")) return handleLoginHash(app, req, res);
    // ⚠️ Go **没有** `/api/auth/register` —— `server/router.go` 的 public 组只有
    // settings / archive_extensions / init_status / init/setup。这里曾自造过一个，
    // 现已删除：首次建管理员走 `/api/public/init/setup`，忘记密码走 CLI
    // `openlist admin set NEW_PASSWORD` / `admin random`（见 docs/STATUS.md §11）。

    // ---- frontend -------------------------------------------------------
    //
    // Everything here is unauthenticated, and deliberately so: the shell
    // *contains* the login page, so requiring a token to fetch it would make
    // the site unreachable. That is why this block sits before the auth gate in
    // `handleAuthed`, mirroring how OpenList's `noRoute` handler sits outside
    // its authenticated route group.
    if (frontend_mod.isAssetPath(p)) return handleAsset(app, req, res);
    if (std.mem.eql(u8, p, "/manifest.json")) return handleManifest(app, res);
    // 内置 setup 页：本实现独有的手动入口，**先于**上游 shell 处理。
    //
    // 为什么需要它：配了 cdn/dist_dir 时前端是上游 SPA，而 CDN 取不到时
    // 二进制直接拒绝启动（见 frontend.zig 的 `CdnIndexFetchFailed`）。
    // 排查时往往只需要一个能看 `init_status`、能建管理员的页面，不该被
    // 卡在"先修好 CDN"上。路径用 `@zig-setup` 而不是 `@init` —— 后者是
    // 上游前端自己的安装向导路由，抢过来会让正常部署行为错乱。
    if (std.mem.eql(u8, p, frontend_mod.Frontend.setup_path_suffix)) {
        try res.set("Content-Type", "text/html; charset=utf-8");
        return res.write(app.frontend.setupHtml());
    }
    // Upstream mounts a WebDAV server at /dav/. This build implements it — see
    // webdav.zig — so route there instead of letting the catch-all answer a
    // PROPFIND with the SPA shell (a 200 carrying HTML is far harder to
    // diagnose than a proper multistatus).
    if (std.mem.eql(u8, p, "/dav") or std.mem.startsWith(u8, p, "/dav/")) {
        return webdav.handle(app, req, res);
    }

    // ---- authenticated API ----------------------------------------------
    // Only the known authenticated prefixes reach `handleAuthed`; any other
    // /api/* path falls through to the 404 catch-all below (matching upstream,
    // which answers an unregistered API route with JSON 404, not 401).
    // CLI（`openlist admin set/random`）改完配置文件后调它做热重载。它用
    // `zig.token`（`openlist admin token` 可查）认证、**不是** JWT，所以必须
    // 拦在 `handleAuthed` 前面 —— 对齐 Go：`cmd/user.go:DelUserCacheOnline`
    // 也是拿 settings 表的 token 去 POST `/api/admin/user/del_cache`。
    if (std.mem.eql(u8, p, "/api/admin/user/del_cache")) return handleDelUserCache(app, req, res);

    if (std.mem.startsWith(u8, p, "/api/fs/")) return handleAuthed(app, req, res);
    // `/api/me` 与 `/api/me/update`（Profile 页改资料）都走这里。
    // 用前缀而不是精确匹配，否则新加的 `me/update` 会被上面的白名单漏掉、
    // 落到 404 catch-all —— 实测踩过。
    if (std.mem.startsWith(u8, p, "/api/me")) return handleAuthed(app, req, res);
    if (std.mem.eql(u8, p, "/api/auth/logout")) return handleAuthed(app, req, res);
    if (std.mem.startsWith(u8, p, "/api/admin/")) return handleAuthed(app, req, res);
    if (std.mem.startsWith(u8, p, "/api/task/")) return handleAuthed(app, req, res);
    // ⚠️ 下载路由**不能**走 `handleAuthed`：那里面第一件事就是 `checkAuth`，
    // 而 `?sign=` 下载压根不带 `Authorization` 头 —— 会在进到
    // `handleDownload` 里的签名校验之前就被 401 拦下（真机实测：sign 生成了、
    // 也正确，但 /d/ 恒 401，日志里连一条 "sign rejected" 都没有）。
    //
    // 对齐 Go：`/d/`、`/p/` 挂在 Down 中间件（`server/middlewares/down.go`）
    // 上，与 auth 中间件是两条独立的链；sign 通过即放行，失败才回落 token。
    if (std.mem.startsWith(u8, p, "/d/")) return handleDownload(app, req, res, false);
    if (std.mem.startsWith(u8, p, "/p/")) return handleDownload(app, req, res, true);

    // Catch-all = OpenList 的 NoRoute（server/router.go:116-118 →
    // server/static/static.go:213-227）。上游的行为是：
    //   * 方法不是 GET/POST  ⇒ **405**（`c.Status(405)`，无正文）；
    //   * 否则               ⇒ 200 + `Content-Type: text/html` + 前端 shell。
    // 注意 405 这一支是 2026-10-17 读源码时才确认的：早先的注释凭"实测
    // PUT 也是 200"把它判成未对齐，实际是当时没走到这条分支。
    return noRoute(app, req, res, p);
}

/// Go `static.Static` 里注册进 `e.NoRoute` 的那个 handler，逐条对齐。
/// 返回给 `handle` / `handleAuthed` 两处共用（未注册路径都落到这里）。
fn noRoute(app: *App, req: *http.Request, res: *http.Response, p: []const u8) !void {
    if (!std.mem.eql(u8, req.method, "GET") and !std.mem.eql(u8, req.method, "POST")) {
        res.setStatus(405);
        return;
    }
    // 上游是 `c.Header("Content-Type", "text/html")` —— **不带** charset
    // （shell 自带 `<meta charset="utf-8">`）。
    try res.set("Content-Type", "text/html");
    try res.write(app.frontend.htmlFor(p));
}

/// 该路径是否为**已注册的**受保护 API 端点（≈ Go 的 gin 路由表）。
/// 未注册 → 上游 NoRoute → 前端 shell（200 HTML），无论登录与否 ——
/// 见 `handleAuthed` 开头的检查。
/// ⚠ 新增端点时必须同步这里（以及下面的 dispatch），否则未登录访问新
/// 端点会拿到 HTML shell。块级粒度（`admin/storage/` 的内部子操作由
/// handler 自己校验），比 gin 的逐路由粒度略粗，边角差异见 STATUS §35。
fn isRegisteredAuthedPath(p: []const u8) bool {
    const exact = [_][]const u8{
        "/api/fs/list",           "/api/fs/get",           "/api/fs/dirs",
        "/api/fs/mkdir",          "/api/fs/rename",        "/api/fs/move",
        "/api/fs/copy",           "/api/fs/remove",        "/api/fs/put",
        "/api/fs/archive/list",   "/api/me",               "/api/me/update",
        "/api/auth/logout",       "/api/admin/storage",    "/api/admin/driver/names",
        "/api/admin/driver/list", "/api/admin/driver/info",
    };
    for (exact) |e| {
        if (std.mem.eql(u8, p, e)) return true;
    }
    if (std.mem.startsWith(u8, p, "/api/admin/storage/")) return true;
    if (std.mem.startsWith(u8, p, "/api/admin/setting/")) return true;
    if (std.mem.startsWith(u8, p, "/api/admin/config/")) return true;
    if (std.mem.startsWith(u8, p, "/api/task/")) return true;
    return false;
}

/// The authenticated API surface. Reached only through `handle`, which has
/// already dealt with the frontend and the public endpoints.
fn handleAuthed(app: *App, req: *http.Request, res: *http.Response) !void {
    const p = req.path;

    // Go 的 NoRoute（gin）：未注册的路径（含"前缀像已注册、端点不存在"）
    // 直接回落前端 shell —— 实测生产实例 `POST /api/nonexistent` 是 200 +
    // index.html，**不看登录状态**（NoRoute 挂在路由表外）。
    if (!isRegisteredAuthedPath(p)) return noRoute(app, req, res, p);

    // The download routes also accept a per-file sign rather than a token; see
    // `checkAuth` and docs/STATUS.md.
    var authed = try checkAuth(app, req);
    // N1：显式开启 `zig.guest_browse` 且请求**完全没有带令牌**时，只读端点
    // 按游客放行（对齐 Go `Auth(true)` 的 guest 分支）。
    if (!authed and isGuestReadRequest(app, req, p)) authed = true;
    // 文案对齐 Go 鉴权中间件（server/middlewares/auth.go:41）——
    // "Guest user is disabled, login please"（实测生产匿名请求逐字）。
    if (!authed) return res.jsonError(401, "Guest user is disabled, login please");

    if (std.mem.eql(u8, p, "/api/fs/list")) return handleFsList(app, req, res);
    if (std.mem.eql(u8, p, "/api/fs/get")) return handleFsGet(app, req, res);
    if (std.mem.eql(u8, p, "/api/fs/dirs")) return handleFsDirs(app, req, res);
    if (std.mem.eql(u8, p, "/api/fs/mkdir")) return handleFsMkdir(app, req, res);
    if (std.mem.eql(u8, p, "/api/fs/rename")) return handleFsRename(app, req, res);
    if (std.mem.eql(u8, p, "/api/fs/move")) return handleFsMove(app, req, res);
    if (std.mem.eql(u8, p, "/api/fs/copy")) return handleFsCopy(app, req, res);
    if (std.mem.eql(u8, p, "/api/fs/remove")) return handleFsRemove(app, req, res);
    if (std.mem.eql(u8, p, "/api/fs/put")) return handleFsPut(app, req, res);
    if (std.mem.eql(u8, p, "/api/fs/archive/list")) return handleFsArchiveList(app, req, res);

    // Admin surface (single-admin build: every authenticated user is the admin).
    if (std.mem.eql(u8, p, "/api/me")) return handleMe(app, req, res);
    // Profile 页的「修改资料」表单（改用户名 / 改密码）。
    // 对齐 Go `server/router.go:76` 的 `auth.POST("/me/update", handles.UpdateCurrent)`
    // —— 之前漏了，前端 Profile 页点保存会 404。
    if (std.mem.eql(u8, p, "/api/me/update")) return handleMeUpdate(app, req, res);
    // 管理页的登出。对齐 Go `auth.GET("/auth/logout", handles.LogOut)`。
    if (std.mem.eql(u8, p, "/api/auth/logout")) return handleLogout(app, req, res);
    // 存储管理面：`/api/admin/storage`（=list）与 `/list|/get|/create|/update|/delete|/enable|/disable|/load_all`
    // 共用前缀分发。对齐 Go `server/router.go:140-148` 的路由表。
    if (std.mem.eql(u8, p, "/api/admin/storage") or std.mem.startsWith(u8, p, "/api/admin/storage/")) {
        return handleAdminStorageRoute(app, req, res, p["/api/admin/storage".len..]);
    }
    if (std.mem.eql(u8, p, "/api/admin/config/export")) return handleConfigExport(app, req, res);
    if (std.mem.eql(u8, p, "/api/admin/config/import")) return handleConfigImport(app, req, res);
    if (std.mem.eql(u8, p, "/api/admin/driver/names")) return handleDriverNames(req, res);
    if (std.mem.eql(u8, p, "/api/admin/driver/list")) return handleDriverList(req, res);
    if (std.mem.eql(u8, p, "/api/admin/driver/info")) return handleDriverInfo(req, res);
    if (std.mem.startsWith(u8, p, "/api/admin/setting/")) return handleSettingRoute(app, req, res, p["/api/admin/setting/".len..]);
    if (std.mem.startsWith(u8, p, "/api/task/")) return handleTaskRoute(req, res, p["/api/task/".len..]);

    if (std.mem.startsWith(u8, p, "/d/")) return handleDownload(app, req, res, false);
    if (std.mem.startsWith(u8, p, "/p/")) return handleDownload(app, req, res, true);

    // 不可达（`isRegisteredAuthedPath` 已过滤）；保险起见仍回落 shell，
    // 保证"新增端点忘了同步清单"时给出可诊断的行为而不是 404。
    return noRoute(app, req, res, p);
}

/// Serve one of the four frontend asset prefixes, either from `dist_dir` or by
/// redirecting to the CDN. See `frontend.zig` for the branch selection.
fn handleAsset(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "GET") and !std.mem.eql(u8, req.method, "HEAD")) {
        res.setStatus(405);
        return;
    }
    // M03：传请求级 arena，别让静态资源请求往进程级 arena 里堆东西。
    switch (app.frontend.asset(req.arena, req.path, req.target)) {
        .redirect => |to| {
            res.setStatus(302);
            try res.set("Location", to);
        },
        .local => |f| {
            const file = std.Io.Dir.cwd().openFile(rt.io(), f.path, .{}) catch |e| {
                log.warn("frontend: cannot open {s}: {s}", .{ f.path, @errorName(e) });
                return res.jsonError(404, "not found");
            };
            try res.set("Content-Type", mimeFor(f.path));
            // Six months, as upstream sets for these four prefixes: the
            // frontend build content-hashes the filenames.
            try res.set("Cache-Control", "public, max-age=15552000");
            res.sendFile(file, f.size);
        },
        // No `dist_dir` and no `cdn`: nothing backs these prefixes. Returning
        // the shell here would turn a missing asset into an HTML parse error
        // buried in the browser console, so say what is wrong instead.
        .missing => {
            res.setStatus(404);
            try res.set("Content-Type", "text/plain; charset=utf-8");
            try res.write("no frontend build available: set dist_dir or cdn in config.json\n");
        },
    }
}

fn handleManifest(app: *App, res: *http.Response) !void {
    try res.set("Content-Type", "application/json");
    try res.set("Cache-Control", "public, max-age=3600");
    try res.write(app.frontend.manifest_json);
}

/// CORS 响应头（Go `server/router.go:255-260` 的 gin cors 中间件）。
///
/// 默认（`cors.allow_*` 缺省 / 全 `["*"]`）：维持通配行为 —— origin 发 `*`，
/// method/header 发固定列表（前端跨域预检一直这么工作，不改）。
/// 用户在 config.json 显式配了列表 → 按列表来：
///   * origin 不含 `*`：仅当请求 Origin 命中才回显它（+ `Vary: Origin`），
///     否则不加头（浏览器拒绝）—— 与 gin-contrib/cors 同语义；
///   * method / header 不含 `*`：逗号 join 成响应值。
fn setCors(req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const cfg = config.getOpt();

    const origins: []const []const u8 = if (cfg) |c| c.cors_allow_origins else &[_][]const u8{"*"};
    if (listHas(origins, "*")) {
        try res.set("Access-Control-Allow-Origin", "*");
    } else if (req.header("Origin")) |org| {
        if (listHas(origins, org)) {
            try res.set("Access-Control-Allow-Origin", org);
            try res.set("Vary", "Origin");
        }
    }

    // M15（审计）：Go 的三项默认都是 `["*"]`（`internal/conf/config.go:227-231`），
    // 而 gin-contrib/cors v1.7.7 只是 `strings.Join(normalize(list), ",")`
    // （utils.go:29-43）⇒ 默认值下发的是**字面的 `*`**，不是展开的列表。
    //
    // 以前这里把 `*` 展开成固定列表：Methods 缺 PATCH/HEAD；Allow-Headers 只有
    // 4 个，浏览器 WebDAV 预检带的 `Depth` / `Destination` / `Overwrite`
    // 直接被拒 ⇒ 浏览器里的 WebDAV 客户端用不了。现在照抄上游：列表本身
    // 原样 join，`["*"]` 就输出 `*`。
    //
    // 附带对齐 `convert(..., strings.ToUpper)`：Methods 值转大写。
    const methods: []const []const u8 = if (cfg) |c| c.cors_allow_methods else &[_][]const u8{"*"};
    try res.set("Access-Control-Allow-Methods", try joinListUpper(a, methods));

    const headers: []const []const u8 = if (cfg) |c| c.cors_allow_headers else &[_][]const u8{"*"};
    try res.set("Access-Control-Allow-Headers", try joinList(a, headers));
}

/// 逗号 join，方法名转大写（gin-contrib `convert(normalize(list), strings.ToUpper)`）。
fn joinListUpper(a: std.mem.Allocator, list: []const []const u8) ![]const u8 {
    var b = Buf.init(a);
    for (list, 0..) |s, i| {
        if (i > 0) try b.appendByte(',');
        const up = try a.alloc(u8, s.len);
        for (s, 0..) |c, j| up[j] = std.ascii.toUpper(c);
        try b.append(up);
    }
    return b.toOwned();
}

fn listHas(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

fn joinList(a: std.mem.Allocator, list: []const []const u8) ![]const u8 {
    var b = Buf.init(a);
    for (list, 0..) |s, i| {
        if (i > 0) try b.appendByte(',');
        try b.append(s);
    }
    return b.toOwned();
}

fn handlePing(res: *http.Response) !void {
    try res.set("Content-Type", "text/plain");
    try res.write("pong");
}

// ---------------------------------------------------------------------------
// Public settings / auth
// ---------------------------------------------------------------------------

/// Go `db.GetPublicSettingItems()` 返回的是 `flag IN (PUBLIC, READONLY)` 的项
/// （`internal/db/settingitem.go:34`），默认值全部取自 `InitialSettings()`
/// （`internal/bootstrap/data/setting.go`）。本工程没有 settings 数据库，所以这里
/// 内联同一张表：**键名与默认值照抄 Go**，其中 4 项改从实时 settings 读
/// （见 `publicSettingValue`），可被 `/api/admin/setting` 改写。
///
/// ⚠️ 值一律是**字符串**。Go 返回 `map[string]string`，前端用
/// `t === 'true' || t === '1'` 判布尔、`Number(t)` 判数字 —— 给原生 bool/int
/// 会让判断恒为 false（`true === 'true'` 不成立），页面静默走错分支。
const PublicSetting = struct { key: []const u8, value: []const u8 };

/// 与 `main.version` 保持一致（api.zig 不能 import main.zig —— 会成环）。
const server_version = "0.1.0-zig";

const public_setting_defaults = [_]PublicSetting{
    // ---- SITE ----
    .{ .key = "version", .value = "" }, // 由 publicSettingValue 填
    .{ .key = "site_title", .value = "OpenList" },
    // ⚠️ 与 Go 的**有意差异**：上游默认值是一段欢迎语（TypeText，Flag 缺省即
    // PUBLIC），Zig 这里是空串。原因见 `docs/STATUS.md` §13.2：加了欢迎语却没有
    // 前台入口去改它，用户就会看到一段永远删不掉的文案。
    //
    // 要补平成 Go 需要一起做：`/api/admin/setting` 支持 announcement 读写 +
    // `publicSettingValue` 把它接进实时 settings。`check_public_settings.py`
    // 把这一项列在 DELIBERATE 里，别当成漂移。
    .{ .key = "announcement", .value = "" },
    .{ .key = "pagination_type", .value = "all" },
    .{ .key = "default_page_size", .value = "30" },
    .{ .key = "allow_indexed", .value = "false" },
    .{ .key = "allow_mounted", .value = "true" },
    .{ .key = "robots_txt", .value = "User-agent: *\nAllow: /" },
    // ---- STYLE ----
    .{ .key = "logo", .value = "https://res.oplist.org/logo/logo.svg" },
    .{ .key = "favicon", .value = "https://res.oplist.org/logo/logo.svg" },
    .{ .key = "main_color", .value = "#1890ff" },
    .{ .key = "home_icon", .value = "🏠" },
    .{ .key = "share_icon", .value = "🎁" },
    .{ .key = "home_container", .value = "max_980px" },
    .{ .key = "settings_layout", .value = "list" },
    .{ .key = "show_disk_usage_in_plain_text", .value = "false" },
    // ---- PREVIEW ----
    .{ .key = "external_previews", .value = "{}" },
    .{ .key = "iframe_previews", .value =
        \\{"doc,docx,xls,xlsx,ppt,pptx":{"Microsoft":"https://view.officeapps.live.com/op/view.aspx?src=$e_url","Google":"https://docs.google.com/gview?url=$e_url&embedded=true"},"pdf":{"PDF.js":"https://res.oplist.org/pdf.js/web/viewer.html?file=$e_url"},"epub":{"EPUB.js":"https://res.oplist.org/epub.js/viewer.html?url=$e_url"}}
    },
    .{ .key = "audio_cover", .value = "https://res.oplist.org/logo/logo.svg" },
    .{ .key = "audio_autoplay", .value = "true" },
    .{ .key = "video_autoplay", .value = "true" },
    .{ .key = "preview_download_by_default", .value = "false" },
    .{ .key = "preview_archives_by_default", .value = "true" },
    .{ .key = "share_preview_download_by_default", .value = "true" },
    .{ .key = "share_preview_archives_by_default", .value = "false" },
    .{ .key = "readme_autorender", .value = "true" },
    .{ .key = "filter_readme_scripts", .value = "true" },
    .{ .key = "non_efs_zip_encoding", .value = "IBM437" },
    // ---- GLOBAL ----
    .{ .key = "hide_files", .value = "/\\/README.md/i" },
    .{ .key = "package_download", .value = "true" },
    .{ .key = "ocr_api", .value = "https://openlistteam-ocr-api-server.hf.space/ocr/file/json" },
    .{ .key = "filename_char_mapping", .value = "{\"/\": \"|\"}" },
    .{ .key = "forward_direct_link_params", .value = "false" },
    .{ .key = "ignore_direct_link_params", .value = "sign,openlist_ts,raw" },
    .{ .key = "webauthn_login_enabled", .value = "false" },
    .{ .key = "share_preview", .value = "false" },
    .{ .key = "share_archive_preview", .value = "false" },
    .{ .key = "share_summary_content", .value =
        \\@{{creator}} shared {{#each files}}{{#if @first}}"{{filename this}}"{{/if}}{{#if @last}}{{#unless (eq @index 0)}} and {{@index}} more files{{/unless}}{{/if}}{{/each}} from {{site_title}}: {{base_url}}/@s/{{id}}{{#if pwd}} , the share code is {{pwd}}{{/if}}{{#if expires}}, please access before {{dateLocaleString expires}}.{{/if}}
    },
    // ---- INDEX ----
    .{ .key = "search_index", .value = "none" },
    .{ .key = "auto_update_index", .value = "false" },
    // ---- SSO ----
    .{ .key = "sso_login_enabled", .value = "false" },
    .{ .key = "sso_login_platform", .value = "" },
    .{ .key = "sso_compatibility_mode", .value = "false" },
    // 上游 ea10624f 新增（`internal/conf/const.go:120` → setting.go:214，
    // TypeString + Flag PUBLIC），Go 的 public settings 因此是 **48** 项。
    // 前端 SSO 的 postMessage origin 校验读它；Zig 无 SSO，恒空串即可。
    .{ .key = "sso_postmessage_origin", .value = "" },
    // ---- LDAP ----
    .{ .key = "ldap_login_enabled", .value = "false" },
    .{ .key = "ldap_login_tips", .value = "login with ldap" },
    // ---- TRAFFIC ----
    .{ .key = "multipart_enabled", .value = "true" },
    .{ .key = "multipart_chunk_size", .value = "10" },
};

/// 4 个键有实时来源（`/api/admin/setting` 改得动），其余走表里的默认值。
/// 读 `app.frontend.settings` 而不是 `config.get()`：前者由 `App` 持有、
/// 测试里无需初始化 config 单例，且 PUT 处理器会同时更新两者。
fn publicSettingValue(app: *const App, item: PublicSetting) []const u8 {
    const s = app.frontend.settings;
    if (std.mem.eql(u8, item.key, "version")) return server_version;
    if (std.mem.eql(u8, item.key, "site_title")) return s.site_title;
    if (std.mem.eql(u8, item.key, "logo")) return s.logo;
    if (std.mem.eql(u8, item.key, "favicon")) return s.favicon;
    if (std.mem.eql(u8, item.key, "main_color")) return s.main_color;
    return item.value;
}

/// `GET /api/public/settings` —— 对齐 Go `handles.PublicSettings`
/// （`server/handles/setting.go:145` → `op.GetPublicSettingsMap()`）。
/// 之前只返回 10 个自造字段（`initial_done`/`api`/`cdn`/`token_expires_in`…），
/// 前端真正读的 30 多个键一个都没有 —— 表现就是首页 `logo` 拿到空串、
/// `<img src="">`。现在按 Go 的字段集补齐。
fn handlePublicSettings(app: *App, res: *http.Response) !void {
    const a = res.arena;
    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":{");
    for (public_setting_defaults, 0..) |item, i| {
        if (i != 0) try b.appendByte(',');
        try json.writeString(&b, item.key);
        try b.appendByte(':');
        try json.writeString(&b, publicSettingValue(app, item));
    }
    // `append` 写原始字节，不做 `print` 那样的 `{{`/`}}` 转义 —— 这里必须是
    // "}}"（关闭 data 与信封）。曾误写成 "}}}"，多出的 `}` 让整个 body 非法，
    // axios 静默把 JSON.parse 失败降级成字符串，前端只报「获取设置失败： Undefined」。
    try b.append("}}");
    try res.jsonOkRaw(b.slice());
}

/// `GET /api/public/init_status` —— 对齐 Go `server/handles/setup.go:15`
/// （`server/router.go:105` 注册为 `Any`）。
///
/// 前端 `App.tsx` 靠它决定是否跳 `/@init` 安装向导：
///   `if (initialized() === false && !pathname().startsWith("/@init")) to("/@init")`
/// 而这个请求的**失败回调在源码里被注释掉了**（静默吞错），`initialized` 于是
/// 保持 `createSignal(true)` 的默认值 —— 端点缺失（404）时前端**永远不会**引导
/// 注册，表现就是"没有注册入口，只能用已有账号登录"。
fn handleInitStatus(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "GET") and !std.mem.eql(u8, req.method, "POST")) {
        return res.jsonError(405, "method not allowed");
    }
    // Go 的判据是"管理员是否已存在"（`op.GetAdmin()` 取不到记录 ⇒ 未初始化）。
    try res.jsonOk(if (app.admin_hash.len > 0) "{\"initialized\":true}" else "{\"initialized\":false}");
}

/// `POST /api/public/init/setup` —— 对齐 Go `server/handles/setup.go:37`。
/// 只在未初始化时可调；成功后**不签发 token**（Go 只回 `data:null`，前端注册完
/// 会自己再走一次登录）。
fn handleInitSetup(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "POST")) return res.jsonError(405, "method not allowed");
    // 已初始化 ⇒ 拒绝（Go：`system has already been initialized`）。
    if (app.admin_hash.len > 0) return res.jsonError(400, "system has already been initialized");

    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const username = v.strAt("username") orelse "";
    const password = v.strAt("password") orelse "";
    if (username.len == 0 or password.len == 0) {
        return res.jsonError(400, "username and password are required");
    }
    // Go 这里是 `< 4`（setup.go:56），比 `/auth/register` 的 6 更宽松 —— 逐字对齐。
    if (password.len < 4) return res.jsonError(400, "password must be at least 4 characters");

    const cfg = config.get();
    const ca = cfg.allocator();
    // 对齐 Go `User.SetPassword`（internal/model/user.go:96）：现生成 16 位 salt，
    // 存的是 `TwoHashPwd(pwd, salt)` —— 不是裸 sha256。前端登录页发的是
    // `StaticHash(pwd)`，服务端再套一层 `HashPwd(·, salt)` 比对，所以缺了 salt
    // 这一层就永远对不上。
    const salt = try randomSalt(ca);
    const hash = try twoHashPwd(ca, password, salt);
    try cfg.putZig("admin_user", .{ .string = try ca.dupe(u8, username) });
    try cfg.putZig("admin_salt", .{ .string = salt });
    try cfg.putZig("admin_password_hash", .{ .string = hash });
    // 口令版本：让随后签发的令牌带上它（改密/重置时推进即可失效旧令牌）。
    app.admin_pwd_ts = rt.nowSeconds();
    try cfg.putZig("admin_pwd_ts", .{ .int = app.admin_pwd_ts });
    // 权限位与 Go `InitSetup` 一致（setup.go:60 的 `Permission: 0x71FF`）。
    // 落盘是为了导入 Go 配置时能保留原值，且重启后仍是同一个数。
    try cfg.putZig("admin_permission", .{ .int = 0x71FF });
    app.admin_permission = 0x71FF;
    // 可选的站点名（Go：`if req.SiteTitle != ""` 才写）。
    if (v.strAt("site_title")) |title| {
        if (title.len > 0) {
            const owned = try ca.dupe(u8, title);
            cfg.site_title = owned;
            try cfg.putZig("site_title", .{ .string = owned });
        }
    }
    cfg.save() catch |e| {
        log.warn("api: could not persist init setup: {s}", .{@errorName(e)});
        return res.jsonError(500, "could not save setup");
    };
    app.admin_user = try app.alloc.dupe(u8, username);
    app.admin_salt = try app.alloc.dupe(u8, salt);
    app.admin_hash = try app.alloc.dupe(u8, hash);
    app.frontend.settings.site_title = try app.alloc.dupe(u8, cfg.site_title);
    log.info("api: initialised by {s}", .{username});
    try res.jsonOk("null");
}

/// `POST /api/admin/user/del_cache` —— 对齐 Go `server/handles/user.go`
/// （路由见 `server/router.go:136`），由 CLI 在改完管理员凭据后调用，让在线
/// 服务丢掉内存里的凭据副本、无需重启。认证用 `zig.token`
/// （`openlist admin token` 可查看），语义对齐 Go 用 settings 表里的 token。
fn handleDelUserCache(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "POST")) return res.jsonError(405, "method not allowed");
    const cfg = config.get();
    const expected = if (cfg.raw("zig.token")) |v| (v.asStr() orelse "") else "";
    const given = req.header("Authorization") orelse "";
    if (expected.len == 0 or !std.mem.eql(u8, expected, given)) {
        return res.jsonError(401, "invalid token");
    }
    app.reloadAdminCredentials() catch |e| {
        log.warn("api: del_cache could not reload config: {s}", .{@errorName(e)});
        return res.jsonError(500, "could not reload config");
    };
    log.info("api: admin credentials reloaded from config (del_cache)", .{});
    try res.jsonOk("null");
}

/// `POST /api/auth/login` —— 收**明文**口令（Go 里标了 Deprecated 但仍可用）。
fn handleLogin(app: *App, req: *http.Request, res: *http.Response) !void {
    return loginCommon(app, req, res, false);
}

/// `POST /api/auth/login/hash` —— **前端登录页实际调用的就是这个**
/// （`server/router.go:75` → `handles.LoginHash`）。body 里的 `password`
/// 已经是 `StaticHash(明文)`，服务端只需再套一层 `HashPwd(·, salt)` 比对。
///
/// ⚠️ 这个端点曾经缺失，导致前端登录恒失败 —— curl 直接打 `/auth/login`
/// 是通的，所以「用 curl 验证过」并不等于「前端能登录」。
fn handleLoginHash(app: *App, req: *http.Request, res: *http.Response) !void {
    return loginCommon(app, req, res, true);
}

/// `already_static` = 收到的 password 是否已经过 `StaticHash`。
/// M11：登录防爆破。对齐 Go `model.LoginCache`（internal/model/user.go:33-37）：
/// 失败计数 ≥5 锁 5 分钟、期间返回 429 `TooManyAttempts`，成功清零。
///
/// ⚠️ 与 Go 的一处刻意偏差：Go 按 `c.ClientIP()` 分桶，而 Zig 0.17 的
/// `std.Io.net.Stream` **不暴露对端地址**（`http.zig` 模块头有记录），拿不到
/// IP ⇒ 退化为**全局**计数。单管理员部署（一台 NAS/一个管理员）下等价；
/// 副作用是分布式来源可把管理员账户也锁 5 分钟 —— 已按 Go 同款常量取最短锁定时。
const LoginThrottle = struct {
    mu: std.Io.Mutex = .init,
    fails: u32 = 0,
    locked_until: i64 = 0,

    /// true = 允许继续尝试；false = 处于锁定期，应回 429。
    fn allow(self: *LoginThrottle) bool {
        self.mu.lockUncancelable(rt.io());
        defer self.mu.unlock(rt.io());
        const now = rt.nowSeconds();
        if (self.locked_until > now) return false;
        if (self.locked_until != 0) {
            // 锁定期满（Go `LoginCache.Expire` 的语义）：重新计数。
            self.fails = 0;
            self.locked_until = 0;
        }
        return true;
    }

    fn recordFailure(self: *LoginThrottle) void {
        self.mu.lockUncancelable(rt.io());
        defer self.mu.unlock(rt.io());
        self.fails += 1;
        if (self.fails >= max_auth_retries) {
            self.locked_until = rt.nowSeconds() + lock_duration_s;
        }
    }

    fn recordSuccess(self: *LoginThrottle) void {
        self.mu.lockUncancelable(rt.io());
        defer self.mu.unlock(rt.io());
        self.fails = 0;
        self.locked_until = 0;
    }
};

/// Go `model.DefaultMaxAuthRetries`。
const max_auth_retries: u32 = 5;
/// Go `model.DefaultLockDuration` = 5 分钟。
const lock_duration_s: i64 = 5 * 60;
/// Go `model.InvalidUsernameOrPassword` / `model.TooManyAttempts`（逐字）。
const msg_login_failed = "Invalid username or password";
const msg_too_many = "Too many unsuccessful sign-in attempts have been made using an incorrect username or password, Try again later.";

var login_throttle = LoginThrottle{};

fn loginCommon(app: *App, req: *http.Request, res: *http.Response, already_static: bool) !void {
    if (app.admin_hash.len == 0) return res.jsonError(400, "no administrator yet; run setup first");
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const username = v.strAt("username") orelse "";
    const password = v.strAt("password") orelse "";
    // M11：锁定期内直接 429，不进入凭据比对（Go loginHash 的检查顺序一致）。
    if (!login_throttle.allow()) {
        return res.jsonError(429, msg_too_many);
    }
    if (!std.mem.eql(u8, username, app.admin_user)) {
        login_throttle.recordFailure();
        return res.jsonError(401, msg_login_failed);
    }
    // Go `User.ValidatePwd` / `ValidatePwdStaticHash`（internal/model/user.go:83-94）：
    //     PwdHash == HashPwd(<static hash>, Salt)
    // 明文接口先做一次 StaticHash；`/login/hash` 直接拿收到的 static hash 用。
    const static = if (already_static) password else try staticHash(a, password);
    const expect = try hashPwd(a, static, app.admin_salt);
    // Constant-time compare. A plain `std.mem.eql` would leak the position of
    // the first differing byte; a length check first would leak the length.
    if (!ctEqual(expect, app.admin_hash)) {
        login_throttle.recordFailure();
        return res.jsonError(401, msg_login_failed);
    }
    login_throttle.recordSuccess();
    return issueToken(app, a, res, username);
}

/// A04：签发**标准三段式 HS256 JWT**，与 Go `common.GenerateToken`
/// （server/common/auth.go:25-40）逐字段对齐：
///
///   header  = {"alg":"HS256","typ":"JWT"}
///   payload = {"username":..,"pwd_ts":..,"exp":..,"iat":..,"nbf":..}
///   sig     = base64url(HMAC-SHA256("<header_b64>.<payload_b64>", secret))
///
/// 以前这里签的是私有的两段 `payload.signature`，浏览器/第三方按标准 JWT 解不开，
/// 也不能把私有两段格式称作 JWT。
fn issueToken(app: *App, a: std.mem.Allocator, res: *http.Response, username: []const u8) !void {
    const now = rt.nowSeconds();
    const exp = now + app.token_expires_in_hours * 3600;

    const h64 = try b64Url(a, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}");

    var payload = Buf.init(a);
    try payload.append("{\"username\":");
    try json.writeString(&payload, username);
    try payload.print(",\"pwd_ts\":{d},\"exp\":{d},\"iat\":{d},\"nbf\":{d}}}", .{
        app.admin_pwd_ts, exp, now, now,
    });
    const p64 = try b64Url(a, payload.slice());

    // 签名覆盖 "header.payload"（不含末尾的点），这是 JWT 的规定。
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ h64, p64 });
    const sig = try hmacSha256(a, app.jwt_secret, signing_input);
    const s64 = try b64Url(a, &sig);
    const token = try std.fmt.allocPrint(a, "{s}.{s}", .{ signing_input, s64 });

    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":{\"token\":");
    try json.writeString(&b, token);
    try b.append("}}");
    try res.jsonOkRaw(b.slice());
}

/// M13：`Authorization` 头是否等于配置里的 admin token（`zig.token`，
/// `openlist admin token` 可查）。
///
/// 与 Go 一致的两条细节：① 比的是**整个头值**，不剥 `Bearer `；
/// ② 常量时间比较（`subtle.ConstantTimeCompare`）。未配置 token 时恒不匹配，
/// 免得空串把任何「不带 Authorization 头」的请求都放行成管理员。
fn isAdminApiToken(req: *http.Request) bool {
    const cfg = config.getOpt() orelse return false;
    const expected = if (cfg.raw("zig.token")) |v| (v.asStr() orelse "") else "";
    if (expected.len == 0) return false;
    const given = req.header("Authorization") orelse return false;
    if (given.len != expected.len) return false;
    return ctEqual(given, expected);
}

/// N1：游客（匿名）只读放行的判据。
///
/// Go 的 `Auth(true)` = allowDisabledGuest（`server/middlewares/auth.go:32-48`）：
/// 空 token ⇒ guest 用户，只有 guest 被**禁用**时才 401 ⇒ 默认部署匿名可读。
/// Zig 是单管理员模型，匿名浏览属于产品取舍（光猫暴露面），所以默认收紧，
/// 只有显式配 `zig.guest_browse = true` 才放开。
///
/// 两条刻意的边界：
///   * **只认「完全没带令牌」**。带了 Authorization / `?token=` 却校验失败的
///     是"凭据错误"，不是"匿名访问"，照旧 401 —— 否则过期令牌比匿名更好用。
///   * **只放开只读端点**（列目录 / 取详情）。游客身份下任何写操作仍 401。
fn isGuestReadRequest(app: *const App, req: *http.Request, p: []const u8) bool {
    _ = app;
    if (req.header("Authorization") != null) return false;
    if (req.queryGet("token") != null) return false;
    const cfg = config.getOpt() orelse return false;
    if (!cfg.guest_browse) return false;
    return std.mem.eql(u8, p, "/api/fs/list") or
        std.mem.eql(u8, p, "/api/fs/get") or
    std.mem.eql(u8, p, "/api/fs/dirs") or
    std.mem.eql(u8, p, "/api/fs/archive/list");
}

/// Accepts either `Authorization: Bearer <jwt>` or a `?token=` query param
/// (the browser needs the latter for `<video src>`).
fn checkAuth(app: *App, req: *http.Request) !bool {
    // M13（审计）：Go 鉴权中间件的**第一分支**是 admin token
    // （server/middlewares/auth.go:19-31）—— `Authorization` 头**整体**（不剥
    // `Bearer `）与 `setting.GetStr(conf.Token)` 做常量时间比较，命中即视为
    // 管理员，对**所有**走 Auth 中间件的端点有效。
    // 以前本工程只在 `/api/admin/user/del_cache` 认它，持 Go admin token 的
    // 第三方脚本/工具在其余端点全 401。
    if (isAdminApiToken(req)) return true;

    var token: []const u8 = "";
    if (req.header("Authorization")) |h| {
        const prefix = "Bearer ";
        if (h.len > prefix.len and std.ascii.eqlIgnoreCase(h[0..prefix.len], prefix)) {
            token = h[prefix.len..];
        } else {
            token = h;
        }
    } else if (req.queryGet("token")) |t| {
        token = t;
    }
    if (token.len == 0) return false;

    // A04：标准三段式 `header.payload.signature`。以前按最后一个点切两段，
    // 结构对不上标准 JWT。
    var parts = std.mem.splitScalar(u8, token, '.');
    const h64 = parts.next() orelse return false;
    const p64 = parts.next() orelse return false;
    const s64 = parts.next() orelse return false;
    if (parts.next() != null) return false; // 多于三段：拒绝
    if (h64.len == 0 or p64.len == 0 or s64.len == 0) return false;

    // 签名覆盖 "header.payload"。
    const signing_input = try std.fmt.allocPrint(req.arena, "{s}.{s}", .{ h64, p64 });
    const expected = try hmacSha256(req.arena, app.jwt_secret, signing_input);
    const got_raw = b64UrlDecode(req.arena, s64) catch return false;

    // A02：长度先判，绝不把长度差窄化进 u8；再常量时间比较。
    if (got_raw.len != expected.len) return false;
    if (!ctEqual(got_raw, &expected)) return false;

    // M14：签名对得上之后才查作废表 —— 只有真令牌能被登记（登出本身要先
    // 过鉴权），所以这里不存在「伪造签名把别人的令牌作废」的路径。
    if (g_invalidated_tokens.contains(s64)) {
        log.info("api: token rejected: logged out", .{});
        return false;
    }

    const payload = b64UrlDecode(req.arena, p64) catch return false;
    const v = json.parse(req.arena, payload) catch return false;

    // A03：令牌必须绑在「当前管理员 + 当前口令版本」上。
    // Go 在 server/middlewares/auth.go:55-68 做同样两件事：按 username 取用户，
    // 再比对 user.PwdTS。改密后旧令牌在这里被拒，而不是继续有效到过期。
    const uname = v.strAt("username") orelse return false;
    if (!std.mem.eql(u8, uname, app.admin_user)) return false;

    const pwd_ts = v.intAt("pwd_ts") orelse 0;
    if (pwd_ts != app.admin_pwd_ts) {
        log.warn("api: token rejected: password changed since it was issued", .{});
        return false;
    }

    const exp = v.intAt("exp") orelse return false;
    return rt.nowSeconds() < exp;
}

// ---------------------------------------------------------------------------
// /api/fs/*
// ---------------------------------------------------------------------------

/// M12：对齐 Go `FsDirs`（server/handles/fsread.go:129-179）的**契约**：
///   * 语义 = 列出**请求路径的子目录**（根路径 ⇒ `fs.List("/")` 的挂载点项），
///     不是"列出挂载点本身"（原实现把这个端点当成了挂载表）。
///   * 形状 = `data` 为**裸数组** `[{"name":..,"modified":..}]`（`DirResp`），
///     不是 `{"content":[...]}`。
///   * 根路径的 name/modified 与 `fs/list` 根条目同源（挂载路径 / 存储的
///     modified —— Go `getStorageVirtualFilesByPath` 用 `Storage.Modified`）。
fn handleFsDirs(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const raw_path = v.strAt("path") orelse "/";

    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":[");
    var first = true;
    if (std.mem.eql(u8, raw_path, "/")) {
        const mounts = app.mountsSnapshot();
        for (mounts) |m| {
            if (!first) try b.appendByte(',');
            first = false;
            try b.append("{\"name\":");
            try json.writeString(&b, std.mem.trim(u8, m.mount_path, "/"));
            try b.append(",\"modified\":");
            try json.writeString(&b, try fmtTime(a, m.storage.modified));
            try b.appendByte('}');
        }
    } else {
        const r = app.resolve(raw_path) orelse return res.jsonError(404, "storage not found");
        var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
        const objs = r.mount.driver.list(&ctx, r.rel) catch |e| return mapDriverError(res, e, &ctx);
        for (objs) |o| {
            // Go `filterDirs`：只保留目录（fsread.go:181-189）。
            if (!o.is_dir) continue;
            if (!first) try b.appendByte(',');
            first = false;
            try b.append("{\"name\":");
            try json.writeString(&b, o.name);
            try b.append(",\"modified\":");
            try json.writeString(&b, try fmtTime(a, o.modified));
            try b.appendByte('}');
        }
    }
    try b.append("]}");
    try res.jsonOkRaw(b.slice());
}

fn handleFsList(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const raw_path = v.strAt("path") orelse "/";
    // 对齐 Go `JoinBasePath`（pkg/utils/path.go:81-87）：
    //   * 空串与 "/" 都表示根（cleanPath("") == "/"）；
    //   * 原始路径含 ".." 而规范化后不再含 → `errs.RelativePath`（403），
    //     而不是让它一路走到 resolve 变成 404 —— 差的就是这个状态码。
    const path = urlmod.cleanPath(a, raw_path) catch raw_path;
    if (std.mem.indexOf(u8, raw_path, "..") != null and
        std.mem.indexOf(u8, path, "..") == null)
    {
        return res.jsonError(403, err_relative_path);
    }

    if (std.mem.eql(u8, path, "/")) {
        return listRoot(app, res, v.intAt("page") orelse 0, v.intAt("per_page") orelse 0);
    }
    const r = app.resolve(path) orelse return res.jsonError(404, "storage not found");

    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    const objs = r.mount.driver.list(&ctx, r.rel) catch |e| {
        return mapDriverError(res, e, &ctx);
    };

    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":{\"content\":[");
    // L23：Go 的 `FsList` 末尾会过一遍 `pagination(objs, &req.PageReq)`
    // （fsread.go:104-107 → 216-230）：按 `page` / `per_page` 切片，
    // `total` 仍是**切片前**的总数。以前这里恒返回全量 —— 只有客户端
    // 显式分页时才有差别（缺省 per_page=MaxInt ⇒ 不分页）。
    const page = v.intAt("page") orelse 0;
    const per_page = v.intAt("per_page") orelse 0;
    for (paginate(model.Obj, objs, page, per_page), 0..) |o, i| {
        if (i != 0) try b.appendByte(',');
        // 规范化列目录路径再 join，和 Go 的 `utils.FixAndCleanPath(dirParam)`
        // 一致 —— 否则 `//a`、`/a/./` 会签出与请求路径不同的签名。
        const dir_clean = urlmod.cleanPath(a, path) catch path;
        const child = try urlmod.joinPath(a, if (dir_clean.len == 1) "" else dir_clean, o.name);
        try writeObj(app, &b, o, child);
    }
    try b.append("],\"total\":");
    try b.print("{d}", .{objs.len});
    try appendFsListTail(&b);
    try res.jsonOkRaw(b.slice());
}

/// `FsListResp` 的尾部字段 —— Go `server/handles/fsread.go:49-58`。
/// **不能省**：前端 store 用 `setWrite(e.write)` 决定是否渲染上传/新建/删除按钮，
/// 字段缺失会让 `write` 变 `undefined`、目录被判成只读（按钮整片消失）。
///   * `readme` / `header` —— 来自 meta；本工程没有 meta，恒空串；
///   * `write` —— 单管理员构建，认证用户一律可写；
///   * `write_content_bypass` —— 无 meta 权限模型，恒 false；
///   * `provider` —— Go 侧也是硬编码 `"unknown"`（fsread.go:110 赋值后再没改过）；
///   * `direct_upload_tools` —— Go 标了 `omitempty`，驱动未实现 `DirectUploader`
///     就不发这个键，这里同样省略。
fn appendFsListTail(b: *Buf) !void {
    try b.append(",\"readme\":\"\",\"header\":\"\",\"write\":true,\"write_content_bypass\":false,\"provider\":\"unknown\"}}");
}

/// Go `pagination`（`server/handles/fsread.go:216-230`，配合 `PageReq.Validate`）。
///
/// Go 的 `FsList` 在 `toObjsResp` 之前会先按 `page` / `per_page` 切一刀：
/// `start = (page-1) * per_page`，`start > total` ⇒ 空数组；`total` 仍是
/// **切片前**的条数。缺省（0 或负）时 `Validate()` 归一成 `page=1`、
/// `per_page=MaxInt` ⇒ 等价于不分页。
///
/// 这里逐条照抄：溢出用饱和运算顶住（Go 是 int 溢出，行为未定义，不值得
/// 复刻崩溃），其余边界（`start > total`）与 Go 一致。
fn paginate(comptime T: type, objs: []const T, page: i64, per_page: i64) []const T {
    const p: i64 = if (page < 1) 1 else page;
    const ps: i64 = if (per_page < 1) std.math.maxInt(i64) else per_page;
    const total: i64 = @intCast(objs.len);
    const start64 = std.math.mul(i64, p - 1, ps) catch std.math.maxInt(i64);
    if (start64 > total) return &.{};
    const start: usize = @intCast(@min(start64, total));
    const end64 = std.math.add(i64, start64, ps) catch std.math.maxInt(i64);
    const end: usize = @intCast(@min(end64, total));
    return objs[start..end];
}

/// The virtual root shows one entry per mount, exactly like OpenList.
fn listRoot(app: *App, res: *http.Response, page: i64, per_page: i64) !void {
    const a = res.arena;
    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":{\"content\":[");
    const mounts = app.mountsSnapshot();
    const shown = paginate(Mount, mounts, page, per_page);
    for (shown, 0..) |m, i| {
        if (i != 0) try b.appendByte(',');
        try b.append("{\"name\":");
        try json.writeString(&b, std.mem.trim(u8, m.mount_path, "/"));
        // Go 的 time.Time 零值 JSON 是 RFC3339 的 year-1，而不是空串；空串
        // 进入前端 `new Date(...).getTime()` 就会变成 NaN。
        try b.append(",\"size\":0,\"is_dir\":true,\"modified\":\"0001-01-01T00:00:00Z\",\"created\":\"0001-01-01T00:00:00Z\"");
        // 挂载点都是目录 → Go 的 FOLDER = 1（以前这里写的是自造的 2）。
        // hashinfo/hash_info：Go 的挂载对象零值 HashInfo ⇒ hashinfo 是字符串
        // "null"、hash_info 是 null（pkg/utils/hash.go:207-215）。
        try b.append(",\"sign\":\"\",\"thumb\":\"\",\"type\":1,\"hashinfo\":\"null\",\"hash_info\":null}");
    }
    try b.append("],\"total\":");
    try b.print("{d}", .{mounts.len});
    try appendFsListTail(&b);
    try res.jsonOkRaw(b.slice());
}

fn handleFsGet(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const raw_path = v.strAt("path") orelse "/";
    // 同 `handleFsList`：对齐 Go `JoinBasePath`（空串=根；含 ".." 且规范化后
    // 消失 → 403 RelativePath）。
    const path = urlmod.cleanPath(a, raw_path) catch raw_path;
    if (std.mem.indexOf(u8, raw_path, "..") != null and
        std.mem.indexOf(u8, path, "..") == null)
    {
        return res.jsonError(403, err_relative_path);
    }

    // 对齐 Go `internal/fs/get.go:25-30`：`/` 不属于任何挂载，但 Go 对它返回一个
    // **虚拟根对象**（`name:"root", is_dir:true, Mask:ReadOnly|Virtual`），而不是
    // "storage not found"。前端 Layout 进首页第一个请求就是 `fs/get /`，此前这里
    // 回了 404，首页直接显示 404（管理后台走的是 storage/list 所以看起来正常）。
    // provider 也对齐 Go：虚拟根取不到 storage ⇒ 空串（fsread.go:309-311 的
    // `!ok && err == nil` 分支不成立）。
    if (std.mem.eql(u8, path, "/")) {
        return res.jsonOk("{\"name\":\"root\",\"size\":0,\"is_dir\":true,\"modified\":\"0001-01-01T00:00:00Z\",\"created\":\"0001-01-01T00:00:00Z\",\"sign\":\"\",\"thumb\":\"\",\"type\":1,\"hashinfo\":\"null\",\"hash_info\":null,\"raw_url\":\"\",\"readme\":\"\",\"header\":\"\",\"provider\":\"\",\"related\":[]}");
    }

    const r = app.resolve(path) orelse return res.jsonError(404, "storage not found");
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    const f = r.mount.driver.details(&ctx, r.rel) catch |e| return mapDriverError(res, e, &ctx);

    // 与 Go `server/common/sign.go` 一致：目录 sign 为空串；文件在
    // `sign_all` 开（或 meta 加密）时签完整路径。fs/get 的 `sign` 字段与
    // raw_url 上带的 `?sign=` 必须是同一个值 —— 前端音频/视频播放器直接用
    // raw_url，不带 sign 的 `/p` 在 sign_all 部署下会被 401（实测踩过）。
    const sign_val = try signForObj(app, a, f.is_dir, path);

    var raw_url: []const u8 = "";
    if (!f.is_dir) {
        // A05：把调用方的请求头交给驱动。115 按 User-Agent 下发下载链接，部分
        // 网盘要求 Referer —— 空 LinkArgs 拿到的 URL 前端直接用不了。
        const lk = r.mount.driver.link(&ctx, r.rel, .{ .headers = req.headers }) catch |e| {
            log.warn("api: link {s} failed: {s}", .{ path, @errorName(e) });
            return mapDriverError(res, e, &ctx);
        };
        // 与 Go `server/handles/fsread.go:318-339` 一致：需要服务端代理的
        // （或本地文件）给出本站 `/p` 可鉴权 URL，不能把带 Cookie 才能用的
        // CDN 地址直接丢给浏览器；只有真正可直链的才回上游 URL。
        // 带 sign 的方式对齐 Go `common.GenerateDownProxyURL`
        // （server/common/proxy.go:31-33：`?sign=` + `sign.Sign(reqPath)`）；
        // 路径编码对齐 `utils.EncodePath(reqPath, true)`（`.path` 保留 `/`）。
        if (lk.proxy or lk.local_path != null) {
            const enc = try urlmod.encode(a, path, .path);
            raw_url = if (sign_val.len == 0)
                try std.fmt.allocPrint(a, "/p{s}", .{enc})
            else
                try std.fmt.allocPrint(a, "/p{s}?sign={s}", .{ enc, sign_val });
        } else {
            raw_url = lk.url;
        }
    }

    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":{");
    try b.print("\"name\":", .{});
    try json.writeString(&b, f.name);
    try b.print(",\"size\":{d},\"is_dir\":{s}", .{ f.size, if (f.is_dir) "true" else "false" });
    try b.append(",\"modified\":");
    try json.writeString(&b, try fmtTime(a, f.modified));
    try b.append(",\"created\":");
    try json.writeString(&b, try fmtTime(a, if (f.created == 0) f.modified else f.created));
    try b.append(",\"sign\":");
    // 对齐 Go `server/common/sign.go`：非目录且 `sign_all` 开时给一个可拼到
    // `/p`、`/d` 后的下载签名（否则空串）。此前这里透传驱动给的 `f.sign`
    // （恒为空），前端拿到的是空 sign，`sign_all=true` 的部署下点不开文件。
    try json.writeString(&b, sign_val);
    // M9：补 `thumb` + `hashinfo` + `hash_info`。Go `FsGetResp` 内嵌
    // `ObjResp`（fsread.go:255-266），字段顺序 sign → thumb → type →
    // hashinfo → hash_info（`toObjsResp` 的 `HashInfoStr`/`HashInfo`）。
    try b.append(",\"thumb\":");
    try json.writeString(&b, f.thumb);
    try b.append(",\"type\":");
    // A06：按 Go 的 `GetObjType` 输出（FOLDER=1、VIDEO=2、AUDIO=3、TEXT=4、
    // IMAGE=5），不再是自造的 file=1/folder=2。
    try b.print("{d}", .{@backingInt(model.objTypeFor(f.name, f.is_dir))});
    try appendHashFields(&b, a, f.hash_info);
    try b.append(",\"raw_url\":");
    try json.writeString(&b, raw_url);
    // Go 的 `FsGetResp` = `ObjResp` + raw_url/readme/header/provider/related
    // （server/handles/fsread.go:249-255）。`provider` 取驱动名 —— 对齐
    // fsread.go:309-311（`model.GetProvider` 拿不到就回落 `storage.Config().Name`）。
    // header/related 前端当前不读，一并补齐，免得再漏。
    try b.append(",\"readme\":\"\",\"header\":\"\",\"provider\":");
    try json.writeString(&b, r.mount.storage.driver);
    try b.append(",\"related\":[");
    // 对齐 Go `FsGet`（fsread.go:350-357 + filterRelated:383）：**仅视频文件**
    // 才列一次父目录、挑出"同名前缀"的兄弟文件作为 related（上游 9de3f69b 才把
    // 条件从"所有文件"收窄到"视频"）。前端播放器拿它做同目录剧集/字幕/外挂
    // 音轨 —— 此前这里恒发空数组，等于这个功能从来没生效过。
    //
    // 列目录失败不能让 fs/get 整体 500：Go 的写法是 `if err == nil` 才填，
    // 出错就留空。
    if (!f.is_dir and model.objTypeFor(f.name, false) == .video) {
        appendRelated(app, &b, a, path, f.name) catch {};
    }
    try b.append("]}}");
    try res.jsonOkRaw(b.slice());
}

/// Go `filterRelated` 的 `strings.TrimSuffix(name, stdpath.Ext(name))`：
/// `movie.mp4` → `movie`，用来前缀匹配 `movie.srt` 这类外挂文件。
fn stemOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

/// 把 `related` 数组写进 `b`（不含外层方括号）。`path` 是被请求视频的完整路径。
fn appendRelated(app: *App, b: *Buf, a: std.mem.Allocator, path: []const u8, name: []const u8) !void {
    const parent = dirnameRel(path);
    const pr = app.resolve(parent) orelse return;
    var pctx = driver.Ctx{ .alloc = a, .tag = pr.mount.mount_path };
    const objs = try pr.mount.driver.list(&pctx, pr.rel);
    // `resolve` 保证父目录与被请求文件落在**同一个挂载**内，所以这里不需要
    // 再做跨挂载判断（Go 的 `fs.List(parentPath)` 同样只解析到一个挂载）。
    const stem = stemOf(name);
    var n: usize = 0;
    for (objs) |o| {
        if (std.mem.eql(u8, o.name, name)) continue;
        if (!std.mem.startsWith(u8, o.name, stem)) continue;
        if (n != 0) try b.appendByte(',');
        const child = try urlmod.joinPath(a, if (parent.len == 1) "" else parent, o.name);
        try writeObj(app, b, o, child);
        n += 1;
    }
}

/// Go `errs.RelativePath` 的文案（`internal/errs/errors.go:13`）。
const err_relative_path = "using relative path is not allowed";

/// 对齐 Go `server/handles/fsmanage.go:338` 的 `checkRelativePath`（上游
/// ea10624f 安全加固）：`names[]` 的元素与 rename 的 `name` 必须是**纯文件名**
/// —— 含 `/` 或 `\`、空串、`.`、`..` 一律 403 `errs.RelativePath`。
/// 上游在四处调用：`FsMove(:116)` / `FsCopy(:223)` / `FsRename(:306)` /
/// `FsRemove(:384)`。
///
/// 为什么必须查：`urlmod.joinPath` 是纯字符串拼接、**不归一化 `..`**。没有这层
/// 校验时 `names:["../x"]` 会拼出 `src_dir/../x` 直接交给驱动（local 有
/// `cleanPath` 兜底，云盘驱动多半 404，但都与上游不一致），`names:["a/b"]`
/// 更是直接操作子路径 —— 两者上游都是 403。
fn isPlainFileName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfScalar(u8, name, '/') == null and
        std.mem.indexOfScalar(u8, name, '\\') == null;
}

fn handleFsMkdir(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const path = v.strAt("path") orelse return res.jsonError(400, "path is required");
    const r = app.resolve(path) orelse return res.jsonError(404, "storage not found");
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    r.mount.driver.makeDir(&ctx, r.rel) catch |e| return mapDriverError(res, e, &ctx);
    try res.jsonOk("null");
}

/// `POST /api/fs/copy` —— 与 `move` 同形，但把条目**复制**到目标目录（保留原名）。
/// 驱动没有 copy 能力时返回 501（`NotSupported`）。
fn handleFsCopy(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const src_dir = v.strAt("src_dir") orelse return res.jsonError(400, "src_dir is required");
    const dst_dir = v.strAt("dst_dir") orelse return res.jsonError(400, "dst_dir is required");
    const names = v.getPath("names") orelse return res.jsonError(400, "names is required");
    const arr = names.asArray() orelse return res.jsonError(400, "names must be an array");
    // 对齐 Go `FsCopy`（fsmanage.go:182）：空数组是显式 400，不是"什么都不做然后 200"。
    if (arr.len == 0) return res.jsonError(400, "Empty file names");

    for (arr) |*n| {
        const name = n.asStr() orelse continue;
        // 对齐 Go `checkRelativePath`（fsmanage.go:223）。
        if (!isPlainFileName(name)) return res.jsonError(403, err_relative_path);
        const src = try urlmod.joinPath(a, src_dir, name);
        const sr = app.resolve(src) orelse return res.jsonError(404, "storage not found");
        const dr = app.resolve(dst_dir) orelse return res.jsonError(404, "storage not found");
        // 跨挂载点复制需要「下载 + 上传」，本工程没有；明确拒绝好过静默做错。
        if (sr.mount != dr.mount) return res.jsonError(400, "copying between storages is not supported yet");
        var ctx = driver.Ctx{ .alloc = a, .tag = sr.mount.mount_path };
        sr.mount.driver.copy(&ctx, sr.rel, dr.rel) catch |e| return mapDriverError(res, e, &ctx);
        notifyObjsUpdateAfterWrite(app, a, dr.mount, dst_dir);
    }
    try res.jsonOk("null");
}

fn handleFsRename(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const path = v.strAt("path") orelse return res.jsonError(400, "path is required");
    const name = v.strAt("name") orelse return res.jsonError(400, "name is required");
    // 对齐 Go `FsRename`（fsmanage.go:306）—— 五个端点里唯一原本就有此校验的。
    if (!isPlainFileName(name)) return res.jsonError(403, err_relative_path);
    const r = app.resolve(path) orelse return res.jsonError(404, "storage not found");
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    r.mount.driver.rename(&ctx, r.rel, name) catch |e| return mapDriverError(res, e, &ctx);
    notifyObjsUpdateAfterWrite(app, a, r.mount, dirnameRel(path));
    try res.jsonOk("null");
}

fn handleFsMove(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const src_dir = v.strAt("src_dir") orelse return res.jsonError(400, "src_dir is required");
    const dst_dir = v.strAt("dst_dir") orelse return res.jsonError(400, "dst_dir is required");
    const names = v.getPath("names") orelse return res.jsonError(400, "names is required");
    const arr = names.asArray() orelse return res.jsonError(400, "names must be an array");
    // 对齐 Go `FsMove`（fsmanage.go:76）。
    if (arr.len == 0) return res.jsonError(400, "Empty file names");

    for (arr) |*n| {
        const name = n.asStr() orelse continue;
        // 对齐 Go `checkRelativePath`（fsmanage.go:116）。
        if (!isPlainFileName(name)) return res.jsonError(403, err_relative_path);
        const src = try urlmod.joinPath(a, src_dir, name);
        const sr = app.resolve(src) orelse return res.jsonError(404, "storage not found");
        const dr = app.resolve(dst_dir) orelse return res.jsonError(404, "storage not found");
        // Cross-mount moves would need a copy+delete the skeleton does not
        // implement; refusing is better than silently doing the wrong thing.
        if (sr.mount != dr.mount) return res.jsonError(400, "moving between storages is not supported yet");
        var ctx = driver.Ctx{ .alloc = a, .tag = sr.mount.mount_path };
        sr.mount.driver.move(&ctx, sr.rel, dr.rel) catch |e| return mapDriverError(res, e, &ctx);
        notifyObjsUpdateAfterWrite(app, a, dr.mount, dst_dir);
    }
    try res.jsonOk("null");
}

fn handleFsRemove(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const dir = v.strAt("dir") orelse return res.jsonError(400, "dir is required");
    const names = v.getPath("names") orelse return res.jsonError(400, "names is required");
    const arr = names.asArray() orelse return res.jsonError(400, "names must be an array");
    // 对齐 Go `FsRemove`（fsmanage.go:358）。
    if (arr.len == 0) return res.jsonError(400, "Empty file names");

    for (arr) |*n| {
        const name = n.asStr() orelse continue;
        // 对齐 Go `checkRelativePath`（fsmanage.go:384）。
        if (!isPlainFileName(name)) return res.jsonError(403, err_relative_path);
        const full = try urlmod.joinPath(a, dir, name);
        const r = app.resolve(full) orelse return res.jsonError(404, "storage not found");
        var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
        // Stat first: itvsh needs to know file vs directory, and guessing from
        // the name is exactly the kind of shortcut that deletes the wrong thing.
        const f = r.mount.driver.details(&ctx, r.rel) catch |e| return mapDriverError(res, e, &ctx);
        r.mount.driver.remove(&ctx, r.rel, f.is_dir) catch |e| return mapDriverError(res, e, &ctx);
        notifyObjsUpdateAfterWrite(app, a, r.mount, dir);
    }
    try res.jsonOk("null");
}

/// `PUT /api/fs/put` with the target in the `File-Path` header and the bytes
/// as the raw body — this is the shape OpenList's frontend uses.
fn handleFsPut(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const raw_path = req.header("File-Path") orelse return res.jsonError(400, "File-Path header is required");
    const path = urlmod.decode(a, raw_path) catch return res.jsonError(400, "bad File-Path");
    const r = app.resolve(path) orelse return res.jsonError(404, "storage not found");

    var body = req.body;
    // A single-put upload reports progress inline; the frontend's chunked upload
    // (many small PUTs) is what surfaces a live bar via this same callback.
    var prog = PutProgress{ .pct = 0 };
    var ctx = driver.Ctx{
        .alloc = a,
        .tag = r.mount.mount_path,
        .progress = putProgressCb,
        .progress_userdata = &prog,
    };
    // Go 的 FileStreamer 带 mimetype（webdav 驱动的 Put callback 会把它设成
    // Content-Type，drivers/webdav/driver.go:117-119）。从目标文件名推断补上
    // —— 目前只有 webdav 驱动消费（AUDIT_2026-10-18-drivers.md §4-P1-2）。
    var src = body.source();
    src.mime = mimeFor(std.fs.path.basename(r.rel));
    r.mount.driver.put(&ctx, r.rel, src) catch |e| return mapDriverError(res, e, &ctx);
    try res.jsonOk("null");
}

// ---------------------------------------------------------------------------
// Archive browsing (read-only ZIP/TAR virtual directories)
// ---------------------------------------------------------------------------

const ArchiveFileSource = struct {
    file: std.Io.File,
    size: i64,

    fn getSize(p: *anyopaque) i64 {
        const self: *ArchiveFileSource = @ptrCast(@alignCast(p));
        return self.size;
    }
    fn readAt(p: *anyopaque, offset: u64, buf: []u8) anyerror!usize {
        const self: *ArchiveFileSource = @ptrCast(@alignCast(p));
        return std.Io.File.readPositionalAll(self.file, rt.io(), buf, offset);
    }
    const vtable = model.Source.VTable{ .size = getSize, .readAt = readAt };

    fn source(self: *ArchiveFileSource) model.Source {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// `POST /api/fs/archive/list` — browse one level inside a local ZIP/TAR. Like
/// upstream this is a virtual read-only filesystem; no archive bytes are copied
/// into RAM. ZIP reads just its end record and central directory; TAR scans
/// 512-byte headers by offset. Remote archives are rejected until the upstream
/// client has a response-stream API (buffering a large archive is unsafe on the
/// router's 128 MiB RAM budget).
fn handleFsArchiveList(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const path = v.strAt("path") orelse return res.jsonError(400, "path is required");
    const inner = v.strAt("inner_path") orelse "";
    const page: usize = @intCast(@max(v.intAt("page") orelse 1, 1));
    const per_page: usize = @intCast(@max(v.intAt("per_page") orelse 1000000, 1));

    const r = app.resolve(path) orelse return res.jsonError(404, "storage not found");
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    const f = r.mount.driver.details(&ctx, r.rel) catch |e| return mapDriverError(res, e, &ctx);
    if (f.is_dir) return res.jsonError(400, "archive path is a directory");
    const format = archive.detect(f.name) orelse return res.jsonError(415, "only ZIP and TAR archives are supported");
    // 请求头同样透传（Go archive.go:114 `Header: c.Request.Header`）。当前
    // 本实现只支持本地归档（远端 501），但这行是防止将来支持远端时踩 115
    // 的 UA 绑定签名坑（见 webdav.zig 的 A05 注释 / STATUS §41.6）。
    const lk = r.mount.driver.link(&ctx, r.rel, .{
        .redirect = false,
        .headers = req.headers,
    }) catch |e| return mapDriverError(res, e, &ctx);
    const local_path = lk.local_path orelse return res.jsonError(501, "remote archive browsing is not available yet");
    const file = std.Io.Dir.cwd().openFile(rt.io(), local_path, .{}) catch |e| {
        log.warn("api: open archive {s} failed: {s}", .{ local_path, @errorName(e) });
        return res.jsonError(404, "archive file not found");
    };
    defer file.close(rt.io());
    var src_ctx = ArchiveFileSource{ .file = file, .size = @intCast(lk.local_size) };
    const entries = archive.list(a, src_ctx.source(), format, inner) catch |e| {
        log.warn("api: list archive {s} failed: {s}", .{ path, @errorName(e) });
        return res.jsonError(400, "invalid or unsupported archive");
    };

    const start = @min((page - 1) *| per_page, entries.len);
    const end = @min(start +| per_page, entries.len);
    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":{\"content\":[");
    for (entries[start..end], 0..) |entry, i| {
        if (i != 0) try b.appendByte(',');
        const o = model.Obj{
            .name = entry.name,
            .size = entry.size,
            .is_dir = entry.is_dir,
            .modified = entry.modified,
        };
        // 归档内条目的虚拟路径 = `<压缩包路径>/<inner>/<name>`，与 Go 的
        // `archive.go` 一致（`archiver` 包把包内路径挂在真实路径下）。
        const inner_clean = if (inner.len == 0) "" else inner;
        const child = try urlmod.joinPath(a, path, try urlmod.joinPath(a, inner_clean, entry.name));
        try writeObj(app, &b, o, child);
    }
    try b.append("],\"total\":");
    try b.print("{d}", .{entries.len});
    try b.append("}}");
    try res.jsonOkRaw(b.slice());
}

// ---------------------------------------------------------------------------
// Admin surface (/api/admin/* and /api/me)
//
// This is a single-admin build, so every authenticated caller is the admin.
// The frontend's settings page and the storage/task-centre management UI hang
// off these endpoints; they were the last unimplemented part of the /api/*
// surface. The handlers below mirror the upstream shapes closely enough that
// the stock OpenList frontend loads and saves without a shim.
// ---------------------------------------------------------------------------

/// `GET /api/me` — the current user record.
///
/// 字段必须与 Go 的 `handles.UserResp`（server/handles/auth.go:87）逐一对齐：
/// 它是 `model.User` 的内嵌 + `Otp bool json:"otp"`，而 `model.User` 里
/// `OtpSecret`/`Authn`/`PwdHash`/`PwdTS`/`Salt` 都标了 `json:"-"` **不输出**。
///
/// ⚠️ 2026-10-15 踩过：这里曾经缺 `sso_id` / `allow_ldap` / `otp`，又多输出了
/// `otp_secret` 和一个 User 里根本不存在的 `token`。缺字段会让上游前端的 JS
/// 读到 `undefined` 后抛错 —— 表现为**登录成功后一直转圈**，而服务端日志一切正常。
/// 这种"契约字段缺失"光看 HTTP 状态码（全是 200）是发现不了的。
fn handleMe(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":{");
    try b.print("\"id\":{d},", .{1});
    try b.append("\"username\":");
    try json.writeString(&b, app.admin_user);
    try b.append(",\"password\":\"\",\"base_path\":\"/\",\"role\":2,\"disabled\":false");
    try b.print(",\"permission\":{d}", .{app.admin_permission});
    // `model.User.SsoID` / `AllowLdap` 有 json tag，Go 会输出；本实现没有 SSO
    // 与 LDAP，固定给空串与 Go 的 gorm default（true）。
    try b.append(",\"sso_id\":\"\",\"allow_ldap\":true");
    // `UserResp.Otp`：Go 是 `OtpSecret != ""` 时为 true。本实现没有 OTP。
    try b.append(",\"otp\":false");
    try b.append("}}");
    try res.jsonOkRaw(b.slice());
}

/// `POST /api/me/update` —— 改用户名 / 改密码。
///
/// 对齐 Go `handles.UpdateCurrent`（`server/handles/auth.go:106-145`）：
///   * `user.Username = req.Username`（无条件赋值）
///   * `if req.Password != "" { user.SetPassword(req.Password) }` —— 空串表示"不改"
///   * `op.UpdateUser(user)` 失败 → 500，成功 → `SuccessResp`（`data: null`）
///
/// 与本构建有关的几点：
///   * 单管理员，所以"改用户名"就是改 `zig.admin_user`。Go 那边有 guest 判断
///     （`IsGuest` → 403），这里没有 guest 概念。
///   * SSO 绑定校验（`req.SsoID`）本构建没有，跳过。
///   * 改密会推进 `admin_pwd_ts` ⇒ `checkAuth` 拒绝旧令牌（见其 A03 注释），
///     等价于 Go 的 `user.PwdTS` 比对。
fn handleMeUpdate(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "POST")) return res.jsonError(405, "method not allowed");
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const cfg = config.get();
    const ca = cfg.allocator();

    // Go 无条件赋值；这里拒绝空串 —— 单管理员把名字改成空只会让登录变不可能。
    const username = v.strAt("username") orelse return res.jsonError(400, "username is required");
    if (username.len == 0) return res.jsonError(400, "username is required");

    // 密码：空串 = 不改（Go 同样语义）。
    const password = v.strAt("password") orelse "";
    var pwd_changed = false;
    if (password.len > 0) {
        if (password.len < 4) return res.jsonError(400, "password must be at least 4 characters");
        // 复用建号时的同一条路径：新 salt + TwoHashPwd，与 Go SetPassword 一致。
        const salt = try randomSalt(ca);
        const hash = try twoHashPwd(ca, password, salt);
        try cfg.putZig("admin_salt", .{ .string = salt });
        try cfg.putZig("admin_password_hash", .{ .string = hash });
        // 推进口令版本 ⇒ 已签发的令牌全部失效。
        app.admin_pwd_ts = rt.nowSeconds();
        try cfg.putZig("admin_pwd_ts", .{ .int = app.admin_pwd_ts });
        app.admin_salt = try app.alloc.dupe(u8, salt);
        app.admin_hash = try app.alloc.dupe(u8, hash);
        pwd_changed = true;
    }

    try cfg.putZig("admin_user", .{ .string = try ca.dupe(u8, username) });
    app.admin_user = try app.alloc.dupe(u8, username);

    cfg.save() catch |e| {
        log.warn("api: could not persist profile update: {s}", .{@errorName(e)});
        return res.jsonError(500, "could not save profile");
    };
    log.info("api: profile updated (username={s}, password changed={})", .{ username, pwd_changed });
    // Go 成功时 `common.SuccessResp(c)` ⇒ `{"code":200,"message":"success","data":null}`
    try res.jsonOk("null");
}

/// `GET /api/auth/logout` —— 登出。
///
/// 对齐 Go `handles.LogOut`（`server/handles/auth.go:204-210`）：把当前令牌从
/// 「已验证令牌缓存」删掉，然后 `SuccessResp`。
///
/// 本构建**没有**那个缓存：`checkAuth` 只验 HMAC 签名 + `username` + `pwd_ts`
/// + `exp`（见其 A03 注释）。所以这里的登出 = 返回成功，**旧令牌在到期前仍有效**。
///
/// 为什么可以接受（而不是引入一张撤销表）：
///   * 单管理员 + `token_expires_in` 默认 48h，暴露窗口有界；
///   * 要即时失效已有一条更彻底的路径 —— **改密码**（推进 `admin_pwd_ts`，
///     所有旧令牌立即被拒），比"只撤销当前这一个"更强；
///   * 撤销表需要一张有界容器 + 过期清理，为一个 48h 窗口引入这套不成比例。
/// 前端登出后本就清掉本地 token，用户视角的登出是完整的。
fn handleLogout(app: *App, req: *http.Request, res: *http.Response) !void {
    _ = app;
    if (!std.mem.eql(u8, req.method, "GET")) return res.jsonError(405, "method not allowed");
    // M14（审计）：Go 的 `LogOut` 会真的让令牌失效 ——
    // `common.InvalidateToken(c.GetHeader("Authorization"))`
    // （server/handles/auth.go:204-211 → server/common/auth.go:67-73）：
    // 把出示的那个令牌从进程内的有效令牌缓存里删掉，之后它立刻失效。
    // 以前这里只回一个成功信封，令牌在 `exp` 之前照旧能用。
    //
    // 只作废**这一个**令牌（不是推进 `admin_pwd_ts` —— 那会把所有会话一起
    // 踢掉，比 Go 强得多，语义不对）。记录的是签名段：它是整串里唯一既
    // 定长又能唯一标识一枚令牌的部分。
    if (jwtSignatureOf(req)) |sig| {
        g_invalidated_tokens.add(sig);
    }
    // Go 传的是整个 Authorization 头；空 token 时它直接返回 nil（不报错）。
    try res.jsonOk("null");
}

/// 从 `Authorization` 里抠出 JWT 的第三段（签名）。拿不到就返回 null
/// （空 token / admin token / `?token=` 形式都走不到这里，与 Go 的
/// "空 token 直接返回 nil" 一致）。
fn jwtSignatureOf(req: *http.Request) ?[]const u8 {
    const h = req.header("Authorization") orelse return null;
    var token: []const u8 = h;
    const prefix = "Bearer ";
    if (h.len > prefix.len and std.ascii.eqlIgnoreCase(h[0..prefix.len], prefix)) {
        token = h[prefix.len..];
    }
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return null;
    _ = parts.next() orelse return null;
    const sig = parts.next() orelse return null;
    if (parts.next() != null) return null;
    if (sig.len == 0) return null;
    return sig;
}

/// M14：已作废令牌的**签名段**登记表。
///
/// 对齐 Go `validTokenCache`（server/common/auth.go）：进程内的、重启即清空的
/// 内存结构。容量有界（FIFO 淘汰），只存签名段（43 字节的 base64url），
/// 线性扫描 —— 单管理员场景下登出是极低频操作，256 条足够覆盖。
const InvalidatedTokens = struct {
    const cap = 256;
    const max_len = 128;

    mu: std.Io.Mutex = .init,
    buf: [cap][max_len]u8 = undefined,
    lens: [cap]usize = @splat(0),
    head: usize = 0,
    count: usize = 0,

    fn add(self: *InvalidatedTokens, sig: []const u8) void {
        if (sig.len == 0 or sig.len > max_len) return;
        self.mu.lockUncancelable(rt.io());
        defer self.mu.unlock(rt.io());
        @memcpy(self.buf[self.head][0..sig.len], sig);
        self.lens[self.head] = sig.len;
        self.head = (self.head + 1) % cap;
        if (self.count < cap) self.count += 1;
    }

    fn contains(self: *InvalidatedTokens, sig: []const u8) bool {
        if (sig.len == 0 or sig.len > max_len) return false;
        self.mu.lockUncancelable(rt.io());
        defer self.mu.unlock(rt.io());
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const n = self.lens[i];
            if (n == sig.len and std.mem.eql(u8, self.buf[i][0..n], sig)) return true;
        }
        return false;
    }
};

var g_invalidated_tokens: InvalidatedTokens = .{ .buf = undefined };

// ---------------------------------------------------------------------------
// Storage admin（/api/admin/storage/*）
// ---------------------------------------------------------------------------
//
// 与 Go 的对照（server/handles/storage.go + internal/op/storage.go）：
//   * 本工程没有数据库，`cfg.storages`（即 config.json 顶层的 `storages` 数组）
//     就是存储表；每次变更后立即 `cfg.save()` 落盘（tmp + rename 原子写）。
//   * create/update/enable 是**同步** init 驱动的（Go 也是，见
//     op.CreateStorage 直接调 initStorage）——慢驱动（189pc 登录 ~48s）会让
//     这一个管理请求等到底，线程/连接模型保证不挡其他请求。
//   * init 失败的记录保留在表里并带 error_msg（Go 把 err 文本写进 status），
//     管理面能看见「errored」行；挂载表里则没有它。
//   * delete/disable 只摘挂载，不 deinit 驱动 —— 旧快照还可能被在途请求持有
//     （见 republishWithEdit 的注释）。
//
// 已知偏差（见 docs/STATUS.md §20）：
//   * 错误信封的 HTTP 状态码 = code（本工程约定），Go 恒回 HTTP 200；
//     前端 axios 对两种形态都做了归一，行为一致。
//   * `modified` 由创建/更新处理器维护（= 该时刻的 Unix 秒，RFC3339 输出），
//     对齐 Go `internal/op/storage.go` 的 `storage.Modified = time.Now()`。

/// 存储记录 → Go `model.Storage` 形状的 JSON（不含外层信封）。`live` 表示
/// 该 id 当前有没有活的挂载（决定 status 的展示）。
///
/// 字段集对齐 Go 的 struct tag（storage.go:8-24）：未建模的 sort/proxy 族给
/// 零值，保证前端编辑表单 round-trip、导出/导入的形状完整。
fn writeStorageRecordJson(b: *Buf, s: *const model.Storage, live: bool) !void {
    try b.print("{{\"id\":{d},", .{s.id});
    try b.append("\"mount_path\":");
    try json.writeString(b, s.mount_path);
    try b.print(",\"order\":{d},", .{s.order});
    try b.append("\"driver\":");
    try json.writeString(b, s.driver);
    try b.print(",\"cache_expiration\":{d},", .{s.cache_expiration});
    try b.append("\"status\":");
    try json.writeString(b, storageDisplayStatus(s, live));
    try b.append(",\"addition\":");
    try json.writeString(b, s.addition);
    try b.append(",\"remark\":");
    try json.writeString(b, s.remark);
    // `modified`：Go 在创建/更新时置 `time.Now()`（internal/op/storage.go），
    // 前端存储列表/编辑表单会显示它 —— 回真值（RFC3339）。零值（从未更新过，
    // 如直接手写的配置文件）保持 Go 零值形态。`web_proxy` 回真值 —— 存储级
    // 「Web 代理」开关，`/d/` 的 ShouldProxy 判定要用（见 handleDownload）。
    var tbuf: [24]u8 = undefined;
    try b.print(",\"modified\":\"{s}\",\"order_by\":\"\",\"order_direction\":\"\",\"extract_folder\":\"\",\"web_proxy\":{},", .{ config.rfc3339(&tbuf, s.modified), s.web_proxy });
    // webdav_policy 的三个取值逐字透给前端表单（下拉框按值选中）；
    // proxy_range 上游是独立的存储开关，本工程未实现（恒 false，与它一致）。
    try b.append("\"webdav_policy\":");
    try json.writeString(b, s.webdav_policy);
    try b.append(",\"proxy_range\":false,\"down_proxy_url\":");
    try json.writeString(b, s.down_proxy_url);
    try b.print(",\"disable_proxy_sign\":{},\"disable_index\":false,\"enable_sign\":false,\"custom_cache_policies\":\"\"", .{s.disable_proxy_sign});
    try b.print(",\"disabled\":{},", .{s.disabled});
    // 运行时错误（init 失败的 @errorName），Go 没有这个字段但对排查有用；
    // syncStorages 刻意不落盘它。
    try b.append("\"error_msg\":");
    try json.writeString(b, s.error_msg);
    try b.appendByte('}');
}

/// 展示状态：disabled > errored > 活挂载 work > 落盘的 status。
/// 与 Go 的 status 语义对齐（conf.WORK="work" / DISABLED="disabled"；init 失败
/// 时 Go 把 err 文本写进 status，这里用「errored」+ 独立的 error_msg 字段）。
fn storageDisplayStatus(s: *const model.Storage, live: bool) []const u8 {
    if (s.disabled) return "disabled";
    if (s.error_msg.len > 0) return "errored";
    if (live) return "work";
    return s.status;
}

/// `?id=` 解析；缺失/非数字回 400（对齐 Go 的 strconv.Atoi 路径）。
fn queryId(req: *http.Request, res: *http.Response) !?i64 {
    const raw = req.queryGet("id") orelse {
        try res.jsonError(400, "id is required");
        return null;
    };
    return std.fmt.parseInt(i64, raw, 10) catch {
        try res.jsonError(400, "invalid id");
        return null;
    };
}

/// `{"code":N,"message":...,"data":<json>}`，HTTP 状态与 code 一致（本工程的
/// 信封约定，同 http.zig 的 jsonError）。给 create 的「行已建好但 init 失败」
/// 用 —— Go 在这里带 data.id 让前端跳编辑页（storage.go:100-107）。
fn jsonErrorWithData(res: *http.Response, code: u16, message: []const u8, data_json: []const u8) !void {
    // 与 `jsonError` 同规：**HTTP 恒 200**（Go `common.ErrorWithDataResp` →
    // `c.JSON(200, Resp{Code: code, Data: data})`，server/common/common.go:74-88）。
    // 前端据此跳编辑页（create init 失败时 data 里带新行的 id）。
    res.status = 200;
    try res.set("Content-Type", "application/json; charset=utf-8");
    try res.buf.print("{{\"code\":{d},\"message\":", .{code});
    try json.writeString(&res.buf, message);
    try res.buf.append(",\"data\":");
    try res.buf.append(data_json);
    try res.buf.appendByte('}');
}

/// 前端把 addition 作为**字符串**发上来（AddOrEdit.tsx `JSON.stringify(addition)`）；
/// 导入/脚本可能给对象，一并收下：对象序列化回字符串（Go 的存储字段就是字符串）。
/// 缺失时给 `"{}"`（create 用；update 对缺失另有「保留旧值」的处理）。
fn additionStringFrom(a: std.mem.Allocator, node: ?*const json.Value) !?[]const u8 {
    const n = node orelse return "{}";
    switch (n.*) {
        .string => |s| return if (s.len == 0) "{}" else s,
        .object => return try json.stringify(a, n),
        else => return null,
    }
}

fn boolAt(v: *const json.Value, key: []const u8) bool {
    const x = v.getPath(key) orelse return false;
    return x.asBool() orelse false;
}

/// 追加一条记录到 `cfg.storages`（在配置 arena 里重排 slice）。
/// **调用方必须已持有 `config.storages_mutex`**（本文件的管理面处理器）。
fn appendStorageRecord(ca: std.mem.Allocator, cfg: *config.Config, s: model.Storage) !void {
    const out = try ca.alloc(model.Storage, cfg.storages.len + 1);
    @memcpy(out[0..cfg.storages.len], cfg.storages);
    out[cfg.storages.len] = s;
    cfg.storages = out;
}

/// 按 id 移除一条记录；不存在时返回 null（不动 slice）。
/// **调用方必须已持有 `config.storages_mutex`**。
fn removeStorageRecord(ca: std.mem.Allocator, cfg: *config.Config, id: i64) !?model.Storage {
    var found = false;
    for (cfg.storages) |*s| {
        if (s.id == id) {
            found = true;
            break;
        }
    }
    if (!found) return null;
    const out = try ca.alloc(model.Storage, cfg.storages.len - 1);
    var n: usize = 0;
    var removed: model.Storage = undefined;
    for (cfg.storages) |s| {
        if (s.id == id) {
            removed = s;
            continue;
        }
        out[n] = s;
        n += 1;
    }
    cfg.storages = out;
    return removed;
}

/// `/api/admin/storage[/...]` 的分发。`suffix` 是 `""`（=list）或
/// `/list|/get|/create|/update|/delete|/enable|/disable|/load_all`。
fn handleAdminStorageRoute(app: *App, req: *http.Request, res: *http.Response, suffix: []const u8) !void {
    if (suffix.len == 0 or std.mem.eql(u8, suffix, "/list")) {
        if (!std.mem.eql(u8, req.method, "GET")) return res.jsonError(405, "method not allowed");
        return handleAdminStorage(app, req, res);
    }
    if (std.mem.eql(u8, suffix, "/get")) return handleAdminStorageGet(app, req, res);
    if (std.mem.eql(u8, suffix, "/create")) return handleAdminStorageCreate(app, req, res);
    if (std.mem.eql(u8, suffix, "/update")) return handleAdminStorageUpdate(app, req, res);
    if (std.mem.eql(u8, suffix, "/delete")) return handleAdminStorageDelete(app, req, res);
    if (std.mem.eql(u8, suffix, "/enable")) return handleAdminStorageEnable(app, req, res);
    if (std.mem.eql(u8, suffix, "/disable")) return handleAdminStorageDisable(app, req, res);
    if (std.mem.eql(u8, suffix, "/load_all")) return handleAdminStorageLoadAll(app, req, res);
    return res.jsonError(404, "storage endpoint not found");
}

/// `GET /api/admin/storage[/list]` —— 管理面的存储表。
///
/// 从 **配置表**（= Go 的 DB）渲染而不是从挂载表：init 失败 / 被禁用的记录
/// 也必须出现在管理面（Go 从 DB 拉全量，挂没挂上只影响 status）。
/// 旧实现只遍历挂载 ⇒ 坏掉的存储在管理面里**消失**，既删不掉也改不了。
fn handleAdminStorage(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const cfg = config.get();
    const mounts = app.mountsSnapshot();
    var b = Buf.init(a);
    // 在 storages_mutex 临界区里渲染：逐字段读表期间不能有并发写
    // （驱动 persist 回写 cookie / 另一个管理操作）。
    config.lockStorages();
    defer config.unlockStorages();
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":{\"content\":[");
    for (cfg.storages, 0..) |*s, i| {
        if (i != 0) try b.appendByte(',');
        try writeStorageRecordJson(&b, s, hasLiveMount(mounts, s.id));
    }
    try b.append("],\"total\":");
    try b.print("{d}", .{cfg.storages.len});
    try b.append("}}");
    try res.jsonOkRaw(b.slice());
}

/// `GET /api/admin/storage/get?id=N` —— 编辑表单取单条记录。
fn handleAdminStorageGet(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "GET")) return res.jsonError(405, "method not allowed");
    const id = (try queryId(req, res)) orelse return;
    const cfg = config.get();
    const mounts = app.mountsSnapshot();
    const a = req.arena;

    config.lockStorages();
    defer config.unlockStorages();
    const s = cfg.storageById(id) orelse return res.jsonError(404, "storage not found");

    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":");
    try writeStorageRecordJson(&b, s, hasLiveMount(mounts, id));
    try b.append("}");
    try res.jsonOkRaw(b.slice());
}

/// `POST /api/admin/storage/create`（body = Go model.Storage 的 JSON）。
///
/// 流程对齐 Go `op.CreateStorage`：校验 → 分配 id → 入表 → 落盘 →（未禁用时）
/// 构建 + init 驱动并发布挂载。init 失败时行已创建，回 500 + `data.id`
/// （前端据此跳编辑页）。
fn handleAdminStorageCreate(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "POST")) return res.jsonError(405, "method not allowed");
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const cfg = config.get();

    // ---- 无锁校验：能早失败就早失败，别占管理串行锁 ----
    const raw_path = v.strAt("mount_path") orelse "";
    if (raw_path.len == 0) return res.jsonError(400, "mount_path is required");
    const driver_name = v.strAt("driver") orelse "";
    if (driver_name.len == 0) return res.jsonError(400, "driver is required");
    const f = driver.find(driver_name) orelse
        return res.jsonError(500, try std.fmt.allocPrint(a, "no driver named: {s}", .{driver_name}));
    const addition = (try additionStringFrom(a, v.getPath("addition"))) orelse
        return res.jsonError(400, "addition must be a JSON string or object");
    _ = json.parse(a, addition) catch return res.jsonError(400, "addition is not valid JSON");
    const mount_path = try normalizeMountPath(a, raw_path);
    const disabled = boolAt(&v, "disabled");
    const web_proxy = boolAt(&v, "web_proxy");
    const webdav_policy = normalizeWebdavPolicy(v.strAt("webdav_policy") orelse "");
    const down_proxy_url = v.strAt("down_proxy_url") orelse "";
    const disable_proxy_sign = boolAt(&v, "disable_proxy_sign");

    // ---- 串行化管理面（挂载重建+发布）----
    const io = rt.io();
    app.storage_ops_lock.lockUncancelable(io);
    defer app.storage_ops_lock.unlock(io);

    var id: i64 = 0;
    {
        config.lockStorages();
        defer config.unlockStorages();
        // 重复挂载路径：Go 靠 DB 唯一索引报错，这里显式查。
        // 两边都归一后比较 —— 配置里可能存着没带前导斜杠的老写法。
        for (cfg.storages) |*s| {
            const existing = urlmod.cleanPath(a, s.mount_path) catch s.mount_path;
            if (std.mem.eql(u8, existing, mount_path)) {
                return res.jsonError(400, "mount path already exists");
            }
        }
        // id = max+1（自增语义）。
        for (cfg.storages) |*s| {
            if (s.id > id) id = s.id;
        }
        id += 1;

        // 深拷贝进配置 arena（A01：请求 arena 出函数即失效，putZig 同理）。
        const ca = cfg.allocator();
        const owned = model.Storage{
            .id = id,
            .mount_path = try ca.dupe(u8, mount_path),
            .order = v.intAt("order") orelse 0,
            .driver = f.key, // 静态串，配置可直接引用
            .cache_expiration = v.intAt("cache_expiration") orelse 0,
            .status = "work",
            .addition = try ca.dupe(u8, addition),
            .remark = try ca.dupe(u8, v.strAt("remark") orelse ""),
            .disabled = disabled,
            .web_proxy = web_proxy,
            .webdav_policy = webdav_policy,
            .down_proxy_url = try ca.dupe(u8, down_proxy_url),
            .disable_proxy_sign = disable_proxy_sign,
            // Go `op.CreateStorage`: `storage.Modified = time.Now()`。
            .modified = rt.nowSeconds(),
        };
        try appendStorageRecord(ca, cfg, owned);
    }

    cfg.save() catch |e| {
        log.warn("api: could not persist storage create: {s}", .{@errorName(e)});
        // 回滚：Go 是先写 DB（失败即返回），所以内存里不会留下幽灵条目。
        // 这里反过来先入内存表再落盘，若不回滚，进程内的列表会显示一条
        // 磁盘上并不存在的存储，直到重启才消失。
        //
        // ⚠️ 这里**不能**用 `try`：回滚失败若向上传播，下面的 unlock 会被跳过，
        //    管理面就永久死锁了。回滚失败只能记日志。
        config.lockStorages();
        _ = removeStorageRecord(cfg.allocator(), cfg, id) catch |re| {
            log.err("api: rollback of storage #{d} failed: {s} — " ++
                "the record stays in memory but not on disk until restart", .{ id, @errorName(re) });
        };
        config.unlockStorages();
        return res.jsonError(500, "could not save config");
    };

    const id_json = try std.fmt.allocPrint(a, "{{\"id\":{d}}}", .{id});
    if (disabled) {
        log.info("storage #{d} {s} created disabled (not mounted)", .{ id, f.key });
        return res.jsonOk(id_json);
    }

    // 拷快照构建：init 期间（可达数十秒）不能占 storages_mutex，否则驱动
    // 自己的 persist 回写（itvsh init 时就写 cookie）会被自己饿死。
    const snap = blk: {
        config.lockStorages();
        defer config.unlockStorages();
        const s = cfg.storageById(id) orelse return res.jsonError(500, "storage vanished");
        break :blk try dupeStorage(app.alloc, s);
    };
    switch (try buildMountFromStorage(app.alloc, &snap)) {
        .ok => |m| {
            try republishWithEdit(app, app.alloc, id, m);
            log.info("storage #{d} {s} created -> {s}", .{ id, f.key, m.mount_path });
            return res.jsonOk(id_json);
        },
        .init_failed => |msg| {
            cfg.setStorageError(id, msg);
            log.err("storage #{d} {s}: init failed: {s} — created but errored", .{ id, f.key, msg });
            return jsonErrorWithData(res, 500, try std.fmt.allocPrint(a, "failed init storage but storage is already created: {s}", .{msg}), id_json);
        },
        .no_driver => return res.jsonError(500, "driver disappeared from build"),
        .invalid_addition => return res.jsonError(400, "addition is not valid JSON"),
    }
}

/// `POST /api/admin/storage/update`（body = 完整 Storage，按 id 定位）。
///
/// 对齐 Go `op.UpdateStorage`：driver 不可改（400）；更新字段落盘后 drop 旧
/// 驱动、重建新驱动（这里= 摘旧挂载、建新挂载）。init 失败 ⇒ 摘挂载 + 500。
///
/// 与 Go 的一处友好偏差：body 缺 `addition` 时保留旧值（Go 绑定出零值 ""
/// 会让 init 失败）；显式传了才覆盖。
fn handleAdminStorageUpdate(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "POST")) return res.jsonError(405, "method not allowed");
    const a = req.arena;
    const v = try parseBodyJson(a, req, res) orelse return;
    const cfg = config.get();
    const id = v.intAt("id") orelse return res.jsonError(400, "id is required");

    const io = rt.io();
    app.storage_ops_lock.lockUncancelable(io);
    defer app.storage_ops_lock.unlock(io);

    var snap: model.Storage = undefined;
    {
        config.lockStorages();
        defer config.unlockStorages();
        const elem = cfg.storageById(id) orelse return res.jsonError(404, "storage not found");
        const new_driver = v.strAt("driver") orelse elem.driver;
        if (!std.mem.eql(u8, new_driver, elem.driver)) return res.jsonError(400, "driver cannot be changed");
        const f = driver.find(elem.driver) orelse
            return res.jsonError(500, try std.fmt.allocPrint(a, "no driver named: {s}", .{elem.driver}));
        const raw_path = v.strAt("mount_path") orelse "";
        if (raw_path.len == 0) return res.jsonError(400, "mount_path is required");
        const mount_path = try normalizeMountPath(a, raw_path);
        for (cfg.storages) |*s| {
            if (s.id == id) continue;
            const existing = urlmod.cleanPath(a, s.mount_path) catch s.mount_path;
            if (std.mem.eql(u8, existing, mount_path)) return res.jsonError(400, "mount path already exists");
        }

        // 字段替换 —— 一律 dupe 进配置 arena（A01）。
        const ca = cfg.allocator();
        elem.mount_path = try ca.dupe(u8, mount_path);
        elem.driver = f.key;
        elem.order = v.intAt("order") orelse elem.order;
        elem.cache_expiration = v.intAt("cache_expiration") orelse elem.cache_expiration;
        if (v.getPath("addition")) |add_node| {
            const add_str = (try additionStringFrom(a, add_node)) orelse
                return res.jsonError(400, "addition must be a JSON string or object");
            _ = json.parse(a, add_str) catch return res.jsonError(400, "addition is not valid JSON");
            elem.addition = try ca.dupe(u8, add_str);
        }
        elem.remark = try ca.dupe(u8, v.strAt("remark") orelse "");
        elem.disabled = boolAt(&v, "disabled");
        elem.web_proxy = boolAt(&v, "web_proxy");
        // ⚠ 三个字段都是"传了才改"：`storage/update` 的表单只回传它渲染出来
        // 的字段，缺字段一律保留原值（与 Go 的 `mapstructure` 部分更新一致）。
        if (v.strAt("webdav_policy")) |p| {
            elem.webdav_policy = normalizeWebdavPolicy(p);
        }
        if (v.strAt("down_proxy_url")) |u| elem.down_proxy_url = try ca.dupe(u8, u);
        if (v.getPath("disable_proxy_sign")) |_| {
            elem.disable_proxy_sign = boolAt(&v, "disable_proxy_sign");
        }
        // Go `op.UpdateStorage`: `storage.Modified = time.Now()`（每次更新都刷新）。
        elem.modified = rt.nowSeconds();
        // 重试 init 前清掉上一轮的运行时错误；status 重置（Go 语义：改配置即重新初始化）。
        elem.status = "work";
        elem.error_msg = "";
        snap = try dupeStorage(app.alloc, elem);
    }

    cfg.save() catch |e| {
        log.warn("api: could not persist storage update: {s}", .{@errorName(e)});
        return res.jsonError(500, "could not save config");
    };

    if (snap.disabled) {
        try republishWithEdit(app, app.alloc, id, null);
        log.info("storage #{d} updated (disabled, unmounted)", .{id});
        return res.jsonOk("null");
    }

    switch (try buildMountFromStorage(app.alloc, &snap)) {
        .ok => |m| {
            try republishWithEdit(app, app.alloc, id, m);
            log.info("storage #{d} {s} updated -> {s}", .{ id, snap.driver, m.mount_path });
            return res.jsonOk("null");
        },
        .init_failed => |msg| {
            cfg.setStorageError(id, msg);
            // 旧驱动已按「不 deinit」策略留给了在途请求；新 init 失败 ⇒ 摘挂载。
            try republishWithEdit(app, app.alloc, id, null);
            log.err("storage #{d} {s}: init failed after update: {s}", .{ id, snap.driver, msg });
            return res.jsonError(500, try std.fmt.allocPrint(a, "failed init storage: {s}", .{msg}));
        },
        .no_driver => return res.jsonError(500, "driver disappeared from build"),
        .invalid_addition => return res.jsonError(400, "addition is not valid JSON"),
    }
}

/// `POST /api/admin/storage/delete?id=N` —— 摘挂载 + 出表 + 落盘。
/// 旧驱动不 deinit（在途请求可能还持有旧快照，见 republishWithEdit 注释）。
fn handleAdminStorageDelete(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "POST")) return res.jsonError(405, "method not allowed");
    const id = (try queryId(req, res)) orelse return;
    const cfg = config.get();

    const io = rt.io();
    app.storage_ops_lock.lockUncancelable(io);
    defer app.storage_ops_lock.unlock(io);

    {
        config.lockStorages();
        defer config.unlockStorages();
        _ = (try removeStorageRecord(cfg.allocator(), cfg, id)) orelse
            return res.jsonError(404, "storage not found");
    }

    cfg.save() catch |e| {
        log.warn("api: could not persist storage delete: {s}", .{@errorName(e)});
        return res.jsonError(500, "could not save config");
    };
    try republishWithEdit(app, app.alloc, id, null);
    log.info("storage #{d} deleted", .{id});
    try res.jsonOk("null");
}

/// `POST /api/admin/storage/enable?id=N` —— 解禁 + 重建驱动 + 挂上。
/// 已启用时回 400（Go 文案原样照抄：`this storage have enabled`）。
fn handleAdminStorageEnable(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "POST")) return res.jsonError(405, "method not allowed");
    const id = (try queryId(req, res)) orelse return;
    const cfg = config.get();

    const io = rt.io();
    app.storage_ops_lock.lockUncancelable(io);
    defer app.storage_ops_lock.unlock(io);

    var snap: model.Storage = undefined;
    {
        config.lockStorages();
        defer config.unlockStorages();
        const elem = cfg.storageById(id) orelse return res.jsonError(404, "storage not found");
        if (!elem.disabled) return res.jsonError(400, "this storage have enabled");
        elem.disabled = false;
        elem.status = "work";
        elem.error_msg = "";
        snap = try dupeStorage(app.alloc, elem);
    }

    cfg.save() catch |e| {
        log.warn("api: could not persist storage enable: {s}", .{@errorName(e)});
        return res.jsonError(500, "could not save config");
    };

    switch (try buildMountFromStorage(app.alloc, &snap)) {
        .ok => |m| {
            try republishWithEdit(app, app.alloc, id, m);
            log.info("storage #{d} {s} enabled -> {s}", .{ id, snap.driver, m.mount_path });
            return res.jsonOk("null");
        },
        .init_failed => |msg| {
            cfg.setStorageError(id, msg);
            try republishWithEdit(app, app.alloc, id, null);
            log.err("storage #{d} {s}: init failed on enable: {s}", .{ id, snap.driver, msg });
            return res.jsonError(500, try std.fmt.allocPrint(req.arena, "failed init storage: {s}", .{msg}));
        },
        .no_driver => return res.jsonError(500, "driver disappeared from build"),
        .invalid_addition => return res.jsonError(400, "addition is not valid JSON"),
    }
}

/// `POST /api/admin/storage/disable?id=N` —— 置 disabled + 摘挂载。
fn handleAdminStorageDisable(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "POST")) return res.jsonError(405, "method not allowed");
    const id = (try queryId(req, res)) orelse return;
    const cfg = config.get();

    const io = rt.io();
    app.storage_ops_lock.lockUncancelable(io);
    defer app.storage_ops_lock.unlock(io);

    {
        config.lockStorages();
        defer config.unlockStorages();
        const elem = cfg.storageById(id) orelse return res.jsonError(404, "storage not found");
        if (elem.disabled) return res.jsonError(400, "this storage have disabled");
        elem.disabled = true;
        // Go：`storage.SetStatus(DISABLED)`（conf 常量即 "disabled"）后落库。
        elem.status = "disabled";
    }

    cfg.save() catch |e| {
        log.warn("api: could not persist storage disable: {s}", .{@errorName(e)});
        return res.jsonError(500, "could not save config");
    };
    try republishWithEdit(app, app.alloc, id, null);
    log.info("storage #{d} disabled (unmounted)", .{id});
    try res.jsonOk("null");
}

/// `load_all` 的忙标记：同一时刻只跑一轮重建。
var g_reload_busy = std.atomic.Value(bool).init(false);

/// `POST /api/admin/storage/load_all` —— 后台线程全量重建挂载。
///
/// 对齐 Go `handles.LoadAllStorages`（storage.go:180-209）：响应立即回成功，
/// 重建在后台跑。已经在跑时幂等跳过（Go 点两次只是排两个 goroutine，这里
/// 选择不叠加，避免两轮重建互相覆盖发布）。
fn handleAdminStorageLoadAll(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "POST")) return res.jsonError(405, "method not allowed");
    const cfg = config.get();
    if (g_reload_busy.cmpxchgWeak(false, true, .acq_rel, .acquire) != null) {
        return res.jsonOk("null");
    }
    const t = std.Thread.spawn(.{}, loadAllWorker, .{ app, cfg }) catch |e| {
        g_reload_busy.store(false, .release);
        return res.jsonError(500, @errorName(e));
    };
    t.detach();
    try res.jsonOk("null");
}

/// `load_all` 的后台 worker。`app`/`cfg` 都是进程级存活对象，detach 安全。
fn loadAllWorker(app: *App, cfg: *config.Config) void {
    defer g_reload_busy.store(false, .release);
    const io = rt.io();
    app.storage_ops_lock.lockUncancelable(io);
    defer app.storage_ops_lock.unlock(io);
    buildMountsFromConfig(app.alloc, app, cfg) catch |e| {
        log.err("storage: load_all rebuild failed: {s}", .{@errorName(e)});
        return;
    };
    log.info("storage: load_all finished, {d} mount(s) published", .{app.mountsSnapshot().len});
}

// ---------------------------------------------------------------------------
// Driver metadata（/api/admin/driver/*）
// ---------------------------------------------------------------------------

/// 一个驱动的表单元数据，对齐 Go `driver.Info`（internal/driver/item.go:16-20）：
///   { "common": [...Item], "additional": [...Item], "config": {...} }
/// 前端「添加存储」读 `/admin/driver/list` 的 map、「编辑存储」读
/// `/admin/driver/info?driver=`，两边都按这个形状渲染表单。
///
/// `common` 是本构建支持的字段子集（mount_path / order / remark）——
/// cache_expiration / web_proxy / webdav_policy 这些 Go 有而本工程没实现的
/// 字段**刻意不出现**：渲染出来会变成「可编辑但不生效」的陷阱。
/// `additional` 从 Factory.addition_schema（对象形态）展开成数组。
fn writeDriverInfo(b: *Buf, a: std.mem.Allocator, f: *const driver.Factory) !void {
    try b.append("{\"common\":[");
    try b.append("{\"name\":\"mount_path\",\"type\":\"string\",\"default\":\"\",\"options\":\"\",\"required\":true,\"help\":\"The path you want to mount to, it is unique and cannot be repeated\"}");
    try b.append(",{\"name\":\"order\",\"type\":\"number\",\"default\":\"\",\"options\":\"\",\"required\":false,\"help\":\"use to sort\"}");
    try b.append(",{\"name\":\"remark\",\"type\":\"text\",\"default\":\"\",\"options\":\"\",\"required\":false,\"help\":\"\"}");
    try b.append("],\"additional\":");
    const schema = json.parse(a, f.addition_schema) catch json.Value{ .object = .{} };
    try writeAdditionalItems(b, &schema);
    // config 对齐 Go `driver.Config` 的 JSON 字段；本工程没有按驱动差异化的
    // 能力位（前端只读 need_ms / alert），未建模项一律 false / 空串。
    try b.append(",\"config\":{\"name\":");
    try json.writeString(b, f.key);
    try b.append(",\"local_sort\":false,\"only_local\":false,\"only_proxy\":false,\"no_cache\":true,\"no_upload\":false,\"need_ms\":false,\"default_root\":\"\",\"only_indices\":false,\"prefer_proxy\":false,\"alert\":\"\"}}");
}

/// addition_schema（`{字段名: {type,default,required,help,options}}`）→ Go
/// `driver.Item` 数组形态。
///
/// ⚠️ `default` 必须输出成**字符串**：Go 的 Item.Default 是 string，前端
/// `GetDefaultValue(Type.Bool, value)` 靠 `value === "true"` 判断 —— 给原生
/// bool `true` 会被判成 false，布尔默认值全部静默失效。schema 里 bool/数字
/// 形态的 default 在这里统一转成字符串。
fn writeAdditionalItems(b: *Buf, schema: *const json.Value) !void {
    const o = schema.asObject() orelse {
        try b.append("[]");
        return;
    };
    try b.appendByte('[');
    for (o.keys, 0..) |k, i| {
        if (i != 0) try b.appendByte(',');
        try b.append("{\"name\":");
        try json.writeString(b, k);
        const item = o.vals[i].asObject() orelse {
            try b.append(",\"type\":\"string\",\"default\":\"\",\"options\":\"\",\"required\":false,\"help\":\"\"}");
            continue;
        };
        const t = if (item.get("type")) |x| (x.asStr() orelse "string") else "string";
        try b.append(",\"type\":");
        try json.writeString(b, t);
        try b.append(",\"default\":");
        try writeItemDefaultAsString(b, item.get("default"));
        try b.append(",\"options\":");
        if (item.get("options")) |x| {
            if (x.asStr()) |s| {
                try json.writeString(b, s);
            } else try b.append("\"\"");
        } else try b.append("\"\"");
        const required = if (item.get("required")) |x| (x.asBool() orelse false) else false;
        try b.print(",\"required\":{},\"help\":", .{required});
        if (item.get("help")) |x| {
            if (x.asStr()) |s| {
                try json.writeString(b, s);
            } else try b.append("\"\"");
        } else try b.append("\"\"");
        try b.appendByte('}');
    }
    try b.appendByte(']');
}

fn writeItemDefaultAsString(b: *Buf, v: ?*const json.Value) !void {
    const x = v orelse return b.append("\"\"");
    switch (x.*) {
        .string => |s| try json.writeString(b, s),
        .bool => |val| try b.append(if (val) "\"true\"" else "\"false\""),
        .int => |n| try b.print("\"{d}\"", .{n}),
        .float => |n| try b.print("\"{d}\"", .{n}),
        else => try b.append("\"\""),
    }
}

/// `GET /api/admin/driver/list` —— `{驱动名: Info}` 的 map。
/// **形状已修正**（2026-10-15）：此前返回的是裸 addition_schema 对象，前端
/// AddOrEdit 取 `drivers()[name].common` 会得到 undefined，「添加存储」表单
/// 根本渲染不出来。现在逐字段对齐 Go 的 `op.GetDriverInfoMap()`。
fn handleDriverList(req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":{");
    for (driver.builtin, 0..) |_, i| {
        if (i != 0) try b.appendByte(',');
        const f = &driver.builtin[i];
        try json.writeString(&b, f.key);
        try b.appendByte(':');
        try writeDriverInfo(&b, a, f);
    }
    try b.append("}}");
    try res.jsonOkRaw(b.slice());
}

/// `GET /api/admin/driver/info?driver=X` —— 单驱动的表单元数据（编辑存储用）。
/// 未知驱动回 404，文案对齐 Go `handles.GetDriverInfo`（driver.go:19-28）。
fn handleDriverInfo(req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "GET")) return res.jsonError(405, "method not allowed");
    // ⚠ 必须用**解码后**的值：Go `c.Query("driver")`（driver.go:20）会做
    // 一次百分号解码，而 `115 Cloud`（带空格）与 `上海电信智家硬盘`（非 ASCII）
    // 经前端 axios 编码后是 `115%20Cloud` / `%E4%B8%8A...` —— 不解码就永远
    // 404 "not found"，管理页的「添加存储」对这两个驱动直接废掉。
    const name = (try req.queryGetDecoded("driver")) orelse
        return res.jsonError(400, "driver is required");
    const f = driver.find(name) orelse
        return res.jsonError(404, try std.fmt.allocPrint(req.arena, "driver [{s}] not found", .{name}));
    const a = req.arena;
    var b = Buf.init(a);
    try b.append("{\"code\":200,\"message\":\"success\",\"data\":");
    try writeDriverInfo(&b, a, f);
    try b.append("}");
    try res.jsonOkRaw(b.slice());
}

/// `GET /api/admin/driver/names` — keys for the storage driver's selector.
fn handleDriverNames(req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    var b = Buf.init(a);
    try b.appendByte('[');
    for (driver.builtin, 0..) |f, i| {
        if (i != 0) try b.appendByte(',');
        try json.writeString(&b, f.key);
    }
    try b.appendByte(']');
    try res.jsonOk(b.slice());
}

/// 一条可配置项的元数据。`setting_defs` 是这份表，前端设置页按它渲染表单。
const SettingDef = struct {
    key: []const u8,
    default: []const u8,
    kind: []const u8,
    group: i64,
    flag: i64 = 0,
};

const setting_defs = [_]SettingDef{
    .{ .key = "site_title", .default = "OpenList", .kind = "string", .group = 1 },
    .{ .key = "logo", .default = "https://res.oplist.org/logo/logo.svg", .kind = "text", .group = 2 },
    .{ .key = "favicon", .default = "https://res.oplist.org/logo/logo.svg", .kind = "string", .group = 2 },
    .{ .key = "main_color", .default = "#1890ff", .kind = "string", .group = 2 },
    .{ .key = "customize_head", .default = "", .kind = "text", .group = 4, .flag = 1 },
    .{ .key = "customize_body", .default = "", .kind = "text", .group = 4, .flag = 1 },
    // 下载签名。Go 侧这两项存在数据库 settings 表（key `sign_all` /
    // `link_expiration`），默认值逐字对齐 `internal/bootstrap/data/setting.go:171`
    // （`sign_all` 默认 "true"）；本工程没有库，落到 `zig.*` 块并立即生效。
    .{ .key = "sign_all", .default = "true", .kind = "bool", .group = 4 },
    .{ .key = "link_expiration", .default = "0", .kind = "number", .group = 4 },
    // Go `proxy_types`（internal/bootstrap/data/setting.go:133）：这些扩展名
    // 的下载强制走服务端代理。默认 `m3u8,url`；Group PREVIEW / Flag PRIVATE。
    .{ .key = "proxy_types", .default = "m3u8,url", .kind = "text", .group = 3, .flag = 1 },
    // Go `text_types`（internal/bootstrap/data/setting.go:128）：文本文件列表，
    // 是 `/p/` 端点 canProxy 准入的一部分（`/d/` 不受它影响）。
    .{ .key = "text_types", .default = "txt,htm,html,xml,java,properties,sql,js,md,json,conf,ini,vue,php,py,bat,gitignore,yml,go,sh,c,cpp,h,hpp,tsx,vtt,srt,ass,rs,lrc,strm", .kind = "text", .group = 3, .flag = 1 },
};

/// `POST /api/admin/setting/reset_token` —— Go `handles.ResetToken`
///（`server/handles/setting.go:19-28`）：生成新 token → 存设置 →
/// `sign.Instance()` → 把新 token 作为 `data` 返回。
///
/// 本工程 token = `zig.token`（CLI 认证与下载签名共用，见 `App.sign_secret`）。
/// Go 的 `sign.Instance()` 以 token 作 HMAC 密钥 ⇒ 换 token 会**作废所有已发
/// 下载链接**；这里同步 `app.sign_secret` 并落盘，语义与 Go 一致。
/// 修复前该路由落在前缀白名单里但没有分支，回的是 JSON 404（前端静默失败）。
fn handleSettingResetToken(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "POST")) return res.jsonError(405, "method not allowed");
    const a = req.arena;
    const cfg = config.get();

    var buf: [128]u8 = undefined;
    const gen = rand.randomToken(&buf);
    cfg.putZig("token", .{ .string = try cfg.allocator().dupe(u8, gen) }) catch |e| {
        log.warn("api: reset_token could not store zig.token: {s}", .{@errorName(e)});
        return res.jsonError(500, "failed to save token");
    };
    cfg.save() catch |e| {
        log.warn("api: reset_token could not persist config: {s}", .{@errorName(e)});
        return res.jsonError(500, "failed to save token");
    };
    // 同步内存副本：此后签发的链接用新密钥，旧链接立即失效（等价 Go 的
    // `sign.Instance()`）。必须先落盘再改内存 —— 落盘失败时内存不能先变。
    app.sign_secret = try app.alloc.dupe(u8, gen);

    // token 字符集是 [A-Za-z0-9-]（`util/random.zig`），直接拼引号即可；
    // 用 allocPrint 而非手写 Buf 是为了跟 Go `SuccessResp(c, token)` 一样
    // 把 token 作为字符串放进 data。
    try res.jsonOk(try std.fmt.allocPrint(a, "\"{s}\"", .{gen}));
}

fn handleSettingRoute(app: *App, req: *http.Request, res: *http.Response, action: []const u8) !void {
    if (std.mem.eql(u8, action, "list") and std.mem.eql(u8, req.method, "GET")) {
        return renderSettingItems(req, res, false, null);
    }
    if (std.mem.eql(u8, action, "default") and (std.mem.eql(u8, req.method, "POST") or std.mem.eql(u8, req.method, "GET"))) {
        return renderSettingItems(req, res, true, null);
    }
    if (std.mem.eql(u8, action, "get") and std.mem.eql(u8, req.method, "GET")) {
        const key = try req.queryGetDecoded("key");
        const keys = try req.queryGetDecoded("keys");
        if (key) |one| return renderSettingItems(req, res, false, one);
        if (keys) |many| return renderSettingItems(req, res, false, many);
        return res.jsonError(400, "key or keys is required");
    }
    if (std.mem.eql(u8, action, "save") and std.mem.eql(u8, req.method, "POST")) {
        return handleSettingSave(app, req, res);
    }
    // Go `router.go:161`：`setting.POST("/reset_token", handles.ResetToken)`。
    if (std.mem.eql(u8, action, "reset_token") and std.mem.eql(u8, req.method, "POST")) {
        return handleSettingResetToken(app, req, res);
    }
    // 前端设置页的每项设置都有删除按钮（Common.tsx onDelete →
    // `/admin/setting/delete?key=`）。Go 删的是 settings 表行 ⇒ 取值回落到
    // 编译期默认；本工程无库，等价实现 = 把键重置为表内默认值并落盘。
    if (std.mem.eql(u8, action, "delete") and std.mem.eql(u8, req.method, "POST")) {
        const key = (try req.queryGetDecoded("key")) orelse return res.jsonError(400, "key is required");
        return handleSettingDelete(app, req, res, key);
    }
    return res.jsonError(404, "setting endpoint not found");
}

fn renderSettingItems(req: *http.Request, res: *http.Response, defaults: bool, only_keys: ?[]const u8) !void {
    const a = req.arena;
    const cfg = config.get();

    // 对齐 Go：`GetSettingItemInKeys` 逐个调 `GetSettingItemByKey`，**任何一个**
    // key 查不到就 err ⇒ handler 回 400。所以 `keys=a,b` 里 b 不存在同样是 400，
    // 不是"只返回存在的那些"。校验放在渲染前，且不看 group 过滤 —— Go 的
    // GetSettingItemByKey 是按键查全表，与 group 无关。
    if (only_keys) |raw_keys| {
        var it = std.mem.tokenizeScalar(u8, raw_keys, ',');
        while (it.next()) |k| {
            if (k.len == 0) continue;
            var found = false;
            for (setting_defs) |def| {
                if (std.mem.eql(u8, def.key, k)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return res.jsonError(400, try std.fmt.allocPrint(
                    a, "setting not found: {s}", .{k}));
            }
        }
    }

    var b = Buf.init(a);
    try b.append("[");
    var wrote: usize = 0;
    for (setting_defs, 0..) |def, index| {
        if (!settingGroupIncluded(req, def.group)) continue;
        if (only_keys) |raw_keys| if (!keyListContains(raw_keys, def.key)) continue;
        if (wrote != 0) try b.appendByte(',');
        const value = if (defaults) def.default else settingValue(cfg, def.key);
        try b.append("{\"key\":");
        try json.writeString(&b, def.key);
        try b.append(",\"value\":");
        try json.writeString(&b, value);
        try b.append(",\"help\":\"\",\"type\":");
        try json.writeString(&b, def.kind);
        try b.append(",\"options\":\"\"");
        try b.print(",\"group\":{d},\"flag\":{d},\"index\":{d}}}", .{ def.group, def.flag, index });
        wrote += 1;
    }
    try b.append("]");
    try res.jsonOk(b.slice());
}

fn settingValue(cfg: *const config.Config, key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "site_title")) return cfg.site_title;
    if (std.mem.eql(u8, key, "logo")) return cfg.logo;
    if (std.mem.eql(u8, key, "favicon")) return cfg.favicon;
    if (std.mem.eql(u8, key, "main_color")) return cfg.main_color;
    if (std.mem.eql(u8, key, "customize_head")) return cfg.customize_head;
    if (std.mem.eql(u8, key, "customize_body")) return cfg.customize_body;
    // 逗号分隔列表类：字符串字段直接回传（曾漏了 proxy_types —— 设置页
    // 会显示空值，2026-10-17 对账时发现并一并补上）。
    if (std.mem.eql(u8, key, "proxy_types")) return cfg.proxy_types;
    if (std.mem.eql(u8, key, "text_types")) return cfg.text_types;
    // 非字符串字段：转成 setting 的字符串形态回给前端（前端表单按 kind 解析）。
    if (std.mem.eql(u8, key, "sign_all")) return if (cfg.sign_all) "true" else "false";
    if (std.mem.eql(u8, key, "link_expiration")) {
        // 调用方给的是一个 arena 里活的 Buf，这里用固定缓冲转十进制。
        var buf: [24]u8 = undefined;
        return std.fmt.bufPrint(&buf, "{d}", .{cfg.link_expiration}) catch "0";
    }
    return "";
}

fn settingGroupIncluded(req: *const http.Request, group: i64) bool {
    const list = req.queryGet("groups") orelse req.queryGet("group") orelse return true;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |item| {
        if (std.fmt.parseInt(i64, item, 10) catch continue == group) return true;
    }
    return false;
}

fn keyListContains(list: []const u8, key: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |item| if (std.mem.eql(u8, item, key)) return true;
    return false;
}

fn handleSettingSave(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const payload = try parseBodyJson(a, req, res) orelse return;
    const items = payload.asArray() orelse return res.jsonError(400, "expected an array of setting items");
    const cfg = config.get();
    const ca = cfg.allocator();
    for (items) |item| {
        const key = item.strAt("key") orelse continue;
        const value_node = item.getPath("value") orelse continue;
        const value = switch (value_node.*) {
            .string => |s| s,
            .bool => |v| if (v) "true" else "false",
            .int => |v| try std.fmt.allocPrint(a, "{d}", .{v}),
            else => continue,
        };
        if (!isConfigBackedSetting(key)) continue;
        const owned = try ca.dupe(u8, value);
        try applySettingItem(cfg, key, owned);
    }
    cfg.save() catch |e| {
        log.warn("api: could not persist settings: {s}", .{@errorName(e)});
        return res.jsonError(500, "could not save settings");
    };
    mirrorFrontendSettings(app, cfg) catch |e| {
        log.warn("api: could not mirror frontend settings: {s}", .{@errorName(e)});
    };
    try res.jsonOk("null");
}

/// 把一个 config-backed 设置写入运行时结构 + `zig` 块。
/// `owned` 必须已归配置 arena 所有（调用方负责 dupe）。
/// `setting/save` 与 `setting/delete`（重置默认）共用。
fn applySettingItem(cfg: *config.Config, key: []const u8, owned: []const u8) !void {
    try cfg.putZig(key, .{ .string = owned });
    if (std.mem.eql(u8, key, "site_title")) cfg.site_title = owned;
    if (std.mem.eql(u8, key, "logo")) cfg.logo = owned;
    if (std.mem.eql(u8, key, "favicon")) cfg.favicon = owned;
    if (std.mem.eql(u8, key, "main_color")) cfg.main_color = owned;
    if (std.mem.eql(u8, key, "customize_head")) cfg.customize_head = owned;
    if (std.mem.eql(u8, key, "customize_body")) cfg.customize_body = owned;
    // 下载签名两项：存的是字符串形态，写回结构体时要转类型。
    if (std.mem.eql(u8, key, "sign_all")) cfg.sign_all = std.mem.eql(u8, owned, "true");
    if (std.mem.eql(u8, key, "proxy_types")) cfg.proxy_types = owned;
    if (std.mem.eql(u8, key, "text_types")) cfg.text_types = owned;
    if (std.mem.eql(u8, key, "link_expiration")) {
        cfg.link_expiration = std.fmt.parseInt(i64, owned, 10) catch 0;
    }
}

/// 把配置里的展示类设置镜像进实时 public-settings 用的结构（SPA shell 与
/// manifest 是启动时一次性构建的，页面层面的变更重启后才可见）。
fn mirrorFrontendSettings(app: *App, cfg: *const config.Config) !void {
    app.frontend.settings.site_title = try app.alloc.dupe(u8, cfg.site_title);
    app.frontend.settings.logo = try app.alloc.dupe(u8, cfg.logo);
    app.frontend.settings.favicon = try app.alloc.dupe(u8, cfg.favicon);
    app.frontend.settings.main_color = try app.alloc.dupe(u8, cfg.main_color);
    app.frontend.settings.customize_head = try app.alloc.dupe(u8, cfg.customize_head);
    app.frontend.settings.customize_body = try app.alloc.dupe(u8, cfg.customize_body);
}

/// `POST /api/admin/setting/delete?key=X` —— Go 删 settings 表行，取值回落到
/// 编译期默认；这里把键重置为 `setting_defs` 里的默认值并落盘。
/// 非本工程建模的键回 404（不存在「删了但还显示」的歧义）。
fn handleSettingDelete(app: *App, req: *http.Request, res: *http.Response, key: []const u8) !void {
    _ = req;
    var def: ?*const SettingDef = null;
    for (&setting_defs) |*d| {
        if (std.mem.eql(u8, d.key, key)) def = d;
    }
    const d = def orelse return res.jsonError(404, "setting not found");
    const cfg = config.get();
    const owned = try cfg.allocator().dupe(u8, d.default);
    try applySettingItem(cfg, key, owned);
    cfg.save() catch |e| {
        log.warn("api: could not persist setting delete: {s}", .{@errorName(e)});
        return res.jsonError(500, "could not save settings");
    };
    mirrorFrontendSettings(app, cfg) catch |e| {
        log.warn("api: could not mirror frontend settings: {s}", .{@errorName(e)});
    };
    try res.jsonOk("null");
}

fn isConfigBackedSetting(key: []const u8) bool {
    for (setting_defs) |def| if (std.mem.eql(u8, key, def.key)) return true;
    return false;
}


// ======================== 配置导入 / 导出（STATUS §36D）========================
//
// `GET /api/admin/config/export[?format=backup|cfg]`
//   * backup（默认）：**OpenList 备份页同格式**
//     `{"encrypted":false,"settings":[...],"users":[...],"storages":[...],"metas":[],"shares":[]}`
//     —— 官方 Web UI（/@manage/backup-restore，纯前端实现）的恢复页可以直接
//     导入；反过来，官方实例导出的备份文件本端也能导入（见 import）。
//   * cfg：当前 cfg.json 原文（自身格式，含 zig 块与凭据），用于整机迁移。
//
// `POST /api/admin/config/import[?mode=merge|overwrite]`
//   * 自动识别两种格式：顶层 `settings` 是数组 ⇒ OpenList 备份格式；
//     否则按 cfg.json 格式读（storages 数组 + 顶层/zig 设置键）。
//   * merge（默认）：设置按 key 覆盖；存储按 mount_path 合并（同路径 =
//     更新，不同 = 新建并 init 挂载）。
//   * overwrite：先摘除并清空全部现有存储，再全量导入。
//   * users/metas/shares：本构建未建模，忽略并在响应里报告。

fn writeBackupSettingsJson(b: *Buf, cfg: *const config.Config) !void {
    for (setting_defs, 0..) |def, i| {
        if (i != 0) try b.appendByte(',');
        try b.append("{\"key\":");
        try json.writeString(b, def.key);
        try b.append(",\"value\":");
        var numbuf: [24]u8 = undefined;
        const val = if (std.mem.eql(u8, def.key, "link_expiration"))
            (std.fmt.bufPrint(&numbuf, "{d}", .{cfg.link_expiration}) catch "0")
        else
            settingValue(cfg, def.key);
        try json.writeString(b, val);
        try b.append(",\"help\":\"\",\"type\":");
        try json.writeString(b, def.kind);
        try b.append(",\"options\":\"\"}");
    }
}

fn handleConfigExport(app: *App, req: *http.Request, res: *http.Response) !void {
    _ = app;
    if (!std.mem.eql(u8, req.method, "GET")) return res.jsonError(405, "method not allowed");
    const a = req.arena;
    const cfg = config.get();
    const format = (try req.queryGetDecoded("format")) orelse "backup";

    if (std.mem.eql(u8, format, "cfg")) {
        // 自身格式：cfg.json 原文。
        const text = try json.stringify(a, &cfg.root);
        try res.set("Content-Disposition", "attachment; filename=\"openlist_cfg.json\"");
        try res.jsonOkRaw(text);
        return;
    }

    var b = Buf.init(a);
    try b.append("{\"encrypted\":false,\"settings\":[");
    try writeBackupSettingsJson(&b, cfg);
    try b.append("],\"users\":[");
    // 单管理员（本构建的用户模型）。password 不导出 —— 我们的哈希格式与
    // Go 的 bcrypt 不通用，导入端本来也不会吃它。
    const admin_user = if (cfg.raw("zig.admin_user")) |u| (u.asStr() orelse "admin") else "admin";
    try b.append("{\"id\":1,\"username\":");
    try json.writeString(&b, admin_user);
    try b.append(",\"password\":\"\",\"base_path\":\"/\",\"role\":2,\"disabled\":false,\"permission\":0,\"sso_id\":\"\",\"allow_ldap\":false}");
    try b.append("],\"storages\":[");
    {
        config.lockStorages();
        defer config.unlockStorages();
        for (cfg.storages, 0..) |*s, i| {
            if (i != 0) try b.appendByte(',');
            try writeStorageRecordJson(&b, s, false);
        }
    }
    try b.append("],\"metas\":[],\"shares\":[],\"note\":\"exported by openlist-zig; users/metas/shares are not modeled (users carry no password hash)\"}");
    // 文件名拼在 arena 上：曾经这里是栈上 `var name_buf: [64]u8` + bufPrint，
    // 而 res.set 只存指针不拷贝（现已改为 dupe），handler 返回后栈被复用，
    // 响应头里出现栈垃圾与 NUL，curl/浏览器直接拒绝下载。
    const fname = try std.fmt.allocPrint(a, "attachment; filename=\"openlist_backup_{d}.json\"", .{rt.nowSeconds()});
    try res.set("Content-Disposition", fname);
    try res.jsonOkRaw(b.slice());
}

/// 从导入行里取 addition 的字符串形态（字符串或对象都收，同 storage/create）。
fn importAddition(a: std.mem.Allocator, row: *const json.Value) !?[]const u8 {
    const node = row.getPath("addition") orelse return "{}";
    return additionStringFrom(a, node);
}

fn handleConfigImport(app: *App, req: *http.Request, res: *http.Response) !void {
    if (!std.mem.eql(u8, req.method, "POST")) return res.jsonError(405, "method not allowed");
    const a = req.arena;
    const root = try parseBodyJson(a, req, res) orelse return;
    const cfg = config.get();
    const ca = cfg.allocator();
    const mode = (try req.queryGetDecoded("mode")) orelse "merge";
    const overwrite = std.mem.eql(u8, mode, "overwrite");

    // ---- 格式识别：顶层 settings 是数组 ⇒ OpenList 备份；否则按 cfg.json 读 ----
    var backup_settings: ?[]json.Value = null;
    if (root.getPath("settings")) |sn| {
        if (sn.asArray()) |arr| backup_settings = arr;
    }

    var b = Buf.init(a);
    var settings_applied: usize = 0;
    var settings_ignored: usize = 0;
    var created: usize = 0;
    var updated: usize = 0;
    var fails = List([]const u8).init(a);
    var touched = List(i64).init(a); // 需要重建挂载的 id
    var unmounted = List(i64).init(a); // 需要摘挂载的旧 id

    const io = rt.io();
    app.storage_ops_lock.lockUncancelable(io);
    defer app.storage_ops_lock.unlock(io);

    // ---- settings ----
    if (backup_settings) |arr| {
        for (arr) |item| {
            const key = item.strAt("key") orelse continue;
            if (!isConfigBackedSetting(key)) {
                settings_ignored += 1;
                continue;
            }
            const value_node = item.getPath("value") orelse continue;
            const value = switch (value_node.*) {
                .string => |s| s,
                .bool => |v| if (v) "true" else "false",
                .int => |v| try std.fmt.allocPrint(a, "{d}", .{v}),
                else => {
                    settings_ignored += 1;
                    continue;
                },
            };
            try applySettingItem(cfg, key, try ca.dupe(u8, value));
            settings_applied += 1;
        }
    } else {
        // cfg.json 格式：顶层键或 zig 块。
        for (setting_defs) |def| {
            var node = root.getPath(def.key);
            if (node == null) {
                if (root.getPath("zig")) |z| node = z.getPath(def.key);
            }
            const vn = node orelse continue;
            const value = switch (vn.*) {
                .string => |s| s,
                .bool => |v| if (v) "true" else "false",
                .int => |v| try std.fmt.allocPrint(a, "{d}", .{v}),
                else => continue,
            };
            try applySettingItem(cfg, def.key, try ca.dupe(u8, value));
            settings_applied += 1;
        }
    }
    mirrorFrontendSettings(app, cfg) catch |e| {
        log.warn("config/import: mirror frontend settings: {s}", .{@errorName(e)});
    };

    // ---- storages：先校验出计划，再统一落表（避免边遍历边增删）----
    const Plan = struct {
        mount_path: []const u8,
        driver_key: []const u8,
        addition: []const u8,
        order: i64,
        cache_expiration: i64,
        remark: []const u8,
        disabled: bool,
        web_proxy: bool,
        webdav_policy: []const u8,
        down_proxy_url: []const u8,
        disable_proxy_sign: bool,
    };
    var plan = List(Plan).init(a);

    if (root.getPath("storages")) |sn| {
        if (sn.asArray()) |rows| {
            for (rows) |*row| {
                const raw_path = row.strAt("mount_path") orelse "";
                if (raw_path.len == 0) {
                    try fails.append(try std.fmt.allocPrint(a, "<empty>: mount_path is required", .{}));
                    continue;
                }
                const driver_name = row.strAt("driver") orelse "";
                const f = driver.find(driver_name) orelse {
                    try fails.append(try std.fmt.allocPrint(a, "{s}: no driver named: {s}", .{ raw_path, driver_name }));
                    continue;
                };
                const addition = (try importAddition(a, row)) orelse {
                    try fails.append(try std.fmt.allocPrint(a, "{s}: addition must be a JSON string or object", .{raw_path}));
                    continue;
                };
                _ = json.parse(a, addition) catch {
                    try fails.append(try std.fmt.allocPrint(a, "{s}: addition is not valid JSON", .{raw_path}));
                    continue;
                };
                const mount_path = try normalizeMountPath(a, raw_path);
                // 文件内去重：同一路径取后出现的行。
                var dup = false;
                for (plan.slice()) |*p| {
                    if (std.mem.eql(u8, p.mount_path, mount_path)) {
                        dup = true;
                        break;
                    }
                }
                if (dup) continue;
                try plan.append(.{
                    .mount_path = mount_path,
                    .driver_key = f.key,
                    .addition = addition,
                    .order = row.intAt("order") orelse 0,
                    .cache_expiration = row.intAt("cache_expiration") orelse 0,
                    .remark = row.strAt("remark") orelse "",
                    .disabled = boolAt(row, "disabled"),
                    .web_proxy = boolAt(row, "web_proxy"),
                    .webdav_policy = normalizeWebdavPolicy(row.strAt("webdav_policy") orelse ""),
                    .down_proxy_url = row.strAt("down_proxy_url") orelse "",
                    .disable_proxy_sign = boolAt(row, "disable_proxy_sign"),
                });
            }
        }
    }

    {
        config.lockStorages();
        defer config.unlockStorages();

        if (overwrite) {
            for (cfg.storages) |s| try unmounted.append(s.id);
            while (cfg.storages.len > 0) {
                _ = try removeStorageRecord(ca, cfg, cfg.storages[cfg.storages.len - 1].id);
            }
        }

        for (plan.slice()) |*p| {
            var existing_id: i64 = 0;
            for (cfg.storages) |*s| {
                const existing = urlmod.cleanPath(a, s.mount_path) catch s.mount_path;
                if (std.mem.eql(u8, existing, p.mount_path)) {
                    existing_id = s.id;
                    break;
                }
            }
            if (existing_id != 0) {
                if (overwrite) {
                    // overwrite 模式下表已清空，不应命中（防御：当新建）。
                    existing_id = 0;
                } else {
                    const elem = cfg.storageById(existing_id).?;
                    if (!std.mem.eql(u8, elem.driver, p.driver_key)) {
                        try fails.append(try std.fmt.allocPrint(a, "{s}: driver cannot be changed", .{p.mount_path}));
                        continue;
                    }
                    elem.mount_path = try ca.dupe(u8, p.mount_path);
                    elem.order = p.order;
                    elem.cache_expiration = p.cache_expiration;
                    elem.addition = try ca.dupe(u8, p.addition);
                    elem.remark = try ca.dupe(u8, p.remark);
                    elem.disabled = p.disabled;
                    elem.web_proxy = p.web_proxy;
                    elem.webdav_policy = p.webdav_policy;
                    elem.down_proxy_url = try ca.dupe(u8, p.down_proxy_url);
                    elem.disable_proxy_sign = p.disable_proxy_sign;
                    elem.modified = rt.nowSeconds();
                    elem.status = "work";
                    elem.error_msg = "";
                    updated += 1;
                    if (!p.disabled) try touched.append(existing_id);
                    continue;
                }
            }
            var max_id: i64 = 0;
            for (cfg.storages) |*s| {
                if (s.id > max_id) max_id = s.id;
            }
            const id = max_id + 1;
            try appendStorageRecord(ca, cfg, .{
                .id = id,
                .mount_path = try ca.dupe(u8, p.mount_path),
                .order = p.order,
                .driver = p.driver_key,
                .cache_expiration = p.cache_expiration,
                .status = "work",
                .addition = try ca.dupe(u8, p.addition),
                .remark = try ca.dupe(u8, p.remark),
                .disabled = p.disabled,
                .web_proxy = p.web_proxy,
                .webdav_policy = p.webdav_policy,
                .down_proxy_url = try ca.dupe(u8, p.down_proxy_url),
                .disable_proxy_sign = p.disable_proxy_sign,
                .modified = rt.nowSeconds(),
            });
            created += 1;
            if (!p.disabled) try touched.append(id);
        }
    }

    cfg.save() catch |e| {
        log.warn("config/import: could not persist: {s}", .{@errorName(e)});
        return res.jsonError(500, "could not save config");
    };

    // ---- 重挂载 ----
    for (unmounted.slice()) |id| try republishWithEdit(app, app.alloc, id, null);
    for (touched.slice()) |id| {
        const snap = blk: {
            config.lockStorages();
            defer config.unlockStorages();
            const s = cfg.storageById(id) orelse continue;
            break :blk try dupeStorage(app.alloc, s);
        };
        switch (try buildMountFromStorage(app.alloc, &snap)) {
            .ok => |m| {
                try republishWithEdit(app, app.alloc, id, m);
                log.info("config/import: storage #{d} {s} -> {s}", .{ id, snap.driver, m.mount_path });
            },
            .init_failed => |msg| {
                cfg.setStorageError(id, msg);
                try republishWithEdit(app, app.alloc, id, null);
                try fails.append(try std.fmt.allocPrint(a, "{s}: init failed: {s}", .{ snap.mount_path, msg }));
            },
            .no_driver => try fails.append(try std.fmt.allocPrint(a, "{s}: driver disappeared from build", .{snap.mount_path})),
            .invalid_addition => try fails.append(try std.fmt.allocPrint(a, "{s}: addition is not valid JSON", .{snap.mount_path})),
        }
    }

    // ---- 汇总 ----
    try b.append("{\"created\":");
    try b.print("{d}", .{created});
    try b.append(",\"updated\":");
    try b.print("{d}", .{updated});
    try b.append(",\"settings_applied\":");
    try b.print("{d}", .{settings_applied});
    try b.append(",\"settings_ignored\":");
    try b.print("{d}", .{settings_ignored});
    try b.append(",\"failed\":[");
    for (fails.slice(), 0..) |msg, i| {
        if (i != 0) try b.appendByte(',');
        try json.writeString(&b, msg);
    }
    try b.append("],\"ignored_sections\":{");
    if (backup_settings != null) {
        // 备份格式里这些段我们没建模，逐个点名（注意别留尾逗号）。
        var ignored: usize = 0;
        if (root.getPath("users") != null) {
            if (ignored != 0) try b.appendByte(',');
            try b.append("\"users\":true");
            ignored += 1;
        }
        if (root.getPath("metas") != null) {
            if (ignored != 0) try b.appendByte(',');
            try b.append("\"metas\":true");
            ignored += 1;
        }
        if (root.getPath("shares") != null) {
            if (ignored != 0) try b.appendByte(',');
            try b.append("\"shares\":true");
            ignored += 1;
        }
    }
    try b.append("}}");
    log.info("config/import: mode={s} created={d} updated={d} settings={d} failed={d}", .{ mode, created, updated, settings_applied, fails.slice().len });
    // 管理端点的响应要走 Go 信封（{code,message,data}），前端 axios 才认。
    try res.jsonOk(b.slice());
}

/// This binary has no background task manager (and deliberately does not add
/// offline-download workers). Returning the real empty-list envelope lets the
/// stock task-centre view render accurately; task actions are not advertised.
fn handleTaskRoute(req: *http.Request, res: *http.Response, suffix: []const u8) !void {
    var it = std.mem.splitScalar(u8, suffix, '/');
    const kind = it.next() orelse return res.jsonError(404, "task route not found");
    const action = it.next() orelse return res.jsonError(404, "task route not found");
    if (it.next() != null) return res.jsonError(404, "task route not found");
    const allowed = [_][]const u8{ "upload", "copy", "move", "offline_download", "offline_download_transfer", "decompress", "decompress_upload" };
    var known = false;
    for (allowed) |candidate| if (std.mem.eql(u8, kind, candidate)) {
        known = true;
        break;
    };
    if (!known) return res.jsonError(404, "task route not found");
    if (!std.mem.eql(u8, action, "undone") and !std.mem.eql(u8, action, "done")) return res.jsonError(404, "task action not found");
    if (!std.mem.eql(u8, req.method, "GET")) return res.jsonError(405, "method not allowed");
    try res.jsonOk("[]");
}

// ---------------------------------------------------------------------------
// Download
// ---------------------------------------------------------------------------

/// Go `utils.GenerateContentDisposition`（pkg/utils/http.go）逐字节对齐：
/// `attachment; filename="<编码>"; filename*=utf-8''<编码>`。两处的编码在 Go
/// 里是同一套字符集 —— `QueryEscape` 保留 `[A-Za-z0-9-_.~]`、其余 %XX 大写，
/// 空格先得 `+` 再被替换成 `%20`，与 RFC5987 编码结果一致（含非 ASCII 时按
/// UTF-8 逐字节转义）。
pub fn contentDisposition(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var b = Buf.init(a);
    try b.append("attachment; filename=\"");
    try appendPercentEncoded(&b, name);
    // ⚠️ Go 的格式串 `...filename*=utf-8''%s` 结尾**没有**引号（RFC5987 的
    // ext-value 不带引号）—— 曾在这里多拼一个 `"`，被单测逐字节抓出。
    try b.append("\"; filename*=utf-8''");
    try appendPercentEncoded(&b, name);
    return b.toOwned();
}

fn appendPercentEncoded(b: *Buf, s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try b.appendByte(c);
        } else {
            try b.appendByte('%');
            try b.appendByte(hex[c >> 4]);
            try b.appendByte(hex[c & 0xf]);
        }
    }
}

/// `proxy_types` 列表（Go 设置默认 `m3u8,url`；配置未加载时同默认）。
fn proxyTypes() []const u8 {
    return if (config.getOpt()) |c| c.proxy_types else "m3u8,url";
}

/// `text_types` 列表（Go 设置默认 32 项，见 `internal/bootstrap/data/
/// setting.go:128`；配置未加载时同默认）。
fn textTypes() []const u8 {
    return if (config.getOpt()) |c| c.text_types else "txt,htm,html,xml,java,properties,sql,js,md,json,conf,ini,vue,php,py,bat,gitignore,yml,go,sh,c,cpp,h,hpp,tsx,vtt,srt,ass,rs,lrc,strm";
}

/// Go `down.go:117-130` 的 `canProxy`（Proxy 端点 `/p/` 的准入）：
/// MustProxy || WebProxy || WebdavProxyURL || proxy_types || text_types。
/// 不满足 → 403 `proxy not allowed`。
/// ⚠ 与 `/d/` 的 `ShouldProxy`（**无** text_types 分支）不同——这是上游
/// 两个端点的既有差异（ShouldProxy 只查 MustProxy/WebProxy/proxy_types），
/// 不是笔误，两个函数都要保持各自的原样。
fn canProxy(must_proxy: bool, web_proxy: bool, webdav_policy: []const u8, name: []const u8) bool {
    if (must_proxy or web_proxy) return true;
    // Go `model.Proxy.WebdavProxyURL()`：策略是 use_proxy_url 时也算可代理。
    if (isWebdavPolicy(webdav_policy, "use_proxy_url")) return true;
    if (extInList(proxyTypes(), name)) return true;
    if (extInList(textTypes(), name)) return true;
    return false;
}

/// Go `model.Proxy.Webdav302()` / `WebdavProxyURL()`（internal/model/storage.go:53-59）。
/// `""` 与 `"native_proxy"` 都是"服务端转发"（上游表单的 native 项）。
pub fn isWebdavPolicy(policy: []const u8, which: []const u8) bool {
    return std.mem.eql(u8, policy, which);
}

/// 管理员表单可能把 native 项原样发成 `"native_proxy"`，而上游的比较是
/// **精确等于**（`p.WebdavPolicy == "use_proxy_url"`），所以 native 一律
/// 归一成空串保存 —— 否则 `"/p/"` 与 WebDAV 的判定会全部落空。
fn normalizeWebdavPolicy(p: []const u8) []const u8 {
    if (std.mem.eql(u8, p, "use_proxy_url") or std.mem.eql(u8, p, "302_redirect")) return p;
    return "";
}

/// `/d/`、`/p/` 的驱动错误输出 —— **ErrorPage（真状态码 + HTML）**，
/// 与 JSON API 的 200 包裹是两套体系（Go：Down 链全部走 `common.ErrorPage`）。
/// 文案贴近 Go 的 wrap 链：目标不存在 → `failed link: failed to get file:
/// object not found`（fs.link → op.Link → GetUnwrap 三层的形态）；
/// 其余尽量带上上游细节（`ctx.err_detail`）。
fn downloadDriverError(res: *http.Response, e: anyerror, ctx: ?*driver.Ctx, a: std.mem.Allocator) !void {
    if (e == error.NotFound) {
        return res.errorPage(500, "failed link: failed to get file: object not found");
    }
    if (ctx) |c| {
        if (c.err_detail) |d| {
            const msg = std.fmt.allocPrint(a, "failed link: {s}", .{d}) catch return res.errorPage(500, "failed link");
            return res.errorPage(500, msg);
        }
    }
    const msg = std.fmt.allocPrint(a, "failed link: {s}", .{@errorName(e)}) catch return res.errorPage(500, "failed link");
    return res.errorPage(500, msg);
}

// ---------------------------------------------------------------------------
// 条件请求 / Etag / Last-Modified —— 对齐 Go `internal/net/util.go` +
// `server/common/proxy.go` 的 `attachHeader` / `GetEtag` / `ServeHTTP`。
//
// 为什么这一块必须做：下载器（IDM/Motrix）用 ETag/Last-Modified 做续传
// 校验与缓存判重；浏览器用 If-None-Match/If-Modified-Since 走 304 省流量。
// 这一层此前完全缺失（只对字节层做了测试）——2026-10-17 对账补全。
// ---------------------------------------------------------------------------

/// Go `http.TimeFormat` = `"Mon, 02 Jan 2006 15:04:05 GMT"`（UTC）。
pub fn httpTime(a: std.mem.Allocator, ts: i64) ![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const epoch_day = es.getEpochDay();
    const ds = es.getDaySeconds();
    const yd = epoch_day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const wd = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const mo = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    // 1970-01-01 是周四（索引 4 with Sun=0）。
    const wday = @mod(epoch_day.day + 4, 7);
    return std.fmt.allocPrint(a, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        wd[wday],
        // ⚠ `day_index` 是**从 0 起**的"月内第几天"（std 注释："days into
        // the month (0 to 30)"），RFC 7231 的 IMF-fixdate 要的是 1 起。
        md.day_index + 1,
        mo[md.month.numeric() - 1],
        yd.year,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

/// Go `http.ParseTime` 的 RFC1123 分支（客户端实际使用的格式）。解析失败
/// 返回 null —— 与 Go `time.Parse` 失败后 `condNone` 的走向一致。宽容性
/// 差异：不校验星期名与日期的一致性、大小写不敏感（Go 偏严格）。
pub fn parseHttpTime(s: []const u8) ?i64 {
    var t = std.mem.trim(u8, s, " \t");
    // "Wdy, " 前缀
    if (std.mem.indexOfScalar(u8, t, ',')) |i| t = t[i + 1 ..];
    // 下面直接 `tokenizeScalar`，它本身就会跳过前导空白，不必再 trim 一次
    // （Zig 0.17 已经没有 `std.mem.trimLeft`）。
    // 期望： "02 Jan 2006 15:04:05 GMT"
    var it = std.mem.tokenizeScalar(u8, t, ' ');
    const day = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const mon_s = it.next() orelse return null;
    const year = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const hms = it.next() orelse return null;
    const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    var mon: i64 = 0;
    var found = false;
    for (months, 0..) |m, i| {
        if (mon_s.len == 3 and std.ascii.eqlIgnoreCase(m, mon_s)) {
            mon = @intCast(i + 1);
            found = true;
            break;
        }
    }
    if (!found) return null;
    // "15:04:05"
    var hit = std.mem.splitScalar(u8, hms, ':');
    const hh = std.fmt.parseInt(i64, hit.next() orelse return null, 10) catch return null;
    const mm = std.fmt.parseInt(i64, hit.next() orelse return null, 10) catch return null;
    const ss = std.fmt.parseInt(i64, hit.next() orelse return null, 10) catch return null;
    if (day < 1 or day > 31 or year < 1970) return null;
    return daysFromCivil(year, mon, day) * 86400 + hh * 3600 + mm * 60 + ss;
}

/// Howard Hinnant 的 days_from_civil（1970-01-01 为 0）。
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divTrunc(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const EtagScan = struct { etag: []const u8 = "", remain: []const u8 = "" };

/// Go `scanETag`（internal/net/util.go:20）：提取语法合法的 ETag（`"..."` 或
/// `W/"..."`），返回其后的剩余文本；非法则 `{"", ""}`。
fn scanEtag(s_in: []const u8) EtagScan {
    const s = std.mem.trim(u8, s_in, " \t\r\n\x0b\x0c");
    var start: usize = 0;
    if (std.mem.startsWith(u8, s, "W/")) start = 2;
    if (s.len - start < 2 or s[start] != '"') return .{};
    var i = start + 1;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == 0x21 or (c >= 0x23 and c <= 0x7e) or c >= 0x80) continue;
        if (c == '"') return .{ .etag = s[0 .. i + 1], .remain = s[i + 1 ..] };
        return .{};
    }
    return .{};
}

/// Go `etagStrongMatch`。假定入参是合法 ETag。
fn etagStrongMatch(etag_a: []const u8, etag_b: []const u8) bool {
    return etag_a.len > 0 and etag_a[0] == '"' and std.mem.eql(u8, etag_a, etag_b);
}

/// Go `etagWeakMatch`。
fn etagWeakMatch(etag_a: []const u8, etag_b: []const u8) bool {
    const a = if (std.mem.startsWith(u8, etag_a, "W/")) etag_a[2..] else etag_a;
    const b = if (std.mem.startsWith(u8, etag_b, "W/")) etag_b[2..] else etag_b;
    return std.mem.eql(u8, a, b);
}

const CondResult = enum { none, ok, no };

fn checkIfMatch(req: *http.Request, etag: []const u8) CondResult {
    var im = req.header("If-Match") orelse return .none;
    while (true) {
        im = std.mem.trim(u8, im, " \t\r\n\x0b\x0c");
        if (im.len == 0) break;
        if (im[0] == ',') {
            im = im[1..];
            continue;
        }
        if (im[0] == '*') return .ok;
        const sc = scanEtag(im);
        if (sc.etag.len == 0) break;
        if (etagStrongMatch(sc.etag, etag)) return .ok;
        im = sc.remain;
    }
    return .no;
}

fn checkIfUnmodifiedSince(req: *http.Request, modtime: i64) CondResult {
    const ius = req.header("If-Unmodified-Since") orelse return .none;
    if (modtime == 0) return .none; // isZeroTime
    const t = parseHttpTime(ius) orelse return .none;
    return if (modtime <= t) .ok else .no;
}

fn checkIfNoneMatch(req: *http.Request, etag: []const u8) CondResult {
    var inm = req.header("If-None-Match") orelse return .none;
    while (true) {
        inm = std.mem.trim(u8, inm, " \t\r\n\x0b\x0c");
        if (inm.len == 0) break;
        if (inm[0] == ',') {
            inm = inm[1..];
            continue;
        }
        if (inm[0] == '*') return .no;
        const sc = scanEtag(inm);
        if (sc.etag.len == 0) break;
        if (etagWeakMatch(sc.etag, etag)) return .no;
        inm = sc.remain;
    }
    return .ok;
}

fn checkIfModifiedSince(req: *http.Request, modtime: i64) CondResult {
    if (!std.mem.eql(u8, req.method, "GET") and !std.mem.eql(u8, req.method, "HEAD")) return .none;
    const ims = req.header("If-Modified-Since") orelse return .none;
    if (modtime == 0) return .none;
    const t = parseHttpTime(ims) orelse return .none;
    return if (modtime <= t) .no else .ok;
}

fn checkIfRange(req: *http.Request, etag: []const u8, modtime: i64) CondResult {
    if (!std.mem.eql(u8, req.method, "GET") and !std.mem.eql(u8, req.method, "HEAD")) return .none;
    const ir = req.header("If-Range") orelse return .none;
    const sc = scanEtag(ir);
    if (sc.etag.len > 0) {
        return if (etagStrongMatch(sc.etag, etag)) .ok else .no;
    }
    if (modtime == 0) return .no;
    const t = parseHttpTime(ir) orelse return .no;
    return if (t == modtime) .ok else .no;
}

const PreGate = enum { proceed, not_modified, precondition_failed };

/// Go `checkPreconditions`（internal/net/util.go:243）：RFC 7232 §6 的完整
/// 序列。`ignore_range` 为 true 表示 If-Range 失效、调用方须丢弃 Range 头
/// （回落整文件 200）。
const PreCheck = struct { gate: PreGate, ignore_range: bool };

fn checkPreconditions(req: *http.Request, etag: []const u8, modtime: i64) PreCheck {
    var ch = checkIfMatch(req, etag);
    if (ch == .none) ch = checkIfUnmodifiedSince(req, modtime);
    if (ch == .no) return .{ .gate = .precondition_failed, .ignore_range = false };

    switch (checkIfNoneMatch(req, etag)) {
        .no => {
            if (std.mem.eql(u8, req.method, "GET") or std.mem.eql(u8, req.method, "HEAD")) {
                return .{ .gate = .not_modified, .ignore_range = false };
            }
            return .{ .gate = .precondition_failed, .ignore_range = false };
        },
        .none => {
            if (checkIfModifiedSince(req, modtime) == .no) {
                return .{ .gate = .not_modified, .ignore_range = false };
            }
        },
        .ok => {},
    }

    var ignore_range = false;
    if (req.header("Range") != null and checkIfRange(req, etag, modtime) == .no) {
        ignore_range = true;
    }
    return .{ .gate = .proceed, .ignore_range = ignore_range };
}

/// Go `GetEtag`（server/common/proxy.go:90）：哈希（非空时）→ `"<hash>"`；
/// 否则参考 nginx → `"<modtime hex>-<size hex>"`。
pub fn etagFor(a: std.mem.Allocator, f: driver.File, total: u64) ![]const u8 {
    if (f.hash_info) |h| {
        if (h.hash_value.len > 0) return std.fmt.allocPrint(a, "\"{s}\"", .{h.hash_value});
    }
    return std.fmt.allocPrint(a, "\"{x}-{x}\"", .{ f.modified, total });
}

/// `attachHeader`（server/common/proxy.go:69-88）+ `ServeHTTP` 前置段的合并：
/// 设 Etag → Last-Modified → C-D/CT（调用方已设 CT 时跳过）→ 跑条件请求。
/// 返回 done=true 表示 304/412 已写出，调用方直接 return。
const PreconditionGate = struct { done: bool, ignore_range: bool };

pub fn preconditionGate(
    req: *http.Request,
    res: *http.Response,
    a: std.mem.Allocator,
    f: driver.File,
    total: u64,
    ct: []const u8,
) !PreconditionGate {
    try res.set("Content-Disposition", try contentDisposition(a, f.name));
    try res.set("Content-Type", ct);
    const etag = try etagFor(a, f, total);
    try res.set("Etag", etag);
    if (f.modified != 0) try res.set("Last-Modified", try httpTime(a, f.modified));

    const pre = checkPreconditions(req, etag, f.modified);
    switch (pre.gate) {
        .precondition_failed => {
            res.setStatus(412);
            return .{ .done = true, .ignore_range = false };
        },
        .not_modified => {
            // Go `writeNotModified`（internal/net/util.go:210）：删
            // Content-Type / Content-Length / Content-Encoding；有 Etag 时
            // 连 Last-Modified 一起删。C-D 与 Etag 保留。
            res.removeHeader("Content-Type");
            res.removeHeader("Content-Length");
            res.removeHeader("Content-Encoding");
            res.removeHeader("Last-Modified");
            res.setStatus(304);
            return .{ .done = true, .ignore_range = false };
        },
        .proceed => {},
    }
    return .{ .done = false, .ignore_range = pre.ignore_range };
}

/// Go `utils.SliceContains(conf.SlicesMap[...], utils.Ext(filename))` 的等价
/// （`proxy_types` / `text_types` 两个设置共用）：`utils.Ext` = 最后一个
/// '.' 之后的部分**小写化**（无点则空串），`SliceContains` 对**条目原样**
/// 精确比较（不做 trim、不做条目大小写折叠 —— "TXT" 条目匹配不了 "a.txt"，
/// 与 Go `strings.Split` + 精确比较一致）。
fn extInList(list: []const u8, name: []const u8) bool {
    const idx = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const ext = name[idx + 1 ..];
    if (ext.len == 0) return false;
    var it = std.mem.tokenizeScalar(u8, list, ',');
    while (it.next()) |entry| {
        if (entry.len != ext.len) continue;
        var same = true;
        for (entry, ext) |e, x| {
            if (e != std.ascii.toLower(x)) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

fn handleDownload(app: *App, req: *http.Request, res: *http.Response, force_proxy: bool) !void {
    const a = req.arena;
    const prefix: usize = 3; // "/d/" or "/p/"
    const raw = req.path[prefix..];
    const path = std.fmt.allocPrint(a, "/{s}", .{raw}) catch return res.errorPage(500, "out of memory");

    // 鉴权（Go `middlewares.Down`）：`needSign` 时验签，四类失败 → 401
    // **HTML**（Go ErrorPage 真状态码语义）。无 sign 且无需签 → 直接放行
    // （默认配置下 /d/ 匿名可达，与 Go 一致）。
    const ctx_path = path;
    if (downloadAuthError(app, req, ctx_path)) |e| {
        return res.errorPage(401, downloadAuthMessage(e));
    }

    const r = app.resolve(path) orelse {
        // Go `down.go:23-27`：fs.GetStorage 失败 → `ErrorPage(err, 500)`；
        // 文案是 `errs.NewErr(StorageNotFound, "rawPath: %s", rawPath)` 的
        // `"%w; %s"` 形态（internal/errs/errors.go:33）。
        const msg = std.fmt.allocPrint(a, "storage not found; rawPath: {s}", .{path}) catch "storage not found";
        return res.errorPage(500, msg);
    };
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };

    const f = r.mount.driver.details(&ctx, r.rel) catch |e| return downloadDriverError(res, e, &ctx, a);
    // Go `op.Link`（internal/op/fs.go:256-258）：对目录直接 `errs.NotFile`，
    // 经 `fs.link` 的 `WithMessage("failed link")` wrap 成
    // `failed link: not a file`，Down 层 ErrorPage 500。
    // （此前实现回 `400 is a directory` —— 状态码与文案都想当然写错了。）
    if (f.is_dir) return res.errorPage(500, "failed link: not a file");

    // A05：同样把调用方的头透传给驱动（Go fsread.go 传的是 c.Request.Header）。
    // ⚠ link 先于 canProxy 执行（我们需要 link 结果里的 `proxy` 标志 ≈
    // Go 的 MustProxy），但 **/p/ 的 403 判定必须优先于 link 的错误**：
    // Go 的 Proxy 端点在调 link 之前就 canProxy，不可代理的文件直接 403
    // `proxy not allowed`（哪怕文件本身不存在）。
    var lk_err: ?anyerror = null;
    const lk_opt: ?driver.Link = r.mount.driver.link(&ctx, r.rel, .{
        .redirect = !force_proxy,
        .headers = req.headers,
    }) catch |e| blk: {
        lk_err = e;
        break :blk null;
    };
    if (force_proxy) {
        const must = if (lk_opt) |lk| lk.proxy else false;
        if (!canProxy(must, r.mount.storage.web_proxy, r.mount.storage.webdav_policy, f.name)) {
            return res.errorPage(403, "proxy not allowed");
        }
    }
    if (lk_opt == null) return downloadDriverError(res, lk_err.?, &ctx, a);
    const lk = lk_opt.?;

    // `total` is what we advertise in `Content-Range`. For local files it is the
    // on-disk size; for in-memory content (Strm 的 `.strm` 文本) it is the text
    // length; for remote it comes from `details`.
    const total: u64 = if (lk.local_path) |_| lk.local_size else if (lk.text) |t| t.len else @intCast(@max(f.size, 0));

    // 条件请求闸门（RFC7232）：只对"实体内容"分支（本地文件 / Strm 文本）
    // 生效 —— 对应 Go 里 link 带 RangeReader 的 `attachHeader` + `ServeHTTP`
    // 那条路。透明代理分支不设这些头（上游自己的响应头照抄，见下）。
    // 顺序也照抄 Go：304/412 先于 Range 解析与 416。
    var gate: PreconditionGate = .{ .done = false, .ignore_range = false };
    const serves_content = lk.local_path != null or lk.text != null;
    if (serves_content) {
        const ct: []const u8 = if (lk.text != null) "text/plain; charset=utf-8" else mimeFor(f.name);
        gate = try preconditionGate(req, res, a, f, total, ct);
        if (gate.done) return;
    }

    // A single byte range, if the client asked for one. Malformed/unknown
    // range syntax is ignored (normal 200); a syntactically valid but
    // unsatisfiable range must be 416, never a silent full-file response.
    // `If-Range` 失配时丢弃 Range（Go `checkPreconditions` 把 rangeHeader 清空）。
    const range_result0 = if (req.header("Range")) |rh| parseRange(rh, total) else ParsedRange.ignore;
    const range_result = if (gate.ignore_range) ParsedRange.ignore else range_result0;
    if (range_result == .unsatisfiable) {
        res.setStatus(416);
        try res.set("Accept-Ranges", "bytes");
        try res.set("Content-Range", try std.fmt.allocPrint(a, "bytes */{d}", .{total}));
        return;
    }
    const range: ?RangeBounds = switch (range_result) {
        .valid => |rg| rg,
        else => null,
    };

    // Local files: stream straight off disk, range-supported.
    if (lk.local_path) |lp| {
        const file = std.Io.Dir.cwd().openFile(rt.io(), lp, .{}) catch |e| {
            log.warn("api: open {s} failed: {s}", .{ lp, @errorName(e) });
            return res.errorPage(500, try std.fmt.allocPrint(a, "failed link: failed get link: open {s}", .{lp}));
        };
        // CT/C-D/Etag/LM 已由 preconditionGate 设置（对齐 attachHeader）。
        try res.set("Accept-Ranges", "bytes");
        if (range) |rg| {
            if (rg.start >= total) {
                res.setStatus(416);
                try res.set("Content-Range", try std.fmt.allocPrint(a, "bytes */{d}", .{total}));
                return;
            }
            res.setStatus(206);
            try res.set("Content-Range", try std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ rg.start, rg.end, total }));
            // Stream only the requested window; never buffer it.
            streamRange(res, a, file, rg.start, rg.end) catch
                return res.errorPage(500, "out of memory");
        } else {
            res.sendFile(file, total);
        }
        return;
    }

    // In-memory content (`Link.text` — Strm 的 `.strm` 虚拟文件，内容是 URL
    // 文本；Go `drivers/strm/driver.go:200-204` 用 RangeReader 返回它）。
    // Content-Type 对齐 Go `http.ServeContent` 对 URL 文本的内容嗅探结果。
    if (lk.text) |txt| {
        // CT/C-D/Etag/LM 已由 preconditionGate 设置。
        try res.set("Accept-Ranges", "bytes");
        if (range) |rg| {
            if (rg.start >= total) {
                res.setStatus(416);
                try res.set("Content-Range", try std.fmt.allocPrint(a, "bytes */{d}", .{total}));
                return;
            }
            res.setStatus(206);
            try res.set("Content-Range", try std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ rg.start, rg.end, total }));
            try res.write(txt[rg.start..rg.end + 1]);
        } else {
            res.setStatus(200);
            try res.write(txt);
        }
        return;
    }

    // Remote, no proxy needed: a 302 is cheaper for everyone (the client talks
    // to the upstream directly and negotiates range there).
    //
    // `web_proxy` is Go `ShouldProxy` 的第一分支（server/common/check.go:106-113）：
    // 存储级「Web 代理」开关。直链绑定会话身份的驱动（夸克/UC）必须靠它强制回源
    // —— 302 出去 Cookie 就丢了，CDN 直接 `require login` 403。用户的夸克存储
    // 正是 web_proxy=true（2026-10-16 e2e 实测复现）。
    if (!lk.proxy and !force_proxy and !r.mount.storage.web_proxy and
        !extInList(proxyTypes(), f.name))
    {
        // Go `down.go` 的 `redirect()` 还带这两个头：`Referrer-Policy:
        // no-referrer`（别把面板 URL 泄给 CDN）+ 禁止缓存 302（直链会过期，
        // 被缓存的 302 会让之后的下载打到死链）。
        try res.set("Referrer-Policy", "no-referrer");
        try res.set("Cache-Control", "max-age=0, no-cache, no-store, must-revalidate");
        try res.redirect(lk.url, 302);
        return;
    }

    // Remote with proxy: forward Range to upstream. When the provider honours
    // Range, only that window is buffered by the current std.http client. If it
    // ignores Range (or the caller omits it), the client still buffers the full
    // upstream response; a streaming response reader remains a known follow-up.
    var hdrs = List(Header).init(a);
    for (lk.header) |h| try hdrs.append(h);
    if (range) |rg| {
        try hdrs.append(.{ .name = "Range", .value = try std.fmt.allocPrint(a, "bytes={d}-{d}", .{ rg.start, rg.end }) });
    }
    var jar = cookiejar.Jar.init(a);
    var client = client_mod.Client.init(a, .{}, &jar);
    defer client.deinit();
    const up = client.send(a, .{
        .method = "GET",
        .url = lk.url,
        .headers = hdrs.slice(),
        // N02：回源必须跟随 3xx。CDN 普遍用 302 把请求转到实际边缘节点，
        // 不跟随就会把 302 当成上游错误、回一个 502 给用户。
        // 注意：只在这个**代理回源**点开启；天翼/itvsh 那些把 302 当业务
        // 状态的调用点保持原样，所以不能改 `Request` 的默认值。
        .follow_redirects = true,
    }) catch |e| {
        log.warn("api: proxy fetch {s} failed: {s}", .{ lk.url, @errorName(e) });
        return res.jsonError(502, "upstream fetch failed");
    };
    // 上游非 2xx：**原样透传**状态码与响应头 + 响应体。
    //
    // Go `common.Proxy`（server/common/proxy.go）就是这么做的：
    // `maps.Copy(w.Header(), res.Header)` + `w.WriteHeader(res.StatusCode)`。
    // 以前这里统一改写成 502「upstream returned an error」—— 夸克 cookie
    // 过期时用户看到的是一个无指向的 502，而 CDN 明明回的是
    // 403 `RequestDeniedByCallback: require login [auth expired]` 这种
    // 自解释错误，排查方向被完全误导（2026-10-16 真机排查实录）。
    if (up.status != 200 and up.status != 206) {
        res.setStatus(up.status);
        for (up.headers) |h| {
            // 跳过头 + 我们会自己写 body：Content-Length 交给响应层，
            // Connection/Transfer-Encoding 是逐跳头，透传会破坏本连接的语义。
            // Set-Cookie 对齐 Go `RequestHttp` 的 `res.Header.Del("set-cookie")`
            // —— 上游 CDN 的 cookie 不该借我们的域下发。
            if (std.ascii.eqlIgnoreCase(h.name, "Content-Length")) continue;
            if (std.ascii.eqlIgnoreCase(h.name, "Connection")) continue;
            if (std.ascii.eqlIgnoreCase(h.name, "Transfer-Encoding")) continue;
            if (std.ascii.eqlIgnoreCase(h.name, "Keep-Alive")) continue;
            if (std.ascii.eqlIgnoreCase(h.name, "Set-Cookie")) continue;
            res.set(h.name, h.value) catch continue;
        }
        // 与 Go 透明代理分支一致：C-D 在 `maps.Copy` 之后设置（覆盖上游可能
        // 带的同名头）—— 上游即便报错，下载语义也保持 attachment。
        try res.set("Content-Disposition", try contentDisposition(a, f.name));
        try res.write(up.body);
        return;
    }

    // 上游 2xx：**透明代理语义**（Go `common.Proxy` 的 `maps.Copy(w.Header(),
    // res.Header)` + C-D 覆盖）—— 上游头尽量原样透传，包括 Content-Type、
    // ETag、Last-Modified、Accept-Ranges、Content-Range；只跳过逐跳头、
    // Content-Length（由本响应层计算）与 Set-Cookie（见上）。
    res.setStatus(up.status);
    for (up.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Length")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "Connection")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "Transfer-Encoding")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "Keep-Alive")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "Set-Cookie")) continue;
        res.set(h.name, h.value) catch continue;
    }
    try res.set("Content-Disposition", try contentDisposition(a, f.name));
    if (up.status == 206) {
        // Content-Range 已在上面随上游头透传；body 即 range 段。
        try res.write(up.body);
    } else if (range) |rg| {
        // Upstream ignored the Range and sent the whole file: slice to the window.
        if (rg.start >= up.body.len) {
            res.setStatus(416);
            try res.set("Content-Range", try std.fmt.allocPrint(a, "bytes */{d}", .{total}));
            return;
        }
        const end_ex = @min(rg.end + 1, up.body.len);
        res.setStatus(206);
        try res.set("Content-Range", try std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ rg.start, end_ex - 1, total }));
        try res.write(up.body[rg.start..end_ex]);
    } else {
        try res.write(up.body);
    }
}

// ---------------------------------------------------------------------------
// Range streaming + progress
// ---------------------------------------------------------------------------

const RangeSrc = struct {
    file: std.Io.File,
    cursor: u64,
    end: u64,
};

/// 把 `file` 的 `[start, end]` 这段作为流式正文挂到响应上（Range 响应共用；
/// WebDAV 的 GET 也走这条路，所以抽成函数）。`end` 是闭区间右端。
pub fn streamRange(res: *http.Response, a: std.mem.Allocator, file: std.Io.File, start: u64, end: u64) !void {
    const len = end - start + 1;
    const rs = a.create(RangeSrc) catch return error.OutOfMemory;
    rs.* = .{ .file = file, .cursor = start, .end = end + 1 };
    res.stream = .{ .ctx = rs, .read = rangeRead, .len = len, .cleanup = rangeCleanup };
}

fn rangeRead(ctx: *anyopaque, out: []u8) anyerror!usize {
    const s: *RangeSrc = @ptrCast(@alignCast(ctx));
    if (s.cursor >= s.end) return 0;
    const want = @min(out.len, s.end - s.cursor);
    var got: usize = 0;
    while (got < want) {
        const n = std.Io.File.readPositionalAll(s.file, rt.io(), out[got..want], s.cursor + got) catch |e| return e;
        if (n == 0) break;
        got += n;
    }
    s.cursor += got;
    return got;
}

fn rangeCleanup(ctx: *anyopaque) void {
    const s: *RangeSrc = @ptrCast(@alignCast(ctx));
    s.file.close(rt.io());
}

/// Inclusive byte range bounds, parsed from an HTTP `Range` header. A named
/// type rather than an anonymous struct so the parser's return type and the
/// caller's variable unify — Zig treats identical anonymous structs at two
/// sites as distinct types.
pub const RangeBounds = struct { start: u64, end: u64 };

pub const ParsedRange = union(enum) {
    ignore,
    unsatisfiable,
    valid: RangeBounds,
};

/// Parse a single `bytes=START-END` (or `START-`, or `-SUFFIX`) range. Multiple
/// ranges are intentionally ignored; unsupported/malformed syntax falls back
/// to a normal response, but a valid range outside the resource yields 416.
pub fn parseRange(hdr: []const u8, total: u64) ParsedRange {
    const eq = std.mem.indexOfScalar(u8, hdr, '=') orelse return .ignore;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, hdr[0..eq], " "), "bytes")) return .ignore;
    const spec = std.mem.trim(u8, hdr[eq + 1 ..], " ");
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .ignore;
    const dash_at = std.mem.indexOfScalar(u8, spec, '-') orelse return .ignore;
    if (std.mem.indexOfScalarPos(u8, spec, dash_at + 1, '-') != null) return .ignore;
    const start_s = spec[0..dash_at];
    const end_s = spec[dash_at + 1 ..];
    if (start_s.len == 0) {
        const n = std.fmt.parseInt(u64, end_s, 10) catch return .ignore;
        if (n == 0 or total == 0) return .unsatisfiable;
        const start = if (n >= total) 0 else total - n;
        return .{ .valid = .{ .start = start, .end = total - 1 } };
    }
    const start = std.fmt.parseInt(u64, start_s, 10) catch return .ignore;
    const end_parsed: ?u64 = if (end_s.len == 0) null else std.fmt.parseInt(u64, end_s, 10) catch return .ignore;
    if (total == 0 or start >= total) return .unsatisfiable;
    var end = end_parsed orelse (total - 1);
    if (start > end) return .unsatisfiable;
    if (end >= total) end = total - 1;
    return .{ .valid = .{ .start = start, .end = end } };
}

/// 上传进度。`pct` 是 **0–100**（`driver.ProgressFn` 的语义，
/// 对应 Go `model.UpdateProgress`）。目前 sink 还只是记录下来 —— 前端轮询
/// 上传状态的接口尚未接线（见 TODO）。
const PutProgress = struct { pct: u64 = 0 };

fn putProgressCb(ud: ?*anyopaque, pct: u64) void {
    if (ud) |p| {
        const s: *PutProgress = @ptrCast(@alignCast(p));
        // 只有 0–100 才收，防上游驱动乱报。
        if (pct <= 100) s.pct = pct;
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// `path` 是该条目的完整虚拟路径（`dir/name`）—— 下载签名签的就是它，
/// 对应 Go `server/common/sign.go` 的 `join(parent, name)`。
///
/// ⚠️ 不能用 `o.sign` 代替：绝大多数驱动不填那个字段（Go 是在 op 层统一填
/// 路径的），拿空串当数据会签出一个"对空路径有效"的签名。
fn writeObj(app: *App, b: *Buf, o: model.Obj, path: []const u8) !void {
    try b.append("{\"name\":");
    try json.writeString(b, o.name);
    try b.print(",\"size\":{d},\"is_dir\":{s}", .{ o.size, if (o.is_dir) "true" else "false" });
    try b.append(",\"modified\":");
    try json.writeString(b, try fmtTime(b.alloc, o.modified));
    try b.append(",\"created\":");
    // Go `Object.CreateTime()` 在 Ctime 为零时回退到 ModTime；不能把零值
    // 直接输出为空串，否则前端日期格式化会得到 NaN。
    try json.writeString(b, try fmtTime(b.alloc, if (o.created == 0) o.modified else o.created));
    try b.append(",\"sign\":");
    try json.writeString(b, try signForObj(app, b.alloc, o.is_dir, path));
    try b.append(",\"thumb\":");
    try json.writeString(b, o.thumb);
    try b.print(",\"type\":{d}", .{@backingInt(o.typeEnum())});
    try appendHashFields(b, b.alloc, o.hash_info);
    try b.appendByte('}');
}

/// Go `toObjsResp`（server/handles/fsread.go:234-247）的哈希两兄弟：
///   * `hashinfo` = `obj.GetHash().String()` —— `json.Marshal(map)` 的结果
///     **再当字符串序列化**（外层会再转义一层引号）；零值 HashInfo 的 map 是
///     nil ⇒ Marshal 出字符串 `"null"`（pkg/utils/hash.go:207-215）。
///   * `hash_info` = 同一个 map 本身（无哈希时是 null）。
/// M9：此前 Zig 只发 `hash_info:null`，缺 `hashinfo` 且从不出真值。
fn appendHashFields(b: *Buf, a: std.mem.Allocator, hi: ?model.HashInfo) !void {
    if (hi) |h| {
        var inner = Buf.init(a);
        defer inner.deinit();
        // ⚠ `json.writeString` **自带引号** —— 这里只补结构字符（`{`/`:`/`}`），
        // 不能再写一层引号（否则产出 `{""md5"` 这种非法 JSON）。
        try inner.append("{");
        try json.writeString(&inner, h.hash_name);
        try inner.append(":");
        try json.writeString(&inner, h.hash_value);
        try inner.append("}");
        try b.append(",\"hashinfo\":");
        try json.writeString(b, inner.slice());
        try b.append(",\"hash_info\":");
        try b.append(inner.slice());
    } else {
        try b.append(",\"hashinfo\":\"null\",\"hash_info\":null");
    }
}

/// OpenList serialises timestamps as RFC3339. We emit the same shape so the
/// frontend's date formatting works.
fn fmtTime(a: std.mem.Allocator, ts: i64) ![]const u8 {
    // Go `time.Time{}` JSON 序列化为 RFC3339 零值；空串会让前端日期
    // 格式化器得到 NaN。保留协议形状，所有 Obj 都输出可解析时间。
    if (ts == 0) return "0001-01-01T00:00:00Z";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(ts, 0)) };
    const day = es.getEpochDay();
    const ds = es.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

fn parseBodyJson(a: std.mem.Allocator, req: *http.Request, res: *http.Response) !?json.Value {
    // The frontend sends JSON; a few endpoints also accept form-encoded.
    if (req.body.len() == 0) return json.Value{ .object = .{} };
    const text = req.body.readAll(a) catch return null;
    return json.parse(a, text) catch {
        res.jsonError(400, "invalid JSON body") catch {};
        return null;
    };
}

/// 驱动错误 → HTTP 响应。
///
/// `ctx` 可为 `null`（没有请求上下文的调用点）。非 null 时会读
/// `ctx.err_detail` —— 驱动在返回上游错误前写的**上游原始消息**，用它当
/// message 以对齐 Go：fs 操作失败时 `common.ErrorResp` 直接透出
/// `err.Error()`，用户看到 `capacity limit[{0}]` 这种真原因；在此机制之前
/// 只能返回泛化的 "upstream error"（STATUS §31.7）。
///
/// 只有「上游」分支吃 detail —— NotFound / NotSupported 这些是本地判定，
/// 有明确语义，不该被上游文案替换。
fn mapDriverError(res: *http.Response, e: anyerror, ctx: ?*driver.Ctx) !void {
    const detail: ?[]const u8 = if (ctx) |c| c.err_detail else null;
    return switch (e) {
        error.AuthFailed, error.ConfiguredTokenExpired => res.jsonError(401, @errorName(e)),
        error.NotFound => res.jsonError(404, "not found"),
        error.NotSupported => res.jsonError(501, "operation not supported by this driver"),
        error.RateLimited => res.jsonError(429, "upstream rate limited"),
        error.WafBlocked => res.jsonError(502, detail orelse "blocked by upstream WAF"),
        error.UnexpectedResponse, error.UpstreamError, error.UpstreamHttp, error.UpstreamNotJson => res.jsonError(502, detail orelse "upstream error"),
        error.TokenUnavailable => res.jsonError(502, detail orelse "could not obtain an upstream token"),
        error.ForwardUrlMissing => res.jsonError(500, "storage is misconfigured (forwardUrl missing)"),
        error.MissingCredentials => res.jsonError(500, "storage credentials are missing"),
        error.InvalidPath => res.jsonError(400, "invalid path"),
        error.TargetExists => res.jsonError(409, "target already exists"),
        error.DirectoryNotEmpty => res.jsonError(409, "directory is not empty"),
        error.InsufficientStorage => res.jsonError(507, "insufficient storage"),
        else => res.jsonError(500, @errorName(e)),
    };
}

fn sha256Hex(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s, &digest, .{});
    const out = try a.alloc(u8, 64);
    const hex = "0123456789abcdef";
    for (digest, 0..) |c, i| {
        out[i * 2] = hex[c >> 4];
        out[i * 2 + 1] = hex[c & 0x0F];
    }
    return out;
}

/// Go `model.StaticHashSalt`（`internal/model/user.go:24`）。
/// 前端登录页会先用它把明文口令算成 "static hash"，再 POST 到
/// `/api/auth/login/hash` —— 所以这个常量必须与 Go **逐字节**一致，
/// 否则前端永远登不上（这正是 2026-10-13 那次「登录失败」的根因）。
pub const static_hash_salt = "https://github.com/alist-org/alist";

/// Go `model.StaticHash` = `sha256(password + "-" + StaticHashSalt)`。
pub fn staticHash(a: std.mem.Allocator, pwd: []const u8) ![]const u8 {
    const s = try std.fmt.allocPrint(a, "{s}-{s}", .{ pwd, static_hash_salt });
    return sha256Hex(a, s);
}

/// Go `model.HashPwd(static, salt)` = `sha256(static + "-" + salt)`。
pub fn hashPwd(a: std.mem.Allocator, static: []const u8, salt: []const u8) ![]const u8 {
    const s = try std.fmt.allocPrint(a, "{s}-{s}", .{ static, salt });
    return sha256Hex(a, s);
}

/// Go `model.TwoHashPwd(pwd, salt)` = `HashPwd(StaticHash(pwd), salt)`。
/// **这才是 Go 存进库里的形态**（`User.SetPassword`，`internal/model/user.go:96`）。
pub fn twoHashPwd(a: std.mem.Allocator, pwd: []const u8, salt: []const u8) ![]const u8 {
    const st = try staticHash(a, pwd);
    return hashPwd(a, st, salt);
}

/// Go `random.String(16)` —— `User.SetPassword` 给每个用户现生成 16 位随机 salt。
pub fn randomSalt(a: std.mem.Allocator) ![]const u8 {
    const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    const out = try a.alloc(u8, 16);
    var raw: [1]u8 = undefined;
    for (out) |*c| {
        rt.io().random(&raw);
        c.* = letters[raw[0] % letters.len];
    }
    return out;
}

fn hmacSha256(a: std.mem.Allocator, key: []const u8, msg: []const u8) ![32]u8 {    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, msg, key);
    _ = a;
    return mac;
}

fn b64Url(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try a.alloc(u8, enc.calcSize(data.len));
    return enc.encode(out, data);
}

// ---------------------------------------------------------------------------
// 下载签名（对齐 Go `pkg/sign/hmac.go` + `server/common/sign.go`）
// ---------------------------------------------------------------------------

/// 与上游逐字段一致的四个错误（`pkg/sign/sign.go:12-17`）。
pub const SignError = error{
    SignExpired,
    SignInvalid,
    ExpireInvalid,
    ExpireMissing,
};

/// `Sign(data, expire)` = `base64url(HMAC-SHA256(secret, data + ":" + expire))`
/// 拼上 `":" + expire`。
///
/// ⚠️ 编码用**带 padding 的 URL-safe base64**（`std.base64.url_safe`）—— Go 是
/// `base64.URLEncoding`（`pkg/sign/hmac.go:26`），而 JWT 那边的
/// `base64.RawURLEncoding` 是无 padding 的。两者差一个 `=`，混用会让签名对不上。
/// `b64Url`（无 padding）留给 JWT 用，不要在这里复用。
pub fn signValue(a: std.mem.Allocator, secret: []const u8, data: []const u8, expire: i64) ![]const u8 {
    const expire_str = try std.fmt.allocPrint(a, "{d}", .{expire});
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, try std.fmt.allocPrint(a, "{s}:{s}", .{ data, expire_str }), secret);
    const b64 = std.base64.url_safe.Encoder;
    const raw = try a.alloc(u8, b64.calcSize(mac.len));
    return std.fmt.allocPrint(a, "{s}:{s}", .{ b64.encode(raw, &mac), expire_str });
}

/// 给 `fs/list` / `fs/get` 的对象签一个下载签名。
///
/// 对齐 Go `server/common/sign.go:13-18`：目录不签；非目录时
/// `!encrypt && !sign_all` 也不签（本工程没有 meta 加密，所以只看 `sign_all`）。
fn signForObj(app: *App, a: std.mem.Allocator, is_dir: bool, path: []const u8) ![]const u8 {
    if (is_dir) return "";
    // 没有加载配置（单元测试 / 极早期启动）时按「不签」处理 —— 与 Go 的
    // `setting.GetBool` 在 settings 表未初始化时返回零值同形。
    const cfg = config.getOpt() orelse return "";
    if (!cfg.sign_all) return "";
    const expire_hours = cfg.link_expiration;
    if (expire_hours == 0) return signValue(a, signKey(app), path, 0);
    // 溢出防护：`link_expiration` 是用户可配的，配个巨大值不能让服务崩在
    // 一次列目录上。算不出来就按「不过期」处理。
    const expire = std.math.mul(i64, expire_hours, 3600) catch {
        log.warn("[api] link_expiration={d} overflows; signing without expiry", .{expire_hours});
        return signValue(a, signKey(app), path, 0);
    };
    return signValue(a, signKey(app), path, rt.nowSeconds() + expire);
}

/// `Verify(data, sign)` —— 逐条对齐 Go `pkg/sign/hmac.go:34-56`。
fn verifySign(app: *App, a: std.mem.Allocator, data: []const u8, sign: []const u8) !void {
    // Go `HMACSign.Verify`（pkg/sign/hmac.go:32-50）：`exp := sign[LastIndex(":")+1:]`
    // —— 没有 ':' 时 LastIndex=-1，整个 sign 都算 exp。逐例对齐：
    //   ""      → exp=""     → ExpireMissing（"expire missing"）
    //   "abc"   → exp="abc"  → ParseInt 失败 → ExpireInvalid（"expire invalid"）
    //   "xxx:"  → exp=""     → ExpireMissing
    // 此前实现把"无 ':'"也归为 ExpireMissing，是错的（2026-10-17 对账修正）。
    const exp_str = if (std.mem.lastIndexOfScalar(u8, sign, ':')) |i| sign[i + 1 ..] else sign;
    if (exp_str.len == 0) return SignError.ExpireMissing;
    const expires = std.fmt.parseInt(i64, exp_str, 10) catch return SignError.ExpireInvalid;
    // 0 表示「永不过期」；负数视为已过期。
    if (expires != 0 and expires < rt.nowSeconds()) return SignError.SignExpired;
    const expect = try signValue(a, signKey(app), data, expires);
    // L1：`std.mem.eql` 会在第一个不同字节处提前返回，等于把"前几个字节对
    // 不对"用响应时间泄漏出去。签名比较必须常量时间（同文件已有 `ctEqual`）。
    if (!ctEqual(expect, sign)) return SignError.SignInvalid;
}

/// `/d/`、`/p/` 的鉴权失败（对齐 Go `middlewares.Down` + `pkg/sign` 的四种
/// 错误）。返回 null = 放行。
pub const DownloadAuthError = enum { expire_missing, expire_invalid, sign_expired, sign_invalid };

/// Go `needSign`（server/middlewares/down.go:50-64）：`sign_all` 开关、
/// 存储级 sign（本工程存储配置无此字段，恒 false）、meta 密码（本工程无
/// meta 系统，恒 false）。
fn needSign(_: []const u8) bool {
    const cfg = config.getOpt() orelse return false;
    return cfg.sign_all;
}

/// `/d/`、`/p/` 的鉴权入口。**Go 语义**（server/middlewares/down.go:27-40）：
/// - `needSign` 为 true：`?sign=`（`strings.TrimSuffix(s, "/")` 后）必须通过
///   HMAC 校验，失败即 401 —— **绝不回落 token**；
/// - `needSign` 为 false：**直接放行**（Down 链上没有 auth 中间件，默认
///   配置下匿名可下载）。此前实现"无 sign 时回落 checkAuth"，在 sign_all
///   关闭的部署上与 Go 行为不同（2026-10-17 对账修正）。
fn downloadAuthError(app: *App, req: *http.Request, raw_path: []const u8) ?DownloadAuthError {
    if (!needSign(raw_path)) return null;
    // Go `strings.TrimSuffix(s, "/")` —— 只去掉**一个**尾部斜杠。
    // Go `c.Query("sign")`（middlewares/down.go:35）也是**解码后**的值 ——
    // 客户端把 `=` 编成 `%3D` 时不解码就校验失败。
    const raw = req.queryGetDecoded("sign") catch {
        log.warn("[api] /d/ sign query decode failed for {s}", .{raw_path});
        return .sign_invalid;
    } orelse "";
    const s = if (std.mem.endsWith(u8, raw, "/")) raw[0 .. raw.len - 1] else raw;
    verifySign(app, req.arena, raw_path, s) catch |e| {
        log.warn("[api] /d/ sign rejected for {s}: {s}", .{ raw_path, @errorName(e) });
        return switch (e) {
            SignError.ExpireMissing => .expire_missing,
            SignError.ExpireInvalid => .expire_invalid,
            SignError.SignExpired => .sign_expired,
            SignError.SignInvalid => .sign_invalid,
            // `verifySign` 会分配（HMAC + 拼接），所以它的错误集里还有
            // OutOfMemory。那是资源问题而不是签名问题，但**绝不能因此放行** ——
            // 按"鉴权未通过"处理，并单独打一条 err（与签名失败区分开）。
            error.OutOfMemory => blk: {
                log.err("[api] /d/ sign check out of memory for {s}", .{raw_path});
                break :blk .sign_invalid;
            },
        };
    };
    return null;
}

/// Go `pkg/sign/sign.go:10-14` 的四个文案，逐字。
fn downloadAuthMessage(e: DownloadAuthError) []const u8 {
    return switch (e) {
        .expire_missing => "expire missing",
        .expire_invalid => "expire invalid",
        .sign_expired => "sign expired",
        .sign_invalid => "sign invalid",
    };
}

fn b64UrlDecode(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const out = try a.alloc(u8, try dec.calcSizeForSlice(s));
    try dec.decode(out, s);
    return out;
}

/// Content type by file extension.
///
/// The web-asset entries are not decoration: a browser refuses to execute a
/// `<script type="module">` unless it is served with a JavaScript MIME type, so
/// a frontend build served as `application/octet-stream` would load the shell
/// and then die with a console error. `.ts` is mapped to `video/mp2t` rather
/// than TypeScript because on a file-browsing server the media reading wins —
/// and no build ships raw TypeScript.
pub fn mimeFor(name: []const u8) []const u8 {
    const ext = std.fs.path.extension(name);
    const map = .{
        // Web assets (served from `dist_dir`).
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".svg", "image/svg+xml" },
        .{ ".ico", "image/x-icon" },
        .{ ".webmanifest", "application/manifest+json" },
        .{ ".map", "application/json" },
        .{ ".wasm", "application/wasm" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".otf", "font/otf" },
        // Documents and data.
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".md", "text/markdown; charset=utf-8" },
        .{ ".csv", "text/csv; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".xml", "application/xml" },
        .{ ".pdf", "application/pdf" },
        // Images.
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".png", "image/png" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".avif", "image/avif" },
        .{ ".bmp", "image/bmp" },
        // Audio / video. ⚠️ 这里不能省：浏览器 `<audio>`/`<video>` 只接受
        // `audio/*`、`video/*` 的响应，`application/octet-stream` 会直接报
        // "no supported source"。Go 版在 Linux 上靠 mime.TypeByExtension 读
        // /etc/mime.types 拿到这些类型（Debian 自带），本工程是固定表，必须
        // 把常见音视频扩展名列全 —— 尤其 .mp3。
        .{ ".mp3", "audio/mpeg" },
        .{ ".m4a", "audio/mp4" },
        .{ ".wma", "audio/x-ms-wma" },
        .{ ".mka", "audio/x-matroska" },
        .{ ".mid", "audio/midi" },
        .{ ".midi", "audio/midi" },
        .{ ".amr", "audio/amr" },
        .{ ".ape", "audio/x-ape" },
        .{ ".m3u", "audio/x-mpegurl" },
        .{ ".avi", "video/x-msvideo" },
        .{ ".wmv", "video/x-ms-wmv" },
        .{ ".asf", "video/x-ms-asf" },
        .{ ".flv", "video/x-flv" },
        .{ ".rmvb", "application/vnd.rn-realmedia-vbr" },
        .{ ".rm", "application/vnd.rn-realmedia" },
        .{ ".3gp", "video/3gpp" },
        .{ ".ogv", "video/ogg" },
        .{ ".m4v", "video/x-m4v" },
        .{ ".mpg", "video/mpeg" },
        .{ ".mpeg", "video/mpeg" },
        .{ ".mp4", "video/mp4" },
        .{ ".mkv", "video/x-matroska" },
        .{ ".webm", "video/webm" },
        .{ ".mov", "video/quicktime" },
        .{ ".ts", "video/mp2t" },
        .{ ".m3u8", "application/vnd.apple.mpegurl" },
        .{ ".mp3", "audio/mpeg" },
        .{ ".m4a", "audio/mp4" },
        .{ ".aac", "audio/aac" },
        .{ ".ogg", "audio/ogg" },
        .{ ".wav", "audio/wav" },
        .{ ".flac", "audio/flac" },
        // Archives.
        .{ ".zip", "application/zip" },
        .{ ".7z", "application/x-7z-compressed" },
        .{ ".rar", "application/vnd.rar" },
        .{ ".gz", "application/gzip" },
        .{ ".tar", "application/x-tar" },
    };
    inline for (map) |m| {
        if (std.ascii.eqlIgnoreCase(ext, m[0])) return m[1];
    }
    return "application/octet-stream";
}

fn readSecret(a: std.mem.Allocator, cfg: *config.Config, key: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "zig.{s}", .{key});
    const v = cfg.raw(path) orelse return "";
    return a.dupe(u8, v.asStr() orelse "");
}

fn readSecretInt(cfg: *config.Config, key: []const u8, default: i64) i64 {
    const path = std.fmt.allocPrint(std.heap.page_allocator, "zig.{s}", .{key}) catch return default;
    defer std.heap.page_allocator.free(path);
    const v = cfg.raw(path) orelse return default;
    return v.asInt() orelse default;
}

fn readSecretDefault(a: std.mem.Allocator, cfg: *config.Config, key: []const u8, default: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "zig.{s}", .{key});
    const v = cfg.raw(path) orelse return a.dupe(u8, default);
    return a.dupe(u8, v.asStr() orelse default);
}

/// Constant-time byte comparison. Written out rather than pulled from
/// `std.crypto.utils.timingSafeEql`, whose module path has moved between Zig
/// releases; this is six lines and cannot drift.
fn ctEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        // Touch both buffers so the timing does not depend on length alone,
        // then fail.
        //
        // 不能把 `a.len ^ b.len`（usize）`@intCast` 成 u8：长度差超过 255 时
        // 安全构建会 panic，ReleaseSmall 下静默截断 —— 畸形签名长度会变成
        // 一条“要么崩进程、要么不可信”的路径。长度差只需参与 OR 累积，用
        // usize 自己的宽度就够了，最后只取低位。
        var acc: usize = a.len ^ b.len;
        for (a) |c| acc |= c;
        for (b) |c| acc |= c;
        // 长度已不等 → 结果恒为 false。写成 `acc != 0 and a.len == b.len`
        // 而不是直接 `return false`，是为了让 `acc` 真正被使用，上面的两次
        // 循环不会被优化掉（否则时序就只取决于长度差了）。
        return acc != 0 and a.len == b.len;
    }
    var acc: u8 = 0;
    for (a, b) |x, y| acc |= x ^ y;
    return acc == 0;
}

// The SPA shell that used to live here as `INDEX_HTML` is now built at startup
// from the configured frontend source — see `frontend.zig`. What this file
// serves is `app.frontend.htmlFor(path)`.

// ---------------------------------------------------------------------------

const testing = std.testing;

test "mount resolution matches on segment boundaries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var mounts = try a.alloc(Mount, 2);
    mounts[0] = .{ .storage = .{ .driver = "Itvsh" }, .driver = undefined, .mount_path = "/nas", .label = "" };
    mounts[1] = .{ .storage = .{ .driver = "Local" }, .driver = undefined, .mount_path = "/", .label = "" };

    var app = App{
        .alloc = a,
        .mounts = mounts,
        .admin_hash = "",
        .admin_user = "admin",
        .admin_pwd_ts = 0,
        .jwt_secret = "s",
        .site_url = "",
        .cdn = "",
        .token_expires_in_hours = 48,
        // `resolve` touches nothing else; building a real frontend here would
        // need a config file and possibly the network.
        .frontend = undefined,
    };

    try testing.expectEqualStrings("/nas", app.resolve("/nas").?.mount.mount_path);
    try testing.expectEqualStrings("/", app.resolve("/nas").?.rel);
    try testing.expectEqualStrings("/a/b", app.resolve("/nas/a/b").?.rel);
    // "/nas2" must NOT match the "/nas" mount
    try testing.expectEqualStrings("/", app.resolve("/nas2").?.mount.mount_path);
    try testing.expectEqualStrings("/x", app.resolve("/x").?.rel);
}

test "mime mapping" {
    try testing.expectEqualStrings("video/mp4", mimeFor("a.MP4"));
    try testing.expectEqualStrings("image/jpeg", mimeFor("x.jpg"));
    try testing.expectEqualStrings("application/octet-stream", mimeFor("x.bin"));
    try testing.expectEqualStrings("application/octet-stream", mimeFor("noext"));
    // A module script with a non-JS content type is refused by the browser, so
    // these two carry the frontend.
    try testing.expectEqualStrings("text/javascript; charset=utf-8", mimeFor("assets/index-abc123.js"));
    try testing.expectEqualStrings("text/javascript; charset=utf-8", mimeFor("chunk.MJS"));
    try testing.expectEqualStrings("text/css; charset=utf-8", mimeFor("assets/index-abc.css"));
    try testing.expectEqualStrings("image/svg+xml", mimeFor("logo.svg"));
    try testing.expectEqualStrings("font/woff2", mimeFor("inter.woff2"));
    try testing.expectEqualStrings("application/wasm", mimeFor("mod.wasm"));
    // HLS segments, not TypeScript.
    try testing.expectEqualStrings("video/mp2t", mimeFor("seg000.ts"));
}

test "sha256 hex and base64url round trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const h = try sha256Hex(a, "abc");
    try testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", h);

    const enc = try b64Url(a, "hello\xff");
    const dec = try b64UrlDecode(a, enc);
    try testing.expectEqualStrings("hello\xff", dec);
}

test "time formatting matches RFC3339" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("0001-01-01T00:00:00Z", try fmtTime(a, 0));
    try testing.expectEqualStrings("1994-11-06T08:49:37Z", try fmtTime(a, 784111777));
}

test "mimeFor gives media types the browser audio/video elements accept" {
    // 回归：浏览器 `<audio>` 拒绝 `application/octet-stream` 的源（报
    // "no supported source"），所以常见音视频扩展名必须映射到 audio/*、
    // video/*，对齐 Go 在 Linux 上读 /etc/mime.types 的行为。
    try testing.expectEqualStrings("audio/mpeg", mimeFor("陶晶莹 - 太委屈.mp3"));
    try testing.expectEqualStrings("audio/x-ms-wma", mimeFor("萧亚轩 - 下一次恋爱.wma"));
    try testing.expectEqualStrings("audio/mp4", mimeFor("a.m4a"));
    try testing.expectEqualStrings("audio/flac", mimeFor("a.flac"));
    try testing.expectEqualStrings("video/mp4", mimeFor("a.mp4"));
    try testing.expectEqualStrings("video/x-msvideo", mimeFor("a.avi"));
    try testing.expectEqualStrings("video/x-ms-wmv", mimeFor("a.wmv"));
    try testing.expectEqualStrings("video/x-flv", mimeFor("a.flv"));
    // 大小写不敏感（浏览器发来的扩展名大小写不可控）。
    try testing.expectEqualStrings("audio/mpeg", mimeFor("A.MP3"));
    // 真正的未知类型才回落 octet-stream。
    try testing.expectEqualStrings("application/octet-stream", mimeFor("a.unknownext"));
}

test "raw_url from fs/get is directly playable: carries sign and a media content-type" {
    // 回归（2026-10-14 光猫实测两个坑）：
    // ① raw_url 不带 `?sign=` → 前端播放器直接用它，sign_all 部署下必 401；
    //    Go 的 `GenerateDownProxyURL`（proxy.go:31-33）生成 /p 链接时是带 sign 的。
    // ② Content-Type 回落 octet-stream → 浏览器 `<audio>` 报 "no supported source"。
    // 这条测试把"fs/get 返回的 raw_url 无凭据即可取回且类型可播"整个链路钉死。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fe = try frontend_mod.initFromHtml(a, .{}, "");
    defer fe.deinit();
    var app = routingApp(a, fe);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io(), .{ .sub_path = "song one.mp3", .data = "0123456789abcdef" });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(root);

    var local_drv = @import("drivers/local.zig").Local{
        .alloc = a,
        .cfg = .{ .root_folder = root },
    };
    const mounts = try a.alloc(Mount, 1);
    mounts[0] = .{
        .storage = .{ .id = 1, .mount_path = "/local", .driver = "Local", .addition = "{}" },
        .driver = driver.asDriver(@import("drivers/local.zig").Local, &local_drv),
        .mount_path = "/local",
        .label = "Local",
    };
    app.publishMounts(mounts);

    // sign_all=true 的独立 config（与本文件其他 sign 测试同模式）。
    // ⚠️ `prev` 必须在 `config.load` **之前**取：load 自己就会把单例指到新对象，
    // 在 load 之后取 prev 等于把单例还原成已 deinit 的对象，后面的测试必 segfault。
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{root});
    defer testing.allocator.free(cfg_path);
    const prev = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev);
    tcfg.sign_all = true;
    tcfg.link_expiration = 0;

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) };

    var req = http.Request{
        .arena = a,
        .method = "POST",
        .path = "/api/fs/get",
        .target = "/api/fs/get",
        .headers = hdrs,
        .body = .{ .memory = "{\"path\":\"/local/song one.mp3\"}" },
    };
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(&app, &req, res);
    try testing.expectEqual(@as(u16, 200), res.status);
    const parsed = try json.parse(a, res.buf.slice());
    const data = parsed.getPath("data").?;
    const sign_field = data.getPath("sign").?.asStr().?;
    const raw_url = data.getPath("raw_url").?.asStr().?;

    // ① sign 字段非空且 raw_url 必须带上同一个 sign（前端不再自己拼）。
    try testing.expect(sign_field.len > 0);
    try testing.expect(std.mem.startsWith(u8, raw_url, "/p/local/song%20one.mp3?sign="));
    try testing.expectEqualStrings(sign_field, raw_url["/p/local/song%20one.mp3?sign=".len..]);

    // ② 无凭据 + Range 直接取 raw_url：必须放行且 Content-Type 可播。
    // 服务器收到请求后会把路径 percent-decode（http.zig 的 `url.decode`），
    // 签名也是对**解码后**的路径校验的 —— 所以这里 .path 必须是解码形态。
    const qmark = std.mem.indexOfScalar(u8, raw_url, '?').?;
    var play = http.Request{
        .arena = a,
        .method = "GET",
        .path = "/p/local/song one.mp3",
        .target = "/p/local/song%20one.mp3",
        .query = raw_url[qmark + 1 ..],
        .headers = try a.dupe(Header, &.{.{ .name = "Range", .value = "bytes=0-3" }}),
    };
    const play_res = try a.create(http.Response);
    play_res.* = http.Response.init(a);
    try handle(&app, &play, play_res);
    try testing.expectEqual(@as(u16, 206), play_res.status);
    var ctype: ?[]const u8 = null;
    for (play_res.headers.slice()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) ctype = h.value;
    }
    try testing.expectEqualStrings("audio/mpeg", ctype.?);
}

test "Range parser supports closed, open-ended and suffix forms" {
    const closed = parseRange("bytes=10-19", 100);
    try testing.expect(closed == .valid);
    try testing.expectEqual(@as(u64, 10), closed.valid.start);
    try testing.expectEqual(@as(u64, 19), closed.valid.end);

    const open_ended = parseRange("bytes=90-", 100);
    try testing.expect(open_ended == .valid);
    try testing.expectEqual(@as(u64, 99), open_ended.valid.end);

    const suffix = parseRange("bytes=-10", 100);
    try testing.expect(suffix == .valid);
    try testing.expectEqual(@as(u64, 90), suffix.valid.start);
    try testing.expectEqual(@as(u64, 99), suffix.valid.end);

    try testing.expect(parseRange("bytes=100-", 100) == .unsatisfiable);
    try testing.expect(parseRange("bytes=8-3", 100) == .unsatisfiable);
    try testing.expect(parseRange("bytes=x-y", 100) == .ignore);
    try testing.expect(parseRange("items=0-1", 100) == .ignore);
    try testing.expect(parseRange("bytes=0-1,4-5", 100) == .ignore);
}

test "upload progress callback keeps a percentage in 0..100" {
    var progress = PutProgress{};
    putProgressCb(@ptrCast(&progress), 42);
    try testing.expectEqual(@as(u64, 42), progress.pct);

    // 越界的值必须被丢掉 —— 维度错了（字节 vs 百分比）比没进度更糟。
    putProgressCb(@ptrCast(&progress), 1024);
    try testing.expectEqual(@as(u64, 42), progress.pct);
    putProgressCb(@ptrCast(&progress), 100);
    try testing.expectEqual(@as(u64, 100), progress.pct);
}

// ---------------------------------------------------------------------------
// Routing
// ---------------------------------------------------------------------------
//
// These drive `handle` directly rather than through a socket. The property
// worth pinning down is ordering: the shell and the assets are unauthenticated
// (the login page lives inside the shell), while everything under /api/fs and
// the download prefixes is not. Getting that backwards produces a site that
// serves a login page nobody can load.

const ROUTING_SHELL =
    \\<title>Loading...</title>
    \\<script>window.OPENLIST_CONFIG = { cdn: undefined, base_path: undefined, main_color: undefined }</script>
    \\<!-- customize head -->
    \\<!-- customize body -->
;

fn routingApp(a: std.mem.Allocator, fe: frontend_mod.Frontend) App {
    return .{
        .alloc = a,
        .mounts = &.{},
        .admin_hash = "",
        .admin_user = "admin",
        .admin_pwd_ts = 0,
        .jwt_secret = "s",
        .site_url = "",
        .cdn = "",
        .token_expires_in_hours = 48,
        .frontend = fe,
    };
}

/// API 错误响应的断言助手。
///
/// Go 的 API 错误（`common.ErrorResp` → `ErrorWithDataResp` → `c.JSON(200, …)`）
/// **HTTP 状态恒为 200**，错误码只出现在 body 的 `code` 里（server/common/
/// common.go:74-88）。所以"401 / 403 / 400 / 500"这些都必须**同时**钉住两件
/// 事：HTTP 200 且 `code` 是期望值 —— 只看 HTTP 状态会把"用了真状态码"这种
/// 未对齐当成通过（2026-10-17 对账时本实现正是这样），只看 code 又放过
/// 状态码的偏离。
///
/// 只用于 JSON API；下载端点（/d/、/p/）与 WebDAV 用**真状态码**，不要用它
/// （它们走 `common.ErrorPage` / `ServeHTTP`，与 API 是两套体系）。
fn expectApiCode(res: *const http.Response, code: i64) !void {
    try testing.expectEqual(@as(u16, 200), res.status);
    const doc = json.parse(res.arena, res.buf.slice()) catch |e| {
        std.debug.print("\nexpectApiCode: response is not JSON ({s}): {s}\n", .{
            @errorName(e), res.buf.slice(),
        });
        return e;
    };
    const node = doc.getPath("code") orelse {
        std.debug.print("\nexpectApiCode: response has no `code`: {s}\n", .{res.buf.slice()});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(code, node.asInt() orelse {
        std.debug.print("\nexpectApiCode: `code` is not an int: {s}\n", .{res.buf.slice()});
        return error.TestUnexpectedResult;
    });
}

fn doRequest(app: *App, a: std.mem.Allocator, method: []const u8, path: []const u8) !*http.Response {
    var req = http.Request{ .arena = a, .method = method, .path = path, .target = path };
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(app, &req, res);
    return res;
}

/// Like `doRequest`, but lets a test set the query string and headers, so one
/// sweep can reach every registered endpoint.
fn doRequestWith(app: *App, a: std.mem.Allocator, method: []const u8, path: []const u8, query: []const u8, headers: []Header) !*http.Response {
    var req = http.Request{ .arena = a, .method = method, .path = path, .query = query, .target = path, .headers = headers };
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(app, &req, res);
    return res;
}

/// Like `doRequestWith`, but with a JSON body. `parseBodyJson` treats a missing
/// body as `{}`, so every endpoint that reads fields needs this to be exercised.
fn doRequestJson(app: *App, a: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8, headers: []Header) !*http.Response {
    var req = http.Request{ .arena = a, .method = method, .path = path, .target = path, .headers = headers, .body = .{ .memory = body } };
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(app, &req, res);
    return res;
}

/// query + JSON body 兼用版（doRequestWith 不带 body，doRequestJson 不带 query）。
fn doRequestJsonQuery(app: *App, a: std.mem.Allocator, method: []const u8, path: []const u8, query: []const u8, body: []const u8, headers: []Header) !*http.Response {
    var req = http.Request{ .arena = a, .method = method, .path = path, .query = query, .target = path, .headers = headers, .body = .{ .memory = body } };
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(app, &req, res);
    return res;
}

test "routing: the shell and the manifest need no token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    const home = try doRequest(&app, a, "GET", "/");
    try testing.expectEqual(@as(u16, 200), home.status);
    try testing.expect(std.mem.indexOf(u8, home.buf.slice(), "cdn: ''") != null);

    try testing.expectEqual(@as(u16, 200), (try doRequest(&app, a, "GET", "/manifest.json")).status);

    // GET and POST both reach the shell, so a deep link boots the router.
    try testing.expectEqual(@as(u16, 200), (try doRequest(&app, a, "GET", "/@manage/storage")).status);
    try testing.expectEqual(@as(u16, 200), (try doRequest(&app, a, "POST", "/@manage/storage")).status);
    // Anything else is 405, as upstream.
    try testing.expectEqual(@as(u16, 405), (try doRequest(&app, a, "PUT", "/x")).status);
    try testing.expectEqual(@as(u16, 405), (try doRequest(&app, a, "DELETE", "/x")).status);
}

test "routing: /@manage gets the admin shell, everything else the public one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{ .settings = .{ .customize_head = "<meta name=x>" } }, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    const public = (try doRequest(&app, a, "GET", "/")).buf.slice();
    const admin = (try doRequest(&app, a, "GET", "/@manage/storage")).buf.slice();

    try testing.expect(std.mem.indexOf(u8, public, "<meta name=x>") != null);
    try testing.expect(std.mem.indexOf(u8, admin, "<meta name=x>") == null);
    try testing.expect(std.mem.indexOf(u8, admin, "<!-- customize head -->") != null);
}

test "routing: /api/fs and the download prefixes still require a token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    for ([_][]const u8{ "/api/fs/list", "/api/fs/get", "/api/fs/dirs", "/api/fs/put" }) |p| {
        const res = try doRequest(&app, a, "POST", p);
        try expectApiCode(res, 401);
    }
    // ⚠ `/d/`、`/p/` **不走** token 鉴权（Go `server/middlewares/down.go`：
    // 它们是独立的一条链，只有 `sign_all` 打开时才验 `?sign=`）。本测试没有
    // 开 sign_all，所以匿名请求是**放行**的 —— 之后走到 `fs.GetStorage`
    // 失败 ⇒ `ErrorPage(err, 500)`（"storage not found"）。拿到 500 才说明
    // 与上游一致；401 反而是旧的"回落 checkAuth"行为（2026-10-17 修正）。
    for ([_][]const u8{ "/d/a/b", "/p/a/b" }) |p| {
        const res = try doRequest(&app, a, "GET", p);
        try testing.expectEqual(@as(u16, 500), res.status);
    }
}

test "routing: /dav now serves WebDAV (auth-gated, OPTIONS open)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    // Without a credential the server answers 401 rather than 501.
    const dav = try doRequest(&app, a, "PROPFIND", "/dav/");
    try testing.expectEqual(@as(u16, 401), dav.status);
    try testing.expectEqual(@as(u16, 401), (try doRequest(&app, a, "GET", "/dav")).status);

    // OPTIONS advertises WebDAV capability without auth.
    const opt = try doRequest(&app, a, "OPTIONS", "/dav");
    try testing.expectEqual(@as(u16, 200), opt.status);
    var dav_hdr: ?[]const u8 = null;
    for (opt.headers.slice()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "DAV")) dav_hdr = h.value;
    }
    // 上游 advertise 的是 **Class 2**（`DAV: 1, 2`）—— 因为它有 LOCK 系统。
    try testing.expectEqualStrings("1, 2", dav_hdr.?);

    // 未注册的 /api 路径 ⇒ Go NoRoute ⇒ 200 + 前端 shell（不是 JSON 404）。
    const typo = try doRequest(&app, a, "GET", "/api/nope");
    try testing.expectEqual(@as(u16, 200), typo.status);
    try testing.expect(std.mem.indexOf(u8, typo.buf.slice(), "OPENLIST_CONFIG") != null);
}

test "routing: assets with no dist_dir answer 404 rather than the shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    const res = try doRequest(&app, a, "GET", "/assets/a.js");
    try testing.expectEqual(@as(u16, 404), res.status);
    // Explicitly not HTML: a shell here would surface as a MIME error.
    try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "dist_dir") != null);
}

test "routing: a configured CDN redirects assets and keeps the query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{ .cdn = "https://c.example.com/4.2.6/dist" }, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    var req = http.Request{
        .arena = a,
        .method = "GET",
        .path = "/assets/index-abc123.js",
        .target = "/assets/index-abc123.js?v=9",
    };
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(&app, &req, res);

    try testing.expectEqual(@as(u16, 302), res.status);
    var found: ?[]const u8 = null;
    for (res.headers.slice()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Location")) found = h.value;
    }
    try testing.expectEqualStrings("https://c.example.com/4.2.6/dist/assets/index-abc123.js?v=9", found.?);
}

/// Test helper: mint a JWT with the same shape `issueToken` emits, so an
/// admin-route test can pass the auth gate. Lives at file scope because Zig does
/// not allow `fn` declarations inside a `test` block.
/// 测试用：签一个和 `issueToken` 同格式的标准三段 JWT。
fn mintTestToken(a: std.mem.Allocator, secret: []const u8, user: []const u8, pwd_ts: i64) ![]u8 {
    const exp: i64 = 4102444800; // 2100-01-01, comfortably in the future
    const h64 = try b64Url(a, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
    var payload = Buf.init(a);
    try payload.append("{\"username\":");
    try json.writeString(&payload, user);
    try payload.print(",\"pwd_ts\":{d},\"exp\":{d}}}", .{ pwd_ts, exp });
    const p64 = try b64Url(a, payload.slice());
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ h64, p64 });
    const sig = try hmacSha256(a, secret, signing_input);
    const s64 = try b64Url(a, &sig);
    return std.fmt.allocPrint(a, "{s}.{s}", .{ signing_input, s64 });
}

test "local download Range streams only the requested byte window" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(rt.io(), .{ .sub_path = "bytes.txt", .data = "0123456789" });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(root);

    var local_drv = @import("drivers/local.zig").Local{
        .alloc = a,
        .cfg = .{ .root_folder = root },
    };
    const mounts = try a.alloc(Mount, 1);
    mounts[0] = .{
        .storage = .{ .id = 1, .mount_path = "/local", .driver = "Local", .addition = "{}" },
        .driver = driver.asDriver(@import("drivers/local.zig").Local, &local_drv),
        .mount_path = "/local",
        .label = "Local",
    };
    app.mounts = mounts;

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const range_headers = try a.alloc(Header, 2);
    range_headers[0] = .{ .name = "Authorization", .value = auth };
    range_headers[1] = .{ .name = "Range", .value = "bytes=2-5" };
    var req = http.Request{ .arena = a, .method = "GET", .path = "/d/local/bytes.txt", .target = "/d/local/bytes.txt", .headers = range_headers };
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(&app, &req, res);
    try testing.expectEqual(@as(u16, 206), res.status);
    try testing.expectEqual(@as(u64, 4), res.stream.?.len.?);

    var buf: [8]u8 = undefined;
    const n = try res.stream.?.read(res.stream.?.ctx, &buf);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualStrings("2345", buf[0..n]);
    res.stream.?.cleanup.?(res.stream.?.ctx);

    range_headers[1].value = "bytes=10-";
    var bad_req = http.Request{ .arena = a, .method = "GET", .path = "/d/local/bytes.txt", .target = "/d/local/bytes.txt", .headers = range_headers };
    const bad_res = try a.create(http.Response);
    bad_res.* = http.Response.init(a);
    try handle(&app, &bad_req, bad_res);
    try testing.expectEqual(@as(u16, 416), bad_res.status);
    var unsatisfied: ?[]const u8 = null;
    for (bad_res.headers.slice()) |h| if (std.ascii.eqlIgnoreCase(h.name, "Content-Range")) {
        unsatisfied = h.value;
    };
    try testing.expectEqualStrings("bytes */10", unsatisfied.?);

    // 回归（2026-10-17 用户实测抓到）：全量下载必须带
    // `Content-Disposition: attachment` —— Go 的 `attachHeader` 与透明代理
    // 两条分支都设；缺失时浏览器会把 .txt 之类**在线打开**而不是下载。
    const auth_only = try a.alloc(Header, 1);
    auth_only[0] = .{ .name = "Authorization", .value = auth };
    var full_req = http.Request{ .arena = a, .method = "GET", .path = "/d/local/bytes.txt", .target = "/d/local/bytes.txt", .headers = auth_only };
    const full_res = try a.create(http.Response);
    full_res.* = http.Response.init(a);
    try handle(&app, &full_req, full_res);
    try testing.expectEqual(@as(u16, 200), full_res.status);
    var got_cd: ?[]const u8 = null;
    var got_ct: ?[]const u8 = null;
    for (full_res.headers.slice()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Disposition")) got_cd = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) got_ct = h.value;
    }
    try testing.expectEqualStrings(
        "attachment; filename=\"bytes.txt\"; filename*=utf-8''bytes.txt",
        got_cd.?,
    );
    try testing.expect(got_ct != null);
    // 收尾：`sendFile` 打开的句柄按响应自身的清理契约关闭（server 侧同样）。
    if (full_res.file) |f| f.close(rt.io());
}

test "contentDisposition matches Go GenerateContentDisposition byte-for-byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s1 = try contentDisposition(a, "proxy_5b5c220.txt");
    try testing.expectEqualStrings(
        "attachment; filename=\"proxy_5b5c220.txt\"; filename*=utf-8''proxy_5b5c220.txt",
        s1,
    );
    // 非 ASCII 与空格按 UTF-8 逐字节 %XX（大写）；空格是 %20 不是 '+'。
    const s2 = try contentDisposition(a, "测试 文件.mp4");
    try testing.expectEqualStrings(
        "attachment; filename=\"%E6%B5%8B%E8%AF%95%20%E6%96%87%E4%BB%B6.mp4\"; filename*=utf-8''%E6%B5%8B%E8%AF%95%20%E6%96%87%E4%BB%B6.mp4",
        s2,
    );
}

test "extInList: Go semantics (lowercased ext, exact entries, no trim)" {
    try testing.expect(extInList("m3u8,url", "直播.m3u8"));
    try testing.expect(extInList("m3u8,url", "link.URL")); // Ext 小写化后匹配
    try testing.expect(!extInList("m3u8,url", "note.txt"));
    try testing.expect(!extInList("m3u8,url", "noext"));
    try testing.expect(!extInList("m3u8,url", "trailing."));
    try testing.expect(!extInList("m3u8, txt", "a.txt")); // 条目原样、不 trim
    // 条目大小写折叠：Go 的 SliceContains 是精确比较 —— "TXT" 条目匹配不了。
    try testing.expect(!extInList("TXT", "a.txt"));
}

test "canProxy: /p/ 准入门槛（含 text_types 分支），ShouldProxy 不含 text" {
    // Go `down.go` canProxy vs ShouldProxy 的既有差异：
    //  - canProxy（/p/）含 text_types；ShouldProxy（/d/）不含。
    // 扩展名判定读取全局配置；这里显式置空，走"未加载→默认列表"路径，
    // 结果确定（m3u8,url + 32 项 text_types）。
    const prev = config.getOpt();
    config.setForTest(null);
    defer config.setForTest(prev);

    try testing.expect(canProxy(true, false, "", "note.txt")); // MustProxy
    try testing.expect(canProxy(false, true, "", "note.txt")); // WebProxy
    try testing.expect(canProxy(false, false, "", "playlist.m3u8")); // proxy_types 默认
    try testing.expect(canProxy(false, false, "", "readme.txt")); // text_types 默认
    try testing.expect(canProxy(false, false, "", "sub.srt")); // text_types 默认
    // WebdavProxyURL：策略是 use_proxy_url 时，连 .exe 都可代理
    try testing.expect(canProxy(false, false, "use_proxy_url", "setup.exe"));
    // 但 302_redirect / native 不行（上游是精确等于比较）
    try testing.expect(!canProxy(false, false, "302_redirect", "setup.exe"));
    try testing.expect(!canProxy(false, false, "native_proxy", "setup.exe"));
    try testing.expect(!canProxy(false, false, "", "setup.exe")); // 都不命中
    try testing.expect(!canProxy(false, false, "", "noext"));
}

test "normalizeWebdavPolicy: native_proxy 存成空串（上游按精确等于判定）" {
    try testing.expectEqualStrings("", normalizeWebdavPolicy("native_proxy"));
    try testing.expectEqualStrings("", normalizeWebdavPolicy(""));
    try testing.expectEqualStrings("", normalizeWebdavPolicy("bogus"));
    try testing.expectEqualStrings("use_proxy_url", normalizeWebdavPolicy("use_proxy_url"));
    try testing.expectEqualStrings("302_redirect", normalizeWebdavPolicy("302_redirect"));
}

test "routing: authed admin endpoints return data, unauthed is 401" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    // `/api/admin/storage` 现在从**配置表**渲染（对齐 Go 从 DB 渲染），测试里
    // 没有 load 过 config 的话 `config.get()` 会 panic。按 sign 测试的模式 load
    // 一份临时配置再注入，`prev` 必须在 load **之前**取（load 自己会改单例）。
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg_dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(cfg_dir);
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{cfg_dir});
    defer testing.allocator.free(cfg_path);
    const prev_cfg = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev_cfg);

    // Mint a token with the same secret/shape `issueToken` uses, so the auth
    // gate in `handleAuthed` accepts it.
    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    // /api/me
    {
        var req = http.Request{ .arena = a, .method = "GET", .path = "/api/me", .target = "/api/me", .headers = hdrs };
        const res = try a.create(http.Response);
        res.* = http.Response.init(a);
        try handle(&app, &req, res);
        try testing.expectEqual(@as(u16, 200), res.status);
        try testing.expect(std.mem.indexOf(u8, res.buf.slice(), app.admin_user) != null);
    }

    // /api/admin/storage — 空配置 ⇒ total 0, content []
    {
        var req = http.Request{ .arena = a, .method = "GET", .path = "/api/admin/storage", .target = "/api/admin/storage", .headers = hdrs };
        const res = try a.create(http.Response);
        res.* = http.Response.init(a);
        try handle(&app, &req, res);
        try testing.expectEqual(@as(u16, 200), res.status);
        const body = res.buf.slice();
        try testing.expect(std.mem.indexOf(u8, body, "\"total\":0") != null);
        try testing.expect(std.mem.indexOf(u8, body, "\"content\":[]") != null);
    }

    // /api/admin/driver/list — the compiled-in drivers
    {
        var req = http.Request{ .arena = a, .method = "GET", .path = "/api/admin/driver/list", .target = "/api/admin/driver/list", .headers = hdrs };
        const res = try a.create(http.Response);
        res.* = http.Response.init(a);
        try handle(&app, &req, res);
        try testing.expectEqual(@as(u16, 200), res.status);
        const body = res.buf.slice();
        try testing.expect(std.mem.indexOf(u8, body, "Local") != null);
        // 驱动名必须与 Go `driver.Config.Name` 一致 —— itvsh 的 Go 名是
        // 「上海电信智家硬盘」（drivers/itvsh/meta.go:34），配置里存的就是它。
        // 仅在 itvsh 被 `-Ddrivers=` 选入时才要求出现（裁剪构建本来就不含它）。
        if (driver.find("上海电信智家硬盘") != null) {
            try testing.expect(std.mem.indexOf(u8, body, "上海电信智家硬盘") != null);
        }
    }

    // Task centre knows these categories but accurately reports no active or
    // completed background jobs in this no-queue build.
    {
        var req = http.Request{ .arena = a, .method = "GET", .path = "/api/task/upload/undone", .target = "/api/task/upload/undone", .headers = hdrs };
        const res = try a.create(http.Response);
        res.* = http.Response.init(a);
        try handle(&app, &req, res);
        try testing.expectEqual(@as(u16, 200), res.status);
        try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "\"data\":[]") != null);
    }

    // No token => 401
    {
        var req = http.Request{ .arena = a, .method = "GET", .path = "/api/me", .target = "/api/me" };
        const res = try a.create(http.Response);
        res.* = http.Response.init(a);
        try handle(&app, &req, res);
        try expectApiCode(res, 401);
    }
}

test "public settings body is strict JSON (regression: stray closing brace)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    var req = http.Request{ .arena = a, .method = "GET", .path = "/api/public/settings", .target = "/api/public/settings" };
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(&app, &req, res);
    try testing.expectEqual(@as(u16, 200), res.status);

    // 回归：收尾的 `append("}}}")` 是笔误。`append` 写**原始字节**，不做 `print`
    // 那样的 `{{`/`}}` 转义，于是 body 末尾多出一个 `}`（337 字节里只有前 336 是
    // 合法 JSON）。后果不是 500，而是前端静默出错：axios 的 `JSON.parse` 抛错后
    // 被 `silentJSONParsing` 降级成字符串，`e.code === 200` 永远为假，首页直接
    // 显示「获取设置失败： Undefined」。`json.parse` 对尾随内容报 `InvalidSyntax`，
    // 正好把这个 bug 钉死。
    const body = res.buf.slice();
    const parsed = try json.parse(a, body);
    try testing.expectEqual(@as(i64, 200), parsed.getPath("code").?.asInt().?);
    switch (parsed.getPath("data").?.*) {
        .object => {},
        else => return error.TestUnexpectedResult,
    }
}

test "every JSON endpoint emits strict, parseable JSON" {
    // 系统性补丁：本工程的 API 响应是**手拼字符串**（不像 Go 版走 struct/map
    // 序列化），一处括号写错就产出非法 JSON；而 axios 会把 `JSON.parse` 的失败
    // 静默降级成字符串，前端于是只报一句毫无线索的「获取设置失败： Undefined」。
    // 这里把**所有**已注册的 JSON 端点跑一遍，逐个用严格解析器校验（`json.parse`
    // 对尾随内容报 InvalidSyntax，正是它抓出了 public/settings 多出的那个 '}'）。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    // /api/admin/setting* 会读 config 单例；测试里没 load 过就直接 panic。
    // 按 sign 测试的做法 load 一份临时配置再注入，退出时还原进入前的单例。
    // 注意 `config.load` **自己就会**把单例指到新对象，所以必须在 load 之前
    // 取 `prev`，否则还原的是新对象、`deinit` 之后单例悬空，后面读 config 的
    // 测试会 segfault。
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg_dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(cfg_dir);
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{cfg_dir});
    defer testing.allocator.free(cfg_path);
    const prev_cfg = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev_cfg);

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    // 1) 公共 GET
    for ([_][]const u8{
        "/api/public/settings",
        "/api/public/archive_extensions",
    }) |p| {
        const res = try doRequest(&app, a, "GET", p);
        try testing.expectEqual(@as(u16, 200), res.status);
        _ = try json.parse(a, res.buf.slice());
    }
    {
        const res = try doRequestWith(&app, a, "GET", "/api/public/offline_download_tools", "path=%2F", &.{});
        try testing.expectEqual(@as(u16, 200), res.status);
        _ = try json.parse(a, res.buf.slice());
    }

    // 2) 认证 GET
    for ([_][]const u8{
        "/api/me",
        "/api/admin/storage",
        "/api/admin/storage/list",
        "/api/admin/driver/names",
        "/api/admin/driver/list",
        "/api/admin/setting/list",
        "/api/admin/setting/default",
        "/api/task/upload/undone",
        "/api/task/upload/done",
        "/api/task/copy/undone",
        "/api/task/copy/done",
        "/api/task/move/undone",
        "/api/task/offline_download/undone",
    }) |p| {
        const res = try doRequestWith(&app, a, "GET", p, "", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        _ = try json.parse(a, res.buf.slice());
    }

    // 2b) 新增的管理面端点：driver/info（200）与 storage/get（无此 id ⇒ 404，
    // 但错误包也必须是合法 JSON）。
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/driver/info", "driver=Local", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        _ = try json.parse(a, res.buf.slice());
    }
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/driver/info", "driver=NoSuchDriver", hdrs);
        try expectApiCode(res, 404);
        _ = try json.parse(a, res.buf.slice());
    }
    // ⚠ query 参数必须**解码**（Go `c.Query` 同款）：`115 Cloud` 经前端编码是
    // `115%20Cloud`，不解码就 404 —— 管理页「添加存储」对它直接废掉。
    // （真机回归 2026-10-17 由 driver_matrix.py 抓出。）
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/driver/info", "driver=115%20Cloud", hdrs);
        try expectApiCode(res, 200);
        // 名字里带空格的驱动要能解回来（响应里至少要出现这个名字本身）
        try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "115 Cloud") != null);
    }
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/storage/get", "id=99", hdrs);
        try expectApiCode(res, 404);
        _ = try json.parse(a, res.buf.slice());
    }

    // 3) setting/get 与 setting/list 都走 query 参数。`group=0` 在 Go
    // `handles.ListSettings` 中是有效筛选值；本构建当前没有 group 0 的配置项，
    // 因而应得到合法的空数组，而不是 404 或忽略筛选。
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/setting/get", "key=site_title", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        _ = try json.parse(a, res.buf.slice());
    }
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/setting/list", "group=0", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        const parsed = try json.parse(a, res.buf.slice());
        const items = parsed.getPath("data").?.asArray().?;
        try testing.expectEqual(@as(usize, 0), items.len);
    }

    // 4) 认证 POST（空 body ⇒ 空对象 ⇒ 无挂载 ⇒ JSON 错误包，也必须是合法 JSON）
    for ([_][]const u8{
        "/api/fs/list",
        "/api/fs/get",
        "/api/fs/dirs",
        "/api/fs/mkdir",
        "/api/fs/rename",
        "/api/fs/move",
        "/api/fs/copy",
        "/api/fs/remove",
        "/api/fs/put",
        "/api/fs/archive/list",
        "/api/admin/storage/create",
        "/api/admin/storage/update",
    }) |p| {
        const res = try doRequestWith(&app, a, "POST", p, "", hdrs);
        _ = try json.parse(a, res.buf.slice());
    }

    // 5) 未注册的 /api/* ⇒ Go NoRoute ⇒ 200 + 前端 shell（**不是** JSON 404）。
    //    这是 2026-10-17 读 `server/static/static.go:213-227` 定下来的：上游
    //    的 NoRoute 挂在路由表外，`/api/nope` 与 `/随便什么` 一视同仁。
    {
        const res = try doRequest(&app, a, "GET", "/api/nope");
        try testing.expectEqual(@as(u16, 200), res.status);
        try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "OPENLIST_CONFIG") != null);
    }
    // 非 GET/POST 的未注册路径 ⇒ 405（同一 handler 的第一个分支）。
    {
        const res = try doRequest(&app, a, "PUT", "/api/nope");
        try testing.expectEqual(@as(u16, 405), res.status);
    }
}

test "public settings carries the keys the frontend actually reads" {
    // 回归：曾经只返回 10 个自造字段（initial_done / api / cdn / token_expires_in …），
    // 前端真正读的键一个都没有 —— 表现就是首页 logo 拿到空串、`<img src="">`。
    // 这里把前端代码实际引用的键逐个钉住（清单来自 4.2.6 的 dist：把每个
    // `(\`key\`)` 取值点扫出来），并强制值必须是字符串。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    const res = try doRequest(&app, a, "GET", "/api/public/settings");
    try testing.expectEqual(@as(u16, 200), res.status);
    const parsed = try json.parse(a, res.buf.slice());
    const data = parsed.getPath("data").?.object;

    const required = [_][]const u8{
        "version",              "site_title",             "announcement",
        "pagination_type",      "logo",                   "favicon",
        "main_color",           "home_icon",              "share_icon",
        "home_container",       "settings_layout",        "show_disk_usage_in_plain_text",
        "audio_cover",          "audio_autoplay",         "video_autoplay",
        "preview_download_by_default", "preview_archives_by_default",
        "share_preview_download_by_default", "share_preview_archives_by_default",
        "readme_autorender",    "filter_readme_scripts",  "hide_files",
        "package_download",     "share_preview",          "share_archive_preview",
        "share_summary_content", "search_index",          "sso_login_enabled",
        "sso_login_platform",   "sso_compatibility_mode", "sso_postmessage_origin",
        "ldap_login_enabled",
        "ldap_login_tips",      "multipart_enabled",
    };
    for (required) |k| {
        const v = data.get(k) orelse return error.MissingPublicSettingKey;
        switch (v.*) {
            .string => {},
            // Go 侧是 `map[string]string`；前端按字符串判布尔/数字
            // （`t === 'true'`、`Number(t)`），给原生 bool/int 会静默判错。
            else => return error.PublicSettingValueMustBeString,
        }
    }

    // logo 尤其不能为空 —— 空串渲染出来就是 `<img src="">`。
    try testing.expect(data.get("logo").?.asStr().?.len > 0);
    try testing.expect(data.get("site_title").?.asStr().?.len > 0);
}

test "fs list carries the envelope fields the frontend reads" {
    // 回归：`readme`/`header`/`write`/`write_content_bypass`/`provider` 少一个，
    // 前端 `setWrite(undefined)` 就会把目录判成只读 —— 上传/新建按钮整片消失。
    // （测试环境无挂载，"/" 走 `listRoot`，信封字段与挂载目录完全一致。）
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    const res = try doRequestWith(&app, a, "POST", "/api/fs/list", "", hdrs);
    try testing.expectEqual(@as(u16, 200), res.status);
    const parsed = try json.parse(a, res.buf.slice());
    const data = parsed.getPath("data").?.object;
    for ([_][]const u8{
        "content", "total", "readme", "header",
        "write",   "write_content_bypass", "provider",
    }) |k| {
        if (data.get(k) == null) return error.MissingFsListField;
    }
    // 单管理员构建 ⇒ 目录可写，前端据此显示上传/新建。
    try testing.expect(data.get("write").?.asBool() != null and data.get("write").?.asBool().?);
}

test "fs move/copy/remove/rename reject relative names like Go checkRelativePath" {
    // 回归：上游 ea10624f 给 `FsMove`/`FsCopy`/`FsRemove` 补了 `checkRelativePath`
    // （`fsmanage.go:116/223/384`），`FsRename`(:306) 原本就有。Zig 四个端点
    // 一个都没有，而 `urlmod.joinPath` 是纯字符串拼接、**不归一化 `..`** ⇒
    // `names:["../x"]` 会拼出 `src_dir/../x` 交给驱动，`["a/b"]` 直接操作子
    // 路径 —— 上游两者都是 403。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    // 纯逻辑：等价于 Go 的 `strings.ContainsAny(path, "/\\") || path == "" ||
    // path == "." || path == ".."`。
    for ([_][]const u8{ "", ".", "..", "a/b", "a\\b" }) |n| {
        try testing.expect(!isPlainFileName(n));
    }
    for ([_][]const u8{ "a.b", "..hidden", "normal name.txt", "电影.mp4" }) |n| {
        try testing.expect(isPlainFileName(n));
    }

    // 端点层：必须在**碰到驱动之前**就 403（测试环境没有挂载，没有这层校验时
    // 这些请求会一路走到 `app.resolve` 返回 404 —— 语义完全不同）。
    for ([_][]const u8{ "../x", "a/b", "..", ".", "" }) |n| {
        const mv = try std.fmt.allocPrint(a, "{{\"src_dir\":\"/\",\"dst_dir\":\"/d\",\"names\":[\"{s}\"]}}", .{n});
        const r1 = try doRequestJson(&app, a, "POST", "/api/fs/move", mv, hdrs);
        try expectApiCode(r1, 403);

        const cp = try std.fmt.allocPrint(a, "{{\"src_dir\":\"/\",\"dst_dir\":\"/d\",\"names\":[\"{s}\"]}}", .{n});
        const r2 = try doRequestJson(&app, a, "POST", "/api/fs/copy", cp, hdrs);
        try expectApiCode(r2, 403);

        const rm = try std.fmt.allocPrint(a, "{{\"dir\":\"/\",\"names\":[\"{s}\"]}}", .{n});
        const r3 = try doRequestJson(&app, a, "POST", "/api/fs/remove", rm, hdrs);
        try expectApiCode(r3, 403);

        const rn = try std.fmt.allocPrint(a, "{{\"path\":\"/x\",\"name\":\"{s}\"}}", .{n});
        const r4 = try doRequestJson(&app, a, "POST", "/api/fs/rename", rn, hdrs);
        try expectApiCode(r4, 403);
    }

    // 空数组是显式 400（Go 的 "Empty file names"），不是"什么都不做然后 200"。
    for ([_][]const u8{ "/api/fs/move", "/api/fs/copy" }) |ep| {
        const r = try doRequestJson(&app, a, "POST", ep, "{\"src_dir\":\"/\",\"dst_dir\":\"/d\",\"names\":[]}", hdrs);
        try expectApiCode(r, 400);
    }
    const rr = try doRequestJson(&app, a, "POST", "/api/fs/remove", "{\"dir\":\"/\",\"names\":[]}", hdrs);
    try expectApiCode(rr, 400);
}

test "stemOf mirrors Go filterRelated's TrimSuffix(name, Ext(name))" {
    // `movie.mp4` → `movie`，用来前缀匹配 `movie.srt`（同目录字幕/外挂音轨）。
    try testing.expectEqualStrings("movie", stemOf("movie.mp4"));
    try testing.expectEqualStrings("movie", stemOf("movie"));
    // 有多个点时取最后一个（Go `path.Ext` 语义）
    try testing.expectEqualStrings("ep.01", stemOf("ep.01.mkv"));
}

test "init_status drives the first-run wizard and init/setup creates the admin" {
    // 回归：`/api/public/init_status` 缺失时前端**永远**不跳 `/@init` ——
    // App.tsx 里这个请求的失败回调被注释掉了（静默吞错），`initialized` 保持
    // 默认 true，用户看不到任何注册入口，只能拿已有账号登录。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    // init/setup 会写 config 单例；`prev` 必须在 load **之前**取
    // （`config.load` 自己就会把单例指过去）。
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg_dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(cfg_dir);
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{cfg_dir});
    defer testing.allocator.free(cfg_path);
    const prev_cfg = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev_cfg);

    // 1) 未初始化（admin_hash 为空）⇒ initialized:false
    {
        const res = try doRequest(&app, a, "GET", "/api/public/init_status");
        try testing.expectEqual(@as(u16, 200), res.status);
        const parsed = try json.parse(a, res.buf.slice());
        try testing.expectEqual(false, parsed.getPath("data.initialized").?.asBool().?);
    }

    // 2) init/setup 建管理员（Go 侧密码下限是 4）
    {
        var req = http.Request{
            .arena = a,
            .method = "POST",
            .path = "/api/public/init/setup",
            .target = "/api/public/init/setup",
            .body = .{ .memory = "{\"username\":\"admin\",\"password\":\"test-pw-1234\",\"site_title\":\"Zig Site\"}" },
        };
        const res = try a.create(http.Response);
        res.* = http.Response.init(a);
        try handle(&app, &req, res);
        try testing.expectEqual(@as(u16, 200), res.status);
        try testing.expect(app.admin_hash.len > 0);
        try testing.expectEqualStrings("admin", app.admin_user);
    }

    // 3) 已初始化后再调 ⇒ 400（Go：`system has already been initialized`）
    {
        var req = http.Request{
            .arena = a,
            .method = "POST",
            .path = "/api/public/init/setup",
            .target = "/api/public/init/setup",
            .body = .{ .memory = "{\"username\":\"x\",\"password\":\"1234\"}" },
        };
        const res = try a.create(http.Response);
        res.* = http.Response.init(a);
        try handle(&app, &req, res);
        try expectApiCode(res, 400);
    }

    // 4) 现在 init_status 应报 initialized:true
    {
        const res = try doRequest(&app, a, "GET", "/api/public/init_status");
        const parsed = try json.parse(a, res.buf.slice());
        try testing.expectEqual(true, parsed.getPath("data.initialized").?.asBool().?);
    }
}

test "login/hash accepts the static hash the frontend actually sends" {
    // 回归：前端登录页 POST 的是 `/api/auth/login/hash`（server/router.go:75），
    // body 里的 password 是 `StaticHash(明文)`。这个端点曾经缺失 ⇒ 前端恒登不上，
    // 而 curl 直接打 `/auth/login` 却是通的 —— 「curl 通过」不等于「前端能登录」。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    // 造一个与 Go 同形的管理员：salt + `TwoHashPwd`。
    const salt = "abcdefghijklmnop";
    app.admin_user = "admin";
    app.admin_salt = salt;
    app.admin_hash = try twoHashPwd(a, "hunter2", salt);

    const post = struct {
        fn call(app_: *App, a_: std.mem.Allocator, path: []const u8, body: []const u8) !*http.Response {
            var req = http.Request{ .arena = a_, .method = "POST", .path = path, .target = path, .body = .{ .memory = body } };
            const res = try a_.create(http.Response);
            res.* = http.Response.init(a_);
            try handle(app_, &req, res);
            return res;
        }
    }.call;

    // 1) 前端路径：发 StaticHash，必须换到 token
    const static = try staticHash(a, "hunter2");
    const body_hash = try std.fmt.allocPrint(a, "{{\"username\":\"admin\",\"password\":\"{s}\",\"otp_code\":\"\"}}", .{static});
    const res_hash = try post(&app, a, "/api/auth/login/hash", body_hash);
    try testing.expectEqual(@as(u16, 200), res_hash.status);
    try testing.expect((try json.parse(a, res_hash.buf.slice())).getPath("data.token") != null);

    // 2) 明文接口（Go 的 `ValidatePwd` 会先做一次 StaticHash）
    const res_plain = try post(&app, a, "/api/auth/login", "{\"username\":\"admin\",\"password\":\"hunter2\"}");
    try testing.expectEqual(@as(u16, 200), res_plain.status);

    // 3) 错口令 / 错用户名必须 401。Go `loginHash` 统一走
    //    `common.ErrorStrResp(c, model.InvalidUsernameOrPassword, 401)`
    //    （server/handles/auth.go:58,64）—— HTTP 恒 200，错误码在 body 里。
    //    M11：以前这里是 400「wrong username or password」，与 Go 不符。
    const bad_pw = try post(&app, a, "/api/auth/login", "{\"username\":\"admin\",\"password\":\"nope\"}");
    try expectApiCode(bad_pw, 401);
    const bad_user = try post(&app, a, "/api/auth/login/hash", "{\"username\":\"root\",\"password\":\"x\"}");
    try expectApiCode(bad_user, 401);

    // 4) M11 回归：累计 5 次失败后锁 5 分钟，期间**连正确口令也回 429**
    //    （Go `model.DefaultMaxAuthRetries` + `TooManyAttempts`）。
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const more = try post(&app, a, "/api/auth/login", "{\"username\":\"admin\",\"password\":\"nope\"}");
        try expectApiCode(more, 401);
    }
    const locked = try post(&app, a, "/api/auth/login", "{\"username\":\"admin\",\"password\":\"hunter2\"}");
    try expectApiCode(locked, 429);
    login_throttle.recordSuccess(); // 复位，避免污染同进程其他用例
}

test "fs/get / returns the virtual root like Go" {
    // 回归：Go `internal/fs/get.go:25-30` 对 `/` 返回虚拟根对象而不是报错。
    // 前端 Layout 进首页第一个请求就是 `fs/get /`；此前我们回 404
    // "storage not found"，首页直接显示 404（管理后台走 storage/list 所以正常）。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    // `doRequestWith` 的第 5 参是 **query** 不是 body，所以这里直接构造 Request
    // （带 JSON body）—— 之前把 body 塞进了 query，fs/get 收到空 body 直接 return，
    // 响应体为空，测试在 getPath 处 null panic。
    var req = http.Request{
        .arena = a,
        .method = "POST",
        .path = "/api/fs/get",
        .target = "/api/fs/get",
        .headers = hdrs,
        .body = .{ .memory = "{\"path\":\"/\"}" },
    };
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(&app, &req, res);
    try testing.expectEqual(@as(u16, 200), res.status);
    const parsed = try json.parse(a, res.buf.slice());
    try testing.expectEqualStrings("root", parsed.getPath("data.name").?.asStr().?);
    try testing.expectEqual(true, parsed.getPath("data.is_dir").?.asBool().?);
    try testing.expectEqualStrings("", parsed.getPath("data.provider").?.asStr().?);
}

test "ctEqual rejects mismatched lengths without narrowing the difference" {
    // A02 回归：旧实现在长度不等时执行 `@intCast(a.len ^ b.len)`，把一个
    // usize 窄化成 u8。长度差超过 255（这里 600^32 = 632）时安全构建 panic、
    // small 构建静默截断 —— 畸形签名长度会变成“要么崩进程、要么不可信”的
    // 路径。现在长度差用 usize 自己的宽度参与累积，只返回 false。
    const long = try testing.allocator.alloc(u8, 600);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    const expected = try testing.allocator.alloc(u8, 32);
    defer testing.allocator.free(expected);
    @memset(expected, 'a');

    // 600 vs 32：差 632，旧代码会 panic/截断
    try testing.expect(!ctEqual(long, expected));
    // 反过来也一样
    try testing.expect(!ctEqual(expected, long));
    // 长度相同但内容不同仍然 false
    var other = try testing.allocator.dupe(u8, expected);
    defer testing.allocator.free(other);
    other[0] ^= 0xff;
    try testing.expect(!ctEqual(other, expected));
    // 长度内容都相同才是 true
    try testing.expect(ctEqual(expected, expected));
}

/// 测试辅助：带 Authorization 头调一次 checkAuth。
fn authWith(a: std.mem.Allocator, app: *App, token: []const u8) !bool {
    const hdrs = try a.dupe(Header, &.{.{
        .name = "Authorization",
        .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}),
    }});
    var req = http.Request{
        .arena = a,
        .method = "GET",
        .path = "/api/me",
        .target = "/api/me",
        .headers = hdrs,
    };
    return checkAuth(app, &req);
}

test "tokens are standard three-part JWTs bound to the password version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app = App{
        .alloc = a,
        .mounts = &.{},
        .admin_hash = "x",
        .admin_user = "admin",
        .admin_pwd_ts = 1000,
        .jwt_secret = "s3cret",
        .site_url = "",
        .cdn = "",
        .token_expires_in_hours = 1,
        .frontend = undefined,
    };

    const token = try mintTestToken(a, app.jwt_secret, "admin", 1000);

    // A04：必须是**三段**标准 JWT，头部是 {"alg":"HS256","typ":"JWT"}。
    // 以前是私有两段 `payload.signature`，标准 JWT 解析器打不开。
    var parts = std.mem.splitScalar(u8, token, '.');
    const h64 = parts.next().?;
    const p64 = parts.next().?;
    const s64 = parts.next().?;
    try testing.expect(parts.next() == null);

    const hdr = try b64UrlDecode(a, h64);
    try testing.expectEqualStrings("{\"alg\":\"HS256\",\"typ\":\"JWT\"}", hdr);

    // 签名必须覆盖 "header.payload"（JWT 的规定），而不是只覆盖 payload。
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ h64, p64 });
    const expect_sig = try hmacSha256(a, app.jwt_secret, signing_input);
    const got_sig = try b64UrlDecode(a, s64);
    try testing.expectEqualSlices(u8, &expect_sig, got_sig);

    // 有效令牌通过。
    try testing.expect(try authWith(a, &app, token));

    // A03：口令版本推进（= 改密）后，**已签发**的旧令牌立刻失效。
    app.admin_pwd_ts = 2000;
    try testing.expect(!(try authWith(a, &app, token)));
}

test "tokens are rejected for a different user or a tampered signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app = App{
        .alloc = a,
        .mounts = &.{},
        .admin_hash = "x",
        .admin_user = "admin",
        .admin_pwd_ts = 1000,
        .jwt_secret = "s3cret",
        .site_url = "",
        .cdn = "",
        .token_expires_in_hours = 1,
        .frontend = undefined,
    };

    // 换用户名 → 拒
    try testing.expect(!(try authWith(a, &app, try mintTestToken(a, app.jwt_secret, "root", 1000))));
    // 换口令版本 → 拒
    try testing.expect(!(try authWith(a, &app, try mintTestToken(a, app.jwt_secret, "admin", 999))));

    // 篡改签名（用别的密钥签）→ 拒
    try testing.expect(!(try authWith(a, &app, try mintTestToken(a, "wrong-secret", "admin", 1000))));

    // 结构不对（只有两段）→ 拒
    try testing.expect(!(try authWith(a, &app, "aaaa.bbbb")));
    // 多一段 → 拒
    try testing.expect(!(try authWith(a, &app, "aaaa.bbbb.cccc.dddd")));
}

// ---------------------------------------------------------------------------
// 下载签名（对齐 Go pkg/sign/hmac.go）
// ---------------------------------------------------------------------------

test "sign: Sign matches the Go HMAC format byte for byte" {
    // 期望值由 Python 的 `hmac`+`base64.urlsafe_b64encode` 独立算出
    // （算法逐字抄自 Go pkg/sign/hmac.go），不是拿本实现的输出当基准。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const secret = "test-jwt-secret-1234567890";

    try testing.expectEqualStrings(
        "m2Ujh34JCH5bNVHL36HjwKmbmg1HKeQZ8fEViuD4xlA=:0",
        try signValue(a, secret, "/local/a.txt", 0),
    );
    try testing.expectEqualStrings(
        "3o7DsCxwWhzlnSDZRENsu9rfNU38tdVFhu84CULfHPc=:0",
        try signValue(a, secret, "/itvsh/dir/f.bin", 0),
    );
    // 未来与过去的时间戳都只是字符串的一部分，签名本身都能算出来。
    const future = try signValue(a, secret, "/local/a.txt", 4102444800);
    try testing.expect(std.mem.endsWith(u8, future, ":4102444800"));
}

test "sign: verifySign accepts a valid signature and rejects tampering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = routingApp(a, try frontend_mod.initFromHtml(a, .{}, ""));

    const good = try signValue(a, app.jwt_secret, "/local/a.txt", 0);
    try verifySign(&app, a, "/local/a.txt", good);

    // 路径被改一个字节 → ErrSignInvalid。
    try testing.expectError(SignError.SignInvalid, verifySign(&app, a, "/local/b.txt", good));
    // secret 不对 → 同样 ErrSignInvalid。
    try testing.expectError(SignError.SignInvalid, verifySign(&app, a, "/local/a.txt", try signValue(a, "other", "/local/a.txt", 0)));
}

test "sign: verifySign reports Go's four expiry errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var app = routingApp(a, try frontend_mod.initFromHtml(a, .{}, ""));

    // ⚠ 没有 ':' 时 Go 的 `LastIndex` 是 -1，`sign[0:]` 拿到的**是整个串**，
    // 于是"没有冒号"和"冒号后面不是数字"走到同一个分支 —— 都是 ExpireInvalid
    // 而不是 ExpireMissing。（早期这里按直觉判成 ExpireMissing，与上游不符。）
    try testing.expectError(SignError.ExpireInvalid, verifySign(&app, a, "/x", "no-colon-here"));
    // exp 不是数字 → ErrExpireInvalid。
    try testing.expectError(SignError.ExpireInvalid, verifySign(&app, a, "/x", "abc:notanumber"));
    // ':' 在末尾 → exp 串为空 → ErrExpireMissing。
    try testing.expectError(SignError.ExpireMissing, verifySign(&app, a, "/x", "abc:"));
    // 空 sign → 同样 ExpireMissing。
    try testing.expectError(SignError.ExpireMissing, verifySign(&app, a, "/x", ""));
    // exp 已过期（非 0）→ ErrSignExpired。
    try testing.expectError(SignError.SignExpired, verifySign(&app, a, "/x", try signValue(a, app.jwt_secret, "/x", 1000000000)));
    // exp == 0 表示永不过期：远古时间戳也要能过。
    try verifySign(&app, a, "/x", try signValue(a, app.jwt_secret, "/x", 0));
}

test "sign: fs/get and fs/list fill a usable sign when sign_all is on" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fe = try frontend_mod.initFromHtml(a, .{}, "");
    defer fe.deinit();
    var app = routingApp(a, fe);

    // sign_all 默认 false：目录与文件都不签。
    try testing.expectEqualStrings("", try signForObj(&app, a, false, "/local/a.txt"));
    try testing.expectEqualStrings("", try signForObj(&app, a, true, "/local/dir"));

    // 打开开关。config 单例在测试里没有 load 过（可能是 null，也可能被别的
    // 测试 deinit 成悬空指针），所以 load 一份临时配置再注入。
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{dir});
    defer testing.allocator.free(cfg_path);
    // 恢复**进入前的**单例，而不是设 null —— 后面的测试（local download 等）
    // 仍要读 config，设 null 会让它们 panic。
    //
    // ⚠️ `prev` 必须在 `load()` **之前**取：`load()` 内部会把单例指向新配置，
    // 之后再 `getOpt()` 拿到的是 tcfg 自己 —— 清理时「恢复」成已 deinit 的
    // tcfg，单例悬空；之后任何读 config 的请求路径（如 setCors）段错误。
    // 2026-10-16 实测炸过（本 bug 在此处潜伏已久，直到 setCors 每请求读配置）。
    const prev = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev);
    tcfg.sign_all = true;
    tcfg.link_expiration = 0;

    const s = try signForObj(&app, a, false, "/local/a.txt");
    try testing.expect(s.len > 0);
    try testing.expect(std.mem.endsWith(u8, s, ":0")); // link_expiration=0 → 不过期
    // 目录永远不签（Go common.Sign 的 obj.IsDir() 分支）。
    try testing.expectEqualStrings("", try signForObj(&app, a, true, "/local/dir"));
    // 签出来的东西必须能验过 —— 否则前端拼上去也打不开。
    try verifySign(&app, a, "/local/a.txt", s);
}

test "sign: /d/ rejects a bad sign and accepts a good one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fe = try frontend_mod.initFromHtml(a, .{}, "");
    defer fe.deinit();
    var app = routingApp(a, fe);
    // 独立 config：sign_all=true，不让测试依赖全局单例的状态。
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{dir});
    defer testing.allocator.free(cfg_path);
    // ⚠️ `prev` 必须在 `load()` 之前取（load 会把单例指向新配置）——
    // 否则清理时恢复成已 deinit 的 tcfg，单例悬空。见前一处测试的注释。
    const prev = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev);
    tcfg.sign_all = true;

    const good = try signValue(a, app.jwt_secret, "/local/a.txt", 0);
    const mk = struct {
        fn f(al: std.mem.Allocator, q: []const u8) http.Request {
            const hdrs = al.dupe(Header, &.{}) catch unreachable;
            return http.Request{
                .arena = al,
                .method = "GET",
                .path = "/d/local/a.txt",
                .target = "/d/local/a.txt",
                .headers = hdrs,
                .query = if (q.len == 0) "" else q,
            };
        }
    }.f;

    // `downloadAuthError` 返回 null = 放行。四个失败态各自落到 Go `pkg/sign`
    // 的对应文案上（见 `downloadAuthMessage`）。
    var req_good = mk(a, try std.fmt.allocPrint(a, "sign={s}", .{good}));
    try testing.expectEqual(@as(?DownloadAuthError, null), downloadAuthError(&app, &req_good, "/local/a.txt"));

    // 整串被篡改且不含 ':' ⇒ 按 Go 的算法它整个被当成 exp ⇒ 解析不出
    // 过期时间 ⇒ **"expire invalid"**（不是 "sign invalid"，见上一条注释）。
    var req_bad = mk(a, "sign=tampered");
    try testing.expectEqual(
        @as(?DownloadAuthError, .expire_invalid),
        downloadAuthError(&app, &req_bad, "/local/a.txt"),
    );

    // 换了路径（签名确实有效、只是签的不是这个文件）⇒ "sign invalid"
    var req_other = mk(a, try std.fmt.allocPrint(a, "sign={s}", .{try signValue(a, app.jwt_secret, "/local/other.txt", 0)}));
    try testing.expectEqual(
        @as(?DownloadAuthError, .sign_invalid),
        downloadAuthError(&app, &req_other, "/local/a.txt"),
    );

    // 无 sign ⇒ Go `sign.go` 的 "expire missing"（exp 串为空）
    var req_none = mk(a, "");
    try testing.expectEqual(
        @as(?DownloadAuthError, .expire_missing),
        downloadAuthError(&app, &req_none, "/local/a.txt"),
    );

    // 只带过期时间、没有签名 ⇒ 值不相等 ⇒ "sign invalid"
    var req_nosig = mk(a, "sign=:0");
    try testing.expectEqual(
        @as(?DownloadAuthError, .sign_invalid),
        downloadAuthError(&app, &req_nosig, "/local/a.txt"),
    );

    // 过期时间非法 ⇒ "expire invalid"
    var req_badexp = mk(a, "sign=abc:xyz");
    try testing.expectEqual(
        @as(?DownloadAuthError, .expire_invalid),
        downloadAuthError(&app, &req_badexp, "/local/a.txt"),
    );

    // 过期时间在过去 ⇒ "sign expired"
    var req_expired = mk(a, try std.fmt.allocPrint(a, "sign={s}", .{
        try signValue(a, app.jwt_secret, "/local/a.txt", 1),
    }));
    try testing.expectEqual(
        @as(?DownloadAuthError, .sign_expired),
        downloadAuthError(&app, &req_expired, "/local/a.txt"),
    );
}

test "sign: /d/ is reachable without a token when the sign is valid" {
    // 回归：曾经 `/d/` 挂在 `handleAuthed` 下，而它开头就是 `checkAuth` ——
    // 只带 `?sign=`（没有 Authorization 头）的请求会在进到签名校验前就被
    // 401 拦掉，sign 体系形同虚设。这里走完整路由 `handle()` 钉住修复。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fe = try frontend_mod.initFromHtml(a, .{}, "");
    defer fe.deinit();
    var app = routingApp(a, fe);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{dir});
    defer testing.allocator.free(cfg_path);
    // ⚠️ `prev` 必须在 `load()` 之前取（load 会把单例指向新配置）——
    // 否则清理时恢复成已 deinit 的 tcfg，单例悬空。见前一处测试的注释。
    const prev = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev);
    tcfg.sign_all = true;

    // 造一个带 sign 的 /d/ 请求（无任何 Authorization 头）。
    const good = try signValue(a, app.jwt_secret, "/local/a.txt", 0);
    const qs = try std.fmt.allocPrint(a, "sign={s}", .{good});
    const hdrs = try a.dupe(Header, &.{});
    var req = http.Request{
        .arena = a,
        .method = "GET",
        .path = "/d/local/a.txt",
        .target = "/d/local/a.txt",
        .headers = hdrs,
        .query = qs,
    };
    // 路由层的判据：合法 sign 时**不会**在鉴权阶段就被拒。本测试没有真实
    // 存储，所以请求会一路走到 `fs.GetStorage` 失败 ⇒ Go `down.go:23-27`
    // 的 `ErrorPage(err, 500)`（"storage not found; rawPath: ..."）。
    // 拿到 500 就证明签名闸门放行了；拿到 401 说明鉴权层先把它拦了。
    const res = try doRequestRaw(&app, a, &req);
    try testing.expectEqual(@as(u16, 500), res.status);
    try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "storage not found") != null);

    // 对照：没有 sign 也没有 token → 401（鉴权层拦截）。
    var req2 = http.Request{
        .arena = a,
        .method = "GET",
        .path = "/d/local/a.txt",
        .target = "/d/local/a.txt",
        .headers = try a.dupe(Header, &.{}),
        .query = "",
    };
    const res2 = try doRequestRaw(&app, a, &req2);
    try testing.expectEqual(@as(u16, 401), res2.status);
}

/// 直接驱动 `handle()`（含路由分发），返回响应。
fn doRequestRaw(app: *App, a: std.mem.Allocator, req: *http.Request) !*http.Response {
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(app, req, res);
    return res;
}

// ---------------------------------------------------------------------------
// Storage admin CRUD ——「网页管理面可用」的全链路回归（2026-10-15 补齐）
// ---------------------------------------------------------------------------

/// 在 Item 数组里按 name 找一项（driver/list 的 additional 是数组形态）。
fn findDriverItem(arr: []const json.Value, name: []const u8) ?*const json.Value {
    for (arr) |*it| {
        if (std.mem.eql(u8, it.strAt("name") orelse "", name)) return it;
    }
    return null;
}

test "storage admin CRUD round trip persists to cfg.json and remounts live" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.createDirPath(rt.io(), "data") catch {};
    try tmp.dir.writeFile(rt.io(), .{ .sub_path = "data/hello.txt", .data = "hi zig" });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(root);
    const data_dir = try std.fmt.allocPrint(testing.allocator, "{s}/data", .{root});
    defer testing.allocator.free(data_dir);

    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{root});
    defer testing.allocator.free(cfg_path);
    const prev_cfg = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev_cfg);

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    // addition 是「JSON 字符串」—— 外层 body 里还得再转义一次。
    const addition = try std.fmt.allocPrint(a, "{{\"root_folder_path\":\"{s}\"}}", .{data_dir});
    var add_esc = Buf.init(a);
    try json.writeString(&add_esc, addition);
    const create_body = try std.fmt.allocPrint(
        a,
        "{{\"mount_path\":\"local\",\"driver\":\"Local\",\"order\":2,\"remark\":\"r1\",\"cache_expiration\":30,\"addition\":{s}}}",
        .{add_esc.slice()},
    );

    // 1) create：mount_path 故意不带前导斜杠，必须归一成 "/local"。
    {
        const res = try doRequestJson(&app, a, "POST", "/api/admin/storage/create", create_body, hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        const doc = try json.parse(a, res.buf.slice());
        try testing.expectEqual(@as(i64, 1), doc.getPath("data.id").?.asInt().?);
    }

    // 2) 落盘验证：config.json 里有归一后的挂载路径与字段。
    {
        const text = try std.Io.Dir.cwd().readFileAlloc(rt.io(), cfg_path, a, .limited(1 << 20));
        const doc = try json.parse(a, text);
        const storages = doc.getPath("storages").?.asArray().?;
        try testing.expectEqual(@as(usize, 1), storages.len);
        try testing.expectEqualStrings("/local", storages[0].strAt("mount_path").?);
        try testing.expectEqualStrings("Local", storages[0].strAt("driver").?);
        try testing.expectEqualStrings("r1", storages[0].strAt("remark").?);
        try testing.expectEqual(@as(i64, 2), storages[0].intAt("order").?);
    }

    // 3) get：编辑表单要的完整记录 + 前端 Storage 接口的字段必须齐。
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/storage/get", "id=1", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        const doc = try json.parse(a, res.buf.slice());
        const data = doc.getPath("data").?;
        try testing.expectEqualStrings("/local", data.strAt("mount_path").?);
        try testing.expectEqualStrings("Local", data.strAt("driver").?);
        try testing.expectEqualStrings("work", data.strAt("status").?);
        try testing.expectEqual(false, data.getPath("disabled").?.asBool().?);
        // addition 仍是字符串（Go 的存储形态），且能解开拿到 root。
        const add_doc = try json.parse(a, data.strAt("addition").?);
        try testing.expectEqualStrings(data_dir, add_doc.strAt("root_folder_path").?);
        for ([_][]const u8{
            "id", "mount_path", "order", "driver", "status", "addition",
            "remark", "modified", "order_by", "order_direction",
            "extract_folder", "web_proxy", "webdav_policy", "disabled",
        }) |k| {
            if (data.getPath(k) == null) return error.MissingStorageField;
        }
    }

    // 4) list：total=1。
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/storage/list", "", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        const doc = try json.parse(a, res.buf.slice());
        try testing.expectEqual(@as(i64, 1), doc.getPath("data.total").?.asInt().?);
        const content = doc.getPath("data.content").?.asArray().?;
        try testing.expectEqualStrings("/local", content[0].strAt("mount_path").?);
        try testing.expectEqualStrings("work", content[0].strAt("status").?);
    }

    // 5) fs/list：挂载**立即**可用 —— 网页加完存储马上能浏览，这是这次补齐的核心。
    {
        const res = try doRequestJson(&app, a, "POST", "/api/fs/list", "{\"path\":\"/local\"}", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        const doc = try json.parse(a, res.buf.slice());
        const content = doc.getPath("data.content").?.asArray().?;
        try testing.expectEqual(@as(usize, 1), content.len);
        try testing.expectEqualStrings("hello.txt", content[0].strAt("name").?);
    }

    // 6) update：改 remark/order ⇒ 落盘 + 重建驱动，目录照常。
    {
        const body = try std.fmt.allocPrint(
            a,
            "{{\"id\":1,\"mount_path\":\"/local\",\"driver\":\"Local\",\"order\":5,\"remark\":\"r2\",\"cache_expiration\":30,\"addition\":{s}}}",
            .{add_esc.slice()},
        );
        const res = try doRequestJson(&app, a, "POST", "/api/admin/storage/update", body, hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
    }
    {
        const fs = try doRequestJson(&app, a, "POST", "/api/fs/list", "{\"path\":\"/local\"}", hdrs);
        try testing.expectEqual(@as(u16, 200), fs.status);
    }
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/storage/get", "id=1", hdrs);
        const doc = try json.parse(a, res.buf.slice());
        try testing.expectEqual(@as(i64, 5), doc.getPath("data.order").?.asInt().?);
        try testing.expectEqualStrings("r2", doc.getPath("data").?.strAt("remark").?);
    }

    // 7) 语义防线：改驱动 / 重复挂载路径 / 坏 addition / 未知驱动 / 缺 mount_path。
    {
        const body = try std.fmt.allocPrint(a, "{{\"id\":1,\"mount_path\":\"/local\",\"driver\":\"WebDav\",\"addition\":{s}}}", .{add_esc.slice()});
        const res = try doRequestJson(&app, a, "POST", "/api/admin/storage/update", body, hdrs);
        try expectApiCode(res, 400);
        try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "driver cannot be changed") != null);
    }
    {
        const res = try doRequestJson(&app, a, "POST", "/api/admin/storage/create", "{\"mount_path\":\"/local\",\"driver\":\"Local\",\"addition\":\"{}\"}", hdrs);
        try expectApiCode(res, 400);
        try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "mount path already exists") != null);
    }
    {
        const res = try doRequestJson(&app, a, "POST", "/api/admin/storage/create", "{\"mount_path\":\"/x\",\"driver\":\"NoSuch\",\"addition\":\"{}\"}", hdrs);
        try expectApiCode(res, 500);
        try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "no driver named") != null);
    }
    {
        const res = try doRequestJson(&app, a, "POST", "/api/admin/storage/create", "{\"mount_path\":\"/y\",\"driver\":\"Local\",\"addition\":\"not json\"}", hdrs);
        try expectApiCode(res, 400);
    }
    {
        const res = try doRequestJson(&app, a, "POST", "/api/admin/storage/create", "{\"driver\":\"Local\",\"addition\":\"{}\"}", hdrs);
        try expectApiCode(res, 400);
    }
    {
        // 缺 id 的 update：Go 的 binding 也会拒。
        const res = try doRequestJson(&app, a, "POST", "/api/admin/storage/update", "{\"mount_path\":\"/local\",\"driver\":\"Local\"}", hdrs);
        try expectApiCode(res, 400);
    }

    // 8) disable：fs 404、记录显示 disabled；enable：恢复。
    {
        const res = try doRequestWith(&app, a, "POST", "/api/admin/storage/disable", "id=1", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
    }
    {
        const fs = try doRequestJson(&app, a, "POST", "/api/fs/list", "{\"path\":\"/local\"}", hdrs);
        try expectApiCode(fs, 404);
    }
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/storage/get", "id=1", hdrs);
        const doc = try json.parse(a, res.buf.slice());
        try testing.expectEqual(true, doc.getPath("data.disabled").?.asBool().?);
        try testing.expectEqualStrings("disabled", doc.getPath("data").?.strAt("status").?);
    }
    {
        // 已禁用再 disable → 400（Go 文案原样）。
        const res = try doRequestWith(&app, a, "POST", "/api/admin/storage/disable", "id=1", hdrs);
        try expectApiCode(res, 400);
        try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "this storage have disabled") != null);
    }
    {
        const res = try doRequestWith(&app, a, "POST", "/api/admin/storage/enable", "id=1", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        const fs = try doRequestJson(&app, a, "POST", "/api/fs/list", "{\"path\":\"/local\"}", hdrs);
        try testing.expectEqual(@as(u16, 200), fs.status);
    }
    {
        // 已启用再 enable → 400。
        const res = try doRequestWith(&app, a, "POST", "/api/admin/storage/enable", "id=1", hdrs);
        try expectApiCode(res, 400);
        try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "this storage have enabled") != null);
    }

    // 9) delete：出表、落盘、摘挂载；重复删除 → 404。
    {
        const res = try doRequestWith(&app, a, "POST", "/api/admin/storage/delete", "id=1", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
    }
    {
        const fs = try doRequestJson(&app, a, "POST", "/api/fs/list", "{\"path\":\"/local\"}", hdrs);
        try expectApiCode(fs, 404);
    }
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/storage/list", "", hdrs);
        const doc = try json.parse(a, res.buf.slice());
        try testing.expectEqual(@as(i64, 0), doc.getPath("data.total").?.asInt().?);
    }
    {
        const text = try std.Io.Dir.cwd().readFileAlloc(rt.io(), cfg_path, a, .limited(1 << 20));
        const doc = try json.parse(a, text);
        try testing.expectEqual(@as(usize, 0), doc.getPath("storages").?.asArray().?.len);
    }
    {
        const res = try doRequestWith(&app, a, "POST", "/api/admin/storage/delete", "id=1", hdrs);
        try expectApiCode(res, 404);
    }

    // 10) create init 失败路径：行保留 + error_msg 可见 + data.id 带回。
    {
        const bad_root = try std.fmt.allocPrint(a, "{s}/no-such-dir", .{root});
        const bad_add = try std.fmt.allocPrint(a, "{{\"root_folder_path\":\"{s}\"}}", .{bad_root});
        var bad_esc = Buf.init(a);
        try json.writeString(&bad_esc, bad_add);
        const body = try std.fmt.allocPrint(
            a,
            "{{\"mount_path\":\"/broken\",\"driver\":\"Local\",\"addition\":{s}}}",
            .{bad_esc.slice()},
        );
        const res = try doRequestJson(&app, a, "POST", "/api/admin/storage/create", body, hdrs);
        try expectApiCode(res, 500);
        const doc = try json.parse(a, res.buf.slice());
        // Go 在这里带 data.id（前端据此跳编辑页）。
        try testing.expect(doc.getPath("data.id") != null);
        // 行已保留，管理面能看到 errored 行（旧实现只遍历挂载 ⇒ 失败项直接消失）。
        const list = try doRequestWith(&app, a, "GET", "/api/admin/storage/list", "", hdrs);
        const ldoc = try json.parse(a, list.buf.slice());
        try testing.expectEqual(@as(i64, 1), ldoc.getPath("data.total").?.asInt().?);
        try testing.expectEqualStrings("errored", ldoc.getPath("data.content.0.status").?.asStr().?);
        try testing.expect(ldoc.getPath("data.content.0.error_msg").?.asStr().?.len > 0);
        // 落盘也在（下次重启仍能看见这条失败记录）。
        const text = try std.Io.Dir.cwd().readFileAlloc(rt.io(), cfg_path, a, .limited(1 << 20));
        const fdoc = try json.parse(a, text);
        try testing.expectEqual(@as(usize, 1), fdoc.getPath("storages").?.asArray().?.len);
    }
}

test "driver list & info carry the Go Info shape the add/edit form renders" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    // /api/admin/driver/list：`{name: {common, additional, config}}`。
    // 回归：此前返回裸 addition_schema（没有 common 键），前端 AddOrEdit 取
    // `drivers()[name].common` 得 undefined，「添加存储」表单根本渲染不出来。
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/driver/list", "", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        const doc = try json.parse(a, res.buf.slice());
        const data = doc.getPath("data").?.asObject().?;
        const local = data.get("Local") orelse return error.LocalDriverMissing;
        const common = local.getPath("common").?.asArray().?;
        try testing.expect(common.len >= 3);
        try testing.expectEqualStrings("mount_path", common[0].strAt("name").?);
        try testing.expectEqual(true, common[0].getPath("required").?.asBool().?);
        // additional：数组形态，且字段取自 addition_schema。
        const additional = local.getPath("additional").?.asArray().?;
        const root_item = findDriverItem(additional, "root_folder_path") orelse return error.MissingRootPathItem;
        try testing.expectEqualStrings("/data", root_item.strAt("default").?);
        // ⚠️ 回归钉子：default 必须是**字符串** "true"，不是原生 bool ——
        // 前端 GetDefaultValue(Type.Bool, value) 靠 `value === "true"` 判断，
        // 给 bool true 会全部静默判成 false。
        const hidden_item = findDriverItem(additional, "show_hidden") orelse return error.MissingShowHiddenItem;
        try testing.expectEqualStrings("true", hidden_item.strAt("default").?);
        try testing.expectEqualStrings("bool", hidden_item.strAt("type").?);
        const conf = local.getPath("config").?;
        try testing.expectEqualStrings("Local", conf.strAt("name").?);
    }

    // /api/admin/driver/info?driver=Local：编辑存储页拉单个驱动的同一形状。
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/driver/info", "driver=Local", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        const doc = try json.parse(a, res.buf.slice());
        try testing.expect(doc.getPath("data.common").?.asArray().?.len >= 3);
        try testing.expect(doc.getPath("data.additional").?.asArray().?.len > 0);
        try testing.expectEqualStrings("Local", doc.getPath("data.config").?.strAt("name").?);
    }
    // 未知驱动 → 404（文案对齐 Go `driver [x] not found`）。
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/driver/info", "driver=NoSuchDriver", hdrs);
        try expectApiCode(res, 404);
        try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "driver [NoSuchDriver] not found") != null);
    }
}

test "setting save persists and setting delete resets a key to its default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(root);
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{root});
    defer testing.allocator.free(cfg_path);
    const prev_cfg = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev_cfg);

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    // save（前端发的就是 SettingItem 数组：key/value/...）。
    {
        const res = try doRequestJson(&app, a, "POST", "/api/admin/setting/save", "[{\"key\":\"site_title\",\"value\":\"Custom Site\"}]", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
    }
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/setting/get", "key=site_title", hdrs);
        const doc = try json.parse(a, res.buf.slice());
        const items = doc.getPath("data").?.asArray().?;
        try testing.expectEqual(@as(usize, 1), items.len);
        try testing.expectEqualStrings("Custom Site", items[0].strAt("value").?);
    }
    // 落盘。
    {
        const text = try std.Io.Dir.cwd().readFileAlloc(rt.io(), cfg_path, a, .limited(1 << 20));
        const doc = try json.parse(a, text);
        try testing.expectEqualStrings("Custom Site", doc.strAt("zig.site_title").?);
    }
    // delete → 回到编译期默认 "OpenList"。
    {
        const res = try doRequestWith(&app, a, "POST", "/api/admin/setting/delete", "key=site_title", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
    }
    {
        const res = try doRequestWith(&app, a, "GET", "/api/admin/setting/get", "key=site_title", hdrs);
        const doc = try json.parse(a, res.buf.slice());
        try testing.expectEqualStrings("OpenList", doc.getPath("data.0.value").?.asStr().?);
    }
    {
        const text = try std.Io.Dir.cwd().readFileAlloc(rt.io(), cfg_path, a, .limited(1 << 20));
        const doc = try json.parse(a, text);
        try testing.expectEqualStrings("OpenList", doc.strAt("zig.site_title").?);
    }
    // 非本工程建模的键 → 404。
    {
        const res = try doRequestWith(&app, a, "POST", "/api/admin/setting/delete", "key=no_such_key", hdrs);
        try expectApiCode(res, 404);
    }
}

test "reset_token rotates zig.token, persists it, and invalidates old download links" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(root);
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{root});
    defer testing.allocator.free(cfg_path);
    const prev_cfg = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev_cfg);

    // 固定一个已知 token 并让 app 用它签名（模拟线上启动时的内存快照）。
    try tcfg.putZig("token", .{ .string = try tcfg.allocator().dupe(u8, "openlist-old-token") });
    app.sign_secret = "openlist-old-token";
    const old_sign = try signValue(a, signKey(&app), "/local/a.txt", 0);
    try verifySign(&app, a, "/local/a.txt", old_sign); // 旧密钥有效

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    const res = try doRequestWith(&app, a, "POST", "/api/admin/setting/reset_token", "", hdrs);
    try testing.expectEqual(@as(u16, 200), res.status);
    const doc = try json.parse(a, res.buf.slice());
    const new_tok = doc.strAt("data") orelse return error.TestUnexpectedResult;
    // Go `random.Token()` 形状：openlist- + 36 位 UUID + 64 位字母数字。
    try testing.expectEqual(@as(usize, 9 + 36 + 64), new_tok.len);
    try testing.expect(std.mem.startsWith(u8, new_tok, "openlist-"));
    try testing.expect(!std.mem.eql(u8, new_tok, "openlist-old-token"));

    // 内存副本同步 + 落盘（重启后仍生效）。
    try testing.expectEqualStrings(new_tok, app.sign_secret);
    {
        const text = try std.Io.Dir.cwd().readFileAlloc(rt.io(), cfg_path, a, .limited(1 << 20));
        const on_disk = try json.parse(a, text);
        try testing.expectEqualStrings(new_tok, on_disk.strAt("zig.token").?);
    }

    // 旧链接立即失效（Go `sign.Instance()` 的效果），新密钥可用。
    try testing.expectError(SignError.SignInvalid, verifySign(&app, a, "/local/a.txt", old_sign));
    const new_sign = try signValue(a, signKey(&app), "/local/a.txt", 0);
    try verifySign(&app, a, "/local/a.txt", new_sign);
}

test "buildMountsFromConfig skips broken records but keeps them visible to the admin list" {
    // 启动 / load_all 共用的全量重建：合法项挂载、未知驱动与重复路径跳过、
    // init 失败记 error_msg（管理面能看到 errored 行）。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.createDirPath(rt.io(), "data") catch {};
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(root);
    const data_dir = try std.fmt.allocPrint(testing.allocator, "{s}/data", .{root});
    defer testing.allocator.free(data_dir);

    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{root});
    defer testing.allocator.free(cfg_path);
    const prev_cfg = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev_cfg);

    // 手写 storages（load 之后直接改内存副本即可 —— 这正是 buildMountsFromConfig
    // 的输入）：#1 合法；#2 未知驱动；#3 与 #1 同路径；#4 根目录不存在（init 失败）。
    const good_add = try std.fmt.allocPrint(a, "{{\"root_folder_path\":\"{s}\"}}", .{data_dir});
    const bad_add = try std.fmt.allocPrint(a, "{{\"root_folder_path\":\"{s}/missing\"}}", .{root});
    const records = try a.alloc(model.Storage, 4);
    records[0] = .{ .id = 1, .mount_path = "/a", .driver = "Local", .addition = good_add };
    records[1] = .{ .id = 2, .mount_path = "/b", .driver = "NoSuchDriver", .addition = "{}" };
    records[2] = .{ .id = 3, .mount_path = "/a", .driver = "Local", .addition = good_add };
    records[3] = .{ .id = 4, .mount_path = "/c", .driver = "Local", .addition = bad_add };
    tcfg.storages = records;

    try buildMountsFromConfig(a, &app, tcfg);

    // 只有 #1 挂上。
    try testing.expectEqual(@as(usize, 1), app.mountsSnapshot().len);
    try testing.expectEqualStrings("/a", app.mountsSnapshot()[0].mount_path);
    // #4 的 init 失败写回了 error_msg（管理面据此显示 errored）。
    try testing.expect(tcfg.storageById(4).?.error_msg.len > 0);
    // 其余记录仍在表里 —— 管理面从配置表渲染，不会丢行。
    try testing.expectEqual(@as(usize, 4), tcfg.storages.len);
}

/// 给会触达 `config.get()` 的 handler 测试准备一份临时配置，并在作用域结束时
/// 还原单例。**必须在 `config.load` 之前取 prev** —— load 自己会把单例指到新
/// 对象，之后取 prev 等于还原成一个已 deinit 的指针（现有 sign 测试的注释里
/// 记着这个 segfault 坑）。
///
/// 返回 `{ .prev, .cfg, .tmp }`，**调用方必须 `defer tc.tmp.cleanup()`**。
///
/// 为什么把 tmp 的所有权交出去：早期版本在这里 `defer tmp.cleanup()`，临时目录
/// 在函数返回时就没了，于是 handler 里的 `cfg.save()` 必然失败 ⇒ `/api/me/update`
/// 实测返回 500 而不是 200（这个坑值得记一笔：**临时目录的生命周期必须长过
/// 会写它的配置对象**）。cleanup 只删目录，cfg 的内存归调用方 alloc 管。
fn testConfig(alloc: std.mem.Allocator) !struct { prev: ?*config.Config, cfg: *config.Config, tmp: testing.TmpDir } {
    const tmp = testing.tmpDir(.{});  // 可变性由调用方 tc.tmp 提供（cleanup 取 &tc.tmp）
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", alloc);
    const cfg_path = try std.fmt.allocPrint(alloc, "{s}/config.json", .{root});
    const prev = config.getOpt();
    const cfg = try config.load(alloc, cfg_path);
    config.setForTest(cfg);
    return .{ .prev = prev, .cfg = cfg, .tmp = tmp };
}

/// M14 之后**每枚测试令牌必须互不相同**。
///
/// `mintTestToken` 的 payload 只由 secret/user/pwd_ts/exp 决定，于是所有调用
/// 方拿到的是**同一枚**令牌。M14 让 logout 真的作废出示的令牌之后，「登出」
/// 测试会把并发运行的其它测试的令牌一起作废（Zig 测试执行器是并行的，
/// 全局作废表是共享的）—— 表现为看似无关的测试突然 401。
/// 这里给每枚令牌塞一个唯一 nonce，把它们的签名撑开。
var g_test_token_seq = std.atomic.Value(u64).init(0);

/// 带唯一 nonce 的测试令牌（payload 多一个 `nbf`，校验侧不看它）。
fn mintTestTokenUnique(a: std.mem.Allocator, secret: []const u8, user: []const u8, pwd_ts: i64) ![]u8 {
    const exp: i64 = 4102444800; // 2100-01-01, comfortably in the future
    const nonce: i64 = @intCast(g_test_token_seq.fetchAdd(1, .monotonic));
    const h64 = try b64Url(a, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
    var payload = Buf.init(a);
    try payload.append("{\"username\":");
    try json.writeString(&payload, user);
    try payload.print(",\"pwd_ts\":{d},\"exp\":{d},\"iat\":{d},\"nbf\":{d}}}", .{ pwd_ts, exp, nonce, nonce });
    const p64 = try b64Url(a, payload.slice());
    const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ h64, p64 });
    const sig = try hmacSha256(a, secret, signing_input);
    const s64 = try b64Url(a, &sig);
    return std.fmt.allocPrint(a, "{s}.{s}", .{ signing_input, s64 });
}

/// 给测试签一枚当前有效的令牌。`routingApp` 里 `admin_hash` 为空（无法真登录），
/// 所以认证路径的测试都靠直接签发令牌来走。
fn testToken(a: std.mem.Allocator, app: *const App) ![]const u8 {
    return mintTestTokenUnique(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
}

fn testAuth(a: std.mem.Allocator, app: *const App) ![]Header {
    const tok = try testToken(a, app);
    const h = try a.alloc(Header, 1);
    h[0] = .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{tok}) };
    return h;
}

test "me/update changes the password and invalidates old tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tc = try testConfig(a);
    defer tc.tmp.cleanup();  // 最先执行（LIFO）；cfg 的内存另由 deinit 释放
    defer config.setForTest(tc.prev);
    defer tc.cfg.deinit();
    const fe = try frontend_mod.initFromHtml(a, .{}, "");
    var app = routingApp(a, fe);

    const hdrs = try testAuth(a, &app);

    // 令牌此刻有效
    {
        const res = try doRequestWith(&app, a, "GET", "/api/me", "", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
    }

    // 改密码（对齐 Go UpdateCurrent：Password != "" 才改）
    {
        const res = try doRequestJson(&app, a, "POST", "/api/me/update",
            "{\"username\":\"admin\",\"password\":\"newpass123\"}", hdrs);
        try testing.expectEqual(@as(u16, 200), res.status);
        _ = try json.parse(a, res.buf.slice());
    }

    // 旧令牌必须被拒（admin_pwd_ts 已推进）—— checkAuth 的 A03 行为
    {
        const res = try doRequestWith(&app, a, "GET", "/api/me", "", hdrs);
        try expectApiCode(res, 401);
    }
    // 用新口令版本重签即可继续访问
    const hdrs2 = try testAuth(a, &app);
    {
        const res = try doRequestWith(&app, a, "GET", "/api/me", "", hdrs2);
        try testing.expectEqual(@as(u16, 200), res.status);
    }

    // 改用户名：登录名随之变（新名字能签出有效令牌，旧名字不能）
    {
        const res = try doRequestJson(&app, a, "POST", "/api/me/update",
            "{\"username\":\"root\",\"password\":\"\"}", hdrs2);
        try testing.expectEqual(@as(u16, 200), res.status);
    }
    try testing.expectEqualStrings("root", app.admin_user);
    const hdrs3 = try testAuth(a, &app);
    {
        const res = try doRequestWith(&app, a, "GET", "/api/me", "", hdrs3);
        try testing.expectEqual(@as(u16, 200), res.status);
    }
}

test "me/update rejects bad input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tc = try testConfig(a);
    defer tc.tmp.cleanup();  // 最先执行（LIFO）；cfg 的内存另由 deinit 释放
    defer config.setForTest(tc.prev);
    defer tc.cfg.deinit();
    const fe = try frontend_mod.initFromHtml(a, .{}, "");
    var app = routingApp(a, fe);
    const hdrs = try testAuth(a, &app);

    // 密码太短：沿用 InitSetup 的 4 位下限，避免"能建不能改"的不一致。
    {
        const res = try doRequestJson(&app, a, "POST", "/api/me/update",
            "{\"username\":\"admin\",\"password\":\"ab\"}", hdrs);
        try expectApiCode(res, 400);
    }
    // 空用户名：单管理员下不接受（Go 无条件赋值，但那会造出无法登录的账号）
    {
        const res = try doRequestJson(&app, a, "POST", "/api/me/update",
            "{\"username\":\"\",\"password\":\"\"}", hdrs);
        try expectApiCode(res, 400);
    }
    // 未认证
    {
        const none = try a.alloc(Header, 0);  // []Header，零长度
        const res = try doRequestJson(&app, a, "POST", "/api/me/update",
            "{\"username\":\"admin\",\"password\":\"x\"}", none);
        try expectApiCode(res, 401);
    }
    // 上面这些失败都不该改动状态
    try testing.expectEqualStrings("admin", app.admin_user);
}

test "auth/logout returns success like Go's LogOut" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tc = try testConfig(a);
    defer tc.tmp.cleanup();  // 最先执行（LIFO）；cfg 的内存另由 deinit 释放
    defer config.setForTest(tc.prev);
    defer tc.cfg.deinit();
    const fe = try frontend_mod.initFromHtml(a, .{}, "");
    var app = routingApp(a, fe);
    const hdrs = try testAuth(a, &app);

    const res = try doRequestWith(&app, a, "GET", "/api/auth/logout", "", hdrs);
    try testing.expectEqual(@as(u16, 200), res.status);
    _ = try json.parse(a, res.buf.slice());

    // 未认证应被拒（路由在 handleAuthed 之下）
    const none = try a.alloc(Header, 0);  // []Header，零长度
    const res2 = try doRequestWith(&app, a, "GET", "/api/auth/logout", "", none);
    try expectApiCode(res2, 401);
}

test "me reports the Go admin permission bits, not zero" {
    // 回归（2026-10-16 从用户备份发现）：Go `InitSetup` 建 admin 时写
    // `Permission: 0x71FF`（server/handles/setup.go:60 = 29183），前端按这些位
    // 决定显不显示操作按钮。这里曾经硬编码 0，等于把界面功能全禁掉。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tc = try testConfig(a);
    defer tc.tmp.cleanup();
    defer config.setForTest(tc.prev);
    defer tc.cfg.deinit();
    const fe = try frontend_mod.initFromHtml(a, .{}, "");
    var app = routingApp(a, fe);

    try testing.expectEqual(@as(i64, 0x71FF), app.admin_permission);
    const hdrs = try testAuth(a, &app);
    const res = try doRequestWith(&app, a, "GET", "/api/me", "", hdrs);
    try testing.expectEqual(@as(u16, 200), res.status);
    const parsed = try json.parse(a, res.buf.slice());
    const perm = parsed.getPath("data.permission").?.asInt().?;
    try testing.expectEqual(@as(i64, 0x71FF), perm);
}

test "fs/list + fs/get 的 path 对齐 Go JoinBasePath（空串=根；.. → 403）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.createDirPath(rt.io(), "data") catch {};
    try tmp.dir.writeFile(rt.io(), .{ .sub_path = "data/hello.txt", .data = "hi zig" });
    const root = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", a);
    defer a.free(root);
    const data_dir = try std.fmt.allocPrint(a, "{s}/data", .{root});
    defer a.free(data_dir);

    const cfg_path = try std.fmt.allocPrint(a, "{s}/config.json", .{root});
    defer a.free(cfg_path);
    const prev_cfg = config.getOpt();
    const tcfg = try config.load(a, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev_cfg);

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    const addition = try std.fmt.allocPrint(a, "{{\"root_folder_path\":\"{s}\"}}", .{data_dir});
    var add_esc = Buf.init(a);
    try json.writeString(&add_esc, addition);
    const create_body = try std.fmt.allocPrint(
        a,
        "{{\"mount_path\":\"local\",\"driver\":\"Local\",\"order\":2,\"remark\":\"r1\",\"cache_expiration\":30,\"addition\":{s}}}",
        .{add_esc.slice()},
    );
    const created = try doRequestJson(&app, a, "POST", "/api/admin/storage/create", create_body, hdrs);
    try testing.expectEqual(@as(u16, 200), created.status);

    // Go `utils.JoinBasePath`：空串 = 根（stdpath.Join(base, "") == base），
    // 所以 fs/list 返回挂载点、fs/get 返回虚拟根对象 —— 不是 404。
    const list_empty = try doRequestJson(&app, a, "POST", "/api/fs/list", "{\"path\":\"\"}", hdrs);
    try testing.expectEqual(@as(u16, 200), list_empty.status);
    const get_empty = try doRequestJson(&app, a, "POST", "/api/fs/get", "{\"path\":\"\"}", hdrs);
    try testing.expectEqual(@as(u16, 200), get_empty.status);

    // 含 ".." 且规范化后消失 → `errs.RelativePath`（403），不是 404。
    for ([_][]const u8{ "/local/../../etc", "/local/../data" }) |p| {
        const body = try std.fmt.allocPrint(a, "{{\"path\":\"{s}\"}}", .{p});
        const r1 = try doRequestJson(&app, a, "POST", "/api/fs/list", body, hdrs);
        try expectApiCode(r1, 403);
        const r2 = try doRequestJson(&app, a, "POST", "/api/fs/get", body, hdrs);
        try expectApiCode(r2, 403);
    }

    // 正常路径不受影响
    const ok = try doRequestJson(&app, a, "POST", "/api/fs/list", "{\"path\":\"/local\"}", hdrs);
    try testing.expectEqual(@as(u16, 200), ok.status);
}

test "config/import+export: OpenList 备份格式 merge（新建→updated）+ 未知驱动 + 两种导出" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg_dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(cfg_dir);
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{cfg_dir});
    defer testing.allocator.free(cfg_path);
    const prev_cfg = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev_cfg);

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    var hdrs = [_]Header{.{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) }};

    // ---- import #1：备份格式（disabled=true 跳过挂载构建，专注表操作）----
    const doc = "{\"encrypted\":false,\"settings\":[{\"key\":\"site_title\",\"value\":\"ImportTest\"}],\"users\":[],\"metas\":[],\"shares\":[],\"storages\":[{\"mount_path\":\"/olz-import-test\",\"driver\":\"Local\",\"addition\":\"{}\",\"remark\":\"io-test\",\"disabled\":true}]}";
    const r1 = try doRequestJsonQuery(&app, a, "POST", "/api/admin/config/import", "mode=merge", doc, &hdrs);
    try expectApiCode(r1, 200);
    const d1 = try json.parse(a, r1.buf.slice());
    try testing.expectEqual(@as(i64, 1), d1.getPath("data").?.intAt("created").?);
    try testing.expectEqual(@as(i64, 1), d1.getPath("data").?.intAt("settings_applied").?);

    // ---- import #2：同一文件再导 → updated=1（不是新建）----
    const r2 = try doRequestJsonQuery(&app, a, "POST", "/api/admin/config/import", "mode=merge", doc, &hdrs);
    try expectApiCode(r2, 200);
    const d2 = try json.parse(a, r2.buf.slice());
    try testing.expectEqual(@as(i64, 0), d2.getPath("data").?.intAt("created").?);
    try testing.expectEqual(@as(i64, 1), d2.getPath("data").?.intAt("updated").?);

    // ---- import #3：未知驱动 → failed 列表，且行不会创建 ----
    const bad = "{\"encrypted\":false,\"settings\":[],\"storages\":[{\"mount_path\":\"/olz-bad\",\"driver\":\"NoSuchDriver\",\"addition\":\"{}\"}]}";
    const r3 = try doRequestJsonQuery(&app, a, "POST", "/api/admin/config/import", "mode=merge", bad, &hdrs);
    try expectApiCode(r3, 200);
    const d3 = try json.parse(a, r3.buf.slice());
    const fails3 = d3.getPath("data.failed").?.asArray().?;
    try testing.expectEqual(@as(usize, 1), fails3.len);

    // ---- export backup：可解析，含全部段与刚导入的存储 ----
    const e1 = try doRequestWith(&app, a, "GET", "/api/admin/config/export", "format=backup", &hdrs);
    try testing.expectEqual(@as(u16, 200), e1.status);
    const eb = try json.parse(a, e1.buf.slice());
    try testing.expect(eb.intAt("encrypted").? == 0);
    try testing.expect(eb.getPath("settings").?.asArray().?.len > 0);
    var found = false;
    for (eb.getPath("storages").?.asArray().?) |*row| {
        if (row.strAt("mount_path")) |mp| {
            if (std.mem.eql(u8, mp, "/olz-import-test")) found = true;
        }
    }
    try testing.expect(found);

    // ---- export cfg：cfg.json 原文（含 jwt_secret / storages）----
    const e2 = try doRequestWith(&app, a, "GET", "/api/admin/config/export", "format=cfg", &hdrs);
    try testing.expectEqual(@as(u16, 200), e2.status);
    const ec = try json.parse(a, e2.buf.slice());
    try testing.expect(ec.strAt("jwt_secret") != null);
}

/// M9/M12 共用的假驱动：`list` 返回固定条目（目录 + 带 md5 的文件）。
const FakeDirsDriver = struct {
    fn name(_: *anyopaque) []const u8 {
        return "Fake";
    }
    fn list(_: *anyopaque, ctx: *driver.Ctx, _: []const u8) anyerror![]model.Obj {
        const objs = try ctx.alloc.alloc(model.Obj, 3);
        objs[0] = .{ .name = "dir-a", .is_dir = true, .modified = 1700000000 };
        objs[1] = .{ .name = "movie.mkv", .is_dir = false, .size = 42, .modified = 1700000001, .hash_info = .{ .hash_name = "md5", .hash_value = "abc" } };
        objs[2] = .{ .name = "dir-b", .is_dir = true, .modified = 1700000002 };
        return objs;
    }
};

test "M12: fs/dirs returns a bare array of subdirectories (Go DirResp shape)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var vt: driver.Driver.VTable = undefined;
    vt.name = FakeDirsDriver.name;
    vt.list = FakeDirsDriver.list;
    var mounts = try a.alloc(Mount, 1);
    mounts[0] = .{ .storage = .{ .driver = "Fake", .mount_path = "/m" }, .driver = .{ .ptr = undefined, .vtable = &vt }, .mount_path = "/m", .label = "Fake" };

    var app = App{
        .alloc = a,
        .mounts = mounts,
        .admin_hash = "",
        .admin_user = "admin",
        .admin_pwd_ts = 0,
        .jwt_secret = "s",
        .site_url = "",
        .cdn = "",
        .token_expires_in_hours = 48,
        .frontend = undefined,
    };

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    // 1) 子路径：只留目录、裸数组、Go DirResp 形状（name + modified）
    var req = http.Request{ .arena = a, .method = "POST", .path = "/api/fs/dirs", .target = "/api/fs/dirs", .headers = hdrs, .body = .{ .memory = "{\"path\":\"/m\"}" } };
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(&app, &req, res);
    try testing.expectEqual(@as(u16, 200), res.status);
    const parsed = try json.parse(a, res.buf.slice());
    const data = parsed.getPath("data") orelse return error.TestFailed;
    try testing.expect(data.* == .array);
    const arr = data.asArray() orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 2), arr.len); // 文件被过滤掉
    try testing.expectEqualStrings("dir-a", arr[0].getPath("name").?.asStr().?);
    try testing.expectEqualStrings("dir-b", arr[1].getPath("name").?.asStr().?);
    // Go `DirResp.Modified` 是 RFC3339 时间（不是挂载点元数据）。
    try testing.expectEqualStrings("2023-11-14T22:13:20Z", arr[0].getPath("modified").?.asStr().?);

    // 2) 根路径：挂载点本身（名字去掉首斜杠），modified 为存储的 modified（零值）。
    var req2 = http.Request{ .arena = a, .method = "POST", .path = "/api/fs/dirs", .target = "/api/fs/dirs", .headers = hdrs, .body = .{ .memory = "{\"path\":\"/\"}" } };
    const res2 = try a.create(http.Response);
    res2.* = http.Response.init(a);
    try handle(&app, &req2, res2);
    const parsed2 = try json.parse(a, res2.buf.slice());
    const arr2 = parsed2.getPath("data").?.asArray() orelse return error.TestFailed;
    try testing.expectEqual(@as(usize, 1), arr2.len);
    try testing.expectEqualStrings("m", arr2[0].getPath("name").?.asStr().?);
    try testing.expectEqualStrings("0001-01-01T00:00:00Z", arr2[0].getPath("modified").?.asStr().?);
}

test "M9: fs/list items carry hashinfo string and hash_info object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var vt: driver.Driver.VTable = undefined;
    vt.name = FakeDirsDriver.name;
    vt.list = FakeDirsDriver.list;
    var mounts = try a.alloc(Mount, 1);
    mounts[0] = .{ .storage = .{ .driver = "Fake", .mount_path = "/m" }, .driver = .{ .ptr = undefined, .vtable = &vt }, .mount_path = "/m", .label = "Fake" };

    var app = App{
        .alloc = a,
        .mounts = mounts,
        .admin_hash = "",
        .admin_user = "admin",
        .admin_pwd_ts = 0,
        .jwt_secret = "s",
        .site_url = "",
        .cdn = "",
        .token_expires_in_hours = 48,
        .frontend = undefined,
    };

    const token = try mintTestToken(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts);
    const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
    const hdrs = try a.alloc(Header, 1);
    hdrs[0] = .{ .name = "Authorization", .value = auth };

    var req = http.Request{ .arena = a, .method = "POST", .path = "/api/fs/list", .target = "/api/fs/list", .headers = hdrs, .body = .{ .memory = "{\"path\":\"/m\"}" } };
    const res = try a.create(http.Response);
    res.* = http.Response.init(a);
    try handle(&app, &req, res);
    const parsed = try json.parse(a, res.buf.slice());
    const items = parsed.getPath("data.content").?.asArray() orelse return error.TestFailed;

    // Go `toObjsResp`：HashInfoStr = json.Marshal(map)（**再序列化成字符串**）⇒
    // 外层再转义一层引号；HashInfo = map 本体。
    const file = items[1]; // dir-a / movie.mkv / dir-b
    try testing.expectEqualStrings("{\"md5\":\"abc\"}", file.getPath("hashinfo").?.asStr().?);
    try testing.expectEqualStrings("abc", file.getPath("hash_info.md5").?.asStr().?);

    // 无哈希的条目：Go 零值 HashInfo 的 map 是 nil ⇒ marshal 出字符串 "null"。
    const dir = items[0];
    try testing.expectEqualStrings("null", dir.getPath("hashinfo").?.asStr().?);
    try testing.expect(dir.getPath("hash_info").?.* == .null);
}

// ---------------------------------------------------------------------------
// 审计 M13 / M14 / M15 回归（2026-10-17 深夜轮）
// ---------------------------------------------------------------------------

/// 测试里取响应头（`http.Response.headers` 是 List，没有 `header()` 访问器）。
fn resHeader(res: *const http.Response, name: []const u8) ?[]const u8 {
    for (res.headers.slice()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

test "M15: CORS defaults emit a literal '*', as gin-contrib/cors does" {
    // 审计 M15：Go 的三项 CORS 默认都是 `["*"]`
    // （`internal/conf/config.go:227-231`），gin-contrib/cors v1.7.7 只是
    // `strings.Join(normalize(list), ",")`（utils.go:29-43）⇒ 下发的是**字面
    // 的 `*`**。以前本工程把 `*` 展开成固定列表：Methods 缺 PATCH/HEAD、
    // Allow-Headers 只有 4 个 ⇒ 浏览器 WebDAV 预检带的 Depth / Destination /
    // Overwrite 直接被拒。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    const hdrs = try a.dupe(Header, &.{.{ .name = "Origin", .value = "https://example.com" }});
    const res = try doRequestWith(&app, a, "OPTIONS", "/api/me", "", hdrs);
    try testing.expectEqual(@as(u16, 204), res.status);
    try testing.expectEqualStrings("*", resHeader(res, "Access-Control-Allow-Origin").?);
    try testing.expectEqualStrings("*", resHeader(res, "Access-Control-Allow-Methods").?);
    try testing.expectEqualStrings("*", resHeader(res, "Access-Control-Allow-Headers").?);

    // 显式配了列表 ⇒ 原样 join，方法转大写（gin-contrib 的 convert/ToUpper）。
    const m = try joinListUpper(a, &[_][]const u8{ "get", "post" });
    try testing.expectEqualStrings("GET,POST", m);
}

test "M13: the configured admin token authenticates every authed endpoint" {
    // 审计 M13：Go 鉴权中间件的第一分支把 `Authorization` 头**整体**与
    // `setting.GetStr(conf.Token)` 比较（`server/middlewares/auth.go:19-31`），
    // 命中即视为管理员，**对所有** Auth 端点有效。以前只有
    // `/api/admin/user/del_cache` 认它。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg_dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(cfg_dir);
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{cfg_dir});
    defer testing.allocator.free(cfg_path);
    // `prev` 必须在 load **之前**取（load 自己会把单例指到新对象）。
    const prev = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev);
    try tcfg.putZig("token", .{ .string = try a.dupe(u8, "admintok-xyz") });

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    // 1) 不带 `Bearer ` 前缀的裸 token 必须是管理员
    const ok = try a.dupe(Header, &.{.{ .name = "Authorization", .value = "admintok-xyz" }});
    const res = try doRequestWith(&app, a, "GET", "/api/me", "", ok);
    try testing.expectEqual(@as(u16, 200), res.status);
    try testing.expect(std.mem.indexOf(u8, res.buf.slice(), "\"username\":\"admin\"") != null);

    // 2) `Bearer <token>` 不是 admin token（Go 比的是整个头值）⇒ 401
    const bearer = try a.dupe(Header, &.{.{ .name = "Authorization", .value = "Bearer admintok-xyz" }});
    try expectApiCode(try doRequestWith(&app, a, "GET", "/api/me", "", bearer), 401);

    // 3) 错 token / 无 token 都不能放行
    const bad = try a.dupe(Header, &.{.{ .name = "Authorization", .value = "nope" }});
    try expectApiCode(try doRequestWith(&app, a, "GET", "/api/me", "", bad), 401);
    try expectApiCode(try doRequest(&app, a, "GET", "/api/me"), 401);
}

test "M14: logout invalidates only the presented token" {
    // 审计 M14：Go 的 `LogOut` 调 `common.InvalidateToken` 让出示的那个令牌
    // 立刻失效（server/handles/auth.go:204-211 + server/common/auth.go:67-73）。
    // 以前这里只回成功信封，令牌在 exp 之前照旧能用。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    // 两枚**不同**的令牌：`mintTestToken` 的 payload 只含 username/pwd_ts/exp，
    // 同参数会得到同一枚（签名也一样），登出一个就等于登出两个。这里自己带
    // 一个 `nbf` 把 payload 撑开，保证签名不同、且 `pwd_ts` 仍是当前版本。
    const mint2 = struct {
        fn f(a_: std.mem.Allocator, secret: []const u8, user: []const u8, pwd_ts: i64, nbf: i64) ![]u8 {
            const exp: i64 = 4102444800; // 2100-01-01
            const h64 = try b64Url(a_, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
            var payload = Buf.init(a_);
            try payload.append("{\"username\":");
            try json.writeString(&payload, user);
            try payload.print(",\"pwd_ts\":{d},\"exp\":{d},\"iat\":{d},\"nbf\":{d}}}", .{ pwd_ts, exp, nbf, nbf });
            const p64 = try b64Url(a_, payload.slice());
            const signing_input = try std.fmt.allocPrint(a_, "{s}.{s}", .{ h64, p64 });
            const sig = try hmacSha256(a_, secret, signing_input);
            const s64 = try b64Url(a_, &sig);
            return std.fmt.allocPrint(a_, "{s}.{s}", .{ signing_input, s64 });
        }
    }.f;
    const t1 = try mint2(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts, 0);
    const t2 = try mint2(a, app.jwt_secret, app.admin_user, app.admin_pwd_ts, 1);
    try testing.expect(!std.mem.eql(u8, t1, t2));
    const h1 = try a.dupe(Header, &.{.{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{t1}) }});
    const h2 = try a.dupe(Header, &.{.{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{t2}) }});

    // 登出前两枚令牌都有效
    try testing.expectEqual(@as(u16, 200), (try doRequestWith(&app, a, "GET", "/api/me", "", h1)).status);
    try testing.expectEqual(@as(u16, 200), (try doRequestWith(&app, a, "GET", "/api/me", "", h2)).status);

    // 登出 t1
    try testing.expectEqual(@as(u16, 200), (try doRequestWith(&app, a, "GET", "/api/auth/logout", "", h1)).status);

    // t1 立刻失效；t2 不受影响（不是「推进 pwd_ts 把所有会话踢掉」）
    try expectApiCode(try doRequestWith(&app, a, "GET", "/api/me", "", h1), 401);
    try testing.expectEqual(@as(u16, 200), (try doRequestWith(&app, a, "GET", "/api/me", "", h2)).status);

    // 签名为空 / 结构不对的令牌不会误伤（jwtSignatureOf 直接返回 null）
    const junk = try a.dupe(Header, &.{.{ .name = "Authorization", .value = "Bearer a.b" }});
    var junk_req = http.Request{ .arena = a, .method = "GET", .path = "/", .target = "/", .headers = junk };
    try testing.expect(jwtSignatureOf(&junk_req) == null);
}

test "N1: anonymous browsing stays closed unless zig.guest_browse is on" {
    // 审计 N1：Go 默认允许 guest 浏览（`Auth(true)` = allowDisabledGuest）；
    // 本工程按用户拍板**默认收紧**，只提供显式开关 `zig.guest_browse`。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg_dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(cfg_dir);
    const cfg_path = try std.fmt.allocPrint(testing.allocator, "{s}/config.json", .{cfg_dir});
    defer testing.allocator.free(cfg_path);
    const prev = config.getOpt();
    const tcfg = try config.load(testing.allocator, cfg_path);
    defer tcfg.deinit();
    config.setForTest(tcfg);
    defer config.setForTest(prev);

    var fe = try frontend_mod.initFromHtml(a, .{}, ROUTING_SHELL);
    defer fe.deinit();
    var app = routingApp(a, fe);

    // 1) 默认（未开开关）：匿名访问只读端点一律 401
    try expectApiCode(try doRequest(&app, a, "POST", "/api/fs/list"), 401);
    try expectApiCode(try doRequest(&app, a, "POST", "/api/fs/get"), 401);

    // 2) 打开开关：匿名访问**只读**端点放行
    try tcfg.putZig("guest_browse", .{ .bool = true });
    try testing.expectEqual(@as(u16, 200), (try doRequest(&app, a, "POST", "/api/fs/list")).status);

    // 3) 写端点对游客仍然拒绝（游客 ≠ 管理员）
    try expectApiCode(try doRequest(&app, a, "POST", "/api/fs/mkdir"), 401);
    try expectApiCode(try doRequest(&app, a, "POST", "/api/fs/remove"), 401);
    try expectApiCode(try doRequest(&app, a, "POST", "/api/fs/put"), 401);
    // 4) 管理员私密端点也不对游客开放
    try expectApiCode(try doRequest(&app, a, "GET", "/api/me"), 401);

    // 5) 带了令牌却校验失败 ⇒ 依然 401（不是"匿名放行"）
    const bearer = try a.dupe(Header, &.{.{ .name = "Authorization", .value = "Bearer tampered.sig" }});
    try expectApiCode(try doRequestWith(&app, a, "POST", "/api/fs/list", "", bearer), 401);

    // 6) 关掉开关后立刻恢复收紧
    try tcfg.putZig("guest_browse", .{ .bool = false });
    try expectApiCode(try doRequest(&app, a, "POST", "/api/fs/list"), 401);
}
