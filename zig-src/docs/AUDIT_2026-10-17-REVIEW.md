# openlist-zig 审计复核报告 v2（2026-10-17 深夜轮，TeleAgent 复核）

> ⚠ **历史快照（2026-10-17 复核（v2 复核版））**：本文是当时那一轮的审计结论，**已被
> [`AUDIT_2026-10-18-drivers.md`](AUDIT_2026-10-18-drivers.md)（按驱动维度的全量对账）
> 与 [`STATUS.md`](STATUS.md) §37–§45（逐项修复记录）取代**。文中的 P0/P1 编号、
> 测试数、二进制大小、驱动覆盖数都是**当时**基线；判断现状请看 STATUS 顶部
> 「当前基线」表。保留本文只为追溯当时的判断与证据链。

> **地位**：本文是 2026-10-17 审计链条的**最终复核版**，现役唯一位置即本文件
> （`zig-src/docs/AUDIT_2026-10-17-REVIEW.md`）。原稿在
> `outputs/AUDIT-复核报告-2026-10-17-v2.md`，内容一致，仅存档案用途。
> **本版取代** `outputs/AUDIT-复核报告-2026-10-17.md`（v1 复核，已整合为
> `AUDIT_2026-10-17-REVIEW-v1.md`，留档对照）。
> **复核对象**：`zig-src/docs/` 下三份文件——`AUDIT_2026-10-17.md`（v1 审计，现带废弃横幅）、`AUDIT_2026-10-17-v2.md`（v2 审计，现行版）、`AUDIT_DS_2026-10-17.md`（DS 第三方独立复核）。
> **本轮工作**：① 对 v2 审计的 12 处修订逐条双侧亲验（Go 上游重读 + Zig 侧重读）；② 读透 zig 改造背景（README / STATUS §1-§3/§22/§35/§36 / TODO / 构建链）；③ 对本人 v1 复核中的一处测量错误自纠；④ 补充三份材料均遗漏的独立发现。
> **性质**：静态源码级复核，未编译、未运行、未上真机。
> **后续落地**：v2 复核列出的修复项已全部完成并经真机回归——
> P0/P1（H1–H7/M1/M9/M11/M12/M16/L2）见 `STATUS.md` §37；
> 剩余 M2/M3/M4/M6/M13–M15/M17、P3 全部、N1 见 `STATUS.md` §38
> （构建 400/400 单测、真机 e2e 92/92）。

---

## 0. 文件时间线与关系（先厘清）

| 时间（10-17） | 事件 | 产物 |
|---|---|---|
| 下午 | 原始审计成稿（当时未落盘，正文以聊天形式提供） | v1 审计（7H/17M/23L） |
| 14:05–14:10 | 本人第一轮复核：H1/H2 机理质疑（arena free 语义）、L1 Go 侧证伪、M10 重定性、fs/archive/meta 漏项 | `outputs/AUDIT-复核报告-2026-10-17.md` |
| 22:14 | DS（DeepSeek V4.1-Flash）独立复核：代码事实 7/7+17/17 属实，但**未做分配器语义分析** | `AUDIT_DS_2026-10-17.md` |
| 22:23 | v2 审计：吸收 arena 语义修正（与本人 v1 复核结论一致）、按 STATUS §22 重写 M10、补背景章 | `AUDIT_2026-10-17-v2.md`（现行） |

本人 v1 复核时两份审计文件确实不存在于仓库（全盘 + git 搜索均无）；本轮三份文件均已落盘。v2 的 H1/H2 机理修正、L1 删去「Go 用 hmac.Equal」的失实表述，与本人 v1 复核的独立结论一致——即 v2 的修订方向有外部复核支撑，可信度高于一般自修订。

---

## 1. 总体结论

**v2 审计是一份可靠、可据以排期的修订版**：

| 维度 | 判定 |
|---|---|
| 12 处修订的核实结果 | **11 处成立，1 处（背景章）含事实错误** |
| 代码行号引用 | 抽查全部命中（含本轮新核的 189 `driver.go:59-77`、123 `upload.go:150-158`、`fsread.go:255-262`、`sign.go:12-16` 等） |
| 影响定级 | v2 的降级/重定性**全部有代码或实测依据**，方向正确 |
| 残留问题 | 5 处（详见 §3）：1 处数字错误（88 MB）、1 处基线口径偏旧、1 处真实缺口漏项（`fs/archive/meta`）、1 处落点描述不精确（reset_token）、1 处口径沿用（"16 驱动"） |
| 覆盖完整性 | 良好；本人另发现 **1 条三份材料均遗漏的行为差异**（匿名浏览，§5） |

**一句话**：采纳 v2 的结论表（§2）做修复排期是安全的；动手前把 §3 的 5 处更正叠上去，再决定 §5 新增项的处置。

---

## 2. v2 十二处修订逐条核验

### 2.1 核验表

| # | v2 修订 | 本人核验证据 | 判定 |
|---|---|---|---|
| H1/H2 | 「必现 UAF」→「所有权 bug（潜伏）」 | ① `ctx.alloc` 全量排查=请求级 arena（`http.zig:622-626`；api/webdav 全部调用点无一例外）；② Zig std `ArenaAllocator.free` 仅在「释放块恰为末尾分配」时回卷 `end_index`，否则 no-op（std 源码）；③ 分配时序：非空结果下 `out.append`/`out.toOwned()` 恒为请求 arena 的**末尾**分配、垫在内层 arena 节点之后 ⇒ deinit 永不满足回卷条件 ⇒ 内存存活到请求结束；空结果下 `out` 为空、无字符串可悬垂 | ✅ 成立，且可**比 v2 更进一步**：v2 写「边界情况（最后一页无追加？）可能回退」带问号——经分配时序穷举，**当前生产路径连边界悬垂窗口都不存在**（回卷只发生在空 out 场景，而空 out 无指针可悬垂）。「潜伏必修」的总定性正确（换 GPA 调用方/跨请求复用即真 UAF） |
| H3 | 高危→中：仅 wohome 通道、自愈失败 | `wopan.zig:439` `if (retry and !std.mem.eql(u8, channel, chan_api_user))` —— api-user 确被排除在刷新重试外；wohome key=accessToken[:16]，刷新后旧密文必 9002；真机 `/wo` 61/0/0（STATUS:2581/2677）证明正常会话不触发 | ✅ 成立（代码缺陷真实，触发面窄） |
| H4 | 高危→中低：仅 classify/zone 两调用、有兜底 | `initClassify`（301-325）每条 catch 都回落空 map（上传 fileType 退 "5"）；`initZone`（327-337）`catch return` + `DefaultZoneURL` 兜底；api-user 的 body 键（401-405 行 `clientId`+`secret:true`）与 SDK `NewBody` 一致 | ✅ 成立 |
| H5 | 维持高危 | Go 侧坐实：`drivers/123/upload.go:150-158` 403 时 `singleflight.AnyGroup.Do("Pan123.newUpload_%p")` 收敛换批、整map替换、GC 保生命周期；Zig 侧三细节（967 无锁读 / 935-937 存进触发 worker 的 arena / 954 `reset(.retain_capacity)` 主动复用缓冲）此前已核 | ✅ 成立。补充：Go 换批后**返回错误**由 errgroup 的 retry 层重试该块（`upload.go:162`），Zig 是原地重试——语义近似，问题纯在内存所有权 |
| H6 | 高危→中：纵深防御 | 需上游响应体携带 CRLF；`Content-Disposition` 文件名路径安全（`api.zig:3019-3041` 逐字节 percent-encode，CRLF 必被转义）；注入面限于直链 URL 与透传头 | ✅ 成立 |
| H7 | 高危→中高：仅外部 blob 触发 | `cookiejar.zig:352-355` toJson 恒写 `"Secure"`/`"HttpOnly"` 两键——自产 blob 不缺键 | ✅ 成立（但触发即启动崩溃、只能改配置恢复，中高定级合理） |
| M3 | 中→设计取舍 | `cloud189pc.zig:2156` meta help 明示「保留字段：本工程串行上传」；`client.zig:155-159` 每客户端一把锁（std.http.Client 非线程安全的既定约束）；pan123（838-845）/itvsh 的 per-worker client 是仓内既有解法 | ✅ 成立（架构约束下的已知代价，非疏漏） |
| M4 | 中→低：仅转码开启时分叉 | UC 全矩阵真机已过（§36A.1）；Go `util.go:55`/`driver.go:66` 的 `d.config.Name == "Quark"` 判据核实 | ✅ 成立。补充：`quarkuc.zig:470` 注释自称「仅 Quark」却无判定——**注释与代码不一致**仍值得顺手修 |
| M5 | 中→低：已缓解 | §36B.8 真机证明失败渠道（8005/9002）不消耗一次性 refresh_token | ✅ 成立 |
| M7 | 中→低 | 用户实际挂载为 koofr/jianguo（非 SharePoint）；Go `webdav/util.go:15-34` SSO 分支核实存在、Zig 确无 | ✅ 成立 |
| M10 | 整条重写为「主动删减」 | STATUS §22.1（1372-1395）逐行核对：`fs/other`、`batch_rename`、`regex_rename`、`recursive_move`、`remove_empty_directory`、`fs/link`、`fs/archive/decompress`、`fs/get_direct_upload_info`、`/ad|ap|ae/*`、`admin/meta`×5、`admin/message`×2、`fs/search`（无索引连带）**全部在删减清单** | ⚠️ 大体成立，**但有漏项**（见 §3.3） |
| 背景 | 基线/架构表更新 | 架构表 8 行全部核实（`model.zig:70-89` 无 ID 字段、`driver.zig:315-353` 编译期白名单、Go `drivers/` 实测 **89 个**驱动目录 vs Zig 12 注册项、config.json/单管理员/CDN/请求级 arena/客户端全局锁均属实） | ⚠️ 大体成立，两处口径问题（见 §3.1/§3.2） |

### 2.2 v2 新增的「已确认对齐」声明核验（本轮补验）

- **189 link「第三跳」是 Go 死代码**：✅ `drivers/189/driver.go:59-77` —— `res` 取自第一次请求；70 行 `_, _ = client.R().Get(link.URL)` **丢弃返回值**，71-72 行仍判旧 `res`、再读旧 `location`。Go 实际行为=只解一跳；Zig `cloud189.zig:842-856` 注释已分析并照实际行为写。**是对齐，不是差异**——v2 新增此条正确，v1 把它隐含在「link 对齐」里没展开。
- **`Sign()` 条件一致**：✅ Go `server/common/sign.go:12-16`（`obj.IsDir() || (!encrypt && !SignAll)` → 空串）vs Zig `api.zig:3894-3899`（`is_dir` → ""、`!sign_all` → ""，无 meta 故无 encrypt 概念）。base64 编码器：Zig `url_safe.Encoder`（带 padding）对应 Go `base64.URLEncoding`（带 padding）✅（注释 3878-3880 明确区分了 JWT 的 no-pad 变体）。
- **FsGetResp 形状**：✅ Go `fsread.go:255-262`（`ObjResp` 内嵌 + raw_url/readme/header/provider/related）；Zig fs/get（1296-1334）缺 `thumb`/`hashinfo`/`hash_info` —— M9 维持成立。

### 2.3 对 DS 复核（AUDIT_DS）的交叉评价

DS 报告验证了**代码事实层**（7/7 高危、17/17 中危、低危抽样 8/8 属实），与本人复核互补，但有三处它没做到位（v2 已修正其中两处）：

1. **H1/H2**：DS 只验证了「结构上指针指向 arena」的代码事实，**未做分配器语义分析**（`ctx.alloc` 的身份 + arena free 的回卷规则），因此把「必现悬垂」判为属实。v2 采纳了本人 v1 复核的机理分析予以降级。**这正是「指针指向已 deinit 的 arena」与「指针实际悬垂」的区别所在。**
2. **L1**：DS 抽样判「属实」只验了 Zig 侧（`api.zig:3925` 用 `std.mem.eql`）；**Go 侧未验**——`pkg/sign/hmac.go:44` 就是普通 `!=` 比较，全仓库无 `hmac.Equal`。L1 的「差异」不成立（两侧行为一致，只能算共同加固项）。v2 已删去该失实表述。
3. **M10**：DS 判「属实」时未对照 STATUS §22.1 的主动删减清单，把设计边界当缺口列了。v2 已按 §22.1 重写。

DS 报告的 §3.5（「全驱动扫描是模式级限定，不能排除其他 arena 用法」）与 §4.3（防回归测试建议——返回后覆写内存再断言）两条**质量很高**，建议修复时采纳。

---

## 3. v2 仍存在的问题（5 处，建议出 v3 或直接更正）

### 3.1 背景章数字错误：「含内嵌前端约 88 MB」

v2 §1.1 写「Go 版全量驱动二进制 45,154,464 B（**含内嵌前端约 88 MB**）」。三重错误：
- STATUS 全文无「88 MB」出处（grep 证实）；
- STATUS §22.1:1376 明写前端内嵌为 **20 MB**；
- 维度不可能：45 MB 二进制装不下 88 MB 内容。
应改为「（含 `//go:embed` 前端约 20 MB）」或删去括注。45,154,464 B 本身有出处（zig-src/README.md:17），真实。

### 3.2 验证基线口径偏旧

v2 §1.3 引「e2e **390** 通过/20 失败/2 跳过」——这是 §36B.7 的较早口径；**最新全量为 437/20/2**（STATUS:2731，§36C，20 个失败仍全部是 /115 上游最终一致性级联，非缺陷）+ 单测 386/386（STATUS:2759/2771，§36D）。结论方向不变，数字应更新。

### 3.3 M10 漏项：`fs/archive/meta`

v2 称「真实缺口只剩 `PUT /api/fs/form` 与 `POST /api/admin/setting/reset_token`」。**漏了第三条**：
- Go `server/router.go:199`（`fsAndShare` 组）注册 `a.Any("/meta", handles.FsArchiveMetaSplit)`；
- Zig 只注册了 `/api/fs/archive/list`（`api.zig:665`），`archive/meta` 全文无踪迹（grep 证实）；
- STATUS §22.1:1393 删减清单只列了 `fs/archive/decompress`，**未涵盖 `archive/meta`**——它不属于已定案边界，是边界内的真实缺口。前端压缩包元信息（类型/大小/条目数）请求会落空。

### 3.4 reset_token 的落点描述不精确

v2 未说明其失败形态。实际路径：`/api/admin/setting/reset_token` 命中前缀白名单（`api.zig:633` `/api/admin/setting/`）→ `handleAuthed` 过鉴权 → `handleSettingRoute`（685 行）五分支均不匹配 → **JSON 404 信封**（`api.zig:2454`，HTTP 200 + body `code:404`）。**不落 NoRoute 的 200+HTML**。对 axios 前端同样是静默失败，但症状与排障定位不同（v1 复核曾指出此区分，v2 行文丢了）。

### 3.5 「全 16 驱动」口径沿用

v2 §6 沿用 v1 的「全 16 驱动扫描」措辞。实测：`src/drivers/` 下 **14 个驱动文件**、注册表 **12 项**（`driver.zig:315-335`）。不影响扫描结论（该模式仅 cloud189/cloud189pc 两文件，本人独立复扫成立），但口径应更正。

---

## 4. 本人 v1 复核的自纠（诚实声明）

| 项 | v1 复核说法 | 正确口径 | 教训 |
|---|---|---|---|
| 源码规模 | 「实测 35,312 行（41 个 .zig 文件求和）；v1 审计夸大约 17%」 | **40 个文件 / 39,511 行**（本轮用 `(Get-Content).Count` 全量重测，含空行） | v1 复核当时用 `Measure-Object -Line`——**该方法不数空行**，且文件数也点错了（40 非 41）。据此指控「夸大 17%」不成立：v1 审计的 41,311 行相对真实值仅偏高 **~4.6%**（可能是不同时点快照或含/不含空行的口径差）。**撤回该指控。** |
| 其余结论 | — | **全部维持**：H1/H2 arena 机理（与 v2 修订一致）；L1 Go 侧无 `hmac.Equal`（v2 已采纳）；L2 阈值实为 ≥10⁶（7 位数即溢出 24 字节 buf，非 10⁸）；M8 的 Go Addition **根本没有** follow_symlinks 字段（`local/meta.go:8-19`，Go 无条件跟随软链目录，是「Zig 自加开关 vs Go 无此概念」）；M10 的 reset_token/NoRoute 区分；fs/archive/meta 漏项 | — |

---

## 5. 三份材料均遗漏的独立发现（本轮新增）

### N1. 匿名（游客）浏览被整体关闭 —— 行为差异，未文档化

- **Go**：`fs/list` 与 `fs/get` **双挂载**——`_fs(auth.Group("/fs"))`（router.go:108，需登录）与 `fsAndShare(api.Group("/fs", middlewares.Auth(true)))`（router.go:109 + 195-201，`Auth(true)`=allowDisabledGuest）。Go `middlewares/auth.go:32-48`：空 token → guest 用户，仅当 guest 被禁用才 401。**默认部署下匿名可列目录/取详情**（OpenList 经典的公共浏览器形态；`fs/archive/meta|list` 同组也对游客开放）。
- **Zig**：`checkAuth`（`api.zig:1097`）对空 token **恒 false** → `handleAuthed` 一律 401「Guest user is disabled, login please」（`api.zig:654`）。匿名浏览整体关闭；仅 `/d/`+sign（sign_all 开时）与 `/p/` 匿名可用。
- **定性**：单管理员设计下大概率是有意收紧，但**不在 STATUS §22 删减清单**（「多用户」行只覆盖用户表，未提 guest 浏览），三份审计材料也都没列。对两类场景是真实分叉：① 拿 Go 行为当基准的第三方工具/脚本（匿名 list 会 401）；② 「公开只读浏览」用途。
- **建议**：至少补进 §22 文档化；若要兼容，可实现 guest 只读（难度低——`checkAuth` 对空 token 放行 + `handleAuthed` 按只读处理）。

### N2. M10 补充（详见 §3.3）：`fs/archive/meta` 为边界内真实缺口。

---

## 6. zig 改造背景（审计上下文，读差异前必读）

### 6.1 这是什么项目

- **目标**：把 OpenList 兼容服务塞进**中兴 F4610U 光猫**（aarch64 / musl / squashfs，内存与存储极小）。「用 Zig 重写 OpenList 的可行性验证工程」（zig-src/README.md:3）。
- **存在理由是体积**：Go 全量驱动二进制 **45,154,464 B** vs Zig **~1.14–1.21 MB**（README:17 / STATUS §3:54），裸小约 39 倍。前端不内嵌（`//go:embed` 20 MB → 改 CDN/`dist_dir`/内置占位页三选一）被 STATUS §22.1 称为「**项目的存在意义**」。
- **驱动面**：Go `drivers/` 实测 **89 个**驱动目录 vs Zig **12 个注册项 / 11 个实现文件 / 14 个驱动源文件**（含 3 个保留未注册的 `_open` 变体），编译期白名单 `-Ddrivers=`（`driver.zig:315-353`，comptime 分支裁剪）。itvsh（上海电信智家硬盘）是 fork 后独立实现的私有驱动，上游无关。
- **构建与部署**：本机无 Zig 工具链，一律走打包机 10.0.0.4（`tools/build_remote.py`：上传 → `zig build test` → `aarch64-linux-musl` 交叉编译 → 取回）；真机测试只在 `/tmp/olz:15399` 隔离实例，**绝不触碰**光猫上的 Go 生产实例（15244/opt）。

### 6.2 架构决策 → 审计发现的因果链（理解每条差异的土壤）

| 架构决策 | 直接后果 | 关联审计条目 |
|---|---|---|
| `config.json` 单文件替代 SQLite（无 DB、无事务） | 写回靠 tmp+rename 原子 + 锁；设置存 `zig.*` 块 | M16（putZig/save 竞态）、M1（sign_all 默认值落在 `zig.*`）、M17 |
| **单管理员**（用户中心思想：「管理员一个账号管理整个存储」，用户 2026-10-16 拍板） | 无用户表/角色/分享/2FA/WebAuthn/LDAP/SSO | §22 删减清单、M13/M14 的定性、「M10 多数项=边界」 |
| 手写 HTTP/1.1 服务端，**每请求一个 ArenaAllocator**（`http.zig:622-626`） | free 仅末尾回卷；请求期内存零逐对象释放 | **H1/H2 的「潜伏」定性**、H6（无 net/http 的头校验） |
| 每驱动一个 Client，**每 Client 一把全局锁**（`client.zig:155-159`，std.http.Client 非线程安全） | 同驱动内请求串行；并发靠 per-worker client | M3（189pc 串行=未采用该解法）、H5 的修复模式参照 |
| `model.Obj` **无 ID 字段**（`model.zig:70-89`，仅 name/sign/priv 等） | 189/189pc 每次操作按路径逐段翻页找 ID | L19（无 id 缓存、深路径多打请求） |
| 前端走 CDN（不内嵌） | 启动强依赖外网；CDN 取不到即退出（`CdnIndexFetchFailed`） | 运行期约束（§6.5）；CDN fallback 是 Zig 特有新增 |
| 编译期驱动白名单 | 未注册驱动导入配置后 init 失败（Baidu/Onedrive 属预期） | §22 边界；驱动名铁律=逐字节等于 Go `Config.Name` |

### 6.3 功能边界（STATUS §22，2026-10-16 用户定案）

- **主动删减（不打算补）**：前端内嵌、SQLite/多用户、分享、SSH 公钥、WebAuthn、2FA/TOTP、LDAP、SSO、搜索索引（连带 `fs/search`）、离线下载全家、Torrent、分片上传 `fs/multipart/*`、Meta、消息中心、S3/FTP/SFTP/MCP 服务，以及 `fs/other`/`batch_rename`/`regex_rename`/`recursive_move`/`remove_empty_directory`/`fs/link`/`fs/archive/decompress`/`fs/get_direct_upload_info`/`/ad|ap|ae`/`/i/`/`/sd|sad`/`/robots.txt`。
- **特意新增（Go 没有）**：itvsh 驱动、CDN 多源 fallback、`@zig-setup` 诊断页、`zig.*` 配置块、编译期白名单、内置页首装面板。
- **边界内仍缺**（本报告口径）：`PUT /api/fs/form`（§22.1:1389 文档自称有、实际无路由——文档漂移）、`POST /api/admin/setting/reset_token`、**`fs/archive/meta`（三份材料中仅本报告指出）**。
- **文档漂移五项**（v2 §7 全部核实成立）：① §22.1:1395 把 `cors` 列为未读配置项，实际已实现（`config.zig:552-556` + `api.zig:745-770`）；② §22.1:1389 的 fs/form 表述；③ §22.4:1415-1420 把 `me/update`/`auth/logout` 列为「应该做但没做」，二者均已实现（`api.zig:672/674` + TODO §0）；④ zig-src/README.md 数字过时（328 测试/十驱动/1,144,432 B vs 实际 386/12 注册/~1.2MB）；⑤ MEMORY.md「WoPan 未真机」过时（已修通 61/0/0）。

### 6.4 当前验证基线（最新口径，2026-10-17 19:30 后）

- 单测 **386/386**（打包机，§36D）；aarch64 交叉编译通过，产物 sha256 `a197229e…`。
- 真机全量 e2e **437 通过 / 20 失败 / 2 跳过**（§36C:2731；20 个失败**全部**是 /115 上传可见性级联——115 上游分钟级最终一致性+对高频轮询的风控空列表，非实现缺陷）。
- driver_matrix **26/0**；UI 冒烟 **11/11**；WebDAV 与生产 Go 实例逐头对照 **4/4**（§36B.7）；**12/12 驱动真机覆盖**（WoPan 单挂载 61/0/0，§36B.5）。
- 今日已修（与审计「已确认对齐」互为印证）：189 登录 SSO 回跳（Go 侧同步修）、115 mkdir Content-Type、WoPan 四连修+多渠道 refresh、189PC `fs/get size=0`、配置导入/导出端点。

### 6.5 运行期已知约束（部署与审计复测须知）

- CDN 取不到即启动失败（设计固有风险）；`/etc/resolv.conf` 末尾无换行触发 Zig 0.17 std 解析 bug（全外网请求 `ResolvConfParseFailed`）。
- quark 的 TLS 需 `tools/ziglib_patch.py` 给 std 补 ECDSA 套件（该 CDN 服务器 RSA 路径损坏）。
- 115 最终一致性极长 + 风控；189 个人云秒级；189web 与 189pc 双驱动互踢会话。
- e2e 网络注意：PC↔光猫走 easytier 隧道会间歇 RST，**动态对照一律走设备本机 loopback（127.0.0.1）**。

### 6.6 §35 方法论（本项目自己的教训，也正是本轮审计该用的方法）

STATUS §35（2026-10-17）立下的规矩：**协议细节不能凭实测感觉判对齐——上游源码是唯一事实来源，必须落到函数与行号；再用光猫上的生产 Go 实例做动态对照，且一律走设备本机 loopback。** 反例即早先把 Go NoRoute 的 405 误判为未对齐（源码一读翻案）。本轮三份材料+本复核均按此执行；后续修复的验证（尤其 M15 的 gin-contrib/cors 展开值）也应照此闭环。

---

## 7. 修正后的最终修复优先级（融合 v2 + 本报告更正）

### P0（正确性 / 崩溃，先做）

1. **H7** cookiejar `.?`→`orelse`（十行内；外部/手改 blob 启动即崩且只能改配置恢复）——三份材料一致，维持首位。
2. **H5** pan123 refetch：解析结果迁入 `BatchState` 自有的长期分配（`state.alloc` 或独立 arena，生命周期=整批）+ `urls` 读写持 `mu`；按 DS §4.3 补多 worker+注入 403 的并发测试。
3. **H1/H2** 189/189pc dupe（`normalizeName(alloc,…)` + thumb/hash dupe）——定性为「拆除地雷」而非救火；顺手按 DS §4.3 加「返回后覆写内存再断言」单测。

### P1（功能 / 安全）

4. **M1** `zig.sign_all` 默认改 `true`（一行）。
5. **M11** 登录 401 + IP 计数限速（429）。
6. **H3** wopan 重试改为重加密（param 明文传 `post` 内部，对齐 SDK `NewBody` 语义）。
7. **M9** fs/get 补 `thumb`/`hashinfo`；`writeObj` 补 `hashinfo` 字符串键。
8. **M12** fs/dirs 改为列子目录的裸数组契约（前端影响未闭环，但第三方契约对齐成本低）。
9. **M2** 115 link header 透传（SDK 在外部仓库，改后需真机回归下载路径）。
10. **H6** `Response.set`/`redirect` 统一剔除 CRLF/NUL（一处改动覆盖全部写头点）。
11. **M16** `putZig`/`setTopLevel` 取 `g_save_mutex`。
12. **M10 补缺（本报告更新）**：`fs/archive/meta`（实现或明确记入 §22.1）+ `fs/form`（同）+ `reset_token`（同；注意其落点是 JSON 404 信封）。

### P2（兼容 / 性能 / 取舍）

13. M6 itvsh 重试放宽到所有可重试错误；M13 admin token 入口（或文档声明边界）；M17 凭据重载原子化；M15 CORS 默认列表补 PATCH/HEAD+WebDAV 头（或文档化可配）；M8 软链策略产品拍板；M3 189pc 并发（抄 pan123 per-worker client 模式）；M4 转码变体判据（顺手修 `quarkuc.zig:470` 的注释-代码不一致）。
14. **N1 匿名浏览差异**：至少补进 §22 文档化；要兼容则实现 guest 只读。

### P3（记录 / 文档）

15. M5、M7、M14、L1–L23（L1 改记「两侧共同的加固项」；L2 顺手把 `cl_buf` 扩到 32 字节）。
16. **文档修正包**：§22.1 cors 行、§22.1 fs/form 行、§22.4、README 数字、MEMORY.md WoPan 行、**v2 的 88MB→20MB**、v2 基线数字 390→437。

---

## 8. 方法与局限

**本轮新核对的两侧源码**（此前两轮之外的增量）：
- Go：`drivers/189/driver.go:40-90`（三跳死代码）、`drivers/123/upload.go:95-169`（singleflight 换批）、`server/handles/fsread.go:240-284`（FsGetResp）、`server/common/sign.go`（全文）、`server/middlewares/auth.go:1-90`（Auth(true) 与 token 分支）、`server/router.go`（全文，双挂载 108-109）、`drivers/local/meta.go`（Addition 无软链字段）、`drivers/webdav/meta.go`、`pkg/gowebdav/client.go:275-322`（Mkdir 405）。
- Zig：`api.zig`（handleAuthed 分发 649-694 / handleSettingRoute 2430-2454 / checkAuth 1085-1119 / signForObj 3894-3909 / contentDisposition 3019-3041）、`cookiejar.zig:330-365`（toJson）、`client.zig:148-177`（全局锁）、`wopan.zig:296-345`（兜底链）、`model.zig:60-104`（Obj 无 ID）、`strm.zig:543-567`（registry）、`driver.zig:300-370`（白名单）。
- 文档：STATUS §1-§3/§22（1372-1420 逐行）/§35/§36 关键行、zig-src/README.md、TODO.md 头部、MEMORY.md。
- 口径实测：src 40 文件/39,511 行/14 驱动文件（`(Get-Content).Count` 全量）；Go `drivers/` 89 个目录。

**局限**：
1. 静态复核——未编译、未运行、未上真机；所有「真机通过」引用均转述 STATUS/工作日志的既有记录。
2. Zig std arena 语义取自 master 分支源码，0.17.0 未逐字比对（以 e2e 长期全绿为旁证；如需钉死可在打包机跑一段 10 行的最小验证程序）。
3. gin-contrib/cors 对 `"*"` 的确切响应头仍未实测（沿 v2 的弱判断「覆盖面 ≥ Zig 固定列表」；建议按 §6.6 方法在设备 loopback 发一次 OPTIONS 预检钉死）。
4. L 级 23 条未逐条复核（两轮累计抽样 9 条 + 若干顺带核对，命中率支持整体采信；采纳修复前按条重读）。
5. 前端 bundle 为旧快照，M12/N1 的前端实际影响未闭环（bundle 未检出 `fs/dirs`/匿名 list 调用点）。

---

## 9. 结论

1. **v2 审计可用**：12 处修订经双侧亲验 11 处成立、方向全部正确；其「协议对齐扎实、风险集中在内存所有权与少数契约细节」的总判断，与 STATUS 记录的验证基线（386 单测/437-e2e/12 驱动真机）相互印证。
2. **采纳前叠加 5 处更正**（§3）：88MB 数字、基线 390→437、补 `fs/archive/meta`、reset_token 落点、16→14 驱动口径。
3. **三份材料共同的盲区是「匿名浏览」**（§5 N1）——它不是 bug，是未文档化的行为分叉，需要产品拍板后进 §22。
4. 修复顺序按 §7：P0 三项（H7/H5/H1H2）的收益-成本比最高；P1 里 `fs/archive/meta` 是本报告新增的必办项。

---
*复核人：TeleAgent（星辰）。2026-10-17 深夜。本报告取代同日早前的 v1 复核（`outputs/AUDIT-复核报告-2026-10-17.md`）。*

> AI生成
