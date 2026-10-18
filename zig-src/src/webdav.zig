//! WebDAV server, mounted at `/dav`.
//!
//! Maps the WebDAV method set onto the existing `driver.Driver` vtable so the
//! nine drivers are served over WebDAV exactly as they are over the JSON API:
//!
//!   PROPFIND  -> list / details        (multistatus XML response)
//!   GET/HEAD  -> link                   (stream local files / proxy remote)
//!   PUT       -> put
//!   MKCOL     -> makeDir
//!   DELETE    -> details + remove
//!   MOVE      -> move / rename          (same-storage; cross-storage unsupported)
//!   COPY      -> link + put             (files only; directory copy unsupported)
//!   OPTIONS   -> DAV: 1 capability advertisement
//!
//! LOCK/UNLOCK/PROPPATCH are answered with 501 (PROPPATCH) or 405 (LOCK): this
//! build targets rclone, Cyberduck and the OpenList frontend's "mount as
//! WebDAV" feature, none of which require locking. Windows Explorer's MiniRedir
//! does send LOCK but falls back to unlocked access, so browsing still works.
//!
//! Authentication: WebDAV clients speak HTTP Basic. We validate the credential
//! against the single admin account (`admin_user` / `admin_hash` == SHA-256 of
//! the password), exactly as `/api/auth/login` does — there is no separate
//! WebDAV password in this single-admin build.

const std = @import("std");
const model = @import("model.zig");
const driver = @import("driver.zig");
const http = @import("http.zig");
const urlmod = @import("util/url.zig");
const time = @import("util/time.zig");
const cookiejar = @import("cookiejar.zig");
const client_mod = @import("client.zig");
const log = @import("log.zig");
const rt = @import("rt.zig");
const Buf = @import("util/buf.zig").Buf;
const List = @import("util/buf.zig").List;
const api = @import("api.zig");
const App = api.App;

const eql = std.mem.eql;

const Depth = enum { zero, one, infinity };

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn handle(app: *App, req: *http.Request, res: *http.Response) !void {
    // OPTIONS is advertised without auth so capability discovery works.
    if (eql(u8, req.method, "OPTIONS")) return options(res);

    if (!try checkBasic(app, req)) {
        res.setStatus(401);
        try res.set("WWW-Authenticate", "Basic realm=\"OpenList\"");
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("401 Unauthorized");
        return;
    }

    const m = req.method;
    if (eql(u8, m, "PROPFIND")) return propfind(app, req, res);
    if (eql(u8, m, "GET") or eql(u8, m, "HEAD")) return getOrHead(app, req, res, eql(u8, m, "HEAD"));
    if (eql(u8, m, "PUT")) return put(app, req, res);
    if (eql(u8, m, "MKCOL")) return mkcol(app, req, res);
    if (eql(u8, m, "DELETE")) return delete(app, req, res);
    if (eql(u8, m, "COPY")) return copy(app, req, res);
    if (eql(u8, m, "MOVE")) return move(app, req, res);
    if (eql(u8, m, "PROPPATCH")) {
        // No dead properties are stored; acknowledge with an empty multistatus.
        var out = Buf.init(req.arena);
        try out.append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\"/>\n");
        res.setStatus(207);
        try res.set("Content-Type", "text/xml; charset=utf-8");
        try res.write(out.slice());
        return;
    }
    // LOCK/UNLOCK and anything else: method not allowed.
    res.setStatus(405);
    try res.set("Allow", "OPTIONS,GET,HEAD,PUT,DELETE,MKCOL,PROPFIND,COPY,MOVE,PROPPATCH");
    try res.set("Content-Type", "text/plain; charset=utf-8");
    try res.write("method not allowed");
}

pub fn options(res: *http.Response) !void {
    res.setStatus(200);
    try res.set("DAV", "1");
    try res.set("Allow", "OPTIONS,GET,HEAD,PUT,DELETE,MKCOL,PROPFIND,COPY,MOVE,PROPPATCH");
    try res.set("Content-Length", "0");
    try res.set("Content-Type", "text/plain; charset=utf-8");
}

// ---------------------------------------------------------------------------
// PROPFIND
// ---------------------------------------------------------------------------

fn propfind(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const vpath = vpathOf(req.path);
    const depth = parseDepth(req.header("Depth"));

    var out = Buf.init(a);
    try out.append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try out.append("<D:multistatus xmlns:D=\"DAV:\">\n");

    if (eql(u8, vpath, "/")) {
        try writeColEntry(a, &out, "/", "");
        if (depth != .zero) try writeRootChildren(app, a, &out, depth);
    } else {
        const r = app.resolve(vpath) orelse {
            res.setStatus(404);
            try res.set("Content-Type", "text/plain; charset=utf-8");
            try res.write("not found");
            return;
        };
        var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
        const f = r.mount.driver.details(&ctx, r.rel) catch |e| return webdavErr(res, e);
        if (f.is_dir) {
            try writeColEntry(a, &out, vpath, f.name);
            if (depth != .zero) try walkDir(app, a, &out, vpath, depth);
        } else {
            try writeObjEntry(a, &out, vpath, .{
                .name = f.name,
                .size = f.size,
                .is_dir = f.is_dir,
                .modified = f.modified,
                .created = f.created,
                .sign = f.sign,
                .thumb = f.thumb,
                .hash_info = f.hash_info,
            });
        }
    }

    try out.append("</D:multistatus>\n");
    res.setStatus(207);
    try res.set("DAV", "1");
    try res.set("Content-Type", "text/xml; charset=utf-8");
    try res.write(out.slice());
}

/// The virtual root shows one entry per mount, exactly like `/api/fs/list`
/// with path "/". If the only mount is "/", its contents are listed directly.
fn writeRootChildren(app: *App, a: std.mem.Allocator, out: *Buf, depth: Depth) !void {
    // T6：mounts 可能仍在后台发布中 —— 取一次快照，后面 walkDir 也用同一份。
    const mounts = app.mountsSnapshot();
    var has_root = false;
    var has_other = false;
    for (mounts) |m| {
        if (eql(u8, m.mount_path, "/")) has_root = true else has_other = true;
    }
    if (has_root and !has_other) {
        try walkDir(app, a, out, "/", depth);
        return;
    }
    for (mounts) |m| {
        if (eql(u8, m.mount_path, "/")) continue;
        const name = std.mem.trim(u8, m.mount_path, "/");
        const cv = try std.fmt.allocPrint(a, "/{s}", .{name});
        try writeObjEntry(a, out, cv, .{ .name = name, .is_dir = true });
    }
}

/// Append `<D:response>` entries for every child of `vpath` (one directory
/// deep for `Depth.one`, recursively for `Depth.infinity`).
fn walkDir(app: *App, a: std.mem.Allocator, out: *Buf, vpath: []const u8, depth: Depth) !void {
    const r = app.resolve(vpath) orelse return;
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    const objs = r.mount.driver.list(&ctx, r.rel) catch return;
    for (objs) |o| {
        const cv = try urlmod.joinPath(a, vpath, o.name);
        try writeObjEntry(a, out, cv, o);
        if (depth == .infinity and o.is_dir) {
            try walkDir(app, a, out, cv, depth);
        }
    }
}

fn writeColEntry(a: std.mem.Allocator, out: *Buf, vpath: []const u8, name: []const u8) !void {
    const href = try davHref(a, vpath);
    try out.print("  <D:response>\n    <D:href>{s}</D:href>\n", .{href});
    try out.append("    <D:propstat>\n      <D:prop>\n        <D:resourcetype><D:collection/></D:resourcetype>\n");
    const mod = cookiejar.httpDate(a, 0) catch "Thu, 01 Jan 1970 00:00:00 GMT";
    try out.print("        <D:getlastmodified>{s}</D:getlastmodified>\n", .{mod});
    try out.append("        <D:displayname>");
    try xmlEscape(out, name);
    try out.append("</D:displayname>\n      </D:prop>\n      <D:status>HTTP/1.1 200 OK</D:status>\n    </D:propstat>\n  </D:response>\n");
}

fn writeObjEntry(a: std.mem.Allocator, out: *Buf, vpath: []const u8, o: model.Obj) !void {
    const href = try davHref(a, vpath);
    try out.print("  <D:response>\n    <D:href>{s}</D:href>\n", .{href});
    try out.append("    <D:propstat>\n      <D:prop>\n");
    if (o.is_dir) {
        try out.append("        <D:resourcetype><D:collection/></D:resourcetype>\n");
    } else {
        try out.append("        <D:resourcetype/>\n");
        try out.print("        <D:getcontentlength>{d}</D:getcontentlength>\n", .{o.size});
        try out.print("        <D:getcontenttype>{s}</D:getcontenttype>\n", .{api.mimeFor(o.name)});
    }
    const mod = cookiejar.httpDate(a, o.modified) catch "Thu, 01 Jan 1970 00:00:00 GMT";
    try out.print("        <D:getlastmodified>{s}</D:getlastmodified>\n", .{mod});
    try out.append("        <D:displayname>");
    try xmlEscape(out, o.name);
    try out.append("</D:displayname>\n      </D:prop>\n      <D:status>HTTP/1.1 200 OK</D:status>\n    </D:propstat>\n  </D:response>\n");
}

// ---------------------------------------------------------------------------
// GET / HEAD
// ---------------------------------------------------------------------------

fn getOrHead(app: *App, req: *http.Request, res: *http.Response, is_head: bool) !void {
    const a = req.arena;
    const vpath = vpathOf(req.path);
    const r = app.resolve(vpath) orelse {
        res.setStatus(404);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("not found");
        return;
    };
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    const f = r.mount.driver.details(&ctx, r.rel) catch |e| return webdavErr(res, e);
    if (f.is_dir) {
        res.setStatus(404);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("is a directory");
        return;
    }
    const lk = r.mount.driver.link(&ctx, r.rel, .{ .redirect = false }) catch |e| return webdavErr(res, e);

    if (lk.local_path) |lp| {
        if (is_head) {
            try res.set("Content-Type", api.mimeFor(f.name));
            if (lk.local_size > 0) try res.set("Content-Length", try fmtSize(a, lk.local_size));
            return;
        }
        const file = std.Io.Dir.cwd().openFile(rt.io(), lp, .{}) catch |e| {
            log.warn("webdav: open {s}: {s}", .{ lp, @errorName(e) });
            res.setStatus(500);
            try res.set("Content-Type", "text/plain; charset=utf-8");
            try res.write("cannot open file");
            return;
        };
        try res.set("Content-Type", api.mimeFor(f.name));
        try res.set("Accept-Ranges", "none");
        res.sendFile(file, lk.local_size);
        return;
    }

    // Remote file: proxy through. Streaming is a follow-up; we buffer the
    // response the same way the JSON download endpoint does.
    if (is_head) {
        try res.set("Content-Type", api.mimeFor(f.name));
        if (f.size > 0) try res.set("Content-Length", try fmtSize(a, @intCast(f.size)));
        return;
    }
    var jar = cookiejar.Jar.init(a);
    var client = client_mod.Client.init(a, .{}, &jar);
    defer client.deinit();
    // W01：把客户端的 Range 透传给上游，并原样回传 206/Content-Range。
    // 之前这里不传 Range、又只接受 200，`/dav` 的断点续传根本走不通
    // （`/d` 的 Range 测试证明不了 `/dav` 支持）。
    var hdrs = List(model.Header).init(a);
    for (lk.header) |h| try hdrs.append(h);
    if (req.header("Range")) |rh| try hdrs.append(.{ .name = "Range", .value = rh });

    const up = client.send(a, .{
        .method = "GET",
        .url = lk.url,
        .headers = hdrs.slice(),
        // N02：回源跟随 3xx，CDN 用 302 转边缘节点，不跟随就变 502。
        .follow_redirects = true,
    }) catch |e| {
        log.warn("webdav: proxy {s}: {s}", .{ lk.url, @errorName(e) });
        res.setStatus(502);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("upstream fetch failed");
        return;
    };
    if (up.status != 200 and up.status != 206) {
        res.setStatus(502);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("upstream error");
        return;
    }
    try res.set("Content-Type", api.mimeFor(f.name));
    try res.set("Accept-Ranges", "bytes");
    if (up.status == 206) {
        res.setStatus(206);
        if (up.header("Content-Range")) |cr| try res.set("Content-Range", cr);
    }
    try res.write(up.body);
}

// ---------------------------------------------------------------------------
// PUT / MKCOL / DELETE
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// ETag 与条件请求 —— 对齐 Go `internal/net/preconditions.go`（上游 8cfe906e
// 把它接到 WebDAV 的 PUT 上）与 `server/common/proxy.go:90` 的 `GetEtag`。
//
// 为什么值得做：标准 WebDAV 客户端（挂载盘、rsync 类同步工具）靠
// `If-None-Match: *` 表达"不存在才写入"。此前这里恒返回 201 且完全不看条件头，
// 于是"只写新文件"的客户端每次都整份重传，冲突覆盖也无从谈起。
// ---------------------------------------------------------------------------

const Cond = enum { none, yes, no };

/// Go `common.GetEtag(file, size)`：有 hash 用 hash，否则退化成
/// `"<hex(mtime 秒)>-<hex(size)>"`。
///
/// ⚠️ 用**秒**不是纳秒：上游注释写明存储后端不保证亚秒精度能跨缓存刷新复现，
/// 用纳秒会让同一文件每次 stat 拿到不同 ETag，条件请求永远不成立。
fn etagFor(a: std.mem.Allocator, f: driver.File) ![]const u8 {
    if (f.hash_info) |hi| {
        if (hi.hash_value.len > 0) return std.fmt.allocPrint(a, "\"{s}\"", .{hi.hash_value});
    }
    return std.fmt.allocPrint(a, "\"{x}-{x}\"", .{ f.modified, f.size });
}

fn trimWs(s: []const u8) []const u8 {
    var i: usize = 0;
    var j: usize = s.len;
    while (i < j and (s[i] == ' ' or s[i] == '\t')) i += 1;
    while (j > i and (s[j - 1] == ' ' or s[j - 1] == '\t')) j -= 1;
    return s[i..j];
}

/// Go `internal/net/preconditions.go:11` 的 `scanETag`：识别 `W/"x"` 或 `"x"`，
/// 返回 ETag 本身与剩余文本。
fn scanETag(s: []const u8) ?struct { etag: []const u8, remain: []const u8 } {
    const t = trimWs(s);
    var start: usize = 0;
    if (std.mem.startsWith(u8, t, "W/")) start = 2;
    if (t.len < start + 2 or t[start] != '"') return null;
    var i: usize = start + 1;
    while (i < t.len) : (i += 1) {
        const c = t[i];
        if (c == '"') return .{ .etag = t[0 .. i + 1], .remain = t[i + 1 ..] };
        // RFC 7232 §2.3 允许的 ETag 字符
        const ok = c == 0x21 or (c >= 0x23 and c <= 0x7e) or c >= 0x80;
        if (!ok) return null;
    }
    return null;
}

fn etagStrongMatch(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b) and a.len > 0 and a[0] == '"';
}

/// Go `etagWeakMatch`：`strings.TrimPrefix(a, "W/") == strings.TrimPrefix(b, "W/")`。
/// 必须是**整串前缀**，不能写成按字符集合 trim（那会把 `"W"` 开头的强 ETag 也剥掉）。
fn stripWeakPrefix(s: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, s, "W/")) s[2..] else s;
}

fn etagWeakMatch(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, stripWeakPrefix(a), stripWeakPrefix(b));
}

/// HTTP 日期解析（Go `http.ParseTime`）。这里支持 RFC 7231 要求发送方必须
/// 产生的 IMF-fixdate（"Mon, 02 Jan 2006 15:04:05 GMT"）以及常见的
/// RFC 850 / asctime 两种老格式；解析不出来时**返回 null**，调用方按 Go 的
/// 语义把它当 `condNone`（忽略该条件头），不会误判成 412。
fn parseHttpTime(s: []const u8) ?i64 {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    const tok = [4][]const u8{ it.next() orelse return null, it.next() orelse return null,
        it.next() orelse return null, it.next() orelse return null };
    var day_s: []const u8 = undefined;
    var mon_s: []const u8 = undefined;
    var year_s: []const u8 = undefined;
    var time_s: []const u8 = undefined;
    var zone_s: []const u8 = undefined;

    // IMF-fixdate:  Mon,  02  Jan  2006  15:04:05  GMT
    if (tok[1].len == 2 and std.ascii.isDigit(tok[1][0]) and std.ascii.isDigit(tok[1][1]) and
        (tok[2].len == 3 or tok[2].len == 4 and tok[2][3] == ','))
    {
        day_s = tok[1];
        mon_s = tok[2][0..3];
        year_s = tok[3];
        time_s = it.next() orelse return null;
        zone_s = it.next() orelse return null;
    } else if (std.mem.indexOfScalar(u8, tok[1], '-') != null) {
        // RFC 850:  Monday, 02-Jan-06 15:04:05 MST   （逗号已在 tokenize 里按空白切，
        // 但这一种的首段常带逗号，故按 '-' 分段）
        var p = std.mem.splitScalar(u8, tok[1], '-');
        day_s = p.next() orelse return null;
        mon_s = p.next() orelse return null;
        year_s = p.next() orelse return null;
        time_s = tok[2];
        zone_s = tok[3];
    } else {
        // asctime:  Mon Jan  2 15:04:05 2006  （注意年是最后一个 token）
        mon_s = tok[1];
        day_s = tok[2];
        time_s = tok[3];
        year_s = it.next() orelse return null;
        zone_s = "GMT";
    }

    if (!std.ascii.eqlIgnoreCase(zone_s, "GMT") and !std.ascii.eqlIgnoreCase(zone_s, "UTC")) return null;

    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    var month: i64 = -1;
    for (month_names, 0..) |m, i| {
        if (std.ascii.eqlIgnoreCase(m, mon_s)) month = @intCast(i + 1);
    }
    if (month < 0) return null;

    const day = std.fmt.parseInt(i64, day_s, 10) catch return null;
    var year = std.fmt.parseInt(i64, year_s, 10) catch return null;
    if (year < 100) year += if (year < 70) 2000 else 1900; // RFC 850 的两位年

    var tp = std.mem.splitScalar(u8, time_s, ':');
    const hh = std.fmt.parseInt(i64, tp.next() orelse return null, 10) catch return null;
    const mm = std.fmt.parseInt(i64, tp.next() orelse return null, 10) catch return null;
    const ss = std.fmt.parseInt(i64, tp.next() orelse return null, 10) catch return null;

    return time.daysFromCivil(year, month, day) * 86400 + hh * 3600 + mm * 60 + ss;
}

fn checkIfMatch(a: std.mem.Allocator, req: *const http.Request, etag: []const u8, exists: bool) !Cond {
    const vals = try req.headersAll(a, "If-Match");
    if (vals.len == 0) return .none;
    var joined = Buf.init(a);
    for (vals, 0..) |v, i| {
        if (i != 0) try joined.appendByte(',');
        try joined.append(v);
    }
    if (!exists) return .no;
    var im = joined.slice();
    while (true) {
        im = trimWs(im);
        if (im.len == 0) break;
        if (im[0] == ',') {
            im = im[1..];
            continue;
        }
        if (im[0] == '*') return .yes;
        const r = scanETag(im) orelse break;
        if (etagStrongMatch(r.etag, etag)) return .yes;
        im = r.remain;
    }
    return .no;
}

fn checkIfNoneMatch(a: std.mem.Allocator, req: *const http.Request, etag: []const u8, exists: bool) !Cond {
    const vals = try req.headersAll(a, "If-None-Match");
    if (vals.len == 0) return .none;
    var joined = Buf.init(a);
    for (vals, 0..) |v, i| {
        if (i != 0) try joined.appendByte(',');
        try joined.append(v);
    }
    if (!exists) return .yes;
    var buf = joined.slice();
    while (true) {
        buf = trimWs(buf);
        if (buf.len == 0) break;
        if (buf[0] == ',') {
            buf = buf[1..];
            continue;
        }
        if (buf[0] == '*') return .no;
        const r = scanETag(buf) orelse break;
        if (etagWeakMatch(r.etag, etag)) return .no;
        buf = r.remain;
    }
    return .yes;
}

fn checkIfUnmodifiedSince(req: *const http.Request, modtime: i64) Cond {
    const v = req.header("If-Unmodified-Since") orelse return .none;
    if (modtime == 0) return .none; // Go `isZeroTime`
    const t = parseHttpTime(v) orelse return .none;
    return if (modtime <= t) .yes else .no;
}

fn checkIfModifiedSince(req: *const http.Request, modtime: i64) Cond {
    // Go：只对 GET / HEAD 生效
    if (!eql(u8, req.method, "GET") and !eql(u8, req.method, "HEAD")) return .none;
    const v = req.header("If-Modified-Since") orelse return .none;
    if (modtime == 0) return .none;
    const t = parseHttpTime(v) orelse return .none;
    return if (modtime <= t) .no else .yes;
}

/// 对齐 Go `internal/net/preconditions.go` 末尾的 `writeNotModified`（RFC 7232 §4.1）。
fn writeNotModified(res: *http.Response) !void {
    res.setStatus(304);
    try res.set("Content-Length", "0");
}

/// 对齐 Go `net.CheckPreconditions`：返回 true 表示条件头已经决定了响应
/// （304 / 412），调用方必须就此返回、不再执行实际操作。
fn checkPreconditions(a: std.mem.Allocator, req: *const http.Request, res: *http.Response, etag: []const u8, modtime: i64, exists: bool) !bool {
    var ch = try checkIfMatch(a, req, etag, exists);
    if (ch == .none) ch = checkIfUnmodifiedSince(req, modtime);
    if (ch == .no) {
        res.setStatus(412);
        try res.set("Content-Length", "0");
        return true;
    }
    switch (try checkIfNoneMatch(a, req, etag, exists)) {
        .no => {
            if (eql(u8, req.method, "GET") or eql(u8, req.method, "HEAD")) {
                try writeNotModified(res);
            } else {
                res.setStatus(412);
                try res.set("Content-Length", "0");
            }
            return true;
        },
        .none => {
            if (checkIfModifiedSince(req, modtime) == .no) {
                try writeNotModified(res);
                return true;
            }
        },
        .yes => {},
    }
    return false;
}

fn put(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const vpath = vpathOf(req.path);
    const r = app.resolve(vpath) orelse {
        res.setStatus(404);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("not found");
        return;
    };
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };

    // 对齐上游 `handlePut`（webdav.go:398-415）：PUT **之前**先 stat ——
    // 目标已存在且是目录 ⇒ 405 Method Not Allowed（覆盖目录没有意义）。
    var exists = false;
    var modtime: i64 = 0;
    var etag: []const u8 = "";
    if (r.mount.driver.details(&ctx, r.rel)) |f| {
        if (f.is_dir) {
            res.setStatus(405);
            try res.set("Content-Length", "0");
            return;
        }
        exists = true;
        modtime = f.modified;
        etag = try etagFor(a, f);
    } else |_| {}

    // 条件请求：If-Match / If-Unmodified-Since / If-None-Match 不满足 ⇒ 412，
    // 且**不执行**上传。
    if (try checkPreconditions(a, req, res, etag, modtime, exists)) return;

    r.mount.driver.put(&ctx, r.rel, req.body.source()) catch |e| return webdavErr(res, e);
    // 上游：已存在 ⇒ 204，新建 ⇒ 201（此前这里恒 201，客户端无法区分覆盖与新建）。
    res.setStatus(if (exists) 204 else 201);
    // 上游写完会再 stat 一次拿新 ETag；拿不到就干脆不发这个头，
    // 也好过发一个已经过期的旧值。
    if (r.mount.driver.details(&ctx, r.rel)) |f| {
        try res.set("ETag", try etagFor(a, f));
    } else |_| {}
    try res.set("Content-Length", "0");
}

fn mkcol(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const vpath = vpathOf(req.path);
    const r = app.resolve(vpath) orelse {
        res.setStatus(404);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("not found");
        return;
    };
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    // RFC 4918 §9.3.1：目标集合已存在时 MKCOL 必须返回 405，而不是 502。
    // 真机上这里曾经把「已存在」报成 502（错误名 `Unexpected` 被 webdavErr
    // 兜到默认分支）。驱动侧虽然已经容错，但协议上仍应显式区分。
    if (r.mount.driver.details(&ctx, r.rel)) |f| {
        if (f.is_dir) {
            res.setStatus(405);
            try res.set("Content-Length", "0");
            return;
        }
    } else |_| {}

    r.mount.driver.makeDir(&ctx, r.rel) catch |e| return webdavErr(res, e);
    res.setStatus(201);
    try res.set("Content-Length", "0");
}

fn delete(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const vpath = vpathOf(req.path);
    const r = app.resolve(vpath) orelse {
        res.setStatus(404);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("not found");
        return;
    };
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    const f = r.mount.driver.details(&ctx, r.rel) catch |e| return webdavErr(res, e);
    r.mount.driver.remove(&ctx, r.rel, f.is_dir) catch |e| return webdavErr(res, e);
    res.setStatus(204);
}

// ---------------------------------------------------------------------------
// MOVE / COPY
// ---------------------------------------------------------------------------

fn move(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const src = vpathOf(req.path);
    const dest_hdr = req.header("Destination") orelse {
        res.setStatus(400);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("Destination header required");
        return;
    };
    const dst = try destVpath(a, dest_hdr) orelse {
        res.setStatus(400);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("bad Destination");
        return;
    };
    const sr = app.resolve(src) orelse {
        res.setStatus(404);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("source not found");
        return;
    };
    const dr = app.resolve(dst) orelse {
        res.setStatus(404);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("destination not found");
        return;
    };
    if (sr.mount != dr.mount) {
        res.setStatus(502);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("cross-storage move not supported");
        return;
    }

    var ctx = driver.Ctx{ .alloc = a, .tag = sr.mount.mount_path };
    const src_parent = urlmod.parentPath(sr.rel);
    const dst_parent = urlmod.parentPath(dr.rel);
    const src_name = urlmod.baseName(sr.rel);
    const dst_name = urlmod.baseName(dr.rel);

    if (eql(u8, src_parent, dst_parent)) {
        if (eql(u8, src_name, dst_name)) {
            res.setStatus(204); // same place: no-op
            return;
        }
        sr.mount.driver.rename(&ctx, sr.rel, dst_name) catch |e| return webdavErr(res, e);
    } else {
        sr.mount.driver.move(&ctx, sr.rel, dst_parent) catch |e| return webdavErr(res, e);
        if (!eql(u8, src_name, dst_name)) {
            const moved_rel = try urlmod.joinPath(a, dst_parent, src_name);
            sr.mount.driver.rename(&ctx, moved_rel, dst_name) catch |e| return webdavErr(res, e);
        }
    }
    res.setStatus(201);
    try res.set("Content-Length", "0");
}

fn copy(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const src = vpathOf(req.path);
    const dest_hdr = req.header("Destination") orelse {
        res.setStatus(400);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("Destination header required");
        return;
    };
    const dst = try destVpath(a, dest_hdr) orelse {
        res.setStatus(400);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("bad Destination");
        return;
    };
    const sr = app.resolve(src) orelse {
        res.setStatus(404);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("source not found");
        return;
    };
    const dr = app.resolve(dst) orelse {
        res.setStatus(404);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("destination not found");
        return;
    };
    if (sr.mount != dr.mount) {
        res.setStatus(502);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("cross-storage copy not supported");
        return;
    }

    var ctx = driver.Ctx{ .alloc = a, .tag = sr.mount.mount_path };
    const f = sr.mount.driver.details(&ctx, sr.rel) catch |e| return webdavErr(res, e);
    if (f.is_dir) {
        res.setStatus(501);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("directory copy not supported");
        return;
    }
    const lk = sr.mount.driver.link(&ctx, sr.rel, .{ .redirect = false }) catch |e| return webdavErr(res, e);
    const data = fetchBytes(a, lk) catch |e| {
        log.warn("webdav: copy fetch: {s}", .{@errorName(e)});
        res.setStatus(502);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("copy source fetch failed");
        return;
    };
    const src_mem = memSource(&data);
    dr.mount.driver.put(&ctx, dr.rel, src_mem) catch |e| return webdavErr(res, e);
    res.setStatus(201);
    try res.set("Content-Length", "0");
}

/// Read a link's bytes into memory. Used by COPY (and would be by a future
/// ranged GET). Local files are read straight off disk; remote links are
/// fetched through the shared client.
fn fetchBytes(a: std.mem.Allocator, lk: model.Link) ![]u8 {
    if (lk.local_path) |lp| {
        const file = std.Io.Dir.cwd().openFile(rt.io(), lp, .{}) catch return error.CannotOpen;
        defer file.close(rt.io());
        const buf = try a.alloc(u8, @intCast(lk.local_size));
        var got: usize = 0;
        while (got < buf.len) {
            const n = try std.Io.File.readPositionalAll(file, rt.io(), buf[got..], got);
            if (n == 0) return error.UnexpectedEof;
            got += n;
        }
        return buf;
    }
    var jar = cookiejar.Jar.init(a);
    var client = client_mod.Client.init(a, .{}, &jar);
    defer client.deinit();
    const up = try client.send(a, .{ .method = "GET", .url = lk.url, .headers = lk.header });
    if (up.status != 200) return error.UpstreamError;
    return try a.dupe(u8, up.body);
}

fn memSource(data: *const []u8) model.Source {
    return .{ .ptr = @ptrCast(@constCast(data)), .vtable = &mem_source_vtable };
}

const mem_source_vtable = model.Source.VTable{
    .size = struct {
        fn f(ptr: *anyopaque) i64 {
            const d: *const []u8 = @ptrCast(@alignCast(ptr));
            return @intCast(d.len);
        }
    }.f,
    .readAt = struct {
        fn f(ptr: *anyopaque, offset: u64, buf: []u8) anyerror!usize {
            const d: *const []u8 = @ptrCast(@alignCast(ptr));
            if (offset >= d.len) return 0;
            const n = @min(buf.len, d.len - offset);
            @memcpy(buf[0..n], d.*[offset..][0..n]);
            return n;
        }
    }.f,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn vpathOf(rp: []const u8) []const u8 {
    if (eql(u8, rp, "/dav")) return "/";
    if (std.mem.startsWith(u8, rp, "/dav/")) return rp[4..]; // "/dav/" -> "/"
    return rp;
}

fn davHref(alloc: std.mem.Allocator, vpath: []const u8) ![]u8 {
    const enc = try urlmod.encode(alloc, vpath, .path);
    return std.fmt.allocPrint(alloc, "/dav{s}", .{enc});
}

fn destVpath(a: std.mem.Allocator, dest: []const u8) !?[]u8 {
    var path = dest;
    if (std.mem.startsWith(u8, dest, "http://") or std.mem.startsWith(u8, dest, "https://")) {
        const after = std.mem.indexOf(u8, dest, "://").? + 3;
        const slash = std.mem.indexOfScalar(u8, dest[after..], '/') orelse return null;
        path = dest[after + slash ..];
    }
    if (eql(u8, path, "/dav")) return try a.dupe(u8, "/");
    if (std.mem.startsWith(u8, path, "/dav/")) path = path[4..];
    return urlmod.decode(a, path) catch null;
}

fn parseDepth(h: ?[]const u8) Depth {
    const d = (h orelse "1");
    if (eql(u8, d, "0")) return .zero;
    if (eql(u8, d, "infinity")) return .infinity;
    return .one;
}

fn xmlEscape(out: *Buf, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.append("&amp;"),
        '<' => try out.append("&lt;"),
        '>' => try out.append("&gt;"),
        '"' => try out.append("&quot;"),
        '\'' => try out.append("&apos;"),
        else => try out.appendByte(c),
    };
}

fn fmtSize(a: std.mem.Allocator, n: u64) ![]u8 {
    return std.fmt.allocPrint(a, "{d}", .{n});
}

fn webdavErr(res: *http.Response, e: anyerror) !void {
    const st: u16 = switch (e) {
        error.NotFound => 404,
        error.AuthFailed, error.ConfiguredTokenExpired => 401,
        error.NotSupported => 501,
        error.RateLimited => 429,
        else => 502,
    };
    res.setStatus(st);
    try res.set("Content-Type", "text/plain; charset=utf-8");
    try res.write(@errorName(e));
}

fn checkBasic(app: *App, req: *http.Request) !bool {
    if (app.admin_hash.len == 0) return false; // setup not done
    const h = req.header("Authorization") orelse return false;
    if (h.len < 6 or !std.ascii.eqlIgnoreCase(h[0..6], "Basic ")) return false;
    const b64 = h[6..];
    const dec = std.base64.standard.Decoder;
    const buf = try req.arena.alloc(u8, dec.calcSizeForSlice(b64) catch return false);
    dec.decode(buf, b64) catch return false;
    const colon = std.mem.indexOfScalar(u8, buf, ':') orelse return false;
    const user = buf[0..colon];
    const pass = buf[colon + 1 ..];
    if (!eql(u8, user, app.admin_user)) return false;
    const hash = sha256Hex(req.arena, pass);
    return ctEqual(hash, app.admin_hash);
}

fn sha256Hex(a: std.mem.Allocator, s: []const u8) []u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s, &digest, .{});
    const out = a.alloc(u8, 64) catch return "";
    const hex = "0123456789abcdef";
    for (digest, 0..) |c, i| {
        out[i * 2] = hex[c >> 4];
        out[i * 2 + 1] = hex[c & 0x0F];
    }
    return out;
}

fn ctEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) {
        var acc: u8 = @intCast(a.len ^ b.len);
        for (a) |c| acc |= c;
        for (b) |c| acc |= c;
        return false;
    }
    var acc: u8 = 0;
    for (a, b) |x, y| acc |= x ^ y;
    return acc == 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "vpathOf strips the /dav prefix" {
    try testing.expectEqualStrings("/", vpathOf("/dav"));
    try testing.expectEqualStrings("/", vpathOf("/dav/"));
    try testing.expectEqualStrings("/Movies", vpathOf("/dav/Movies"));
    try testing.expectEqualStrings("/Movies/a b.mp4", vpathOf("/dav/Movies/a b.mp4"));
}

test "destVpath parses absolute and path Destination headers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("/x/y", (try destVpath(a, "http://host:5244/dav/x/y")).?);
    try testing.expectEqualStrings("/x", (try destVpath(a, "/dav/x")).?);
    try testing.expectEqualStrings("/", (try destVpath(a, "/dav")).?);
}

test "xmlEscape covers the five predefined entities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var b = Buf.init(arena.allocator());
    try xmlEscape(&b, "<a&b'c\"d>");
    try testing.expectEqualStrings("&lt;a&amp;b&apos;c&quot;d&gt;", b.slice());
}

test "webdav: PROPFIND requires auth and lists a mounted directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var stub = Stub{};
    const drv = stub.toDriver();
    var mounts = try a.alloc(api.Mount, 1);
    mounts[0] = .{ .storage = .{ .driver = "Stub" }, .driver = drv, .mount_path = "/v", .label = "v" };
    var app = App{
        .alloc = a,
        .mounts = mounts,
        .admin_hash = sha256Hex(a, "pass"),
        .admin_user = "admin",
        .admin_pwd_ts = 0,
        .jwt_secret = "s",
        .site_url = "",
        .cdn = "",
        .token_expires_in_hours = 48,
        .frontend = undefined,
    };

    // No credential -> 401.
    var req = http.Request{ .arena = a, .method = "PROPFIND", .path = "/dav/v", .target = "/dav/v" };
    var res = http.Response.init(a);
    try handle(&app, &req, &res);
    try testing.expectEqual(@as(u16, 401), res.status);

    // With Basic auth -> 207 multistatus containing both children.
    var req2 = http.Request{ .arena = a, .method = "PROPFIND", .path = "/dav/v", .target = "/dav/v" };
    var auth_hdr = [_]model.Header{ .{ .name = "Authorization", .value = "Basic YWRtaW46cGFzcw==" } };
    req2.headers = &auth_hdr;
    var res2 = http.Response.init(a);
    try handle(&app, &req2, &res2);
    try testing.expectEqual(@as(u16, 207), res2.status);
    const body = res2.buf.slice();
    try testing.expect(std.mem.indexOf(u8, body, "<D:multistatus") != null);
    try testing.expect(std.mem.indexOf(u8, body, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, body, "sub") != null);
    try testing.expect(std.mem.indexOf(u8, body, "getcontentlength") != null);
}

test "webdav: OPTIONS advertises DAV without auth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var res = http.Response.init(a);
    try options(&res);
    try testing.expectEqual(@as(u16, 200), res.status);
    var found: bool = false;
    for (res.headers.slice()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "DAV") and std.mem.eql(u8, h.value, "1")) found = true;
    }
    try testing.expect(found);
}

/// In-test driver that returns a fixed directory, so PROPFIND can be exercised
/// without any network or config.
const Stub = struct {
    fn vname(_: *anyopaque) []const u8 {
        return "Stub";
    }
    fn vinit(_: *anyopaque, _: *driver.Ctx) !void {}
    fn vdeinit(_: *anyopaque, _: *driver.Ctx) void {}
    fn vlist(_: *anyopaque, ctx: *driver.Ctx, dir: []const u8) ![]model.Obj {
        _ = dir;
        var objs = try ctx.alloc.alloc(model.Obj, 2);
        objs[0] = .{ .name = "a.txt", .size = 10, .is_dir = false, .modified = 1_000_000_000 };
        objs[1] = .{ .name = "sub", .is_dir = true, .modified = 2_000_000_000 };
        return objs;
    }
    fn vdetails(_: *anyopaque, ctx: *driver.Ctx, path: []const u8) !model.File {
        _ = ctx;
        if (eql(u8, path, "/")) return .{ .name = "", .is_dir = true };
        return .{ .name = path, .is_dir = false, .size = 10 };
    }
    fn vlink(_: *anyopaque, _: *driver.Ctx, _: []const u8, _: model.LinkArgs) !model.Link {
        return .{ .local_path = "/tmp/x", .local_size = 10 };
    }
    fn vmakeDir(_: *anyopaque, _: *driver.Ctx, _: []const u8) !void {}
    fn vmove(_: *anyopaque, _: *driver.Ctx, _: []const u8, _: []const u8) !void {}
    fn vrename(_: *anyopaque, _: *driver.Ctx, _: []const u8, _: []const u8) !void {}
    fn vremove(_: *anyopaque, _: *driver.Ctx, _: []const u8, _: bool) !void {}
    fn vput(_: *anyopaque, _: *driver.Ctx, _: []const u8, _: model.Source) !void {}

    const vtable: driver.Driver.VTable = .{
        .name = vname,
        .init = vinit,
        .deinit = vdeinit,
        .list = vlist,
        .details = vdetails,
        .link = vlink,
        .makeDir = vmakeDir,
        .move = vmove,
        .rename = vrename,
        .remove = vremove,
        .put = vput,
        .space = null,
    };

    fn toDriver(self: *Stub) driver.Driver {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }
};
