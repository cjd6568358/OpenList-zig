//! `config.json` handling — an OpenList-compatible subset, plus write-back.
//!
//! Compatibility is a hard requirement, not a nicety. The whole point of this
//! exercise is to drop a smaller binary into an existing 光猫 image, so:
//!   * unknown keys in an existing `config.json` are preserved verbatim;
//!   * `storages[].addition` stays a JSON *string*, because that is what the
//!     Go build writes and what the frontend round-trips;
//!   * a missing config is created with sane defaults instead of aborting.
//!
//! Write-back matters because itvsh persists its session cookies into
//! `addition` after login (see `cookiejar.toJson`), which is how a 光猫
//! survives a reboot without re-authenticating.

const std = @import("std");
const json = @import("util/json.zig");
const model = @import("model.zig");
const log = @import("log.zig");
const Buf = @import("util/buf.zig").Buf;
const List = @import("util/buf.zig").List;
const rt = @import("rt.zig");

pub const Config = struct {
    /// Owns every string in this struct and the whole parsed document.
    arena: std.heap.ArenaAllocator,
    root: json.Value,
    path: []const u8,

    // scheme
    address: []const u8,
    http_port: i64,
    https_port: i64,
    force_https: bool,
    cert_file: []const u8,
    key_file: []const u8,

    site_url: []const u8,
    cdn: []const u8,
    /// Path to an on-disk OpenList frontend build (upstream's `dist_dir`).
    /// When set, `/assets`, `/images`, `/streamer` and `/static` are served
    /// from here and `index.html` is read from it, instead of falling back to
    /// the built-in placeholder page. See `frontend.zig`.
    dist_dir: []const u8,
    /// The frontend release this deployment targets. OpenList bakes this in at
    /// link time (`-X .../conf.WebVersion=`); a Zig build has no equivalent, so
    /// it lives in config. `$version` inside `cdn` expands to this with a
    /// leading `"v"` stripped, so `"v4.2.6"` pins and `"rolling"` tracks edge.
    web_version: []const u8,

    /// 备用前端 CDN 列表（`zig.cdn_fallbacks`，字符串数组）。
    ///
    /// 为什么需要：CDN 是**启动时的强依赖** —— 取不到 index.html 就
    /// `CdnIndexFetchFailed` 退出。而 jsdelivr 在大陆网络是**间歇性**可用的
    /// （实测同一 URL 时而 200、时而 `Connection reset by peer`／503）。
    /// 单点 CDN 意味着网络抖一下就起不来。
    ///
    /// 取值顺序：先 `cdn`，再按这里的顺序逐个试，每个重试若干次，
    /// 全失败才退出。留空数组即"只有 `cdn` 一个来源"（旧行为）。
    cdn_fallbacks: []const []const u8,
    jwt_secret: []const u8,
    token_expires_in: i64,

    /// 下载签名（`internal/sign` / `server/common/sign.go`）。
    /// `sign_all` 为 true 时**所有** `/d/` 路径都要求 `?sign=`；
    /// `link_expiration` 是签名有效期（小时，0 = 永不过期）。
    /// 两者默认值均与 Go 的 setting 默认（false / 0）一致。
    sign_all: bool,
    link_expiration: i64,
    /// `proxy_types`：命中这些扩展名的文件下载时**强制服务端代理**
    /// （Go `ShouldProxy` 第二分支，默认 `m3u8,url`）。扩展名小写、不带点，
    /// 逗号分隔；条目不做 trim（与 Go `strings.Split` 一致）。
    proxy_types: []const u8,
    /// `text_types`：文本文件扩展名列表（Go 设置默认 32 项，见
    /// `internal/bootstrap/data/setting.go:128`）。它**不参与** `/d/` 的
    /// `ShouldProxy` 判定，只参与 `/p/`（Proxy 端点）的 `canProxy` 准入
    /// —— 不在列表里的文件访问 `/p/` 会得到 403 `proxy not allowed`。
    text_types: []const u8,

    temp_dir: []const u8,
    tls_insecure_skip_verify: bool,
    max_connections: i64,
    max_concurrency: i64,
    /// Go `conf.Conf.DelayedStart`（`internal/bootstrap/run.go:88-90`）：
    /// 启动时先 `time.Sleep(秒)` 再加载存储/监听。0 = 不延迟。
    delayed_start: i64,

    /// Go `conf.Conf.Cors`（`server/router.go:255-260` 的 gin cors 中间件）。
    /// 默认全部 `["*"]` = 通配。详见 api.zig 的 `setCors`。
    cors_allow_origins: []const []const u8,
    cors_allow_methods: []const []const u8,
    cors_allow_headers: []const []const u8,

    /// N1（审计）：是否允许**匿名（游客）只读**浏览。
    ///
    /// Go 的 `fs/list` / `fs/get` 是**双挂载**：`_fs(auth.Group("/fs"))`（要登录）
    /// 与 `fsAndShare(api.Group("/fs", middlewares.Auth(true)))`（`Auth(true)` =
    /// allowDisabledGuest）。`server/middlewares/auth.go:32-48`：空 token ⇒ guest
    /// 用户，仅当 guest 被禁用才 401 ⇒ **默认部署下匿名可列目录**。
    ///
    /// Zig 是单管理员模型，匿名浏览属于**产品取舍**（光猫暴露面）。这里做成
    /// 开关：**默认 false = 收紧（空 token 一律 401）**，显式开启后空 token
    /// 才按游客放行，且**只放行只读端点**（fs/list、fs/get；下载仍走签名），
    /// 任何写操作对游客照旧 401。
    guest_browse: bool,

    // 刻意**不**建模的配置项：`tasks`（离线下载/转存任务系统的 worker 池配置）。
    // 本构建没有任务系统，读进来也无处使用；`root` 保留原始文档，
    // `save()` 序列化时其余键原样带回，字段不会丢 —— 属合理子集
    // （见 TODO §5 与 STATUS §22 的功能边界）。

    log_enable: bool,
    log_name: []const u8,

    storages: []model.Storage,

    /// Zig-only extension block (`"zig": {...}`). The Go build ignores it, so
    /// the same config file stays valid for both.
    ca_bundle: []const u8,
    http_timeout: i64,

    /// Frontend presentation. OpenList keeps these in its settings table and
    /// rewrites `index.html` from them at startup; this build has no database,
    /// so they are static config. Defaults match OpenList's fresh install (see
    /// `internal/bootstrap/data/setting.go`), which makes the placeholder
    /// substitution a no-op until an operator overrides something.
    site_title: []const u8,
    main_color: []const u8,
    logo: []const u8,
    favicon: []const u8,
    customize_head: []const u8,
    customize_body: []const u8,

    pub fn allocator(self: *Config) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Frees everything `load` allocated, including the `Config` itself.
    pub fn deinit(self: *Config) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self);
    }

    /// Look up a raw key path in the preserved document, for fields this
    /// binary does not model but a plugin or the frontend may need.
    pub fn raw(self: *const Config, path: []const u8) ?*const json.Value {
        return self.root.getPath(path);
    }

    /// Deep-copy `v` into `a`, so the result owns every byte it points at.
    ///
    /// 配置文档活得比任何单个请求都久，所以任何从 request arena 进来的值都
    /// 必须先过这里 —— 只存引用会在请求结束时留下悬空指针。
    fn cloneValue(a: std.mem.Allocator, v: json.Value) !json.Value {
        return switch (v) {
            .string => |s| json.Value{ .string = try a.dupe(u8, s) },
            .array => |arr| blk: {
                const out = try a.alloc(json.Value, arr.len);
                for (arr, 0..) |item, i| out[i] = try cloneValue(a, item);
                break :blk json.Value{ .array = out };
            },
            .object => |o| blk: {
                const keys = try a.alloc([]const u8, o.keys.len);
                const vals = try a.alloc(json.Value, o.vals.len);
                for (o.keys, 0..) |k, i| keys[i] = try a.dupe(u8, k);
                for (o.vals, 0..) |item, i| vals[i] = try cloneValue(a, item);
                break :blk json.Value{ .object = .{ .keys = keys, .vals = vals } };
            },
            // 标量本身没有指向外部内存的指针，按值复制即可。
            else => v,
        };
    }

    /// Set `zig.<key>`. Used by the first-run admin flow, which stores the
    /// admin username and password hash under `zig` so the Go build ignores
    /// them entirely. Creates the `zig` object if the file predates it.
    pub fn putZig(self: *Config, key: []const u8, val: json.Value) !void {
        const a = self.arena.allocator();
        const root_obj = self.root.asObject() orelse return error.InvalidConfig;
        const mut = @constCast(root_obj);

        // M16：与 `save()` 的 `json.stringify` 互斥。以前 putZig 无锁改 root
        // 对象（重分配 keys/vals），而驱动 persist / 会话刷新的 save() 可能
        // 正在序列化同一份文档 ⇒ 写出丢键/半新半旧的 config.json。
        // 锁序恒 g_save_mutex → storages_mutex（见文件头）：putZig 不拿
        // storages_mutex，不会成环；所有调用方（setup/改密码/设置保存/启动）
        // 均不持锁进入，无重入死锁。
        g_save_mutex.lockUncancelable(rt.io());
        defer g_save_mutex.unlock(rt.io());

        // 所有权契约：`putZig` **深拷贝**它收下的值。
        //
        // 调用方（api.handleInitSetup）用的是 request arena —— 请求一结束那块
        // 内存就被释放，而配置要活到进程结束。以前这里只 dupe 了 key、原样
        // 存 value，于是 `zig.admin_user` / `zig.admin_password_hash` 变成悬空
        // 引用：下一次 `cfg.save()`（改设置、驱动 persist、会话刷新）就会去读
        // 已释放的内存。现在字符串与嵌套结构都归配置 arena 所有。
        const owned = try cloneValue(a, val);

        for (mut.keys, 0..) |k, i| {
            if (!std.mem.eql(u8, k, "zig")) continue;
            const zig_obj = mut.vals[i].asObject() orelse break;
            const zmut = @constCast(zig_obj);
            for (zmut.keys, 0..) |zk, zi| {
                if (std.mem.eql(u8, zk, key)) {
                    zmut.vals[zi] = owned;
                    return;
                }
            }
            var nk = try a.alloc([]const u8, zmut.keys.len + 1);
            var nv = try a.alloc(json.Value, zmut.vals.len + 1);
            @memcpy(nk[0..zmut.keys.len], zmut.keys);
            @memcpy(nv[0..zmut.vals.len], zmut.vals);
            nk[zmut.keys.len] = try a.dupe(u8, key);
            nv[zmut.vals.len] = owned;
            zmut.keys = nk;
            zmut.vals = nv;
            return;
        }
        // No `zig` block yet: create one with this single key.
        const keys = try a.dupe([]const u8, &.{try a.dupe(u8, key)});
        const vals = try a.dupe(json.Value, &.{owned});
        try setTopLevelRaw(a, &self.root, "zig", .{ .object = .{ .keys = keys, .vals = vals } });
    }

    pub fn storageById(self: *Config, id: i64) ?*model.Storage {
        for (self.storages) |*s| {
            if (s.id == id) return s;
        }
        return null;
    }

    /// 记录某条存储的运行时初始化错误（`error_msg` 不落盘 —— `syncStorages`
    /// 刻意不序列化它，与 Go 的「DB status 字段」对齐的展示层另行合成）。
    /// 供启动 worker 与 `/api/admin/storage/*` 写入；错误字符串归配置 arena
    /// 所有，因此能活过后续的 slice 重排。
    ///
    /// 内部自取 `storages_mutex`，所以可以在任何持锁状态外调用。
    pub fn setStorageError(self: *Config, id: i64, msg: []const u8) void {
        const io = rt.io();
        storages_mutex.lockUncancelable(io);
        defer storages_mutex.unlock(io);
        const s = self.storageById(id) orelse return;
        const a = self.arena.allocator();
        s.error_msg = a.dupe(u8, msg) catch "";
    }

    /// 清除某条存储的运行时错误（改配置重试 init 前）。与 `setStorageError`
    /// 一样自取锁。
    pub fn clearStorageError(self: *Config, id: i64) void {
        const io = rt.io();
        storages_mutex.lockUncancelable(io);
        defer storages_mutex.unlock(io);
        const s = self.storageById(id) orelse return;
        s.error_msg = "";
    }

    /// Set a top-level config key (used by the settings PUT for `site_url`,
    /// `cdn`, `token_expires_in`, ...). Values must already live in the config
    /// arena — see the callers in `api.zig`, which dupe into `cfg.allocator()`.
    pub fn setTopLevel(self: *Config, key: []const u8, val: json.Value) !void {
        const a = self.arena.allocator();
        try setTopLevelRaw(a, &self.root, key, val);
    }

    /// Serialize the document back to disk atomically (tmp + rename), so a
    /// power cut mid-write cannot leave a truncated config on the device.
    ///
    /// T6：存储初始化搬到后台线程后，itvsh 这类「init 期间就回写 cookie」的
    /// 驱动会和请求线程的 settings 保存并发 —— 两个 save 同时序列化同一份
    /// 文档会读到写了一半的字段。加一把进程级锁把这个竞态类整体关掉。
    pub fn save(self: *Config) !void {
        const io = rt.io();
        g_save_mutex.lockUncancelable(io);
        defer g_save_mutex.unlock(io);
        try self.syncStorages();

        // M04：序列化结果和临时路径都是**短命**数据。以前它们被分配进
        // 配置的长期 arena，于是每次 `save()` 都永久留下一份完整的配置文本
        // 和一份 tmp 路径 —— 驱动每刷新一次 token 就 save 一次，长跑必涨。
        // 用一个挂在配置 arena 父分配器下的 scratch arena，出函数即回收。
        var scratch = std.heap.ArenaAllocator.init(self.arena.child_allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const text = try json.stringify(sa, &self.root);

        var tmp = Buf.init(sa);
        try tmp.append(self.path);
        try tmp.append(".tmp");
        const tmp_path = try tmp.toOwnedZ();

        // 0.17: every one of these takes the `Io` handle, and `File.close` /
        // `File.sync` became free functions on `std.Io.File` (callable with
        // method syntax because their first parameter is the file).
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.createFile(io, tmp_path, .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, text);
        try f.sync(io);
        try cwd.rename(tmp_path, cwd, self.path, io);
    }

    /// Push the in-memory `storages` slice back into the JSON document.
    /// M04：以前这里把所有错误都 `catch return` / `catch {}` 吞掉，OOM 会被
    /// 静默当成"保存成功"。现在错误向上传播，`save()` 的调用方能知道失败。
    ///
    /// 读 `self.storages` 前自取 `storages_mutex`：序列化期间不能有并发写
    /// （后台驱动的 `persist` 回写 cookie / 管理面增删改），否则可能把撕裂的
    /// slice 头或半新半旧的字符串写进文件。锁序恒为 g_save_mutex →
    /// storages_mutex（`save` 先拿 g_save），调用方绝不能反序。
    fn syncStorages(self: *Config) !void {
        const io = rt.io();
        storages_mutex.lockUncancelable(io);
        defer storages_mutex.unlock(io);

        const a = self.arena.allocator();
        var vals = List(json.Value).init(a);
        for (self.storages) |s| {
            const keys = try a.dupe([]const u8, &.{
                "id",     "mount_path", "order",  "driver",   "cache_expiration",
                "status", "addition",   "remark", "disabled", "web_proxy",
                "webdav_policy", "down_proxy_url", "disable_proxy_sign",
                "modified",
            });
            const fields = try a.dupe(json.Value, &.{
                .{ .int = s.id },
                .{ .string = s.mount_path },
                .{ .int = s.order },
                .{ .string = s.driver },
                .{ .int = s.cache_expiration },
                .{ .string = s.status },
                .{ .string = s.addition },
                .{ .string = s.remark },
                .{ .bool = s.disabled },
                .{ .bool = s.web_proxy },
                .{ .string = s.webdav_policy },
                .{ .string = s.down_proxy_url },
                .{ .bool = s.disable_proxy_sign },
                .{ .string = try rfc3339FromUnix(a, s.modified) },
            });
            try vals.append(.{ .object = .{ .keys = keys, .vals = fields } });
        }
        const arr = json.Value{ .array = try a.dupe(json.Value, vals.slice()) };
        try setTopLevelRaw(a, &self.root, "storages", arr);
    }
};

// ---------------------------------------------------------------------------
// RFC3339 时间：Go 的 `time.Time` JSON 形态（`Storage.Modified`、文件条目都
// 用它）。格式 `YYYY-MM-DDTHH:MM:SS[.frac](Z|±HH:MM)`；这里只做 seconds 精度，
// 分数秒在解析时截断、输出时不带（前端 `new Date()` 全都能解析）。
// ---------------------------------------------------------------------------

/// Unix 秒 → RFC3339（UTC，`Z`），写入调用者的缓冲（≥24 字节）。0 = Go 零值。
/// 不分配 —— 无分配器的调用点（如 api.zig 的存储 JSON 序列化）直接用。
pub fn rfc3339(out: []u8, ts: i64) []const u8 {
    if (ts == 0) return "0001-01-01T00:00:00Z";
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(ts, 0)) };
    const day = es.getEpochDay();
    const ds = es.getDaySeconds();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch "0001-01-01T00:00:00Z";
}

/// 分配版本（config arena / 请求 arena 用）。
pub fn rfc3339FromUnix(a: std.mem.Allocator, ts: i64) ![]const u8 {
    if (ts == 0) return "0001-01-01T00:00:00Z";
    return rfc3339(try a.alloc(u8, 24), ts);
}

/// RFC3339 → Unix 秒。解析失败返回 null（调用方按「无此字段」处理）。
/// 支持 `Z` 与 `±HH:MM` 偏移、可选小数秒；日期部分用 `std.time.epoch` 反推，
/// 偏移部分直接从 UTC 秒里加减。
pub fn rfc3339ToUnix(s: []const u8) ?i64 {
    // 最短形态 "YYYY-MM-DDTHH:MM:SSZ" = 20 字符。
    if (s.len < 20) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    // 剩余部分：小数秒 / 时区。
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    var offset_secs: i64 = 0;
    if (i >= s.len) return null;
    if (s[i] == 'Z' or s[i] == 'z') {
        if (i + 1 != s.len) return null;
    } else if (s[i] == '+' or s[i] == '-') {
        if (i + 6 != s.len or s[i + 3] != ':') return null;
        const oh = std.fmt.parseInt(i64, s[i + 1 .. i + 3], 10) catch return null;
        const om = std.fmt.parseInt(i64, s[i + 4 .. i + 6], 10) catch return null;
        if (oh > 23 or om > 59) return null;
        offset_secs = oh * 3600 + om * 60;
        if (s[i] == '-') offset_secs = -offset_secs;
    } else return null;

    // 天数：Go 的 epoch 日算法（1-1-1 = day 0）。
    const epoch_year: u16 = 1970;
    if (year < epoch_year) return null;
    const leap_test = struct {
        fn f(y: u16) bool {
            return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
        }
    }.f;
    const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var days: i64 = 0;
    var y: u16 = epoch_year;
    while (y < year) : (y += 1) {
        days += if (leap_test(y)) 366 else 365;
    }
    const max_day: u8 = if (month == 2 and leap_test(year)) 29 else month_days[month - 1];
    if (day > max_day) return null;
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += if (m == 2 and leap_test(year)) 29 else month_days[m - 1];
    }
    days += day - 1;
    const unix = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second - offset_secs;
    return unix;
}

// ---------------------------------------------------------------------------

var g_config: ?*Config = null;

/// 序列化/落盘的进程级互斥。只有一个 Config 实例（进程生命周期），
/// 所以一把静态锁就够；保护的是「文档内存」而不是某个 Config 字段。
/// 0.17 的 `std.Thread.Mutex` 已并入 `std.Io.Mutex`（lock/unlock 需要 io）。
var g_save_mutex: std.Io.Mutex = .init;

/// `cfg.storages` 切片结构 **及每个元素字段** 的互斥锁。
///
/// 为什么需要：三条路径会在运行时并发碰这张表 ——
///   * 后台驱动的 `persist` 回写（itvsh 刷 token/cookie 时改 `addition`）；
///   * `/api/admin/storage/*` 的增删改（append/remove/字段替换）；
///   * `save()` → `syncStorages` 序列化读。
/// 任两者重叠都可能读到撕裂的 slice 头/半新半旧的字符串。
///
/// **锁序（必须遵守，否则死锁）**：
///   1. `g_save_mutex` → `storages_mutex`（`save` 路径，syncStorages 内部）；
///   2. 调用方绝不能在持有 `storages_mutex` 时去拿 `g_save_mutex`；
///      正确姿势是「锁内改完 → 解锁 → 再 save()」，参见 api.zig 的处理器
///      与 main.zig 的 `persistStorage`。
/// 与 `App.storage_ops_lock`（api.zig，串行化挂载重建+发布）是两把不同的
/// 锁，后者的临界区里可以短暂拿本锁，但反过来不行。
var storages_mutex: std.Io.Mutex = .init;

/// 进入 `cfg.storages` 临界区。管理面处理器与 `persistStorage` 用；
/// `setStorageError` / `clearStorageError` / `syncStorages` 内部自取，
/// 调用它们时**不要**已持有本锁（非重入锁会死锁）。
pub fn lockStorages() void {
    storages_mutex.lockUncancelable(rt.io());
}

pub fn unlockStorages() void {
    storages_mutex.unlock(rt.io());
}

pub fn get() *Config {
    return g_config orelse @panic("config not initialised");
}

pub fn isLoaded() bool {
    return g_config != null;
}

/// 单例可能为 null（进程刚起来、或单元测试没有 load 过配置）。调用方拿它
/// 当「可选值」用时走这个，比 `get()` 的 panic 友好 —— 下载签名这类
/// 「没有配置就用默认行为」的场合特别合适。
pub fn getOpt() ?*Config {
    return g_config;
}

/// 把单例指向调用方给的 Config（仅供测试使用）。
///
/// 存在的理由：`load` 只赋值不清零，而 `config.zig` 自己的测试会 `deinit()`
/// 刚 load 出来的 Config —— `g_config` 于是指向已释放内存，之后任何
/// `config.get()` 都是 use-after-free（实测：读到垃圾 `link_expiration`，
/// 乘法直接 integer overflow panic）。
///
/// 测试用法：`defer config.setForTest(null)` 收尾，或注入一份自己 load 的。
pub fn setForTest(cfg: ?*Config) void {
    g_config = cfg;
}

/// Load `<data_dir>/config.json`, creating it with defaults when absent.
pub fn load(alloc: std.mem.Allocator, path: []const u8) !*Config {
    const cfg = try alloc.create(Config);
    // M04：原来 `create` 之后没有任何 errdefer。读文件失败、JSON 非法、
    // 根不是对象……每一条失败路径都会把 Config 本体和整个 arena 漏在
    // 父分配器上。启动时反复重载配置（配置热更新）就会持续泄漏。
    errdefer alloc.destroy(cfg);
    cfg.arena = std.heap.ArenaAllocator.init(alloc);
    errdefer cfg.arena.deinit();
    const a = cfg.arena.allocator();
    cfg.path = try a.dupe(u8, path);

    const text: []u8 = std.Io.Dir.cwd().readFileAlloc(rt.io(), path, a, .limited(8 * 1024 * 1024)) catch |e| switch (e) {
        error.FileNotFound => blk: {
            log.info("config: {s} not found, writing defaults", .{path});
            const fresh = try a.dupe(u8, DEFAULT_CONFIG);
            try writeFile(path, fresh);
            break :blk fresh;
        },
        else => return e,
    };

    // A poisoned config is a real scenario: an earlier bug once wrote raw
    // response-body bytes (invalid UTF-8) into this file via the itvsh cookie
    // jar. The JSON parser copies bytes verbatim, so it would happily build a
    // Value tree full of broken strings — refuse instead of guessing.
    if (!std.unicode.utf8ValidateSlice(text)) {
        log.err("config: {s} is not valid UTF-8 (corrupt file? refusing to load)", .{path});
        return error.InvalidConfig;
    }

    cfg.root = json.parse(a, text) catch |e| {
        log.err("config: {s} is not valid JSON: {s}", .{ path, @errorName(e) });
        return error.InvalidConfig;
    };
    if (cfg.root.asObject() == null) {
        log.err("config: {s} must be a JSON object", .{path});
        return error.InvalidConfig;
    }

    // ---- scheme ----
    cfg.address = str(cfg.root.getPath("scheme.address"), "0.0.0.0");
    cfg.http_port = int(cfg.root.getPath("scheme.http_port"), 5244);
    cfg.https_port = int(cfg.root.getPath("scheme.https_port"), -1);
    cfg.force_https = boolean(cfg.root.getPath("scheme.force_https"), false);
    cfg.cert_file = str(cfg.root.getPath("scheme.cert_file"), "");
    cfg.key_file = str(cfg.root.getPath("scheme.key_file"), "");

    cfg.site_url = str(cfg.root.getPath("site_url"), "");
    cfg.cdn = str(cfg.root.getPath("cdn"), "");
    cfg.dist_dir = str(cfg.root.getPath("dist_dir"), "");
    cfg.web_version = str(cfg.root.getPath("zig.web_version"), "rolling");
    // 备用 CDN 列表。接受两种写法：
    //   ["a","b"]        字符串数组（推荐）
    //   "a,b"            逗号分隔字符串（写起来方便，Go 版也能当普通字符串忽略）
    // 空串 / 空数组都表示"没有备用"。
    cfg.cdn_fallbacks = try parseStringList(cfg.allocator(), cfg.root.getPath("zig.cdn_fallbacks"));
    cfg.token_expires_in = int(cfg.root.getPath("token_expires_in"), 48);
    // 下载签名开关。放在 `zig` 块里而不是顶层：这两个是 Zig 侧才能持久化的
    // 设置（Go 侧存在数据库 settings 表），且 Go 版会原样忽略未知的 `zig` 键，
    // 同一份配置文件因此对两个版本都有效。
    // M1：默认值对齐 Go `internal/bootstrap/data/setting.go:171`（Value:"true"）——
    // 以前默认 false，等于全新部署默认公开可下载，安全姿态与 Go 相反。
    cfg.sign_all = boolean(cfg.root.getPath("zig.sign_all"), true);
    cfg.link_expiration = int(cfg.root.getPath("zig.link_expiration"), 0);
    cfg.proxy_types = str(cfg.root.getPath("zig.proxy_types"), "m3u8,url");
    // Go `internal/bootstrap/data/setting.go:128` 的默认值，一字不差。
    cfg.text_types = str(cfg.root.getPath("zig.text_types"), "txt,htm,html,xml,java,properties,sql,js,md,json,conf,ini,vue,php,py,bat,gitignore,yml,go,sh,c,cpp,h,hpp,tsx,vtt,srt,ass,rs,lrc,strm");
    cfg.temp_dir = str(cfg.root.getPath("temp_dir"), "data/temp");
    cfg.tls_insecure_skip_verify = boolean(cfg.root.getPath("tls_insecure_skip_verify"), false);
    cfg.max_connections = int(cfg.root.getPath("max_connections"), 0);
    cfg.max_concurrency = int(cfg.root.getPath("max_concurrency"), 64);
    cfg.delayed_start = int(cfg.root.getPath("delayed_start"), 0);
    // `cors.allow_origins/methods/headers`：字符串数组；缺省/空 → `["*"]`
    // （Go `cors.DefaultConfig` + 上游把三项都设成 `["*"]` 的默认形态）。
    cfg.cors_allow_origins = try parseStringListDefaultStar(cfg.allocator(), cfg.root.getPath("cors.allow_origins"));
    cfg.cors_allow_methods = try parseStringListDefaultStar(cfg.allocator(), cfg.root.getPath("cors.allow_methods"));
    cfg.cors_allow_headers = try parseStringListDefaultStar(cfg.allocator(), cfg.root.getPath("cors.allow_headers"));
    // N1：匿名只读浏览开关（默认关 = 与单管理员收紧姿态一致）。Go 侧默认开
    // （guest 用户），本工程把它变成显式选择项，见 STATUS §22.1。
    cfg.guest_browse = boolean(cfg.root.getPath("zig.guest_browse"), false);

    cfg.log_enable = boolean(cfg.root.getPath("log.enable"), true);
    cfg.log_name = str(cfg.root.getPath("log.name"), "data/log/log.log");

    cfg.ca_bundle = str(cfg.root.getPath("zig.ca_bundle"), "");
    cfg.http_timeout = int(cfg.root.getPath("zig.http_timeout"), 60);

    cfg.site_title = str(cfg.root.getPath("zig.site_title"), "OpenList (zig)");
    cfg.main_color = str(cfg.root.getPath("zig.main_color"), "#1890ff");
    cfg.logo = str(cfg.root.getPath("zig.logo"), "https://res.oplist.org/logo/logo.svg");
    cfg.favicon = str(cfg.root.getPath("zig.favicon"), "https://res.oplist.org/logo/logo.svg");
    cfg.customize_head = str(cfg.root.getPath("zig.customize_head"), "");
    cfg.customize_body = str(cfg.root.getPath("zig.customize_body"), "");

    // jwt_secret: OpenList generates one on first run. A fixed empty secret
    // would let anyone mint tokens, so generate and persist if absent.
    cfg.jwt_secret = str(cfg.root.getPath("jwt_secret"), "");
    var generated_secret = false;
    if (cfg.jwt_secret.len == 0) {
        cfg.jwt_secret = try randomSecret(a);
        try setTopLevelRaw(a, &cfg.root, "jwt_secret", .{ .string = cfg.jwt_secret });
        generated_secret = true;
    }

    // ---- storages ----
    cfg.storages = try parseStorages(a, cfg.root.getPath("storages"));

    g_config = cfg;
    // Persist the generated secret (and the file skeleton) immediately, so the
    // first restart reuses the same signing key. A secret that changes on
    // every boot silently invalidates every issued token.
    if (generated_secret) cfg.save() catch |e| {
        log.warn("config: could not persist generated jwt_secret: {s}", .{@errorName(e)});
    };
    return cfg;
}

/// 字符串列表读取：接受 JSON 字符串数组，或逗号/空格分隔的单个字符串。
///
/// 两种都收是为了好用：数组是规范写法，而逗号串在 config.json 里手写更省事，
/// 且 Go 版读到 `zig` 下的未知键会原样忽略，同一份配置对两个版本都有效。
fn parseStringList(a: std.mem.Allocator, v: ?*const json.Value) ![]const []const u8 {
    const val = v orelse return &.{};
    if (val.asArray()) |arr| {
        var out = try a.alloc([]const u8, arr.len);
        var n: usize = 0;
        for (arr) |*item| {
            const s = item.asStr() orelse continue;
            if (s.len == 0) continue;
            out[n] = try a.dupe(u8, s);
            n += 1;
        }
        return out[0..n];
    }
    if (val.asStr()) |raw| {
        // 两遍扫描而不是 ArrayList：0.17 的 `ArrayList.init` 已不存在，
        // 而这里元素数一眼可数，先数再分配更省事也更省内存。
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, raw, ", \t\n");
        while (it.next()) |_| count += 1;
        var out = try a.alloc([]const u8, count);
        var n: usize = 0;
        var it2 = std.mem.tokenizeAny(u8, raw, ", \t\n");
        while (it2.next()) |tok| {
            out[n] = try a.dupe(u8, tok);
            n += 1;
        }
        return out;
    }
    return &.{};
}

/// 同 `parseStringList`，但空结果回退到 `["*"]` —— CORS 三兄弟的默认值
/// （Go `cors.DefaultConfig` + 上游默认把三项都设 `["*"]`）。
fn parseStringListDefaultStar(a: std.mem.Allocator, v: ?*const json.Value) ![]const []const u8 {
    const out = try parseStringList(a, v);
    if (out.len == 0) return &[_][]const u8{"*"};
    return out;
}

fn parseStorages(a: std.mem.Allocator, v: ?*const json.Value) ![]model.Storage {    const arr = if (v) |x| (x.asArray() orelse return &.{}) else return &.{};
    var out = try a.alloc(model.Storage, arr.len);
    var n: usize = 0;
    for (arr) |*item| {
        if (item.asObject() == null) continue;
        out[n] = .{
            .id = item.intAt("id") orelse 0,
            .mount_path = str(item.getPath("mount_path"), "/"),
            .order = item.intAt("order") orelse 0,
            .driver = str(item.getPath("driver"), ""),
            .cache_expiration = item.intAt("cache_expiration") orelse 0,
            .status = str(item.getPath("status"), "work"),
            .addition = str(item.getPath("addition"), "{}"),
            .remark = str(item.getPath("remark"), ""),
            .disabled = boolean(item.getPath("disabled"), false),
            .web_proxy = boolean(item.getPath("web_proxy"), false),
            .webdav_policy = str(item.getPath("webdav_policy"), ""),
            .down_proxy_url = str(item.getPath("down_proxy_url"), ""),
            .disable_proxy_sign = boolean(item.getPath("disable_proxy_sign"), false),
            // Go 备份里是 RFC3339（带纳秒+时区，如 2026-09-26T18:10:34.436+08:00）；
            // 缺失/解析失败按零值（Go 零值时间）处理，不拒绝整份配置。
            .modified = if (item.strAt("modified")) |m| (rfc3339ToUnix(m) orelse 0) else 0,
        };
        n += 1;
    }
    return out[0..n];
}

fn str(v: ?*const json.Value, default: []const u8) []const u8 {
    const x = v orelse return default;
    return x.asStr() orelse default;
}

fn int(v: ?*const json.Value, default: i64) i64 {
    const x = v orelse return default;
    return x.asInt() orelse default;
}

fn boolean(v: ?*const json.Value, default: bool) bool {
    const x = v orelse return default;
    return x.asBool() orelse default;
}

fn setTopLevelRaw(a: std.mem.Allocator, root: *json.Value, key: []const u8, val: json.Value) !void {
    const obj = root.asObject() orelse return error.InvalidConfig;
    const mut = @constCast(obj);
    for (mut.keys, 0..) |k, i| {
        if (std.mem.eql(u8, k, key)) {
            mut.vals[i] = val;
            return;
        }
    }
    var nk = try a.alloc([]const u8, mut.keys.len + 1);
    var nv = try a.alloc(json.Value, mut.vals.len + 1);
    @memcpy(nk[0..mut.keys.len], mut.keys);
    @memcpy(nv[0..mut.vals.len], mut.vals);
    nk[mut.keys.len] = key;
    nv[mut.vals.len] = val;
    mut.keys = nk;
    mut.vals = nv;
}

fn randomSecret(a: std.mem.Allocator) ![]u8 {
    var raw: [32]u8 = undefined;
    // 0.17 removed `std.crypto.random`; entropy is now requested through the
    // `Io` handle. `Io.Threaded.random` is a ChaCha CSPRNG seeded from
    // `randomSecure` (i.e. from the OS), so it is a drop-in for a JWT secret.
    rt.io().random(&raw);
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const out = try a.alloc(u8, 32);
    for (&raw, 0..) |b, i| out[i] = alphabet[b % alphabet.len];
    return out;
}

fn writeFile(path: []const u8, text: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const io = rt.io();
    if (std.fs.path.dirname(path)) |d| {
        if (d.len > 0) cwd.createDirPath(io, d) catch {};
    }
    const f = try cwd.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, text);
}

/// Mirrors OpenList's `conf.DefaultConfig` for the fields we model, so a fresh
/// install behaves the same as the Go build's fresh install.
pub const DEFAULT_CONFIG =
    \\{
    \\  "force": false,
    \\  "site_url": "",
    \\  "cdn": "",
    \\  "dist_dir": "",
    \\  "jwt_secret": "",
    \\  "token_expires_in": 48,
    \\  "database": {
    \\    "type": "sqlite3",
    \\    "host": "",
    \\    "port": 0,
    \\    "user": "",
    \\    "password": "",
    \\    "name": "",
    \\    "db_file": "data/data.db",
    \\    "table_prefix": "x_",
    \\    "ssl_mode": ""
    \\  },
    \\  "scheme": {
    \\    "address": "0.0.0.0",
    \\    "http_port": 5244,
    \\    "https_port": -1,
    \\    "force_https": false,
    \\    "cert_file": "",
    \\    "key_file": "",
    \\    "unix_file": "",
    \\    "unix_file_perm": "",
    \\    "enable_h2c": false
    \\  },
    \\  "temp_dir": "data/temp",
    \\  "bleve_dir": "data/bleve",
    \\  "log": {
    \\    "enable": true,
    \\    "name": "data/log/log.log",
    \\    "max_size": 10,
    \\    "max_backups": 5,
    \\    "max_age": 28,
    \\    "compress": false
    \\  },
    \\  "delayed_start": 0,
    \\  "max_connections": 0,
    \\  "max_concurrency": 64,
    \\  "tls_insecure_skip_verify": false,
    \\  "zig": {
    \\    "ca_bundle": "",
    \\    "http_timeout": 60,
    \\    "web_version": "rolling",
    \\    "cdn_fallbacks": [],
    \\    "site_title": "OpenList (zig)",
    \\    "main_color": "#1890ff",
    \\    "logo": "https://res.oplist.org/logo/logo.svg",
    \\    "favicon": "https://res.oplist.org/logo/logo.svg",
    \\    "customize_head": "",
    \\    "customize_body": ""
    \\  },
    \\  "storages": []
    \\}
;

// ---------------------------------------------------------------------------

const testing = std.testing;

test "load creates defaults then round-trips" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "config.json" });
    defer testing.allocator.free(path);

    const cfg = try load(testing.allocator, path);
    defer cfg.deinit();
    // `load` 会把单例指到 cfg；deinit 之后 g_config 就悬空了。把它按回
    // 局部变量，否则本测试之后任何 config.get() 都是 use-after-free。
    setForTest(cfg);
    defer setForTest(null);

    try testing.expectEqual(@as(i64, 5244), cfg.http_port);
    try testing.expectEqualStrings("0.0.0.0", cfg.address);
    try testing.expect(cfg.jwt_secret.len > 0);
    try testing.expectEqual(@as(usize, 0), cfg.storages.len);

    // written file must be parseable and carry the generated secret
    const back = try std.Io.Dir.cwd().readFileAlloc(rt.io(), path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(back);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try json.parse(arena.allocator(), back);
    try testing.expectEqualStrings(cfg.jwt_secret, v.strAt("jwt_secret").?);
}

test "unknown keys survive a save" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "config.json" });
    defer testing.allocator.free(path);

    try std.Io.Dir.cwd().writeFile(rt.io(), .{ .sub_path = path, .data =
        \\{"jwt_secret":"x","custom_future_key":{"a":1},"storages":[]}
    });

    const cfg = try load(testing.allocator, path);
    defer cfg.deinit();
    // `load` 会把单例指到 cfg；deinit 之后 g_config 就悬空了。把它按回
    // 局部变量，否则本测试之后任何 config.get() 都是 use-after-free。
    setForTest(cfg);
    defer setForTest(null);
    try cfg.save();

    const back = try std.Io.Dir.cwd().readFileAlloc(rt.io(), path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(back);
    try testing.expect(std.mem.indexOf(u8, back, "custom_future_key") != null);
    try testing.expect(std.mem.indexOf(u8, back, "\"a\":1") != null);
}

test "storages parse with addition as a string" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "config.json" });
    defer testing.allocator.free(path);

    try std.Io.Dir.cwd().writeFile(rt.io(), .{ .sub_path = path, .data =
        \\{"jwt_secret":"x","storages":[
        \\ {"id":1,"mount_path":"/nas","order":0,"driver":"Itvsh",
        \\  "addition":"{\"mobile\":\"13800000000\"}","status":"work"}]}
    });

    const cfg = try load(testing.allocator, path);
    defer cfg.deinit();
    // `load` 会把单例指到 cfg；deinit 之后 g_config 就悬空了。把它按回
    // 局部变量，否则本测试之后任何 config.get() 都是 use-after-free。
    setForTest(cfg);
    defer setForTest(null);
    try testing.expectEqual(@as(usize, 1), cfg.storages.len);
    try testing.expectEqualStrings("Itvsh", cfg.storages[0].driver);
    try testing.expectEqualStrings("/nas", cfg.storages[0].mount_path);
    // addition stays a string, exactly as the Go build stores it
    try testing.expectEqualStrings("{\"mobile\":\"13800000000\"}", cfg.storages[0].addition);
}

test "storages parse web_proxy, defaulting to false" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "config.json" });
    defer testing.allocator.free(path);

    try std.Io.Dir.cwd().writeFile(rt.io(), .{ .sub_path = path, .data =
        \\{"jwt_secret":"x","storages":[
        \\ {"id":1,"mount_path":"/quark","driver":"Quark","web_proxy":true},
        \\ {"id":2,"mount_path":"/local","driver":"Local"}]}
    });

    const cfg = try load(testing.allocator, path);
    defer cfg.deinit();
    setForTest(cfg);
    defer setForTest(null);
    try testing.expectEqual(@as(usize, 2), cfg.storages.len);
    // 用户的夸克存储就是 web_proxy=true：`/d/` 必须回源而不是 302，
    // 否则 CDN 以 require login 拒掉（2026-10-16 e2e 实测）。
    try testing.expect(cfg.storages[0].web_proxy);
    try testing.expect(!cfg.storages[1].web_proxy);
}

test "storages parse the WebDAV proxy trio, defaulting to the native policy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "config.json" });
    defer testing.allocator.free(path);

    try std.Io.Dir.cwd().writeFile(rt.io(), .{ .sub_path = path, .data =
        \\{"jwt_secret":"x","storages":[
        \\ {"id":1,"mount_path":"/a","driver":"Local","webdav_policy":"302_redirect"},
        \\ {"id":2,"mount_path":"/b","driver":"Local","webdav_policy":"use_proxy_url","down_proxy_url":"https://cdn.example.com","disable_proxy_sign":true},
        \\ {"id":3,"mount_path":"/c","driver":"Local"}]}
    });

    const cfg = try load(testing.allocator, path);
    defer cfg.deinit();
    setForTest(cfg);
    defer setForTest(null);

    try testing.expectEqualStrings("302_redirect", cfg.storages[0].webdav_policy);
    try testing.expectEqualStrings("use_proxy_url", cfg.storages[1].webdav_policy);
    try testing.expectEqualStrings("https://cdn.example.com", cfg.storages[1].down_proxy_url);
    try testing.expect(cfg.storages[1].disable_proxy_sign);
    // 缺失 ⇒ 空串 ⇒ native 转发（不改既有配置的行为）
    try testing.expectEqualStrings("", cfg.storages[2].webdav_policy);
    try testing.expectEqualStrings("", cfg.storages[2].down_proxy_url);
    try testing.expect(!cfg.storages[2].disable_proxy_sign);
}

test "putZig deep-copies out of the request arena" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "config.json" });
    defer testing.allocator.free(path);

    const cfg = try load(testing.allocator, path);
    defer cfg.deinit();
    // `load` 会把单例指到 cfg；deinit 之后 g_config 就悬空了。把它按回
    // 局部变量，否则本测试之后任何 config.get() 都是 use-after-free。
    setForTest(cfg);
    defer setForTest(null);

    // 模拟 request arena：handleInitSetup 就是在这种一次性 arena 上分配
    // 用户名和口令哈希的。
    var req = std.heap.ArenaAllocator.init(testing.allocator);
    const ra = req.allocator();

    const user = try ra.dupe(u8, "admin");
    try cfg.putZig("admin_user", .{ .string = user });

    // 嵌套结构同样要深拷贝：字符串在 object 里面，只拷顶层救不了它。
    const nested_keys = try ra.dupe([]const u8, &.{"token"});
    const nested_vals = try ra.dupe(json.Value, &.{.{ .string = try ra.dupe(u8, "abc") }});
    try cfg.putZig("session", .{ .object = .{ .keys = nested_keys, .vals = nested_vals } });

    // 请求结束：整块 arena 释放。任何还指进这里的引用现在都是悬空的。
    req.deinit();

    // 配置必须仍然持有可用副本 —— 这是 A01 的回归测试：修复前这里读到的是
    // 已释放内存，内容不确定（ASAN 下直接报 use-after-free）。
    try testing.expectEqualStrings("admin", cfg.raw("zig.admin_user").?.asStr().?);
    try testing.expectEqualStrings("abc", cfg.raw("zig.session.token").?.asStr().?);

    // 并且这份副本要能撑过一次真正的落盘。
    try cfg.save();
}

test "rfc3339ToUnix parses Go's time.Time JSON forms" {
    // 无小数、Z 结尾。
    try testing.expectEqual(@as(i64, 0), rfc3339ToUnix("1970-01-01T00:00:00Z").?);
    // Go 备份的真实形态：带纳秒 + 时区偏移（2026-09-26T18:10:34.436449082+08:00）。
    // 18:10:34+08:00 = 10:10:34Z。
    const with_offset = rfc3339ToUnix("2026-09-26T18:10:34.436449082+08:00").?;
    const utc = rfc3339ToUnix("2026-09-26T10:10:34Z").?;
    try testing.expectEqual(utc, with_offset);
    // 负偏移（-05:30 → +5h30m UTC）。
    try testing.expectEqual(
        rfc3339ToUnix("2026-01-01T06:30:00Z").?,
        rfc3339ToUnix("2026-01-01T01:00:00-05:30").?,
    );
    // 闰年 2 月 29 日合法、非闰年拒绝。
    try testing.expect(rfc3339ToUnix("2024-02-29T00:00:00Z") != null);
    try testing.expectEqual(@as(?i64, null), rfc3339ToUnix("2023-02-29T00:00:00Z"));
    // 缺时区 / 短串 / 乱串 → null（调用方按「无此字段」处理）。
    try testing.expectEqual(@as(?i64, null), rfc3339ToUnix("2026-01-01T00:00:00"));
    try testing.expectEqual(@as(?i64, null), rfc3339ToUnix("garbage"));
    try testing.expectEqual(@as(?i64, null), rfc3339ToUnix(""));
}

test "rfc3339 format/parse round-trip" {
    var buf: [24]u8 = undefined;
    const cases = [_]i64{ 1, 946684800, 1758930634, 4102444800 };
    for (cases) |ts| {
        const s = rfc3339(&buf, ts);
        try testing.expectEqual(ts, rfc3339ToUnix(s).?);
    }
    // 0 = Go 零值时间，按约定输出 year-1（解析会得到负秒，属预期外的输入）。
    try testing.expectEqualStrings("0001-01-01T00:00:00Z", rfc3339(&buf, 0));
}

test "storage modified survives a save/load round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.Io.Dir.realPathFileAlloc(tmp.dir, rt.io(), ".", testing.allocator);
    defer testing.allocator.free(dir);
    const path = try std.fs.path.join(testing.allocator, &.{ dir, "config.json" });
    defer testing.allocator.free(path);

    const cfg = try load(testing.allocator, path);
    defer cfg.deinit();
    setForTest(cfg);
    defer setForTest(null);

    // 模拟「导入 Go 备份后 + 管理面创建」两种来源：一个 RFC3339 时间戳、
    // 一个 0（从未更新过）。save() 后重新 load 必须原样读回。
    cfg.storages = try cfg.allocator().alloc(model.Storage, 2);
    cfg.storages[0] = .{ .id = 1, .mount_path = "/a", .driver = "Local", .modified = 1758930634 };
    cfg.storages[1] = .{ .id = 2, .mount_path = "/b", .driver = "Local", .modified = 0 };
    try cfg.save();

    const cfg2 = try load(testing.allocator, path);
    defer cfg2.deinit();
    try testing.expectEqual(@as(usize, 2), cfg2.storages.len);
    try testing.expectEqual(@as(i64, 1758930634), cfg2.storages[0].modified);
    try testing.expectEqual(@as(i64, 0), cfg2.storages[1].modified);
    // 落盘文本里必须是 RFC3339 字符串（前端 `new Date()` 要能解析）。
    const raw = try std.Io.Dir.cwd().readFileAlloc(rt.io(), path, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "2025-09-26T23:50:34Z") != null);
    try testing.expect(std.mem.indexOf(u8, raw, "0001-01-01T00:00:00Z") != null);
}
