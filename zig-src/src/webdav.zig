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
//! against the single admin account (`admin_user` / `admin_hash`), exactly as
//! `/api/auth/login` does — there is no separate WebDAV password in this
//! single-admin build.
//!
//! ⚠️ `admin_hash` is **not** a bare SHA-256 of the password: it is Go's
//! `model.TwoHashPwd` = `sha256(sha256(pw + "-" + StaticHashSalt) + "-" +
//! salt)` (see `api.twoHashPwd` and the `admin_hash` doc comment in api.zig).
//! Comparing `sha256(pw)` against it can never succeed — that was a real bug
//! (every WebDAV client got a 401) until the e2e regression caught it
//! 2026-10-16. The JSON login path was always right; this path now shares the
//! same helper.

const std = @import("std");
const model = @import("model.zig");
const driver = @import("driver.zig");
const http = @import("http.zig");
const urlmod = @import("util/url.zig");
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
    // Go `WebDAVAuth`（server/webdav.go:86-90）：拿不到凭据时 **OPTIONS 会被
    // 放行**（以 guest 身份继续），能力探测因此不需要鉴权。其余方法一律 401。
    if (eql(u8, req.method, "OPTIONS")) return options(app, req, res);

    if (!try checkBasic(app, req)) {
        // Go `WebDAVAuth`（server/webdav.go:91-93）：`c.Status(401)` + Abort
        // —— **正文为空**，且 `WWW-Authenticate` 的 realm 是固定小写
        // "openlist"（不随管理员用户名变化）。以前这里发的是
        // `Basic realm="OpenList"` 加一句正文，两头都不对（虽然只影响
        // 探测性客户端，不会让登录失败）。
        res.setStatus(401);
        try res.set("WWW-Authenticate", "Basic realm=\"openlist\"");
        return;
    }

    const m = req.method;
    if (eql(u8, m, "PROPFIND")) return propfind(app, req, res);
    // Go `ServeHTTP`（webdav.go:64）：GET / HEAD / **POST** 三个方法进同一个
    // `handleGetHeadPost`（POST 是若干下载器用来带参数取文件的写法）。
    if (eql(u8, m, "GET") or eql(u8, m, "HEAD") or eql(u8, m, "POST")) {
        return getOrHead(app, req, res, eql(u8, m, "HEAD"));
    }
    if (eql(u8, m, "PUT")) return put(app, req, res);
    if (eql(u8, m, "MKCOL")) return mkcol(app, req, res);
    if (eql(u8, m, "DELETE")) return delete(app, req, res);
    if (eql(u8, m, "COPY")) return copy(app, req, res);
    if (eql(u8, m, "MOVE")) return move(app, req, res);
    if (eql(u8, m, "PROPPATCH")) return proppatch(req, res);
    // LOCK / UNLOCK 以及其它未注册方法。
    //
    // 上游真的实现了 LOCK/UNLOCK（内存锁系统），本工程没有锁，所以一律 405
    // 并列出真实支持的方法集 —— 客户端（含 Windows MiniRedir）会自行降级为
    // 无锁访问，浏览不受影响。
    res.setStatus(405);
    try res.set("Allow", "OPTIONS,GET,HEAD,POST,PUT,DELETE,MKCOL,PROPFIND,COPY,MOVE,PROPPATCH");
    try res.set("Content-Type", "text/plain; charset=utf-8");
    try res.write("Method Not Allowed");
}

/// Go `handleOptions`（server/webdav/webdav.go:195-219）。
///
/// 三件事与之前的写法不同：
///  1. `Allow` 是**动态的**（按目标存在与否 + 是目录还是文件给出三套值）；
///     拿不到条目时用的是「还不存在的文件」那一套。
///  2. `DAV` 是 `"1, 2"`（RFC 4918 的 Class 2 = 支持 LOCK，因为上游有锁系统）
///     —— 以前只发 `"1"`。
///  3. 带 `MS-Author-Via: DAV`：Windows 的 Web Client（MiniRedir）靠这个头
///     决定要不要把该位置当 WebDAV 共享打开，缺了它资源管理器会退化成
///     「只读的 Web 文件夹」。
pub fn options(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const vpath = vpathOf(req.path);
    var allow: []const u8 = "OPTIONS, LOCK, PUT, MKCOL";
    var is_dir = false;
    var known = false;
    if (eql(u8, vpath, "/")) {
        // 虚拟根本身就是个集合
        is_dir = true;
        known = true;
    } else if (app.resolve(vpath)) |r| {
        var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
        if (r.mount.driver.details(&ctx, r.rel)) |f| {
            is_dir = f.is_dir;
            known = true;
        } else |_| {}
    }
    if (known) {
        allow = if (is_dir)
            "OPTIONS, LOCK, DELETE, PROPPATCH, COPY, MOVE, UNLOCK, PROPFIND"
        else
            "OPTIONS, LOCK, GET, HEAD, POST, DELETE, PROPPATCH, COPY, MOVE, UNLOCK, PROPFIND, PUT";
    }
    try res.set("Allow", allow);
    try res.set("DAV", "1, 2");
    try res.set("MS-Author-Via", "DAV");
}

/// Go `handleProppatch`（webdav.go:796-844）：本工程不存死属性，直接回一个
/// 空的 207（上游会为每个属性回 200 `<D:propstat>`，语义等价）。
fn proppatch(req: *http.Request, res: *http.Response) !void {
    var out = Buf.init(req.arena);
    try out.append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\"/>\n");
    res.setStatus(207);
    try res.set("Content-Type", "text/xml; charset=utf-8");
    try res.write(out.slice());
}

// ---------------------------------------------------------------------------
// PROPFIND
// ---------------------------------------------------------------------------

fn propfind(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const vpath = vpathOf(req.path);
    // Go `handlePropfind`（webdav.go:741-747）：**没带 Depth 时默认是
    // infinity**（不是 1），带了非法值则是 400。以前本实现默认 1 且不校验，
    // 于是 `Depth: 2` 这种请求会静默按 1 处理。
    const depth = parseDepth(req.header("Depth")) orelse {
        res.setStatus(400);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("Bad Request");
        return;
    };

    var out = Buf.init(a);
    try out.append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    try out.append("<D:multistatus xmlns:D=\"DAV:\">\n");

    if (eql(u8, vpath, "/")) {
        try writeColEntry(a, &out, "/", "");
        if (depth != .zero) try writeRootChildren(app, a, &out, depth);
    } else {
        const r = app.resolve(vpath) orelse return webdavStatus(res, 404);
        var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
        // Go `handlePropfind`（webdav.go:734-740）：fs.Get 失败时 404 / 405，
        // 但 `ServeHTTP`（webdav.go:85-88）对 PROPFIND 又统一改写成 **404**
        // —— 注释写明「对客户端把它当空目录」。
        const f = r.mount.driver.details(&ctx, r.rel) catch return webdavStatus(res, 404);
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
    // Go `handlePropfind`（webdav.go:778-781）：集合的 href 以 "/" 结尾
    // （根目录除外）。缺这个斜杠时部分客户端会把目录当成文件去 GET，
    // 拿到 405 后报「读取失败」。
    const href = try davHref(a, vpath, true);
    try out.print("  <D:response>\n    <D:href>{s}</D:href>\n", .{href});
    try out.append("    <D:propstat>\n      <D:prop>\n        <D:resourcetype><D:collection/></D:resourcetype>\n");
    const mod = cookiejar.httpDate(a, 0) catch "Thu, 01 Jan 1970 00:00:00 GMT";
    try out.print("        <D:getlastmodified>{s}</D:getlastmodified>\n", .{mod});
    try out.append("        <D:displayname>");
    try xmlEscape(out, name);
    try out.append("</D:displayname>\n      </D:prop>\n      <D:status>HTTP/1.1 200 OK</D:status>\n    </D:propstat>\n  </D:response>\n");
}

fn writeObjEntry(a: std.mem.Allocator, out: *Buf, vpath: []const u8, o: model.Obj) !void {
    const href = try davHref(a, vpath, o.is_dir);
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
    const r = app.resolve(vpath) orelse return webdavStatus(res, 404);
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    // Go `handleGetHeadPost`（webdav.go:242-245）：fs.Get 出错**一律** 404
    // （不区分「不存在」还是「驱动炸了」）。
    const f = r.mount.driver.details(&ctx, r.rel) catch return webdavStatus(res, 404);

    // Go webdav.go:246-253 —— 目录不是 404 而是按方法分：
    //   HEAD → 200 + `Content-Type: httpd/unix-directory` + `Content-Length: 0`
    //   （客户端靠这个判定「这是个目录，别下载」）
    //   GET/POST → 405
    // 以前本实现两种都回 404「is a directory」，浏览器挂载与 rclone 的
    // 目录嗅探因此拿到的是「不存在」而不是「不能下载」。
    if (f.is_dir) {
        if (is_head) {
            try res.set("Content-Type", "httpd/unix-directory");
            try res.set("Content-Length", "0");
            return;
        }
        return webdavStatus(res, 405);
    }

    // Go `handleGetHeadPost`（webdav.go:255-272）的两个存储级策略。它们决定
    // 的是"要不要 302 出去"，所以必须在 link / 本地 / 远程分支**之前**判定。
    //
    // ⚠ A05 的 WebDAV 半边（2026-10-18 实证，STATUS §41.6）：Go 两处都传
    //   `model.LinkArgs{Header: r.Header}`（webdav.go:257 与 :274）。**必须**
    //   把请求头交给驱动 —— 115 的直链签名是 **User-Agent 绑定**的：同一个
    //   URL 用生成时的 UA 取 = 200，换任何别的 UA = 403 `invalid signature`
    //   （设备上 Go/Zig 双侧受控实验证实）。此前 WebDAV 三处 link 都没传
    //   headers ⇒ 驱动拿到空 UA（downurl 用空 UA 签）⇒ 回源时链接头里没有
    //   UA、客户端默认 UA 补上 ⇒ 签名对不上 ⇒ **115 的 WebDAV 下载恒 403**。
    const policy = r.mount.storage.webdav_policy;
    var target: ?[]const u8 = null;
    if (api.isWebdavPolicy(policy, "302_redirect")) {
        // 302 直链：不回源、不通流量，交给客户端自己去取。
        // ⚠ `link` 必须按 `redirect=true` 取：部分驱动（189/夸克）在
        // redirect 模式下才会给出可外链的那一份 URL。
        const lk = r.mount.driver.link(&ctx, r.rel, .{
            .redirect = true,
            .headers = req.headers,
        }) catch {
            return webdavStatus(res, 500);
        };
        target = lk.url;
    } else if (api.isWebdavPolicy(policy, "use_proxy_url") and
        r.mount.storage.down_proxy_url.len > 0)
    {
        // 302 到存储配置的 `down_proxy_url`（编码后的路径，默认带签名）。
        // Go `common.GenerateDownProxyURL`（server/common/proxy.go:146-159）。
        // 上游在 URL 为空时会**退回 native 转发**，这里同样靠上面的条件
        // 表达式落到 native 分支，不做 500。
        var u = Buf.init(a);
        // Go 取 `strings.Split(DownProxyURL, "\n")[0]` —— 配置里常写多行做
        // 负载分担，只用第一行。
        const base = r.mount.storage.down_proxy_url;
        const nl = std.mem.indexOfScalar(u8, base, '\n');
        try u.append(if (nl) |i| base[0..i] else base);
        try u.append(try urlmod.encode(a, vpath, .path));
        if (!r.mount.storage.disable_proxy_sign) {
            try u.append("?sign=");
            try u.append(try api.signValue(a, app.jwt_secret, vpath, 0));
        }
        try res.set("Cache-Control", "max-age=0, no-cache, no-store, must-revalidate");
        target = try u.toOwned();
    }
    if (target) |t| {
        try res.redirect(t, 302);
        return;
    }

    // Go webdav.go:274-278：link 失败 → 500。
    const lk = r.mount.driver.link(&ctx, r.rel, .{
        .redirect = false,
        .headers = req.headers,
    }) catch |e| {
        log.warn("webdav: link {s}: {s}", .{ vpath, @errorName(e) });
        return webdavStatus(res, 500);
    };

    const total: u64 = if (lk.local_path) |_|
        lk.local_size
    else if (lk.text) |t|
        t.len
    else
        @intCast(@max(f.size, 0));

    // 本地文件 / 内存文本 ⇒ 走 Go `common.Proxy` 里 **link 带 RangeReader**
    // 的那个分支：`attachHeader` + `net.ServeHTTP`，也就是有
    // Etag / Last-Modified / 条件请求 / Range（206+416）。
    // 远程直链 ⇒ 透明代理分支（上游头原样透传，不设 Etag）。
    if (lk.local_path != null or lk.text != null) {
        const ct: []const u8 = if (lk.text != null) "text/plain; charset=utf-8" else api.mimeFor(f.name);
        const gate = try api.preconditionGate(req, res, a, f, total, ct);
        if (gate.done) return;
        try res.set("Accept-Ranges", "bytes");

        const r0: api.ParsedRange = if (req.header("Range")) |rh| api.parseRange(rh, total) else .ignore;
        switch (if (gate.ignore_range) api.ParsedRange.ignore else r0) {
            .unsatisfiable => {
                res.setStatus(416);
                try res.set("Content-Range", try std.fmt.allocPrint(a, "bytes */{d}", .{total}));
                return;
            },
            .valid => |rg| {
                if (rg.start >= total) {
                    res.setStatus(416);
                    try res.set("Content-Range", try std.fmt.allocPrint(a, "bytes */{d}", .{total}));
                    return;
                }
                res.setStatus(206);
                try res.set("Content-Range", try std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ rg.start, rg.end, total }));
                if (lk.local_path) |lp| {
                    const file = std.Io.Dir.cwd().openFile(rt.io(), lp, .{}) catch {
                        log.warn("webdav: open {s}: not found", .{lp});
                        return webdavStatus(res, 500);
                    };
                    api.streamRange(res, a, file, rg.start, rg.end) catch return webdavStatus(res, 500);
                } else if (lk.text) |txt| {
                    try res.write(txt[rg.start..rg.end + 1]);
                }
                return;
            },
            .ignore => {},
        }
        if (lk.local_path) |lp| {
            const file = std.Io.Dir.cwd().openFile(rt.io(), lp, .{}) catch {
                log.warn("webdav: open {s}: not found", .{lp});
                return webdavStatus(res, 500);
            };
            res.sendFile(file, total);
        } else if (lk.text) |txt| {
            try res.write(txt);
        }
        return;
    }

    // ---- 远程：透明代理（Go `common.Proxy` 的 `maps.Copy` + C-D 分支）----
    var jar = cookiejar.Jar.init(a);
    var client = client_mod.Client.init(a, .{}, &jar);
    defer client.deinit();
    // W01：把客户端的 Range **原样**透传给上游。
    //
    // ⚠ 这里刻意**不**做本端的 Range 解析/切片/416 合成：Go 的透明代理分支
    //   （`common.Proxy` 的末尾）只做 `maps.Copy(w.Header(), res.Header)`，
    //   客户端的 Range 经 `net.ProcessHeader` 原样发给上游，上游回什么就转发
    //   什么 —— 上游不支持 Range 时上游回 200，Go 也回 200。
    //   （本地/内存那条分支才走 `net.ServeHTTP`，那才是会自己切 Range、
    //   会合成 416 的地方；两个分支的语义本来就不一样。）
    //   早先这里"解析 Range → 只转发能解析的 → 上游忽略就自己切"，对
    //   `size=0` 的云盘条目会把 Range 整个丢掉，且与上游的 200 语义相左。
    var hdrs = List(model.Header).init(a);
    for (lk.header) |h| try hdrs.append(h);
    if (req.header("Range")) |rh| {
        try hdrs.append(.{ .name = "Range", .value = rh });
    }

    const up = client.send(a, .{
        // Go `net.RequestHttp(ctx, r.Method, ...)`：方法照抄（HEAD 就是 HEAD），
        // 拿到响应后 `if r.Method == HEAD { return nil }` 不发正文。
        .method = req.method,
        .url = lk.url,
        .headers = hdrs.slice(),
        // N02：回源跟随 3xx，CDN 用 302 转边缘节点，不跟随就变 502。
        .follow_redirects = true,
    }) catch |e| {
        log.warn("webdav: proxy {s}: {s}", .{ lk.url, @errorName(e) });
        return webdavStatus(res, 500);
    };
    if (up.status >= 400) {
        // Go：RequestHttp 对 4xx/5xx 返回 error（HttpStatusCodeError），
        // handleGetHeadPost 把它展开成真实状态码 → 客户端看到的就是上游的
        // 403/404，正文是状态码文本。以前这里统一压成 502，夸克 cookie 过期
        // 时用户在 WebDAV 里只看到「Bad Gateway」，排查方向被完全误导。
        return webdavStatus(res, up.status);
    }
    if (up.status >= 300) return webdavStatus(res, up.status);

    res.setStatus(up.status);
    for (up.headers) |h| {
        // 跳过逐跳头 + 交给响应层计算的 Content-Length；Set-Cookie 对齐
        // Go `RequestHttp` 的 `res.Header.Del("set-cookie")`（上游 CDN 的
        // cookie 不该借我们的域下发）。
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Length")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "Connection")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "Transfer-Encoding")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "Keep-Alive")) continue;
        if (std.ascii.eqlIgnoreCase(h.name, "Set-Cookie")) continue;
        res.set(h.name, h.value) catch continue;
    }
    // C-D 在透传后设置（覆盖上游同名头）：WebDAV 的 GET 也是下载语义。
    // ⚠ 与本地分支相反，这里**不**自己补 `Accept-Ranges`：透明代理的语义是
    //   "上游说什么就是什么"，上游带了就透传过来（koofr 等 WebDAV 上游会
    //   带），上游没带就不带 —— 与 Go 的 `maps.Copy` 一致。
    try res.set("Content-Disposition", try api.contentDisposition(a, f.name));
    try res.write(up.body);
}

// ---------------------------------------------------------------------------
// PUT / MKCOL / DELETE
// ---------------------------------------------------------------------------

/// Go `handlePut`（server/webdav/webdav.go:339-424）。
///
/// 三条与旧实现不同的语义：
///  1. **状态码恒为 201**（不管目标是新建还是覆盖）。旧实现按 RFC 给了
///     204/201 两种，看上去更"正确"，但上游就只有 201 —— 而某些客户端
///     （含 rclone 的 WebDAV 后端）把 204 当成"没写进去"而报同步失败。
///  2. **不做条件请求**（If-Match / If-None-Match）。上游 webdav.go:358 有
///     明确的 TODO 说还没支持；强行 412 会让"存在才更新"语义的客户端写不进
///     去 —— 而上游此时是直接覆盖。
///  3. **写完必回 ETag**：stat 不到新对象时，退回用请求自带的
///     `X-OC-Mtime`（或当前时间）+ `Content-Length` 拼（webdav.go:414-417）。
fn put(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const vpath = vpathOf(req.path);
    // Go handlePut:351 —— 根路径不能 PUT。
    if (eql(u8, vpath, "/")) return webdavStatus(res, 405);
    const r = app.resolve(vpath) orelse {
        // 父目录不存在（fs.PutDirectly 失败）⇒ 405，与上游一致。
        return webdavStatus(res, 405);
    };
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };

    // 上游是"先写、写失败才 405"。这里提前挡掉目录目标：覆盖一个集合没有
    // 意义，状态码与上游一致，还省掉一次注定失败的上传（云盘侧可能是几 MB
    // 的上行流量）。
    if (r.mount.driver.details(&ctx, r.rel)) |f| {
        if (f.is_dir) {
            res.setStatus(405);
            try res.set("Content-Length", "0");
            return;
        }
    } else |_| {}

    // DAV PUT 的 Content-Type 优先取客户端自己发的（浏览器/rclone 会带真实
    // 类型），没带再从文件名推断 —— Go 侧等价物是 FileStreamer.GetMimetype()
    // 被 webdav 驱动的 Put callback 设成 Content-Type
    // （drivers/webdav/driver.go:117-119；此前本工程一个 CT 都不发，
    // AUDIT_2026-10-18-drivers.md §4-P1-2）。
    var src = req.body.source();
    src.mime = req.header("Content-Type") orelse api.mimeFor(std.fs.path.basename(r.rel));
    r.mount.driver.put(&ctx, r.rel, src) catch {
        return webdavStatus(res, 405);
    };
    res.setStatus(201);
    // ETag：优先写后 stat 的真实值；stat 不到就退回请求推导值。
    // 头名用 Go 的大小写 `Etag`（`w.Header().Set("Etag", etag)`）—— 有些
    // 客户端（含 litmus）对大小写敏感。
    if (r.mount.driver.details(&ctx, r.rel)) |nf| {
        try res.set("Etag", try api.etagFor(a, nf, @intCast(@max(nf.size, 0))));
    } else |_| {
        const size = req.body.len();
        const mtime = headerUnix(req, "X-OC-Mtime") orelse rt.nowSeconds();
        try res.set("Etag", try std.fmt.allocPrint(a, "\"{x}-{x}\"", .{ mtime, size }));
    }
}

/// 解析 `X-OC-Mtime` / `X-OC-Ctime`（ownCloud 系客户端用来带 mtime 的私有头，
/// Go `webdav/util.go:20-36`）。解析失败时 Go 会打一条 warn 并用 `time.Now()`，
/// 这里同样返回 null 让调用方回落。
fn headerUnix(req: *http.Request, name: []const u8) ?i64 {
    const v = req.header(name) orelse return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t"), 10) catch null;
}

/// Go `handleMkcol`（webdav.go:426-479）。
fn mkcol(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const vpath = vpathOf(req.path);
    const r = app.resolve(vpath) orelse return webdavStatus(res, 405);
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    // RFC 4918 §9.3.1：目标**已存在**（文件或目录都算）⇒ 405。
    // 旧实现只对目录挡 405，对同名文件会试图 makeDir，把驱动的错误再兜成
    // 502 —— 而协议上这是"URL 已被映射"，就是 405。
    if (r.mount.driver.details(&ctx, r.rel)) |_| {
        res.setStatus(405);
        try res.set("Content-Length", "0");
        return;
    } else |_| {}
    // RFC 4918 §9.3.1：父集合不存在 ⇒ 409（服务器不得自动创建中间层）。
    if (parentMissing(app, a, vpath)) return webdavStatus(res, 409);

    r.mount.driver.makeDir(&ctx, r.rel) catch return webdavStatus(res, 409);
    res.setStatus(201);
    try res.set("Content-Length", "0");
}

/// 父路径是否不可解析 / 不存在。虚拟根的父级视为存在。
fn parentMissing(app: *App, a: std.mem.Allocator, vpath: []const u8) bool {
    const parent = urlmod.parentPath(vpath);
    if (eql(u8, parent, "/") or parent.len == 0) return false;
    const pr = app.resolve(parent) orelse return true;
    var ctx = driver.Ctx{ .alloc = a, .tag = pr.mount.mount_path };
    const pf = pr.mount.driver.details(&ctx, pr.rel) catch return true;
    return !pf.is_dir;
}

/// Go `handleDelete`（webdav.go:293-337）：先 stat（不存在 ⇒ 404），
/// 再删（失败 ⇒ 405），成功 204。
fn delete(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const vpath = vpathOf(req.path);
    const r = app.resolve(vpath) orelse return webdavStatus(res, 404);
    var ctx = driver.Ctx{ .alloc = a, .tag = r.mount.mount_path };
    const f = r.mount.driver.details(&ctx, r.rel) catch return webdavStatus(res, 404);
    r.mount.driver.remove(&ctx, r.rel, f.is_dir) catch return webdavStatus(res, 405);
    res.setStatus(204);
}

// ---------------------------------------------------------------------------
// MOVE / COPY
// ---------------------------------------------------------------------------

/// Go `handleCopyMove`（webdav.go:481-509）的公共前置段：取 Destination 头、
/// 剥前缀、再做两个 RFC 4918 的硬校验。失败时响应已经写好，返回 null。
fn copyMovePaths(app: *App, req: *http.Request, res: *http.Response, a: std.mem.Allocator) !?struct { src: []const u8, dst: []const u8 } {
    _ = app;
    const src = vpathOf(req.path);
    // 缺 Destination ⇒ 400（Go:482-485）
    const dest_hdr = req.header("Destination") orelse {
        try webdavStatus(res, 400);
        return null;
    };
    // 解析不出路径（不是本机的 URL / 不含 /dav 前缀）⇒ 400
    const dst = (try destVpath(a, dest_hdr)) orelse {
        try webdavStatus(res, 400);
        return null;
    };
    // Go:504-509 —— 目标为空 ⇒ 502；**目标 == 源 ⇒ 403**（不是 204 成功）。
    // 旧实现把"移到自己身上"当成 204 空操作返回，而协议上这是被禁止的。
    if (dst.len == 0) {
        try webdavStatus(res, 502);
        return null;
    }
    if (eql(u8, dst, src)) {
        try webdavStatus(res, 403);
        return null;
    }
    return .{ .src = src, .dst = dst };
}

/// Go `handleCopyMove` + `moveFiles`（webdav/file.go:35-74）。
fn move(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const cm = (try copyMovePaths(app, req, res, a)) orelse return;
    const sr = app.resolve(cm.src) orelse return webdavStatus(res, 404);
    const dr = app.resolve(cm.dst) orelse return webdavStatus(res, 404);
    // ⚠ 已知偏离：上游 `fs.Move` 走任务系统，跨存储也能搬；本工程没有任务
    //  系统，driver 的 move/rename 只在同存储内有效，跨存储只能 502 说明。
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

    // 与 Go `moveFiles`（file.go:58-68）同构：同目录 ⇒ 直接改名；
    // 跨目录 ⇒ 先 move 到目标目录，名字不同再补一次 rename。
    if (eql(u8, src_parent, dst_parent)) {
        sr.mount.driver.rename(&ctx, sr.rel, dst_name) catch {
            log.warn("webdav: move {s}: failed", .{cm.src});
            return webdavStatus(res, 500);
        };
    } else {
        sr.mount.driver.move(&ctx, sr.rel, dst_parent) catch {
            log.warn("webdav: move {s}: failed", .{cm.src});
            return webdavStatus(res, 500);
        };
        if (!eql(u8, src_name, dst_name)) {
            const moved_rel = try urlmod.joinPath(a, dst_parent, src_name);
            sr.mount.driver.rename(&ctx, moved_rel, dst_name) catch {
                log.warn("webdav: rename {s}: failed", .{moved_rel});
                return webdavStatus(res, 500);
            };
        }
    }
    // Go moveFiles 结尾：`return http.StatusCreated` —— 恒 201。
    res.setStatus(201);
}

/// Go `handleCopyMove` + `copyFiles`（webdav/file.go:80-107）。
fn copy(app: *App, req: *http.Request, res: *http.Response) !void {
    const a = req.arena;
    const cm = (try copyMovePaths(app, req, res, a)) orelse return;
    const sr = app.resolve(cm.src) orelse return webdavStatus(res, 404);
    const dr = app.resolve(cm.dst) orelse return webdavStatus(res, 404);

    var sctx = driver.Ctx{ .alloc = a, .tag = sr.mount.mount_path };
    const f = sr.mount.driver.details(&sctx, sr.rel) catch return webdavStatus(res, 404);
    // ⚠ 已知偏离：上游 `fs.Copy` 递归拷贝整个集合。本工程的 HTTP 客户端是
    //  整体缓冲式的（`client.send` 一次拿全量），递归拷贝整棵树会把整棵树的
    //  内容同时压进内存，所以只对单个文件实现；目录明确回 501 让客户端自己
    //  逐条 COPY（rclone/Cyberduck 都会这么做），而不是悄悄少拷一半。
    if (f.is_dir) {
        res.setStatus(501);
        try res.set("Content-Type", "text/plain; charset=utf-8");
        try res.write("Not Implemented");
        return;
    }
    const lk = sr.mount.driver.link(&sctx, sr.rel, .{
        .redirect = false,
        .headers = req.headers,
    }) catch {
        return webdavStatus(res, 500);
    };
    const data = fetchBytes(a, lk) catch |e| {
        log.warn("webdav: copy fetch {s}: {s}", .{ cm.src, @errorName(e) });
        return webdavStatus(res, 500);
    };
    // 跨存储是允许的（本实现是"下载 + 上传"，不依赖驱动的 move/rename，
    // 这一点反而比只支持同存储的 MOVE 更接近上游）。
    var dctx = driver.Ctx{ .alloc = a, .tag = dr.mount.mount_path };
    const src_mem = memSource(&data);
    dr.mount.driver.put(&dctx, dr.rel, src_mem) catch {
        log.warn("webdav: copy put {s}: failed", .{cm.dst});
        return webdavStatus(res, 500);
    };
    // Go copyFiles 结尾：`return http.StatusCreated` —— 恒 201。
    res.setStatus(201);
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

fn davHref(alloc: std.mem.Allocator, vpath: []const u8, is_dir: bool) ![]u8 {
    const enc = try urlmod.encode(alloc, vpath, .path);
    // 与 Go 一致：集合补尾斜杠，根（"/"）不补。
    if (is_dir and !eql(u8, vpath, "/")) {
        return std.fmt.allocPrint(alloc, "/dav{s}/", .{enc});
    }
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

/// Go `parseDepth`（webdav.go:881-891）：只认 "0" / "1" / "infinity"，
/// 其它一律非法（invalidDepth）。不带头时返回 null 让调用方用默认的
/// infinity。
fn parseDepth(h: ?[]const u8) ?Depth {
    const d = h orelse return .infinity;
    if (eql(u8, d, "0")) return .zero;
    if (eql(u8, d, "1")) return .one;
    if (eql(u8, d, "infinity")) return .infinity;
    return null;
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

/// Go `ServeHTTP`（server/webdav/webdav.go:94-98）的收尾：
/// `w.WriteHeader(status); w.Write([]byte(StatusText(status)))`。
///
/// 也就是说 WebDAV 的错误响应体**就是状态码文本**（"Not Found" /
/// "Method Not Allowed"…），不是自定义文案 —— 绝大多数 WebDAV 客户端只看
/// 状态码，但少数（含 litmus 测试套件）会比对这段文本。以前这里写的是
/// "not found"、"is a directory"、"upstream error" 之类自造文案。
fn webdavStatus(res: *http.Response, status: u16) !void {
    res.setStatus(status);
    try res.set("Content-Type", "text/plain; charset=utf-8");
    try res.write(http.statusText(status));
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
    // Same derivation as /api/auth/login: StaticHash first, then the salted
    // HashPwd. `admin_salt` empty (older configs / test doubles) would make
    // twoHashPwd disagree with however the hash was produced, so require it.
    if (app.admin_salt.len == 0) return false;
    const expect = api.twoHashPwd(req.arena, pass, app.admin_salt) catch return false;
    return ctEqual(expect, app.admin_hash);
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

    var app = try mkApp(a);

    // No credential -> 401.
    var req = http.Request{ .arena = a, .method = "PROPFIND", .path = "/dav/v", .target = "/dav/v" };
    var res = http.Response.init(a);
    try handle(&app, &req, &res);
    try testing.expectEqual(@as(u16, 401), res.status);

    // With Basic auth + Depth 1 -> 207 multistatus containing both children.
    //
    // ⚠ 必须显式带 Depth：不带时按上游语义是 infinity，而 Stub 的 list 对
    // 任何路径都返回同样的两个孩子 —— 递归永不终止。
    var req2 = http.Request{ .arena = a, .method = "PROPFIND", .path = "/dav/v", .target = "/dav/v" };
    var hs = [_]model.Header{
        .{ .name = "Authorization", .value = "Basic YWRtaW46cGFzcw==" },
        .{ .name = "Depth", .value = "1" },
    };
    req2.headers = &hs;
    var res2 = http.Response.init(a);
    try handle(&app, &req2, &res2);
    try testing.expectEqual(@as(u16, 207), res2.status);
    const body = res2.buf.slice();
    try testing.expect(std.mem.indexOf(u8, body, "<D:multistatus") != null);
    try testing.expect(std.mem.indexOf(u8, body, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, body, "sub") != null);
    try testing.expect(std.mem.indexOf(u8, body, "getcontentlength") != null);
    // 集合的 href 必须以 "/" 结尾（Go handlePropfind:778-781）
    try testing.expect(std.mem.indexOf(u8, body, "<D:href>/dav/v/sub/</D:href>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<D:href>/dav/v/a.txt</D:href>") != null);
}

test "webdav: OPTIONS advertises DAV 1,2 + MS-Author-Via without auth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 文件（/v/a.txt → stub 的 details 报"文件"）
    var app = try mkApp(a);
    var req = http.Request{ .arena = a, .method = "OPTIONS", .path = "/dav/v/a.txt", .target = "/dav/v/a.txt" };
    var res = http.Response.init(a);
    try handle(&app, &req, &res);
    try testing.expectEqual(@as(u16, 200), res.status);
    try testing.expectEqualStrings("1, 2", hdr(&res, "DAV").?);
    try testing.expectEqualStrings("DAV", hdr(&res, "MS-Author-Via").?);
    try testing.expectEqualStrings(
        "OPTIONS, LOCK, GET, HEAD, POST, DELETE, PROPPATCH, COPY, MOVE, UNLOCK, PROPFIND, PUT",
        hdr(&res, "Allow").?,
    );

    // 目录（/v → stub 的 details("/") 报"集合"）
    var req2 = http.Request{ .arena = a, .method = "OPTIONS", .path = "/dav/v", .target = "/dav/v" };
    var res2 = http.Response.init(a);
    try handle(&app, &req2, &res2);
    try testing.expectEqualStrings(
        "OPTIONS, LOCK, DELETE, PROPPATCH, COPY, MOVE, UNLOCK, PROPFIND",
        hdr(&res2, "Allow").?,
    );
}

test "webdav: 401 uses Go's lowercase realm and an empty body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app = try mkApp(a);
    var req = http.Request{ .arena = a, .method = "PROPFIND", .path = "/dav/v", .target = "/dav/v" };
    var res = http.Response.init(a);
    try handle(&app, &req, &res);
    try testing.expectEqual(@as(u16, 401), res.status);
    try testing.expectEqualStrings("Basic realm=\"openlist\"", hdr(&res, "WWW-Authenticate").?);
    try testing.expectEqual(@as(usize, 0), res.buf.len);
}

test "webdav: HEAD on a directory is 200 httpd/unix-directory, GET is 405" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app = try mkApp(a);
    var auth = [_]model.Header{.{ .name = "Authorization", .value = "Basic YWRtaW46cGFzcw==" }};

    var req_h = http.Request{ .arena = a, .method = "HEAD", .path = "/dav/v", .target = "/dav/v", .headers = &auth };
    var res_h = http.Response.init(a);
    try handle(&app, &req_h, &res_h);
    try testing.expectEqual(@as(u16, 200), res_h.status);
    try testing.expectEqualStrings("httpd/unix-directory", hdr(&res_h, "Content-Type").?);
    try testing.expectEqualStrings("0", hdr(&res_h, "Content-Length").?);

    var req_g = http.Request{ .arena = a, .method = "GET", .path = "/dav/v", .target = "/dav/v", .headers = &auth };
    var res_g = http.Response.init(a);
    try handle(&app, &req_g, &res_g);
    try testing.expectEqual(@as(u16, 405), res_g.status);
    try testing.expectEqualStrings("Method Not Allowed", res_g.buf.slice());
}

test "webdav: PROPFIND rejects an invalid Depth with 400" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app = try mkApp(a);
    var hs = [_]model.Header{
        .{ .name = "Authorization", .value = "Basic YWRtaW46cGFzcw==" },
        .{ .name = "Depth", .value = "2" },
    };
    var req = http.Request{ .arena = a, .method = "PROPFIND", .path = "/dav/v", .target = "/dav/v", .headers = &hs };
    var res = http.Response.init(a);
    try handle(&app, &req, &res);
    try testing.expectEqual(@as(u16, 400), res.status);
    try testing.expectEqualStrings("Bad Request", res.buf.slice());
}

test "webdav: MOVE onto itself is 403 (not 204)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app = try mkApp(a);
    var hs = [_]model.Header{
        .{ .name = "Authorization", .value = "Basic YWRtaW46cGFzcw==" },
        .{ .name = "Destination", .value = "/dav/v/a.txt" },
    };
    var req = http.Request{ .arena = a, .method = "MOVE", .path = "/dav/v/a.txt", .target = "/dav/v/a.txt", .headers = &hs };
    var res = http.Response.init(a);
    try handle(&app, &req, &res);
    try testing.expectEqual(@as(u16, 403), res.status);
    try testing.expectEqualStrings("Forbidden", res.buf.slice());
}

test "webdav: PUT is always 201 and carries an ETag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app = try mkApp(a);
    var auth = [_]model.Header{.{ .name = "Authorization", .value = "Basic YWRtaW46cGFzcw==" }};
    var req = http.Request{
        .arena = a,
        .method = "PUT",
        .path = "/dav/v/new.txt",
        .target = "/dav/v/new.txt",
        .headers = &auth,
        .body = .{ .memory = "hello" },
    };
    var res = http.Response.init(a);
    try handle(&app, &req, &res);
    try testing.expectEqual(@as(u16, 201), res.status);
    // stub 写完后 details 仍然报同一个文件 ⇒ ETag 是 `"<mtime hex>-<size hex>"`。
    try testing.expectEqualStrings("\"0-a\"", hdr(&res, "ETag").?);
}

test "webdav: PUT onto a directory is 405" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var app = try mkApp(a);
    var auth = [_]model.Header{.{ .name = "Authorization", .value = "Basic YWRtaW46cGFzcw==" }};
    var req = http.Request{
        .arena = a,
        .method = "PUT",
        .path = "/dav/v",
        .target = "/dav/v",
        .headers = &auth,
        .body = .{ .memory = "hello" },
    };
    var res = http.Response.init(a);
    try handle(&app, &req, &res);
    try testing.expectEqual(@as(u16, 405), res.status);
}

/// 取响应头（大小写不敏感），测试里用来断言 WebDAV 的三个新头。
fn hdr(res: *http.Response, name: []const u8) ?[]const u8 {
    for (res.headers.slice()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    }
    return null;
}

/// 测试用的 App：一个 Stub 驱动挂在 /v，口令 pass（与既有 PROPFIND 测试同源）。
fn mkApp(a: std.mem.Allocator) !App {
    // ⚠ 驱动对象必须**分配在 arena 上**：返回局部 `Stub` 的地址就是典型的
    // 悬垂指针（mkApp 返回后栈帧失效，ReleaseSmall 下不报错、只是读到垃圾）。
    // 跨函数返回指针一律用分配器 —— 2026-10-16 的夸克 502 就是这么来的。
    const stub = try a.create(Stub);
    stub.* = Stub{};
    const drv = stub.toDriver();
    var mounts = try a.alloc(api.Mount, 1);
    mounts[0] = .{ .storage = .{ .driver = "Stub" }, .driver = drv, .mount_path = "/v", .label = "v" };
    const salt = "0123456789abcdef";
    return .{
        .alloc = a,
        .mounts = mounts,
        .admin_hash = try api.twoHashPwd(a, "pass", salt),
        .admin_salt = salt,
        .admin_user = "admin",
        .admin_pwd_ts = 0,
        .jwt_secret = "s",
        .site_url = "",
        .cdn = "",
        .token_expires_in_hours = 48,
        .frontend = undefined,
    };
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
