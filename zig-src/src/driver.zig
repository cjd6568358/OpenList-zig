//! Driver interface (hand-rolled vtable) + registry.
//!
//! Zig has no interfaces, so each driver is a struct with a `driver() Driver`
//! method returning a type-erased `{ptr, vtable}` pair. This is the same shape
//! as `std.mem.Allocator` and costs one indirect call per operation — nothing
//! measurable next to the network round-trip every one of these performs.
//!
//! The method set is a deliberate subset of OpenList's `driver.Driver`
//! interface: only what the registered drivers actually need (`Local / WebDav /
//! Itvsh / 189Cloud / 189CloudPC / 123Pan / AliyundriveOpen /
//! Quark+UC / 115 Cloud / WoPan / Strm` + `Thunder` / `ThunderExpert` /
//! `ThunderWeb`，全量 15 个注册名 / 12 个实现文件，见下面 `builtin`).
//! `copy` is **optional**
//! (`null` = the upstream driver's `Copy` is `NotSupport`), and `space` is
//! optional too (null = no quota). Still absent: `putURL`, `getArchive`,
//! `extractArchive`, `mkdir`-with-recursion, and every optional capability
//! interface (`ObjThumb`, `ObjUpload`, `ObjReader`, `ArchiveReader`, `Other`,
//! `DirectUploader`, ...). Each of those is a documented, budgeted extension
//! point rather than a blank check — see docs/AUDIT_2026-10-18-drivers.md §2.

const std = @import("std");
const testing = std.testing;
const model = @import("model.zig");
const json = @import("util/json.zig");
/// 编译期驱动白名单，由 `build.zig` 的 `-Ddrivers=` 注入。
/// 字段：`drivers`（basename 逗号分隔串）+ `drivers_all`（true = 全量）。
/// 只有走 `zig build` / `zig build test` 才有这个模块 —— 这也正是
/// `tools/build_remote.py` 必须走 `zig build test` 而不是裸 `zig test` 的原因。
const build_options = @import("build_options");

pub const Obj = model.Obj;
pub const File = model.File;
pub const Link = model.Link;
pub const LinkArgs = model.LinkArgs;
pub const Source = model.Source;

/// Per-call context. The allocator is a request-scoped arena: drivers allocate
/// freely and nothing is freed individually.
pub const Ctx = struct {
    alloc: std.mem.Allocator,
    /// Prefix used in log lines, e.g. `[/nas]` or `[itvsh:家庭共享]`.
    tag: []const u8 = "",

    /// 驱动在返回上游错误前，可把上游的**人类可读消息**写到这里（用
    /// `ctx.alloc` 分配）。`api.zig` 的 `mapDriverError` 会优先用它当响应
    /// message —— 对齐 Go：fs 操作失败时 `common.ErrorResp` 直接透出
    /// `err.Error()`，用户看到的是 `capacity limit[{0}]` 这种真原因，而不是
    /// 泛化的 "upstream error"（2026-10-16 全驱动回归发现，见 STATUS §31.7）。
    ///
    /// 值语义（不是指针）：`Ctx` 自己就活在**请求栈帧**上（handler 的局部
    /// 变量），所以字段天然是请求级、无并发串台，handler 不需要额外开槽。
    /// 驱动内部的辅助函数要把**这个字段的地址**（`&ctx.err_detail`）往下传
    /// 才能写回。
    /// 注意：Zig `error` 无 payload，这是把上游文本带出驱动的通道。
    ///
    /// ⚠ 只能在**请求线程**上写：多线程分块上传的驱动（如 itvsh 的 worker）
    /// 从别的线程写它属于数据竞争。这类驱动要透传得先把消息收回到请求线程。
    err_detail: ?[]const u8 = null,

    /// Optional upload progress sink. Mirrors OpenList's
    /// `driver.UpdateProgress` so the frontend's chunked upload can show a bar.
    /// `null` means "caller does not care about progress".
    progress: ?ProgressFn = null,
    /// Opaque per-request state handed back to `progress`.
    progress_userdata: ?*anyopaque = null,

    /// 便利函数：写上游消息。空串按「没有消息」处理（避免响应回落时被空串
    /// 顶掉默认的 "upstream error"）。
    pub fn setErrDetail(self: *Ctx, msg: []const u8) void {
        if (msg.len > 0) self.err_detail = msg;
    }
};

/// Signature for the upload progress callback.
///
/// `percentage` is **0–100**, matching Go's `model.UpdateProgress`
/// (`internal/model/obj.go:59` → `func(percentage float64)`). This is *not* a
/// byte count: the Go frontend scales it straight into its upload progress bar.
///
/// ⚠️ 曾经这里签名是 `bytes: u64`、文档写"累计字节数"，而 4 个驱动里 3 个
/// 传的是百分比 —— 语义分裂。现已统一为百分比；传字节的 pan115 已改。
pub const ProgressFn = *const fn (userdata: ?*anyopaque, percentage: u64) void;

pub const Driver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,

        /// One-time setup after construction: validate config, log in, restore
        /// cookies. Called once at startup and again on config reload.
        init: *const fn (ptr: *anyopaque, ctx: *Ctx) anyerror!void,

        /// Release driver-owned resources. Must tolerate being called after a
        /// failed `init`.
        deinit: *const fn (ptr: *anyopaque, ctx: *Ctx) void,

        list: *const fn (ptr: *anyopaque, ctx: *Ctx, dir: []const u8) anyerror![]Obj,

        details: *const fn (ptr: *anyopaque, ctx: *Ctx, path: []const u8) anyerror!File,

        link: *const fn (ptr: *anyopaque, ctx: *Ctx, path: []const u8, args: LinkArgs) anyerror!Link,

        makeDir: *const fn (ptr: *anyopaque, ctx: *Ctx, dir: []const u8) anyerror!void,

        /// `dst_dir` is the destination *directory*; the entry keeps its name.
        move: *const fn (ptr: *anyopaque, ctx: *Ctx, src: []const u8, dst_dir: []const u8) anyerror!void,

        /// `new_name` is a bare name, not a path — the entry stays in its
        /// current directory. This mirrors OpenList's `Rename(srcObj, newName)`
        /// and, importantly, the itvsh API, whose rename method takes
        /// (directory, filename, newFilename).
        rename: *const fn (ptr: *anyopaque, ctx: *Ctx, src: []const u8, new_name: []const u8) anyerror!void,

        /// `is_dir` is passed in rather than probed: itvsh needs a different
        /// upstream method for files and directories, and every caller
        /// (WebDAV DELETE, /api/fs/remove) already knows the answer from the
        /// entry it just looked up.
        remove: *const fn (ptr: *anyopaque, ctx: *Ctx, path: []const u8, is_dir: bool) anyerror!void,

        put: *const fn (ptr: *anyopaque, ctx: *Ctx, dst: []const u8, src: Source) anyerror!void,

        /// Copy `src` into `dst_dir`, keeping the entry's name (same shape as
        /// `move`). Optional: `null` means the driver cannot copy (itvsh /
        /// 123Pan / Quark are `NotSupport` upstream too) and `Driver.copy`
        /// returns `NotSupported`.
        copy: ?*const fn (ptr: *anyopaque, ctx: *Ctx, src: []const u8, dst_dir: []const u8) anyerror!void = null,

        /// Optional. Null means "no quota information"; the API then reports
        /// zeroes rather than an error, matching OpenList's behaviour for
        /// drivers that do not implement `GetDetails`.
        space: ?*const fn (ptr: *anyopaque, ctx: *Ctx) anyerror!DiskUsage = null,
    };

    pub fn name(self: Driver) []const u8 {
        return self.vtable.name(self.ptr);
    }
    pub fn init(self: Driver, ctx: *Ctx) !void {
        return self.vtable.init(self.ptr, ctx);
    }
    pub fn deinit(self: Driver, ctx: *Ctx) void {
        self.vtable.deinit(self.ptr, ctx);
    }
    pub fn list(self: Driver, ctx: *Ctx, dir: []const u8) ![]Obj {
        return self.vtable.list(self.ptr, ctx, dir);
    }
    pub fn details(self: Driver, ctx: *Ctx, path: []const u8) !File {
        return self.vtable.details(self.ptr, ctx, path);
    }
    pub fn link(self: Driver, ctx: *Ctx, path: []const u8, args: LinkArgs) !Link {
        return self.vtable.link(self.ptr, ctx, path, args);
    }
    pub fn makeDir(self: Driver, ctx: *Ctx, dir: []const u8) !void {
        return self.vtable.makeDir(self.ptr, ctx, dir);
    }
    pub fn move(self: Driver, ctx: *Ctx, src: []const u8, dst_dir: []const u8) !void {
        return self.vtable.move(self.ptr, ctx, src, dst_dir);
    }
    pub fn rename(self: Driver, ctx: *Ctx, src: []const u8, new_name: []const u8) !void {
        return self.vtable.rename(self.ptr, ctx, src, new_name);
    }
    pub fn remove(self: Driver, ctx: *Ctx, path: []const u8, is_dir: bool) !void {
        return self.vtable.remove(self.ptr, ctx, path, is_dir);
    }
    pub fn put(self: Driver, ctx: *Ctx, dst: []const u8, src: Source) !void {
        return self.vtable.put(self.ptr, ctx, dst, src);
    }
    /// `dst_dir` is the destination *directory*; the entry keeps its name.
    /// Drivers without a copy capability report `NotSupported`.
    pub fn copy(self: Driver, ctx: *Ctx, src: []const u8, dst_dir: []const u8) !void {
        const f = self.vtable.copy orelse return Error.NotSupported;
        return f(self.ptr, ctx, src, dst_dir);
    }
    /// Never fails: an unsupported driver reports zero capacity.
    pub fn space(self: Driver, ctx: *Ctx) DiskUsage {
        const f = self.vtable.space orelse return .{};
        return f(self.ptr, ctx) catch .{};
    }
};

pub const DiskUsage = struct {
    total: i64 = 0,
    used: i64 = 0,
};

/// Installed by `main.zig`. Drivers call `persist()` when they have mutated
/// their own `addition` blob (itvsh stores its session cookies and the
/// per-user `forwardUrl` there) so the change survives a reboot.
///
/// A hook rather than a direct call into `config.zig`, because `driver.zig`
/// must stay importable by drivers without dragging the whole config layer in.
pub var persist_hook: ?*const fn (storage_id: i64, addition_json: []const u8) void = null;

pub fn persist(storage_id: i64, addition_json: []const u8) void {
    if (persist_hook) |h| h(storage_id, addition_json);
}

// ---------------------------------------------------------------------------
// fs bridge —— Strm 驱动回调本实例其他挂载的通道
// ---------------------------------------------------------------------------

/// Strm（`drivers/strm`）的特殊之处：它不做任何自己的存储 IO，而是把**同一
/// OpenList 实例里其他挂载**的目录映射成 `.strm` 虚拟文件。Go 侧直接调
/// `internal/fs`（`fs.List` / `fs.Get`）和 `op.Link` / `common.GetApiUrl` /
/// `sign.Sign`；本工程的驱动层不能反向依赖 App，所以由 App 在启动时安装
/// 这组函数指针（`api.installFsBridge`），驱动经全局单例调用。
pub const FsBridge = struct {
    ctx: *anyopaque,

    /// Go `fs.Get`：解析虚拟路径到具体挂载并取对象详情。不存在 → error.NotFound。
    get: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, path: []const u8) anyerror!File,
    /// Go `fs.List`（NoLog、按需 Refresh；本实现无缓存层，语义等价）。
    list: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, path: []const u8) anyerror![]Obj,
    /// Go `op.Link`：目标挂载的真实下载链接（不经过 Strm 的 OnlyProxy 包装）。
    link: *const fn (
        ctx: *anyopaque,
        alloc: std.mem.Allocator,
        path: []const u8,
        args: LinkArgs,
    ) anyerror!Link,
    /// Go `sign.Sign(path)`（expire=0，永不过期），secret 用实例 jwt_secret。
    sign: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, path: []const u8) anyerror![]const u8,
    /// Go `common.GetApiUrl(ctx)` 的无请求回退形态：settings 里的 site_url。
    site_url: *const fn (ctx: *anyopaque) []const u8,
};

/// 由 `main.zig`（经 `api.installFsBridge`）在 App 构造后安装。为 null 时
/// Strm 驱动的 list/get 返回 NotFound —— 与 Go 在无存储时 `op.GetStorageAndActualPath`
/// 失败的行为一致。
pub var fs_bridge: ?FsBridge = null;

// ---------------------------------------------------------------------------
// objs-update hook —— Go `op.RegisterObjsUpdateHook` 的对应物
// ---------------------------------------------------------------------------

/// Go `internal/op/hook.go` 的 `ObjsUpdateHook = func(ctx, parent, objs)`。
/// 本工程只有 Strm 的 `UpdateLocalStrm` 这一个使用者，所以用单槽而不是列表；
/// 将来出现第二个钩子再扩成列表。
pub const ObjsUpdateHook = *const fn (
    ctx: *anyopaque,
    alloc: std.mem.Allocator,
    parent: []const u8,
    objs: []const Obj,
) void;

var objs_update_hook: ?struct {
    func: ObjsUpdateHook,
    ctx: *anyopaque,
} = null;

/// 由驱动注册（幂等：后注册者覆盖 —— 本工程只有一个使用者）。
pub fn registerObjsUpdateHook(func: ObjsUpdateHook, ctx: *anyopaque) void {
    objs_update_hook = .{ .func = func, .ctx = ctx };
}

/// Go `op.HandleObjsUpdateHook`。写操作处理层在配置开关
/// `zig.handle_hook_after_writing`（对齐 Go settings `handle_hook_after_writing`，
/// 默认 false）打开时调用。
pub fn notifyObjsUpdate(alloc: std.mem.Allocator, parent: []const u8, objs: []const Obj) void {
    const h = objs_update_hook orelse return;
    h.func(h.ctx, alloc, parent, objs);
}

/// Ergonomic wrapper: `drv.list(ctx, path)` on a concrete `*T`.
pub fn asDriver(comptime T: type, ptr: *T) Driver {
    return .{ .ptr = ptr, .vtable = &T.vtable };
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

pub const Factory = struct {
    /// Value stored in `Storage.driver`.
    ///
    /// 必须与 Go `driver.Config.Name` **逐字节相同** —— Go 把驱动名直接写进
    /// 配置的 `Storage.driver`，改名就等于读不懂已有配置。itvsh 的 Go 名
    /// 2026-10-19 起是 "Itvsh"（原中文名「上海电信智家硬盘」，用户要求驱动名
    /// 统一 ASCII，Go/Zig 同步改名，见 drivers/itvsh/meta.go:34）。
    ///
    /// **不提供别名 / 不忽略大小写**（用户 2026-10-15 明确要求）：本工程不背
    /// 兼容性包袱。历史名一律删除，配置按最新驱动名重新添加即可。
    /// Go 侧就是 `map[string]DriverConstructor` 的精确查找
    /// （`internal/op/driver.go:26`），这里与之对齐。
    key: []const u8,
    /// One-line description, used in the startup log line only.
    ///
    /// ⚠ 它**不是**展示名、也没有任何 API 出口：上游 Go 的 `driver.Config` /
    /// `driver.Info` 都没有 label 字段，客户端「添加存储」下拉框的选项文字全部
    /// 来自 `/api/admin/driver/names` 返回的 **key**（该端点注释原文 "driver
    /// keys for the selector"；前端各 chunk 里没有任何驱动的中文映射表，
    /// 2026-10-19 在打包机实测确认）。中文 key 能正常显示也正因为如此 ——
    /// 显示什么由 key 决定，与 label 无关。
    /// 2026-10-19 曾据"label 应与上游展示一致"把各驱动 label 统一改成 key，
    /// 随后证实前提错误（label 根本不展示），已回退为各驱动的中文短名。
    label: []const u8,
    /// JSON text of the `addition` schema (field name -> default/type), served
    /// to the frontend so it can render the storage form without a rebuild.
    addition_schema: []const u8,
    /// Config keys that must be redacted before echoing config back.
    secrets: []const []const u8,
    /// Go `driver.Config.OnlyProxy`（internal/driver/config.go:6）。
    ///
    /// 与 `no_link_url` 合起来决定 `Config.MustProxy()`，后者是
    /// `fs/get` 的 raw_url 走 `/p` 还是走直链的第一判据
    /// （server/handles/fsread.go:314）。上游置 true 的：Local、Strm、
    /// Itvsh、UC、QuarkOpen、Virtual、Weiyun、Mega、ProtonDrive、SFTP、
    /// SMB、FTP、Crypt、Chunk、Chaoxing、GoogleDrive/Photo、HalalCloud。
    only_proxy: bool = false,
    /// Go `driver.Config.NoLinkURL`（internal/driver/config.go:25，"驱动返回的
    /// Link 不带 URL"）。上游置 true 的：Local、Strm、Virtual、Chunk、Crypt、
    /// FTP、HalalCloud、Mega、ProtonDrive、SFTP、SMB。
    no_link_url: bool = false,
    /// `storage_id` is the real id of the `Storage` row being constructed.
    ///
    /// 驱动用它把刷新后的 token / cookie / forwardUrl 写回配置文件（见
    /// `persist`）。以前这个参数不存在，所有驱动内部都以 id=0 构造，
    /// `persistStorage(0)` 在 `storageById(0)` 查无记录 —— 会话只在进程内
    /// 有效，重启就丢，refresh token 轮换后可能彻底失效。
    ///
    /// `cfg` is the parsed `addition` object, or null when the storage has an
    /// empty/missing `addition` — drivers must tolerate both.
    create: *const fn (alloc: std.mem.Allocator, storage_id: i64, cfg: ?*const json.Value) anyerror!Driver,

    /// Go `Config.MustProxy()`（internal/driver/config.go:42-44）。
    pub fn mustProxy(self: Factory) bool {
        return self.only_proxy or self.no_link_url;
    }
};

/// Built-in driver table. Explicit rather than self-registering: Zig has no
/// static initialisers, and an explicit list makes the size cost of each
/// driver visible in one place — which is the whole point of this exercise.
///
/// **按编译期白名单生成**（用户 2026-10-15 要求，即 `-Ddrivers=`，见
/// `docs/MODULAR_DRIVERS.md` §4 方案 A）。不勾选的驱动连编译都不进二进制，
/// 体积按 xz 边际全额省下，`/api/admin/driver/names` 与前端下拉框自然只列
/// 编译进去的那些。
///
/// ⚠️ 为什么这里必须是**一串 `if (comptime ...)`**，而不能把 factory 收集进
/// 一个数组再过滤：`registry` 一旦持有 `Factory` 值，就等于持有了里面每个
/// fn 指针，**所有驱动的代码都会被强制生成**（Zig 惰性分析只认"被引用"）。
/// 用 comptime 分支时，未选中的 `@import(...).factory` 连同整个分支一起被
/// 消掉，一行代码都不生成 —— 这是整个白名单能省体积的关键。
pub const builtin = blk: {
    // 每个 if 对应一项，与 build.zig 的 DRIVERS 表一一对应
    // （build.zig 负责把用户传的名字翻译成这里的 basename 并校验）。
    // 2026-10-20 起 15 个注册项 / 12 个实现（thunder 出 Thunder + ThunderExpert + ThunderWeb）。
    // 另有 3 个**编译期可选**项（`123 Open` / `QuarkOpen` / `115 Open`，用
    // `opted()` 而不是 `has()`）—— 默认全量构建里不出现，只有 `-Ddrivers=`
    // 点名才注册，所以注册项总数仍是 15。
    @setEvalBranchQuota(200000);
    var list: []const Factory = &.{};
    if (has("local")) list = list ++ [_]Factory{@import("drivers/local.zig").factory};
    if (has("webdav")) list = list ++ [_]Factory{@import("drivers/webdav.zig").factory};
    if (has("itvsh")) list = list ++ [_]Factory{@import("drivers/itvsh.zig").factory};
    if (has("aliyundrive")) list = list ++ [_]Factory{@import("drivers/aliyundrive.zig").factory};
    if (has("cloud189")) list = list ++ [_]Factory{@import("drivers/cloud189.zig").factory};
    if (has("cloud189pc")) list = list ++ [_]Factory{@import("drivers/cloud189pc.zig").factory};
    if (has("pan123")) list = list ++ [_]Factory{@import("drivers/pan123.zig").factory};
    // T2（2026-10-12）：补上的三个正确变体（用户配置 + build_sqfs.yml
    // 默认清单用的是这些，不是 `_open` 系列）。
    if (has("quarkuc")) list = list ++ [_]Factory{
        @import("drivers/quarkuc.zig").factory, // Quark（Cookie）
        @import("drivers/quarkuc.zig").uc_factory, // UC（Cookie，OnlyProxy 变体）
    };
    if (has("pan115")) list = list ++ [_]Factory{@import("drivers/pan115.zig").factory};
    if (has("wopan")) list = list ++ [_]Factory{@import("drivers/wopan.zig").factory};
    if (has("strm")) list = list ++ [_]Factory{@import("drivers/strm.zig").factory};
    // 迅雷云盘：Go 的 `drivers/thunder` 一个包注册两个驱动（普通 + 专家），
    // 共用一套 `XunLeiCommon` 协议实现，所以这里也是同一份文件出两个 factory。
    // 第三个 `ThunderWeb` 是本工程新增（网页版 refresh_token + 自签 captcha，
    // 绕开安卓 SDK 的数美风控），见 docs/THUNDER_WEB_RE_2026-10-20.md。
    if (has("thunder")) list = list ++ [_]Factory{
        @import("drivers/thunder.zig").factory, // Thunder
        @import("drivers/thunder.zig").expert_factory, // ThunderExpert
        @import("drivers/thunder.zig").web_factory, // ThunderWeb
    };

    // ---------------------------------------------------------------------
    // 编译期可选（opt-in）入口 —— 代码完整、有单测，但**默认不进产物**。
    //
    // OpenList 里同一个网盘常有两个互不兼容的驱动：
    //   `123`/`123Pan`(用户名+密码)      vs `123_open`/`123 Open`(开放平台)
    //   `quark_uc`/`Quark`(Cookie)       vs `quark_open`/`QuarkOpen`(refresh_token)
    //   `115`/`115 Cloud`(Cookie)        vs `115_open`/`115 Open`(开放平台)
    //
    // T2（2026-10-12）补齐了前者，后者的处理方式见 `opted()`：**默认不注册**
    // （前端下拉框不会出现两个语义相近的入口，用户 2026-10-12 的指示），
    // 但可以 `-Ddrivers=123open,quark,115open` 显式点名编进产物做验证/使用。
    // ---------------------------------------------------------------------
    if (opted("123open")) list = list ++ [_]Factory{@import("drivers/123open.zig").factory};
    if (opted("quark")) list = list ++ [_]Factory{@import("drivers/quark.zig").factory};
    if (opted("115open")) list = list ++ [_]Factory{@import("drivers/115open.zig").factory};

    break :blk list;
};

/// 编译期驱动白名单查询。`build_options.drivers` 是 build.zig 传进来的
/// **basename**（= `src/drivers/<name>.zig` 去掉扩展名）逗号分隔串，
/// `drivers_all` 为 true 时全量。
///
/// 用**字符串**而不是 `[]const []const u8` 选项：生成模块里的字面量是
/// comptime 已知的，`splitScalar` 才能在 comptime 下跑；万一哪天它不是，
/// 这里会直接编译失败而不是静默跑出个空注册表。
fn has(comptime name: []const u8) bool {
    if (build_options.drivers_all) return true;
    return nameInList(build_options.drivers, name);
}

/// 「编译期可选」查询：**只认显式点名**，`drivers_all`（默认全量构建）一律不算。
///
/// 这是 `has()` 的严格版，专门给三个"同名变体"驱动用（`123 Open` /
/// `QuarkOpen` / `115 Open`）。为什么需要两个语义：
///   * `has()` = "全量构建里应该有我" —— 12 个主驱动都是这个语义；
///   * `opted()` = "只有我名字出现在 `-Ddrivers=` 里才有我" —— 变体驱动是
///     这个语义，否则 `zig build`（全量）会把它们一并注册，前端下拉框里就会
///     冒出 `123 Open`/`123Pan`、`115 Open`/`115 Cloud` 这种易混的两项。
///
/// 副作用是好的：默认产物里不会多出这三个驱动的**任何一个字节**，`keys()`
/// 仍是 15 项；要验证/使用变体时显式点名即可，例如
///   `zig build -Ddrivers=local,123open,quark,115open`
fn opted(comptime name: []const u8) bool {
    if (build_options.drivers_all) return false;
    return nameInList(build_options.drivers, name);
}

fn nameInList(raw: []const u8, comptime name: []const u8) bool {
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " ");
        if (t.len != 0 and std.mem.eql(u8, t, name)) return true;
    }
    return false;
}


/// 精确匹配，与 Go `op.GetDriver`（`internal/op/driver.go:26` 的 map 查找）
/// 一致：没有别名、不忽略大小写。用户 2026-10-15 定的规矩——不背兼容性
/// 包袱，历史名直接删，配置按最新驱动名重新加。
///
/// 返回**指向 `builtin` 元素的指针**而不是拷贝：`builtin` 现在是 slice
/// （编译期白名单 re方向生成，长度不定），for 出来的是值，取不到地址。
pub fn find(key: []const u8) ?*const Factory {
    for (builtin, 0..) |f, i| {
        if (std.mem.eql(u8, f.key, key)) return &builtin[i];
    }
    return null;
}

/// Keys of all compiled-in drivers, for `/api/admin/driver/list`.
pub fn keys(alloc: std.mem.Allocator) ![][]const u8 {
    var out = try alloc.alloc([]const u8, builtin.len);
    for (builtin, 0..) |f, i| out[i] = f.key;
    return out;
}

// ---------------------------------------------------------------------------
// Shared driver errors — mapped to HTTP status by the API layer
// ---------------------------------------------------------------------------

pub const Error = error{
    /// Credentials rejected, or session token expired and re-login failed.
    AuthFailed,
    /// Path does not exist.
    NotFound,
    /// Operation not supported by this driver.
    NotSupported,
    /// Upstream rate-limited us; caller should back off.
    RateLimited,
    /// Upstream returned a well-formed response we could not interpret.
    UnexpectedResponse,
};

test "find matches the Go Config.Name byte for byte — no aliases, no case folding" {
    // 回归（用户 2026-10-15）：不许再有兼容性包袱。Go 侧是
    // `internal/op/driver.go:26` 的 map 精确查找，Zig 必须一致。
    //
    // 白名单感知：本测试跑在 `-Ddrivers=` 选中的子集上，所以"能找到"只能断言
    // **编译进来了的**驱动；"找不到"的断言与白名单无关，必须无条件的。
    // 全量构建下 4 条"能找到"覆盖 Quark / UC / 123Pan / itvsh 四类易错项。
    try testing.expectEqualStrings("Local", find("Local").?.key); // 任何构建都该有

    if (find("UC") != null) {
        try testing.expectEqualStrings("UC", find("UC").?.key);
        try testing.expect(find("Quark") != null); // 同实现，必然同时入选
    }
    if (find("123Pan") != null) try testing.expectEqualStrings("123Pan", find("123Pan").?.key);
    if (find("Itvsh") != null) {
        try testing.expectEqualStrings("Itvsh", find("Itvsh").?.key);
    }

    for ([_][]const u8{
        "上海电信智家硬盘", // itvsh 2026-10-19 改名前的旧中文名（无兼容包袱，必须查不到）
        "123",             // 123Pan 的历史名
        "quark",           // 大小写变体
        "local",
        "LOCAL",
        "123pan",
        "",                // 空串
    }) |bad| {
        try testing.expect(find(bad) == null);
    }

    // `QuarkOpen` 是 opt-in 变体（见 `opted()`）：默认全量构建里查不到，
    // 但 `-Ddrivers=quark` 点名时必须查得到 —— 否则白名单等于失效。
    if (build_options.drivers_all) {
        try testing.expect(find("QuarkOpen") == null);
    } else {
        try testing.expectEqual(nameInList(build_options.drivers, "quark"), find("QuarkOpen") != null);
    }
}

test "keys() reports exactly the registered driver names, no duplicates" {
    const ks = try keys(testing.allocator);
    defer testing.allocator.free(ks);
    // 条数随白名单变化（全量 = 15 注册项 / 12 个实现：quarkuc 出 Quark + UC，
    // thunder 出 Thunder + ThunderExpert + ThunderWeb），所以不断言固定值，
    // 只断言"自洽 + 无重复 + 非空"这些不变量。
    try testing.expect(ks.len > 0);
    for (ks, 0..) |k, i| {
        for (ks[i + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, k, other));
        }
        // find 必须能按这个 key 找到自己
        try testing.expectEqualStrings(k, find(k).?.key);
    }
}

test "nameInList is exact, whitespace-tolerant, and does not know 'all'" {
    // `opted()` 的全部判断都落在这个纯函数上，所以逐条钉住：
    // 分隔符是逗号、两侧空格容忍、**子串不算命中**（`quark` ≠ `quarkuc`）。
    try testing.expect(nameInList("local,123open", "123open"));
    try testing.expect(nameInList(" local , 123open ", "123open"));
    try testing.expect(nameInList("123open", "123open"));
    try testing.expect(!nameInList("local,quarkuc", "quark"));
    try testing.expect(!nameInList("all", "quark")); // `all` 由 drivers_all 表示，不是名字
    try testing.expect(!nameInList("", "quark"));
    try testing.expect(!nameInList("123open2", "123open"));
}

test "opt-in variants stay out of the default (drivers_all) build" {
    // 用户 2026-10-12：这三个变体"代码保留但不注册"。2026-10-22 收尾时改成
    // "编译期可选"：默认全量构建（`zig build` / `-Ddrivers=all`）里**必须没有**
    // 它们，否则前端「添加存储」下拉框会出现 `123 Open` 与 `123Pan`、
    // `115 Open` 与 `115 Cloud` 这种易混的两项。
    //
    // 只有全量构建能断言这一点；`-Ddrivers=123open` 这类点名构建里它们本该
    // 存在，跳过即可（用 SkipZigTest 而不是让它红）。
    if (!build_options.drivers_all) return error.SkipZigTest;

    for ([_][]const u8{ "123 Open", "QuarkOpen", "115 Open" }) |name| {
        try testing.expect(find(name) == null);
    }
    // 同时钉住"已注册的那些还在"—— 防止哪天 opt-in 写错把整张表带崩。
    try testing.expect(find("123Pan") != null);
    try testing.expect(find("Quark") != null);
    try testing.expect(find("115 Cloud") != null);
}

test "every addition_schema writes select options as a comma string" {
    // Go 的 `driver.Item.Options` 是 **string**（`internal/driver/item.go:11`，
    // 值来自 struct tag `options:"a,b,c"`），前端按逗号 split 出下拉项。
    // Zig 侧 `api.zig` 的 `writeAdditionalItems` 同样只认字符串：写成数组会被
    // 静默降级成 `"options":""` —— 下拉框变成空的，只能用它自己填的默认值。
    //
    // 2026-10-22 真机抓到 QuarkOpen / Quark / 115 Cloud / AliyundriveOpen /
    // 189CloudPC 五个驱动都是数组形态（共 16 处），全部已改成逗号串。
    // 这个测试是防复发：新增驱动时写数组会在这里立刻红。
    for (builtin) |f| {
        if (std.mem.indexOf(u8, f.addition_schema, "\"options\":[") != null) {
            std.debug.print("driver {s}: addition_schema uses an array for options\n", .{f.key});
            return error.ArrayOptionsInSchema;
        }
    }
}

test "Ctx.setErrDetail holds the upstream message; empty is ignored" {
    // 请求级出口：api 层把响应 message 取走（对齐 Go err.Error() 透出）。
    var ctx = Ctx{ .alloc = testing.allocator };
    try testing.expect(ctx.err_detail == null);
    ctx.setErrDetail("capacity limit[{0}]");
    try testing.expectEqualStrings("capacity limit[{0}]", ctx.err_detail.?);
    // 再次写入覆盖（长请求里可能有多段上游消息）
    ctx.setErrDetail("other");
    try testing.expectEqualStrings("other", ctx.err_detail.?);
    // 空串不覆盖：否则会把默认的 "upstream error" 顶成空 message
    ctx.setErrDetail("");
    try testing.expectEqualStrings("other", ctx.err_detail.?);
}
