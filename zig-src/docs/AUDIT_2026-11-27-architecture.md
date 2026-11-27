# 架构复核 2026-11-27 —— 架构设计 / 模块解耦 / 性能优化 / 静态分析

> **范围**：`zig-src/src` 全量（~52,000 行）：api / drivers（12 实现 + 3 可选变体）/
> http+webdav+sftp 服务端三件套 / client+cookiejar+config+frontend+archive+util。
> **方法**：4 个并行子代理逐行通读（api.zig、驱动层、服务端层、IO/工具层各一），
> 全部 P0/P1 论断再由人工逐条读码**一手复验**；本机 zig 0.17.0 工具链跑
> `zig build test` 与 aarch64 交叉编译做构建级验证。
> **分级口径**：P0 = 正确性 / 内存安全；P1 = 显著缺陷；P2 = 可维护性；P3 = 建议。
> **溯源约定**：正文中标注〔一手〕的发现均经人工读码逐行确认，行号可直接复核；
> 标注〔子代理〕的发现来自子代理报告并抽验通过（抽验命中率 100%），动手前建议复核行号。完整清单见附录 A。

---

## 0. 验证基线（一手）

| 项 | 结果 | 与既有基线比对 |
|---|---|---|
| `zig build test`（本机 Windows，0.17.0） | **556 pass + 4 skip**（560 总），无泄漏告警 | 与 STATUS 顶部"本机 Windows 556 pass + 4 skip"逐字一致 ✓ |
| 交叉编译 `aarch64-linux-musl -Doptimize=small` | **成功**，1,443,712 B，SHA256 `F271DCBF…` | STATUS 基线 1,443,624 B（§60.42，2026-11-02）→ **+88 B，哈希不同**，见下 |
| git 状态 | 工作区干净（仅未跟踪 `.temp/`），构建源 = `db9300bf`（2026-11-02，与基线产物同一提交） | — |

**未解的 88 字节漂移**〔一手〕：本机从与基线**同一提交**构建出 1,443,712 B
（哈希 `F271DCBFCFB8DA38FA39C2AD96859D47DA5A575646B489AFDE242A8E011B11E1`），
比 STATUS 记录的 1,443,624 B / `8fac3896` 大 88 B。STATUS §54.4 曾记录本机与
打包机**逐字节相同**（1,320,952 B 时代），此后两边编译器版本若有微差或记录口径
变化即会出现此漂移。**建议**：在打包机复跑 `build_remote.py` 对账一次，把
结论回写 STATUS 顶部基线行；若打包机仍是 1,443,624 B，则本机 zig.exe 与打包机
zig 已不是同一编译器构建，"本机产物可自测交付"的既定假设需要重新校准。

**静态扫描**〔一手〕：全仓无裸 `unreachable`；`catch unreachable` 22 处
（api.zig×1 / client.zig×1 / http.zig×1 / 115open×3 / pan115×7 / ec115×5 / m115×2 /
url.zig×1），抽查全部为「缓冲区尺寸数学上足够」的不变量断言或修复残留**注释**
（client.zig:667-670 的 L2 修复注释即属后者，实际代码已返回错误）；`@panic` 仅
3 处启动前置检查（config.zig:531、rt.zig:47/59）。无生产级风险。

---

## 1. 架构设计

### 1.1 资产（做对了的，后续演进必须保持的）

1. **依赖倒置干净**〔一手〕：`driver.zig` 用 `persist_hook`（driver.zig:238）、
   `FsBridge`（:253-276）、`ObjsUpdateHook`（:285-308）三组函数指针把「驱动层
   需要上层服务」的反向依赖全部倒置——否则 drivers→config/api 成环。
   Strm 驱动回调同实例其他挂载的 fs-bridge 是教科书式解法。
2. **两套 vtable 抽象窄而正确**（`Driver` / `Source`）〔一手〕：`Ctx.err_detail`
   值语义请求级出口（:42-75）+ 多线程写入禁令（:59-61）在 itvsh / pan123 /
   cloud189pc 三个并发上传驱动**全部遵守**（worker 只写共享 state，join 后才在
   请求线程合成消息）——纪律性经过跨驱动核验。
3. **comptime 驱动白名单双语义**〔一手〕：`has()`（全量构建应含）与
   `opted()`（仅点名构建含）分离（driver.zig:452-472），配合 build.zig 编译期
   校验（build.zig:48-71）杜绝两表漂移；未选驱动经 comptime 分支整体消除，
   "一个字节不进产物"的体积承诺有工程闭环。
4. **挂载表快照发布 + 显式锁序**：`mountsSnapshot/publishMounts`（api.zig:296-310
   附近）写方整 slice 替换、读方持锁只拷 slice 头；锁序文档化
   （config.zig:361-364 `g_save→storages`；multipart `mp_mu→s.mu`）；
   `dupeStorage` 临界区最小化（驱动 init 数十秒在锁外）。并发骨架健全、无死锁环。
5. **SFTP 五层分层 + Resolver/Fetcher 窄接口**〔子代理〕：handler.zig:52-104
   用 20 行函数指针把分发逻辑对 `api.App` 的依赖清零，约 40 条内存驱动纯单测
   佐证；ssh.zig 密码学原语全来自 std.crypto（X25519/Ed25519/Aes128/HmacSha256），
   自研仅协议封装；rekey stash（4MiB/4096 条双上限）经 psftp 真机回归。
   全库解耦最佳实践。
6. **跨协议共享登录限速**：64 桶 LRU 失败计数（api.zig:1237-1396）HTTP /
   WebDAV / SSH 三方共用同一实例——换协议绕不过限速，全工程最正确的一条安全决策。

### 1.2 缺陷

#### P0-A multipart 会话 UAF 竞态〔一手，本轮最高优先发现〕

**形态**：chunk / status / complete 三个 handler 均为「`mp_mu` 锁内 `get` →
解锁 → 用裸指针继续 `s.touch()` / `s.mu.lock`」，而**三条销毁路径都在解锁
`mp_mu` 之后**直接 `mpFreeSession(app, s)`（destroy）：

| 路径 | 证据（api.zig） | 时序 |
|---|---|---|
| chunk 裸指针逃逸 | :2553-2557 get → unlock → :2558 `s.touch()` | 与下述任一 free 并发即写已释放内存 |
| abort 锁外 free | :2853-2867 remove+unlock → :2868-2869 deleteFile+**mpFreeSession** | 前端「取消上传」即此路径 |
| sweep 锁外 free | :2309-2319 置 aborted+unlock → :2320-2323 **mpFreeSession** | 每次 multipart init 顺手清扫 |
| init stale 替换锁外 free | :2510-2522 remove+unlock → :2523-2525 **mpFreeSession** | 同 key 重传且旧会话非 receiving |

**触发流量形态**：原生前端取消上传（3 个 chunk worker 在飞 + abort）。
缺引用计数 / epoch / 分代屏障，属真实内存安全缺陷。
**配套**〔一手〕：`mp_seq` 非原子 `+=`（:2330 mpNewId 内与 ：2415 init 里
**双重自增**，后者为死代码）在 one-thread-per-connection 下是数据竞争 UB，
ID 唯一性目前靠 16 字节随机串兜底。

**修复方向**：把「摘除+touch+free」整体圈进 `mp_mu` 保护域，或给会话加引用
计数（get 时 +1、用完 -1、归零才 free）；`mp_seq` 改 `std.atomic.Value(u64)`；
删 ：2415 死代码。补一个「65 并发 chunk + 并发 abort」回归（参照既有背压 e2e 先例）。

#### P0-B HTTP 侧默认无连接上限 + 无分段超时（slowloris 暴露面）〔一手〕

- `max_connections` 默认 0 = 不限（config.zig:649 解析、:879 默认模板），
  http.zig:593 `if (self.opts.max_connections > 0)` 才背压——H04 只接通了旋钮，
  没给默认值。**SFTP 侧有 pre-auth 30s + 64 并发硬上限三件套默认生效
  （sftp_wire.zig:278 / channel.zig:81,690），HTTP 侧一项都没有**，两侧不对称。
- `read_timeout_s=300` 是 socket 级整体 RCVTIMEO：慢速攻击者每 <300s 发一个
  字节即可无限占用线程（slowloris）；无独立 partial-header 超时
  〔子代理：http.zig:802、1156-1165〕；chunked trailer 行数无上限
  〔子代理：http.zig:919-925〕。
- 光猫默认部署即处于暴露状态。

**修复方向**：`max_connections` 默认 64（对齐 SFTP）；partial-header 30s /
body-idle 60s 分段计时。

#### P0-C 关停路径 UAF 窗口〔子代理，结构一手核验〕

`drain()` 超时（10s）后 `run()` 返回，仍在飞的 detach 连接线程随后读
`self.opts` / `in_flight`（serveConnThread defer，http.zig:659-673 附近）构成
use-after-free；测试注释自述了该竞态。进程整体退出时窗口极小，但
`Server.deinit` 与连接线程并发真实可达（http.zig:627-636 ↔ 659-673）。
**修复方向**：drain 超时后跳过 deinit 直接 `exit(0)`（交 OS 回收），或连接
句柄计数引用。

#### P1-A init/setup TOCTOU + 凭据非原子发布〔一手〕

handleInitSetup（api.zig:1148-1199）：入口检查 `app.admin_hash.len > 0`（:1151）
与三字段写入（:1193-1195 `admin_user/admin_salt/admin_hash`）之间**无锁无原子
屏障**——窗口内含解析、哈希、config.putZig、save 整段。两个并发 setup 都见
空则都建管理员，最后落盘者赢；公网首启窗口存在竞速夺号（Go 侧有 DB 唯一索引
兜底，本工程没有）。且 ：1193-1196 三字段非原子逐个发布（新 user 旧 salt 撕裂
窗口）、旧切片不 retire（泄漏敏感串 + 违反同文件 M17 退役纪律的写法）。
handleMeUpdate（api.zig:3485-3491〔子代理〕）同款。
**修复方向**：setup 入口用 atomic cmpxchg「未初始化→初始化中」占位；三字段
合并进单个结构体切片一次性发布。

### 1.3 其余架构级（P1）

| 级别 | 问题 | 证据 |
|---|---|---|
| P1 | `api.zig` God-Module：9,281 行（34% 为内嵌 73 个 test 块），App struct 七类字段（锁/挂载/凭据/密钥/配置副本/前端宿主/multipart 会话表）。 | api.zig:103-171〔子代理，结构一手核验〕 |
| P1 | api↔webdav 循环 import，实为一个模块被文件系统切成两半（webdav 反向 import api 的 sign/writeObj/mimeFor/contentDisposition）。 | api.zig:79 ↔ webdav.zig:44〔子代理〕 |

---

## 2. 模块解耦

### 2.1 好的一面

api→driver 单向依赖（接口层而非实现层，生产代码不 import 具体驱动文件）；
SFTP Resover/Fetcher 窄接口；err_detail 通道与 progress 回调跨驱动统一；
util 层 json/rsa/aes/hash/xml/time 集中复用（rsa.zig 经独立实现对拍向量，
无发现）。

### 2.2 缺陷

| 级别 | 问题 | 证据 |
|---|---|---|
| P1 | **驱动层 ~600 行纯机械重复**（零协议分歧，抽 `drivers/common` 收益最大）：`dupeOr`×10（pan123:152 / aliyundrive:331 / cloud189pc:240 / cloud189:164 / quarkuc:144 / thunder:348 / 123open:165 / 115open:197 / quark:152 / pan115:140）、`ObjWriter`×7、`pathBase/parent`×4 另有两种命名变体、AWS SigV4×2（thunder:2103 ↔ pan123:1065 密钥派生链逐行等价）、**分片并发上传框架×3 同构**（itvsh UploadState:1226 ↔ pan123 BatchState:919 ↔ cloud189pc PartBatch:2024，连「每 worker 独立 client+arena」注释都互相引用）、persist+last_saved 去重模式×8 | 〔子代理逐项对照〕 |
| P2 | 路由四表手工同步（handle 前缀表 :652-753 / isRegisteredAuthedPath :798-817 / handleAuthed 分发 :841-875 / 模块头注释），历史上已踩过 `/api/me/update` 漏注册 404 | api.zig〔子代理〕 |
| P2 | JSON 信封手拼 ~10 处（`{"code":200,...}` 样板），历史 `}}}` 前科（STATUS §4.3）；缺 `jsonEnvelope` helper | api.zig:1115 等〔子代理〕 |
| P2 | 「按 mount_path 找挂载 + 比对 driver_ptr」样板三份拷贝——正是 P0-A 的病灶，抽函数顺带修竞态 | api.zig:2257/2585/2729〔子代理〕 |
| P2 | 189/189pc 无全驱动 `req_mu`（与 thunder/pan115/pan123/quarkuc 模式分叉），`applySession` 多字段非原子写存在撕裂窗口（概率极窄） | cloud189pc.zig:1403-1409〔子代理〕 |
| P2 | 建议拆分清单（api.zig 内部边界已天然清晰）：**multipart.zig**（1230 行连续块+Fake 驱动，修 P0-A 时整体搬走）→ **sign/auth.zig**（顺带解 api↔webdav 环）→ storage_admin → mounts → router → **download.zig**（707 行 RFC 7232 完整实现藏在 API 文件里） | api.zig:2095-3323/993-1569/3594-4162/4962-5668〔子代理〕 |

---

## 3. 性能优化

### 3.1 做对了的

per-request arena（http.zig keep-alive 循环内一轮 init/deinit）；上行
`Source.readAllInto` 块级复用缓冲（T7，O(块大小) 内存）；本地文件 GET 真流式
（64 KiB 栈缓冲 + iovec，无大分配）；body 三层缓冲（≤1MiB 内存 / spool 落盘 /
413，spool 失败路径 errdefer 不漏 fd）；189pc 上传 32 MiB 总内存闸（光猫特化）；
`aes.zig` 核取自 std.crypto 而非手写〔子代理〕。

### 3.2 缺陷

#### P0-D 代理回源下载：非流式 + 三重放大〔一手〕

api.zig:5493-5496 注释自认 "the client still buffers the full upstream
response; a streaming response reader remains a known follow-up"（** README
与代码注释均已记载的已知欠账，但放大面与副作用本轮有新细化**）：

1. **无流式出口**：`client.send` 把整份上游响应读进请求 arena，`res.write(up.body)`
   再拷贝进响应 Buf——内存峰值 **2× 文件大小**；上游忽略 Range 回 200 时全量
   （:5564-5574 此时才切片），并发 N 个下载 = 2×N×size。光猫 128-512 MB RAM
   下，一个 2 GiB 视频即确定性 OOM。client.zig:141-147 注释同样自认。
   (`Options.max_response_bytes` 默认 0 不限——该旋钮只交给了 SFTP Wire 的 4 MiB
   闸〔子代理：sftp_wire.zig:114-117〕，HTTP/WebDAV 代理路径没设。)
2. **每请求 `Client.init(a, .{}, &jar)`**（api.zig:5502-5504；webdav.zig:435/741、
   strm.zig:672 同款〔子代理〕）——连接池、TLS 会话、系统 CA 三重全丢：
   每次代理下载重新扫描全部系统证书 + X.509 解析 + 分配再丢弃
   （ensureCaBundle 依赖 per-instance `inner.now`，新实例必重扫
   〔子代理：client.zig:724-740〕）。
3. **传空 Options ⇒ 配置未生效**：代理路径没有消费 `zig.ca_bundle` /
   `zig.http_timeout`——用户配置的自定义 CA 与超时在回源路径形同虚设。

**修复方向**：`max_response_bytes` 回灌此路径（受 `zig.max_upload_mb` 量级
约束）；改为进程级共享 Client（CA 一次加载）；长期做流式转发出口（工作量大，
单独排期）。

#### P1 级性能缺陷

| 级别 | 问题 | 证据 |
|---|---|---|
| P1 | **TLS 握手阶段无超时**：`applySocketTimeout` 在 `inner.request()` 返回后才挂 socket——握手发生在 request() 内部；上游 TLS 静默挂起 ⇒ 线程永久阻塞。N01 修复遗留窗口 | 〔一手：client.zig:404-406、745-748〕 |
| P1 | **出站流量全局串行化**：每 Client 一把互斥锁包住整个请求生命周期（std.http.Client 非线程安全的补偿），分片上传 N workers 吞吐上限 = 单连接 RTT | 〔结构一手（client.zig:155-159 锁与理由注释）；锁位 ：368-369/604-606 子代理〕 |
| P1 | **配置写盘三件套**：① `syncStorages` 每次 save 在**长命 arena** 里重建整棵 storages 子树（旧子树无法回收，单调泄漏）；② save 无节流/去抖（每次全量 stringify+fsync+rename）；③ quarkuc `absorbCookie` **无值比对无 last_saved**——`__puus` 滚动机制下夸克几乎每个响应都回 Set-Cookie，一次深层 list 可触发十几次落盘（flash 磨损 + arena 泄漏放大）。quarkuc 恰是**唯一没走 persist 去重模式**的驱动 | 〔一手：config.zig:365-398、quarkuc.zig:288-310；save 流程子代理〕 |
| P1 | thunder 分片 PUT / MPU **无任何重试**（全驱动唯一；Go 上游 s3manager 默认 3 次）——弱网大文件成功率显著劣于其他 5 家 | 〔子代理：thunder.zig:1416-1458〕 |
| P2 | WebDAV COPY `fetchBytes` 整份进内存无上限（注释自认；目录已 501，单文件没闸） | 〔子代理：webdav.zig:727-746〕 |
| P2 | SFTP `sendData` 每分片 Buf init/deinit；READ 句柄 1 MiB 窗口缓存理论常驻上限 = 64 连接 × 4 并发 = 256 MiB 无总量闸 | 〔子代理：channel.zig:642-668、handler.zig:108,931〕 |
| P2 | `aes.zig` 每 16B 块重建轮密钥（现调用面小，2-5x 慢）；`writeObj` 每条目 fmtTime×2 + signForObj（千条目录 ≈4000 次分配）；fsList 循环内重算循环不变量 cleanPath | 〔子代理：aes.zig:42-62、api.zig:5684-5690/1661〕 |
| P2 | `jsonOkRaw` 双拷贝且注释宣称免拷贝（注释漂移）；archive.zig addChild 线性查重 O(n²) | 〔子代理：http.zig:410-417、archive.zig:185-193〕 |

> 注：**远程 Range 缓冲为 README/代码双重自认的已知欠账**（属 §3.2 P0-D-1），
> 本轮细化的是其并发放大公式与「代理路径配置未生效」副作用；其余性能项均为本轮新发现。

---

## 4. 静态分析

- **构建面全部干净**（§0）：test + 交叉编译双过，README 警告的「单测全绿 ≠
  能编出二进制」（惰性分析）本轮未触发。
- **WebDAV PROPFIND href 未做 XML 转义（P0，互操作正确性）〔一手〕**：
  `davHref`（webdav.zig:780-787）用 `urlmod.encode(.path)` 编码后直接进 `{s}`
  输出，而 `.path` 编码集**保留 `&` 字面量**（url.zig:38-40——`<` `>` 会被
  %-编码，`&` 不会）；writeColEntry/writeObjEntry 的 `displayname` 走了
  `xmlEscape`（:268-269/:286-287）而 **href 漏掉**。文件名含 `&`（"Tom &
  Jerry.mp4"）即产出非法 XML，严格解析器（如某些 Java/python 客户端）下整个
  目录列表失败。**修复一行**：`davHref` 输出补 `xmlEscape` + 回归测试。
- **JSON unpaired surrogate 产出非法 UTF-8（P1）〔一手〕**：json.zig:324-336
  高代理无后随 `\uDC00-\uDFFF` 时 cp 保持 0xD800-0xDBFF 直接 `appendUtf8`，
  产出 CESU-8 风格非法序列（Go 语义是 U+FFFD）。驱动 persist → save 落盘 →
  下次启动 `config.load` 的 utf8Validate 拒绝 → **服务拒启**，与文件头记录的
  历史"配置中毒"故障链完全同构。修复成本一行。
- **静默失败（P1）**：`parseBodyJson` 读 body 失败 `catch return null` →
  上层静默返回 status=200 空响应（api.zig:5745-5753〔子代理〕——JSON 端点拿到
  200+空 body 比错误码更难排查）；multipart `slice_md5s.append` OOM 静默丢片
  仍 complete 上游（api.zig:2657〔一手，chunk 成功路径确认〕、:2765〔子代理，
  complete 排空路径〕）——秒传/校验语义被破坏且无日志。
- P2〔子代理〕：webdav OPTIONS 宣告 `DAV: 1, 2` 但 LOCK 实际 405（PROPFIND 宣
  告 `1`，自相矛盾，Windows MiniRedir 会尝试 LOCK 后降级）；
  `InvalidatedTokens` 256 FIFO 溢出旧令牌复活（注释自证取舍）；LRU 淘汰无
  「锁定中豁免」（65 IP 可洗掉活动锁定）；`republishWithEdit` 旧驱动实例无限
  累积（文档化取舍但无计数告警）；wopan `childByName` 把 JSON 解析失败静默映射
  为 NotFound（wopan.zig:860-861）；cloud189 分页无防环绕 guard
  （cloud189.zig:771-837，对比 189pc/pan123/thunder 均有）；itvsh `login` 覆盖
  session_token 不 free（itvsh.zig:578，重登路径泄漏）；strict-kex（Terrapin
  CVE-2023-48795 缓解）未实现、无 EtM（光猫场景风险偏低，公网可绑端点应记入
  已知差距，ssh.zig:70〔子代理〕）；X25519 无显式 all-zero 公钥检查（深度防御）。
- P3〔子代理〕：`xml` close-tag 不校验；JSON 重复键取首个（Go 取最后）；
  `ec115` LZ4 解压无输出上限（对端可信）；`frontend` isSafeRelative 不认
  Windows 反斜杠（仅 Windows 构建，Linux 生产安全）；文档漂移两处
  （driver.zig 头注释引用不存在的 `api/spool.zig`；api.zig:1008-1009
  `server_version` 手工镜像 main.version 的升级必忘点）。

---

## 5. 修复路线图（优先级 × 工作量）

> **2026-11-27 落地回填**：#1-#6（全部 P0）已于当日修复并验证（本机
> Windows 563 pass + 5 skip / 568 总；aarch64 产物 1,447,632 B / `14F58FBA…`，
> +0.27%，未部署），详见 `docs/STATUS.md` §60.43。#7 起未动。
> 测试侧两处踩坑（config 单例 prev 必须在 load 前取、mp_sessions 桶数组
> 测试需显式 deinit）也已记入 §60.43。

| # | 项 | 级别 | 工作量 | 落地状态 | 要点 |
|---|---|---|---|---|---|
| 1 | multipart UAF + mp_seq | P0 | 1-1.5 天 | ✅ 已落地（§60.43 #1） | 引用计数化 + touch/mp_seq 原子化 + 删死代码；mount 查找三份收敛 mpMountFor；mpFreeSession 改按 driver_ptr 找驱动；+2 回归 |
| 2 | WebDAV href 转义 | P0 | 0.5 h | ✅ 已落地（§60.43 #2） | davHref 编码后过 xmlEscape + 回归 |
| 3 | HTTP 默认上限 + 分段超时 | P0 | 0.5-1 天 | ✅ 已落地（§60.43 #3） | head_timeout_s=30（首字节起整头墙钟，408）+ body_idle_timeout_s=60 + max_connections 缺省 0→64（显式 0 保留） |
| 4 | 代理回源闸 + Client 复用 | P0 | 0.5 天 | ✅ 已落地（§60.43 #4） | App 4 槽轮询代理池（消费 ca_bundle/http_timeout）+ zig.max_proxy_body_mb=256MiB 闸（507）；use_cookies=false |
| 5 | WebDAV COPY 大文件闸 | P0 | 0.5 天 | ✅ 已落地（§60.43 #5） | details 预检超 cap → 507（fetchBytes 之前） |
| 6 | 关停 UAF | P0 | 0.5 天 | ✅ 已落地（§60.43 #6） | run 返回后 inFlight()>0 → exit(0) 跳过 defer |
| 7 | TOCTOU + 凭据原子发布 | P1 | 0.5 天 | 未动 | setup 入口 atomic 占位；三字段单切片发布 |
| 8 | 静默失败修硬 ×2 | P1 | 0.5 天 | 未动 | parseBodyJson→400；slice_md5 OOM→fail 会话 |
| 9 | json surrogate 修复 | P1 | 0.5 天 | 未动 | U+FFFD 替换 + 写盘中毒回归 |
| 10 | persist-if-changed 公共层 | P1 | 1 天 | 未动 | 抽 drivers/common，8 家共用 + 根治 quarkuc 落盘放大 |
| 11 | syncStorages scratch 化 | P1 | 1 天 | 未动 | 序列化走临时 arena，M04 补完 |
| 12 | TLS 握手超时 | P1 | 1 天 | 未动 | 验证 std 0.17 可挂载点 |
| 13 | thunder 分片重试 | P1 | 0.5 天 | 未动 | 对齐 s3manager 3 次退避 |
| 14 | 打包机产物对账（88 B 漂移） | P1 | 0.5 天 | 未动（§60.43 验证边界保留） | 复跑 build_remote.py，结论回写 STATUS 基线行 |
| 15 | api.zig 拆分 | P2 | 3-5 天 | 未动 | 序：multipart.zig（可随已修的 #1 整体搬走）→ sign/auth（解环）→ storage_admin → mounts → router → download |
| 16 | drivers/common 机械重复收敛 | P2 | 2-3 天 | 未动 | ~600 行（dupeOr/ObjWriter/SigV4/并发框架/persist 模式） |
| 17 | client 流式出口 | P2 | 3-5 天 | 未动 | 价值最高、工作量最大，单独排期；#4 的 256MiB 闸已把该路径从 OOM 收口为明确 507 |

**P0 合计 ≈ 4-5 人日（实际一轮完成）；P1 ≈ 6-7 人日；P2 按季度节奏。**

---

## 6. 总体结论

这是一份**工程纪律罕见地高**的手写服务代码库：锁序声明、快照发布、err_detail
通道、"注释即架构"的 Go 对照体系、真机回归钉住行为——四个维度的底子远超同规模
私有项目平均水平。SFTP 子系统是全库解耦的最佳实践。

**结构性矛盾只有两个**：

1. **api.zig God-Module**（9,281 行 / 12 类职责）是后续演进的阻力点；
   multipart 状态机独立成模块时应顺带修掉全库唯一的内存安全缺陷（UAF 竞态，
   本轮经一手证实的最高优先发现）。
2. **下载方向无流式出口**——上行已流式（readAllInto）、下行双份全量缓冲，
   是光猫部署画像下最大的性能悬崖；且代理路径的 CA/超时配置实际未生效。

安全面上，HTTP 侧默认参数（无连接上限、无分段超时）与 SFTP 侧形成不对称暴露
面，属"旋钮有、默认值没给"的收尾级问题；WebDAV href 转义是一次性低成本的
互操作修复。

---

## 附录 A. 证据溯源

**一手复验（人工逐行读码确认，行号可直接复核）**：

| 发现 | 证据位置 |
|---|---|
| multipart UAF（chunk 逃逸 / abort / sweep / stale 三条锁外 free） | api.zig:2545-2669 / 2850-2871 / 2296-2325 / 2490-2526 |
| mp_seq 双重自增（含死代码） | api.zig:2330、2413-2415 |
| init/setup TOCTOU + 凭据非原子发布 | api.zig:1148-1199 |
| 代理回源双份缓冲 + 每请求 Client.init + 空 Options | api.zig:5493-5577；client.zig:141-147 |
| TLS 超时挂载在 request() 返回后 | client.zig:404-406 |
| max_connections 默认 0 | config.zig:649、879；http.zig:593 |
| davHref 未转义 + `.path` 保留 `&` | webdav.zig:259-289、780-787；url.zig:34-46 |
| syncStorages 长命 arena 重建 | config.zig:365-398 |
| quarkuc absorbCookie 无去重 | quarkuc.zig:283-310 |
| json unpaired surrogate → 非法 UTF-8 | json.zig:318-346 |
| slice_md5 OOM 静默丢片（chunk 路径） | api.zig:2657 |
| catch unreachable 全量扫描 + 抽查 | 全仓 22 处（§0） |
| 构建/测试/产物哈希/git 状态 | §0 |

**子代理报告（抽验命中 100%，动手前建议复核行号）**：路由四表、JSON 信封
样板、App 字段归类、超长函数 TOP5（handleConfigImport ~291 行 / handleDownload
~243 行 / handleMultipartInit ~189 行…）、驱动层全部重复对照清单、thunder 无
重试、cloud189 分页无 guard、wopan 解析失败映射 404、itvsh 重登泄漏、
DAV: 1,2 宣告矛盾、PROPFIND infinity 递归、COPY 无上限、SFTP 缓存总量无闸、
aes 每块重建轮密钥、sendData 分片分配、writeObj/ fsList 分配密度、
InvalidatedTokens/LRU 淘汰边界、republishWithEdit 累积、strict-kex 缺失、
X25519 零公钥检查、X509 每请求重扫、重定向 body 全量读出、双 Cookie 头、
URL 双重解析、no-proxy 差异、config setTopLevel 死代码、xml close-tag、
JSON 重复键、ec115 LZ4、archive O(n²)、Windows 反斜杠穿越、文档漂移两处。

## 附录 B. 与既有文档的承接

- **已知欠账（README / 代码注释双重自认）**：远程 Range 缓冲（→ 本轮 P0-D，
  细化了并发放大公式与配置未生效副作用）；WebDAV 目录 COPY 501（内存理由）；
  TODO.md §1 的驱动功能缺口（SharePoint/family_transfer/缩略图/video_preview 等，
  与本轮发现正交，不重复计入）。
- **本轮新发现**：multipart UAF、HTTP 默认暴露面（slowloris）、关停 UAF、
  TOCTOU、href 转义、json surrogate 中毒链、TLS 握手超时、全局串行锁、
  配置写盘三件套（arena 泄漏/无节流/quarkuc 放大）、thunder 无重试、
  88 B 产物漂移——STATUS/TODO/REVIEW_2026-11-01-sftp.md 均无记载。
- **建议后续动作**（不属本报告范围）：① STATUS 顶部基线行补本报告引文；
  ② 打包机对账 88 B 漂移；③ 修复路线图按 §5 顺序执行时逐条回填本文落地状态。

---

> AI 生成（TeleAgent 架构复核，4 并行子代理 + 人工一手复验 + 本机构建验证）

> AI生成
