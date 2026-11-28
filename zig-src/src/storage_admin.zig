//! 存储管理面（/api/admin/storage/*）—— 自 api.zig 整体搬出
//! （AUDIT-2026-11-27 路线图 #15-M3）。搬出为纯移动：存储 CRUD 七个
//! handler、记录表 JSON 形状、load_all 后台重建与路由分发逐行未动；
//! 挂载生命周期辅助（dupeStorage/buildMount*/republishWithEdit 等）仍留
//! api.zig（M4 mounts 拆出时随迁），此处经别名调用。

const std = @import("std");
const http = @import("http.zig");
const model = @import("model.zig");
const driver = @import("driver.zig");
const config = @import("config.zig");
const json = @import("util/json.zig");
const urlmod = @import("util/url.zig");
const log = @import("log.zig");
const rt = @import("rt.zig");
const Buf = @import("util/buf.zig").Buf;

const api = @import("api.zig");
const App = api.App;
const fixAndCleanPath = api.fixAndCleanPath;
const dupeStorage = api.dupeStorage;
const initErrText = api.initErrText;
const buildMountFromStorage = api.buildMountFromStorage;
const buildMountsFromConfig = api.buildMountsFromConfig;
const republishWithEdit = api.republishWithEdit;
const hasLiveMount = api.hasLiveMount;
const handleDownload = api.handleDownload;
const normalizeWebdavPolicy = api.normalizeWebdavPolicy;
const parseBodyJson = api.parseBodyJson;

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
pub fn writeStorageRecordJson(b: *Buf, s: *const model.Storage, live: bool) !void {
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
pub fn additionStringFrom(a: std.mem.Allocator, node: ?*const json.Value) !?[]const u8 {
    const n = node orelse return "{}";
    switch (n.*) {
        .string => |s| return if (s.len == 0) "{}" else s,
        .object => return try json.stringify(a, n),
        else => return null,
    }
}

pub fn boolAt(v: *const json.Value, key: []const u8) bool {
    const x = v.getPath(key) orelse return false;
    return x.asBool() orelse false;
}

/// 追加一条记录到 `cfg.storages`（在配置 arena 里重排 slice）。
/// **调用方必须已持有 `config.storages_mutex`**（本文件的管理面处理器）。
pub fn appendStorageRecord(ca: std.mem.Allocator, cfg: *config.Config, s: model.Storage) !void {
    const out = try ca.alloc(model.Storage, cfg.storages.len + 1);
    @memcpy(out[0..cfg.storages.len], cfg.storages);
    out[cfg.storages.len] = s;
    cfg.storages = out;
}

/// 按 id 移除一条记录；不存在时返回 null（不动 slice）。
/// **调用方必须已持有 `config.storages_mutex`**。
pub fn removeStorageRecord(ca: std.mem.Allocator, cfg: *config.Config, id: i64) !?model.Storage {
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
pub fn handleAdminStorageRoute(app: *App, req: *http.Request, res: *http.Response, suffix: []const u8) !void {
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
    const mount_path = try fixAndCleanPath(a, raw_path);
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
        .init_failed => |ef| {
            // `a` 是请求 arena，出请求即回收 —— 拼消息落这里是安全的。
            const msg = try initErrText(a, ef);
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
        const mount_path = try fixAndCleanPath(a, raw_path);
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
        .init_failed => |ef| {
            const msg = try initErrText(a, ef);
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
        .init_failed => |ef| {
            // 这个 handler 只有 `req.arena`（请求 arena），同样出请求即回收。
            const msg = try initErrText(req.arena, ef);
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
