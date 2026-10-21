//! OpenList-compatible frontend serving.
//!
//! A port of OpenList's `server/static/config.go` + `server/static/static.go`.
//! The behaviour worth preserving is the *default* one, because that is what an
//! existing deployment already relies on:
//!
//!   * `cdn` empty — assets are served by this process out of `dist_dir`, and
//!     the SPA shell is read from `dist_dir/index.html`.
//!   * `cdn` set   — `/assets|images|streamer|static/*` answer 302 into the
//!     CDN, and the shell itself comes from the binary when the deployment
//!     pins `web_version` to the baked shell release (upstream pinned-release
//!     semantics, `zig.embed_index_html`), or else is fetched from
//!     `{cdn}/index.html` once at startup so the served HTML and the assets
//!     it references come from the same build. See `loadRawIndex`.
//!
//! `$version` inside the `cdn` value expands to `web_version` with a leading
//! `"v"` stripped — `"v4.2.6"` -> `"4.2.6"`, `"rolling"` -> `"rolling"`. That is
//! how OpenList's own `build.sh` feeds the frontend release tag into a CDN
//! template, so a value like
//! `https://cdn.example.com/openlist/$version/dist` pins to one release and
//! `https://cdn.example.com/openlist/rolling/dist` tracks the edge build.
//!
//! ## The one deliberate divergence
//!
//! Upstream compiles the ~20 MB frontend into the Go binary via
//! `//go:embed public/dist`. Avoiding exactly that is the point of this
//! rewrite, so when there is neither a `dist_dir` nor a `cdn` we serve
//! `BUILTIN_INDEX`: a small self-contained diagnostic page. It is not a
//! frontend. It carries the same placeholder tokens as the real `index.html`
//! so that `replaceFirstEach` is exercised identically no matter where the
//! shell came from.
//!
//! Getting the real UI is therefore a config change, not a rebuild — see
//! `docs/STATUS.md`.

const std = @import("std");
const log = @import("log.zig");
const rt = @import("rt.zig");
const urlmod = @import("util/url.zig");
const client_mod = @import("client.zig");
const cookiejar = @import("cookiejar.zig");
const Buf = @import("util/buf.zig").Buf;

/// The four path prefixes OpenList treats as frontend assets. Anything under
/// them is either served from `dist_dir` or redirected to the CDN; everything
/// else falls through to the SPA shell.
pub const asset_folders = [_][]const u8{ "assets", "images", "streamer", "static" };

/// Largest `index.html` we will read. The real built one is ~4.3 KB (v4.2.6);
/// 4 MiB leaves
/// room for a heavily customised build without letting a hostile `dist_dir`
/// exhaust memory at startup.
const max_index_bytes: usize = 4 * 1024 * 1024;

/// CDN 候选上限（主 + 备用）。比这更长的列表只取前 N 个 —— 再多也不会
/// 全部试完，启动延迟反而不可控。
const max_cdn_candidates: usize = 8;

/// 内嵌前端外壳：上游 pinned release 用 `//go:embed public/dist` 把整份 dist
/// （约 20 MB）带进二进制；本构建只带这一份 `index.html`（v4.2.6 实测 4363
/// 字节），取自 npm 包 `@openlist-frontend/openlist-frontend` 的
/// `dist/index.html`，用 `tools/fetch_frontend_shell.py` 抓取更新。
///
/// 它解决的只是"外壳从哪来"：`web_version` 钉在同一版本时，启动不再从 CDN
/// 拉 index.html —— 启动的网络强依赖（`CdnIndexFetchFailed` 直接退出）随之
/// 消失。npmmirror 这类**只拦 .html**（451 `{"error":"blocked"}`，防滥用
/// 而非法律原因）、但 js/css 与 CORS 头齐全的 CDN，也因此可以直接当 `cdn`
/// 用（外壳由本二进制出，assets 由浏览器从它加载）。
///
/// 硬约束：外壳里烙着该版本的 Vite 哈希资源名，`cdn` 必须指向**同一版本**
/// 的 dist。`web_version` 对不上时自动退回 CDN 拉取路径，绝不错配。
const EMBEDDED_SHELL = @embedFile("frontend_shell_v4.2.6.html");

/// The upstream frontend release `EMBEDDED_SHELL` was taken from, without a
/// leading `"v"`. Kept next to the `@embedFile` name on purpose: bumping the
/// shell means updating both together, which is exactly what
/// `tools/fetch_frontend_shell.py` does.
pub const embedded_shell_version = "4.2.6";

/// True when `web_version` pins exactly `embedded_shell_version` — `"v4.2.6"`
/// or `"4.2.6"`. `rolling`/`beta`/empty/any other pin do not match, mirroring
/// `expandVersion`'s lowercase-`v` handling.
fn embeddedShellMatches(web_version: []const u8) bool {
    const v = if (web_version.len > 0 and web_version[0] == 'v') web_version[1..] else web_version;
    return std.mem.eql(u8, v, embedded_shell_version);
}

/// Presentation defaults, copied from OpenList's
/// `internal/bootstrap/data/setting.go`. These are the values a *fresh*
/// install has, i.e. what the placeholder substitution does when the operator
/// overrides nothing.
pub const Settings = struct {
    site_title: []const u8 = "OpenList",
    main_color: []const u8 = "#1890ff",
    /// Both default to the same asset upstream; note the placeholders they
    /// replace are the `.png` and `.svg` variants respectively.
    logo: []const u8 = "https://res.oplist.org/logo/logo.svg",
    favicon: []const u8 = "https://res.oplist.org/logo/logo.svg",
    customize_head: []const u8 = "",
    customize_body: []const u8 = "",
};

/// Everything the frontend needs from `config.json`, passed in rather than
/// read from the global config so that this module is testable in isolation.
pub const Input = struct {
    /// `site_url`. Only its path component matters — OpenList derives the base
    /// path from it.
    site_url: []const u8 = "",
    /// `cdn`, verbatim. Empty means "serve assets ourselves".
    cdn: []const u8 = "",
    /// 备用 CDN（`zig.cdn_fallbacks`）。`cdn` 取不到时按顺序往下试。
    /// 每个都会重试 `cdn_retries` 次，全失败才放弃 —— CDN 是启动强依赖，
    /// 而 jsdelivr 在大陆网络是间歇性可用的（实测同一 URL 时而 200、
    /// 时而 reset/503），单点会让网络抖一下服务就起不来。
    cdn_fallbacks: []const []const u8 = &.{},
    /// 每个 CDN 的尝试次数。2 = 首次 + 1 次重试。
    cdn_retries: u32 = 2,
    /// `dist_dir`. Empty means "no on-disk frontend build".
    dist_dir: []const u8 = "",
    /// The frontend release this deployment targets. OpenList bakes this in
    /// with `-ldflags`; we read it from config.
    web_version: []const u8 = "rolling",
    /// `zig.embed_index_html`. When `web_version` pins exactly the release
    /// `EMBEDDED_SHELL` was taken from, the shell is served from the binary
    /// and the startup CDN fetch is skipped — upstream pinned-release
    /// semantics. `false` restores the always-fetch behaviour.
    embed_index_html: bool = true,
    settings: Settings = .{},
};

/// Port of OpenList's `SiteConfig`.
///
/// `cdn` here is the *normalised* value: trailing slash trimmed, `$version`
/// expanded, and — when unset — fallen back to the base path. It is what goes
/// into the `cdn:` placeholder and into the 302 targets. The local-vs-CDN
/// routing decision uses the raw config value instead; see `Frontend.cdn_raw`.
pub const SiteConfig = struct {
    base_path: []const u8,
    cdn: []const u8,
};

/// Where the served shell came from. Reported at startup, and used by tests to
/// assert which branch ran.
pub const Source = enum {
    /// Fetched from `{cdn}/index.html` at startup (or a fallback).
    cdn,
    /// Read from `dist_dir/index.html`.
    dist_dir,
    /// `EMBEDDED_SHELL`, baked into the binary at build time. Only when the
    /// deployment pins the matching `web_version` and did not opt out.
    embedded,
    /// `BUILTIN_INDEX`, the diagnostic placeholder page.
    builtin,
};

pub const Frontend = struct {
    /// Owns every string in this struct.
    ///
    /// Behind a pointer, not inline: `ArenaAllocator.allocator()` hands out an
    /// interface whose `ptr` is the arena's own address, so moving the arena
    /// after that call would dangle every allocator derived from it. Keeping it
    /// on the heap lets this struct be returned and copied by value.
    arena: *std.heap.ArenaAllocator,

    site: SiteConfig,
    /// Raw `cdn` from config. Upstream branches on *this*, not on `site.cdn`.
    cdn_raw: []const u8,
    dist_dir: []const u8,
    /// True when `dist_dir` names a directory that exists, i.e. when assets
    /// can actually be served locally.
    has_dist: bool,
    settings: Settings,
    source: Source,

    /// Fully substituted, customisations applied. Served for every non-asset
    /// path that is not `/@manage*`.
    index_html: []const u8,
    /// Favicon/logo/title/colour applied but *not* the custom head and body
    /// blocks. Served for `/@manage*` so operator-supplied HTML is not
    /// injected into the admin SPA.
    manage_html: []const u8,
    /// 内置占位页（含首装面板），同样经过 token 替换。
    ///
    /// 配了 cdn 或 dist_dir 时前端是上游 SPA，正常路径下**不会**用到这份；
    /// 它专供 `/<base>/@zig-setup` —— 一个本实现独有的、手动访问的入口。
    /// 存在的理由：CDN 取不到时二进制直接拒绝启动，而排查者往往只需要一个
    /// 能看到 `init_status`、能建管理员的页面，不必先修好 CDN。
    setup_html: []const u8,
    /// `/manifest.json`, the PWA manifest.
    manifest_json: []const u8,

    pub fn deinit(self: *Frontend) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
        self.arena = undefined;
    }

    pub fn allocator(self: *Frontend) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Which shell to serve for `path`. Mirrors the catch-all handler: the
    /// `/@manage` prefix is the admin SPA.
    pub fn htmlFor(self: *const Frontend, path: []const u8) []const u8 {
        return if (std.mem.startsWith(u8, path, "/@manage")) self.manage_html else self.index_html;
    }

    /// 手动 setup 页的路径后缀（相对 base_path）。
    ///
    /// 刻意**不叫** `/@init`：那是上游前端自己的安装向导路由，抢过来会让
    /// 配了 CDN 的正常部署行为错乱。`zig` 前缀表明这是本实现独有的入口。
    pub const setup_path_suffix = "/@zig-setup";

    /// 内置 setup 页。配了 CDN 时前端是上游 SPA，正常路径下拿不到它；
    /// 手动访问 `/<base>/@zig-setup` 即可 —— 这是 CDN 挂掉时的排查入口。
    pub fn setupHtml(self: *const Frontend) []const u8 {
        return self.setup_html;
    }

    /// What to do with a request for a frontend asset.
    ///
    /// `path` is the percent-decoded path (used for local file lookup);
    /// `raw_target` is the still-encoded request target (used for the redirect
    /// URL). They differ for any asset whose name needs escaping, and the CDN
    /// needs the encoded form.
    /// M03：`a` 必须是**请求级** allocator。
    ///
    /// 以前这里用 `self.arena`（进程生命周期）来拼重定向 URL 和本地文件路径，
    /// 每个公开静态资源请求都往里面堆一份，直到进程结束才释放；并发请求还
    /// 共用同一个 arena（不是线程安全的分配器）。
    pub fn asset(self: *Frontend, a: std.mem.Allocator, path: []const u8, raw_target: []const u8) Asset {
        if (self.cdn_raw.len > 0) {
            var b = Buf.init(a);
            // `site.cdn` has no trailing slash and `raw_target` starts with
            // one, so this cannot produce a doubled slash.
            b.append(self.site.cdn) catch return .missing;
            b.append(if (raw_target.len > 0 and raw_target[0] == '/') raw_target else path) catch return .missing;
            return .{ .redirect = b.toOwned() catch return .missing };
        }

        if (!self.has_dist) return .missing;

        const rel = stripLeadingSlash(path);
        if (!isSafeRelative(rel)) return .missing;

        const full = std.fs.path.join(a, &.{ self.dist_dir, rel }) catch return .missing;
        const st = std.Io.Dir.cwd().statFile(rt.io(), full, .{}) catch return .missing;
        if (st.kind != .file) return .missing;
        return .{ .local = .{ .path = full, .size = st.size } };
    }
};

pub const Asset = union(enum) {
    /// Serve this file from disk.
    local: LocalFile,
    /// 302 the client at this URL.
    redirect: []const u8,
    /// No local build and no CDN configured.
    missing,

    pub const LocalFile = struct {
        path: []const u8,
        size: u64,
    };
};

/// True when `path` is one of the four asset prefixes. Requires the trailing
/// slash so that a storage mounted at `/static` is not shadowed by the
/// `/static/` asset prefix.
pub fn isAssetPath(path: []const u8) bool {
    for (asset_folders) |folder| {
        if (path.len > folder.len + 1 and path[0] == '/') {
            if (std.mem.startsWith(u8, path[1..], folder) and path[1 + folder.len] == '/') return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// Build the frontend, fetching `{cdn}/index.html` if the configuration calls
/// for it. Does blocking network I/O at startup.
pub fn init(alloc: std.mem.Allocator, in: Input) !Frontend {
    const arena = try newArena(alloc);
    errdefer freeArena(arena);

    const a = arena.allocator();
    const site = try siteConfig(a, in);
    const raw = try loadRawIndex(a, in, site);
    // 配了 fallback 时，实际可用的是 `raw.cdn` 而不是配置里的 `site.cdn`。
    // assets 的 302 必须跟着走，否则壳能加载、资源全 404。
    var eff = site;
    if (raw.cdn.len > 0) eff.cdn = raw.cdn;
    return build(arena, in, eff, raw.html, raw.source);
}

/// Build the frontend from an already-obtained shell. No I/O. Tests use this.
pub fn initFromHtml(alloc: std.mem.Allocator, in: Input, raw_index: []const u8) !Frontend {
    const arena = try newArena(alloc);
    errdefer freeArena(arena);

    const site = try siteConfig(arena.allocator(), in);
    return build(arena, in, site, raw_index, if (in.dist_dir.len > 0) .dist_dir else .builtin);
}

fn newArena(alloc: std.mem.Allocator) !*std.heap.ArenaAllocator {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(alloc);
    return arena;
}

fn freeArena(arena: *std.heap.ArenaAllocator) void {
    const child = arena.child_allocator;
    arena.deinit();
    child.destroy(arena);
}

fn build(arena: *std.heap.ArenaAllocator, in: Input, site: SiteConfig, raw_index: []const u8, source: Source) !Frontend {
    const a = arena.allocator();
    // Duplicate everything the caller owns so the returned value is
    // self-contained and the caller's strings may be freed.
    const settings = Settings{
        .site_title = try a.dupe(u8, in.settings.site_title),
        .main_color = try a.dupe(u8, in.settings.main_color),
        .logo = try a.dupe(u8, in.settings.logo),
        .favicon = try a.dupe(u8, in.settings.favicon),
        .customize_head = try a.dupe(u8, in.settings.customize_head),
        .customize_body = try a.dupe(u8, in.settings.customize_body),
    };
    const dist_dir = try a.dupe(u8, in.dist_dir);
    const cdn_raw = try a.dupe(u8, in.cdn);

    const has_dist = blk: {
        if (dist_dir.len == 0) break :blk false;
        const st = std.Io.Dir.cwd().statFile(rt.io(), dist_dir, .{}) catch break :blk false;
        break :blk st.kind == .directory;
    };

    // Pass 1 — site configuration. These are the tokens `initIndex` fills in.
    const manifest_path = if (std.mem.eql(u8, site.base_path, "/"))
        "/manifest.json"
    else
        try std.fmt.allocPrint(a, "{s}/manifest.json", .{site.base_path});

    // 三份 shell 走**同一个**渲染函数，避免内置 setup 页那份漏掉替换 ——
    // 漏了的话页面上会原样出现 `cdn: undefined` / `Loading...` 这类占位符。
    const index_html = try renderShell(a, raw_index, site, settings, manifest_path, true);
    const manage_html = try renderShell(a, raw_index, site, settings, manifest_path, false);
    // 内置页始终渲染一份：配了 CDN 时前端是上游 SPA，但仍允许手动访问
    // `/<base>/@zig-setup` 拿到这个自包含的 setup 页（CDN 挂掉时的救命入口）。
    const setup_html = try renderShell(a, BUILTIN_INDEX, site, settings, manifest_path, false);

    return .{
        .arena = arena,
        .site = site,
        .cdn_raw = cdn_raw,
        .dist_dir = dist_dir,
        .has_dist = has_dist,
        .settings = settings,
        .source = source,
        .index_html = index_html,
        .manage_html = manage_html,
        .setup_html = setup_html,
        .manifest_json = try manifestJson(a, site.base_path, settings),
    };
}

/// 对任意原始 HTML 做三轮 token 替换：
///   1. 站点配置（`cdn` / `base_path` / manifest 路径）
///   2. 展示设置（favicon / logo / 标题 / 主色）
///   3. 运营注入（`customize_head` / `customize_body`）—— 仅公开 shell
///
/// `raw_index`（CDN/dist 拿到的）与 `BUILTIN_INDEX`（内置页）都经过这里，
/// 所以两者在 token 处理上行为一致。
fn renderShell(
    a: std.mem.Allocator,
    raw: []const u8,
    site: SiteConfig,
    settings: Settings,
    manifest_path: []const u8,
    with_operator_html: bool,
) ![]const u8 {
    // Pass 1 — site configuration. These are the tokens `initIndex` fills in.
    const pass1 = try replaceFirstEach(a, raw, &[_]Pair{
        .{ .needle = "cdn: undefined", .replacement = try std.fmt.allocPrint(a, "cdn: '{s}'", .{site.cdn}) },
        .{ .needle = "base_path: undefined", .replacement = try std.fmt.allocPrint(a, "base_path: '{s}'", .{site.base_path}) },
        .{ .needle = "href=\"/manifest.json\"", .replacement = try std.fmt.allocPrint(a, "href=\"{s}\"", .{manifest_path}) },
    });

    // Pass 2 — presentation settings. This is `UpdateIndex`.
    const pass2 = try replaceFirstEach(a, pass1, &[_]Pair{
        .{ .needle = "https://res.oplist.org/logo/logo.svg", .replacement = settings.favicon },
        .{ .needle = "https://res.oplist.org/logo/logo.png", .replacement = settings.logo },
        .{ .needle = "Loading...", .replacement = settings.site_title },
        .{ .needle = "main_color: undefined", .replacement = try std.fmt.allocPrint(a, "main_color: '{s}'", .{settings.main_color}) },
    });

    // Pass 3 — operator HTML injection. Only the public shell gets it; the
    // `/@manage` SPA and the setup page must not have operator HTML injected.
    if (!with_operator_html) return pass2;
    return replaceFirstEach(a, pass2, &[_]Pair{
        .{ .needle = "<!-- customize head -->", .replacement = settings.customize_head },
        .{ .needle = "<!-- customize body -->", .replacement = settings.customize_body },
    });
}

// ---------------------------------------------------------------------------
// Site configuration
// ---------------------------------------------------------------------------

/// Port of OpenList's `getSiteConfig`.
pub fn siteConfig(a: std.mem.Allocator, in: Input) !SiteConfig {
    const base_path = try basePathFrom(a, in.site_url);
    const cdn = try expandVersion(a, in.cdn, in.web_version);

    if (cdn.len == 0) {
        // Upstream quirk, preserved deliberately: with no CDN configured the
        // *normalised* cdn becomes the base path with its trailing slash
        // removed. For the default base path "/" that is the empty string, so
        // the shell reads `cdn: ''` and the frontend resolves assets against
        // the base path. For a non-root base path it reads `cdn: '/sub'`.
        return .{ .base_path = base_path, .cdn = trimTrailingSlash(base_path) };
    }
    return .{ .base_path = base_path, .cdn = cdn };
}

fn basePathFrom(a: std.mem.Allocator, site_url: []const u8) ![]const u8 {
    const p = pathOfUrl(site_url);
    if (p.len == 0) return "/";
    // `fixAndCleanPath` mirrors `utils.FixAndCleanPath`: force a leading
    // slash, collapse duplicates, resolve `.`/`..`. `cleanPath` already drops
    // a trailing slash except at the root, so nothing more is needed here.
    return fixAndCleanPath(a, p);
}

/// Extract the path component of a URL without pulling in a URI parser.
///
/// `std.Uri` would work, but it returns components in a raw-or-percent-encoded
/// union that then needs normalising; the path is all we need and it is
/// unambiguous.
fn pathOfUrl(u: []const u8) []const u8 {
    if (u.len == 0) return "";
    var rest = u;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    // The authority ends at the first '/', '?' or '#'.
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse return "";
    if (end >= rest.len) return "";
    var p = rest[end..];
    if (std.mem.indexOfAny(u8, p, "?#")) |i| p = p[0..i];
    return p;
}

fn fixAndCleanPath(a: std.mem.Allocator, p: []const u8) ![]const u8 {
    if (p.len == 0) return "/";
    var b = Buf.init(a);
    defer b.deinit();
    if (p[0] != '/') try b.appendByte('/');
    try b.append(p);
    return urlmod.cleanPath(a, b.slice());
}

/// `strings.TrimSuffix(p, "/")`, including the "/" -> "" case that makes the
/// default CDN fallback come out empty.
fn trimTrailingSlash(p: []const u8) []const u8 {
    if (p.len > 0 and p[p.len - 1] == '/') return p[0 .. p.len - 1];
    return p;
}

/// `strings.ReplaceAll(strings.TrimSuffix(cdn, "/"), "$version", strings.TrimPrefix(web_version, "v"))`.
fn expandVersion(a: std.mem.Allocator, cdn: []const u8, web_version: []const u8) ![]const u8 {
    const trimmed = trimTrailingSlash(cdn);
    if (std.mem.indexOf(u8, trimmed, "$version") == null) return trimmed;

    const ver = if (web_version.len > 0 and web_version[0] == 'v') web_version[1..] else web_version;
    var b = Buf.init(a);
    defer b.deinit();
    var rest = trimmed;
    while (std.mem.indexOf(u8, rest, "$version")) |i| {
        try b.append(rest[0..i]);
        try b.append(ver);
        rest = rest[i + "$version".len ..];
    }
    try b.append(rest);
    return b.toOwned();
}

// ---------------------------------------------------------------------------
// Shell loading
// ---------------------------------------------------------------------------

/// `cdn` 是**实际生效**的那个 CDN：配了 fallback 时它可能不是配置里的
/// `cdn`，而 assets 的 302 必须指向真正能用的那一个，所以这里要带出来。
const RawIndex = struct {
    html: []const u8,
    source: Source,
    cdn: []const u8 = "",
};

/// Where the shell will come from. Split out of `loadRawIndex` so the branch
/// selection is testable without a network round trip.
pub fn sourceFor(in: Input) Source {
    // 配了 fallback 也算"有 CDN"：用户给了来源就是要走 CDN 分支，
    // 不该因为主 cdn 留空而静默退回占位页。
    if (in.dist_dir.len == 0 and (in.cdn.len > 0 or in.cdn_fallbacks.len > 0)) {
        // 上游 pinned-release 语义：`web_version` 钉死且与内嵌外壳同一版本
        // ⇒ 直接用内嵌的，启动零网络往返。版本对不上（rolling / beta /
        // 别的 pin）⇒ 仍走 CDN 拉取 —— 拿 4.2.6 的哈希文件名去配 rolling
        // 的 assets 只会得到一个白屏，宁可多一次启动拉取。
        if (in.embed_index_html and embeddedShellMatches(in.web_version)) return .embedded;
        return .cdn;
    }
    if (in.dist_dir.len > 0) return .dist_dir;
    return .builtin;
}

/// Port of OpenList's `initIndex` branch selection.
///
/// Upstream serves a rolling-style `web_version` (`""`, `beta`, `dev`,
/// `rolling`) from the CDN and prefers its `//go:embed`ed copy for pinned
/// releases. This port mirrors both halves: pinned on `EMBEDDED_SHELL`'s
/// release (with `zig.embed_index_html` not disabled) serves the baked shell
/// with no network round trip; everything else fetches `{cdn}/index.html`
/// through the fallback chain below. The one divergence left: a pinned
/// version that does *not* match the baked shell still fetches from the CDN,
/// where upstream would use its embedded dist — fetching keeps the shell and
/// the assets on the same build instead of serving a guaranteed-mismatched
/// pair.
fn loadRawIndex(a: std.mem.Allocator, in: Input, site: SiteConfig) !RawIndex {
    switch (sourceFor(in)) {
        .cdn => {
            // 候选顺序：先配置的 `cdn`，再依次试 `cdn_fallbacks`。
            // 每个候选重试 `cdn_retries` 次 —— 网络抖动是**间歇性**的
            // （实测同一 URL 时而 200、时而 reset/503），重试比换域名更早
            // 见效，所以内层是重试、外层才是换源。
            var cands: [max_cdn_candidates][]const u8 = undefined;
            var n: usize = 0;
            if (site.cdn.len > 0) {
                cands[n] = site.cdn;
                n += 1;
            }
            for (in.cdn_fallbacks) |f| {
                // fallback 里的 `$version` 也要展开，否则只有主 cdn 支持
                // 版本占位，两个来源行为不一致。
                const expanded = try expandVersion(a, f, in.web_version);
                if (expanded.len == 0 or n >= cands.len) continue;
                // 去重：fallback 里重复写了主 cdn 时不浪费一轮。
                var dup = false;
                for (cands[0..n]) |c| {
                    if (std.mem.eql(u8, c, expanded)) dup = true;
                }
                if (dup) continue;
                cands[n] = expanded;
                n += 1;
            }
            if (n == 0) return error.CdnIndexFetchFailed;

            const tries: u32 = if (in.cdn_retries == 0) 1 else in.cdn_retries;
            var last_url: []const u8 = "";
            var last_err: anyerror = error.CdnIndexFetchFailed;

            for (cands[0..n], 0..) |cand, ci| {
                log.info("frontend: fetching index.html from CDN {s} ({d}/{d}): {s}/index.html", .{ cand, ci + 1, n, cand });
                var t: u32 = 0;
                while (t < tries) : (t += 1) {
                    const html = fetchIndex(a, cand) catch |e| {
                        last_url = cand;
                        last_err = e;
                        log.warn("frontend: CDN {s} attempt {d}/{d} failed: {s}", .{ cand, t + 1, tries, @errorName(e) });
                        continue;
                    };
                    if (ci > 0) {
                        log.warn("frontend: primary CDN failed; using fallback {s} — " ++
                            "consider putting it first in `cdn` or fixing network reachability", .{cand});
                    }
                    log.info("frontend: fetched {d} bytes of index.html from CDN", .{html.len});
                    // 关键：assets 的 302 必须指向**实际可用**的那个 CDN，
                    // 否则壳能加载、资源全 404。
                    return .{ .html = html, .source = .cdn, .cdn = cand };
                }
            }

            // 上游是 Fatalf，这里同样拒绝启动：服务一个资源全 302 到黑洞的
            // 壳，比直接起不来更难排查。
            log.err("frontend: all {d} CDN candidate(s) failed ({d} attempt(s) each); last: {s}: {s}", .{ n, tries, last_url, @errorName(last_err) });
            return error.CdnIndexFetchFailed;
        },
        .dist_dir => {
            const path = try std.fs.path.join(a, &.{ in.dist_dir, "index.html" });
            const html = std.Io.Dir.cwd().readFileAlloc(rt.io(), path, a, .limited(max_index_bytes)) catch |e| {
                log.err("frontend: cannot read {s}: {s}", .{ path, @errorName(e) });
                return error.MissingIndexHtml;
            };
            log.info("frontend: using custom dist directory {s}", .{in.dist_dir});
            return .{ .html = html, .source = .dist_dir };
        },
        .embedded => {
            // 没有网络往返：外壳就在二进制里。`cdn` 留空，`init` 便沿用
            // `site.cdn`（`$version` 已展开），assets 的 302 因此指向配置的
            // 主 CDN；`cdn_fallbacks` 在这个分支**不参与** —— 那是拉取失败时
            // 的换源机制，这里没有拉取。也刻意不做可达性探测：探测一次就把
            // 启动网络依赖请回来了，与这个分支存在的意义矛盾。CDN 挂掉的
            // 表现是浏览器侧资源加载失败，二进制照常起 —— 与上游 pinned
            // release 的姿态一致。
            log.info("frontend: using embedded shell (upstream v{s}); assets come from the configured cdn", .{embedded_shell_version});
            return .{ .html = EMBEDDED_SHELL, .source = .embedded };
        },
        .builtin => return .{ .html = BUILTIN_INDEX, .source = .builtin },
    }
}

fn fetchIndex(a: std.mem.Allocator, cdn: []const u8) ![]const u8 {
    const url = try std.fmt.allocPrint(a, "{s}/index.html", .{cdn});

    // A throwaway jar: the CDN is not expected to set cookies, and sharing the
    // storage drivers' jar would leak its contents into the frontend fetch.
    var jar = cookiejar.Jar.init(a);
    defer jar.deinit();
    var cl = client_mod.Client.init(a, .{
        .timeout_s = 30,
        .user_agent = "OpenList-Zig",
        .insecure_skip_verify = false,
    }, &jar);
    defer cl.deinit();

    const res = try cl.send(a, .{
        .url = url,
        .headers = &.{.{ .name = "Accept", .value = "text/html" }},
        .use_cookies = false,
    });
    if (res.status != 200) {
        log.err("frontend: CDN returned HTTP {d} for {s}", .{ res.status, url });
        return error.CdnIndexFetchError;
    }
    if (res.body.len > max_index_bytes) return error.CdnIndexTooLarge;
    return res.body;
}

// ---------------------------------------------------------------------------
// Placeholder substitution
// ---------------------------------------------------------------------------

const Pair = struct { needle: []const u8, replacement: []const u8 };

/// Port of OpenList's `replaceStrings`: replace at most the *first* occurrence
/// of each needle.
///
/// Two deliberate differences from the Go original, both removing
/// nondeterminism it has:
///   * needles are tried in a fixed order, not Go's randomised map order;
///   * the scan never re-examines inserted text, so a replacement whose value
///     happens to contain another needle — a logo URL ending in `.png`, say —
///     cannot cascade into a second replacement.
fn replaceFirstEach(a: std.mem.Allocator, content: []const u8, pairs: []const Pair) ![]const u8 {
    if (pairs.len == 0) return content;

    const done = try a.alloc(bool, pairs.len);
    @memset(done, false);

    var out = Buf.init(a);
    defer out.deinit();

    var i: usize = 0;
    while (i < content.len) {
        var matched = false;
        for (pairs, 0..) |p, pi| {
            if (done[pi] or p.needle.len == 0) continue;
            if (std.mem.startsWith(u8, content[i..], p.needle)) {
                try out.append(p.replacement);
                i += p.needle.len;
                done[pi] = true;
                matched = true;
                break;
            }
        }
        if (!matched) {
            try out.appendByte(content[i]);
            i += 1;
        }
    }
    return out.toOwned();
}

/// The PWA manifest. Upstream marshals a struct with `json.Encoder`, which
/// emits the fields in declaration order and appends a newline; both are
/// reproduced so a cached manifest stays byte-identical across the two builds.
fn manifestJson(a: std.mem.Allocator, base_path: []const u8, settings: Settings) ![]const u8 {
    const logo_url = firstLine(settings.logo);

    var b = Buf.init(a);
    defer b.deinit();
    try b.append("{\"display\":\"standalone\",\"scope\":");
    try writeJsonString(&b, base_path);
    try b.append(",\"start_url\":");
    try writeJsonString(&b, base_path);
    try b.append(",\"name\":");
    try writeJsonString(&b, settings.site_title);
    try b.append(",\"icons\":[{\"src\":");
    try writeJsonString(&b, logo_url);
    try b.append(",\"sizes\":\"512x512\",\"type\":\"image/png\"}]}\n");
    return b.toOwned();
}

/// `strings.Split(s, "\n")[0]`. OpenList stores the logo as a multi-line text
/// setting (light and dark variants); the manifest takes the light one.
fn firstLine(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\n')) |i| return s[0..i];
    return s;
}

/// JSON string escaping, matching Go's `encoding/json` for the subset that can
/// appear here: `"` `\` and the C0 controls. `<`, `>` and `&` are escaped as
/// `\u003c`/`\u003e`/`\u0026` by Go's default `SetEscapeHTML(true)`, and the
/// site title and logo URL are both operator-controlled, so they get the same
/// treatment rather than being emitted raw into an HTML-adjacent document.
fn writeJsonString(b: *Buf, s: []const u8) !void {
    try b.appendByte('"');
    for (s) |c| switch (c) {
        '"' => try b.append("\\\""),
        '\\' => try b.append("\\\\"),
        '\n' => try b.append("\\n"),
        '\r' => try b.append("\\r"),
        '\t' => try b.append("\\t"),
        '<' => try b.append("\\u003c"),
        '>' => try b.append("\\u003e"),
        '&' => try b.append("\\u0026"),
        else => {
            if (c < 0x20) {
                try b.print("\\u{x:0>4}", .{c});
            } else {
                try b.appendByte(c);
            }
        },
    };
    try b.appendByte('"');
}

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

fn stripLeadingSlash(p: []const u8) []const u8 {
    if (p.len > 0 and p[0] == '/') return p[1..];
    return p;
}

/// Reject anything that could escape `dist_dir`. `http.Request.path` is
/// percent-decoded, so `%2e%2e%2f` arrives here as `../` and has to be caught
/// by name; the caller has already collapsed nothing.
fn isSafeRelative(rel: []const u8) bool {
    if (rel.len == 0) return false;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return false;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) return false;
    }
    return true;
}

/// Stand-in for OpenList's embedded `public/dist`.
///
/// Not a frontend: a diagnostic page that proves the server is up and names
/// the two ways to get the real UI. It deliberately reuses the upstream
/// placeholder tokens (`Loading...`, both `res.oplist.org` logo URLs,
/// `cdn:`/`base_path:`/`main_color: undefined`, `href="/manifest.json"`, and
/// both customisation comments) so that the substitution pipeline is exercised
/// identically whether the shell came from here, from `dist_dir`, or from a
/// CDN.
const BUILTIN_INDEX =
    \\<!doctype html>
    \\<html lang="zh-CN">
    \\  <head>
    \\    <!-- customize head -->
    \\    <meta charset="utf-8" />
    \\    <meta name="viewport" content="width=device-width, initial-scale=1" />
    \\    <meta name="color-scheme" content="light dark" />
    \\    <meta name="generator" content="OpenList" />
    \\    <link href="/manifest.json" rel="manifest" />
    \\    <link rel="apple-touch-icon" href="https://res.oplist.org/logo/logo.png" />
    \\    <link rel="shortcut icon" type="image/svg+xml" href="https://res.oplist.org/logo/logo.svg" />
    \\    <title>Loading...</title>
    \\    <script>
    \\      window.OPENLIST_CONFIG = {
    \\        cdn: undefined,
    \\        base_path: undefined,
    \\        api: undefined,
    \\        main_color: undefined,
    \\      }
    \\      window.__dynamic_base__ = window.OPENLIST_CONFIG.cdn || ""
    \\    </script>
    \\    <style>
    \\      :root { --fg:#1f2328; --bg:#ffffff; --dim:#59636e; --line:#d1d9e0; --code:#f6f8fa; }
    \\      @media (prefers-color-scheme: dark) {
    \\        :root { --fg:#e6edf3; --bg:#0d1117; --dim:#9198a1; --line:#30363d; --code:#161b22; }
    \\      }
    \\      body { font:15px/1.65 system-ui,-apple-system,"Segoe UI","Noto Sans CJK SC",sans-serif;
    \\             background:var(--bg); color:var(--fg); max-width:760px; margin:0 auto; padding:40px 20px; }
    \\      h1 { font-size:1.5rem; margin:0 0 .25rem; }
    \\      .sub { color:var(--dim); margin:0 0 2rem; }
    \\      h2 { font-size:1rem; margin:2rem 0 .5rem; border-bottom:1px solid var(--line); padding-bottom:.35rem; }
    \\      code, pre { font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:.875em; }
    \\      code { background:var(--code); padding:.15em .4em; border-radius:4px; }
    \\      pre { background:var(--code); border:1px solid var(--line); border-radius:6px; padding:12px 14px; overflow-x:auto; }
    \\      ul { padding-left:1.3rem; } li { margin:.3rem 0; }
    \\      a { color:var(--accent,#1890ff); }
    \\      .pill { display:inline-block; border:1px solid var(--line); border-radius:999px;
    \\              padding:.1em .7em; font-size:.78em; color:var(--dim); }
    \\    </style>
    \\  </head>
    \\  <body>
    \\    <h1 id="title">OpenList</h1>
    \\    <p class="sub" id="tagline">内置页 —— 首次安装与故障排查用。</p>
    \\    <p class="pill" id="mode"></p>
    \\
    \\    <h2 id="setup-title">首次安装</h2>
    \\    <p id="setup-lead">这个实例还没有管理员。填下面两项即可完成初始化 ——
    \\    它发的就是 <code>POST /api/public/init/setup</code>，与上游前端的安装向导是同一个接口。</p>
    \\    <form id="setup">
    \\      <p><label>用户名 <input name="username" value="admin" required /></label></p>
    \\      <p><label>密码 <input name="password" type="password" minlength="4" required /></label>
    \\         <span class="sub">至少 4 位</span></p>
    \\      <p><button type="submit">创建管理员</button></p>
    \\      <p id="setup-msg" class="sub"></p>
    \\    </form>
    \\
    \\    <div id="setup-done" hidden>
    \\      <p>这个实例<strong>已经初始化过了</strong>，不需要再建管理员。</p>
    \\      <p><a href="/" id="home-link">打开完整前端 →</a></p>
    \\      <p class="sub">忘了密码就在服务器上执行
    \\      <code>openlist admin set NEW_PASSWORD</code>（或 <code>admin random</code>）。
    \\      <code>admin set</code> 在还没有任何管理员时会报 <code>NoAdministrator</code>，
    \\      所以它只能改密码，不能用来首次创建。</p>
    \\    </div>
    \\
    \\    <details id="about">
    \\      <summary>关于这个内置页 / 怎么配前端来源</summary>
    \\      <p class="sub">配了 <code>cdn</code> 或 <code>dist_dir</code> 时，正常访问
    \\      <code>/</code> 得到的是完整前端；本页只在两种情况下有用：还没有管理员时
    \\      完成初始化，以及前端加载不出来时做排查。下面是没配前端来源时的配置说明。</p>
    \\
    \\    <h2>为什么不是完整前端</h2>
    \\    <p>原版把编译好的前端（完整版约 20&nbsp;MB，lite 版约 2.9&nbsp;MB）用
    \\    <code>//go:embed</code> 编进 Go 二进制。本项目存在的意义正是去掉这部分体积，
    \\    因此这里改为在运行时从外部加载，行为与原版一致。</p>
    \\
    \\    <h2>方式一：本地 dist 目录（推荐）</h2>
    \\    <p>下载官方 lite 前端并解压，然后把 <code>dist_dir</code> 指向该目录：</p>
    \\    <pre>curl -L -o fe.tar.gz \\
    \\  https://github.com/OpenListTeam/OpenList-Frontend/releases/latest/download/openlist-frontend-dist-lite.tar.gz
    \\mkdir -p data/dist &amp;&amp; tar -xzf fe.tar.gz -C data/dist</pre>
    \\    <p>在 <code>config.json</code> 中设置：</p>
    \\    <pre>{ "dist_dir": "data/dist" }</pre>
    \\
    \\    <h2>方式二：CDN</h2>
    \\    <p>把 dist 目录挂到任意静态托管上，然后在 <code>config.json</code> 中设置
    \\    <code>cdn</code>。其中 <code>$version</code> 会替换为
    \\    <code>web_version</code>（去掉前导 <code>v</code>）：</p>
    \\    <pre>{ "cdn": "https://your-cdn.example.com/openlist/$version/dist",
    \\  "zig": { "web_version": "v4.2.6" } }</pre>
    \\    <p>启动时会从 <code>{cdn}/index.html</code> 拉取页面外壳，
    \\    <code>/assets/</code>、<code>/images/</code>、<code>/streamer/</code>、
    \\    <code>/static/</code> 四个前缀则 302 跳转到 CDN。</p>
    \\    <p class="sub">当前构建内嵌了 v4.2.6 的页面外壳：把
    \\    <code>web_version</code> 钉在同一版本时启动不再拉取外壳，二进制断网也能起；
    \\    registry.npmmirror.com 这类只拦 .html（451）的 CDN 也能直接当
    \\    <code>cdn</code> 用 —— 外壳由本二进制出，assets 由浏览器从它加载。
    \\    配 <code>"zig": {"embed_index_html": false}</code> 回到“启动拉取”。</p>
    \\
    \\    <h2>接口</h2>
    \\    <ul>
    \\      <li><code>GET /ping</code> — 存活探测</li>
    \\      <li><code>GET /api/public/settings</code> — 站点配置</li>
    \\      <li><code>POST /api/auth/login</code> — 登录换取 JWT</li>
    \\      <li><code>POST /api/fs/list</code> — 列目录</li>
    \\      <li><code>GET /d/*</code> — 下载</li>
    \\    </ul>
    \\    <p class="sub">接口是 OpenList 的子集，完整前端只会有部分功能可用，
    \\    详见 <code>docs/STATUS.md</code>。</p>
    \\
    \\    </details>
    \\
    \\    <script>
    \\      var c = window.OPENLIST_CONFIG;
    \\      if (c.main_color) {
    \\        document.documentElement.style.setProperty("--accent", c.main_color);
    \\      }
    \\      var parts = [];
    \\      if (c.base_path && c.base_path !== "/") parts.push("base_path " + c.base_path);
    \\      parts.push(c.cdn ? "assets → CDN" : "assets → 本地");
    \\      document.getElementById("mode").textContent = parts.join(" · ");
    \\
    \\      // init_status 是 public 路由，不需要令牌。
    \\      // 已初始化时**必须换文案**：访问 @zig-setup 的人多半是想初始化，
    \\      // 旧版把表单永久隐藏后页面看起来就是坏的（用户实测反馈）。
    \\      fetch("api/public/init_status").then(function (r) { return r.json(); })
    \\        .then(function (j) {
    \\          var initialized = !!(j && j.data && j.data.initialized);
    \\          if (initialized) {
    \\            document.getElementById("setup-title").hidden = true;
    \\            document.getElementById("setup-lead").hidden = true;
    \\            document.getElementById("setup-done").hidden = false;
    \\            return;
    \\          }
    \\          var f = document.getElementById("setup");
    \\          f.hidden = false;
    \\          f.onsubmit = function (ev) {
    \\            ev.preventDefault();
    \\            var d = new FormData(f);
    \\            fetch("api/public/init/setup", {
    \\              method: "POST",
    \\              headers: { "Content-Type": "application/json" },
    \\              body: JSON.stringify({ username: d.get("username"), password: d.get("password") }),
    \\            }).then(function (r) { return r.json(); })
    \\              .then(function (j) {
    \\                if (j && j.code === 200) { location.reload(); return; }
    \\                document.getElementById("setup-msg").textContent =
    \\                  "失败：" + ((j && j.message) || "未知错误");
    \\              }).catch(function (e) {
    \\                document.getElementById("setup-msg").textContent = "失败：" + e;
    \\              });
    \\            return false;
    \\          };
    \\        }).catch(function () {
    \\          document.getElementById("setup-title").hidden = true;
    \\          document.getElementById("setup-lead").hidden = true;
    \\          document.getElementById("setup-done").hidden = false;
    \\        });
    \\    </script>
    \\    <!-- customize body -->
    \\  </body>
    \\</html>
;

// ---------------------------------------------------------------------------

const testing = std.testing;

/// The upstream frontend's `index.html`, verbatim (`OpenList-Frontend` @ main,
/// v4.2.6). Kept here so the substitution tests run against the real artefact
/// rather than a paraphrase of it — the whole point of the exercise is that
/// the shipped HTML is what gets rewritten at startup.
const UPSTREAM_INDEX_HTML =
    \\<!doctype html>
    \\<html lang="en" translate="no">
    \\  <head>
    \\    <!-- customize head -->
    \\    <meta charset="utf-8" />
    \\    <meta name="viewport" content="width=device-width, initial-scale=1" />
    \\    <meta name="referrer" content="same-origin" />
    \\    <meta name="color-scheme" content="light dark" />
    \\    <meta name="generator" content="OpenList" />
    \\    <meta name="theme-color" content="#000000" />
    \\    <meta name="google" content="notranslate" />
    \\    <link href="/manifest.json" rel="manifest" />
    \\    <meta name="apple-mobile-web-app-capable" content="yes" />
    \\    <meta name="apple-mobile-web-app-title" content="OpenList" />
    \\    <link rel="apple-touch-icon" href="https://res.oplist.org/logo/logo.png" />
    \\    <link
    \\      rel="shortcut icon"
    \\      type="image/ico"
    \\      href="https://res.oplist.org/logo/logo.svg"
    \\    />
    \\    <title>Loading...</title>
    \\    <script>
    \\      window.OPENLIST_CONFIG = {
    \\        cdn: undefined,
    \\        base_path: undefined,
    \\        api: undefined,
    \\        main_color: undefined,
    \\      }
    \\      window.__dynamic_base__ = window.OPENLIST_CONFIG.cdn || ""
    \\    </script>
    \\  </head>
    \\  <body>
    \\    <noscript>You need to enable JavaScript to run this app.</noscript>
    \\    <div id="root"></div>
    \\
    \\    <script src="/src/main.tsx" type="module"></script>
    \\    <!-- customize body -->
    \\  </body>
    \\</html>
;

test "pathOfUrl extracts the path component" {
    try testing.expectEqualStrings("", pathOfUrl(""));
    try testing.expectEqualStrings("", pathOfUrl("https://example.com"));
    try testing.expectEqualStrings("/", pathOfUrl("https://example.com/"));
    try testing.expectEqualStrings("/sub", pathOfUrl("https://example.com/sub"));
    // The trailing slash is part of the path; `basePathFrom` is what trims it.
    try testing.expectEqualStrings("/sub/", pathOfUrl("https://example.com/sub/"));
    try testing.expectEqualStrings("/sub/", pathOfUrl("https://example.com/sub/?a=1"));
    try testing.expectEqualStrings("/sub", pathOfUrl("https://example.com/sub#frag"));
    try testing.expectEqualStrings("/sub", pathOfUrl("http://example.com:5244/sub"));
    // A bare path is accepted too.
    try testing.expectEqualStrings("/sub", pathOfUrl("/sub"));
}

test "expandVersion substitutes every occurrence and strips a leading v" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings(
        "https://c.example.com/4.2.6/dist",
        try expandVersion(a, "https://c.example.com/$version/dist/", "v4.2.6"),
    );
    try testing.expectEqualStrings(
        "https://c.example.com/rolling/dist",
        try expandVersion(a, "https://c.example.com/$version/dist", "rolling"),
    );
    // No placeholder: the trailing slash is still trimmed.
    try testing.expectEqualStrings(
        "https://c.example.com/dist",
        try expandVersion(a, "https://c.example.com/dist/", "v1.0.0"),
    );
    // Empty stays empty, which is what makes the default fallback work.
    try testing.expectEqualStrings("", try expandVersion(a, "", "rolling"));
}

test "sourceFor picks the CDN whenever no dist_dir is set" {
    try testing.expectEqual(Source.builtin, sourceFor(.{}));
    try testing.expectEqual(Source.cdn, sourceFor(.{ .cdn = "https://c.example.com/dist" }));
    // Upstream pinned-release semantics, now mirrored: pinning the baked
    // shell's release serves the embedded copy instead of fetching.
    try testing.expectEqual(Source.embedded, sourceFor(.{
        .cdn = "https://c.example.com/$version/dist",
        .web_version = "v4.2.6",
    }));
    // Opt-out switch restores the always-fetch behaviour.
    try testing.expectEqual(Source.cdn, sourceFor(.{
        .cdn = "https://c.example.com/$version/dist",
        .web_version = "v4.2.6",
        .embed_index_html = false,
    }));
    // 版本对不上 ⇒ 仍然拉取：4.2.6 的外壳配 rolling 的 assets 是必然白屏。
    try testing.expectEqual(Source.cdn, sourceFor(.{
        .cdn = "https://c.example.com/dist",
        .web_version = "rolling",
    }));
    try testing.expectEqual(Source.cdn, sourceFor(.{
        .cdn = "https://c.example.com/dist",
        .web_version = "v4.2.5",
    }));
    // A dist_dir wins over the CDN, as upstream.
    try testing.expectEqual(Source.dist_dir, sourceFor(.{ .cdn = "https://c/x", .dist_dir = "/fe" }));
    try testing.expectEqual(Source.dist_dir, sourceFor(.{ .dist_dir = "/fe" }));
    // 只给了 fallback 也算有 CDN —— 用户给了来源就该走 CDN 分支，
    // 不该因为主 cdn 留空而静默退回占位页。
    try testing.expectEqual(Source.cdn, sourceFor(.{
        .cdn_fallbacks = &.{"https://f.example.com/dist"},
    }));
    // dist_dir 仍然优先于 fallback。
    try testing.expectEqual(Source.dist_dir, sourceFor(.{
        .cdn_fallbacks = &.{"https://f.example.com/dist"},
        .dist_dir = "/fe",
    }));
}

test "embedded shell matches only its own pinned version" {
    try testing.expect(embeddedShellMatches("v" ++ embedded_shell_version));
    try testing.expect(embeddedShellMatches(embedded_shell_version));
    // 与 `expandVersion` 一致：只认小写 `v` 前缀。
    try testing.expect(!embeddedShellMatches("V4.2.6"));
    try testing.expect(!embeddedShellMatches("4.2.5"));
    try testing.expect(!embeddedShellMatches("rolling"));
    try testing.expect(!embeddedShellMatches("beta"));
    try testing.expect(!embeddedShellMatches(""));
}

test "embedded shell is the real built artefact, placeholders intact" {
    // 内嵌的是 npm 包里的 built dist/index.html 本尊，不是转述。占位符集合
    // 与 renderShell 的 needle 一一对应 —— 上游改了占位符写法时，这里先炸，
    // 不会把 `cdn: undefined` 原样发给用户。
    for ([_][]const u8{
        "window.OPENLIST_CONFIG",
        "cdn: undefined",
        "base_path: undefined",
        "main_color: undefined",
        "href=\"/manifest.json\"",
        "https://res.oplist.org/logo/logo.svg",
        "https://res.oplist.org/logo/logo.png",
        "Loading...",
        "<!-- customize head -->",
        "<!-- customize body -->",
    }) |needle| {
        try testing.expect(std.mem.indexOf(u8, EMBEDDED_SHELL, needle) != null);
    }
    // 是 built 产物而不是仓库里的 dev 版 index.html（那个引用 /src/main.tsx），
    // 且带着本版本的哈希资源名。
    try testing.expect(std.mem.indexOf(u8, EMBEDDED_SHELL, "/src/main.tsx") == null);
    try testing.expect(std.mem.indexOf(u8, EMBEDDED_SHELL, "/assets/") != null);
}

test "renderer fills the embedded shell like any other shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const site = SiteConfig{
        .base_path = "/",
        .cdn = "https://registry.npmmirror.com/@openlist-frontend/openlist-frontend/4.2.6/files/dist",
    };
    const out = try renderShell(a, EMBEDDED_SHELL, site, .{}, "/manifest.json", true);
    try testing.expect(std.mem.indexOf(u8, out, "cdn: 'https://registry.npmmirror.com/@openlist-frontend/openlist-frontend/4.2.6/files/dist'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "cdn: undefined") == null);
    try testing.expect(std.mem.indexOf(u8, out, "Loading...") == null);
    try testing.expect(std.mem.indexOf(u8, out, "main_color: '#1890ff'") != null);
    // 烙进外壳的哈希资源名必须原样存活 —— 改写管线只碰 OPENLIST_CONFIG 一带。
    try testing.expect(std.mem.indexOf(u8, out, "/assets/index-") != null);
}

test "cdn fallback list is deduplicated and version-expanded" {
    // 这段逻辑在 `loadRawIndex` 里（需要网络才能走到 fetch），但候选表的构造
    // 是纯计算，单独提出来测：主 cdn 与 fallback 重复时只留一份，且
    // fallback 里的 `$version` 与主 cdn 一样要展开。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const main = try expandVersion(a, "https://main/$version/dist", "v4.2.6");
    try testing.expectEqualStrings("https://main/4.2.6/dist", main);

    // 与主 cdn 重复的 fallback 必须被跳过（否则白等一轮超时）
    const dup = try expandVersion(a, "https://main/$version/dist", "v4.2.6");
    try testing.expect(std.mem.eql(u8, main, dup));

    const alt = try expandVersion(a, "https://alt/$version/dist", "v4.2.6");
    try testing.expectEqualStrings("https://alt/4.2.6/dist", alt);
    try testing.expect(!std.mem.eql(u8, main, alt));
}

test "siteConfig follows OpenList's getSiteConfig" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Default install: no site_url, no cdn. base_path "/" and the normalised
    // cdn falls back to TrimSuffix("/", "/") == "".
    {
        const s = try siteConfig(a, .{});
        try testing.expectEqualStrings("/", s.base_path);
        try testing.expectEqualStrings("", s.cdn);
    }
    // Non-root base path with no cdn: the normalised cdn becomes the base path
    // minus its trailing slash, so the shell asks for assets under /sub.
    {
        const s = try siteConfig(a, .{ .site_url = "https://example.com/sub/" });
        try testing.expectEqualStrings("/sub", s.base_path);
        try testing.expectEqualStrings("/sub", s.cdn);
    }
    // Real cdn wins over the fallback.
    {
        const s = try siteConfig(a, .{
            .site_url = "https://example.com/sub",
            .cdn = "https://c.example.com/$version/dist",
            .web_version = "v4.2.6",
        });
        try testing.expectEqualStrings("/sub", s.base_path);
        try testing.expectEqualStrings("https://c.example.com/4.2.6/dist", s.cdn);
    }
}

test "placeholder substitution rewrites the real upstream index.html" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try initFromHtml(a, .{
        .cdn = "https://cdn.example.com/rolling/dist",
        .web_version = "rolling",
        .settings = .{ .site_title = "My 光猫", .main_color = "#ff0000" },
    }, UPSTREAM_INDEX_HTML);
    defer fe.deinit();

    const html = fe.index_html;
    try testing.expect(std.mem.indexOf(u8, html, "cdn: 'https://cdn.example.com/rolling/dist'") != null);
    try testing.expect(std.mem.indexOf(u8, html, "base_path: '/'") != null);
    try testing.expect(std.mem.indexOf(u8, html, "main_color: '#ff0000'") != null);
    try testing.expect(std.mem.indexOf(u8, html, "<title>My 光猫</title>") != null);
    // `api: undefined` is left alone, matching upstream.
    try testing.expect(std.mem.indexOf(u8, html, "api: undefined") != null);
    // Every placeholder was consumed.
    try testing.expect(std.mem.indexOf(u8, html, "undefined'") == null);
    try testing.expect(std.mem.indexOf(u8, html, "Loading...") == null);
    // `href="/manifest.json"` is a no-op at the root, and must stay intact.
    try testing.expect(std.mem.indexOf(u8, html, "href=\"/manifest.json\"") != null);
}

test "base path rewrites the manifest href and the cdn fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try initFromHtml(a, .{ .site_url = "https://example.com/openlist" }, UPSTREAM_INDEX_HTML);
    defer fe.deinit();

    try testing.expect(std.mem.indexOf(u8, fe.index_html, "href=\"/openlist/manifest.json\"") != null);
    // No CDN configured, so the normalised value falls back to the base path.
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "cdn: '/openlist'") != null);
    try testing.expectEqualStrings("/openlist", fe.site.base_path);
}

test "customize blocks reach the public shell but not the admin shell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try initFromHtml(a, .{
        .settings = .{ .customize_head = "<script>1</script>", .customize_body = "<div>2</div>" },
    }, UPSTREAM_INDEX_HTML);
    defer fe.deinit();

    try testing.expect(std.mem.indexOf(u8, fe.index_html, "<script>1</script>") != null);
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "<div>2</div>") != null);
    // The admin shell keeps the raw comments instead of the injected HTML.
    try testing.expect(std.mem.indexOf(u8, fe.manage_html, "<!-- customize head -->") != null);
    try testing.expect(std.mem.indexOf(u8, fe.manage_html, "<script>1</script>") == null);

    try testing.expectEqualStrings(fe.index_html, fe.htmlFor("/"));
    try testing.expectEqualStrings(fe.manage_html, fe.htmlFor("/@manage/storage"));
}

test "a replacement value containing another needle does not cascade" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The favicon value itself contains the `.png` needle. Go's randomised map
    // order makes the result depend on iteration order here; ours cannot.
    var fe = try initFromHtml(a, .{
        .settings = .{ .favicon = "https://x/logo.png", .logo = "https://x/logo.svg" },
    }, UPSTREAM_INDEX_HTML);
    defer fe.deinit();

    try testing.expect(std.mem.indexOf(u8, fe.index_html, "href=\"https://x/logo.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "href=\"https://x/logo.svg\"") != null);
}

test "asset paths are recognised and cannot escape dist_dir" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(isAssetPath("/assets/index-abc.js"));
    try testing.expect(isAssetPath("/images/bg.png"));
    try testing.expect(isAssetPath("/streamer/hls.m3u8"));
    try testing.expect(isAssetPath("/static/logo.svg"));
    // Needs the trailing slash: a storage mounted at /static is not an asset.
    try testing.expect(!isAssetPath("/static"));
    try testing.expect(!isAssetPath("/staticx/a"));
    try testing.expect(!isAssetPath("/@manage"));
    try testing.expect(!isAssetPath("/"));
    // The four names are not allowed to be matched as bare prefixes.
    try testing.expect(!isAssetPath("/assetsx/a.js"));

    try testing.expect(isSafeRelative("assets/a.js"));
    try testing.expect(!isSafeRelative("../etc/passwd"));
    try testing.expect(!isSafeRelative("assets/../../etc/passwd"));
    try testing.expect(!isSafeRelative(""));
    try testing.expect(!isSafeRelative("a/\x00b"));

    // With a CDN configured the asset is a redirect, and the encoded target is
    // what gets appended — not the decoded path.
    var fe = try initFromHtml(a, .{ .cdn = "https://c.example.com/dist" }, UPSTREAM_INDEX_HTML);
    defer fe.deinit();
    const r = fe.asset(a, "/assets/a b.js", "/assets/a%20b.js?v=1");
    try testing.expectEqualStrings("https://c.example.com/dist/assets/a%20b.js?v=1", r.redirect);

    // With neither a CDN nor a dist dir there is nothing to serve.
    var fe2 = try initFromHtml(a, .{}, UPSTREAM_INDEX_HTML);
    defer fe2.deinit();
    try testing.expect(std.meta.activeTag(fe2.asset(a, "/assets/a.js", "/assets/a.js")) == .missing);
}

test "manifest matches upstream's shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try initFromHtml(a, .{
        .site_url = "https://example.com/sub",
        .settings = .{ .site_title = "Home", .logo = "https://x/logo.svg\nhttps://x/dark.svg" },
    }, UPSTREAM_INDEX_HTML);
    defer fe.deinit();

    // Scope and start_url follow the base path; the logo is the first line only.
    try testing.expectEqualStrings(
        "{\"display\":\"standalone\",\"scope\":\"/sub\",\"start_url\":\"/sub\",\"name\":\"Home\"," ++
            "\"icons\":[{\"src\":\"https://x/logo.svg\",\"sizes\":\"512x512\",\"type\":\"image/png\"}]}\n",
        fe.manifest_json,
    );
}

test "the builtin shell carries every token the pipeline looks for" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tokens = [_][]const u8{
        "cdn: undefined",
        "base_path: undefined",
        "main_color: undefined",
        "Loading...",
        "https://res.oplist.org/logo/logo.svg",
        "https://res.oplist.org/logo/logo.png",
        "href=\"/manifest.json\"",
        "<!-- customize head -->",
        "<!-- customize body -->",
    };
    // A typo in the constant would show up as a missing token.
    for (tokens) |tok| try testing.expect(std.mem.indexOf(u8, BUILTIN_INDEX, tok) != null);

    // Every replacement is given a value distinct from its token, so "the token
    // is gone" really does mean it was substituted. With the *defaults* two of
    // these are identity replacements — favicon is literally the logo.svg URL,
    // and the manifest href is unchanged at the root — and the token would
    // legitimately survive.
    var fe = try initFromHtml(a, .{
        .site_url = "https://example.com/sub",
        .settings = .{
            .site_title = "T",
            .favicon = "https://x/f.ico",
            .logo = "https://x/l.png",
            .main_color = "#123456",
            .customize_head = "<!--h-->",
            .customize_body = "<!--b-->",
        },
    }, BUILTIN_INDEX);
    defer fe.deinit();

    try testing.expectEqual(Source.builtin, fe.source);
    for (tokens) |tok| {
        try testing.expect(std.mem.indexOf(u8, fe.index_html, tok) == null);
    }
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "<title>T</title>") != null);
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "cdn: '/sub'") != null);
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "base_path: '/sub'") != null);
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "main_color: '#123456'") != null);
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "href=\"/sub/manifest.json\"") != null);
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "href=\"https://x/f.ico\"") != null);
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "href=\"https://x/l.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "<!--h-->") != null);
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "<!--b-->") != null);
}

test "the built-in shell carries a first-run setup panel" {
    // 回归（用户 2026-10-15 指出）：内置占位页原先连入口都没有，普通用户无法在
    // 浏览器里初始化 —— 只能上服务器敲 curl。这个面板把它补上，发的是
    // `POST /api/public/init/setup`（和原版前端安装向导同一个接口）。
    // 于是这几样东西必须在页面里齐备，缺一个表单就跑不通。
    try testing.expect(std.mem.indexOf(u8, BUILTIN_INDEX, "首次安装") != null);
    try testing.expect(std.mem.indexOf(u8, BUILTIN_INDEX, "id=\"setup\"") != null);
    // init_status 是 public 路由，页面据此决定显不显面板
    try testing.expect(std.mem.indexOf(u8, BUILTIN_INDEX, "api/public/init_status") != null);
    try testing.expect(std.mem.indexOf(u8, BUILTIN_INDEX, "api/public/init/setup") != null);
    // 密码下限与后端一致（后端是 <4 拒绝）
    try testing.expect(std.mem.indexOf(u8, BUILTIN_INDEX, "minlength=\"4\"") != null);
    // 成功后 reload，让页面进入已初始化状态
    try testing.expect(std.mem.indexOf(u8, BUILTIN_INDEX, "location.reload()") != null);
}

test "the built-in page's inline JS contains no HTML entities" {
    // 回归（2026-10-15 用户实测报错：`Unexpected token ';'`，表单永远不显示）。
    // `<script>` 是 raw text 元素 —— 里面的 HTML 实体**不会被解码**。写了
    // `&amp;&amp;`，浏览器就把字面量 `&amp;&amp;` 交给 JS 解析器，于是
    // `c.base_path & amp` 后面跟 `;` ⇒ 语法错误 ⇒ **整个脚本不执行**。
    // 这条测试就是钉住"script 段内不许出现实体"。
    const body_at = std.mem.indexOf(u8, BUILTIN_INDEX, "  <body>").?;
    const js_start = std.mem.lastIndexOf(u8, BUILTIN_INDEX, "<script>").?;
    try testing.expect(js_start > body_at); // 必须取到 body 里那个，不是 head 的
    const js_end = std.mem.lastIndexOf(u8, BUILTIN_INDEX, "</script>").?;
    const js = BUILTIN_INDEX[js_start..js_end];
    for ([_][]const u8{ "&amp;", "&lt;", "&gt;", "&quot;", "&#" }) |ent| {
        if (std.mem.indexOf(u8, js, ent)) |at| {
            std.debug.print("built-in page JS contains HTML entity '{s}' at offset {d}\n", .{ ent, at });
            return error.TestUnexpectedResult;
        }
    }
    // 顺带确认取到的确实是主逻辑（而不是空段）。
    try testing.expect(std.mem.indexOf(u8, js, "init_status") != null);
}

test "the setup form is visible without JS (progressive enhancement)" {
    // 表单**默认可见**，JS 在确认"已初始化"之后才隐藏它。
    // 反过来的做法（默认 hidden + 靠 JS 亮出）会让脚本一出错页面就彻底废掉 ——
    // 这正是 2026-10-15 那个 bug 的放大器：JS 因实体报错，表单也就永远不见了。
    try testing.expect(std.mem.indexOf(u8, BUILTIN_INDEX, "<form id=\"setup\">") != null);
    try testing.expect(std.mem.indexOf(u8, BUILTIN_INDEX, "<form id=\"setup\" hidden>") == null);
}

test "the built-in setup page is rendered even when a CDN supplies the shell" {
    // 回归（用户 2026-10-15 要求）：配了 cdn 时正常路径走上游 SPA，但仍要能
    // 手动访问 `/<base>/@zig-setup` 拿到内置页 —— 这是 CDN 取不到时的排查入口。
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fe = try initFromHtml(a, .{
        .cdn = "https://c.example.com/4.2.6/dist",
        .settings = .{
            .site_title = "MyTitle",
            // 用带标记的值，才能区分"注入了"和"没注入"。
            .customize_head = "OPERATOR_HEAD_MARKER",
            .customize_body = "OPERATOR_BODY_MARKER",
        },
    }, "<html><div id=\"root\"></div><!-- customize head --></html>");
    defer fe.deinit();

    // 正常路径用的是 CDN 那份，setup 页是另一份，两者不能混。
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "<div id=\"root\">") != null);
    try testing.expect(std.mem.indexOf(u8, fe.setupHtml(), "id=\"setup\"") != null);
    try testing.expect(std.mem.indexOf(u8, fe.setupHtml(), "首次安装") != null);
    // token 替换同样生效，不能残留占位符。
    try testing.expect(std.mem.indexOf(u8, fe.setupHtml(), "cdn: undefined") == null);
    try testing.expect(std.mem.indexOf(u8, fe.setupHtml(), "main_color: undefined") == null);
    // 运营注入的 HTML **内容**不进 setup 页（与 /@manage 同规矩）。
    // 注意断言的是内容标记而不是 token 字面量 —— `<!-- customize head -->`
    // 在 BUILTIN_INDEX 里本来就存在，不注入时它会作为注释原样留下。
    try testing.expect(std.mem.indexOf(u8, fe.setupHtml(), "OPERATOR_HEAD_MARKER") == null);
    try testing.expect(std.mem.indexOf(u8, fe.setupHtml(), "OPERATOR_BODY_MARKER") == null);
    // 公开 shell 才拿得到它。
    try testing.expect(std.mem.indexOf(u8, fe.index_html, "OPERATOR_HEAD_MARKER") != null);
    // 路径刻意避开上游的 /@init。
    try testing.expectEqualStrings("/@zig-setup", Frontend.setup_path_suffix);
}
