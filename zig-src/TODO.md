# TODO — openlist-zig 待办清单

> 最后更新：2026-10-30（网页端上传 network error 根因 = `multipart_enabled` 撒谎，
> 已改 false 并部署；新增请求体安全阀 `zig.max_upload_mb`（默认 64 MiB）与
> `/api/*` 未注册路径 501 JSON 兜底，见 STATUS §55/§56。
> **下一轮主项 = §5.5 分片直传**）
>
> 上一版：2026-10-18（审计修复两轮全部收官：§37.4 剩余项 + P3 + N1 落地，
> 构建 400/400、真机 e2e 92/92，审计文档整合进 docs/，见 STATUS.md §38）
> **完成度**：P0 端点已补、功能边界已定案、驱动名/操作集对齐已复查、Go 配置导入工具已重写、
> Quark 下载 502 真根因已修（`Link.header` 悬垂栈指针，见 STATUS.md §30）、
> 上游错误 message 透传已落地（quarkuc 全链路，见 §31.9）、
> 路径语义已对齐 Go `JoinBasePath`（§32）、
> **下载响应头 / API 信封 / WebDAV 三块已对 Go 源码逐行对账并动态对照**（§35）、
> **全驱动真实 API 回归 + 边界/稳定性 + UI 回归全绿**
> （10 挂载点 e2e，见 §31/§32/§35；唯一跳过 = 坚果云根级目录禁止 API 删除，
> 服务商规则，需 WEB 手动删）。
> **115 上传链路两个真 bug 已修**（getOssToken 键名大小写 + listPage 悬垂指针，
> 见 STATUS.md §41）：上传/列目录/copy/WebDAV 全链真机通过，产物
> cd228d85…；115 直链被上游 CDN 拒签（403 invalid signature，§41.4）与
> koofr GET 目录瞬时 404（§41.5）均已定性为上游行为、Go 同构。
> **卡住的一件事**：189Cloud（web 驱动）卡账号侧二次验证；UC/115/WoPan/Thunder 缺凭据。
>
> **§35 立下的规矩（这轮最大的教训）**：协议细节**不能凭"实测感觉"**判未对齐
> —— 上游源码是唯一事实来源，且必须落到函数与行号。本轮之前凭一次"PUT 也
> 是 200"的实测把 Go 的 NoRoute 405 判成了未对齐，源码一读就翻案。
>
> 完整背景见 `docs/STATUS.md`（§20–§32 是近两轮新增）。项目铁律见下文 §7。
>
> **2026-10-18 驱动维度全量对账完成** → `docs/AUDIT_2026-10-18-drivers.md`
> （11 个驱动逐个 Go↔Zig 三分法对账；**P0 两个真 bug 已修**：local put 进度传
> 字节、cloud189 fs/get size 恒 0；**P1 已落地 8 项**：pan115 动态 appver +
> OSS 分片重试、189pc 分片重试、pan123 err_detail、webdav PUT Content-Type、
> err_detail 铺开到 8 驱动、**reset_token 端点 + 签名密钥对齐 Go（token 而非
> jwt_secret）**；**文档漂移 11 处清零** —— 411/411 单测 + 真机 e2e 464/0/1，
> 详见 STATUS §42/§43/§44/§45；
> P1 剩余：SharePoint、189pc family_transfer/old 上传/torrent、local 缩略图、
> aliyun Other；`fs/form` 与 `archive/meta` 有明确不做理由（STATUS §45.3）。）

---

## 0. 已完成（不用重做）

| 项 | 状态 | 落在哪 |
|---|---|---|
| 补 `/api/me/update`（改密码/改用户名） | ✅ 361→364 单测，真机验证 | `src/api.zig` `handleMeUpdate` |
| 补 `/api/auth/logout` | ✅ 真机验证 | `src/api.zig` `handleLogout` |
| 修 `/api/me` 的 `permission` 硬编码 0 → `0x71FF` | ✅ 真机 `permission: 29183` | `src/api.zig` `App.admin_permission` |
| 修 `/api/me` 缺 `sso_id`/`allow_ldap`/`otp`、多出 `otp_secret`/`token` | ✅ | `src/api.zig` `handleMe` |
| 审核并修 `admin/storage/*` 四处问题 | ✅ 13/13 真机回归 | STATUS.md §20 |
| 功能边界定案（删减 vs 新增） | ✅ 文档化 | STATUS.md §22 |
| 驱动名铁律复查 11/11 | ✅ 逐字节对齐 | STATUS.md §26.1 |
| 驱动操作集复查 | ✅ 与上游 NotSupport 一致 | STATUS.md §26.1 |
| 重写 `tools/import_go_config.py` | ✅ 无损版 | 见 §4 |
| Playwright 前端自动化 | ✅ 跑通（playwright-core + 系统 Chrome） | 见 §6 |
| 迅雷云盘驱动（`Thunder` + `ThunderExpert`） | ✅ 2026-10-20 移植 + **真机**（e2e 62/63，分片上传通；431/431 单测） | STATUS.md §48 |
| 三个"待验证"变体收尾（`123 Open` / `QuarkOpen` / `115 Open`） | ✅ 2026-10-22 编译期可选注册（`opted()`）+ 补 copy 槽位 + **真机抓出 2 个契约 bug**（115 Open 的 schema 键名、5 驱动 16 处 select options 写错）；451/451 单测、真机 27/27 + 14/14 | STATUS.md §53 |

---

## 1. 【已解决 2026-10-16】Quark 驱动 init 失败（TlsInitializationFailed）

**原现象**

```
[ERROR] storage #8 Quark: init failed: TlsInitializationFailed — marking as errored
```

**真根因（§"设备 CA 缺 GlobalSign"是错的，grep PEM 证明不了任何事）**

1. 同设备 Go 实例 `/quark` 正常（`success load storage: [/quark]`，且 Go 开着证书校验）⇒ Zig 侧问题。
2. 设备 CA 库**有** GlobalSign R46 根：quark 的 ECDSA 链 `openssl verify -CAfile` 设备 bundle → OK。
3. **quark 的 TLS 终结者 ECDHE-RSA 路径是坏的**：RSA 套件下服务器发完 RSA 证书链就在 ServerKeyExchange 处 `fatal internal_error(80)`。用 OpenSSL 的完整 ClientHello + RSA-only 套件复现了同样失败 —— 与客户端实现无关。
4. **Zig 0.17.0 std 只提供 ECDHE-RSA 套件**（`Client.zig` 的 `cipher_suites` 硬编码，无开关），永远走不了服务器唯一可用的 ECDSA 路径。

**修复**：`tools/ziglib_patch.py` 在工作区内给 std 副本打补丁（offer 列表两个 comptime 分支追加 c02b/c02c/cca9；ServerHello 两个 switch 补 ECDSA 分支），`build_remote.py` 构建时以 `ZIG_LIB_DIR` 指向它。工具链本体 `/root/.cache` 保持只读。

**验证**：构建机探针 `HANDSHAKE OK version=tls_1_2`；真机挂载成功，`/api/fs/list /quark` 返回 16 条真实条目。完整证据链见 `docs/STATUS.md` §28。

**顺带修了两个 e2e 回归抓出的 bug**（详见 STATUS.md §28.3）：
- `web_proxy` 未实现 → 夸克下载 403（CDN `require login`）：模型/配置/导入工具/admin API/`handleDownload` 全线补齐。
- WebDAV Basic 认证算法错误（`sha256(明文)` vs `TwoHashPwd`）→ 恒 401：改用 `api.twoHashPwd`。

**相关文件**：`tools/ziglib_patch.py`（新）、`tools/build_remote.py`、`src/model.zig`、`src/config.zig`、`src/api.zig`、`src/webdav.zig`、`tools/import_go_config.py`

---

## 1.5 【已解决 2026-10-16 深夜】Quark 下载 502（真根因：Link.header 悬垂栈指针）

**原现象**：`/d/quark/...` 代理回源 502，日志
`client: GET https://dl-pc-zb... sendBodiless failed: WriteFailed`。

**真根因**：`quarkuc.zig` 的 `link()` 用
`return .{ .header = &[_]model.Header{...} }` 返回**函数栈帧里的临时数组**。
返回后该内存失效，代理回源读到栈残留（slice len 是 16MB 级垃圾），TLS 层把它
按 16KB 上限切成 `len=16408` 的畸形记录，CDN 回 alert → WriteFailed。
（`quark.zig` 的 `linkResult()` 早修过并留了注释，quarkuc 当时漏了。）

**证据链**（详见 STATUS.md §30）：阶段日志定位到写入 → 设备本机 curl 403 正常
打脸「CDN 静默」假说 → probe3/4 复刻 std.http.Client 6/6 成功 → Zig 临时数组
返回语义实验 `BAD=8/8` 悬垂实锤 → ppp0 抓包看到 16408B 畸形记录 + curl 对照。

**修复**：
- `quarkuc.zig`：拆 `linkResult()` 纯函数 + `alloc.alloc(model.Header, 3)`；
- `pan123.zig:649`：同款（第二跳 Referer）同款修复；
- `api.zig`：上游非 2xx 改为**原样透传**（对齐 Go `common.Proxy`），不再改写 502；
- 防回归单测 + 探针双层 flush 修复（`https_probe*.zig`）。

**验证完成（2026-10-16 深夜）**：新二进制部署后 `/d/quark/sn.img` → **200 + 5386
字节**；Range 206 + `Content-Range`；篡改 sign 401。阶段日志闭环
`connected → sending → sent → got head, status=200`。

**用户侧待办（作废）**：无需重新登录夸克 —— 设备上的 cookie 一直有效
（`__puus=099db75f`，用户已更新过）；之前的 403 是本机调试脚本读了**旧副本**
（`__puus=85c0fddb`）造成的假象，见 STATUS.md §30.5。调试脚本已改成从设备实时
读 cookie（`tools/device_cookie.py`）。

---

## 2. 【已完成 2026-10-16 深夜】全驱动真实 API + UI 回归测试（Task 19）

**结果**：9 挂载点 e2e **165 通过 / 0 失败 / 1 跳过** + UI smoke **11/11**，
完整报告见 STATUS.md §31。（原始日志目录 `docs/regression/` 已于 2026-10-20 清理，结论全部保留在 STATUS.md）
（唯一跳过 = jianguo 临时目录删不掉，服务商规则，非实现问题。）

**quark 按用户 2026-10-16 的要求改「读取 + 删除」回归**（容量满，添加暂不测）：
- 读取：list + **定向下载** `sn.img`（`--extra-download quark`，200/5386 字节
  + Range 206 + 篡改 sign 401）；
- 删除：mkdir 临时目录 → 等可见 → remove → 生效（建目录不占容量）；
- 不测上传：e2e 里的 `NO_PUT_MOUNTS`，**容量恢复后清空该集合即恢复全量写测**。

| mount | driver | init | 文件级写（put/rename/move/remove） | copy | 备注 |
|---|---|---|---|---|---|
| /quark | Quark | ✅（TLS 补丁后） | **按「读取+删除」回归**（容量满，添加暂不测） | 501 NotSupport ✅ | **账号容量满**（32003）；容量恢复后清 `NO_PUT_MOUNTS` 恢复写测 |
| /ecloud_self | 189CloudPC | ✅ | ✅ | ✅ 200 | copy 需等目录可见（190 一致性） |
| /itvsh | Itvsh | ✅ **首次真机** | ✅ | 501 NotSupport ✅ | 账密登录路径验证通过 |
| /koofr | WebDav | ✅ | ✅ | ✅ 200 | |
| /123_2763、/123_5137 | 123Pan | ✅ | ✅ | 501 NotSupport ✅ | |
| /aliyun | AliyundriveOpen | ✅（token 自动刷新） | ✅ | ✅ 200 | |
| /hikvision | Local | ✅ | ✅ | ✅ 200 | root 指向 /tmp/olz/hikvision |
| /jianguo | WebDav | ✅ | ✅ | ✅ 200 | 残留 2 个临时目录待 WEB 手动删 |

**同轮固化的工具**：
- `tools/merge_import.py`（新）—— 备份存储增量合并进现役配置（防凭据回退）
- `tools/deploy_device.py --keep-config`（新选项）—— restart 不再重写 cfg.json
- `tools/ui_smoke.js`（新）—— Playwright UI 回归（9 断言）
- `tools/e2e_test.py` —— 新增 copy 断言（支持组 200/源保留；NotSupport 组 501）、
  mkdir 后一致性等待、上游容量限制识别（SKIP 不级联）

**用户侧事项**：
- jianguo 需 WEB 手动删 5 个临时目录（`/jianguo/` 根下）：
  `olz-e2e-1792160579`、`olz-e2e-1792161053`、`olz-e2e-1792161964`、
  `olz-e2e-1792165484`、`olz-e2e-1792166633`；
- quark 容量满：清理空间后上传即可恢复 —— 届时把 e2e 的 `NO_PUT_MOUNTS`
  清空，写测自动覆盖上传。

---

## 3. 【暂缓，用户 2026-10-16 明确：暂时不需要移植】BaiduNetdisk / Onedrive

**当前状态：不做。** 用户已明确"暂时不需要移植"，从待办移到暂缓。

留个记录以便日后重启这个话题：

- Go 树里都有：`drivers/baidu_netdisk`、`drivers/onedrive`
- 备份里 `/baidu`（BaiduNetdisk）是 `disabled: false` —— **用户实际在用的**；
  `/onedrive` 是 disabled 的
- 所以导入这份配置后，`/baidu` 会 init 失败（`no driver named: BaiduNetdisk`），
  `/onedrive` 无所谓 —— **这是预期行为，不是 bug**
- 日后要做的话，唯一信号是用户说"百度网盘也要"

**相关**：`UNSUPPORTED` 表在 `tools/import_go_config.py` 里已写了这两个的理由
（"未移植（Go 树里有 drivers/xxx）"），导入时会明确报告而不是静默丢弃。

---

## 4. 导入工具用法（已重写）

```bash
python tools/import_go_config.py <backup.json> <out_config.json> \
    [--go-config <go config.json>] [--port 15399] [--temp-dir /tmp/olz/temp] \
    [--only id,id,...] [--include-disabled]
```

改了什么：
- **驱动名原样搬**（Zig `factory.key` 逐字节 == Go `Config.Name`，旧的映射表是多余的）
- **迁移 settings**：site_title/logo/favicon/main_color/customize_head/body/sign_all/link_expiration → `zig.*`
- **迁移 admin**：username + permission（**密码哈希迁移不了**，见下）
- **明确报告**跳过的驱动（含理由）与未实现的 setting（80 项）

**已知限制**：Go 的 `PwdHash`/`Salt`/`PwdTS` 都是 `json:"-"`，导出里根本没有 →
**密码无法迁移**，首次启动要用 `openlist admin set <密码>` 或 setup 页面设。

**⚠ 未传 `--go-config` 时 `jwt_secret` 为空**（重启会重新生成）、`cdn` 为空
（Zig 版前端走 CDN，**cdn 空了前端就是占位页**，测试前记得配）。

---

## 5. 已知待办小项

- ~~**上游错误 message 不透传**~~ ✅ **已修 2026-10-16 深夜**（全驱动回归发现）：
  机制 = `driver.Ctx.err_detail: ?[]const u8`（**值语义**，Ctx 活在请求栈帧上 →
  请求级、无并发串台，handler 不用开槽）+ `mapDriverError` 的**上游类**分支
  优先用它当 message；驱动内辅助函数收 `&ctx.err_detail` 写回。
  quarkuc（`Quark`，用户实际变体）全链路接入；真机验证上传撞容量时响应
  `"capacity limit[{0}]"`（与 Go 一致）。构建 371/371。详见 STATUS §31.9。
  （状态码**保持** 502 的既有细粒度映射，未改成 Go 的 500 —— 既有设计取舍。）
- ~~**`err_detail` 逐驱动接入（进行中）**~~ ✅ **已完成 2026-10-18**：8 个驱动
  全链接入 —— quarkuc / quark / itvsh / pan115 / **cloud189 / cloud189pc /
  aliyundrive / wopan**（后四个见 STATUS §44）。**worker 线程与上传链一律传
  null**（跨线程写请求线程栈上的字段是数据竞争）；local（OS 错误）、strm
  （无上游）、webdav（只有 HTTP 状态码）不适用。
- ~~**驱动覆盖收官（2026-10-17）**~~ ✅ **12/12 已真机覆盖**（2026-10-17 收官，
  见 STATUS §36A/§36B.5）：UC 全矩阵通过、115 Cloud 写入/mkdir/上传通过、
  WoPan 四连修后 20MB 分片 md5 全链一致。`tools/driver_matrix.py` 仍作为
  「无凭据回归」（注册表/表单/哑凭据添加闭环）保留。**顺带修出两个真 bug**：
  query 参数未解码（`115 Cloud` 与当时 itvsh 的中文名 表单恒 404）、
  189 驱动对非 JSON 响应静默吞掉。
- ~~**下载响应头遗留**~~ ✅ **已修 2026-10-17（见 STATUS §35，用户实测驱动）**
  `attachHeader` 的 `Etag`/`Last-Modified`、条件请求（304/412/`If-Range`）、
  Range（206+416 带 `bytes */total`）、透明代理头透传、`canProxy`（含
  `text_types` 与 `use_proxy_url`）的 403、`webdav_policy` 三策略全部补齐。
  同一轮还把 **API 信封（业务错误 HTTP 恒 200）**、**NoRoute 405**、
  **WebDAV 全套协议语义**逐条对齐。单测 **385/385**；WebDAV 动态对照（光猫本机
  loopback，`tools/dav_compare.py`）与生产 Go 实例 OPTIONS/401 **逐头相等**；
  e2e **342/0/2**（10 挂载 + 云盘写，2 跳过都是服务商规则），UI **11/11**。
  - ⚠ 两条分支的语义**必须分开记**，别再混为一谈：
    **本地/内存分支** = `net.ServeHTTP`（本端切 Range、合成 416、发 Etag、
    跑条件请求）；**远程直链分支** = `common.Proxy` 透明代理（Range 原样转发
    给上游，上游回 200 就是 200，**不切片、不合成 416、不补 Accept-Ranges**）。
  - 留：**跨存储 MOVE 502 / 目录 COPY 501 / LOCK 405 / SSRF 仅字面量**
    （各有理由，见 STATUS §35.5）。
- ~~`model.Storage` 无 `modified` 字段~~ ✅ **已完成 2026-10-16 深夜**：
  `modified: i64`（Unix 秒）入模型；创建/更新时置 `time.Now()`（对齐 Go
  `op.CreateStorage`/`op.UpdateStorage`）；配置解析（RFC3339 带偏移/纳秒 → 秒）
  与序列化（回 RFC3339，零值 = `0001-01-01T00:00:00Z`）双向往返；admin API 回真值；
  导入工具原样搬运 Go 备份里的 `modified`。单测 3 个（解析/往返/落盘）。
- ~~纯配置项未读：`delayed_start` / `cors` / `tasks`~~ ✅ **已处理 2026-10-16**：
  * `delayed_start`：启动时日志 + `std.Io.sleep`（对齐 Go `run.go:88-90`）；
  * `cors`：`cors.allow_origins/methods/headers` 入配置，`setCors` 按配置输出
    （默认 `["*"]` 维持原通配行为；显式列表 → origin 命中回显 + `Vary: Origin`，
    method/header 逗号 join）；
  * `tasks`：**刻意不建模** —— 本构建无任务系统（离线下载/转存 worker 池），
    读了无处用；`root` 保留原始文档，save 时其余键原样带回，字段不会丢
    （已在 config.zig 写注释说明，属合理子集）。
- **三个编译期可选变体缺真实凭据（2026-10-22 记）**：`123 Open`（开发者
  ClientID/Secret 或 renewapi token）、`QuarkOpen`（refresh_token + sign_key）、
  `115 Open`（access/refresh_token）。当前真机只到「注册表 + 表单 + 哑凭据
  闭环」；拿到凭据后按 `driver_matrix.py --only ...` 挂真实存储补全
  list/下载/上传/删除矩阵（流程同 §36）。构建方式见 STATUS.md §53.5。
- ✅ **审计修复两轮全部收官（2026-10-18，见 STATUS §37/§38）**：
  §37.4 的未做项（M2 115 link header / M3 189pc 并发上传 / M4 UC 转码判据 /
  M6 itvsh 分片重试 / M13–M15/M17 api 四项 / P3 全部 / N1 匿名浏览）
  **全部落地**，构建 **400/400**、真机 e2e **92/92**、定向下载 quark 200 +
  wo 302 透传。M3 采 per-worker Client 并发（并发度按配置×片数×32 MiB
  内存三元夹取）；N1 为 `zig.guest_browse` opt-in（默认关闭）。
  **⚠ 时序陷阱（新）**：`deploy_device.py restart` 返回后存储 init 还要
  数秒~数十秒，**立刻跑 e2e 会空挂载假失败** —— e2e 已加「0.5 等待存储
  初始化」轮询；另两处脚本加固：禁系统代理（跟随 /d/ 302 时会崩）、
  下载断言改第一跳（200 正文 / 302 校验 Location）。
  审计与复核文档已收敛到 `zig-src/docs/AUDIT_2026-10-18-drivers.md`（权威）+
  `docs/STATUS.md`（状态与编年日志）；更早的 6 份审计与 `outputs/` 原稿已于
  2026-10-18 清理，需要时从 git 历史取回（`git show 7356589e:<path>`）。

---

## 5.5 【✅ 已完成 2026-10-30 晚】分片直传（网页端大文件上传的正解）

> **已实现并部署真机**（STATUS §57）：189pc 直传（本地零落盘）+ 全驱动通用回退
> （分片落 temp_dir 稀疏文件）。真机 25 MiB 乱序 3 片 + 11 MiB 下载回源 MD5 一致。
> 单测 466 pass + 3 skip。`multipart_enabled` 已翻回 `true`。

**背景**：`multipart_enabled` 已关（STATUS §55），网页端上传全走 `PUT /api/fs/put`，
受 `zig.max_upload_mb`（默认 64 MiB，2026-10-30 新增的安全阀）限制。光猫 tmpfs
只有 220 MB 且占 RAM，"整份落盘再交给驱动"的路永远走不通 —— 要支持大文件，
必须**分片直传驱动**：分片字节由前端逐片送来，服务端不落盘。

**接口（对齐 4.2.6 前端 `Upload-*.js` 的实际调用，逐条实测过）**：

| 端点 | 前端行为 |
|---|---|
| `POST /api/fs/multipart/init`（头：`File-Path`/`X-File-Size`/`X-Chunk-Size`/`Last-Modified`） | 失败重试 3 次（1s/2s）后抛 `multipart init failed: network error`；响应 `data{upload_id, chunk_size, total_chunks, state, received[], received_bytes}` |
| `PUT /api/fs/multipart/chunk`（头：`X-Upload-Id`/`X-Chunk-Index`，body=分片字节） | 并发 3；响应 code 429/409 可重试，其他非 200 抛错；`X()` 只认 `{code:number,data}` |
| `POST /api/fs/multipart/complete`（头：`X-Upload-Id`） | 发出后轮询 status 直到 `state==="completed"` |
| `GET /api/fs/multipart/status?upload_id=` | `data.state`: `receiving`/`completed`/`failed*` |
| `POST /api/fs/multipart/abort` | 前端 4.2.6 未调用，可后置 |

**设计要点**：

1. **服务端不落盘**。每片的 MD5 在内存片上现算；189 的 commit 需要
   `fileMd5`（整文件）与 `sliceMd5`（各片 MD5 大写 hex 用 `\n` 连接后再 MD5），
   两者都能增量算（`hash.Md5Stream` 边喂边更）—— complete 时就绪，不需要再读文件。
2. **驱动要新增可选槽位**（vtable 可选项，参照 `copy` 的先例）：
   `beginUpload(dir,name,size,chunk_size) → session` / `putChunk(session, part_no, md5_b64, bytes)` /
   `commitUpload(session, file_md5, slice_md5)`。189/189pc 直接映射到
   `initMultiUpload` / `getMultiUploadUrls+PUT`（复用 `putPartRaw` 的重试）/
   `commitMultiUploadFile`。其他驱动先回 501 "driver does not support chunked upload"。
3. **session = App 级内存 map**（upload_id → 会话），30 min 过期清理；
   进程重启丢会话 ⇒ 前端重新 init（received 空），无需持久化。
4. **与安全阀的关系**：chunk PUT 本身 = chunk_size（默认 10 MiB）<
   `max_upload_mb`，不受影响；`fs/put` 与 WebDAV 大文件仍被 64 MiB 拦住。
5. **验收**：网页端传 1 GB 到 `/ecloud_self` 成功；服务端 RSS 峰值 < 60 MB；
   `zig build test` 全绿 + 真机 e2e；`multipart_enabled` 翻回 `true`
   （要同步改 `public_setting_defaults` 的注释与钉住它的单测）。

预估 1–2 天。**动工前先读一遍 4.2.6 `Upload-legacy-Cl_JVVnw.js` 的 `Z()`/`E()`/
`X()`**（本地缓存 `/tmp/fe/all/`，或从 npmmirror 重下）。

---

## 6. 环境速查

**测试机（光猫，SSH 192.168.1.1:10022，root / （口令见 ~/.olz_root_pwd））**
- 测试实例：`/tmp/olz`（tmpfs，重启即失），端口 15399
- **生产 Go 实例**：`/opt/sq/openlist/openlist` + `/opt/armbian/bin/openlist/config.json`
  ⚠ **绝不能碰**（2026-10-15 误杀过一次，见 STATUS.md 事故记录）

**本机**
- **本机有 Zig 0.17.0 了（2026-10-22 起）**：`C:\Program Files\zig-x86_64-windows-0.17.0\zig.exe`，
  产物与打包机**逐字节相同**（见 STATUS §54.1）。跑法：
  ```bash
  cd zig-src
  python tools/ziglib_patch.py "C:/Program Files/zig-x86_64-windows-0.17.0/lib" C:/zigcache/olz-ziglib
  ZIG_LIB_DIR=C:/zigcache/olz-ziglib ZIG_GLOBAL_CACHE_DIR=C:/zigcache/olz \
  ZIG_LOCAL_CACHE_DIR=C:/zigcache/olz "C:/Program Files/zig-x86_64-windows-0.17.0/zig.exe" build test --summary all
  ```
  ⚠ `--zig-lib-dir` 不是 `zig build` 的参数（用 `ZIG_LIB_DIR`）；本机 3 条 Linux-only 用例会 skip
- 也可以走打包机：`python tools/build_remote.py`（10.0.0.4，约 3–4.5 分钟，test+交叉编译+取回一条龙）
  ⚠ `zig build` 会吞掉 "All N tests passed."，判成功看 `--summary all` 里的 `test success`
- 部署：`python tools/deploy_device.py start|status|stop|restart [--port 15399]`
  ⚠⚠ **`start`/`restart` 默认会用内置模板重写 `/tmp/olz/cfg.json`（storages 清空）**！
  要保留手工配置的存储跑回归，必须加 `--keep-config`（要求 cfg.json 已存在；
  2026-10-16 踩坑：一次 restart 抹掉 9 存储配置，表现为 `no usable storages
  configured` + 0 mount published）。
- 合并 Go 备份的存储进现役配置：`python tools/merge_import.py <backup.json>
  <base_cfg.json> <out.json> [--only 1,2,3]`（设备版为准、防凭据回退、默认启用）
- 忘密码：`cd /tmp/olz && ./openlist admin set NEW_PASSWORD cfg.json`（先停实例，
  否则运行中实例 save 会回写覆盖；命令会尝试热通知、连不上会提示重启生效）
- **前端自动化**：`playwright-core` 装在
  `C:/Users/Administrator/.workbuddy-ai/binaries/node/workspace/node_modules`，
  用系统 Chrome `C:/Program Files/Google/Chrome/Application/chrome.exe`：
  ```js
  const { chromium } = require('playwright-core');
  await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] });
  ```
  跑：`NODE_PATH=<workspace>/node_modules node <script>.js`
  ⚠ **别用 agent-browser**（它下载 Chromium 会失败，两次各卡 10 分钟）
  ⚠ 前端自动化**点按钮必须按文字/role 定位**（`getByRole('button', {name:'登录'})`），
    登录页有「清除」和「登录」两个按钮，`.first()` 会点错（我踩过）
  ⚠ 已知白名单 404：`/api/public/plugins`、`/api/public/env_check`（Go 上游也
    没有这两个端点，前端有容错 —— STATUS.md §18.2），UI 断言要排除它们
- UI 回归：`NODE_PATH=<workspace>/node_modules node tools/ui_smoke.js`
  （OLZ_URL / OLZ_USER / OLZ_PASS 环境变量可覆盖）

**设备限制**：busybox 阉割，但 **`/bin/curl` 与 `/usr/sbin/tcpdump 4.9.3` 在**
（2026-10-16 实测，是排查大杀器：本机 curl 一跑就能分清「网络问题 vs 进程问题」，tcpdump 抓 WAN
口 `ppp0` 可直接看 TLS 记录序列）；`chmod` 失效（用 SFTP `sftp.chmod()`）、
`nohup ... &` 要加 `</dev/null`（否则 paramiko 读到 EOF 才返回）、
curl 请用 `-K 配置文件`（URL/头都太长，命令行引号会被吃掉）。

---

## 7. 铁律（违反会出事）

1. **真机测试只在 `/tmp/olz`**，绝不碰 `/opt/sq/openlist` 与 Go 的 config.json / data.db
2. **杀进程只按 pidfile + 隔离目录绝对路径**，绝不用命令行子串匹配
   （生产与测试命令行都含 "openlist server"，用子串筛必误杀）
3. **驱动名铁律**：`factory.key` 必须逐字节等于 Go 的 `driver.Config.Name`
4. **加新 API 端点要同时改 `handle()` 的前缀白名单**
   （`src/api.zig` ~line 567）。只往 `handleAuthed` 里加分支不够 ——
   `/api/me/update` 就是这样 404 的
5. **核心算法一律对齐 Go，不得自创**（密码哈希、签名、JWT claim、时间格式）
6. **上游唯一事实来源 = 本地 `D:\workspace\OpenList` 树**（`drivers/<name>/`），
   不要去 GitHub 拉；`itvsh` 是用户私有驱动，只存在于本地树
7. **catch 分支里的 `try` 要检查会不会跳过配对 unlock**（会 → 死锁）

---

## 8. 磁盘：✅ 已清理（2026-10-16 用户处理过）

当前 `D: 3.0G 总 / 1.8G 已用 / 1.3G 可用（58%）` —— 之前是 100% 满、只剩 3M。

**教训留在**：拉前端包（npm pack，23MB）用完**立刻删**，别堆积。
我反复下载导致过一次 `npm error nospc`（那时 `npm pack` 中途失败、
tarball 残缺，前端包解压出来是空的，还误以为前端有问题）。
