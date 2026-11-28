//! HTTP 路由分发（handle/handleAuthed 双层分发表 + noRoute + CORS + 前端
//! 资产路由）—— 自 api.zig 整体搬出（AUDIT-2026-11-27 路线图 #15-M5）。
//! 搬出为纯移动：handle 的公共路由链（OPTIONS/公共 API/前端资产/dav/
//! 下载前缀）、isRegisteredAuthedPath（≈ gin 路由表）、handleAuthed 的
//! 鉴权分发表、noRoute（405/501/HTML 外壳三分支）、setCors 与列表辅助
//! 逐行未动。各端点 handler 留守 api.zig，经别名调用（api↔router 双向
//! import 与既有 api↔webdav 同形）。

const std = @import("std");
const http = @import("http.zig");
const config = @import("config.zig");
const json = @import("util/json.zig");
const log = @import("log.zig");
const rt = @import("rt.zig");
const Buf = @import("util/buf.zig").Buf;
const frontend_mod = @import("frontend.zig");
const webdav = @import("webdav.zig");
const multipart = @import("multipart.zig");
const storage_admin = @import("storage_admin.zig");

const api = @import("api.zig");
const download_mod = @import("download.zig");
const App = api.App;
const handlePublicSettings = api.handlePublicSettings;
const handleInitStatus = api.handleInitStatus;
const handleInitSetup = api.handleInitSetup;
const handleDelUserCache = api.handleDelUserCache;
const handleLogin = api.handleLogin;
const handleLoginHash = api.handleLoginHash;
const isGuestReadRequest = api.isGuestReadRequest;
const checkAuth = api.checkAuth;
const handleFsDirs = api.handleFsDirs;
const handleFsList = api.handleFsList;
const handleFsGet = api.handleFsGet;
const handleFsMkdir = api.handleFsMkdir;
const handleFsCopy = api.handleFsCopy;
const handleFsRename = api.handleFsRename;
const handleFsMove = api.handleFsMove;
const handleFsRemove = api.handleFsRemove;
const handleFsPut = api.handleFsPut;
const handleFsArchiveList = api.handleFsArchiveList;
const handleMe = api.handleMe;
const handleMeUpdate = api.handleMeUpdate;
const handleLogout = api.handleLogout;
const handleDriverList = api.handleDriverList;
const handleDriverInfo = api.handleDriverInfo;
const handleDriverNames = api.handleDriverNames;
const handleSettingRoute = api.handleSettingRoute;
const handleConfigExport = api.handleConfigExport;
const handleConfigImport = api.handleConfigImport;
const handleTaskRoute = api.handleTaskRoute;
const handleDownload = download_mod.handleDownload;
const mimeFor = download_mod.mimeFor;

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
    //
    // 2026-10-30 起 `/api/*` 未注册路径改为 **501 JSON**（`noRoute` 内），
    // 不再回落 HTML 外壳 —— 见 `noRoute` 上的理由。
    return noRoute(app, req, res, p);
}

/// Go `static.Static` 里注册进 `e.NoRoute` 的那个 handler，逐条对齐。
/// 返回给 `handle` / `handleAuthed` 两处共用（未注册路径都落到这里）。
///
/// ★ 2026-10-30 引入一处**刻意偏差**：`/api/*` 未注册路径不再回落 HTML 外壳，
/// 改为 **501 JSON**。理由：上游的 NoRoute 对 `/api/*` 返回 200 + index.html，
/// 前端会把 HTML 当 JSON 解析后静默降级 —— 网页端上传那次
/// `multipart init failed: network error`（STATUS §55）就是这么被掩盖的：
/// 真问题（路由不存在）被包装成了"网络错误"。宁可明说"没实现"。
/// `/api/` 之外（前端 SPA 路由、静态资源）维持上游行为不变。
pub fn noRoute(app: *App, req: *http.Request, res: *http.Response, p: []const u8) !void {
    if (std.mem.startsWith(u8, p, "/api/")) {
        const msg = std.fmt.allocPrint(
            res.arena,
            "not implemented: {s} {s}",
            .{ req.method, p },
        ) catch "not implemented";
        // 注意用**真实** HTTP 501，不能走 `jsonError` —— 后者对齐 Go 的
        // `c.JSON(200, …)` 恒回 HTTP 200（见 http.zig jsonError 注释），
        // 而这里恰恰要让状态码本身说明问题（curl/脚本一眼可见，前端 axios
        // 走错误分支也能拿到 message）。
        res.status = 501;
        try res.set("Content-Type", "application/json; charset=utf-8");
        try res.buf.append("{\"code\":501,\"message\":");
        try json.writeString(&res.buf, msg);
        try res.buf.append(",\"data\":null}");
        return;
    }
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
/// 未注册 → `noRoute`：2026-10-30 起对 `/api/*` 返回 **501 JSON**（见
/// `noRoute` 的注释），`/api/` 之外仍是前端 shell（200 HTML）。
/// ⚠ 新增端点时必须同步这里（以及下面的 dispatch），否则未登录访问新
/// 端点会拿到 501。块级粒度（`admin/storage/` 的内部子操作由
/// handler 自己校验），比 gin 的逐路由粒度略粗，边角差异见 STATUS §35。
fn isRegisteredAuthedPath(p: []const u8) bool {
    const exact = [_][]const u8{
        "/api/fs/list",           "/api/fs/get",            "/api/fs/dirs",
        "/api/fs/mkdir",          "/api/fs/rename",         "/api/fs/move",
        "/api/fs/copy",           "/api/fs/remove",         "/api/fs/put",
        "/api/fs/archive/list",   "/api/me",                "/api/me/update",
        "/api/auth/logout",       "/api/admin/storage",     "/api/admin/driver/names",
        "/api/admin/driver/list", "/api/admin/driver/info",
    };
    for (exact) |e| {
        if (std.mem.eql(u8, p, e)) return true;
    }
    // 分片上传（init/chunk/complete/status/abort）。
    if (std.mem.startsWith(u8, p, "/api/fs/multipart/")) return true;
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
    // ⚠ 2026-10-30 起对 `/api/*` 刻意偏差为 501 JSON（HTML 外壳会把真问题
    // 掩盖成"network error"，见 STATUS §55）；`/api/` 之外维持上游行为。
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
    if (std.mem.startsWith(u8, p, "/api/fs/multipart/")) return multipart.handleMultipart(app, req, res, p);
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
        return storage_admin.handleAdminStorageRoute(app, req, res, p["/api/admin/storage".len..]);
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
pub fn joinListUpper(a: std.mem.Allocator, list: []const []const u8) ![]const u8 {
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
