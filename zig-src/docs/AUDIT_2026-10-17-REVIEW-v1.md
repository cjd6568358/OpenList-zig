# openlist-zig 审计复核报告 v1（2026-10-17 下午，TeleAgent 复核，留档）

> ⚠ **历史快照（2026-10-17 复核（v1，已被 REVIEW 取代））**：本文是当时那一轮的审计结论，**已被
> [`AUDIT_2026-10-18-drivers.md`](AUDIT_2026-10-18-drivers.md)（按驱动维度的全量对账）
> 与 [`STATUS.md`](STATUS.md) §37–§45（逐项修复记录）取代**。文中的 P0/P1 编号、
> 测试数、二进制大小、驱动覆盖数都是**当时**基线；判断现状请看 STATUS 顶部
> 「当前基线」表。保留本文只为追溯当时的判断与证据链。

> **⚠ 本版已被 `AUDIT_2026-10-17-REVIEW.md`（v2 深夜复核）取代**，仅作历史对照留存。
> v2 复核对本文的自纠声明见其 §4（88 MB 数字错误）；本文 H1–H7 / M1–M17 的
> 逐条亲验结论仍有效，且多数已被 v2 复核与后续 `STATUS.md` §37/§38 吸收。
> 原稿在 `outputs/AUDIT-复核报告-2026-10-17.md`，内容一致，仅存档案用途。

---



**复核对象**：用户提供的《openlist-zig vs Go 上游差异审计报告（2026-10-17）》正文（声称落盘于 `zig-src/docs/AUDIT_2026-10-17.md`，**该文件在仓库、git 历史、全盘搜索中均不存在**，正文为唯一审计内容）。
**复核方法**：逐条双侧源码亲验——每条声明同时核对 Zig 侧（`zig-src/src`）行号/代码事实与 Go 侧（仓库根 Go 树）行号/语义；对定性存疑项追加第三层证据（Zig std 库源码、真机 e2e 实测记录、调用链全量排查）。
**复核范围**：H1–H7 全部亲验；M1–M17 全部亲验；L 项抽查 9 条（L1/L2/L3/L7/L10/L13/L21/L22/L23）；「已确认对齐」声明抽查 4 组；另做独立扫描补充报告未覆盖的差异点。

---

## 一、总体结论

| 维度 | 判定 |
|---|---|
| 行号/代码事实引用准确性 | **极高**（抽查 40+ 处行号几乎全部命中，含双侧） |
| 机制描述真实性 | 高（H3–H7、M1–M17 逐条核实为真差异/真缺陷） |
| 影响定级准确性 | **存在 2 处实质性错误**（H1/H2 夸大为"必现 UAF"；L1 的 Go 侧断言失实） |
| 口径准确性 | 3 处小错（行数/驱动数、L2 阈值差两个数量级、M10 的 reset_token 落点） |
| 覆盖完整性 | 好；本人另发现 1 条报告遗漏的路由缺失（`fs/archive/meta`） |

**一句话结论**：这份报告是真实的高质量审计——代码引用可信、绝大多数发现属实，可作为修复依据；但 **H1/H2 的"必现 UAF"定性必须降级**（生产路径无实际悬垂），**L1 整条不成立**（Go 侧同样非常量时间比较），采纳修复建议前应先按本报告 §三的裁决表校正。

---

## 二、高危项逐条裁决（H1–H7）

### H1 cloud189.zig:736-768「UAF（必现）」——**代码事实属实，定性错误：生产无实际悬垂**

Zig 侧事实（全部核实）：
- `getFiles` 内 `arena = ArenaAllocator.init(alloc)` + `defer arena.deinit()`（737-738 行）；
- `out = List(model.Obj).init(alloc)`（741 行）分配在外层分配器；
- `.name`/`.thumb` 直接取自 arena 内解析的 JSON（724 行 `json.parse(arena, body)`；749/758/762 行）。

**但影响判定不成立**，三层证据：

1. **分配器拓扑**：`getFiles` 仅被 `list()`（815 行）调用，全部生产调用点传入的 `ctx.alloc = req.arena`——即 `http.zig:622` 的每请求 `ArenaAllocator`（api.zig:1163/1182/1348/495、webdav.zig:106/148/272/473/520/553/596/641 全量排查，无一例外；`api.zig:323` 的 init 路径传 gpa 但不调 `getFiles`）。
2. **Zig std arena 的 free 语义**（取自 ziglang/zig master `lib/std/heap/arena_allocator.zig`，0.17 同代实现）：`free()` **仅当被释放块恰好是 arena 当前末尾分配时回卷 `end_index`，否则什么都不做**（顶部文档注释原话："Calls to free an individual item only free the item if it was the most recent allocation, otherwise calls to free do nothing"）。本地 arena 的 `deinit()` 经由请求 arena 的 `rawFree` 释放节点缓冲——而 `getFiles` 在**非空结果**下 `out.toOwned()`（767 行）总是最后一个请求 arena 分配、垫在本地 arena 节点之后，节点释放永不满足回卷条件 ⇒ 内存不回收、字符串有效到请求结束。**唯一发生回卷的空目录场景里 `out` 为空，不存在可悬垂的字符串。**
3. **实证反证**：真机全量 e2e（176→437 用例，含 /ecloud_self 189 个人云列目录数百次、名字逐条断言、9 挂载点并发 list）长期全绿；若每次列目录都返回悬垂字符串，不可能通过。

**正确定性**：真实的**内存所有权契约违反**（跨分配器返回内部指针，违反本仓 cookiejar/quark 确立的 dupe 范式），属高危技术债——任何一处改动（调用点换非 arena 分配器、`toOwned` 行为变化、std 语义收紧）都会立即变成真 UAF；且在 `std.testing.allocator` 语境下（driver.zig:459 模式）就是真悬垂。**报告"每次列目录都返回悬垂字符串、压测/长跑必现乱码名字或段错误"的断言在当前生产二进制上不成立。**

### H2 cloud189pc.zig:1505-1531 同类——**同 H1：属实但不悬垂**

`name` 已 `normalizeName(alloc,...)` dupe（1509/1519 行）；`.thumb`（1524）、`.hash_value`（1525-1526）确指本地 arena。调用链（1673 行 `getFiles(ctx.alloc, e.id)`）与 H1 完全同构，同一定性。

### H3 wopan.zig:439-442 重放旧密文——**属实，真 bug**

- Zig 442 行：`return self.post(a, channel, key, param_b64, false, ...)` —— 重放调用方已用**旧 key** 加密的 `param_b64`；
- wohome 通道 AES key = accessToken 前 16 字节（wopan.zig:17 注释、462 行解密同源），`refreshToken`（235 行）更新 `self.access_token` 后旧密文必失效（9002）；
- SDK 对照：`wopan-sdk-request.go:19` 每次 `request()` 内重新 `NewBody` 加密，`:47` 重试时传**明文 param** 重新走加密。✓ 报告引用行号精确。

### H4 wopan.zig:406 body 键名——**属实，真差异**

- Zig 406 行恒发 `"secret":true`；
- SDK `wopan-sdk-api-wohome.go:137,154`（ClassifyRule/GetZoneInfo）实发 `Json{"key": true}`。✓ 行号精确。影响 init 的 classify/zone 两步（wopan.zig:301-333 证实这两步存在）。

### H5 pan123.zig 竞态/UAF——**属实，真并发缺陷**

三处细节全部核实：967 行 `urlFor(state.urls, ...)` **无锁读**；930-938 行 `refetch(a)` 把解析结果存进**触发 worker 自己的 arena**（935-937）；该 worker 每片后 `arena.reset(.retain_capacity)`（954 行，缓冲复用、内容可被覆盖）、退出 `arena.deinit()`（944 行）。`upload_thread > 1` 时其他 worker 读到撕裂/被覆盖的 URL 树；**单 worker 下同样存在自毁窗口**（reset 后该片重试/下一片的 `client.send` 分配会覆盖 `url` 切片指向的区域）。

### H6 响应头注入——**机制属实，真实加固缺口**

- `http.zig:975` `try head.print("{s}: {s}\r\n", .{h.name, h.value})` 头值零校验；
- `res.redirect`（393-396 行）→ `set("Location", ...)` 无过滤；`api.zig:3532` `res.redirect(lk.url, 302)` 的 URL 来自上游 JSON 响应体，JSON 字符串可携带真实 CRLF ⇒ 头注入/响应拆分。Go `net/http` 会拒绝非法头值。
- 补充（报告未提）：`Content-Disposition` 的 filename 路径**安全**——`contentDisposition`（api.zig:3019-3041）对文件名逐字节 percent-encode，CRLF 会被转义。注入面限于直链 URL 与其他原样透传的头值（如代理透传的 `lk.header`）。

### H7 cookiejar.zig:400-401 缺键 panic——**完全属实，真崩溃风险**

- 400/401 行 `item.getPath("Secure").?` / `.getPath("HttpOnly").?`——缺键即 panic；
- 相邻字段（name/path/domain/expires/max_age/same_site）全部 `orelse` 容错，唯独这两行 `.?`；
- 调用链坐实：itvsh init（264 行）→ `restoreCookies`（431）→ `fromJson`（369 行函数体即 400-401 所在）；
- 426 行注释自称"内容损坏时静默清空"，`.?` 直接违背该承诺：合法 JSON 但缺 Secure/HttpOnly 键的最小 blob（手改配置/其他工具导出）→ init 崩 → 服务起不来 → 管理面无法自救。

---

## 三、中危项裁决表（M1–M17，全部亲验）

| # | 裁决 | 核实要点（双侧） |
|---|---|---|
| M1 | ✅属实 | Zig `config.zig:542` 默认 `false`；Go `internal/bootstrap/data/setting.go:171` 默认 `"true"`。行号精确。仅影响全新部署（现网 cfg 为 true） |
| M2 | ✅属实 | Zig `pan115.zig:697` `.header = &.{}`；Go `drivers/115/driver.go:77` `Header: downloadInfo.Header`（DownloadWithUA 回填 UA+Cookie）。代理回源丢失 UA 授权头 |
| M3 | ✅属实，**但属已文档化偏差** | Zig 无 `Thread.spawn`（cloud189pc.zig 全文核实），表单 help（2156 行）自认"本工程串行上传"；Go `drivers/189pc/utils.go:739` errgroup 并发（报告引 driver.go:369-454 为 Put 分发处，行号略松但结论对）。`upload_thread` 确为死配置（仅 219/780 行做钳制归一） |
| M4 | ✅属实 | Zig `quarkuc.zig:253`（__pus 吸收）与 `:471`（转码链）均无变体判定；Go `util.go:55`、`driver.go:66` 均含 `d.config.Name == "Quark"`。**Zig 470 行注释自称"仅 Quark"却没实现该条件**——比报告说的更值得修 |
| M5 | ✅属实 | Zig `wopan.zig:438-443` 任意 `RSP_CODE != "0000"` 都刷新重试；SDK `request.go:42` 仅 `"9999"`。误刷消耗一次性 refresh_token |
| M6 | ✅属实 | Zig `itvsh.zig:1266-1279` 仅 `AuthFailed` 重登重试；Go `drivers/itvsh/upload.go:73-76` 每块任意错误 3 次+指数退避 |
| M7 | ✅属实 | Go `drivers/webdav/util.go:15-34` sharepoint 走 odrvcookie SSO（删 Authorization、种 Cookie）；Zig webdav.zig 仅表单保留 vendor 字段（747/925 行），无任何 SSO 逻辑 |
| M8 | ✅属实，**补一细节** | Zig `local.zig:224-246` `follow_symlinks` 默认 false ⇒ 拒绝；**Go 的 local Addition（meta.go:8-19）根本没有该字段**——Go 无条件跟随符号链接（util.go:30-47 isSymlinkDir 无开关）。是"Zig 自加安全开关 vs Go 无此概念"，非同配置不同默认值 |
| M9 | ✅属实 | Go `ObjResp`（fsread.go:35-47）含 `thumb`+`hashinfo`（+`hash_info` map）；Zig fs/get（api.zig:1296-1334）两者皆无。writeObj（3722-3738）有 thumb 但只有 `hash_info:null`、缺 `hashinfo` 字符串键（3736 行） |
| M10 | ✅大体属实，**2 处细节修正** | 缺失路由核实：fs/other、fs/batch_rename、fs/regex_rename、fs/recursive_move、fs/remove_empty_directory、PUT fs/form、POST fs/link、fs/search、/ad /ap /ae（router.go:54-59）、admin/meta×5（122-127）、admin/message×2（178-180）确实全缺（Zig isRegisteredAuthedPath 620-637 + dispatch 全查）。修正①：`admin/setting/reset_token` 因前缀 `/api/admin/setting/` 命中白名单、**不落 NoRoute**，而是进 dispatch 后无 handler（行为是另一种坏法，报告表述不准）；修正②：fs/search、离线下载、multipart、share 等属 STATUS §22 已定案边界，不宜与未声明缺失并列。**另发现报告漏了一条：`fs/archive/meta`（Go router.go:199 注册）Zig 侧同样缺失**——前端压缩包元信息请求会静默落空 |
| M11 | ✅属实 | Zig `api.zig:1031-1042` 业务码 400 且无任何限速；Go `auth.go:46-67` 401 + LoginCache ≥5 次锁 5 分钟回 429 |
| M12 | ✅属实 | Zig `handleFsDirs`（api.zig:1140-1159）列**挂载点**、`data.content` 包裹、字段 name/path/driver/label/order；Go `fsread.go:160-185` 列**请求路径子目录**、裸数组 `[{name,modified}]`。形状与语义双不符，行号精确 |
| M13 | ✅属实 | Go `middlewares/auth.go:19-31` 首分支：settings 表 token（常量时间比较）对**所有**挂 Auth 的端点授予 admin；Zig 仅 `/api/admin/user/del_cache`（api.zig:572）收 `zig.token`。持 Go token 的第三方工具在 Zig 全 401 |
| M14 | ✅属实，**已文档化** | Zig `api.zig:1695-1700` 登出仅返成功；代码注释（1681-1694）明示该取舍（改密推 pwd_ts 可全局失效）。Go `auth.go` InvalidateToken 即时失效 |
| M15 | ✅Zig 侧属实 | Zig `setCors`（api.zig:745-770）：methods 固定 `GET,POST,PUT,DELETE,OPTIONS,PROPFIND`（缺 PATCH/HEAD、逗号无空格）、headers 固定 4 个（缺 Depth/Destination/Overwrite）；Go 默认三项 `["*"]`（conf/config.go:227-231 核实）。gin-contrib/cors 对 `*` 的具体展开（默认方法集含 PATCH/HEAD、头反射）未逐字验证，但"浏览器 WebDAV 预检在 Zig 下必挂"的推断成立——预检请求头 Depth/Destination/Overwrite 不在 Allow-Headers 里浏览器就直接拒绝 |
| M16 | ✅属实 | `putZig`（config.zig:163-201）与 `setTopLevel`（238-241）**无锁**改 root 树（187-194 行重分配 keys/vals，两行赋值间存在撕裂窗）；`save`（249-279）的 `g_save_mutex` 只挡 save-vs-save，不挡 save-vs-修改。触发场景（itvsh 后台 cookie 刷新 save × 前台设置保存）成立 |
| M17 | ✅属实 | `reloadAdminCredentials`（api.zig:166-184）180-183 行四字段逐个 dupe 替换、无锁；旧三块字符串永不释放。调用频率低（del_cache），实际风险小 |

---

## 四、低危项抽查（9/23）

| # | 裁决 | 说明 |
|---|---|---|
| L1 | ❌ **不成立（Go 侧失实）** | Zig 侧引用准确（api.zig:3925 确用 `std.mem.eql`；4105 行确有 `ctEqual` 未用）。**但 Go 的 `pkg/sign/hmac.go:44` 就是普通字符串比较 `s.Sign(data, expires) != sign`，全仓库 grep 无 `hmac.Equal`**。Zig 与 Go 行为一致，不构成差异；只可作为"两侧共同的加固项"记录 |
| L2 | ⚠️ 属实但**阈值错两个数量级** | `client.zig:653-655` `[24]u8` buf + `catch unreachable` 属实；但 `"Content-Length: "`(16) + 位数 + `\r\n`(2) ⇒ **≥1,000,000（7 位数）即溢出**，非报告所称 10⁸。路径为 `sendRawOnce`（WebDAV 动词专用，561-573 行注释），当前调用点 body 小——"潜伏"定性正确，但比报告说的更易触达 |
| L3 | ✅属实 | webdav.zig:222-233 `Depth.infinity` 无深度/条目上限递归。Go 侧是否同样无上限未验证（报告亦未主张 Go 不同），按共同健壮性缺口记录 |
| L7 | ✅Zig 侧属实 | local.zig `put`（549 行）无 mtime 回写（全文无 chtimes 类调用）。Go driver.go:426 引用未复核，方向可信 |
| L10 | ✅属实 | `drivers/webdav.zig:503` `if (res.status == 201 or res.status == 405) return;`——远程 MKCOL 405 当成功；Go vendored `pkg/gowebdav/client.go:279-290` 仅 201 成功、405 返回 `newPathError`。**注意是驱动侧文件**，Zig 注释里"matching every other client"的辩解与 vendored gowebdav 行为相悖 |
| L13 | ✅属实 | Zig webdav 表单 753-754 行 `required:false`；Go meta.go:11-12 `required:"true"` |
| L21 | ✅属实 | `itvsh.zig:247-249` `drvName` 返回 "Itvsh"；Go meta.go:34 `Name: "上海电信智家硬盘"`。factory.key 已对齐（注册名正确），仅内部展示名不一致，实际影响≈0 |
| L22 | ✅属实 | `wopan.zig:690-691` uniqueId 固定后缀 `"olzzig"`（SDK 为 6 位随机）。时间戳前缀保证基本唯一性，同毫秒并发上传有理论碰撞 |
| L23 | ✅属实（限 fs/list） | `handleFsList`（1162 行）不读 page/per_page；Go 默认 MaxInt 等价。补充：`handleFsArchiveList`（1544-1545 行）**有**分页，报告若泛指需限定 |

未抽查的 L4/L5/L6/L8/L9/L11/L12/L14–L20：鉴于已抽查 9 条中 7.5 条属实、行号全部命中，整体采信，但**采纳修复前建议按本报告方法逐条过一遍**（尤其 L1 类"Go 侧断言"务必复核）。

---

## 五、「已确认对齐」声明抽查（4 组，全部属实）

1. **密码哈希**：✅ `static_hash_salt = "https://github.com/alist-org/alist"`（api.zig:3817）与 Go `StaticHashSalt` 一致；`staticHash`/`hashPwd` 的 `"{s}-{s}"` 格式与 Go `user.go:235-245` 的 `fmt.Sprintf("%s-%s", ...)` 逐字一致。
2. **189 SSO toUrl 双侧都有**：✅ Go `drivers/189/login.go:132-137`（2026-10-17 补的回跳）；Zig `cloud189.zig:633-649`。
3. **「其他驱动 arena 干净」**：✅ 独立复扫全驱动：quark init（375 行，dupe user_id）/ aliyun init（570 行，dupe drive_id）/ itvsh worker（1240 行自包含）等均为规范模式；跨分配器返回内部指针的模式确仅 cloud189/cloud189pc 两处。
4. **API 信封 / NoRoute / 下载端点两套体系**：✅ 与 STATUS §35 记录一致（http.zig:329-361 的注释即当时对账结论）。

---

## 六、报告口径问题（影响可信度评价，不影响技术结论）

1. **源文件不存在**：`zig-src/docs/AUDIT_2026-10-17.md` 在仓库/git 历史/全盘中均无；审计以正文形式存在，无法核对"亲验/代理"标注的原始痕迹。
2. **范围数字不准**：自称"zig-src/src 41,311 行、16 驱动"；实测 **35,312 行**（41 个 .zig 文件求和）、**12 个注册驱动**（driver.zig:315-335）/14 个驱动源文件（含未注册的 quark/115open/123open）。夸大约 17%。
3. **"全部高危/中危已双侧亲验"与实测矛盾**：L1 的 Go 侧引用（hmac.Equal）不存在——至少该条没有真正读过 Go 的 `pkg/sign/hmac.go`；L2 阈值错误同源。
4. **M6/M7/M13/M14 自标"代理/未亲验"**：本次全部亲验为实，该部分诚实标注值得肯定。

---

## 七、修正后的修复优先级

**P0（正确性与崩溃）**
1. H7：`cookiejar.zig:400-401` 两处 `.?` → `orelse false`（十行内，防启动崩溃）——报告建议正确，维持。
2. H3+H4：wopan 一起修——重试改为重加密（把 param 明文传入 post 内部加密），wohome body 键名按调用区分 `key:true`/`secret:true`。
3. H5：pan123 换批重试——refetch 结果存 `BatchState` 自有 arena（或 `state.alloc` 直配）+ `putPart` 读 `urls` 前加锁。
4. H6：`http.zig` 写头处统一校验/剔除 CR/LF（`Response.set` 一处即可覆盖）。

**P1（安全姿态与可用性）**
5. M1：`zig.sign_all` 默认改 `true`（一行，对齐 Go 新部署姿态）。
6. M11：登录错误码 401 + 简单 IP 限速（429）。
7. M9/M12：fs/get 补 `thumb`/`hashinfo`；fs/dirs 改为列子目录的裸数组形状。
8. M2：pan115 link 透传 UA 头。
9. M13：`zig.token` 认证面扩展到全部 authed API（或至少 fs/me/admin 常用面）。
10. M10（挑前端会点到的）：fs/form、fs/batch_rename、fs/recursive_move、admin/meta/list、**fs/archive/meta（本报告新增）**。

**P2（一致性债）**
11. H1/H2：按报告的 dupe 范式修（`normalizeName(alloc,...)` + thumb/hash dupe）——**定性为"防患于未然"而非救火**；顺手在 getFiles 注释里写明请求 arena 契约。
12. M4：quarkuc 补变体判定（变体信息现成：`self.conf.only_proxy` 即 UC 特征，或加显式 variant 字段）。
13. M16/M17：config 树变更与 save 共锁；reloadAdminCredentials 原子快照 + 释放旧值。
14. M3：189pc 并发上传（可抄 pan123 的 per-worker client 模式，注释里的"全局锁"理由在 pan123 已被解决）。

**P3**：其余低项；L1 从"对齐差异"改记为"共同加固项"；L2 修 24→32 字节 buf 或改用 arena（顺手，一分钟的活）。

---

## 八、复核方法与局限

- **双侧亲验**：Zig 侧以 Read 精确核对行号与代码；Go 侧逐一打开报告引用的文件行段（router.go 全文、auth.go、fsread.go、login.go、hmac.go、user.go、setting.go、config.go、driver.go×3、util.go×3、meta.go×2、gowebdav client.go、wopan-sdk 三个文件等）。
- **第三层证据**：Zig std `arena_allocator.zig`（master 源码逐函数分析 free/reset/deinit 语义）；调用链 grep 全量排查（list()/getFiles()/Ctx.alloc 构造点/`req.arena` 来源）；真机 e2e 历史记录（.workbuddy 日志 2026-10-17，437/20/2 全量回归）作为经验反证。
- **局限**：① Zig 0.17.0 与 master 的 arena 实现差异未在打包机直接比对（以 master 源码+e2e 实证双保险）；② gin-contrib/cors 对 `"*"` 的输出未动态验证（可按 §35 方法在光猫生产实例 loopback 发 OPTIONS 预检一次即可钉死）；③ L 项 14 条未逐一复核；④ 本报告未重新跑构建/测试（纯静态复核）。

---
*复核人：TeleAgent（星辰）。2026-10-17。*

> AI生成
