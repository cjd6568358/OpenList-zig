# SFTP 收尾改动复核（2026-11-01）

复核对象：工作区未提交改动（`git diff` 12 文件 + 2 新文件，约 +1424 行）。

方法：逐文件读 diff 与全文，对照 Go 上游（`internal/model/user.go`、`server/handles/auth.go`、
`server/ftp.go`）、RFC 4253 §9 / RFC 4254 §5.3、以及 `docs/STATUS.md` 的既有约定；
另外独立复跑 `zig build test --summary all`（538 pass + 4 skip）。

结论：五项收尾与互通修复**方向正确、实现基本扎实**（资源所有权、幂等收尾、stash 双限都做对了）。
但发现 **1 个高危绕过**、**2 个会静默损坏数据的缺陷**，另有若干测试/文档问题。

| # | 严重度 | 位置 | 问题 |
|---|---|---|---|
| R1 | **高** | `webdav.zig:813` `checkBasic` | WebDAV Basic 认证完全不参与失败计数 ⇒ `/api` 的 5 次锁定可绕过，且是无成本 CPU 放大面 |
| R2 | 中 | `sftp/handler.zig:846` + `:894` | `size_known` 为真时的上游短读被映射成 `EOF` ⇒ 下载静默截断 |
| R3 | 中 | `sftp/handler.zig:770` | 续传把「驱动没报大小」当成「空文件」并返回成功 ⇒ 上传静默缺一块 |
| R4 | 中 | `api.zig:1269-1360` | 64 桶 LRU 与键匹配**零单测**；`authThrottleReset` 无调用者 |
| R5 | 低 | `api.zig:1304` | 锁定期内继续尝试不续期（Go 会续期）⇒ 固定 5 分钟后自动解锁 |
| R6 | 低 | `api.zig:1245` + STATUS 三处 | 「上游用 `IP:端口`」是事实错误：HTTP 登录走 `c.ClientIP()`（纯 IP），只有 FTP 带端口 |
| R7 | 低 | `tools/sftp_interop.py:207` | rclone 的 `deletefile` 返回码被丢弃；全 SKIP 时仍 exit 0 |
| R8 | 低 | `sftp/channel.zig:189` | 服务端主动 rekey 只有 opt-in 的 e2e，无单测；`shouldRekey` 无测试 |
| R9 | 低 | `main.zig:288` | `--sftp-ssh` 把主机密钥写死成**相对 cwd** 的 `data/ssh_host_ed25519_key`，忽略 `sftp.host_key`，从别的工作目录起服务会凭空建一个 `data/` |
| R10 | **中** | `sftp/ssh.zig` `Stash.max_items` | 上限 256 按「8 KiB 分片」估的，而 psftp 的 WRITE 是 ~4 KiB ⇒ 服务端主动 rekey 时 2 MiB 上传在 1 MiB 处撞条数上限、直接断连（`Software caused connection abort`）。**复核时被列为「未验证」，补验证时当场发现** |

---

## R1（高）WebDAV 绕过登录限速

**证据**

- `webdav.zig:813` `checkBasic()`：解析 `Authorization: Basic` → 比用户名 → `twoHashPwd` → `ctEqual`，
  **全程不调用 `api.authThrottle*`**。
- `/dav` 在 `api.zig:659`（OPTIONS）与 `:711` 无条件路由，没有 enable 开关（WebDAV 常开）。

**影响**

1. 本轮刚把限速做成按 IP 分桶，但攻击者只要把请求发到 `/dav/`（`curl -u admin:guess /dav/`），
   就完全绕开 5 次锁定 —— 分桶做得再对也不生效。这与新注释「HTTP 登录与 SSH 认证共用同一份
   计数：换协议不能绕过限速」直接矛盾。
2. 每次失败的 Basic 认证都会跑一次 `twoHashPwd`（双层加盐哈希，代价不低）。无上限重试 ⇒
   单连接就能把 CPU 打满，比 HTTP 登录路径更省攻击者的成本。

**建议**

`checkBasic` 开头取 `req.peer_ip` 调 `api.authThrottleAllow`，三条失败分支改调
`authThrottleFailure`，末尾成功调 `authThrottleSuccess`。约 6 行，且能进现有 `webdav.zig`
的单测（`/dav` 401 用例旁边加一个「第 6 次回 429」）。

---

## R2（中）`size_known` 下的短读被当成 EOF ⇒ 静默截断

**证据**

- `readAt`（`handler.zig:859`）：短读时分两路 —— `!size_known` 返回已读到的部分（正确），
  否则 `return error.OutOfRange`（`:894`）。
- `handleRead`（`:843-849`）把 `error.EndOfStream, error.OutOfRange` **一起**映射成 `.eof`。
- 改动前同一位置走 `statusFor(e)` ⇒ `.failure`（`git show HEAD` 已核对）。

**影响**

驱动**报了 size** 却少给字节（上游截断、限速返回部分内容、CDN 抖动）时，客户端拿到 `EOF`
就认为「文件就这么长」，于是**下载出一个残缺文件且没有任何错误**。这与本项目反复强调的
「绝不静默少一块」是同一类问题，只是方向从上传变成下载。

**建议**

`error.OutOfRange` 只在 `!rs.size_known` 时映射成 `.eof`；已知大小时保留 `statusFor(e)`
（`.failure`），让客户端明确失败。现有用例 `:2233` 覆盖的是 `!size_known` 分支，
新增一条「size 已知但 fetcher 短读 ⇒ 回 failure」即可钉住。

---

## R3（中）续传把「大小未知」当成「空文件」

**证据**

`preloadExisting`（`handler.zig:770`）：`if (det.size <= 0) return 0; // 空文件：没有可续的内容`

**问题**

同一个文件在 `handleOpen` 里的判定是 `size_known = f.size > 0` —— 即 **`size == 0` 被当作
「未知」**。到了续传路径，`size <= 0` 却直接被当成「空文件」并**返回成功**。驱动报 0（分享类、
部分网盘）时会预载 0 字节、然后接受客户端在 `offset > 0` 处的 `WRITE`，前面那段就是空洞 ——
正是函数头注释里写明要避免的「上传成功却缺一块」。

**建议**

`det.size == 0` 无法区分「真空」与「未知」，一律 `return error.NotSupported`（客户端拿到
`op_unsupported` 会退回 trunc 上传，代价只是重传）；要更聪明就先 `fetch(0, 1)` 探一下。

---

## R4（中）分桶逻辑没有单测

- `api.zig` 本轮 **0 条新增测试**（其余文件：handler 5、ssh 4、channel 1）。
- `authThrottleReset`（`:1356`）无任何调用者，属于死代码 —— 它显然是为测试准备的，但测试没写。
- 裸奔的行为包括：纯 IP 键匹配、全局桶（`key_len == 0`）与「空位」的区分、LRU 淘汰、
  锁定期满复位、超长键截断。这些都是「写错了不会报错、只会静默失效」的类型
  （例如把 `used` 换成 `key_len == 0` 判断，全局桶会被第一个来源覆盖）。
- 附：`recordSuccess` 也走 `slot()`，表满时一次**成功**登录可能淘汰掉一个**正在锁定**的桶。
  低危（管理员 IP 通常已在表内），但如果要修，成功路径应「有则清零、无则不新建」。

---

## R5（低）锁定期不续期，与 Go 不一致

Go `server/handles/auth.go:50-52`：锁定期内**每次**请求都 `LoginCache.Expire(ip, 5min)`，
即攻击者越试锁得越久。Zig `allow()`（`api.zig:1304`）只在 `locked_until > now` 时返回 false，
不续期 ⇒ 固定 5 分钟后自动解锁，攻击者可以精确按 5 分钟节奏爆破。

这是**改动前就存在**的行为（不是本轮引入），但既然本轮目标是「对齐 Go 的限速语义」，
顺带补上更完整。

---

## R6（低）文档里的上游事实错误

`api.zig:1245` 与 `STATUS.md` §4696 / §5038 / §5360 都写「上游 Go 用 `IP:端口`」。实测：

- HTTP 登录：`server/handles/auth.go:48` `ip := c.ClientIP()` —— gin 的 `ClientIP()`
  剥掉端口，**纯 IP**；
- 只有 FTP：`server/ftp.go:116` `ip := cc.RemoteAddr().String()` —— 这个**带端口**，是那条
  「限速形同虚设」结论的来源；
- Go 的 SFTP（`server/sftp`）根本没有 `LoginCache`。

结论（键必须纯 IP）没错，但归因错了，而且已经写进 3 处文档。建议改成
「上游 FTP 用 `RemoteAddr().String()`（带端口）⇒ 失效；HTTP 登录用 `ClientIP()`（纯 IP）」。

---

## R7（低）`sftp_interop.py` 的两处「看起来过了」

1. `:207` `run(common + ["deletefile", ...])` 的返回码被丢弃 ⇒ rclone 的 `rm` 失败仍然报 PASS，
   与脚本自称的「ls / put / get / rm 往返」不符。psftp / WinSCP 两条都检查了 rc，只有 rclone 漏了。
2. `ran == 0`（全部 SKIP）时只打印一行提示，**退出码仍是 0**。CI 里「什么都没装」看起来和
   「全通过」一样。

---

## R8（低）服务端主动 rekey 缺少单测

`e2e` 里的 `--expect-server-rekey` 是 opt-in 的（默认不跑），单测侧只有 `ssh.zig` 的
「stash 入队 / 上限 / 计数归零」三条，**没有**「主动 rekey → stash 补投 → 数据完整」的集成用例，
`shouldRekey()`（`channel.zig:189`）也没有直接测试。这条路径是本轮最容易出「上传随机卡住」的地方，
建议补一条：构造 `rekey_limit` 很小 + 内存 stream，断言 stash 里的包按序被 dispatch。

---

## 逐项复核通过（确认无问题）

| 项 | 核对点 |
|---|---|
| `util/peeraddr.zig` | IPv4 按内存序取 4 字节（不反转）、IPv6 输出压缩形式不带端口、缓冲区不足返回 `null` 不截断、Windows 明确 `null`（`@compileError` 的 `std.posix.getpeername` 确实不能用，文件头解释准确） |
| 桶键生命周期 | `http.zig:691` 的 `peer_buf` 在 `serveConn` 栈上、循环外 ⇒ 覆盖整条连接的所有请求；`Request.peer_ip` 注释明确「处理器不得存起来」 |
| 续传所有权 | `createFile` 失败 / `preloadExisting` 失败两条路径的显式释放与 errdefer **不会同时跑**（正常 `return` 不触发 errdefer），无二次释放；temp 文件两条路径都被删 |
| 续传正确性 | 分块拉取每块一个 arena（不把整份文件挂请求 arena）、短读 `got.len == 0` 直接报错、`size > limit` 先拒绝、text 源直写不绕 fetcher |
| `size_known` | `local_size` / `text` 会覆盖成「已知」；`readAt` 的窗口预算不再被 0 夹死；`offset >= size` 仅在有 size 时短路 |
| 服务端 rekey | `kex()` 走 `pending_client_kexinit == null` 分支 ⇒ 先发自己的 KEXINIT、再读对端的 ⇒ **两边同时发起不会死锁**（KEXINIT 交叉是正常流程，不是错误路径） |
| stash | 双限（4 MiB / 256 条）、`payload` 深拷贝（`pkt.raw` 会被释放）、`Conn.stash` 的地址在 `loop()` 里取（避免按值返回的临时对象悬垂）、`deinit` 顺序 `c` 先于 `t` |
| 字节计数 | `kex_bytes_in/out` 在 KEX 结束时归零，否则低阈值会连续 rekey |
| EOF 握手 | `closeChannel` 幂等（收到对端 CLOSE 不再回一个）、`closing` 状态机只认 CLOSE/DISCONNECT、256 条兜底、单测覆盖「EOF 后不立刻返回 / 丢弃中间包 / CLOSE 到达才收尾」 |
| host key 0600 | `fromMode` 存在性检查 + 老文件显式 `setPermissions` + 失败只 WARN 不致命 + Windows 降级路径有日志 |
| 接线 | `--sftp-ssh` 调试端点显式传 `rekey_limit = 0`；配置路径负值当 0；`serveSsh` 启动时把 rekey 策略打进日志 |

## 建议的修复顺序

1. **R1**（安全绕过，6 行 + 1 个单测）
2. **R2 / R3**（静默损坏数据，各 1-3 行 + 单测）
3. **R4 / R8**（补测试，把 R1-R3 的修复钉住）
4. R5 / R6 / R7（语义与文档）

---

## 修复记录（2026-11-01 下午，已落地）

| # | 状态 | 改动 |
|---|---|---|
| R1 | ✅ 已修 | `webdav.zig`：`handle()` 先过 `authThrottleAllow(req.peer_ip)`，锁定期回 429 空正文；`checkBasic` 返回值改 `enum { ok, missing, invalid }`，只有 `invalid` 记失败（对齐 Go 的 `!ok` 分支不计数） |
| R2 | ✅ 已修 | `handler.zig` `handleRead`：`OutOfRange` 只在 `!size_known` 时算 EOF，已知大小回 `FAILURE` |
| R3 | ✅ 已修 | `handler.zig` `preloadExisting`：`det.size <= 0 ⇒ NotSupported`（不再假装续传成功） |
| R4 | ✅ 已修 | `api.zig` 新增 5 条分桶单测（隔离 / 空键 / 清零 / 过期 / LRU）；`recordSuccess` 改走 `find()` 不再新建桶；`authThrottleReset` 被单测使用 |
| R5 | ✅ 已修 | `allow()` 锁定期内续期（`locked_until = now + 5min`），+1 条单测 |
| R6 | ✅ 已修 | `api.zig` 注释与 STATUS §9 / §60.35 / §60.37 三处表述更正为「FTP 带端口、HTTP 纯 IP、上游 SFTP 无 LoginCache」 |
| R7 | ✅ 已修 | `sftp_interop.py`：rclone `deletefile` 检查返回码；全 SKIP 退出码改 2 |
| R8 | ✅ 已修 | `channel.zig` 新增 2 条单测（`shouldRekey` 阈值与 `rekey_busy`、`drainStash` 顺序补投） |
| R9 | ✅ 已修 | `main.zig`：`--sftp-ssh` 改用 `cfg.sftp_host_key`（真机验证时踩到的：写死的相对路径在 `zig-src/` 下建了个 `data/`） |
| R10 | ✅ 已修 | `ssh.zig`：`Stash.max_items` 256 → 4096（按 4 KiB 分片反推），push 失败时打 `items/bytes/incoming`，新增 512×4134 单测。2 MiB ×3 轮、8 MiB（rekey 48 次）psftp/WinSCP 全过 |

验证：**550 pass + 4 skip**，0 失败 0 泄漏（+12 条）。详见 `STATUS.md` §60.39。

**真机验证（光猫 aarch64，端口 15399，未碰生产）**：

| 步骤 | 结果 |
|---|---|
| 源 `127.0.0.1` 5 次错凭据 → 第 6 次正确凭据 | 401 ×5 → **429** |
| 源 `192.168.1.1` 正确凭据 | **207**（另一个桶，不受影响） |
| 源 `192.168.1.1` 5 次错凭据后走 `/api/auth/login` | **429**（同 IP 跨协议共用） |
| 源 `127.0.0.1` 的 WebDAV 锁住后，SSH（pscp，正确口令） | **Access denied** + 日志 `from 127.0.0.1` |

日志里是真实 IP（不是 `unknown`）⇒ POSIX `getpeername` 正常。分桶、跨协议共用、
SSH 侧接线三条全部落地。唯一没解释的是隧道上 pscp 提前放弃时出现过 **1 次**
`Remote side unexpectedly closed network connection`，`-v` 重跑与本地直连 8/8 均干净，
**未复现，不认定缺陷**（细节见 STATUS §60.39）。

## 未验证项（诚实说明）

初版复核留下两条「未验证」，后续都已补上，其中一条当场变成 R10：

- ~~Windows 上 `peeraddr` 恒为 `null`，分桶只有单测覆盖~~ → **已在真机（aarch64）
  用两个源 IP 验过**：127.0.0.1 锁住、192.168.1.1 不受影响，同 IP 跨协议共用。
- ~~服务端主动 rekey 只有 paramiko 验过，第三方客户端未验证~~ → **补验证时发现
  psftp 直接断连**（R10），修好后 2 MiB ×3 轮、8 MiB（rekey 48 次）全过。

仍存的不确定性：真机上那轮 pscp 提前放弃时出现过 1 次 `Remote side unexpectedly
closed network connection`，`-v` 重跑与本地 8/8 均干净，未复现（详见 STATUS §60.39）。

---

## 附记（2026-11-02）：复审本报告落地后的 13 个本地提交

对 10-31 审计落地以来到 `c8e24304` 为止的 13 个本地提交又做了一轮三路子代理
复审（SSH 层 / 应用层 / WebDAV / 文档一致性，主控逐条核验代码行号）。结论：
R1–R10 的落地**逐条吻合**，协议本体正确；新发现集中在边界与所有权——
**1 项 P0**（pre-auth 资源耗尽：零超时 × accept 无上限，上轮 P0-3 唯一没落地的）
与 **8 项 P1**（`k_mpint`/`toOwned` 泄漏、512 预算压死合法 stash 窗口、嵌套 rekey
acc 下溢、`handleOpen`/`registerDir` 双释放、offset u64 回绕、200 全量下载无上限、
锁定期日志可刷穿闪存、kexinit dupe 顺序），已全部修复并加回归单测。真机验证
阶段又抓到两条并当天闭环：**目录句柄 CLOSE 堆越界**（本报告附记下方的
「P2-A」定级被证明是错的——`*DirState` 强转 `*FileState` 读 tag 是分配块外的
越界读，是否触发取决于堆历史；补 `h.kind` 检查）与 **0600 测试 Linux 编译炸**
（`Io.File.Stat` 无 `mode` 字段；打包机测试闸门自 d41acfcc 起实际是断的，
11-01 的三个构建都没过这道闸）。

**特别相关的一条**：R10 修的 `max_items` 256 → 4096 曾被 `readKexPacket` 的
512 次循环预算架空——stash 的包也计入预算，而合法最坏值恰 ~512 条（psftp
4 KiB WRITE × 2 MiB 在飞窗口），高 BDP 链路上同症状会复活（局域网 BDP 小测不出）。
修法是 stash 分支不占预算、预算只数杂项包，并有「600 条数据包后 KEXINIT 仍读得到」
的单测钉住。

完整清单、修复方式与验证：`STATUS.md` §60.42（终态 560/560 Linux 原生、
隔离实例 e2e 15/15、已切生产 `8fac3896`）。

> AI生成
