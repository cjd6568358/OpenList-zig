//! 迅雷云盘驱动 —— Go 版 `drivers/thunder` 的 Zig 移植。
//!
//! 上游一个 Go 包注册了**两个**驱动，本文件导出**三个** factory：
//!
//!   | Go `driver.Config.Name` | Zig factory      | 登录方式 |
//!   |-------------------------|------------------|----------|
//!   | `Thunder`               | `factory`        | 用户名 + 密码（参数全部硬编码，对齐 Go `Init`） |
//!   | `ThunderExpert`         | `expert_factory` | `login_type` = `user` / `refresh_token`，签名方式可选 |
//!   | —— 上游没有，本工程新增   | `web_factory`     | 手机号+密码走网页 OAuth；refresh_token 续期，失效自动重登 |
//!
//! 三者共用同一套协议逻辑（Go 里就是 `XunLeiCommon` 嵌入两个结构体），本文件
//! 用一个 `variant` 字段区分，避免两份几乎相同的代码漂移。
//!
//! ## 协议形态（drivers/thunder/util.go）
//!
//! 1. **两段式登录**：先 `POST /xluser.core.login/v3/login`（安卓 SDK 形态）
//!    拿 `sessionID`，再用它 `POST /v1/auth/signin/token` 换 OAuth token。
//!    换 token 前必须先刷 `captcha_token`（`POST /v1/shield/captcha/init`），
//!    否则 4122/4121/10/16。
//! 2. **签名**：`captcha_sign = "1." + md5(...md5(clientID+clientVersion+
//!    packageName+deviceID+timestamp + alg1) + alg2...)`，算法表见
//!    `default_algorithms`。`deviceID` 缺省时由账号派生（见 `computeDeviceId`）。
//! 3. **错误判据**：HTTP 状态码**完全不看**（Go 的 resty 也不看），只看
//!    body 里的 `{error_code, error, error_description}`。`error == "success"`
//!    视为成功；`error == "review_panel"` 表示要人工过验证码。
//! 4. **上传**：先按 GCID 申请上传，拿到 `UPLOAD_TYPE_RESUMABLE` 的
//!    `access_key_id/secret/bucket/endpoint/key/security_token` 后**自己走
//!    S3 分片**（Go 用 aws-sdk-go 的 s3manager）。分片大小、单片/分片阈值
//!    都与 SDK 默认值一致（5 MiB / 10000 片）。
//!
//! ## 与 Go 的差异（有意为之，均在此登记）
//!
//! * **路径 → ID**：Go 的 `model.Obj` 自带 `id`，本工程的 vtable 是路径式的，
//!   所以每个操作都要从 `root_folder_id` 逐级按名字翻页找 ID（同 pan123 /
//!   cloud189 的做法）。Go 走 `op.Get` 的对象缓存，没有这一步。
//! * **离线下载**（`OfflineDownload` / `OfflineList` / `DeleteOfflineTasks`）：
//!   Go 里也**没有任何驱动接口或路由调用它们**（`driver.Driver` 没有对应
//!   方法，`Other` 接口也没实现），是死代码。本工程不移植。
//! * **review_panel 提示**：Go 返回一段 HTML `<div>`；这里写纯文本到
//!   `ctx.err_detail`（前端弹窗按纯文本渲染，HTML 只会被转义显示成一堆标签）。
//! * **错误信息**：Go 用 `&ErrResp` 的 `Error()` 字符串；这里同样把
//!   `ErrorCode/Error/ErrorDescription` 拼成可读文本写进 `ctx.err_detail`。
//! * **静默成功**：上传接口返回非 `UPLOAD_TYPE_RESUMABLE` 时 Go 直接 `return
//!   nil`（文件其实没上传，但报告成功）。这里保持一致，只多打一条 warn 日志
//!   —— 改行为会让"上传成功但文件不存在"变成"上传失败"，与 Go 不一致。
//! * `GetDetails` 的 `limit`/`usage` 解析失败在 Go 里是硬错误，这里同样报错。
//! * **`device_id` 派生阈值**（2026-10-20 登记）：Go 是 `len(DeviceID) != 32`
//!   才派生（normal→md5(user+pass)，expert→md5(配置值本身)；等于 32 时原样用）；
//!   Zig 是「非空就原样用」。正常流程下两者等价（Go/Zig 首次都会把 32 位 hex
//!   落盘），**只有手填非 32 位值才分叉**。按现状保留，改判对齐 Go 会让
//!   用户已有但非 32 位的配置在下一次 init 时突然变一个不同的 ID。
//! * **`Link` 空直链**（2026-10-20 登记）：Go 拿到空 `web_content_link` 会把
//!   空串塞进 `Link.URL` 交给下游（然后在别处炸）；Zig 直接返回
//!   `InvalidResponse` 并写 `ctx.err_detail`。Zig 更严格，但确实是差异。
//! * **S3 分片上传的 `uploadId`/`ETag` 未转义**（2026-10-20 登记，提醒级）：
//!   `partNumber/uploadId` 原样进 URL 与 canonical query，ETag 原样嵌 XML。
//!   AWS 生态这两者通常 URL-safe/hex，且安卓版上传真机验过（6 MiB 分片）；
//!   但若哪天网页版分片上传报 403 / `InvalidRequest`，**这里第一嫌疑**。

const std = @import("std");
const driver = @import("../driver.zig");
const model = @import("../model.zig");
const json = @import("../util/json.zig");
const hash = @import("../util/hash.zig");
const httpclient = @import("../client.zig");
const cookiejar = @import("../cookiejar.zig");
const urlmod = @import("../util/url.zig");
const timeutil = @import("../util/time.zig");
const Buf = @import("../util/buf.zig").Buf;
const List = @import("../util/buf.zig").List;
const randommod = @import("../util/random.zig");
const log = @import("../log.zig");
const rt = @import("../rt.zig");

// ---------------------------------------------------------------------------
// 常量（drivers/thunder/util.go）
// ---------------------------------------------------------------------------

const api_url = "https://api-pan.xunlei.com/drive/v1";
const file_api_url = api_url ++ "/files";
/// Go 的离线下载端点（`OfflineList`/`DeleteOfflineTasks` 用它）。本工程不移植
/// 离线下载（Go 里也没有任何接口调用），常量保留以便对照上游。
const task_api_url = api_url ++ "/tasks";
const xluser_base = "https://xluser-ssl.xunlei.com";
const xluser_api = xluser_base ++ "/v1";

const ep_captcha_init = xluser_api ++ "/shield/captcha/init";
const ep_signin_token = xluser_api ++ "/auth/signin/token";
const ep_auth_token = xluser_api ++ "/auth/token";
const ep_user_me = xluser_api ++ "/user/me";
const ep_core_login = xluser_base ++ "/xluser.core.login/v3/login";
const ep_about = api_url ++ "/about";
// 网页版 OAuth 登录链路的两个端点（详见 webLogin 的注释）
const ep_signin = xluser_api ++ "/auth/signin";
const ep_user_authorize = xluser_api ++ "/user/authorize";

const kind_folder = "drive#folder";
const kind_file = "drive#file";

const upload_type_resumable = "UPLOAD_TYPE_RESUMABLE";

const sign_provider = "access_end_point_token";
const app_id = "40";
const app_key = "34a062aaa22f906fca4fefe9fb3a3021";

/// Go `Init` 里硬编码的 10 段签名算法（`drivers/thunder/driver.go:48-59`）。
const default_algorithms = [_][]const u8{
    "9uJNVj/wLmdwKrJaVj/omlQ",
    "Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf",
    "Eb+L7Ce+Ej48u",
    "jKY0",
    "ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd",
    "wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK",
    "gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O",
    "5IiCoM9B1/788ntB",
    "P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf",
    "+oK0AN",
};

/// Go `ExpertAddition` 的 `algorithms` 字段默认值（逗号分隔的同一张表）。
const default_algorithms_str = "9uJNVj/wLmdwKrJaVj/omlQ,Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf,Eb+L7Ce+Ej48u,jKY0,ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd,wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK,gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O,5IiCoM9B1/788ntB,P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf,+oK0AN";

const default_client_id = "Xp6vsxz_7IYVw2BB";
const default_client_secret = "Xp6vsy4tN9toTVdMSpomVdXpRmES";
const default_client_version = "8.31.0.9726";
const default_package_name = "com.xunlei.downloadprovider";
const default_user_agent = "ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC OSVersion/12 protocolVersion/301 platformVersion/10 sdkVersion/512000 Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)";
const default_download_user_agent = "Dalvik/2.1.0 (Linux; U; Android 12; M2004J7AC Build/SP1A.210812.016)";
/// `CoreLogin` 专用的 UA（Go `req.SetHeader("User-Agent", "android-ok-http-client/...")`）。
const core_login_ua = "android-ok-http-client/xl-acc-sdk/version-5.0.12.512000";
const captcha_redirect_uri = "xlaccsdk01://xunlei.com/callback?state=harbor";

// -- 网页版（pan.xunlei.com）--------------------------------------------------
// 逆向结论见 docs/THUNDER_WEB_RE_2026-10-20.md。这里的值与网页前端
// utils-initial 配置模块 32 的 `pan.xunlei.com` 条目逐字一致。
const web_client_id = "Xqp0kJBXWhwaTpB6";
/// 网页版 refresh grant 不需要 client_secret（实测空串即可）。
const web_client_secret = "";
const web_client_version = "1.93.12";
/// 注意：网页版的 `package_name` 同时充当签名 base 里的 `location.host`，
/// 两者都是 `pan.xunlei.com`，所以 `captchaSignAt` 不用改。
const web_package_name = "pan.xunlei.com";
const web_user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

// -- 网页版 OAuth 登录的固定参数（2026-10-20 抓包，见 RE 文档 §2.5）--
/// `i.xunlei.com` 账号中心（SSO）的 client_id。**不是** pan 的那个：
/// signin 必须用它，authorize 才用 `web_client_id`。
const web_sso_client_id = "XW5SkOhLDjnOZP7J";
const web_redirect_uri = "https://pan.xunlei.com/login?sso_sign_in_in_iframe=";
const web_sign_out_uri = "https://pan.xunlei.com/login?sso_sign_out=";
const web_scope = "profile offline pan sso user";

/// 网页版签名盐表：15 轮 `md5(prev + salt)`，顺序即调用顺序。
/// ⚠️ 前端重新打包就会变。失效时用 `tools/thunder_web_sign_harness.js` 重取
/// （步骤见 docs/THUNDER_WEB_RE_2026-10-20.md §4.3），改这里即可，单测会兜底。
const web_algorithms = [_][]const u8{
    "QT5gqd1eSINZe+K",
    "9TafMwqVWgh45hLntDm6HLcOXE",
    "L0nOen58D2cCsOSRaRRYt1Mj+XTVM",
    "gu4CPVQhQU",
    "X/6jue5AUYt56MbqopFv",
    "EuBhpIhdLUh37zvuzrOA3t8HL2HBtlCw",
    "3LSRoSaxM6YKIbhtx7RxaBpf",
    "OOnBZYkw3kRrfGD8",
    "ytWf",
    "psUOt",
    "+0izM",
    "tF53Ovo+aqLG00zho+b",
    "OnrcYC9y8",
    "cv2tHyrFOPhJUFkk6KhecIHJDUKK",
    "NnkQ2lQy",
};

const web_algorithms_str = "QT5gqd1eSINZe+K,9TafMwqVWgh45hLntDm6HLcOXE,L0nOen58D2cCsOSRaRRYt1Mj+XTVM,gu4CPVQhQU,X/6jue5AUYt56MbqopFv,EuBhpIhdLUh37zvuzrOA3t8HL2HBtlCw,3LSRoSaxM6YKIbhtx7RxaBpf,OOnBZYkw3kRrfGD8,ytWf,psUOt,+0izM,tF53Ovo+aqLG00zho+b,OnrcYC9y8,cv2tHyrFOPhJUFkk6KhecIHJDUKK,NnkQ2lQy";

/// 网页版 captcha token 实测 `expires_in = 300` 秒；提前 60 秒主动换新。
const web_captcha_ttl_ms: i64 = 300 * 1000;
const web_captcha_skew_ms: i64 = 60 * 1000;



// s3manager 默认值（Go 侧没有覆盖，只有超大文件时才调 PartSize）。
const default_part_size: i64 = 5 * 1024 * 1024;
const max_upload_parts: i64 = 10000;
const s3_region = "xunlei";
const s3_service = "s3";
const unsigned_payload = "UNSIGNED-PAYLOAD";

pub const Error = error{
    /// 用户名/密码/refresh_token 缺失，或上游明确拒绝。
    AuthFailed,
    /// Go `errs.EmptyToken`：还没登录就要发需要鉴权的请求。
    EmptyToken,
    UpstreamNotJson,
    /// 上游给了 `error_code` 且不在可重试集合里。
    UpstreamError,
    InvalidResponse,
    InvalidPath,
    /// 需要人工过验证码（Go 的 `review_panel` / `need verify: <a href=...>`）。
    NeedVerify,
    UploadFailed,
    /// 上传接口没给出完整的 S3 参数。
    BadUploadParams,
};

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

pub const Variant = enum {
    /// Go `Thunder`：参数全部硬编码。
    normal,
    /// Go `ThunderExpert`：全部参数可配。
    expert,
    /// 网页版 `pan.xunlei.com`：只走 refresh_token，签名用网页 15 盐链。
    /// 上游没有这个驱动（三个迅雷驱动全走安卓 core login），是本工程新增，
    /// 逆向记录见 `docs/THUNDER_WEB_RE_2026-10-20.md`。
    web,
};

/// 两个 Go 结构体的并集。`normal` 变体只读写前 7 个字段，其余字段固定为 Go
/// 硬编码的常量（`parse` 在 normal 模式下忽略这些键，`toJson` 也不写出它们，
/// 保证写回的 addition 与 Go 的 `Addition` 序列化形态一致）。
pub const Addition = struct {
    // -- 两个变体共有（Go `Addition` / `ExpertAddition` 的同名字段）--
    root_folder_id: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    captcha_token: []const u8 = "",
    credit_key: []const u8 = "",
    device_id: []const u8 = "",
    space: []const u8 = "",

    // -- 仅 expert --
    login_type: []const u8 = "user",
    sign_type: []const u8 = "algorithms",
    refresh_token: []const u8 = "",
    algorithms: []const u8 = default_algorithms_str,
    captcha_sign: []const u8 = "",
    timestamp: []const u8 = "",
    client_id: []const u8 = default_client_id,
    client_secret: []const u8 = default_client_secret,
    client_version: []const u8 = default_client_version,
    package_name: []const u8 = default_package_name,
    user_agent: []const u8 = default_user_agent,
    download_user_agent: []const u8 = default_download_user_agent,
    use_video_url: bool = false,

    pub fn parse(alloc: std.mem.Allocator, v: ?*const json.Value, variant: Variant) !Addition {
        var a = Addition{};
        // 默认值按变体分流：normal 不读这些键，web 与 expert 的差异只在
        // client_id / 版本 / 包名 / UA / 算法表 / 登录方式（见 docs §7.2）。
        const d = defaultsFor(variant);
        a.algorithms = d.algorithms;
        a.client_id = d.client_id;
        a.client_secret = d.client_secret;
        a.client_version = d.client_version;
        a.package_name = d.package_name;
        a.user_agent = d.user_agent;
        a.download_user_agent = d.download_user_agent;
        a.login_type = d.login_type;

        const o = v orelse return a;
        if (o.asObject() == null) return a;

        a.root_folder_id = try dupeOr(alloc, o.strAt("root_folder_id"), "");
        a.username = try dupeOr(alloc, o.strAt("username"), "");
        a.password = try dupeOr(alloc, o.strAt("password"), "");
        a.captcha_token = try dupeOr(alloc, o.strAt("captcha_token"), "");
        a.credit_key = try dupeOr(alloc, o.strAt("credit_key"), "");
        a.device_id = try dupeOr(alloc, o.strAt("device_id"), "");
        a.space = try dupeOr(alloc, o.strAt("space"), "");

        if (variant != .normal) {
            a.login_type = try dupeOr(alloc, o.strAt("login_type"), d.login_type);
            a.sign_type = try dupeOr(alloc, o.strAt("sign_type"), "algorithms");
            a.refresh_token = try dupeOr(alloc, o.strAt("refresh_token"), "");
            a.algorithms = try dupeOr(alloc, o.strAt("algorithms"), d.algorithms);
            a.captcha_sign = try dupeOr(alloc, o.strAt("captcha_sign"), "");
            a.timestamp = try dupeOr(alloc, o.strAt("timestamp"), "");
            a.client_id = try dupeOr(alloc, o.strAt("client_id"), d.client_id);
            a.client_secret = try dupeOr(alloc, o.strAt("client_secret"), d.client_secret);
            a.client_version = try dupeOr(alloc, o.strAt("client_version"), d.client_version);
            a.package_name = try dupeOr(alloc, o.strAt("package_name"), d.package_name);
            a.user_agent = try dupeOr(alloc, o.strAt("user_agent"), d.user_agent);
            a.download_user_agent = try dupeOr(alloc, o.strAt("download_user_agent"), d.download_user_agent);
            a.use_video_url = o.getPath("use_video_url") != null and
                (o.getPath("use_video_url").?.asBool() orelse false);
        }
        return a;
    }

    /// 序列化回 `addition`。键名 = Go 的 json tag，保证 Go 版能直接读。
    pub fn toJson(self: Addition, alloc: std.mem.Allocator, expert: bool) ![]u8 {
        var b = Buf.init(alloc);
        try b.append("{");
        if (expert) {
            try b.append("\"login_type\":");
            try json.writeString(&b, self.login_type);
            try b.append(",\"sign_type\":");
            try json.writeString(&b, self.sign_type);
        }
        if (expert) try b.append(",");
        try b.append("\"username\":");
        try json.writeString(&b, self.username);
        try b.append(",\"password\":");
        try json.writeString(&b, self.password);
        if (expert) {
            try b.append(",\"refresh_token\":");
            try json.writeString(&b, self.refresh_token);
            try b.append(",\"algorithms\":");
            try json.writeString(&b, self.algorithms);
            try b.append(",\"captcha_sign\":");
            try json.writeString(&b, self.captcha_sign);
            try b.append(",\"timestamp\":");
            try json.writeString(&b, self.timestamp);
        }
        try b.append(",\"captcha_token\":");
        try json.writeString(&b, self.captcha_token);
        try b.append(",\"credit_key\":");
        try json.writeString(&b, self.credit_key);
        try b.append(",\"device_id\":");
        try json.writeString(&b, self.device_id);
        if (expert) {
            try b.append(",\"client_id\":");
            try json.writeString(&b, self.client_id);
            try b.append(",\"client_secret\":");
            try json.writeString(&b, self.client_secret);
            try b.append(",\"client_version\":");
            try json.writeString(&b, self.client_version);
            try b.append(",\"package_name\":");
            try json.writeString(&b, self.package_name);
            try b.append(",\"user_agent\":");
            try json.writeString(&b, self.user_agent);
            try b.append(",\"download_user_agent\":");
            try json.writeString(&b, self.download_user_agent);
            try b.print(",\"use_video_url\":{s}", .{if (self.use_video_url) "true" else "false"});
        }
        try b.append(",\"space\":");
        try json.writeString(&b, self.space);
        try b.append(",\"root_folder_id\":");
        try json.writeString(&b, self.root_folder_id);
        try b.append("}");
        return b.toOwned();
    }
};

fn dupeOr(alloc: std.mem.Allocator, v: ?[]const u8, fallback: []const u8) ![]const u8 {
    return alloc.dupe(u8, v orelse fallback);
}

/// 各变体的 `addition` 默认值。抽出来是为了让 `parse` 只有一处「默认值来源」，
/// 加新变体时不会漏字段（web 与 expert 的差异全部集中在这张表）。
const Defaults = struct {
    login_type: []const u8,
    algorithms: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    client_version: []const u8,
    package_name: []const u8,
    user_agent: []const u8,
    download_user_agent: []const u8,
};

fn defaultsFor(variant: Variant) Defaults {
    return switch (variant) {
        .normal => .{
            .login_type = "user",
            .algorithms = default_algorithms_str,
            .client_id = default_client_id,
            .client_secret = default_client_secret,
            .client_version = default_client_version,
            .package_name = default_package_name,
            .user_agent = default_user_agent,
            .download_user_agent = default_download_user_agent,
        },
        .expert => .{
            .login_type = "user",
            .algorithms = default_algorithms_str,
            .client_id = default_client_id,
            .client_secret = default_client_secret,
            .client_version = default_client_version,
            .package_name = default_package_name,
            .user_agent = default_user_agent,
            .download_user_agent = default_download_user_agent,
        },
        .web => .{
            // 网页版没有账号密码体系 ⇒ 默认登录方式只能是 refresh_token。
            .login_type = "refresh_token",
            .algorithms = web_algorithms_str,
            .client_id = web_client_id,
            .client_secret = web_client_secret,
            .client_version = web_client_version,
            .package_name = web_package_name,
            .user_agent = web_user_agent,
            .download_user_agent = web_user_agent,
        },
    };
}

/// 32 位小写 hex，与网页前端 `deviceID` 的形态一致（16 随机字节 → hex）。
fn randomHex32(a: std.mem.Allocator) ![]const u8 {
    var raw: [16]u8 = undefined;
    rt.io().random(&raw);
    const hex = "0123456789abcdef";
    const out = try a.alloc(u8, 32);
    for (raw, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

/// 网页登录的账号规范化：`/v1/auth/signin` 要求手机号形如 `+86 138...`
/// （抓包实测，带空格）。邮箱/已带国家码的原样返回。
fn webUsername(a: std.mem.Allocator, u: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, u, " \t\r\n");
    if (t.len == 0) return a.dupe(u8, t);
    if (t[0] == '+') return a.dupe(u8, t);
    if (std.mem.indexOfScalar(u8, t, '@') != null) return a.dupe(u8, t);
    var all_digit = true;
    for (t) |c| {
        if (!std.ascii.isDigit(c)) {
            all_digit = false;
            break;
        }
    }
    if (all_digit and t.len == 11) return std.fmt.allocPrint(a, "+86 {s}", .{t});
    return a.dupe(u8, t);
}

/// base64url 无填充（RFC 7636 的 `code_challenge` 就是这个形态）。
fn base64UrlNoPad(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    const tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    const out = try a.alloc(u8, (data.len * 4 + 2) / 3);
    var i: usize = 0;
    var j: usize = 0;
    while (i + 3 <= data.len) : (i += 3) {
        const n = (@as(u32, data[i]) << 16) | (@as(u32, data[i + 1]) << 8) | data[i + 2];
        out[j] = tbl[(n >> 18) & 63];
        out[j + 1] = tbl[(n >> 12) & 63];
        out[j + 2] = tbl[(n >> 6) & 63];
        out[j + 3] = tbl[n & 63];
        j += 4;
    }
    const rest = data.len - i;
    if (rest == 1) {
        const n = @as(u32, data[i]) << 16;
        out[j] = tbl[(n >> 18) & 63];
        out[j + 1] = tbl[(n >> 12) & 63];
        j += 2;
    } else if (rest == 2) {
        const n = (@as(u32, data[i]) << 16) | (@as(u32, data[i + 1]) << 8);
        out[j] = tbl[(n >> 18) & 63];
        out[j + 1] = tbl[(n >> 12) & 63];
        out[j + 2] = tbl[(n >> 6) & 63];
        j += 3;
    }
    return out[0..j];
}

/// PKCE：`base64url(sha256(verifier))`，43 字符、无填充。
fn pkceChallenge(a: std.mem.Allocator, verifier: []const u8) ![]const u8 {
    const d = hash.sha256(verifier);
    return base64UrlNoPad(a, &d);
}

// ---------------------------------------------------------------------------
// 驱动
// ---------------------------------------------------------------------------

const Token = struct {
    token_type: []const u8,
    access_token: []const u8,
    refresh_token: []const u8,
    user_id: []const u8,
};

/// 上游错误信封（Go `ErrResp`）。注意 Go 只读 snake_case 的 `error_code`：
/// core login 的 camelCase `errorCode` 它读不到，只能靠 `error` 字段判定。
const ErrInfo = struct {
    code: i64 = 0,
    msg: []const u8 = "",
    desc: []const u8 = "",

    /// Go `ErrResp.IsError()`。
    fn isSet(self: ErrInfo) bool {
        if (std.mem.eql(u8, self.msg, "success")) return false;
        return self.code != 0 or self.msg.len != 0 or self.desc.len != 0;
    }
};

pub const Thunder = struct {
    alloc: std.mem.Allocator,
    storage_id: i64,
    variant: Variant,
    cfg: Addition,
    jar: *cookiejar.Jar,
    client: httpclient.Client,

    /// 串行化：token / captcha / credit_key 都是共享可变状态，而且 token 刷新
    /// 本身就要发请求。Go 那边靠 `sync.Mutex` 的等价物（`base.NewRestyClient`
    /// 每驱动一个 client + op 层锁），这里一把锁覆盖全部。
    req_mu: std.Io.Mutex = .init,

    /// 运行期 device id（`x-device-id` 头 + 签名输入）。持久化副本在 `cfg`。
    device_id: []const u8 = "",
    /// 签名算法表；空表示「用 `captcha_sign` 固定签名」（Go `Algorithms == nil`）。
    algorithms: []const []const u8 = &.{},
    /// 网页版 captcha token 的取得时刻（毫秒）。0 = 未知/需要重取。
    /// 网页 captcha token 实测只活 300 秒，靠这个字段主动换新，
    /// 而不是等业务接口报 `error_code == 9` 再补救。
    captcha_at_ms: i64 = 0,
    token: ?Token = null,
    /// Go `identity` 字段：登录特征，变了才重新登录。
    identity_cached: []const u8 = "",
    /// 上一次落盘的 addition 文本，避免重复写盘。
    last_saved: []const u8 = "",

    const VTable = driver.Driver.VTable{
        .name = drvName,
        .init = init,
        .deinit = deinit,
        .list = list,
        .details = details,
        .link = link,
        .makeDir = makeDir,
        .move = move,
        .rename = rename,
        .remove = remove,
        .put = put,
        .copy = copy,
        .space = space,
    };

    pub const vtable = VTable;

    fn drvName(ptr: *anyopaque) []const u8 {
        const self = as(ptr);
        return switch (self.variant) {
            .normal => "Thunder",
            .expert => "ThunderExpert",
            .web => "ThunderWeb",
        };
    }

    // -- 小工具 -------------------------------------------------------------

    fn setOwned(self: *Thunder, field: *[]const u8, v: []const u8) !void {
        const dup = try self.alloc.dupe(u8, v);
        if (field.*.len > 0) self.alloc.free(@constCast(field.*));
        field.* = dup;
    }

    fn freeToken(self: *Thunder) void {
        if (self.token) |t| {
            self.alloc.free(@constCast(t.token_type));
            self.alloc.free(@constCast(t.access_token));
            self.alloc.free(@constCast(t.refresh_token));
            self.alloc.free(@constCast(t.user_id));
            self.token = null;
        }
    }

    /// `algorithms` 是 `self.alloc` 拥有的 `[][]const u8`（init 会重算，reload
    /// 时必须先释放，否则每次重载漏一份）。
    fn freeAlgorithms(self: *Thunder) void {
        if (self.algorithms.len == 0) return;
        for (self.algorithms) |s| self.alloc.free(@constCast(s));
        self.alloc.free(@constCast(self.algorithms));
        self.algorithms = &.{};
    }

    /// 把 token 换掉（深拷贝到 `self.alloc`），并同步 refresh_token 到配置。
    fn setToken(self: *Thunder, t: Token) !void {
        self.freeToken();
        self.token = .{
            .token_type = try self.alloc.dupe(u8, t.token_type),
            .access_token = try self.alloc.dupe(u8, t.access_token),
            .refresh_token = try self.alloc.dupe(u8, t.refresh_token),
            .user_id = try self.alloc.dupe(u8, t.user_id),
        };
        // Go `ThunderExpert.SetTokenResp`：把轮换后的 refresh_token 写回配置。
        // 网页版同样必须落盘 —— 网页 refresh_token 是一次性的（轮换），
        // 不写回就等于「用一次就把自己锁在门外」。
        if (self.variant != .normal) try self.setOwned(&self.cfg.refresh_token, t.refresh_token);
    }

    fn additionJson(self: *Thunder, a: std.mem.Allocator) ![]u8 {
        return self.cfg.toJson(a, self.variant != .normal);
    }

    /// Go `op.MustSaveDriverStorage(x)`。失败只记日志（Go 那边是 Must*，会
    /// panic；本工程不因为写盘失败把整个存储打挂）。
    fn persist(self: *Thunder, a: std.mem.Allocator) void {
        const text = self.additionJson(a) catch return;
        if (std.mem.eql(u8, text, self.last_saved)) return;
        driver.persist(self.storage_id, text);
        if (self.last_saved.len > 0) self.alloc.free(@constCast(self.last_saved));
        self.last_saved = self.alloc.dupe(u8, text) catch "";
    }

    // -- 签名 / 设备 --------------------------------------------------------

    /// Go `Init` 里 device id 的取值链，各变体的派生输入**不同**：
    ///   * normal：`md5(username + password)`
    ///   * expert：`md5("")`（Go 对 `DeviceID` 本身做 md5，未配置时就是空串）
    ///   * web：随机 32 位 hex（网页版没有「由账号派生」这回事，前端就是
    ///     `crypto` 随机生成后存 localStorage；这里生成后落盘，保持稳定）
    /// 配置里给了非空 `device_id` 时一律直接用配置值。
    fn computeDeviceId(self: *Thunder, a: std.mem.Allocator) ![]const u8 {
        if (self.cfg.device_id.len != 0) return a.dupe(u8, self.cfg.device_id);
        switch (self.variant) {
            .web => return randomHex32(a),
            .expert => return hash.md5Hex(a, self.cfg.device_id),
            .normal => {},
        }
        const joined = try std.fmt.allocPrint(a, "{s}{s}", .{ self.cfg.username, self.cfg.password });
        return hash.md5Hex(a, joined);
    }

    /// Go `GetIdentity()`：变了才重新登录。normal 变体只有 md5(用户名+密码)。
    fn identity(self: *Thunder, a: std.mem.Allocator) ![]const u8 {
        if (self.variant == .normal) {
            const joined = try std.fmt.allocPrint(a, "{s}{s}", .{ self.cfg.username, self.cfg.password });
            return hash.md5Hex(a, joined);
        }
        var b = Buf.init(a);
        if (std.mem.eql(u8, self.cfg.login_type, "refresh_token")) {
            try b.append(self.cfg.refresh_token);
        } else {
            try b.append(self.cfg.username);
            try b.append(self.cfg.password);
        }
        if (std.mem.eql(u8, self.cfg.sign_type, "captcha_sign")) {
            try b.append(self.cfg.captcha_sign);
            try b.append(self.cfg.timestamp);
        } else {
            try b.append(self.cfg.algorithms);
        }
        try b.append(self.cfg.device_id);
        try b.append(self.cfg.client_id);
        try b.append(self.cfg.client_secret);
        try b.append(self.cfg.client_version);
        try b.append(self.cfg.package_name);
        return hash.md5Hex(a, b.slice());
    }

    /// Go `GetCaptchaSign()`。纯函数版本见 `captchaSignAt`（可单测）。
    fn captchaSign(self: *Thunder, a: std.mem.Allocator) !struct { timestamp: []const u8, sign: []const u8 } {
        if (self.algorithms.len == 0) {
            return .{ .timestamp = self.cfg.timestamp, .sign = self.cfg.captcha_sign };
        }
        const ts = try std.fmt.allocPrint(a, "{d}", .{rt.nowMillis()});
        const sign = try captchaSignAt(a, self.cfg.client_id, self.cfg.client_version, self.cfg.package_name, self.device_id, ts, self.algorithms);
        return .{ .timestamp = ts, .sign = sign };
    }

    // -- HTTP ---------------------------------------------------------------

    /// 无鉴权头的基础请求（Go `Common.Request`）。返回原始 body + 错误信封，
    /// **不**在这里把上游错误变成 Zig error —— 调用方（`requestLocked`）要
    /// 看 `error_code` 决定是否刷新 token 重试。
    fn sendOnce(
        self: *Thunder,
        a: std.mem.Allocator,
        method: []const u8,
        url: []const u8,
        body: ?[]const u8,
        auth: bool,
        ua: ?[]const u8,
    ) !struct { body: []const u8, err: ErrInfo } {
        var hl = List(model.Header).init(a);
        try hl.append(.{ .name = "user-agent", .value = ua orelse self.cfg.user_agent });
        try hl.append(.{ .name = "accept", .value = "application/json;charset=UTF-8" });
        try hl.append(.{ .name = "x-device-id", .value = self.device_id });
        try hl.append(.{ .name = "x-client-id", .value = self.cfg.client_id });
        try hl.append(.{ .name = "x-client-version", .value = self.cfg.client_version });
        if (auth) {
            const t = self.token orelse return Error.EmptyToken;
            const authz = try std.fmt.allocPrint(a, "{s} {s}", .{ t.token_type, t.access_token });
            try hl.append(.{ .name = "Authorization", .value = authz });
            try hl.append(.{ .name = "X-Captcha-Token", .value = self.cfg.captcha_token });
        }

        const res = try self.client.send(a, .{
            .method = method,
            .url = url,
            .headers = hl.slice(),
            .body = body orelse "",
            .use_cookies = false,
        });
        return .{ .body = res.body, .err = parseErrInfo(a, res.body) };
    }

    /// 带鉴权 + 自动重试的请求（Go `XunLeiCommon.Request`）。返回响应 body。
    ///
    /// 重试规则与 Go 的 switch 逐条对齐：
    ///   * `error_code == 0` → **当成功**（Go 的 `case 0: return data, nil`，
    ///     即便 body 里带了 `error` 文本 —— 这是上游行为，不是笔误）；
    ///   * `4122/4121/10/16` → 刷 token 后重试；
    ///   * `9` → 刷 captcha_token 后重试；
    ///   * 其余 → 失败。
    fn requestLocked(
        self: *Thunder,
        a: std.mem.Allocator,
        method: []const u8,
        url: []const u8,
        body: ?[]const u8,
        ed: ?*?[]const u8,
        depth: u8,
    ) anyerror![]const u8 {
        if (self.token == null) return Error.EmptyToken;
        // 网页版：captcha token 只活 300 秒，发请求前先确保它新鲜。
        // 安卓变体不这么做（它的 token 由风控流程管理，主动刷反而会触发限频）。
        if (self.variant == .web) try self.ensureWebCaptcha(a, method, url, ed);
        const r = try self.sendOnce(a, method, url, body, true, null);
        if (!r.err.isSet()) return r.body;

        if (std.mem.eql(u8, r.err.msg, "review_panel")) {
            try self.reviewDetail(a, r.body, ed);
            return Error.NeedVerify;
        }
        // 防御：Go 是无界递归（刷新成功但上游仍报错时就会一直重试），这里限深。
        if (depth >= 3) {
            setErr(ed, try errText(a, r.err));
            return Error.UpstreamError;
        }
        switch (r.err.code) {
            0 => return r.body,
            4122, 4121, 10, 16 => try self.refreshFlow(a, ed),
            9 => {
                const t = self.token orelse return Error.EmptyToken;
                const action = try getAction(a, method, url);
                try self.refreshCaptchaTokenAtLogin(a, action, t.user_id, ed);
            },
            else => {
                setErr(ed, try errText(a, r.err));
                return Error.UpstreamError;
            },
        }
        return self.requestLocked(a, method, url, body, ed, depth + 1);
    }

    /// Go `refreshTokenFunc`（三个变体分支的合集）。
    fn refreshFlow(self: *Thunder, a: std.mem.Allocator, ed: ?*?[]const u8) !void {
        // 网页版：refresh 失败不能就地放弃 —— 直接重走手机号密码登录，
        // 用户完全无感（这正是「只录一次」的兜底）。
        //
        // ⚠️ web 走的是自己的分支，**不会走到下面的 expert 逻辑** —— 别在
        //    下面再加 `self.variant == .web` 判断，那是死条件（2026-10-20 审计
        //    发现过一次），也别在这里写「网页版没有回退」：回退就在这个分支里。
        if (self.variant == .web) {
            const tok = try self.webLoginOrRefresh(a, ed);
            try self.setToken(tok);
            self.persist(a);
            return;
        }
        const cur = self.token orelse return Error.EmptyToken;
        // 只有 expert + refresh_token 这一种「刷新失败就不再降级」的情形：
        // 其他组合（normal / expert-user）都没有能在设备上跑通的自愈路径
        // —— normal 的 core login 会被数美风控拦，正是 ThunderWeb 要绕开的东西。
        const only_refresh = self.variant == .expert and
            std.mem.eql(u8, self.cfg.login_type, "refresh_token");

        if (self.refreshTokenCall(a, cur.refresh_token, ed)) |tok| {
            try self.setToken(tok);
            if (self.variant != .normal) self.persist(a);
        } else |e| {
            log.warn("[thunder] refresh_token failed: {s}", .{@errorName(e)});
            if (only_refresh) return e;
            // Go：刷新失败就用用户名密码重新登录，并清空信任密钥。
            const tok = try self.login(a, self.cfg.username, self.cfg.password, ed);
            // 不清 credit_key（理由同 initNormal）
            try self.setToken(tok);
            if (self.variant != .normal) self.persist(a);
        }
    }

    /// Go `RefreshToken(refreshToken)`。
    fn refreshTokenCall(self: *Thunder, a: std.mem.Allocator, refresh_token: []const u8, ed: ?*?[]const u8) !Token {
        var b = Buf.init(a);
        try b.append("{\"grant_type\":\"refresh_token\",\"refresh_token\":");
        try json.writeString(&b, refresh_token);
        try b.append(",\"client_id\":");
        try json.writeString(&b, self.cfg.client_id);
        try b.append(",\"client_secret\":");
        try json.writeString(&b, self.cfg.client_secret);
        try b.append("}");

        const r = try self.sendOnce(a, "POST", ep_auth_token, b.slice(), false, null);
        if (r.err.isSet()) {
            setErr(ed, try errText(a, r.err));
            return Error.AuthFailed;
        }
        const v = try a.create(json.Value);
        v.* = json.parse(a, r.body) catch return Error.UpstreamNotJson;
        const tok = try tokenFromJson(v);
        // Go `errs.EmptyToken`：refresh_token 空说明上游没给新令牌。
        if (tok.refresh_token.len == 0) return Error.EmptyToken;
        return tok;
    }

    // -- 网页版登录（pan.xunlei.com OAuth）----------------------------------

    /// 网页版取令牌：有 refresh_token 就先 refresh，失败再走手机号密码登录。
    /// **这就是「只录一次手机号密码」的实现点** —— 只要配置里有账号密码，
    /// 令牌链断在哪一环都能自愈。
    fn webLoginOrRefresh(self: *Thunder, a: std.mem.Allocator, ed: ?*?[]const u8) !Token {
        var refresh_fail: ?[]const u8 = null;
        if (self.cfg.refresh_token.len != 0) {
            if (self.refreshTokenCall(a, self.cfg.refresh_token, ed)) |tok| {
                return tok;
            } else |e| {
                // 记下真因：下面 webLogin 失败时会把它一并写进 err_detail，
                // 否则「网络挂了」会被改写成「缺账号密码」，排障时完全被带偏
                // （2026-10-20 审计提出）。
                refresh_fail = @errorName(e);
                log.warn("[thunder] web refresh_token 失效（{s}），改用手机号密码重新登录", .{@errorName(e)});
            }
        }
        return self.webLogin(a, ed) catch |e| {
            if (refresh_fail) |rf| {
                const prev = if (ed) |p| (p.* orelse "") else "";
                const msg = if (prev.len > 0)
                    std.fmt.allocPrint(a, "refresh_token 失败（{s}）；账号密码登录也失败：{s}", .{ rf, prev }) catch
                    return e
                else
                    std.fmt.allocPrint(a, "refresh_token 失败（{s}）；账号密码登录也不可用（没配 username/password）", .{rf}) catch
                    return e;
                setErr(ed, msg);
            }
            return e;
        };
    }

    /// 网页版「手机号 + 密码」登录，产出 pan 令牌（含 refresh_token）。
    ///
    /// 逆向记录见 `docs/THUNDER_WEB_RE_2026-10-20.md` §2.5。四步纯 HTTP，
    /// **无短信、无滑块、不需要 captcha_sign**（这个 action 的 captcha init
    /// 只认手机号，不校验签名 —— 这是网页登录能程序化的根本原因）：
    ///
    ///   1. `POST /v1/shield/captcha/init`  SSO client，action=POST:/v1/auth/signin
    ///   2. `POST /v1/auth/signin`          带 X-Captcha-Token ⇒ SSO access_token
    ///   3. `POST /v1/user/authorize`       Bearer SSO，PKCE S256 ⇒ code（120 秒有效）
    ///   4. `POST /v1/auth/token`           authorization_code + code_verifier ⇒ pan 令牌
    ///
    /// 有了它，`ThunderWeb` 就和安卓两个变体一样「只录一次手机号密码」：
    /// 首次登录拿 refresh_token 并落盘，之后靠 refresh 续期；refresh 一旦失效
    /// 就静默重走本函数，用户无感。
    fn webLogin(self: *Thunder, a: std.mem.Allocator, ed: ?*?[]const u8) !Token {
        const user = try webUsername(a, self.cfg.username);
        if (user.len == 0 or self.cfg.password.len == 0) {
            setErr(ed, "网页版登录需要 username + password（也可以直接填 refresh_token）");
            return Error.AuthFailed;
        }

        // ---- 1. SSO captcha init（不校验 captcha_sign）----
        var b1 = Buf.init(a);
        try b1.append("{\"client_id\":");
        try json.writeString(&b1, web_sso_client_id);
        try b1.append(",\"action\":\"POST:/v1/auth/signin\",\"device_id\":");
        try json.writeString(&b1, self.device_id);
        try b1.append(",\"meta\":{\"phone_number\":");
        try json.writeString(&b1, user);
        try b1.append("}}");
        const r1 = try self.webPost(a, ep_captcha_init, b1.slice(), null, null);
        var captcha_token: []const u8 = "";
        if (r1.status < 300 and r1.body.len > 0) {
            const v1 = try a.create(json.Value);
            v1.* = json.parse(a, r1.body) catch .null;
            captcha_token = v1.strAt("captcha_token") orelse "";
        }

        // ---- 2. signin ⇒ SSO access_token ----
        var b2 = Buf.init(a);
        try b2.append("{\"username\":");
        try json.writeString(&b2, user);
        try b2.append(",\"password\":");
        try json.writeString(&b2, self.cfg.password);
        try b2.append(",\"client_id\":");
        try json.writeString(&b2, web_sso_client_id);
        try b2.append("}");
        const r2 = try self.webPost(a, ep_signin, b2.slice(), null, captcha_token);
        if (r2.status >= 300) {
            const msg = try std.fmt.allocPrint(a, "web signin HTTP {d}: {s}", .{ r2.status, r2.body[0..@min(r2.body.len, 300)] });
            setErr(ed, msg);
            return Error.AuthFailed;
        }
        const v2 = try a.create(json.Value);
        v2.* = json.parse(a, r2.body) catch return Error.UpstreamNotJson;
        const sso_at = v2.strAt("access_token") orelse "";
        if (sso_at.len == 0) {
            setErr(ed, r2.body[0..@min(r2.body.len, 300)]);
            return Error.AuthFailed;
        }

        // ---- 3. authorize（PKCE S256）⇒ code ----
        var verifier_buf: [32]u8 = undefined;
        const verifier = randommod.randomString(&verifier_buf);
        const challenge = try pkceChallenge(a, verifier);
        const state = try std.fmt.allocPrint(a, "state-{s}", .{verifier[0..12]});
        var b3 = Buf.init(a);
        try b3.append("{\"client_id\":");
        try json.writeString(&b3, self.cfg.client_id);
        try b3.append(",\"response_type\":\"code\",\"redirect_uri\":");
        try json.writeString(&b3, web_redirect_uri);
        try b3.append(",\"state\":");
        try json.writeString(&b3, state);
        try b3.append(",\"scope\":");
        try json.writeString(&b3, web_scope);
        try b3.append(",\"code_challenge\":");
        try json.writeString(&b3, challenge);
        try b3.append(",\"code_challenge_method\":\"S256\",\"sign_out_uri\":");
        try json.writeString(&b3, web_sign_out_uri);
        try b3.append("}");
        const r3 = try self.webPost(a, ep_user_authorize, b3.slice(), sso_at, null);
        if (r3.status >= 300) {
            const msg = try std.fmt.allocPrint(a, "web authorize HTTP {d}: {s}", .{ r3.status, r3.body[0..@min(r3.body.len, 300)] });
            setErr(ed, msg);
            return Error.AuthFailed;
        }
        const v3 = try a.create(json.Value);
        v3.* = json.parse(a, r3.body) catch return Error.UpstreamNotJson;
        const code = v3.strAt("code") orelse "";
        if (code.len == 0) {
            setErr(ed, r3.body[0..@min(r3.body.len, 300)]);
            return Error.AuthFailed;
        }

        // ---- 4. authorization_code ⇒ pan 令牌 ----
        var b4 = Buf.init(a);
        try b4.append("{\"code\":");
        try json.writeString(&b4, code);
        try b4.append(",\"grant_type\":\"authorization_code\",\"code_verifier\":");
        try json.writeString(&b4, verifier);
        try b4.append(",\"redirect_uri\":");
        try json.writeString(&b4, web_redirect_uri);
        try b4.append(",\"client_id\":");
        try json.writeString(&b4, self.cfg.client_id);
        try b4.append("}");
        const r4 = try self.webPost(a, ep_auth_token, b4.slice(), null, null);
        if (r4.status >= 300) {
            const msg = try std.fmt.allocPrint(a, "web token HTTP {d}: {s}", .{ r4.status, r4.body[0..@min(r4.body.len, 300)] });
            setErr(ed, msg);
            return Error.AuthFailed;
        }
        const v4 = try a.create(json.Value);
        v4.* = json.parse(a, r4.body) catch return Error.UpstreamNotJson;
        const tok = try tokenFromJson(v4);
        if (tok.refresh_token.len == 0) {
            setErr(ed, "web login 没返回 refresh_token");
            return Error.EmptyToken;
        }
        log.info("[thunder] web login ok (user_id={s})", .{tok.user_id});
        return tok;
    }

    /// 网页版专用 POST：自己拼头（要带 Bearer / X-Captcha-Token，且**不能**像
    /// 业务请求那样无条件塞 x-client-id，否则 SSO 端点会拿到错的 client）。
    fn webPost(
        self: *Thunder,
        a: std.mem.Allocator,
        url: []const u8,
        body: []const u8,
        bearer: ?[]const u8,
        captcha_token: ?[]const u8,
    ) !struct { status: u16, body: []const u8 } {
        var hl = List(model.Header).init(a);
        try hl.append(.{ .name = "user-agent", .value = self.cfg.user_agent });
        try hl.append(.{ .name = "accept", .value = "application/json" });
        try hl.append(.{ .name = "content-type", .value = "application/json" });
        try hl.append(.{ .name = "origin", .value = "https://pan.xunlei.com" });
        try hl.append(.{ .name = "referer", .value = "https://pan.xunlei.com/" });
        try hl.append(.{ .name = "x-device-id", .value = self.device_id });
        if (bearer) |t| {
            const v = try std.fmt.allocPrint(a, "Bearer {s}", .{t});
            try hl.append(.{ .name = "Authorization", .value = v });
        }
        if (captcha_token) |t| {
            if (t.len > 0) try hl.append(.{ .name = "X-Captcha-Token", .value = t });
        }
        const res = try self.client.send(a, .{
            .method = "POST",
            .url = url,
            .headers = hl.slice(),
            .body = body,
            .use_cookies = false,
        });
        return .{ .status = res.status, .body = res.body };
    }

    /// Go `Login(username, password)`：core login 拿 sessionID → 刷 captcha →
    /// signin/token 换令牌。
    fn login(self: *Thunder, a: std.mem.Allocator, username: []const u8, password: []const u8, ed: ?*?[]const u8) !Token {
        if (username.len == 0 or password.len == 0) return Error.AuthFailed;
        const session_id = try self.coreLogin(a, username, password, ed);

        const action = try getAction(a, "POST", ep_signin_token);
        try self.refreshCaptchaTokenInLogin(a, action, username, ed);

        var b = Buf.init(a);
        try b.append("{\"client_id\":");
        try json.writeString(&b, self.cfg.client_id);
        try b.append(",\"client_secret\":");
        try json.writeString(&b, self.cfg.client_secret);
        try b.append(",\"provider\":");
        try json.writeString(&b, sign_provider);
        try b.append(",\"signin_token\":");
        try json.writeString(&b, session_id);
        try b.append("}");

        const r = try self.sendOnce(a, "POST", ep_signin_token, b.slice(), false, null);
        if (r.err.isSet()) {
            setErr(ed, try errText(a, r.err));
            return Error.AuthFailed;
        }
        const v = try a.create(json.Value);
        v.* = json.parse(a, r.body) catch return Error.UpstreamNotJson;
        const tok = try tokenFromJson(v);
        // Go 这里不校验，但空 access_token 的存储必然全部请求失败 —— 直接报错，
        // 让 admin 界面显示"登录失败"而不是一连串 401。
        if (tok.access_token.len == 0) return Error.AuthFailed;
        return tok;
    }

    /// Go `CoreLogin`：`POST /xluser.core.login/v3/login`。
    fn coreLogin(self: *Thunder, a: std.mem.Allocator, username: []const u8, password: []const u8, ed: ?*?[]const u8) ![]const u8 {
        const devicesign = try generateDeviceSign(a, self.device_id, self.cfg.package_name);
        var b = Buf.init(a);
        try b.append("{\"protocolVersion\":\"301\",\"sequenceNo\":\"1000012\",\"platformVersion\":\"10\"");
        try b.append(",\"isCompressed\":\"0\",\"appid\":\"");
        try b.append(app_id);
        try b.append("\",\"clientVersion\":\"8.31.0.9726\"");
        try b.append(",\"peerID\":\"00000000000000000000000000000000\"");
        try b.append(",\"appName\":\"ANDROID-com.xunlei.downloadprovider\"");
        try b.append(",\"sdkVersion\":\"512000\",\"devicesign\":");
        try json.writeString(&b, devicesign);
        try b.append(",\"netWorkType\":\"WIFI\",\"providerName\":\"NONE\"");
        try b.append(",\"deviceModel\":\"M2004J7AC\",\"deviceName\":\"Xiaomi_M2004j7ac\"");
        try b.append(",\"OSVersion\":\"12\",\"creditkey\":");
        try json.writeString(&b, self.cfg.credit_key);
        try b.append(",\"hl\":\"zh-CN\",\"userName\":");
        try json.writeString(&b, username);
        try b.append(",\"passWord\":");
        try json.writeString(&b, password);
        try b.append(",\"verifyKey\":\"\",\"verifyCode\":\"\",\"isMd5Pwd\":\"0\"}");

        const r = try self.sendOnce(a, "POST", ep_core_login, b.slice(), false, core_login_ua);
        if (r.err.isSet()) {
            if (std.mem.eql(u8, r.err.msg, "review_panel")) {
                try self.reviewDetail(a, r.body, ed);
                return Error.NeedVerify;
            }
            setErr(ed, try errText(a, r.err));
            return Error.AuthFailed;
        }
        const v = try a.create(json.Value);
        v.* = json.parse(a, r.body) catch return Error.UpstreamNotJson;
        const sid = v.strAt("sessionID") orelse return Error.InvalidResponse;
        if (sid.len == 0) return Error.InvalidResponse;
        return a.dupe(u8, sid);
    }

    /// Go `RefreshCaptchaTokenAtLogin`（登录后：meta 带 timestamp/captcha_sign）。
    fn refreshCaptchaTokenAtLogin(self: *Thunder, a: std.mem.Allocator, action: []const u8, user_id: []const u8, ed: ?*?[]const u8) !void {
        const cs = try self.captchaSign(a);
        const metas = [_][2][]const u8{
            .{ "client_version", self.cfg.client_version },
            .{ "package_name", self.cfg.package_name },
            .{ "user_id", user_id },
            .{ "timestamp", cs.timestamp },
            .{ "captcha_sign", cs.sign },
        };
        try self.refreshCaptchaToken(a, action, &metas, ed);
    }

    /// Go `RefreshCaptchaTokenInLogin`（登录时：meta 是账号标识）。
    fn refreshCaptchaTokenInLogin(self: *Thunder, a: std.mem.Allocator, action: []const u8, username: []const u8, ed: ?*?[]const u8) !void {
        var metas: [1][2][]const u8 = undefined;
        if (looksLikeEmail(username)) {
            metas[0] = .{ "email", username };
        } else if (username.len >= 11 and username.len <= 18) {
            metas[0] = .{ "phone_number", username };
        } else {
            metas[0] = .{ "username", username };
        }
        try self.refreshCaptchaToken(a, action, &metas, ed);
    }

    /// 网页版：captcha token 只活 300 秒（实测 `expires_in:300`），所以每次
    /// 业务请求前检查一次，临期就主动换新，而不是等 `error_code == 9` 兜底
    /// （那会浪费一次往返 + 一次重试）。
    fn ensureWebCaptcha(self: *Thunder, a: std.mem.Allocator, method: []const u8, url: []const u8, ed: ?*?[]const u8) !void {
        const now = rt.nowMillis();
        if (self.cfg.captcha_token.len != 0 and self.captcha_at_ms != 0 and
            now - self.captcha_at_ms < web_captcha_ttl_ms - web_captcha_skew_ms) return;
        const t = self.token orelse return Error.EmptyToken;
        const action = try getAction(a, method, url);
        try self.refreshCaptchaTokenAtLogin(a, action, t.user_id, ed);
    }

    /// Go `refreshCaptchaToken(action, metas)`。
    ///
    /// 网页版与安卓版的请求体**不同**（对齐浏览器实际抓包）：
    ///   * 不带 `captcha_token`（安卓版是「拿旧 token 续期」）；
    ///   * 不带 `redirect_uri`（那是安卓 SDK 的 `xlaccsdk01://` 回调）；
    ///   * meta 里带上空的 username/phone_number/email（前端就是这么发的）。
    fn refreshCaptchaToken(self: *Thunder, a: std.mem.Allocator, action: []const u8, metas: []const [2][]const u8, ed: ?*?[]const u8) !void {
        var b = Buf.init(a);
        try b.append("{\"action\":");
        try json.writeString(&b, action);
        if (self.variant != .web) {
            try b.append(",\"captcha_token\":");
            try json.writeString(&b, self.cfg.captcha_token);
        }
        try b.append(",\"client_id\":");
        try json.writeString(&b, self.cfg.client_id);
        try b.append(",\"device_id\":");
        try json.writeString(&b, self.device_id);
        try b.append(",\"meta\":{");
        if (self.variant == .web) {
            try b.append("\"username\":\"\",\"phone_number\":\"\",\"email\":\"\",");
        }
        for (metas, 0..) |kv, i| {
            if (i > 0) try b.append(",");
            try json.writeString(&b, kv[0]);
            try b.append(":");
            try json.writeString(&b, kv[1]);
        }
        try b.append("}");
        if (self.variant != .web) {
            try b.append(",\"redirect_uri\":");
            try json.writeString(&b, captcha_redirect_uri);
        }
        try b.append("}");

        const r = try self.sendOnce(a, "POST", ep_captcha_init, b.slice(), false, null);
        if (r.err.isSet()) {
            // 网页版最常见的失败是盐表过期（前端重新打包）。给一句能直接查的指引。
            if (self.variant == .web and std.mem.indexOf(u8, r.body, "captcha_sign") != null) {
                const msg = try std.fmt.allocPrint(
                    a,
                    "captcha_sign rejected — xunlei likely rebuilt its frontend and the web salt table is stale; see docs/THUNDER_WEB_RE_2026-10-20.md §4.3. upstream: {s}",
                    .{r.body[0..@min(r.body.len, 300)]},
                );
                setErr(ed, msg);
                return Error.UpstreamError;
            }
            setErr(ed, try errText(a, r.err));
            return Error.UpstreamError;
        }
        const v = try a.create(json.Value);
        v.* = json.parse(a, r.body) catch return Error.UpstreamNotJson;
        // Go：给了 url 就是"要人去过验证码"。
        if (v.strAt("url")) |u| {
            if (u.len > 0) {
                const msg = try std.fmt.allocPrint(a, "need verify: {s}", .{u});
                setErr(ed, msg);
                return Error.NeedVerify;
            }
        }
        const token = v.strAt("captcha_token") orelse "";
        if (token.len == 0) {
            setErr(ed, "empty captchaToken");
            return Error.InvalidResponse;
        }
        try self.setOwned(&self.cfg.captcha_token, token);
        self.captcha_at_ms = rt.nowMillis();
        self.persist(a);
    }

    /// Go `IsLogin()`：GET /user/me 只要不报错就算登录态。
    fn isLoginLocked(self: *Thunder, a: std.mem.Allocator) bool {
        if (self.token == null) return false;
        _ = self.requestLocked(a, "GET", ep_user_me, null, null, 0) catch return false;
        return true;
    }

    /// Go `getReviewData`：把人工验证所需数据写进 err_detail。
    ///
    /// ⚠️ 这里必须输出**带大括号的 JSON**，不能只写一段人话：官方文档的
    /// credit_key 获取流程是「复制报错界面上的全部内容（含大括号）→ 打开
    /// i.xunlei.com/xlcaptcha/android.html → 控制台执行 `reviewCb({...})`
    /// → 短信验证 → 拿到 creditkey 填回存储」。纯文本会让这一步直接做不了。
    /// 外壳 HTML 与 Go 的 `fmt.Errorf` 一致（前端是同一套 CDN bundle，按
    /// HTML 渲染，样式因此与 Go 版一模一样）。
    fn reviewDetail(self: *Thunder, a: std.mem.Allocator, body: []const u8, ed: ?*?[]const u8) !void {
        const v = try a.create(json.Value);
        v.* = json.parse(a, body) catch return;
        const device_sign = try generateDeviceSign(a, self.device_id, self.cfg.package_name);
        const review_url = v.strAt("reviewurl") orelse "";
        // Go：`reviewResp.Reviewurl + "&deviceid=" + deviceSign`
        const full_url = try std.fmt.allocPrint(a, "{s}&deviceid={s}", .{ review_url, device_sign });

        // Go `json.MarshalIndent(reviewData, "", "  ")`：字段顺序 creditkey /
        // reviewurl / deviceid / devicesign，两空格缩进。
        var j = Buf.init(a);
        try j.append("{\n  \"creditkey\": ");
        try json.writeString(&j, v.strAt("creditkey") orelse "");
        try j.append(",\n  \"reviewurl\": ");
        try json.writeString(&j, full_url);
        try j.append(",\n  \"deviceid\": ");
        try json.writeString(&j, device_sign);
        try j.append(",\n  \"devicesign\": ");
        try json.writeString(&j, device_sign);
        try j.append("\n}");

        // ⚠ 前端把 error_msg 当**纯文本**渲染（不解析 HTML），所以这里绝不能包
        // HTML 外壳——否则用户看到的就是"全是代码"。信息一个不少：JSON 仍完整
        // 内嵌，指导语换成三行中文，照着做即可。（Go 那边是 HTML，前端同样不渲染。）
        const msg = try std.fmt.allocPrint(a,
            "本次登录需要验证（新设备 / 风控）。\n" ++
            "把下面这段 JSON（含大括号）复制到 https://i.xunlei.com/xlcaptcha/android.html ，\n" ++
            "按 F12 打开控制台执行 reviewCb(<粘贴>) ；完成后把得到的 creditkey 填到本存储的\n" ++
            "「信用密钥」再保存即可。\n{s}", .{j.slice()});
        setErr(ed, msg);
    }

    // -- 文件 ---------------------------------------------------------------

    /// 列一页（Go `getFiles` 的单页部分）。
    fn listPageLocked(self: *Thunder, a: std.mem.Allocator, parent_id: []const u8, page_token: []const u8, ed: ?*?[]const u8) !*const json.Value {
        var q = Buf.init(a);
        try q.print("space={s}&__type=drive&refresh=true&__sync=true&parent_id={s}&page_token={s}&with_audit=true&limit=100&filters={s}", .{
            try urlmod.encode(a, self.cfg.space, .form),
            try urlmod.encode(a, parent_id, .form),
            try urlmod.encode(a, page_token, .form),
            try urlmod.encode(a, "{\"phase\":{\"eq\":\"PHASE_TYPE_COMPLETE\"},\"trashed\":{\"eq\":false}}", .form),
        });
        // 挂在"远程设备"（space 非空）时，Go 额外要这几个 with 参数。
        if (self.cfg.space.len != 0) {
            try q.append("&with=withCategoryDiskMountPath&with=withCategoryDiskDriveCachePath&with=withCategoryHistoryDownloadPath&with=withReadOnlyFS");
        }
        const url = try std.fmt.allocPrint(a, "{s}?{s}", .{ file_api_url, q.slice() });
        const body = try self.requestLocked(a, "GET", url, null, ed, 0);
        const v = try a.create(json.Value);
        v.* = json.parse(a, body) catch return Error.UpstreamNotJson;
        return v;
    }

    /// 在 `parent_id` 下按名字找子项（本工程没有 Go 的 Obj 缓存，只能翻页找）。
    fn findChildLocked(self: *Thunder, a: std.mem.Allocator, parent_id: []const u8, name: []const u8, ed: ?*?[]const u8) !Entry {
        var page_token: []const u8 = "";
        var guard: usize = 0;
        while (guard < 10_000) : (guard += 1) {
            const v = try self.listPageLocked(a, parent_id, page_token, ed);
            const files = arrAt(v, "files");
            for (files) |*f| {
                const n = f.strAt("name") orelse continue;
                if (!std.mem.eql(u8, n, name)) continue;
                return entryFrom(f);
            }
            const next = v.strAt("next_page_token") orelse "";
            if (next.len == 0) break;
            page_token = next;
        }
        return driver.Error.NotFound;
    }

    /// 路径 → 条目。空路径 = 根（id 就是 `root_folder_id`）。
    fn resolveEntryLocked(self: *Thunder, a: std.mem.Allocator, path: []const u8, ed: ?*?[]const u8) !Entry {
        var cur = Entry{
            .id = self.cfg.root_folder_id,
            .name = "/",
            .is_dir = true,
            .raw = null,
        };
        var it = std.mem.tokenizeAny(u8, path, "/\\");
        while (it.next()) |seg| {
            cur = try self.findChildLocked(a, cur.id, seg, ed);
        }
        return cur;
    }

    /// GET /files/{id}?space=...（Go `Link` 的第一步）。
    fn getFileLocked(self: *Thunder, a: std.mem.Allocator, id: []const u8, ed: ?*?[]const u8) !*const json.Value {
        const url = try std.fmt.allocPrint(a, "{s}/{s}?space={s}", .{
            file_api_url,
            try urlmod.encode(a, id, .path),
            try urlmod.encode(a, self.cfg.space, .form),
        });
        const body = try self.requestLocked(a, "GET", url, null, ed, 0);
        const v = try a.create(json.Value);
        v.* = json.parse(a, body) catch return Error.UpstreamNotJson;
        return v;
    }

    // -- 上传（S3 分片，等价 aws-sdk-go s3manager）----------------------------

    fn putLocked(self: *Thunder, a: std.mem.Allocator, dst: []const u8, src: model.Source, ctx: *driver.Ctx) !void {
        const name = pathBase(dst) orelse return Error.InvalidPath;
        const parent_path = pathParent(dst) orelse return Error.InvalidPath;
        const parent = try self.resolveEntryLocked(a, parent_path, &ctx.err_detail);
        if (!parent.is_dir) return driver.Error.NotFound;

        const size = src.size();
        if (size < 0) return Error.InvalidPath;

        // Go：file.GetHash().GetHash(GCID)，拿不到就整文件算一遍。本工程的
        // `model.Source` 不带哈希，所以永远走"算一遍"这条路径。
        const gcid = try computeGcid(a, src, size, ctx);

        var b = Buf.init(a);
        try b.append("{\"kind\":\"" ++ kind_file ++ "\",\"parent_id\":");
        try json.writeString(&b, parent.id);
        try b.append(",\"name\":");
        try json.writeString(&b, name);
        try b.print(",\"size\":{d},\"hash\":", .{size});
        try json.writeString(&b, gcid);
        try b.append(",\"upload_type\":\"" ++ upload_type_resumable ++ "\",\"space\":");
        try json.writeString(&b, self.cfg.space);
        try b.append("}");

        const body = try self.requestLocked(a, "POST", file_api_url, b.slice(), &ctx.err_detail, 0);
        const v = try a.create(json.Value);
        v.* = json.parse(a, body) catch return Error.UpstreamNotJson;

        const utype = v.strAt("upload_type") orelse "";
        if (!std.mem.eql(u8, utype, upload_type_resumable)) {
            // 与 Go 一致：非 RESUMABLE 直接当成功返回（文件其实没上传）。
            log.warn("[thunder] upload_type={s} (not resumable); file NOT uploaded", .{utype});
            return;
        }

        const params = S3Params{
            .access_key_id = v.strAt("resumable.params.access_key_id") orelse return Error.BadUploadParams,
            .access_key_secret = v.strAt("resumable.params.access_key_secret") orelse return Error.BadUploadParams,
            .bucket = v.strAt("resumable.params.bucket") orelse return Error.BadUploadParams,
            .endpoint = v.strAt("resumable.params.endpoint") orelse return Error.BadUploadParams,
            .key = v.strAt("resumable.params.key") orelse return Error.BadUploadParams,
            .security_token = v.strAt("resumable.params.security_token") orelse "",
        };
        try self.s3Upload(a, params, src, size, ctx);
    }

    fn s3Upload(self: *Thunder, a: std.mem.Allocator, p: S3Params, src: model.Source, size: i64, ctx: *driver.Ctx) !void {
        const base = try s3Base(a, p.endpoint, p.bucket);
        const host = hostOf(base);
        const key_enc = try s3UriEncode(a, p.key);
        // virtual-hosted：bucket 在子域，路径里**只有** key（见 `s3Base` 的实测表）
        const obj_uri = try std.fmt.allocPrint(a, "/{s}", .{key_enc});
        const obj_url = try std.fmt.allocPrint(a, "{s}{s}", .{ base, obj_uri });

        const now = rt.nowSeconds();
        const days = @divFloor(now, std.time.s_per_day);
        const c = timeutil.civilFromDays(days);
        const sod = @mod(now, std.time.s_per_day);
        var date_b = Buf.init(a);
        try padNum(&date_b, c.y, 4);
        try padNum(&date_b, c.m, 2);
        try padNum(&date_b, c.d, 2);
        const date_stamp = try date_b.toOwned();
        var time_b = Buf.init(a);
        try padNum(&time_b, @divFloor(sod, 3600), 2);
        try padNum(&time_b, @divTrunc(@mod(sod, 3600), 60), 2);
        try padNum(&time_b, @mod(sod, 60), 2);
        const amz_date = try std.fmt.allocPrint(a, "{s}T{s}Z", .{ date_stamp, try time_b.toOwned() });

        const sc = SigCtx{
            .amz_date = amz_date,
            .date_stamp = date_stamp,
            .scope = try std.fmt.allocPrint(a, "{s}/{s}/{s}/aws4_request", .{ date_stamp, s3_region, s3_service }),
            .host = host,
            .access_key = p.access_key_id,
            .secret_key = p.access_key_secret,
            .session_token = p.security_token,
        };

        // s3manager：默认 5 MiB/片；超过 10000 片上限时按片数折算。
        var part_size: i64 = default_part_size;
        if (size > max_upload_parts * default_part_size) {
            part_size = @divTrunc(size, max_upload_parts - 1);
        }

        if (size <= part_size) {
            const buf = try a.alloc(u8, @intCast(@max(size, 1)));
            if (size > 0) try src.readAllInto(0, buf[0..@intCast(size)]);
            const auth = try sigV4(a, sc, "PUT", obj_uri, "", &.{});
            const res = try self.client.send(a, .{
                .method = "PUT",
                .url = obj_url,
                .headers = try authHeaders(a, sc, auth),
                .body = buf[0..@intCast(size)],
                .omit_content_type = true,
                .use_cookies = false,
            });
            if (!res.isOk()) {
                log.warn("[thunder] s3 single PUT HTTP {d}: {s}", .{ res.status, res.body[0..@min(res.body.len, 200)] });
                return Error.UploadFailed;
            }
            reportProgress(ctx, 100);
            return;
        }

        const count: i64 = @divTrunc(size + part_size - 1, part_size);
        // 1) CreateMultipartUpload
        const create_auth = try sigV4(a, sc, "POST", obj_uri, "uploads=", &.{});
        const create_res = try self.client.send(a, .{
            .method = "POST",
            .url = try std.fmt.allocPrint(a, "{s}?uploads=", .{obj_url}),
            .headers = try authHeaders(a, sc, create_auth),
            .omit_content_type = true,
            .use_cookies = false,
        });
        if (!create_res.isOk()) {
            log.warn("[thunder] s3 MPU create HTTP {d}", .{create_res.status});
            return Error.UploadFailed;
        }
        const upload_id = xmlTag(create_res.body, "UploadId") orelse return Error.InvalidResponse;

        // 2) 逐片 PUT
        const chunk = try a.alloc(u8, @intCast(part_size));
        const etags = try a.alloc([]const u8, @intCast(count));
        var part_no: i64 = 1;
        while (part_no <= count) : (part_no += 1) {
            const off: u64 = @intCast((part_no - 1) * part_size);
            const len: usize = @intCast(@min(part_size, size - @as(i64, @intCast(off))));
            try src.readAllInto(off, chunk[0..len]);
            const q = try std.fmt.allocPrint(a, "partNumber={d}&uploadId={s}", .{ part_no, upload_id });
            const auth = try sigV4(a, sc, "PUT", obj_uri, q, &.{});
            const res = try self.client.send(a, .{
                .method = "PUT",
                .url = try std.fmt.allocPrint(a, "{s}?{s}", .{ obj_url, q }),
                .headers = try authHeaders(a, sc, auth),
                .body = chunk[0..len],
                .omit_content_type = true,
                .use_cookies = false,
            });
            if (!res.isOk()) {
                log.warn("[thunder] s3 part {d} HTTP {d}", .{ part_no, res.status });
                return Error.UploadFailed;
            }
            etags[@intCast(part_no - 1)] = res.header("ETag") orelse return Error.InvalidResponse;
            reportProgress(ctx, @as(f64, @floatFromInt(off + len)) * 100.0 / @as(f64, @floatFromInt(@max(size, 1))));
        }

        // 3) CompleteMultipartUpload
        var xml = Buf.init(a);
        try xml.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload>");
        for (etags, 0..) |etag, i| {
            try xml.print("<Part><PartNumber>{d}</PartNumber><ETag>{s}</ETag></Part>", .{ i + 1, etag });
        }
        try xml.append("</CompleteMultipartUpload>");
        const q = try std.fmt.allocPrint(a, "uploadId={s}", .{upload_id});
        const auth = try sigV4(a, sc, "POST", obj_uri, q, &.{});
        const res = try self.client.send(a, .{
            .method = "POST",
            .url = try std.fmt.allocPrint(a, "{s}?{s}", .{ obj_url, q }),
            .headers = try authHeaders(a, sc, auth),
            .body = xml.slice(),
            .omit_content_type = true,
            .use_cookies = false,
        });
        if (!res.isOk()) {
            log.warn("[thunder] s3 MPU complete HTTP {d}: {s}", .{ res.status, res.body[0..@min(res.body.len, 200)] });
            return Error.UploadFailed;
        }
        reportProgress(ctx, 100);
    }

    // -- 生命周期 -----------------------------------------------------------

    fn initLocked(self: *Thunder, a: std.mem.Allocator, ed: ?*?[]const u8) !void {
        if (self.variant == .normal) return self.initNormal(a, ed);
        return self.initExpert(a, ed);
    }

    /// Go `Thunder.Init`：参数全硬编码，只认用户名密码。
    fn initNormal(self: *Thunder, a: std.mem.Allocator, ed: ?*?[]const u8) !void {
        self.freeAlgorithms();
        self.algorithms = try ownAlgorithms(self.alloc, &default_algorithms);
        // ⚠️ `a` 是**请求级 arena**，init 返回后就被回收 —— 驱动要长期持有的
        // 切片必须落在 `self.alloc` 上，否则下一次请求读到的是悬垂内存。
        try self.setOwned(&self.device_id, try self.computeDeviceId(a));
        if (self.cfg.device_id.len == 0) {
            try self.setOwned(&self.cfg.device_id, self.device_id);
            self.persist(a);
        }
        const trimmed = std.mem.trim(u8, self.cfg.captcha_token, " \t\r\n");
        if (trimmed.len != 0) try self.setOwned(&self.cfg.captcha_token, trimmed);

        const id = try self.identity(a);
        if (!std.mem.eql(u8, id, self.identity_cached) or !self.isLoginLocked(a)) {
            try self.setOwned(&self.identity_cached, id);
            const tok = try self.login(a, self.cfg.username, self.cfg.password, ed);
            // ⚠ Go 在这里清 `Addition.CreditKey`，但它**只在内存里清、不落盘**
            // （Init 里只有算 device_id 那步 MustSaveDriverStorage）。
            // 本工程的 access_token 不落盘 ⇒ 重启后 `isLogin` 为假，必须靠配置里
            // 的 credit_key 重新登录。早期实现"清空 + persist"把它从 config 抹了，
            // 表现为每次重启都要重新过手机/滑块验证（2026-10-20 真机踩到）。
            // 故这里**不能**清、更不能 persist。
            try self.setToken(tok);
        }
    }

    /// Go `ThunderExpert.Init`，兼作网页版（`.web`）的 init。
    ///
    /// 与 Go 的唯一顺序差异：device_id 在算 `identity` **之前**就落定。
    /// 否则首次运行 identity 用的是空 device_id，生成并落盘后再算一次就变了，
    /// 下次启动必然多打一次登录/refresh —— 网页版每次 refresh 都会轮换
    /// refresh_token，白白多烧一次。挪到前面后 identity 首轮即稳定。
    fn initExpert(self: *Thunder, a: std.mem.Allocator, ed: ?*?[]const u8) !void {
        try self.setOwned(&self.device_id, try self.computeDeviceId(a));
        if (self.cfg.device_id.len == 0) {
            try self.setOwned(&self.cfg.device_id, self.device_id);
            self.persist(a);
        }
        // Go 的 expert 分支**不** trim captcha_token（只有 normal 会 trim）。

        const id = try self.identity(a);
        if (!std.mem.eql(u8, id, self.identity_cached) or !self.isLoginLocked(a)) {
            try self.setOwned(&self.identity_cached, id);

            // 签名方式：captcha_sign 走固定签名（算法表为空），否则按逗号拆。
            // 网页版恒走算法表（15 盐），配置里给了 captcha_sign 也无意义。
            self.freeAlgorithms();
            if (self.variant != .web and std.mem.eql(u8, self.cfg.sign_type, "captcha_sign")) {
                self.algorithms = &.{};
            } else {
                self.algorithms = try splitAlgorithms(self.alloc, self.cfg.algorithms);
            }

            // 登录方式。网页版没有 core login 回退（那正是它要绕开的风控），
            // 走自己的 OAuth：refresh_token 优先，失效则手机号密码重登。
            if (self.variant == .web) {
                const tok = try self.webLoginOrRefresh(a, ed);
                try self.setToken(tok);
                self.persist(a);
            } else if (std.mem.eql(u8, self.cfg.login_type, "refresh_token")) {
                if (self.cfg.refresh_token.len == 0) return Error.AuthFailed;
                const tok = try self.refreshTokenCall(a, self.cfg.refresh_token, ed);
                try self.setToken(tok);
                self.persist(a);
            } else {
                const tok = try self.login(a, self.cfg.username, self.cfg.password, ed);
                // 同 initNormal：不清 credit_key，否则重启后无法重新登录（见上方注释）。
                try self.setToken(tok);
                if (self.variant != .normal) self.persist(a);
            }
        }
    }
};

// ---------------------------------------------------------------------------
// vtable 入口
// ---------------------------------------------------------------------------

fn as(ptr: *anyopaque) *Thunder {
    return @ptrCast(@alignCast(ptr));
}

const Entry = struct {
    id: []const u8,
    name: []const u8,
    is_dir: bool,
    /// 列表接口返回的原始节点（指向请求 arena，活到请求结束）。
    raw: ?*const json.Value = null,
};

fn entryFrom(f: *const json.Value) Entry {
    const kind = f.strAt("kind") orelse "";
    return .{
        .id = f.strAt("id") orelse "",
        .name = f.strAt("name") orelse "",
        .is_dir = std.mem.eql(u8, kind, kind_folder),
        .raw = f,
    };
}

fn objFrom(f: *const json.Value) model.Obj {
    const e = entryFrom(f);
    const h = f.strAt("hash") orelse "";
    return .{
        .name = e.name,
        .size = f.intAt("size") orelse 0,
        .is_dir = e.is_dir,
        .modified = parseTime(f.strAt("modified_time")),
        .created = parseTime(f.strAt("created_time")),
        // `sign` 带上文件 id（本工程 api 层不消费它，但排查时有用）。
        .sign = e.id,
        .thumb = f.strAt("thumbnail_link") orelse "",
        .hash_info = if (!e.is_dir and h.len > 0)
            model.HashInfo{ .hash_name = "gcid", .hash_value = h }
        else
            null,
    };
}

fn init(ptr: *anyopaque, ctx: *driver.Ctx) anyerror!void {
    const self = as(ptr);
    const io = rt.io();
    self.req_mu.lockUncancelable(io);
    defer self.req_mu.unlock(io);
    return self.initLocked(ctx.alloc, &ctx.err_detail);
}

fn deinit(ptr: *anyopaque, ctx: *driver.Ctx) void {
    const self = as(ptr);
    _ = ctx;
    self.freeToken();
    self.freeAlgorithms();
    self.client.deinit();
}

fn list(ptr: *anyopaque, ctx: *driver.Ctx, dir: []const u8) anyerror![]model.Obj {
    const self = as(ptr);
    const a = ctx.alloc;
    const io = rt.io();
    self.req_mu.lockUncancelable(io);
    defer self.req_mu.unlock(io);

    const entry = try self.resolveEntryLocked(a, dir, &ctx.err_detail);
    if (!entry.is_dir) return driver.Error.NotFound;

    var out = List(model.Obj).init(a);
    var page_token: []const u8 = "";
    var guard: usize = 0;
    while (guard < 10_000) : (guard += 1) {
        const v = try self.listPageLocked(a, entry.id, page_token, &ctx.err_detail);
        for (arrAt(v, "files")) |*f| try out.append(objFrom(f));
        const next = v.strAt("next_page_token") orelse "";
        if (next.len == 0) break;
        page_token = next;
    }
    return out.toOwned();
}

fn details(ptr: *anyopaque, ctx: *driver.Ctx, path: []const u8) anyerror!model.File {
    const self = as(ptr);
    const a = ctx.alloc;
    const io = rt.io();
    self.req_mu.lockUncancelable(io);
    defer self.req_mu.unlock(io);

    var it = std.mem.tokenizeAny(u8, path, "/\\");
    if (it.next() == null) return .{ .name = "/", .is_dir = true };
    const entry = try self.resolveEntryLocked(a, path, &ctx.err_detail);
    const raw = entry.raw orelse return .{ .name = entry.name, .is_dir = entry.is_dir };
    const o = objFrom(raw);
    return model.File.fromObj(o);
}

fn link(ptr: *anyopaque, ctx: *driver.Ctx, path: []const u8, args: driver.LinkArgs) anyerror!model.Link {
    const self = as(ptr);
    const a = ctx.alloc;
    _ = args;
    const io = rt.io();
    self.req_mu.lockUncancelable(io);
    defer self.req_mu.unlock(io);

    const entry = try self.resolveEntryLocked(a, path, &ctx.err_detail);
    if (entry.is_dir) return driver.Error.NotSupported;
    const f = try self.getFileLocked(a, entry.id, &ctx.err_detail);

    var url = f.strAt("web_content_link") orelse "";
    if (self.cfg.use_video_url) {
        if (f.getPath("medias")) |mv| {
            if (mv.asArray()) |medias| {
                for (medias) |m| {
                    const u = m.strAt("link.url") orelse "";
                    if (u.len > 0) {
                        url = u;
                        break;
                    }
                }
            }
        }
    }
    if (url.len == 0) {
        ctx.setErrDetail("upstream returned an empty download url");
        return Error.InvalidResponse;
    }

    // ⚠️ header 必须由分配器拥有（见 quarkuc.zig 的栈悬垂事故记录）。
    const hdrs = try a.alloc(model.Header, 1);
    hdrs[0] = .{ .name = "User-Agent", .value = self.cfg.download_user_agent };
    return .{ .url = url, .header = hdrs };
}

fn makeDir(ptr: *anyopaque, ctx: *driver.Ctx, dir: []const u8) anyerror!void {
    const self = as(ptr);
    const a = ctx.alloc;
    const name = pathBase(dir) orelse return Error.InvalidPath;
    const parent_path = pathParent(dir) orelse return Error.InvalidPath;
    const io = rt.io();
    self.req_mu.lockUncancelable(io);
    defer self.req_mu.unlock(io);

    const parent = try self.resolveEntryLocked(a, parent_path, &ctx.err_detail);
    if (!parent.is_dir) return driver.Error.NotFound;

    var b = Buf.init(a);
    try b.append("{\"kind\":\"" ++ kind_folder ++ "\",\"name\":");
    try json.writeString(&b, name);
    try b.append(",\"parent_id\":");
    try json.writeString(&b, parent.id);
    try b.append(",\"space\":");
    try json.writeString(&b, self.cfg.space);
    try b.append("}");
    _ = try self.requestLocked(a, "POST", file_api_url, b.slice(), &ctx.err_detail, 0);
}

fn move(ptr: *anyopaque, ctx: *driver.Ctx, src: []const u8, dst_dir: []const u8) anyerror!void {
    const self = as(ptr);
    const a = ctx.alloc;
    const io = rt.io();
    self.req_mu.lockUncancelable(io);
    defer self.req_mu.unlock(io);

    const entry = try self.resolveEntryLocked(a, src, &ctx.err_detail);
    const dst = try self.resolveEntryLocked(a, dst_dir, &ctx.err_detail);
    if (!dst.is_dir) return driver.Error.NotFound;

    const body = try batchBody(a, "to", dst.id, entry.id, self.cfg.space);
    const url = file_api_url ++ ":batchMove";
    _ = try self.requestLocked(a, "POST", url, body, &ctx.err_detail, 0);
}

fn copy(ptr: *anyopaque, ctx: *driver.Ctx, src: []const u8, dst_dir: []const u8) anyerror!void {
    const self = as(ptr);
    const a = ctx.alloc;
    const io = rt.io();
    self.req_mu.lockUncancelable(io);
    defer self.req_mu.unlock(io);

    const entry = try self.resolveEntryLocked(a, src, &ctx.err_detail);
    const dst = try self.resolveEntryLocked(a, dst_dir, &ctx.err_detail);
    if (!dst.is_dir) return driver.Error.NotFound;

    const body = try batchBody(a, "to", dst.id, entry.id, self.cfg.space);
    const url = file_api_url ++ ":batchCopy";
    _ = try self.requestLocked(a, "POST", url, body, &ctx.err_detail, 0);
}

fn rename(ptr: *anyopaque, ctx: *driver.Ctx, src: []const u8, new_name: []const u8) anyerror!void {
    const self = as(ptr);
    const a = ctx.alloc;
    const io = rt.io();
    self.req_mu.lockUncancelable(io);
    defer self.req_mu.unlock(io);

    const entry = try self.resolveEntryLocked(a, src, &ctx.err_detail);
    var b = Buf.init(a);
    try b.append("{\"name\":");
    try json.writeString(&b, new_name);
    try b.append(",\"space\":");
    try json.writeString(&b, self.cfg.space);
    try b.append("}");
    const url = try std.fmt.allocPrint(a, "{s}/{s}", .{ file_api_url, try urlmod.encode(a, entry.id, .path) });
    _ = try self.requestLocked(a, "PATCH", url, b.slice(), &ctx.err_detail, 0);
}

fn remove(ptr: *anyopaque, ctx: *driver.Ctx, path: []const u8, is_dir: bool) anyerror!void {
    const self = as(ptr);
    _ = is_dir; // 迅雷的 trash 接口对文件/目录是同一个
    const a = ctx.alloc;
    const io = rt.io();
    self.req_mu.lockUncancelable(io);
    defer self.req_mu.unlock(io);

    const entry = try self.resolveEntryLocked(a, path, &ctx.err_detail);
    const url = try std.fmt.allocPrint(a, "{s}/{s}/trash?space={s}", .{
        file_api_url,
        try urlmod.encode(a, entry.id, .path),
        try urlmod.encode(a, self.cfg.space, .form),
    });
    _ = try self.requestLocked(a, "PATCH", url, "{}", &ctx.err_detail, 0);
}

fn space(ptr: *anyopaque, ctx: *driver.Ctx) anyerror!driver.DiskUsage {
    const self = as(ptr);
    const a = ctx.alloc;
    const io = rt.io();
    self.req_mu.lockUncancelable(io);
    defer self.req_mu.unlock(io);

    const body = try self.requestLocked(a, "GET", ep_about, null, &ctx.err_detail, 0);
    const v = try a.create(json.Value);
    v.* = json.parse(a, body) catch return Error.UpstreamNotJson;
    // Go 对 limit/usage 的解析失败是硬错误（strconv.ParseInt 直接 return err）。
    const total = v.strAt("quota.limit") orelse return Error.InvalidResponse;
    const used = v.strAt("quota.usage") orelse return Error.InvalidResponse;
    return .{
        .total = std.fmt.parseInt(i64, total, 10) catch return Error.InvalidResponse,
        .used = std.fmt.parseInt(i64, used, 10) catch return Error.InvalidResponse,
    };
}

fn put(ptr: *anyopaque, ctx: *driver.Ctx, dst: []const u8, src: model.Source) anyerror!void {
    const self = as(ptr);
    const io = rt.io();
    self.req_mu.lockUncancelable(io);
    defer self.req_mu.unlock(io);
    return self.putLocked(ctx.alloc, dst, src, ctx);
}

// ---------------------------------------------------------------------------
// 纯函数（全部可单测）
// ---------------------------------------------------------------------------

fn arrAt(v: *const json.Value, path: []const u8) []json.Value {
    const x = v.getPath(path) orelse return &.{};
    return x.asArray() orelse &.{};
}

fn setErr(ed: ?*?[]const u8, msg: []const u8) void {
    if (ed) |p| {
        if (msg.len > 0) p.* = msg;
    }
}

/// Go `ErrResp.Error()`：`ErrorCode: %d ,Error: %s ,ErrorDescription: %s `。
fn errText(a: std.mem.Allocator, e: ErrInfo) ![]const u8 {
    return std.fmt.allocPrint(a, "ErrorCode: {d} ,Error: {s} ,ErrorDescription: {s} ", .{ e.code, e.msg, e.desc });
}

fn parseErrInfo(a: std.mem.Allocator, body: []const u8) ErrInfo {
    var e = ErrInfo{};
    const v = json.parse(a, body) catch return e;
    if (v.asObject() == null) return e;
    if (v.intAt("error_code")) |c| e.code = c;
    if (v.strAt("error")) |s| e.msg = s;
    if (v.strAt("error_description")) |s| e.desc = s;
    return e;
}

fn tokenFromJson(v: *const json.Value) !Token {
    return .{
        .token_type = v.strAt("token_type") orelse "Bearer",
        .access_token = v.strAt("access_token") orelse "",
        .refresh_token = v.strAt("refresh_token") orelse "",
        .user_id = v.strAt("user_id") orelse "",
    };
}

/// Go `GetAction`：正则 `://[^/]+((/[^/\s?#]+)*)` 取 path 部分。
fn getAction(a: std.mem.Allocator, method: []const u8, url: []const u8) ![]const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse 0;
    const rest = url[if (scheme == 0) 0 else scheme + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const path = if (slash) |i| rest[i..] else "";
    const end = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
    return std.fmt.allocPrint(a, "{s}:{s}", .{ method, path[0..end] });
}

/// Go `generateDeviceSign`：`div101.<deviceID><md5(hex(sha1(deviceID+package+APPID+APPKey)))>`。
fn generateDeviceSign(a: std.mem.Allocator, device_id: []const u8, package_name: []const u8) ![]const u8 {
    const base = try std.fmt.allocPrint(a, "{s}{s}{s}{s}", .{ device_id, package_name, app_id, app_key });
    const sha1_hex = try hash.sha1Hex(a, base);
    const md5_hex = try hash.md5Hex(a, sha1_hex);
    return std.fmt.allocPrint(a, "div101.{s}{s}", .{ device_id, md5_hex });
}

/// Go `GetCaptchaSign` 的纯函数形态：`"1." + md5(...md5(base + alg))`。
fn captchaSignAt(
    a: std.mem.Allocator,
    client_id: []const u8,
    client_version: []const u8,
    package_name: []const u8,
    device_id: []const u8,
    timestamp: []const u8,
    algorithms: []const []const u8,
) ![]const u8 {
    var s = try std.fmt.allocPrint(a, "{s}{s}{s}{s}{s}", .{ client_id, client_version, package_name, device_id, timestamp });
    for (algorithms) |alg| {
        const joined = try std.fmt.allocPrint(a, "{s}{s}", .{ s, alg });
        s = try hash.md5Hex(a, joined);
    }
    return std.fmt.allocPrint(a, "1.{s}", .{s});
}

/// Go `strings.Split(x.Algorithms, ",")`。空串 → 一个空元素（与 Go 一致：
/// `len(Algorithms) == 1`，所以仍会做一次 md5）。
fn splitAlgorithms(a: std.mem.Allocator, s: []const u8) ![]const []const u8 {
    var l = List([]const u8).init(a);
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |tok| try l.append(try a.dupe(u8, tok));
    return l.toOwned();
}

/// 把算法表复制到**驱动自己的分配器**上。
///
/// ⚠️ 不能直接存 `&default_algorithms`（静态常量数组）：`freeAlgorithms` 会在
/// reload 时释放它，释放只读常量段会直接崩。所以一律深拷，所有权单一。
fn ownAlgorithms(a: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, items.len);
    for (items, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
}

/// Go `utils.IsEmailFormat` 的正则 `\w+([-+.]\w+)*@\w+([-.]\w+)*\.\w+([-.]\w+)*`
/// 是**非锚定**匹配。这里按同样的判据近似：本地部分至少 1 个词字符，域名含点，
/// 且点后有词字符。对账号（邮箱/手机号/用户名）这三类输入行为一致。
fn looksLikeEmail(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at + 1 >= s.len) return false;
    // 本地部分必须是词字符开头
    if (!isWordChar(s[0])) return false;
    const domain = s[at + 1 ..];
    const dot = std.mem.lastIndexOfScalar(u8, domain, '.') orelse return false;
    if (dot == 0 or dot + 1 >= domain.len) return false;
    if (!isWordChar(domain[dot + 1])) return false;
    return true;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn parseTime(s: ?[]const u8) i64 {
    const v = s orelse return 0;
    return timeutil.parseRfc3339(v) orelse 0;
}

fn pathBase(path: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, path, "/\\");
    if (t.len == 0) return null;
    const i = std.mem.lastIndexOfAny(u8, t, "/\\") orelse return t;
    if (i + 1 >= t.len) return null;
    return t[i + 1 ..];
}

fn pathParent(path: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, path, "/\\");
    const i = std.mem.lastIndexOfAny(u8, t, "/\\") orelse return "";
    if (i == 0) return "";
    return t[0..i];
}

fn batchBody(a: std.mem.Allocator, to_key: []const u8, to_id: []const u8, id: []const u8, space_id: []const u8) ![]const u8 {
    var b = Buf.init(a);
    try b.print("{{\"{s}\":{{\"parent_id\":", .{to_key});
    try json.writeString(&b, to_id);
    try b.append("},\"ids\":[");
    try json.writeString(&b, id);
    try b.append("],\"space\":");
    try json.writeString(&b, space_id);
    try b.append("}");
    return b.toOwned();
}

/// 零填充十进制（Zig 0.17 的 `{d:0>4}` 行为不可靠，手写更稳）。
fn padNum(b: *Buf, v: i64, width: usize) !void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
    var i: usize = width;
    while (i > s.len) : (i -= 1) try b.appendByte('0');
    try b.append(s);
}

fn reportProgress(ctx: *driver.Ctx, pct: f64) void {
    if (ctx.progress) |f| f(ctx.progress_userdata, @intFromFloat(@min(pct, 100.0)));
}

/// Go `getGcid` 的分块大小：`psize=256KiB`，当 `size/psize > 512` 时翻倍，
/// 上限 2 MiB。
fn gcidBlockSize(size: i64) i64 {
    var psize: i64 = 0x40000;
    const s: f64 = @floatFromInt(size);
    while (s / @as(f64, @floatFromInt(psize)) > 512.0 and psize < 0x200000) psize <<= 1;
    return psize;
}

/// Go `getGcid`：每块先 sha1，再把 20 字节摘要喂给外层 sha1。
fn computeGcid(a: std.mem.Allocator, src: model.Source, size: i64, ctx: *driver.Ctx) ![]const u8 {
    const block: usize = @intCast(gcidBlockSize(size));
    const buf = try a.alloc(u8, block);
    var outer = hash.Sha1Stream{};
    var off: u64 = 0;
    while (true) {
        var got: usize = 0;
        while (got < buf.len) {
            const n = try src.readAt(off + got, buf[got..]);
            if (n == 0) break;
            got += n;
        }
        if (got == 0) break;
        var inner: [hash.SHA1_LEN]u8 = undefined;
        hash.Sha1.hash(buf[0..got], &inner, .{});
        outer.update(&inner);
        off += got;
        // 与 Go 一致：算哈希这一段自己也把进度跑到 100，随后上传再从 0 开始
        // （`stream.CacheFullAndHash(file, &up, ...)` 与上传共用一个回调）。
        if (size > 0) reportProgress(ctx, @as(f64, @floatFromInt(off)) * 100.0 / @as(f64, @floatFromInt(size)));
    }
    return outer.finalHexLower(a);
}

// ---------------------------------------------------------------------------
// S3（SigV4）
// ---------------------------------------------------------------------------

const S3Params = struct {
    access_key_id: []const u8,
    access_key_secret: []const u8,
    bucket: []const u8,
    endpoint: []const u8,
    key: []const u8,
    security_token: []const u8,
};

const SigCtx = struct {
    amz_date: []const u8,
    date_stamp: []const u8,
    scope: []const u8,
    host: []const u8,
    access_key: []const u8,
    secret_key: []const u8,
    session_token: []const u8,
};

/// Go `strings.TrimLeft(s, cutset)` —— 第二个参数是**字符集**，不是前缀。
/// 迅雷返回的 endpoint 形如 `<bucket>.oss-cn-xxx.aliyuncs.com`，Go 用
/// `TrimLeft(endpoint, bucket+".")` 去掉 bucket 前缀（能work是因为 'o' 不在
/// 字符集里）。这里逐字复刻字符集语义，避免出现"我们比 Go 更聪明"的偏差。
fn trimLeftCutset(s: []const u8, cutset: []const u8) []const u8 {
    var i: usize = 0;
    outer: while (i < s.len) : (i += 1) {
        for (cutset) |c| {
            if (s[i] == c) continue :outer;
        }
        break;
    }
    return s[i..];
}

/// endpoint → **virtual-hosted** base URL：`https://<bucket>.<去前缀 endpoint>`。
///
/// 2026-10-20 真机实测（tools/raw_put.py，4 种形态 × 2 个 region）：
///
///   | 形态 | 结果 |
///   |---|---|
///   | `https://<bucket>.<trimLeft(endpoint)>/<key>` | **200** ← 唯一可用 |
///   | `https://<trimLeft(endpoint)>/<bucket>/<key>` | DNS 解析不到 |
///   | `https://<bucket>.<原 endpoint>/<key>` | DNS 解析不到（bucket 重复） |
///   | `https://<原 endpoint>/<bucket>/<key>` | **403 AccessDenied**（host 不认 path-style） |
///
/// 这也解释了 Go 为什么要先 `TrimLeft(endpoint, bucket+".")`：aws-sdk-go 默认
/// 就是 virtual-hosted，会自己把 bucket 拼到子域上，不先剪掉前缀就成了
/// `<bucket>.<bucket>.up.xdrive...`。剪完是 `up.xdrive.xunlei.com`，拼回去正好
/// 等于服务端给的原始 endpoint —— 这是**正确**的，不是巧合。
///
/// region 用 "xunlei"（Go 写死的值）还是响应里的 "cn-shanghai" 都能过：
/// 迅雷这套 OSS 网关不校验 scope 里的 region。
fn s3Base(a: std.mem.Allocator, endpoint: []const u8, bucket: []const u8) ![]const u8 {
    // 顺序：先剥 scheme / 尾斜杠，再按 Go 的字符集语义剪 bucket 前缀。
    // （Go 是先 TrimLeft 后交给 SDK 补 scheme；对真实 endpoint 两者等价 ——
    // 迅雷返回的 endpoint 不带 scheme。先剥 scheme 更稳，带 scheme 也不出错。）
    var rest = endpoint;
    if (std.mem.indexOf(u8, rest, "://")) |i| rest = rest[i + 3 ..];
    rest = std.mem.trimEnd(u8, rest, "/");
    var cut_buf: [512]u8 = undefined;
    const cutset = std.fmt.bufPrint(&cut_buf, "{s}.", .{bucket}) catch bucket;
    const trimmed = trimLeftCutset(rest, cutset);
    return std.fmt.allocPrint(a, "https://{s}.{s}", .{ bucket, trimmed });
}

fn hostOf(url: []const u8) []const u8 {
    const i = std.mem.indexOf(u8, url, "://") orelse 0;
    const rest = url[if (i == 0) 0 else i + 3 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return rest[0..slash];
}

fn authHeaders(a: std.mem.Allocator, sc: SigCtx, auth: []const u8) ![]model.Header {
    // 与 aws-sdk-go 一致：static credentials 没有 session token 时**不**发
    // `x-amz-security-token` 头（发了空值会被 OSS 当成非法令牌）。
    const n: usize = if (sc.session_token.len > 0) 4 else 3;
    const hl = try a.alloc(model.Header, n);
    hl[0] = .{ .name = "x-amz-content-sha256", .value = unsigned_payload };
    hl[1] = .{ .name = "x-amz-date", .value = sc.amz_date };
    if (n == 4) {
        hl[2] = .{ .name = "x-amz-security-token", .value = sc.session_token };
        hl[3] = .{ .name = "Authorization", .value = auth };
    } else {
        hl[2] = .{ .name = "Authorization", .value = auth };
    }
    return hl;
}

/// AWS SigV4 的 URI 编码：`UriEncode(path, encodeSlash=false)` —— 只保留
/// unreserved 字符和 `/`，其余全部百分号编码（比 `urlmod` 的 `.path` 严格：
/// `.path` 会放过 `:`、`,`、`@` 等，那些字符在 SigV4 里必须编码）。
fn s3UriEncode(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    const enc = try urlmod.encode(a, s, .component);
    if (std.mem.indexOf(u8, enc, "%2F") == null) return enc;
    var b = Buf.init(a);
    var i: usize = 0;
    while (i < enc.len) {
        if (i + 3 <= enc.len and std.mem.eql(u8, enc[i .. i + 3], "%2F")) {
            try b.appendByte('/');
            i += 3;
        } else {
            try b.appendByte(enc[i]);
            i += 1;
        }
    }
    return b.toOwned();
}

/// AWS SigV4（UNSIGNED-PAYLOAD），产出 Authorization 头。
fn sigV4(
    a: std.mem.Allocator,
    sc: SigCtx,
    method: []const u8,
    canonical_uri: []const u8,
    canonical_query: []const u8,
    extra_headers: []const model.Header,
) ![]const u8 {
    const signed_headers = if (sc.session_token.len > 0)
        "host;x-amz-content-sha256;x-amz-date;x-amz-security-token"
    else
        "host;x-amz-content-sha256;x-amz-date";
    var canon_headers = Buf.init(a);
    try canon_headers.print("host:{s}\n", .{sc.host});
    try canon_headers.print("x-amz-content-sha256:{s}\n", .{unsigned_payload});
    try canon_headers.print("x-amz-date:{s}\n", .{sc.amz_date});
    if (sc.session_token.len > 0) {
        try canon_headers.print("x-amz-security-token:{s}\n", .{sc.session_token});
    }
    for (extra_headers) |h| {
        var low = try a.alloc(u8, h.name.len);
        for (h.name, 0..) |c, i| low[i] = std.ascii.toLower(c);
        try canon_headers.print("{s}:{s}\n", .{ low, h.value });
    }

    var canon_req = Buf.init(a);
    try canon_req.print("{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        method,
        canonical_uri,
        canonical_query,
        canon_headers.slice(),
        signed_headers,
        unsigned_payload,
    });

    var req_hash: [32]u8 = undefined;
    hash.Sha256.hash(canon_req.slice(), &req_hash, .{});

    var sts = Buf.init(a);
    try sts.append("AWS4-HMAC-SHA256\n");
    try sts.print("{s}\n{s}\n", .{ sc.amz_date, sc.scope });
    try sts.append(&std.fmt.bytesToHex(req_hash, .lower));

    const seed = try a.alloc(u8, 4 + sc.secret_key.len);
    @memcpy(seed[0..4], "AWS4");
    @memcpy(seed[4..], sc.secret_key);
    var k_date: [32]u8 = undefined;
    hmacSha256(seed, sc.date_stamp, &k_date);
    var k_region: [32]u8 = undefined;
    hmacSha256(&k_date, s3_region, &k_region);
    var k_service: [32]u8 = undefined;
    hmacSha256(&k_region, s3_service, &k_service);
    var k_signing: [32]u8 = undefined;
    hmacSha256(&k_service, "aws4_request", &k_signing);
    var signature: [32]u8 = undefined;
    hmacSha256(&k_signing, sts.slice(), &signature);

    return std.fmt.allocPrint(a, "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}", .{
        sc.access_key, sc.scope, signed_headers, &std.fmt.bytesToHex(signature, .lower),
    });
}

fn hmacSha256(key: []const u8, msg: []const u8, out: *[32]u8) void {
    std.crypto.auth.hmac.sha2.HmacSha256.create(out, msg, key);
}

fn xmlTag(xml: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [65]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag}) catch return null;
    const s = std.mem.indexOf(u8, xml, open) orelse return null;
    const from = s + open.len;
    const e = std.mem.indexOf(u8, xml[from..], close) orelse return null;
    return xml[from .. from + e];
}

// ---------------------------------------------------------------------------
// factory
// ---------------------------------------------------------------------------

pub const factory = driver.Factory{
    // 逐字等于 Go `driver.Config.Name`（drivers/thunder/meta.go:100）。
    .key = "Thunder",
    .label = "迅雷云盘",
    .secrets = &.{ "password", "captcha_token", "credit_key" },
    .addition_schema =
    \\{
    \\  "username":       {"type":"string","required":true,"help":"迅雷账号（手机号/邮箱）"},
    \\  "password":       {"type":"string","required":true,"secret":true,"help":"登录密码"},
    \\  "root_folder_id": {"type":"string","default":"","help":"根目录 ID，留空 = 网盘根"},
    \\  "device_id":      {"type":"string","default":"","help":"登录设备 ID（32 位），留空自动派生"},
    \\  "captcha_token":  {"type":"string","default":"","secret":true,"help":"验证码 token，留空自动获取"},
    \\  "credit_key":     {"type":"string","default":"","secret":true,"help":"信任密钥，仅登录时需要验证时填"},
    \\  "space":          {"type":"string","default":"","help":"远程设备 ID，留空 = 个人云盘"}
    \\}
    ,
    .create = create,
};

pub const expert_factory = driver.Factory{
    // 逐字等于 Go `driver.Config.Name`（drivers/thunder/meta.go:105）。
    .key = "ThunderExpert",
    .label = "迅雷云盘（专家）",
    .secrets = &.{ "password", "refresh_token", "captcha_token", "credit_key", "client_secret" },
    .addition_schema =
    \\{
    \\  "login_type":     {"type":"select","options":"user,refresh_token","default":"user","help":"登录方式"},
    \\  "sign_type":      {"type":"select","options":"algorithms,captcha_sign","default":"algorithms","help":"签名方式"},
    \\  "username":       {"type":"string","required":true,"help":"login_type=user 时必填"},
    \\  "password":       {"type":"string","required":true,"secret":true,"help":"login_type=user 时必填"},
    \\  "refresh_token":  {"type":"string","required":true,"secret":true,"help":"login_type=refresh_token 时必填"},
    \\  "algorithms":     {"type":"string","default":"9uJNVj/wLmdwKrJaVj/omlQ,Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf,Eb+L7Ce+Ej48u,jKY0,ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd,wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK,gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O,5IiCoM9B1/788ntB,P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf,+oK0AN","help":"sign_type=algorithms 时的算法表（逗号分隔）"},
    \\  "captcha_sign":   {"type":"string","default":"","help":"sign_type=captcha_sign 时的固定签名"},
    \\  "timestamp":      {"type":"string","default":"","help":"sign_type=captcha_sign 时的时间戳"},
    \\  "captcha_token":  {"type":"string","default":"","secret":true,"help":"验证码 token"},
    \\  "credit_key":     {"type":"string","default":"","secret":true,"help":"信任密钥"},
    \\  "device_id":      {"type":"string","default":"","help":"登录设备 ID（32 位），留空自动派生"},
    \\  "client_id":      {"type":"string","default":"Xp6vsxz_7IYVw2BB"},
    \\  "client_secret":  {"type":"string","default":"Xp6vsy4tN9toTVdMSpomVdXpRmES","secret":true},
    \\  "client_version": {"type":"string","default":"8.31.0.9726"},
    \\  "package_name":   {"type":"string","default":"com.xunlei.downloadprovider"},
    \\  "user_agent":     {"type":"string","default":"ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC OSVersion/12 protocolVersion/301 platformVersion/10 sdkVersion/512000 Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)","help":"登录请求 UA"},
    \\  "download_user_agent": {"type":"string","default":"Dalvik/2.1.0 (Linux; U; Android 12; M2004J7AC Build/SP1A.210812.016)","help":"下载请求 UA"},
    \\  "use_video_url":  {"type":"boolean","default":false,"help":"优先用视频转码地址代替下载直链"},
    \\  "space":          {"type":"string","default":"","help":"远程设备 ID，留空 = 个人云盘"},
    \\  "root_folder_id": {"type":"string","default":"","help":"根目录 ID，留空 = 网盘根"}
    \\}
    ,
    .create = createExpert,
};

/// 网页版（pan.xunlei.com）。**上游没有这个驱动** —— 上游三个迅雷驱动全走
/// 安卓 core login，必被数美风控拦。本驱动改用网页 OAuth 的 refresh_token，
/// 并用逆向出的网页签名盐表自签 `captcha_sign`。
/// 逆向记录与盐表重取方法：`docs/THUNDER_WEB_RE_2026-10-20.md`。
pub const web_factory = driver.Factory{
    .key = "ThunderWeb",
    .label = "迅雷云盘（网页版）",
    .secrets = &.{ "password", "refresh_token", "captcha_token" },
    .addition_schema =
    \\{
    \\  "username":       {"type":"string","help":"迅雷账号（手机号/邮箱）。填了它驱动就能自动续期，只需录一次"},
    \\  "password":       {"type":"string","secret":true,"help":"登录密码（与 username 配套）"},
    \\  "refresh_token":  {"type":"string","secret":true,"help":"可选。填了优先用 refresh_token；失效会自动用上面的账号密码重新登录"},
    \\  "client_id":      {"type":"string","default":"Xqp0kJBXWhwaTpB6","help":"网页版 client_id，勿改成安卓的（会 invalid_grant）"},
    \\  "client_version": {"type":"string","default":"1.93.12","help":"网页前端版本，与签名盐表绑定"},
    \\  "package_name":   {"type":"string","default":"pan.xunlei.com","help":"同时充当签名 base 里的 host"},
    \\  "device_id":      {"type":"string","default":"","help":"设备 ID（32 位 hex），留空自动生成并持久化"},
    \\  "algorithms":     {"type":"string","default":"QT5gqd1eSINZe+K,9TafMwqVWgh45hLntDm6HLcOXE,L0nOen58D2cCsOSRaRRYt1Mj+XTVM,gu4CPVQhQU,X/6jue5AUYt56MbqopFv,EuBhpIhdLUh37zvuzrOA3t8HL2HBtlCw,3LSRoSaxM6YKIbhtx7RxaBpf,OOnBZYkw3kRrfGD8,ytWf,psUOt,+0izM,tF53Ovo+aqLG00zho+b,OnrcYC9y8,cv2tHyrFOPhJUFkk6KhecIHJDUKK,NnkQ2lQy","help":"网页版签名盐表（15 个，逗号分隔）；迅雷前端发版后可能需要更新"},
    \\  "captcha_token":  {"type":"string","default":"","secret":true,"help":"验证码 token，留空自动获取（有效期 300 秒，驱动会主动续）"},
    \\  "user_agent":     {"type":"string","default":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36","help":"网页版 UA"},
    \\  "space":          {"type":"string","default":"","help":"远程设备 ID，留空 = 个人云盘"},
    \\  "root_folder_id": {"type":"string","default":"","help":"根目录 ID，留空 = 网盘根"}
    \\}
    ,
    .create = createWeb,
};

fn create(alloc: std.mem.Allocator, storage_id: i64, cfg: ?*const json.Value) !driver.Driver {
    return driver.asDriver(Thunder, try createVariant(alloc, storage_id, cfg, .normal));
}

fn createExpert(alloc: std.mem.Allocator, storage_id: i64, cfg: ?*const json.Value) !driver.Driver {
    return driver.asDriver(Thunder, try createVariant(alloc, storage_id, cfg, .expert));
}

fn createWeb(alloc: std.mem.Allocator, storage_id: i64, cfg: ?*const json.Value) !driver.Driver {
    return driver.asDriver(Thunder, try createVariant(alloc, storage_id, cfg, .web));
}

fn createVariant(alloc: std.mem.Allocator, storage_id: i64, cfg: ?*const json.Value, variant: Variant) !*Thunder {
    const self = try alloc.create(Thunder);
    const jar = try alloc.create(cookiejar.Jar);
    jar.* = cookiejar.Jar.init(alloc);
    self.* = .{
        .alloc = alloc,
        .storage_id = storage_id,
        .variant = variant,
        .cfg = try Addition.parse(alloc, cfg, variant),
        .jar = jar,
        .client = httpclient.Client.init(alloc, .{}, jar),
    };
    return self;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "THU-1: GetAction mirrors Go's regex — path only, no query/fragment" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("POST:/v1/auth/signin/token", try getAction(a, "POST", ep_signin_token));
    try testing.expectEqualStrings("GET:/drive/v1/files", try getAction(a, "GET", "https://api-pan.xunlei.com/drive/v1/files?space=&limit=100"));
    try testing.expectEqualStrings("PATCH:/drive/v1/files/abc/trash", try getAction(a, "PATCH", "https://api-pan.xunlei.com/drive/v1/files/abc/trash?space=x"));
    try testing.expectEqualStrings("GET:", try getAction(a, "GET", "https://api-pan.xunlei.com"));
    // 带端口 / userinfo 的 host 不影响 path 提取
    try testing.expectEqualStrings("GET:/a/b", try getAction(a, "GET", "http://user@host:8080/a/b#frag"));
}

test "THU-2: gcid block size matches Go's calcBlockSize" {
    try testing.expectEqual(@as(i64, 0x40000), gcidBlockSize(0));
    try testing.expectEqual(@as(i64, 0x40000), gcidBlockSize(1));
    try testing.expectEqual(@as(i64, 0x40000), gcidBlockSize(0x40000 * 512));
    // 刚过 512 块就翻倍
    try testing.expectEqual(@as(i64, 0x80000), gcidBlockSize(0x40000 * 512 + 1));
    try testing.expectEqual(@as(i64, 0x100000), gcidBlockSize(0x80000 * 512 + 1));
    try testing.expectEqual(@as(i64, 0x200000), gcidBlockSize(0x100000 * 512 + 1));
    // 上限 2 MiB
    try testing.expectEqual(@as(i64, 0x200000), gcidBlockSize(1 << 40));
}

test "THU-3: computeGcid matches the Go/Python golden value (700000 bytes)" {
    // 期望值由 Python hashlib 独立算出（同一算法：分块 sha1 → 外层 sha1）。
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    const n = 700_000;
    const data = try a.alloc(u8, n);
    for (data, 0..) |*b, i| b.* = @truncate((i *% 31) +% 7);

    const Holder = struct { d: []const u8 };
    const vt = model.Source.VTable{
        .size = struct {
            fn f(p: *anyopaque) i64 {
                const s: *const Holder = @ptrCast(@alignCast(p));
                return @intCast(s.d.len);
            }
        }.f,
        .readAt = struct {
            fn f(p: *anyopaque, offset: u64, buf: []u8) anyerror!usize {
                const s: *const Holder = @ptrCast(@alignCast(p));
                if (offset >= s.d.len) return 0;
                const k = @min(buf.len, s.d.len - offset);
                @memcpy(buf[0..k], s.d[offset..][0..k]);
                return k;
            }
        }.f,
    };
    var holder = Holder{ .d = data };
    const src = model.Source{ .ptr = &holder, .vtable = &vt };

    var ctx = driver.Ctx{ .alloc = a };
    const got = try computeGcid(a, src, n, &ctx);
    try testing.expectEqualStrings("5dc3c1111f56c44b038515acbd16d0bd6dcfca91", got);

    // 空文件：外层 sha1 无输入 → sha1("")
    var empty = Holder{ .d = &.{} };
    const src0 = model.Source{ .ptr = &empty, .vtable = &vt };
    try testing.expectEqualStrings("da39a3ee5e6b4b0d3255bfef95601890afd80709", try computeGcid(a, src0, 0, &ctx));
}

test "THU-4: generateDeviceSign / captchaSignAt golden values" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const dev = "0123456789abcdef0123456789abcdef";
    try testing.expectEqualStrings(
        "div101.0123456789abcdef0123456789abcdef65a0eb042c2ee98a299fae0c79607fdd",
        try generateDeviceSign(a, dev, default_package_name),
    );
    const algs = [_][]const u8{ "9uJNVj/wLmdwKrJaVj/omlQ", "jKY0" };
    try testing.expectEqualStrings(
        "1.d231578d7c5d84ebd05ea64f80b6dbec",
        try captchaSignAt(a, default_client_id, default_client_version, default_package_name, dev, "1700000000000", &algs),
    );
}

test "THU-5: identity matches Go GetIdentity for both variants" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    var normal = Thunder{
        .alloc = a,
        .storage_id = 0,
        .variant = .normal,
        .cfg = .{ .username = "alice", .password = "secret" },
        .jar = undefined,
        .client = undefined,
    };
    try testing.expectEqualStrings("c4e31313222cf05fcdd1fc068af5570e", try normal.identity(a));

    var expert = Thunder{
        .alloc = a,
        .storage_id = 0,
        .variant = .expert,
        .cfg = .{
            .username = "alice",
            .password = "secret",
            .algorithms = "9uJNVj/wLmdwKrJaVj/omlQ,Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf",
            .device_id = "0123456789abcdef0123456789abcdef",
        },
        .jar = undefined,
        .client = undefined,
    };
    try testing.expectEqualStrings("aa90e77e175c5104029adf518e4d224b", try expert.identity(a));

    // login_type=refresh_token 时用 refresh_token 参与摘要
    expert.cfg.login_type = "refresh_token";
    expert.cfg.refresh_token = "RT";
    const id2 = try expert.identity(a);
    try testing.expect(!std.mem.eql(u8, id2, "aa90e77e175c5104029adf518e4d224b"));
}

test "THU-6: device id derivation — configured value wins, otherwise md5 of the variant's input" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    var normal = Thunder{
        .alloc = a,
        .storage_id = 0,
        .variant = .normal,
        .cfg = .{ .username = "alice", .password = "secret" },
        .jar = undefined,
        .client = undefined,
    };
    // md5("alicesecret")
    try testing.expectEqualStrings("c4e31313222cf05fcdd1fc068af5570e", try normal.computeDeviceId(a));

    var expert = Thunder{
        .alloc = a,
        .storage_id = 0,
        .variant = .expert,
        .cfg = .{},
        .jar = undefined,
        .client = undefined,
    };
    // expert 对空 device_id 做 md5 → md5("")
    try testing.expectEqualStrings("d41d8cd98f00b204e9800998ecf8427e", try expert.computeDeviceId(a));

    // 配置了就用配置值（两个变体都一样）
    normal.cfg.device_id = "0123456789abcdef0123456789abcdef";
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", try normal.computeDeviceId(a));
    expert.cfg.device_id = "0123456789abcdef0123456789abcdef";
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", try expert.computeDeviceId(a));
}

test "THU-7: Addition parses the Go addition shape and round-trips" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    // 用户 Go 备份里 Thunder 存储的 addition 形态
    const src =
        \\{"username":"13800138000","password":"pw","root_folder_id":"","device_id":"",
        \\ "captcha_token":"ct","credit_key":"ck","space":""}
    ;
    const v = try json.parse(a, src);
    const add = try Addition.parse(a, &v, .normal);
    try testing.expectEqualStrings("13800138000", add.username);
    try testing.expectEqualStrings("ct", add.captcha_token);
    // normal 变体不读 expert 键，且保持 Go 硬编码默认值
    try testing.expectEqualStrings(default_client_id, add.client_id);
    try testing.expectEqualStrings("user", add.login_type);

    const out = try add.toJson(a, false);
    const v2 = try json.parse(a, out);
    const add2 = try Addition.parse(a, &v2, .normal);
    try testing.expectEqualStrings(add.username, add2.username);
    try testing.expectEqualStrings(add.password, add2.password);
    try testing.expectEqualStrings(add.captcha_token, add2.captcha_token);
    // normal 的序列化里**不**出现 expert 键
    try testing.expect(std.mem.indexOf(u8, out, "login_type") == null);
    try testing.expect(std.mem.indexOf(u8, out, "client_id") == null);

    // expert：全字段往返
    const esrc =
        \\{"login_type":"refresh_token","sign_type":"captcha_sign","username":"u","password":"p",
        \\ "refresh_token":"RT","algorithms":"a,b","captcha_sign":"cs","timestamp":"1",
        \\ "captcha_token":"ct","credit_key":"ck","device_id":"d","client_id":"cid",
        \\ "client_secret":"csec","client_version":"v","package_name":"pkg",
        \\ "user_agent":"ua","download_user_agent":"dua","use_video_url":true,
        \\ "space":"sp","root_folder_id":"root"}
    ;
    const ev = try json.parse(a, esrc);
    const eadd = try Addition.parse(a, &ev, .expert);
    try testing.expectEqualStrings("refresh_token", eadd.login_type);
    try testing.expectEqualStrings("captcha_sign", eadd.sign_type);
    try testing.expectEqualStrings("RT", eadd.refresh_token);
    try testing.expectEqualStrings("a,b", eadd.algorithms);
    try testing.expect(eadd.use_video_url);
    const eout = try eadd.toJson(a, true);
    const ev2 = try json.parse(a, eout);
    const eadd2 = try Addition.parse(a, &ev2, .expert);
    try testing.expectEqualStrings(eadd.refresh_token, eadd2.refresh_token);
    try testing.expectEqualStrings(eadd.user_agent, eadd2.user_agent);
    try testing.expect(eadd2.use_video_url);
}

test "THU-8: Addition tolerates a missing/null addition" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const none = try Addition.parse(a, null, .expert);
    try testing.expectEqualStrings(default_client_version, none.client_version);
    try testing.expectEqualStrings(default_download_user_agent, none.download_user_agent);
    const nullv: json.Value = .null;
    const from_null = try Addition.parse(a, &nullv, .normal);
    try testing.expectEqualStrings("", from_null.username);
}

test "THU-9: ErrInfo mirrors Go ErrResp.IsError" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(!parseErrInfo(a, "{\"error\":\"success\"}").isSet());
    try testing.expect(!parseErrInfo(a, "{}").isSet());
    try testing.expect(!parseErrInfo(a, "<html>oops</html>").isSet());
    try testing.expect(parseErrInfo(a, "{\"error_code\":4122}").isSet());
    try testing.expect(parseErrInfo(a, "{\"error\":\"invalid_grant\"}").isSet());
    try testing.expect(parseErrInfo(a, "{\"error_description\":\"x\"}").isSet());
    // "success" 优先：即使同时带 error_code 也不算错误（Go 的第一条判断）
    try testing.expect(!parseErrInfo(a, "{\"error\":\"success\",\"error_code\":1}").isSet());

    const e = parseErrInfo(a, "{\"error_code\":9,\"error\":\"captcha_invalid\",\"error_description\":\"expired\"}");
    try testing.expectEqual(@as(i64, 9), e.code);
    try testing.expectEqualStrings("ErrorCode: 9 ,Error: captcha_invalid ,ErrorDescription: expired ", try errText(a, e));
}

test "THU-10: objFrom maps the Files JSON (string size, RFC3339 times, gcid hash)" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\{"kind":"drive#file","id":"F1","parent_id":"","name":"a.mkv","size":"1234",
        \\ "modified_time":"2026-10-19T12:34:56.789+08:00","created_time":"2026-10-18T00:00:00Z",
        \\ "thumbnail_link":"http://t","hash":"ABC","web_content_link":"http://d"}
    ;
    const v = try json.parse(a, src);
    const o = objFrom(&v);
    try testing.expectEqualStrings("a.mkv", o.name);
    try testing.expectEqual(@as(i64, 1234), o.size);
    try testing.expect(!o.is_dir);
    try testing.expectEqualStrings("F1", o.sign);
    try testing.expectEqualStrings("gcid", o.hash_info.?.hash_name);
    try testing.expectEqualStrings("ABC", o.hash_info.?.hash_value);
    // 2026-10-19T12:34:56+08:00 == 2026-10-19T04:34:56Z
    try testing.expectEqual(@as(i64, 1792384496), o.modified);
    try testing.expectEqual(@as(i64, 1792281600), o.created);

    const fsrc = \\{"kind":"drive#folder","id":"D1","name":"dir","size":"0"}
    ;
    const fv = try json.parse(a, fsrc);
    const fo = objFrom(&fv);
    try testing.expect(fo.is_dir);
    try testing.expect(fo.hash_info == null);
}

test "THU-11: trimLeftCutset replicates Go strings.TrimLeft cutset semantics" {
    // 典型迅雷 endpoint：bucket 前缀被当作字符集剥掉
    try testing.expectEqualStrings("oss-cn-shenzhen.aliyuncs.com", trimLeftCutset("xunlei-abc.oss-cn-shenzhen.aliyuncs.com", "xunlei-abc."));
    // 字符集语义：'x' 在集合里 → 连续剥离，直到遇到不在集合里的字符
    try testing.expectEqualStrings("yz", trimLeftCutset("xxxyz", "x"));
    try testing.expectEqualStrings("", trimLeftCutset("xxx", "x"));
    try testing.expectEqualStrings("abc", trimLeftCutset("abc", ""));
}

test "THU-12: s3Base builds the virtual-hosted URL the live API accepts" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    // 真机实测的原始参数（2026-10-20，tools/raw_put.py 打出）：
    //   bucket=vip-lixian-08  endpoint=vip-lixian-08.up.xdrive.xunlei.com
    // 正确 URL = https://vip-lixian-08.up.xdrive.xunlei.com/<key>（200）
    try testing.expectEqualStrings(
        "https://vip-lixian-08.up.xdrive.xunlei.com",
        try s3Base(a, "vip-lixian-08.up.xdrive.xunlei.com", "vip-lixian-08"),
    );
    // 带 scheme 的 endpoint 也要能处理
    try testing.expectEqualStrings(
        "https://b.oss.example.com",
        try s3Base(a, "http://b.oss.example.com/", "b"),
    );
    try testing.expectEqualStrings("vip-lixian-08.up.xdrive.xunlei.com", hostOf(try s3Base(a, "vip-lixian-08.up.xdrive.xunlei.com", "vip-lixian-08")));
    try testing.expectEqualStrings("oss.example.com", hostOf("https://oss.example.com/x/y"));
}

test "THU-13: path helpers split the target path the way put/mkdir need" {
    try testing.expectEqualStrings("a.mkv", pathBase("/dir/a.mkv").?);
    try testing.expectEqualStrings("dir", pathParent("/dir/a.mkv").?);
    try testing.expectEqualStrings("", pathParent("/a.mkv").?);
    try testing.expect(pathBase("/") == null);
    try testing.expect(pathBase("") == null);
    try testing.expectEqualStrings("a", pathBase("/x/y/a").?);
    try testing.expectEqualStrings("x/y", pathParent("/x/y/a").?);
}

test "THU-14: looksLikeEmail distinguishes account kinds the way Go's regex does" {
    try testing.expect(looksLikeEmail("a@b.com"));
    try testing.expect(looksLikeEmail("user.name+tag@sub.example.cn"));
    try testing.expect(!looksLikeEmail("13800138000"));
    try testing.expect(!looksLikeEmail("plainuser"));
    try testing.expect(!looksLikeEmail("@b.com"));
    try testing.expect(!looksLikeEmail("a@bcom"));
    try testing.expect(!looksLikeEmail(""));
}

test "THU-15: splitAlgorithms keeps Go's Split semantics for an empty string" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const one = try splitAlgorithms(a, "x,y,z");
    try testing.expectEqual(@as(usize, 3), one.len);
    try testing.expectEqualStrings("z", one[2]);
    // Go strings.Split("", ",") == [""] → 长度为 1，仍会算一次 md5
    const empty = try splitAlgorithms(a, "");
    try testing.expectEqual(@as(usize, 1), empty.len);
    try testing.expectEqualStrings("", empty[0]);
    const def = try splitAlgorithms(a, default_algorithms_str);
    try testing.expectEqual(default_algorithms.len, def.len);
    try testing.expectEqualStrings(default_algorithms[0], def[0]);
}

test "THU-16: batchBody shape matches Go's base.Json payload" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const body = try batchBody(a, "to", "PARENT", "ID", "");
    try testing.expectEqualStrings("{\"to\":{\"parent_id\":\"PARENT\"},\"ids\":[\"ID\"],\"space\":\"\"}", body);
}

test "THU-18: s3UriEncode keeps '/' but encodes everything else per SigV4" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    // 目录分隔符保留，空格/冒号/中文全部编码
    try testing.expectEqualStrings("a/b/c.bin", try s3UriEncode(a, "a/b/c.bin"));
    try testing.expectEqualStrings("a%20b/c", try s3UriEncode(a, "a b/c"));
    try testing.expectEqualStrings("a%3Ab", try s3UriEncode(a, "a:b"));
    try testing.expectEqualStrings("%E4%B8%AD/x", try s3UriEncode(a, "中/x"));
    // unreserved 字符原样保留
    try testing.expectEqualStrings("A-z_0.9~x", try s3UriEncode(a, "A-z_0.9~x"));
}

test "THU-19: sigV4 signs x-amz-security-token only when a session token exists" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    const base = SigCtx{
        .amz_date = "20261020T000000Z",
        .date_stamp = "20261020",
        .scope = "20261020/xunlei/s3/aws4_request",
        .host = "oss-cn-shenzhen.aliyuncs.com",
        .access_key = "AK",
        .secret_key = "SK",
        .session_token = "ST",
    };
    const with_tok = try sigV4(a, base, "PUT", "/b/k", "", &.{});
    try testing.expect(std.mem.indexOf(u8, with_tok, "SignedHeaders=host;x-amz-content-sha256;x-amz-date;x-amz-security-token") != null);
    try testing.expect(std.mem.startsWith(u8, with_tok, "AWS4-HMAC-SHA256 Credential=AK/20261020/xunlei/s3/aws4_request"));

    var no_tok_ctx = base;
    no_tok_ctx.session_token = "";
    const no_tok = try sigV4(a, no_tok_ctx, "PUT", "/b/k", "", &.{});
    try testing.expect(std.mem.indexOf(u8, no_tok, "SignedHeaders=host;x-amz-content-sha256;x-amz-date,") != null);
    try testing.expect(std.mem.indexOf(u8, no_tok, "x-amz-security-token") == null);
    // 令牌不同 ⇒ 签名必须不同（否则说明令牌没进规范请求）
    try testing.expect(!std.mem.eql(u8, with_tok, no_tok));

    const hl_tok = try authHeaders(a, base, with_tok);
    try testing.expectEqual(@as(usize, 4), hl_tok.len);
    const hl_no = try authHeaders(a, no_tok_ctx, no_tok);
    try testing.expectEqual(@as(usize, 3), hl_no.len);
    try testing.expectEqualStrings("Authorization", hl_no[2].name);
}

test "THU-21: all three addition_schema blobs are valid JSON (api.zig silently degrades to {} on failure)" {
    // `api.zig` 的 `writeDriverInfo` 是 `json.parse(...) catch .{ .object = .{} }`
    // —— schema 写坏了不会报错，只会让「添加存储」表单变成空白。手拼 JSON
    // 出过事（STATUS §31），所以三个 factory 的 schema 都钉住。
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    const normal = try json.parse(a, factory.addition_schema);
    const n_obj = normal.asObject() orelse return error.SchemaNotObject;
    try testing.expect(n_obj.get("username") != null);
    try testing.expect(n_obj.get("password") != null);
    try testing.expect(n_obj.get("root_folder_id") != null);
    // normal 变体**不**暴露 expert 的字段（否则表单会多出无效项）
    try testing.expect(n_obj.get("login_type") == null);

    const expert = try json.parse(a, expert_factory.addition_schema);
    const e_obj = expert.asObject() orelse return error.SchemaNotObject;
    try testing.expect(e_obj.get("login_type") != null);
    try testing.expect(e_obj.get("sign_type") != null);
    try testing.expect(e_obj.get("refresh_token") != null);
    try testing.expect(e_obj.get("algorithms") != null);
    // schema 的默认值必须与 Go 的 struct tag 默认值一致（前端会把它们写回
    // addition，空串会让签名/UA 失效）。
    try testing.expectEqualStrings("user", e_obj.get("login_type").?.strAt("default").?);
    try testing.expectEqualStrings("algorithms", e_obj.get("sign_type").?.strAt("default").?);
    try testing.expectEqualStrings(default_algorithms_str, e_obj.get("algorithms").?.strAt("default").?);
    try testing.expectEqualStrings(default_user_agent, e_obj.get("user_agent").?.strAt("default").?);
    try testing.expectEqualStrings(default_download_user_agent, e_obj.get("download_user_agent").?.strAt("default").?);
    try testing.expectEqualStrings(default_client_id, e_obj.get("client_id").?.strAt("default").?);

    // 网页版 schema：只暴露它自己那套字段，且默认值必须是网页客户端的。
    const web = try json.parse(a, web_factory.addition_schema);
    const w_obj = web.asObject() orelse return error.SchemaNotObject;
    try testing.expect(w_obj.get("refresh_token") != null);
    try testing.expect(w_obj.get("algorithms") != null);
    // 网页版现在也要账号密码（用于自动续期），但**没有** login_type：
    // 它的登录方式由变体决定，不给用户切换的余地。
    try testing.expect(w_obj.get("username") != null);
    try testing.expect(w_obj.get("password") != null);
    try testing.expect(w_obj.get("login_type") == null);
    try testing.expectEqualStrings(web_client_id, w_obj.get("client_id").?.strAt("default").?);
    try testing.expectEqualStrings(web_package_name, w_obj.get("package_name").?.strAt("default").?);
    try testing.expectEqualStrings(web_algorithms_str, w_obj.get("algorithms").?.strAt("default").?);
}

test "THU-20: factory keys are byte-identical to Go's Config.Name" {
    try testing.expectEqualStrings("Thunder", factory.key);
    try testing.expectEqualStrings("ThunderExpert", expert_factory.key);
    // 注册名与 Go 一致：没有任何别名
    try testing.expect(!std.mem.eql(u8, factory.key, expert_factory.key));
    // ThunderWeb 是本工程新增（上游没有对应 Go 驱动），key 由我们定，
    // 但同样必须是纯 ASCII 且不与前两个冲突。
    try testing.expectEqualStrings("ThunderWeb", web_factory.key);
    try testing.expect(!std.mem.eql(u8, web_factory.key, factory.key));
    try testing.expect(!std.mem.eql(u8, web_factory.key, expert_factory.key));
}

test "THU-22: web captcha sign reproduces the browser-captured golden vector" {
    // 黄金对来自浏览器 2026-10-20 18:19 的真实请求，并且已在服务端换到
    // captcha_token（docs §3.4）。这条测试是网页版驱动的地基：
    // 盐表、盐顺序、拼接方式、base 组成 —— 任一改动都会让它红。
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const sign = try captchaSignAt(
        a,
        web_client_id,
        web_client_version,
        web_package_name,
        "28419a6fe0b7e47c355bbd8a95777fef",
        "1792491447693",
        &web_algorithms,
    );
    try testing.expectEqualStrings("1.68270948a01b031830b45681bb1da55f", sign);
}

test "THU-23: web salt table string and array are the same 15 salts in the same order" {
    // `Addition.algorithms` 是逗号分隔的字符串（要能存进 config.json），
    // 而 `web_algorithms` 是数组（单测和默认值用）。两者漂移过一次就会
    // 让「配置里看着对、签名却错」这种最难查的 bug 出现。
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try splitAlgorithms(a, web_algorithms_str);
    try testing.expectEqual(web_algorithms.len, parsed.len);
    try testing.expectEqual(@as(usize, 15), parsed.len);
    for (web_algorithms, parsed) |want, got| {
        try testing.expectEqualStrings(want, got);
        // 盐里不能有逗号，否则 split 会切错（前端给的盐是 base64 字母表 + 少量符号）
        try testing.expect(std.mem.indexOfScalar(u8, want, ',') == null);
    }
}

test "THU-24: web addition defaults point at the web client, not the android one" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();

    const web = try Addition.parse(a, null, .web);
    try testing.expectEqualStrings(web_client_id, web.client_id);
    try testing.expectEqualStrings(web_client_version, web.client_version);
    try testing.expectEqualStrings(web_package_name, web.package_name);
    try testing.expectEqualStrings(web_algorithms_str, web.algorithms);
    // 网页版没有账号密码体系 ⇒ 默认只能是 refresh_token
    try testing.expectEqualStrings("refresh_token", web.login_type);
    // 安卓的 cid 绝不能漏到网页版（会 invalid_grant）
    try testing.expect(!std.mem.eql(u8, web.client_id, default_client_id));

    // 显式配置覆盖默认值
    const v = try json.parse(a,
        \\{"refresh_token":"a1.xxx","client_version":"1.99.0","device_id":"00112233445566778899aabbccddeeff"}
    );
    const custom = try Addition.parse(a, &v, .web);
    try testing.expectEqualStrings("a1.xxx", custom.refresh_token);
    try testing.expectEqualStrings("1.99.0", custom.client_version);
    try testing.expectEqualStrings("00112233445566778899aabbccddeeff", custom.device_id);
    try testing.expectEqualStrings(web_client_id, custom.client_id); // 未给 ⇒ 仍是网页默认
}

test "THU-25: generated web device id is 32 lowercase hex chars" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const id = try randomHex32(a);
    try testing.expectEqual(@as(usize, 32), id.len);
    for (id) |c| try testing.expect(std.ascii.isHex(c) and !std.ascii.isUpper(c));
    // 两次生成不应相同（CSPRNG）
    const id2 = try randomHex32(a);
    try testing.expect(!std.mem.eql(u8, id, id2));
}

test "THU-26: PKCE S256 challenge matches RFC 7636's reference vector" {
    // RFC 7636 附录 B 的官方例子：verifier → challenge。
    // 这条测试保证网页登录第 3 步算出来的 code_challenge 是对的，
    // 否则 /v1/user/authorize 会直接拒。
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    try testing.expectEqualStrings(
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        try pkceChallenge(a, verifier),
    );
    // 长度必须 43（32 字节 sha256 → base64url 无填充）
    try testing.expectEqual(@as(usize, 43), (try pkceChallenge(a, verifier)).len);
}

test "THU-27: webUsername normalizes phone numbers the way /v1/auth/signin wants" {
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    // 11 位纯数字 ⇒ "+86 号码"（抓包实测的形态，带空格）
    try testing.expectEqualStrings("+86 18616132763", try webUsername(a, "18616132763"));
    try testing.expectEqualStrings("+86 18616132763", try webUsername(a, " 18616132763 "));
    // 已带国家码 / 邮箱 / 用户名 ⇒ 原样
    try testing.expectEqualStrings("+86 18616132763", try webUsername(a, "+86 18616132763"));
    try testing.expectEqualStrings("a@b.com", try webUsername(a, "a@b.com"));
    try testing.expectEqualStrings("alice", try webUsername(a, "alice"));
    // 非 11 位数字不硬加国家码
    try testing.expectEqualStrings("12345", try webUsername(a, "12345"));
}

test "THU-28: web login refuses to run without credentials instead of looping" {
    // 既没 refresh_token 也没账号密码时，必须直接报错（而不是反复打空请求
    // 把账号打进限频）。
    var arena = testArena();
    defer arena.deinit();
    const a = arena.allocator();
    var self = Thunder{
        .alloc = a,
        .storage_id = 0,
        .variant = .web,
        .cfg = .{},
        .jar = undefined,
        .client = undefined,
    };
    var ed: ?[]const u8 = null;
    try testing.expectError(Error.AuthFailed, self.webLoginOrRefresh(a, &ed));
    try testing.expect(ed != null and ed.?.len > 0);
}
