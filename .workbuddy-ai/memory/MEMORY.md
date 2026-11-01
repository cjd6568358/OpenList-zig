# openlist-zig 长期记忆（2026-11-01 精简）

## 项目

- `D:\workspace\OpenList-zig` = Go 上游（`drivers/ server/ internal/ pkg/ main.go`）+ Zig 移植（`zig-src/src`）；**交付以 Zig 为主**，Go 树是**唯一上游事实来源**（别去 GitHub 拉）。
- 前端：`cdn` 或 `dist_dir`；都不配 ⇒ 占位页。`public/dist/` 只有 README ⇒ 仓库内无前端产物，加不了 UI 控件。
- 记忆目录 `D:/workspace/OpenList-zig/.workbuddy-ai/memory/`；根目录整洁铁律：只允许上游文件 + `zig-src/ .github/ .workbuddy-ai/`。

## 驱动（15 存储 / 14 挂载，均有单测）

| 驱动 | Go Name | 状态 |
|---|---|---|
| local/webdav/strm、itvsh | `Local`/`WebDav`/`Strm`/`Itvsh` | ✅ 真机 |
| 189 个人/家庭 | `189Cloud`/`189CloudPC` | ✅ 真机（签名逐字节一致） |
| 123 / quark+UC / 115 / aliyun | `123Pan`/`Quark`,`UC`/`115 Cloud`/`AliyundriveOpen` | ✅ 完成（aliyun 401 自动 refresh） |
| wopan | `WoPan` | ✅ 实现，未真机 |
| 迅雷 / 专家 / 网页版 | `Thunder`/`ThunderExpert`/`ThunderWeb` | ✅ 真机；`/thunder` 长期 errored，**日常用 `/thunderweb`** |
| 123 Open/QuarkOpen/115 Open | 同名 | ⚠️ 编译期可选（`opted()`），缺凭据 |

- **`factory.key` 逐字节等于 Go `driver.Config.Name`**，不设别名。**label 不是展示名**：中文名来自 bundle `assets/entry-*.js` 的 109 条映射，Zig `label` 只进启动日志（用户要求 label 保持中文）。
- `pan123`/`quarkuc`/`itvsh` 上游 Copy 即 NotSupport ⇒ `.copy=null`，有测试钉住别补。
- **可选驱动用 `opted()` 而非 `has()`**（`has()` 全量构建下恒 true）。`-Ddrivers=` 按 `,`/空格分词 ⇒ 只传 Zig 文件名（`115open`）。
- **addition_schema 键 = Go 的 json tag**（非字段名），每驱动有「schema 键 == parse 键」单测；**select 的 `options` 必须是逗号字符串**（JSON 数组静默降级成空串）。
- 迅雷：S3 必须 virtual-hosted；登录限频 ⇒ 别在循环里重建存储。`/thunder` 走不通真因：出口 IP 被风控 + 安卓端点必发滑块。
- **迅雷网页版**（权威 `zig-src/docs/THUNDER_WEB_RE_2026-10-20.md`）：`captcha_sign="1."+15 轮 md5(prev+salt)`，盐表随发版变 ⇒ `tools/thunder_web_sign_harness.js` 重取；captcha 300s；refresh_token **不轮换**，`4126 has been refresh at` 真因是**多实例并发 refresh**；登录 4 步纯 HTTP（SSO cid `XW5SkOhLDjnOZP7J` + PKCE S256）。回归 `tools/thunder_web_probe.py` / `thunder_web_e2e.py`。
- **WoPan refresh_token 一次性轮换**：只能由驱动刷（成功即 `save()` 落盘）；外部探针刷一次就消费掉必丢。令牌 `zig-src/tools/creds.local.json`（gitignored 0600）。`115`/`WoPan` 依赖仓库外 SDK ⇒ 只能真实 API 回归。
- **BaiduNetdisk / Onedrive 暂不移植**（10-16 明确）；重启信号 = 用户说「百度网盘也要」。

## 构建

- Zig 0.17.0：`C:\Program Files\zig-x86_64-windows-0.17.0\zig.exe`；**基线 551 pass + 4 skip**（`zig-src` 下跑）。
- 必须：① `tools/ziglib_patch.py "<toolchain>/lib" C:/zigcache/olz-ziglib`（已就绪，`grep -c "openlist-zig patch"` = 2）；② 用 **`ZIG_LIB_DIR=C:/zigcache/olz-ziglib`**（`--zig-lib-dir` 0.17 不认）；③ `ZIG_GLOBAL_CACHE_DIR`/`ZIG_LOCAL_CACHE_DIR` → `C:/zigcache/olz`。
- **🔴 裸调 `zig build`（漏 ZIG_LIB_DIR）= 静默丢 TLS 补丁**：不报错，部署后 Quark/UC 消失（14→12）。尺寸判据代码一变即失效（**11-01 生产 aarch64 1,442,536 B `b7082785`**，win 1,945,088 B `74d87640`）；**最终判据：部署后 grep `mount(s) published` = 14**。
- ⚠ `zig build` 吞 "All tests passed" 且末尾打误导性 `failed command`（退出码 0）；**跑测试一律带 `--summary all`**，判据是 `N pass, M skip`。裸跑 `.zig-cache/o/*/test.exe` 必崩（`--listen=-` 是 server 模式）——正常现象。裸 `zig test src/tests.zig` 编译不过（缺 `build_options`）。
- 单测一律 `std.testing.allocator`；**D 盘满会假报 NoSpaceLeft/泄漏**。写盘只写 `/tmp`；工具链 cache 只读。
- **Zig 0.17 坑**：裸 `assert` 移除 → `std.debug.assert`；`**` 数组重复非法 → 定长数组 + `@memset`；驱动新方法必须放进 struct；`_ = self;` 在 self 已用时是编译错误。
- **CLI**：`openlist version`（六行，对齐 Go `cmd/version.go`）/ `-v`；裸 positional **必须 `.json` 结尾**，否则 `unknown command` + exit 2（旧行为曾静默起服务）。CLI 输出走 stderr。
- 打包机 `10.0.0.4` 可选（`tools/build_remote.py`，`/tmp/olz-build`）。GitHub 产物走 `https://ghfast.top/<原始URL>`，api JSON 直连（60 次/小时）。`remote.py`：远端命令作**单个带引号参数**、内联用绝对路径、`--put` 去掉前导斜杠。**经 SSH 的远程删除/移动被 sandbox 拦截** ⇒ 需用户手动。

## ★ 用户硬要求（不得以简化/体积/困难跳过）

- **Go 配置必须无缝迁移**（`tools/import_go_config.py` 无损版）。
- **允许 SQLite（C 桥接）；无 1MB 体积上限；交叉编译不是 Zig 弱项**。
- **核心算法逐函数对齐 Go，不得自创**：`TwoHashPwd` 双层加盐 + `StaticHashSalt="https://github.com/alist-org/alist"`、签名、JWT claim、时间格式。
- 不支持的驱动/端点给**明确可查询**的理由（进 `zig-src/docs/STATUS.md`），不静默丢弃。

## 真机铁律（光猫 192.168.1.1:10022，测试只在 `/tmp/olz`）

- **绝不碰** `/opt/sq/openlist`、Go 的 `config.json`/`data.db`；**绝不用子串筛进程**（10-15 误杀过生产），只按 pidfile / `--port <n>`。
- **生产**：`/opt/armbian/bin/openlist/openlist server --config .../config.zig.json`，日志 `/tmp/openlist.log`，端口仅 **15244**；启停 `/opt/script/openlist_start.sh [stop]`（幂等+重试）。**无看门狗**，崩溃后手工跑它。
- **🔴 绝不对光猫下重启/停机命令**：无 `reboot`；`ubus call system reboot` 会杀 easytier/xray/rtp2httpd 却不完成。**重启只有用户能发起**。
- **重启生产前必须数进程**（遍历 `/proc/*/exe` 匹配 `*openlist*`）——必须 **1 个**且不带 `(deleted)`（10-20 曾 3 个抢 15244 写坏 config）。
- **日志口径**：请求打点降 `log.debug` ⇒ 稳态 ≈0–1 行/分；细节用 `--log-level debug`。`/tmp` = tmpfs 220.9 MB ⇒ 日志不轮转仍是隐患。
- SSH cwd `/root` ⇒ 绝对路径；起后台服务必须 `< /dev/null`；busybox 无 `curl`/`pkill`/`setsid`、`wget` 无 `--header`。**本机 `tools/deploy_device.py` 跑不了**（paramiko）⇒ `scp` + `chmod 755` + `nohup ./openlist ... --port 15399`（免密）。无凭据回归 `tools/driver_matrix.py <base> --user admin --password ...`。
- **留档**：`/opt/armbian/...` → `D:/workspace/server/armbian/...`；`/opt/script`、`/opt/apps`、`/root` → `D:/workspace/server/f4610u/...`；只留最新。改设备上运行中脚本：put 到**同盘** `/opt/script/<name>.new` → `sh -n` → `mv -f`（**不能从 /tmp mv**）。

## ★ 前端走 CDN，绝不在设备养前端副本

- 设备放 dist = 把要消除的东西装回去，还掩盖「CDN 为什么取不到」。**先在沙箱诊断再动设备**。
- **quark/UC TLS 失败 = 缺 ECDSA 套件补丁**（非 CA）：Zig 0.17 std 只 offer ECDHE-RSA ⇒ 必须 offer c02b/c02c/cca9（`tools/ziglib_patch.py` 改 `tls/Client.zig` 四处）。**症状静默**：`TlsInitializationFailed`，挂载 14→12，服务照常 200。
- **Zig 0.17 std resolv.conf bug**：`HostName.zig` 遇文末无换行报 `EndOfStream` ⇒ 全部外网请求 `ResolvConfParseFailed`。确保 `/etc/resolv.conf` 末尾有 `\n`。
- `zig.cdn_fallbacks` 逐个重试 2 次；`RawIndex` 要带出**实际生效**的 cdn 覆盖 `site.cdn`；`registry.npmmirror.com` 专拦 .html（451）⇒ 不能做外壳源。

## 血的教训

1. 手拼 JSON：`Buf.append` 不转义，只有 `Buf.print` 转义 `{{}}` ⇒ 严格 JSON 测试兜底。
2. 字符串里有 ≠ 浏览器能跑：内联 `<script>` 不解 HTML 实体 ⇒ `&amp;&amp;` 语法错、整段不执行。改前端至少 `node --check`（`tools/check_builtin_js.py` 已接 build 第 0 步）。
3. 契约字段 bug 光看状态码发现不了：`/api/me` 曾缺 `sso_id`/`allow_ldap`/`otp`、多输出 `otp_secret` ⇒ 登录转圈；必须逐字段对 Go struct tag。`permission` 应为 `0x71FF`（真机 29183）。
4. catch 里的 `try` 会跳过配对 unlock ⇒ 死锁；catch 里一律 `_ = f() catch |e| {...}`。
5. 临时目录生命周期必须长过会写它的配置对象（defer 太早 ⇒ 实测 500）。
6. 189 个人云 list 有秒级最终一致性延迟（家庭云无）⇒ 轮询容忍，不是 bug。`driver.ProgressFn` 是 0–100 百分比；`addition` 是字符串不是对象。
7. 路由白名单：`handle()` 只放行已知前缀进 `handleAuthed`，加端点必须同步改白名单。
8. 架构：每请求一个 ArenaAllocator（`http.zig:622`）；`Client` 每实例一把全局锁（`client.zig:159`）；`model.Obj` 无 ID ⇒ 189 靠路径逐段翻页找 ID。
9. busybox ash 的 `trap 'cmd' INT TERM` 跑完会从中断处继续循环 ⇒ trap 里必须显式 `exit`。
10. **协议实现只用一个客户端验证 = 必然漏**：pscp 只发 `CHANNEL_EOF` 就等我们关，OpenSSH 自己发 `CLOSE` ⇒ 「不回 close」的洞用 OpenSSH 永远测不出。**每加一个协议层，至少用两套独立实现回归**。
11. **`Transport.readPacket` 返回分配块 +5 的子切片，不能直接 `free`**（`SafeAllocator` panic）⇒ 用 `readPacketOwned` → `OwnedPacket.deinit`。
12. **「验证假通过」三连**：① `timeout`/`env` 套在 Git Bash 的 `pscp` 前会**静默什么都不做**（rc=0、文件没传）；② paramiko 的 rekey 计数改实例属性无效（`_handler_table` 存 bound method）⇒ 计数恒 0 像没 rekey；③ 造数据写成 `bytes(range(256))*(kib//256+1)` ⇒ 512 KiB 只生成 768 B。**生成数据必须 `assert` 钉死长度**。

## 边界与 API 契约

- **刻意不做**：分享 / SSH 公钥 / webauthn / 2FA / LDAP / 多用户·SQLite·SSO / 搜索索引 / 离线下载 / S3·FTP·MCP 服务。中心思想：单管理员管整个存储。
- **Zig 特有**：itvsh 驱动、CDN fallback、`@zig-setup`、`zig.*` 配置块、编译期驱动白名单、内置页首装面板。
- **分片上传**（STATUS §57/§58）：`/api/fs/multipart/*` 全实现，`multipart_enabled=true`；`mp_*` 四槽位（189pc 直传零落盘），其余驱动回退（落 `temp_dir` 稀疏文件）；`mp_begin` 回写生效片大小；会话表 30min TTL。
- **`zig.max_upload_mb`（默认 64 MiB）**：>4MiB 请求体落 `temp_dir`（生产=tmpfs 占 RAM）⇒ 150–220MB 会 OOM；超限回**真实 413 JSON**；0 = 恢复 8GiB。WebDAV PUT 同用。分片 pwrite 撞 `NoSpaceLeft/DiskQuota` ⇒ 会话判死 + 413。
- **`/api/*` 未注册路径 = 真实 501 JSON**（`not implemented: <METHOD> <PATH>`，刻意偏差 Go 的 200+HTML）；`/api/` 之外仍是 200+shell / 405。**不能用 `res.jsonError`**。前端 4.2.6 无条件调的未实现端点只有 archive_extensions / offline_download_tools，已在 `handle()` 放行。调试可用 `config.zig.json` 的 `zig.token` 当 `Authorization`。
- **登录限速（`api.zig` `LoginThrottle`）**：按对端 IP 分桶（64 桶 LRU，`util/peeraddr.zig`，Windows 恒 null ⇒ 全局桶）；**HTTP 登录 / WebDAV `/dav` / SSH 三处共用同一份计数**。WebDAV 曾漏记账（`/dav` 是绕过 5 次锁定的后门，11-01 补）。**「没带凭据」不计数**（`checkBasic` 返回 `ok/missing/invalid`），否则扫描器随手几个无 Authorization 请求就能锁管理员。锁定期内每次尝试都续期（对齐 Go `Expire`）。**上游事实**：Go HTTP 登录用 `ClientIP()`（纯 IP）、FTP 用 `RemoteAddr()`（带端口，才是「限速失效」的来源）、上游 SFTP 无 `LoginCache` —— 别再说「上游用 IP:端口」。
- **11-01 真机验过**：光猫上 127.0.0.1 与 192.168.1.1 是两个独立桶（一个 429 另一个 207），同 IP 跨协议共用（WebDAV 锁住后 SSH 正确口令也 Access denied），日志里是真实 IP ⇒ POSIX `getpeername` 正常。**验证手法**：设备自身有 lo/br0 多个地址 ⇒ 换「目的地址」就换「来源 IP」；`--sftp-ssh` 只绑 127.0.0.1 ⇒ `ssh -L` 隧道 + PuTTY `pscp` 当第二客户端。

## SFTP 服务端（11-01 收尾完成）

- 分层：`sftp/protocol.zig`（v3 编解码）+ `session.zig`（句柄表/路径归一）+ `handler.zig`（分发，两个窄接口 `Resolver`/`Fetcher` 便于纯单测）+ `ssh.zig`（传输层，curve25519 + ssh-ed25519 + aes128-ctr + hmac-sha2-256）+ `channel.zig`（RFC 4254/4252 + `subsystem sftp`）+ `sftp_wire.zig`（生产接线）。
- **11-01 五项**：①失败计数按 IP 分桶（`util/peeraddr.zig`，POSIX `getpeername` **只取 IP 不带端口**，Windows 明确 null 回退全局桶；64 桶 LRU，HTTP/SSH 共用）；②断点续传（OPEN 无 trunc 且文件已存在 ⇒ `preloadExisting` 把原内容拉进 temp，上游短读直接报错）；③`size_known`（驱动没报 size 时按 Range 实际返回判 EOF）；④服务端主动 rekey（`sftp.rekey_mb` 默认 1024；KEX 期间对端包进 Stash，NEWKEYS 后补投）；⑤host key 0600。
- **收尾握手缺陷**（STATUS §60.38）：收到 `CHANNEL_EOF` 发完 EOF+CLOSE 就关 socket ⇒ 对端回的 CLOSE 没读走，Winsock 用 **RST** 收尾 ⇒ psftp quit 随机报 abort（文件其实已传完）。按 RFC 4254 §5.3 双向握手（等对端 CLOSE 再关，`closeChannel` 幂等）后 15/15。
- **复核后的三条硬规则**（STATUS §60.39）：①**已知大小**的上游短读必须回 `FAILURE`，只有 `size_known == false` 才把短读当 EOF（否则下载静默截断）；②续传时 `details().size <= 0` 一律拒绝（`size == 0` 无法区分真空/未知，当成空文件会留空洞）；③`size_known` 的判据是 `size > 0`，两处必须一致。
- 回归：`tools/sftp_ssh_e2e.py`（paramiko，含双向 rekey / 续传 / 3 MiB 完整性）、`tools/sftp_interop.py`（psftp / WinSCP / rclone 逐字节比对，`--kib` 可调；全 SKIP 时退出码 2）。
- `--sftp-plain` **已删除**（11-01 用户决定）：无认证端点不该留在二进制里。连带删 `servePlain`/`connThread`/`serveStream`（120 行）+ `tools/sftp_probe.py`。handler 分发本来有纯单测，SSH 侧靠 `sftp_ssh_e2e.py` + `sftp_interop.py`。
- **不做前端开关**：仓库无前端产物 + `setting/save` 写 `zig.*` 而 SFTP 读 `sftp.*` + 监听器是 detached 线程里的 accept 死循环（无 stop 句柄）。

## 文档与留档

- **权威待办 `zig-src/TODO.md`**（只放未做项）；编年 `zig-src/docs/STATUS.md`（§60.37 五项、§60.38 握手缺陷）；驱动审计 `docs/AUDIT_2026-10-18-drivers.md`。
- 分片上传真机验收 `tools/multipart_upload.py`（Git Bash 要给 `--path` 加 `MSYS_NO_PATHCONV=1`）。
- **pan115 fixture 铁律**：`src/drivers/115list_fixture.json` **必须入库**；真机原文 `115list_sample.json` **永不入库**。
- **外部二进制留档** `D:/workspace/server/armbian/bin/openlist/` = 二进制 + 设备现役 `config.zig.json`；换二进制：传 `openlist.new` → `chmod 755` → `stop` → `mv -f` → start。
- 磁盘紧张是老问题；npm pack 的 23MB 前端包用完立刻删。
