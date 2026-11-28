//! 认证与签名原语 —— 自 api.zig 整体搬出（AUDIT-2026-11-27 路线图
//! #15-M2）。搬出为纯移动：跨协议共享的登录限速、凭据哈希
//! （static/two-hash/salt）、JWT 测试铸币、下载签名
//! （signPath/signForObj/verifySign）与作废令牌表逐行保持不变。
//! api.zig 侧的登录 handler（loginCommon/checkAuth/issueToken）与下载鉴权
//! （M6 拆出）留守，经 `auth.*` 别名调用；webdav/sftp_wire/main 的认证面
//! 同样切到本模块。App 与 ctEqual 以别名引用（api↔auth 双向 import 与既有
//! api↔webdav 同形，完整解环在 M6 download 拆出后闭环）。

const std = @import("std");
const http = @import("http.zig");
const model = @import("model.zig");
const config = @import("config.zig");
const log = @import("log.zig");
const rt = @import("rt.zig");
const urlmod = @import("util/url.zig");
const peeraddr = @import("util/peeraddr.zig");
const json = @import("util/json.zig");
const Buf = @import("util/buf.zig").Buf;

const api = @import("api.zig");
const App = api.App;
const ctEqual = api.ctEqual;
const testing = std.testing;


/// 下载签名密钥：`zig.token`（Go 的 `token` 设置），空串时回退 jwt_secret。
/// 单独一个函数是为了让所有签名/验签点**只有一处**取密钥 —— 换密钥（
/// reset_token）时不会漏掉某条路径。
pub fn signKey(app: *const App) []const u8 {
    return if (app.sign_secret.len > 0) app.sign_secret else app.jwt_secret;
}

/// `already_static` = 收到的 password 是否已经过 `StaticHash`。
/// M11：登录防爆破。对齐 Go `model.LoginCache`（internal/model/user.go:33-37）：
/// 失败计数 ≥5 锁 5 分钟、期间返回 429 `TooManyAttempts`，成功清零。
///
/// ## 按来源分桶（2026-11-01）
///
/// Go 用 `c.ClientIP()` 分桶。这里过去是**全局**计数 —— 因为拿不到对端地址。
/// 全局计数的副作用很实在：任何人反复试错 5 次就能把管理员账户锁 5 分钟
/// （HTTP 和 SSH 还会互相牵连）。现在 `util/peeraddr.zig` 在 POSIX 上能拿到
/// IP，于是照 Go 的语义分桶；拿不到（Windows，或 socket 已断）就退回全局桶，
/// 行为与以前一致，不会因为「没 IP」而放行任何人。
///
/// ⚠ 桶键**必须用纯 IP、不带端口**。上游 Go 的 HTTP 登录用的是 `c.ClientIP()`
/// （gin 会剥掉端口，所以天然是纯 IP），**但它的 FTP 用的是
/// `cc.RemoteAddr().String()` —— 这个带端口**，扫描器每次源端口都不同 ⇒ 每个
/// 连接一个新桶 ⇒ 计数永远到不了阈值，限速形同虚设（`docs/STATUS.md` §9）。
/// 也就是说这条规则不是从 HTTP 那条路径抄来的，而是从 FTP 那个坑反推出来的。
const ThrottleBucket = struct {
    /// `false` = 从未使用。**不能**用「key 为空」判断：全局桶的 key 本来就是
    /// 空串，用 key_len == 0 当空闲标记会让全局桶被别人覆盖掉。
    used: bool = false,
    key: [peeraddr.max_len]u8 = @splat(0),
    key_len: u8 = 0,
    fails: u32 = 0,
    locked_until: i64 = 0,
    /// 最近一次使用（秒）。表满时淘汰最久未用的那个。
    seen: i64 = 0,

    fn name(self: *const ThrottleBucket) []const u8 {
        return self.key[0..self.key_len];
    }
};

/// 同时跟踪多少个来源。单管理员部署实际上只有一两个；表满了淘汰最久未用
/// 的桶，于是「大量来源轮番爆破」最多占用这么多内存（每个桶 ~90 字节）。
const throttle_buckets = 64;

const LoginThrottle = struct {
    mu: std.Io.Mutex = .init,
    buckets: [throttle_buckets]ThrottleBucket = @splat(.{}),

    /// 找已存在的桶，**不**新建。成功路径用它：一次成功登录不该占用一个桶位，
    /// 否则表满时会把某个正在锁定的来源淘汰掉（等于给攻击者一次重试）。
    fn find(self: *LoginThrottle, key: []const u8) ?*ThrottleBucket {
        for (&self.buckets) |*b| {
            if (b.used and b.key_len == key.len and std.mem.eql(u8, b.name(), key)) return b;
        }
        return null;
    }

    /// 找到 `key` 的桶；没有就占用一个空位/最久未用的位置。
    /// 调用方必须持锁。
    fn slot(self: *LoginThrottle, key: []const u8, now: i64) *ThrottleBucket {
        var first_free: ?usize = null;
        var lru: usize = 0; // 所有桶都占用时才用得上，此时它一定是 used 的

        for (&self.buckets, 0..) |*b, i| {
            if (b.used and b.key_len == key.len and std.mem.eql(u8, b.name(), key)) return b;
            if (!b.used) {
                if (first_free == null) first_free = i;
            } else if (b.seen < self.buckets[lru].seen) {
                lru = i;
            }
        }

        const b = &self.buckets[first_free orelse lru];
        // 键过长（理论上不会：IP 文本 ≤ 45 字节）就截断，宁可把两个来源
        // 并进同一个桶（更严），也不能越界。
        const n = @min(key.len, peeraddr.max_len);
        @memcpy(b.key[0..n], key[0..n]);
        b.key_len = @intCast(n);
        b.used = true;
        b.fails = 0;
        b.locked_until = 0;
        b.seen = now;
        return b;
    }

    /// true = 允许继续尝试；false = 处于锁定期，应回 429。
    pub fn allow(self: *LoginThrottle, key: []const u8) bool {
        self.mu.lockUncancelable(rt.io());
        defer self.mu.unlock(rt.io());
        const now = rt.nowSeconds();
        const b = self.slot(key, now);
        b.seen = now;
        if (b.locked_until > now) {
            // 锁定期内**每次**尝试都续期（Go `LoginCache.Expire(ip, 5min)`，
            // server/handles/auth.go:52）。不续期的话锁定就是一个固定 5 分钟
            // 的窗口，攻击者可以精确按节奏继续爆破；续期后越试锁得越久。
            b.locked_until = now + lock_duration_s;
            return false;
        }
        if (b.locked_until != 0) {
            // 锁定期满（Go `LoginCache.Expire` 的语义）：重新计数。
            b.fails = 0;
            b.locked_until = 0;
        }
        return true;
    }

    pub fn recordFailure(self: *LoginThrottle, key: []const u8) void {
        self.mu.lockUncancelable(rt.io());
        defer self.mu.unlock(rt.io());
        const now = rt.nowSeconds();
        const b = self.slot(key, now);
        b.seen = now;
        b.fails += 1;
        if (b.fails >= max_auth_retries) {
            b.locked_until = now + lock_duration_s;
            // 锁定**进入**时告警一次（带来源）。拒绝路径上不再打日志：HTTP 侧
            // 锁定期内每个请求都会被拒，逐请求打日志等于给扫描器一个「写穿
            // 闪存」的放大面（stderr 落盘，光猫小容量 flash）；SSH 侧虽然每
            // 次拒绝都对应一次完整握手、量级小得多，但也统一走这一条。
            log.warn("auth: {s} locked for {d}s after {d} failed logins", .{
                b.name(), lock_duration_s, b.fails,
            });
        }
    }

    pub fn recordSuccess(self: *LoginThrottle, key: []const u8) void {
        self.mu.lockUncancelable(rt.io());
        defer self.mu.unlock(rt.io());
        // 只清已有的桶：成功登录不该新建桶（见 `find` 的注释）。
        const b = self.find(key) orelse return;
        b.fails = 0;
        b.locked_until = 0;
        b.seen = rt.nowSeconds();
    }
};

/// 登录限速：`key` = 对端 IP（不带端口），空串 = 全局桶。
///
/// HTTP 登录与 SSH 认证**共用同一份计数**：换协议不能绕过限速。同一个来源
/// 用两种协议各试 3 次，加起来照样到阈值。
pub fn authThrottleAllow(key: []const u8) bool {
    return login_throttle.allow(key);
}

pub fn authThrottleFailure(key: []const u8) void {
    login_throttle.recordFailure(key);
}

pub fn authThrottleSuccess(key: []const u8) void {
    login_throttle.recordSuccess(key);
}

pub fn authThrottleReset() void {
    login_throttle.mu.lockUncancelable(rt.io());
    defer login_throttle.mu.unlock(rt.io());
    login_throttle.buckets = @splat(.{});
}

/// Go `model.DefaultMaxAuthRetries`。
const max_auth_retries: u32 = 5;
/// Go `model.DefaultLockDuration` = 5 分钟。
const lock_duration_s: i64 = 5 * 60;

pub var login_throttle = LoginThrottle{};

/// Go `common.GenerateDownProxyURL`（server/common/proxy.go:151-163）。
/// 没配 `down_proxy_url` 时返回**空串** —— 与上游一致（fsread.go:319 判
/// `if rawURL == ""` 再回落本站 `/p`）。
pub fn generateDownProxyURL(
    app: *App,
    a: std.mem.Allocator,
    storage: *const model.Storage,
    path: []const u8,
) ![]const u8 {
    if (storage.down_proxy_url.len == 0) return "";
    // Go `strings.Split(s, "\n")[0]` —— 多行只取第一行。
    const base = if (std.mem.indexOfScalar(u8, storage.down_proxy_url, '\n')) |i|
        storage.down_proxy_url[0..i]
    else
        storage.down_proxy_url;
    const enc = try urlmod.pathEscape(a, path);
    if (storage.disable_proxy_sign) return std.fmt.allocPrint(a, "{s}{s}", .{ base, enc });
    // `?sign=` + `sign.Sign(reqPath)`（**不看 sign_all**）。
    return std.fmt.allocPrint(a, "{s}{s}?sign={s}", .{ base, enc, try signPath(app, a, path) });
}

/// 从 `Authorization` 里抠出 JWT 的第三段（签名）。拿不到就返回 null
/// （空 token / admin token / `?token=` 形式都走不到这里，与 Go 的
/// "空 token 直接返回 nil" 一致）。
pub fn jwtSignatureOf(req: *http.Request) ?[]const u8 {
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

    pub fn add(self: *InvalidatedTokens, sig: []const u8) void {
        if (sig.len == 0 or sig.len > max_len) return;
        self.mu.lockUncancelable(rt.io());
        defer self.mu.unlock(rt.io());
        @memcpy(self.buf[self.head][0..sig.len], sig);
        self.lens[self.head] = sig.len;
        self.head = (self.head + 1) % cap;
        if (self.count < cap) self.count += 1;
    }

    pub fn contains(self: *InvalidatedTokens, sig: []const u8) bool {
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

pub var g_invalidated_tokens: InvalidatedTokens = .{ .buf = undefined };

pub fn sha256Hex(a: std.mem.Allocator, s: []const u8) ![]const u8 {
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

pub fn hmacSha256(a: std.mem.Allocator, key: []const u8, msg: []const u8) ![32]u8 {
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, msg, key);
    _ = a;
    return mac;
}

pub fn b64Url(a: std.mem.Allocator, data: []const u8) ![]const u8 {
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

/// Go `internal/sign.Sign(data)`（internal/sign/sign.go:12-19）。
///
/// ⚠️ 它**不看 `sign_all`** —— 上游的 `sign.Sign` 是无条件签，用不用由调用方
/// 决定（`common.Sign` 看 `sign_all`，`GenerateDownProxyURL` 与 Strm 的
/// `withSign` 不看）。读 `link_expiration`（小时）：0 ⇒ 永不过期（`expire=0`），
/// 否则 `now + N*3600`。
pub fn signPath(app: *App, a: std.mem.Allocator, path: []const u8) ![]const u8 {
    // 没有加载配置（单元测试 / 极早期启动）时按「不过期」处理 —— 与 Go 的
    // `setting.GetInt` 在 settings 表未初始化时返回零值同形。
    const cfg = config.getOpt() orelse return signValue(a, signKey(app), path, 0);
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

/// 给 `fs/list` / `fs/get` 的对象签一个下载签名。
///
/// 对齐 Go `server/common/sign.go:13-18`：目录不签；非目录时
/// `!encrypt && !sign_all` 也不签（本工程没有 meta 加密，所以只看 `sign_all`）。
pub fn signForObj(app: *App, a: std.mem.Allocator, is_dir: bool, path: []const u8) ![]const u8 {
    if (is_dir) return "";
    // 没有加载配置（单元测试 / 极早期启动）时按「不签」处理 —— 与 Go 的
    // `setting.GetBool` 在 settings 表未初始化时返回零值同形。
    const cfg = config.getOpt() orelse return "";
    if (!cfg.sign_all) return "";
    return signPath(app, a, path);
}

/// `Verify(data, sign)` —— 逐条对齐 Go `pkg/sign/hmac.go:34-56`。
pub fn verifySign(app: *App, a: std.mem.Allocator, data: []const u8, sign: []const u8) !void {
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

pub fn mintTestToken(a: std.mem.Allocator, secret: []const u8, user: []const u8, pwd_ts: i64) ![]u8 {
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

/// M14 之后**每枚测试令牌必须互不相同**。
///
/// `mintTestToken` 的 payload 只由 secret/user/pwd_ts/exp 决定，于是所有调用
/// 方拿到的是**同一枚**令牌。M14 让 logout 真的作废出示的令牌之后，「登出」
/// 测试会把并发运行的其它测试的令牌一起作废（Zig 测试执行器是并行的，
/// 全局作废表是共享的）—— 表现为看似无关的测试突然 401。
/// 这里给每枚令牌塞一个唯一 nonce，把它们的签名撑开。
var g_test_token_seq = std.atomic.Value(u64).init(0);

/// 带唯一 nonce 的测试令牌（payload 多一个 `nbf`，校验侧不看它）。
pub fn mintTestTokenUnique(a: std.mem.Allocator, secret: []const u8, user: []const u8, pwd_ts: i64) ![]u8 {
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


// ---------------------------------------------------------------------------
// 登录限速的行为测试（随域自 api.zig 搬来；仅去掉调用前缀，逐行未动）
// ---------------------------------------------------------------------------

test "auth/throttle: 失败计数按来源分桶，锁一个不影响另一个" {
    // 这是「按 IP 分桶」存在的全部意义：全局计数下，任何人试错 5 次就能把
    // 管理员锁 5 分钟。桶键必须是**纯 IP**（端口每次都变，带上就等于每个连接
    // 一个桶 —— 上游 FTP 的 `RemoteAddr().String()` 就是这么失效的）。
    defer authThrottleReset();
    authThrottleReset();

    const bad = "203.0.113.7";
    var i: usize = 0;
    while (i < max_auth_retries) : (i += 1) {
        try testing.expect(authThrottleAllow(bad));
        authThrottleFailure(bad);
    }
    try testing.expect(!authThrottleAllow(bad)); // 第 6 次：锁住

    // 另一个来源、以及全局桶（空键 = 拿不到 IP 的平台）都不受影响。
    try testing.expect(authThrottleAllow("203.0.113.8"));
    try testing.expect(authThrottleAllow(""));
}

test "auth/throttle: 空键是独立桶，不会和「空位」混淆" {
    // 空串既是全局桶的键，也是桶未使用时的初始状态。用 `key_len == 0` 判断
    // 「空位」会让全局桶被第一个来源覆盖掉 —— 这条用例就是钉住 `used` 标志。
    defer authThrottleReset();
    authThrottleReset();

    var i: usize = 0;
    while (i < max_auth_retries) : (i += 1) {
        try testing.expect(authThrottleAllow(""));
        authThrottleFailure("");
    }
    try testing.expect(!authThrottleAllow("")); // 全局桶确实被锁
    try testing.expect(authThrottleAllow("192.0.2.1")); // 有 IP 的来源另算
}

test "auth/throttle: 成功一次清零，之后重新攒满才锁" {
    defer authThrottleReset();
    authThrottleReset();

    const ip = "198.51.100.4";
    var i: usize = 0;
    while (i < max_auth_retries - 1) : (i += 1) {
        try testing.expect(authThrottleAllow(ip));
        authThrottleFailure(ip);
    }
    authThrottleSuccess(ip);
    // 清零后还能再失败满 5 次，第 6 次才锁 —— 证明计数真的归零了。
    i = 0;
    while (i < max_auth_retries) : (i += 1) {
        try testing.expect(authThrottleAllow(ip));
        authThrottleFailure(ip);
    }
    try testing.expect(!authThrottleAllow(ip));
}

test "auth/throttle: 锁定期满自动重新计数（Go `LoginCache` 过期语义）" {
    defer authThrottleReset();
    authThrottleReset();

    const ip = "198.51.100.9";
    var i: usize = 0;
    while (i < max_auth_retries) : (i += 1) {
        _ = authThrottleAllow(ip);
        authThrottleFailure(ip);
    }
    try testing.expect(!authThrottleAllow(ip));

    // 把锁定期拨到过去，模拟 5 分钟过去。不这样做就只能等真实的 5 分钟。
    const now = rt.nowSeconds();
    for (&login_throttle.buckets) |*b| {
        if (b.used and std.mem.eql(u8, b.name(), ip)) b.locked_until = now - 1;
    }
    try testing.expect(authThrottleAllow(ip)); // 过期 ⇒ 放行
    // 而且是**重新计数**，不是「剩 1 次」：再失败满 5 次才会锁。
    i = 0;
    while (i < max_auth_retries) : (i += 1) {
        try testing.expect(authThrottleAllow(ip));
        authThrottleFailure(ip);
    }
    try testing.expect(!authThrottleAllow(ip));
}

test "auth/throttle: 锁定期内继续尝试会续期（越试锁得越久）" {
    // Go `LoginCache.Expire(ip, 5min)` 在锁定分支里**每次**都执行，所以持续
    // 爆破会把锁定一直往后推。不续期的话锁定只是一个固定的 5 分钟窗口，
    // 攻击者按节奏打就能拿到稳定的尝试配额。
    defer authThrottleReset();
    authThrottleReset();

    const ip = "198.51.100.11";
    var i: usize = 0;
    while (i < max_auth_retries) : (i += 1) {
        _ = authThrottleAllow(ip);
        authThrottleFailure(ip);
    }

    // 把锁定期压到「只剩 100 秒」，再试一次。
    const now = rt.nowSeconds();
    for (&login_throttle.buckets) |*b| {
        if (b.used and std.mem.eql(u8, b.name(), ip)) b.locked_until = now + 100;
    }
    try testing.expect(!authThrottleAllow(ip));

    const after = rt.nowSeconds();
    for (&login_throttle.buckets) |*b| {
        if (b.used and std.mem.eql(u8, b.name(), ip)) {
            // 续期到「当前 + 完整锁定时长」；±1 秒是时间戳跨秒的抖动。
            try testing.expect(b.locked_until >= after + lock_duration_s - 1);
            try testing.expect(b.locked_until <= after + lock_duration_s + 1);
        }
    }
}

test "auth/throttle: 表满淘汰最久未用的来源，内存有界" {
    // 64 个桶、每个约 90 字节。表满了必须淘汰，否则「大量来源轮番爆破」会把
    // 内存撑爆；同时淘汰顺序要稳定（LRU），不能随机丢掉正在锁定的桶。
    defer authThrottleReset();
    authThrottleReset();

    var buf: [peeraddr.max_len]u8 = undefined;
    var i: usize = 0;
    while (i < throttle_buckets) : (i += 1) {
        const key = try std.fmt.bufPrint(&buf, "10.0.{d}.1", .{i});
        _ = authThrottleAllow(key);
        authThrottleFailure(key);
    }
    // 第 65 个来源进来：所有桶的 `seen` 都在同一秒，LRU 取最早的那个（10.0.0.1）。
    _ = authThrottleAllow("10.0.99.1");
    authThrottleFailure("10.0.99.1");

    // 被淘汰的来源从 0 重新计数：还能再试满 5 次。
    i = 0;
    while (i < max_auth_retries) : (i += 1) {
        try testing.expect(authThrottleAllow("10.0.0.1"));
        authThrottleFailure("10.0.0.1");
    }
}