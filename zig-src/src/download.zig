//! 下载域（/d/ /p/ 的 handleDownload + RFC 7232 条件请求 + Range + 代理
//! 判定 + MIME 表）—— 自 api.zig 整体搬出（AUDIT-2026-11-27 路线图
//! #15-M6）。搬出为纯移动：五块逐行未动 —— mustProxyForStorage；Download
//! banner 块（contentDisposition/canProxy/isWebdavPolicy/
//! normalizeWebdavPolicy/downloadDriverError + 条件请求/Etag/Last-Modified
//! 簇 + etagFor/preconditionGate/extInList）；handleDownload + Range 簇
//! （streamRange/parseRange）；DownloadAuthError 鉴权簇；mimeFor MIME 表。
//!
//! **api.zig 自此不再 import webdav.zig** —— api↔webdav 循环引用闭环
//! （webdav 的下载辅助改指本模块；仅类型 App/Mount 仍自 api.zig 引用，
//! 而 /dav 路由自 router.zig 分发）。鉴权走 auth_mod（verifySign/
//! generateDownProxyURL），路径清洗走 mounts_mod（fixAndCleanPath）。

const std = @import("std");
const http = @import("http.zig");
const model = @import("model.zig");
const driver = @import("driver.zig");
const config = @import("config.zig");
const json = @import("util/json.zig");
const log = @import("log.zig");
const rt = @import("rt.zig");
const Buf = @import("util/buf.zig").Buf;
const List = @import("util/buf.zig").List;
const auth_mod = @import("auth.zig");
const mounts_mod = @import("mounts.zig");

const api = @import("api.zig");
const App = api.App;
const Header = api.Header;
const checkAuth = api.checkAuth;


/// Go `storage.Config().MustProxy()`（server/handles/fsread.go:314 的第一判据，
/// 定义见 internal/driver/config.go:42-44）。
///
/// 判据是**驱动声明**（`OnlyProxy || NoLinkURL`），不是某次 `link` 的结果 ——
/// 上游在这里不看 Link 上的任何标志。
pub fn mustProxyForStorage(driver_key: []const u8) bool {
    const f = driver.find(driver_key) orelse return false;
    return f.mustProxy();
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
pub fn canProxy(must_proxy: bool, web_proxy: bool, webdav_policy: []const u8, name: []const u8) bool {
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
pub fn normalizeWebdavPolicy(p: []const u8) []const u8 {
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
pub fn extInList(list: []const u8, name: []const u8) bool {
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

pub fn handleDownload(app: *App, req: *http.Request, res: *http.Response, force_proxy: bool) !void {
    const a = req.arena;
    const prefix: usize = 3; // "/d/" or "/p/"
    const raw = req.path[prefix..];
    // Go 的路由是 `g.GET("/d/*path", middlewares.PathParse, signCheck, ...)`
    // （server/router.go:49-52）—— `PathParse` 先跑，`Down` 后跑。也就是
    // rawPath 是 `utils.FixAndCleanPath(c.Param("path"))` 的结果，
    // **签名是对清洗后的路径计算的**（server/common/sign.go 签的也是同一串）。
    // 此前这里只做了 `"/" + raw`，漏了反斜杠归一与 Clean，与上游不同形。
    const path = mounts_mod.fixAndCleanPath(a, raw) catch return res.errorPage(500, "out of memory");

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
            try res.write(txt[rg.start .. rg.end + 1]);
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
    // AUDIT-2026-11-27 #4：共享代理池。不再每请求现开 Client —— 那会把
    // 连接池、TLS 会话、系统 CA 三样按请求清零，还把 `zig.ca_bundle` /
    // `zig.http_timeout` 整个绕过。响应体由池上挂的 `zig.max_proxy_body_mb`
    // 闸住：上游忽略 Range 回 200 时从「全量缓冲把设备吃死」变成明确的 507。
    const pclient = app.proxyClient();
    const up = pclient.send(a, .{
        .method = "GET",
        .url = lk.url,
        .headers = hdrs.slice(),
        // N02：回源必须跟随 3xx。CDN 普遍用 302 把请求转到实际边缘节点，
        // 不跟随就会把 302 当成上游错误、回一个 502 给用户。
        // 注意：只在这个**代理回源**点开启；天翼/itvsh 那些把 302 当业务
        // 状态的调用点保持原样，所以不能改 `Request` 的默认值。
        .follow_redirects = true,
        // 共享池不记 cookie —— 需要的 Cookie 已由驱动放进 lk.header；
        // Go 的 common.Proxy 也是无 Jar 客户端（net/http 默认 Jar 为 nil）。
        .use_cookies = false,
    }) catch |e| {
        if (e == error.ResponseTooLarge) {
            log.warn("api: proxy fetch {s}: body over zig.max_proxy_body_mb", .{lk.url});
            try res.jsonError(507, "upstream response exceeds zig.max_proxy_body_mb — raise the setting or stream via a Range request");
            res.status = 507; // jsonError 恒写 200（对齐 Go 信封），这里要真实状态码
            return;
        }
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
pub fn downloadAuthError(app: *App, req: *http.Request, raw_path: []const u8) ?DownloadAuthError {
    if (!needSign(raw_path)) return null;
    // Go `strings.TrimSuffix(s, "/")` —— 只去掉**一个**尾部斜杠。
    // Go `c.Query("sign")`（middlewares/down.go:35）也是**解码后**的值 ——
    // 客户端把 `=` 编成 `%3D` 时不解码就校验失败。
    const raw = req.queryGetDecoded("sign") catch {
        log.warn("[api] /d/ sign query decode failed for {s}", .{raw_path});
        return .sign_invalid;
    } orelse "";
    const s = if (std.mem.endsWith(u8, raw, "/")) raw[0 .. raw.len - 1] else raw;
    auth_mod.verifySign(app, req.arena, raw_path, s) catch |e| {
        log.warn("[api] /d/ sign rejected for {s}: {s}", .{ raw_path, @errorName(e) });
        return switch (e) {
            auth_mod.SignError.ExpireMissing => .expire_missing,
            auth_mod.SignError.ExpireInvalid => .expire_invalid,
            auth_mod.SignError.SignExpired => .sign_expired,
            auth_mod.SignError.SignInvalid => .sign_invalid,
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
pub fn downloadAuthMessage(e: DownloadAuthError) []const u8 {
    return switch (e) {
        .expire_missing => "expire missing",
        .expire_invalid => "expire invalid",
        .sign_expired => "sign expired",
        .sign_invalid => "sign invalid",
    };
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
