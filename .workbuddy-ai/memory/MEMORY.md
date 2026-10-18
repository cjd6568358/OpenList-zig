# openlist-zig —— 项目长期记忆（2026-10-17 重整）

## 项目与目录

- **仓库 `D:\workspace\OpenList-zig` = Go 上游(OpenList/alist fork) + Zig 移植并存**：
  Go 在根目录（`drivers/`、`server/`、`internal/`、`pkg/`、`main.go`）；
  Zig 在 `zig-src/src`（`zig-src/build.zig`）。
  **上游唯一事实来源 = 本仓库 Go 树**，不要去 GitHub 拉。
- Zig 版不内嵌前端：`cdn`（302 到 jsdelivr）或 `dist_dir` 二选一，都不配 ⇒ 内置占位页。
- 本目录 `.workbuddy-ai/memory/` 随 zig-src 自包含，勿搬。

## 驱动状态（11 个注册项）

| 驱动 | Go Name | Zig | 状态 |
|---|---|---|---|
| local | `Local` | local.zig | ✅ 真机 |
| webdav | `WebDav` | webdav.zig | ✅ 真机 |
| itvsh 上海电信智家硬盘 | `上海电信智家硬盘` | itvsh.zig | ✅ 真机（私有驱动，仅本仓库有） |
| 189 个人 | `189Cloud` | cloud189.zig | ✅ 真机 |
| 189 家庭 | `189CloudPC` | cloud189pc.zig | ✅ 真机（签名逐字节一致） |
| 123 | `123Pan` | pan123.zig | ✅ 实现完成 |
| aliyun | `AliyundriveOpen` | aliyundrive.zig | ✅ 真机 |
| quark（+UC） | `Quark`/`UC` | quarkuc.zig | ✅ 实现完成 |
| 115 | `115 Cloud` | pan115.zig | ✅ 实现完成 |
| wopan 沃云盘 | `WoPan` | wopan.zig | ✅ 实现，未真机（无凭据） |
| strm | `Strm` | strm.zig | ✅ |

- **驱动名铁律**：`factory.key` 逐字节等于 Go `driver.Config.Name`；别名只能进 `Factory.aliases`。
- `pan123`/`quarkuc`/`itvsh` 上游 `Copy` 就是 NotSupport ⇒ vtable `.copy=null`，有测试钉住别顺手补。
- `115 Cloud` 依赖外部 SDK（`SheltonZhu/115driver`）、`WoPan` 依赖 `wopan-sdk-go`
  （其 Go 源码已 vendor 到 `zig-src/wopan-sdk-*.go` 供对照）⇒ 只能靠真实 API 回归。
- **BaiduNetdisk / Onedrive 暂不移植**（用户 2026-10-16 14:58 明确；`/baidu` 在用户备份里
  实际在用，导入后 init 失败属预期）。重启话题的唯一信号 = 用户说"百度网盘也要"。

## 构建约定

- **下载 GitHub 产物（Release 等）走 `https://ghfast.top/<原始URL>` 代理**（用户 2026-10-19
  指定）：本机直连 release 资产域名卡死不起步；api.github.com 的 JSON 可直连但共享 IP
  60 次/小时限额。
- **本机无 Zig 工具链**；编译/测试一律走打包机 **10.0.0.4**（`tools/build_remote.py`，
  /tmp/olz-build，zig 0.17.0，目标 `aarch64-linux-musl`，`-lc -fstrip`）。本机产物只能自测。
- `build.zig` 的 `-Ddrivers=` 编译期白名单：名字收 Go 名或 Zig 源文件名；
  **必须用 comptime 分支**（收集进数组会强制生成全部驱动，裁剪失效）。
- `tools/build_remote.py` 必须走 `zig build test`（`driver.zig` 依赖 `build_options`）。
- ⚠ `zig build` 会吞 "All tests passed" 且末尾打误导性 `failed command`（退出码实为 0）；
  判成功看 `--summary all` 的 `test success`。
- 每个驱动都要单元测试（`std.testing.allocator` 抓泄漏）。**D 盘满会假报 NoSpaceLeft/泄漏**。
- **Zig 0.17 语言层坑（2026-10-18 连踩三次）**：① 裸 `assert` 已移除 → `std.debug.assert`；
  ② `**` 数组重复不再是合法 token（`x ** n` 被词法成两个 `*`，报 whitespace 错）→
  定长数组 + `@memset(&buf, v)`；③ 驱动里 `init` 常是 struct **外**的自由函数，
  `self.foo()` 只能调到 struct 内声明的成员 —— 新方法必须放进 struct（否则
  `no field or member function named ...`）；④ `_ = self;` 在 self 已被使用时是编译错误。

## ★ 用户明确要求（不得再以"简化/体积/困难"为由跳过）

- **Go 配置必须无缝迁移**：Zig 配置 = Go 的**子集**，不该有差异。
  `tools/import_go_config.py` 已重写为直读 Go 备份的无损版。
- **允许 SQLite（C 桥接）；无 1 MB 体积上限；交叉编译不是 Zig 弱项**。
- **核心算法一律逐函数对齐 Go，不得自创**：密码哈希（Go `TwoHashPwd` 双层加盐 +
  `StaticHashSalt="https://github.com/alist-org/alist"`；⚠ Zig 若仍是单层 sha256 就是欠账）、
  签名、JWT claim、时间格式。验证沿用 189pc 的**逐字节**法。
- 不支持的驱动/端点要给**明确可查询**的理由，不能静默丢弃（结论统一进 `zig-src/docs/STATUS.md`）。

## 真机部署铁律（光猫 192.168.1.1:10022，测试只在 `/tmp/olz`）

- **绝不碰** `/opt/sq/openlist`、Go 的 `config.json`/`data.db`。
- **绝不用命令行子串筛进程**（2026-10-15 误杀过生产）。只按 **pidfile / `--port <n>`** 匹配；
  必须循环杀到 0 并 `netstat` 复核。脚本每次 start/stop 主动打印生产实例是否还在。
- **生产实例**：`/opt/sq/openlist/openlist server --config /opt/armbian/bin/openlist/config.json`，
  日志 `/tmp/openlist.log`，端口 15244 + SFTP 15222。挂了只能手动按原命令行 `nohup` 恢复。
- SSH 默认 cwd 是 `/root` ⇒ 写盘一律绝对路径 `/tmp/olz/...` 且同条命令 `mkdir -p`。
- 起后台服务必须 `< /dev/null`（否则 paramiko read() 永不到 EOF）；起服务+探测放同一条 exec。
- 设备 busybox：`chmod` 失效（用 paramiko sftp.chmod）、无 `curl`/`pkill`/`setsid`，
  `wget` 无 `--header`。大二进制用 SCP 传（SFTP 传 1MB 必断）。
- 工具：`zig-src/tools/deploy_device.py start|stop|status|restart [bin] [--port]`（默认 15399）。

## ★ 前端一律走 CDN，绝不在设备上养前端副本（用户强烈要求，已犯过一次）

在设备上放 dist 副本 = 把要消除的东西装回去，且掩盖"CDN 为什么取不到"。
正确做法：**先在沙箱（打包机）诊断再动设备**。
- 设备 CA 库无 GlobalSign 根 ⇒ drive.quark.cn 的 TLS 握手失败（`TlsInitializationFailed`，
  非 Zig 代码问题；189 用 WoTrus 所以成功）。
- **Zig 0.17 std 的 resolv.conf 解析 bug**：`HostName.zig` `takeSentinel('\n')` 遇文末无
  换行报 `EndOfStream` ⇒ 全部外网请求 `ResolvConfParseFailed`。部署时确保 `/etc/resolv.conf`
  末尾有 `\n`（打包机实测中招）。
- CDN fallback：`zig.cdn_fallbacks`（逐个重试 2 次）；主 cdn 挂 => 自动切。
  `RawIndex` 要带出**实际生效**的 cdn 覆盖 `site.cdn`，否则 `/assets` 全 302 到死域名。
  `registry.npmmirror.com` 专拦 .html（451）⇒ 不可用作外壳源。
- **CDN 取不到时二进制直接退出**（`CdnIndexFetchFailed`）—— 设计固有风险。

## 血的教训（踩过的坑）

1. **手拼 JSON**：`Buf.append` 写原始字节不转义，只有 `Buf.print` 转义 `{{}}` ⇒ 严格 JSON 解析测试兜底；
   前端 axios 把 JSON.parse 失败**静默降级成字符串**，只报"获取设置失败: Undefined"。
2. **字符串里有 ≠ 浏览器里能跑**：内联 `<script>` 里 HTML 实体不解码 ⇒ `&amp;&amp;` 语法错误、
   整个 script 不执行（首装表单从来没显示过）。改动前端行为至少跑 `node --check`
   （`tools/check_builtin_js.py` 已接 build 第 0 步），理想用真浏览器。
3. **前端自动化**：用 `playwright-core` + 系统 Chrome（别用 agent-browser，下载卡死）；
   点按钮必须按文字/role 定位，`.first()` 会点到「清除」。
4. **契约字段 bug 只看 HTTP 状态码发现不了**：`/api/me` 曾缺 `sso_id`/`allow_ldap`/`otp`、
   多输出 `otp_secret`/`token` ⇒ 登录后转圈。必须拿 Go struct tag 逐字段对。
5. **`permission` 曾硬编码 0** ⇒ 前端按位禁用按钮、界面功能全废。Go `InitSetup` 建 admin 写
   `0x71FF`；Zig 已改 `App.admin_permission`（真机实测 29183）。
6. **catch 分支里的 `try` 会跳过配对 unlock** ⇒ 管理面死锁。catch 里一律
   `_ = f() catch |e| {...}`。
7. **临时目录生命周期必须长过会写它的配置对象**（defer cleanup 太早 ⇒ 实测 500）。
8. **189 个人云 list 有秒级最终一致性延迟**（家庭云无）⇒ e2e 轮询容忍，不是 bug。
9. **`driver.ProgressFn` 是 0–100 百分比**，勿传字节数。
10. **`addition` 是字符串不是对象**，会原样落盘 cfg.json。
11. 路由白名单：`handle()` 只放行已知前缀进 `handleAuthed`；加新端点必须同时改白名单
    （曾因 `/api/me` 精确匹配漏掉 `me/update` ⇒ 404）。

## 功能边界（已定案，STATUS.md §22）

- **刻意不做**：分享 / SSH 公钥 / webauthn / 2FA / LDAP / 多用户·SQLite·SSO / 搜索索引 /
  离线下载 / 分片上传 / S3·FTP·SFTP·MCP 服务。中心思想：单管理员管理整个存储。
- **Zig 特有新增**：itvsh 驱动、CDN fallback、`@zig-setup`（配 CDN 也可用）、`zig.*` 配置块、
  编译期驱动白名单、内置页首装面板。
- 用户 Go 备份实况：`/baidu`(BaiduNetdisk)、`/onedrive` 在用但**暂不移植**；
  `/itvsh,/koofr,/jianguo,/123x2,/aliyun,/baidu,/quark,/ecloud_self,/ecloud_family,/hikvision`。

## 待办与文档入口

- **权威待办 = `zig-src/TODO.md`**；审计结论 = `zig-src/docs/STATUS.md`（§22/§23 边界与凭据表）。
- 已知欠项：全驱动真实 API+UI 回归（凭据备份 `zig-src/openlist_backup_2026_10_16 13_53_16.json`）、
  `model.Storage` 无 `modified` 字段、配置项 `delayed_start`/`cors`/`tasks`。
- **驱动维度差异审计 = `zig-src/docs/AUDIT_2026-10-18-drivers.md`（权威）**。
  更早的 10-11 / 10-17（v1/v2）/ REVIEW / REVIEW-v1 / DS 六份审计已于 2026-10-18
  清理（结论并入 STATUS §28–§46），需要原文用
  `git show 7356589e:<path>` 取回。
  **P0 三项已修**（2026-10-17 深夜，均带回归测试，构建结果见 STATUS §37）：
  ① `pan123.zig` refetch 竞态（BatchState.refetch_arena + currentUrls 持 mu）
  ② `cloud189.zig`/`cloud189pc.zig` 所有权 bug（dupeStr/normalizeName 恒 dupe + thumb/hash 深拷）
  ③ `cookiejar.zig:400` `.?` panic（改 if/orelse）
  **P1 已修**：wopan refresh 重加密（post 收明文、内部按通道加密）；sign_all 默认 true；
  登录 401 + LoginThrottle（5 次锁 5 分钟，全局计数——**Zig 0.17 Stream 无对端 IP**）；
  fs/get thumb/hashinfo/hash_info + writeObj hashinfo；fs/dirs 改裸数组子目录契约；
  http.zig 头校验（CRLF/NUL/DEL 拒绝）+ client.zig 请求头同规则；putZig 取 g_save_mutex；cl_buf 24→40。
  **架构事实**（解释一切差异的前提）：每请求一个 ArenaAllocator（`http.zig:622`）；arena `free` 只在最近一次分配时回退；
  `Client` 每实例一把全局锁（`client.zig:159`），并发靠每 worker 一个 Client；`model.Obj` 无 ID（Go 有），
  189/189pc 靠路径逐段翻页找 ID。**未上真机回归，修复须全量回归。**
- 验证基线：364 单测全过，aarch64 ~1.21MB；真机 e2e 32/32（2026-10-13 起多次全绿）。
- 磁盘紧张是老问题（D 盘曾 100%）；npm pack 的 23MB 前端包用完立刻删。
