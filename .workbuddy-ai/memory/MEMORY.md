# openlist-zig 长期记忆（2026-10-31 三次精简）

## 项目

- 仓库 `D:\workspace\OpenList-zig` = Go 上游（`drivers/ server/ internal/ pkg/ main.go`）+ Zig 移植（`zig-src/src`）；**交付以 Zig 为主**，Go 树是**唯一上游事实来源**（别去 GitHub 拉）。
- 前端：`cdn` 或 `dist_dir`；都不配 ⇒ 占位页。10-21 起**内嵌外壳**，启动不拉 index.html。
- 记忆目录：`D:/workspace/OpenList-zig/.workbuddy-ai/memory/`。

## 驱动（15 存储 / 14 挂载，均有单测）

| 驱动 | Go Name | 状态 |
|---|---|---|
| local/webdav/strm、itvsh | `Local`/`WebDav`/`Strm`/`Itvsh` | ✅ 真机 |
| 189 个人/家庭 | `189Cloud`/`189CloudPC` | ✅ 真机（签名逐字节一致） |
| 123 / quark+UC / 115 / aliyun | `123Pan`/`Quark`,`UC`/`115 Cloud`/`AliyundriveOpen` | ✅ 完成（aliyun 401 自动 refresh） |
| wopan | `WoPan` | ✅ 实现，未真机 |
| 迅雷 / 专家 / 网页版 | `Thunder`/`ThunderExpert`/`ThunderWeb` | ✅ 真机；`/thunder` 长期 errored，**日常用 `/thunderweb`** |
| 123 Open/QuarkOpen/115 Open | 同名 | ⚠️ 编译期可选（`opted()`），缺凭据 |

- **`factory.key` 逐字节等于 Go `driver.Config.Name`**，不设别名。
- **label 不是展示名**：中文名来自 bundle `assets/entry-*.js` 的 109 条映射，Zig `label` 只进启动日志；**用户要求 label 保持中文**。
- `pan123`/`quarkuc`/`itvsh` 上游 Copy 即 NotSupport ⇒ `.copy=null`，有测试钉住别补。
- **可选驱动用 `opted()` 而非 `has()`**（`has()` 全量构建下恒 true）。`-Ddrivers=` 按 `,`/空格分词 ⇒ 只传 Zig 文件名（`115open`）。
- **addition_schema 键 = Go 的 json tag**（非 Go 字段名），每驱动有「schema 键 == parse 键」单测；**select 的 `options` 必须是逗号字符串**（JSON 数组会静默降级成空串）。
- 迅雷：S3 必须 virtual-hosted；登录限频（`shield_reject: Operation too frequent`）⇒ 别在循环里重建存储。`/thunder` 走不通的真因：设备出口 IP 被风控 + 安卓端点必发滑块，`refresh_token` 能绕登录但业务接口 `captcha_invalid`。
- **迅雷网页版**（权威 `zig-src/docs/THUNDER_WEB_RE_2026-10-20.md`）：`captcha_sign="1."+15 轮 md5(prev+salt)`，盐表随发版变 ⇒ `tools/thunder_web_sign_harness.js` 重取；captcha 300s；refresh_token **不轮换**，`4126 has been refresh at` 真因是**多实例并发 refresh**；登录 4 步纯 HTTP（SSO cid `XW5SkOhLDjnOZP7J` + PKCE S256，手机号 `+86 <11位>`）。回归 `tools/thunder_web_probe.py` / `thunder_web_e2e.py`。
- **WoPan refresh_token 一次性轮换**：只能由驱动刷（成功即 `save()` 落盘），外部探针刷一次就消费掉必丢。令牌 `zig-src/tools/creds.local.json`（gitignored，0600）。
- `115`/`WoPan` 依赖仓库外 SDK ⇒ 只能真实 API 回归。
- **BaiduNetdisk / Onedrive 暂不移植**（用户 10-16 明确）；重启信号 = 用户说「百度网盘也要」。

## 构建

- Zig 0.17.0：`C:\Program Files\zig-x86_64-windows-0.17.0\zig.exe`；`zig build test` = **467 pass + 3 skip**。必须 ① `tools/ziglib_patch.py "<toolchain>/lib" C:/zigcache/olz-ziglib`；② 用 **`ZIG_LIB_DIR`**（`--zig-lib-dir` 0.17 不认）；③ `ZIG_GLOBAL_CACHE_DIR`/`ZIG_LOCAL_CACHE_DIR` → `C:/zigcache/olz`。
- **🔴 裸调 `zig build`（漏 ZIG_LIB_DIR）= 静默丢 TLS 补丁**：不报错，部署后 Quark/UC 消失（14→12）。尺寸判据**代码一变即失效**（1,376,016 B / `935ab9fc` = 10-31 生产现役）；**最终判据：部署后 grep `mount(s) published` = 14** + sha256。
- 打包机 `10.0.0.4` 可选（`tools/build_remote.py`，`/tmp/olz-build`），必须走 `zig build test`；`-Ddrivers=` 白名单必须 comptime 分支。
- ⚠ `zig build` 吞 "All tests passed" 且末尾打误导性 `failed command`（退出码 0）；判成功看 `--summary all` 的 `test success`。
- 单测一律 `std.testing.allocator`；**D 盘满会假报 NoSpaceLeft/泄漏**。
- **Zig 0.17 坑**：裸 `assert` 移除 → `std.debug.assert`；`**` 数组重复非法 → 定长数组 + `@memset`；驱动新方法必须放进 struct；`_ = self;` 在 self 已用时是编译错误。
- **CLI**：`openlist version`（六行，对齐 Go `cmd/version.go`）/ `-v`；裸 positional **必须 `.json` 结尾**，否则 `unknown command` + exit 2 —— 旧行为把任何裸词当 config 路径，`openlist version` 曾静默在 5244 起服务并在 cwd 建 `data/`（误判成「命令挂住」）。CLI 输出走 stderr。
- **写盘边界**：构建/调试只写 `/tmp`；工具链 cache 只读（裸调 `zig cc` 曾 +60MB）。编 Go 先 `. /root/build-env.sh`（`D:/workspace/server/0806/BUILD-ENV.md` §0.5.3）。
- GitHub 产物走 `https://ghfast.top/<原始URL>`，api.github.com JSON 直连（60 次/小时）。仓库内一键取件：`.github/workflows/proxy_download.yml`（dispatch 收 URL + 代理前缀列表，产物进 artifacts）。
- `remote.py` 坑：argv 空格拼接 ⇒ 远端命令作**单个带引号参数**；内联命令用**绝对路径**（cwd=/root）；`--put` 远端路径**去掉前导斜杠**；别设 `MSYS_NO_PATHCONV=1`。
- **沙箱限制**：经 SSH 的**远程删除/移动**被 sandbox-center 拦截（rm/mv/unlink，`dangerouslyDisableSandbox` 同样报错）⇒ 远程删除需用户手动；`--put` 上行不受影响。

## ★ 用户硬要求（不得以简化/体积/困难跳过）

- **Go 配置必须无缝迁移**（`tools/import_go_config.py` 无损版）。
- **允许 SQLite（C 桥接）；无 1MB 体积上限；交叉编译不是 Zig 弱项**。
- **核心算法逐函数对齐 Go，不得自创**：`TwoHashPwd` 双层加盐 + `StaticHashSalt="https://github.com/alist-org/alist"`、签名、JWT claim、时间格式。
- 不支持的驱动/端点给**明确可查询**的理由（进 `zig-src/docs/STATUS.md`），不静默丢弃。

## 真机铁律（光猫 192.168.1.1:10022，测试只在 `/tmp/olz`）

- **绝不碰** `/opt/sq/openlist`、Go 的 `config.json`/`data.db`；**绝不用子串筛进程**（10-15 误杀过生产），只按 pidfile / `--port <n>`。
- **生产**：`/opt/armbian/bin/openlist/openlist server --config /opt/armbian/bin/openlist/config.zig.json`，日志 `/tmp/openlist.log`，端口仅 **15244**；启停 `/opt/script/openlist_start.sh [stop]`（幂等+重试）。**无看门狗**（10-27 已移除），崩溃后手工跑它。
- **日志口径**：请求打点已降 `log.debug` ⇒ 稳态 ≈0–1 行/分（只剩 189 `HttpConnectionClosing` WARN）；细节用 `--log-level debug`/`OPENLIST_LOG_LEVEL=debug`。`/tmp` = tmpfs **220.9 MB**（已用 ~125 MB）⇒ 日志不轮转仍是隐患。
- **🔴 绝不对光猫下重启/停机命令**：无 `reboot`（rc=127 空操作）；`ubus call system reboot` 会杀 easytier/xray/rtp2httpd 却不完成（极具迷惑）。**重启只有用户能发起**。
- **重启生产前必须数进程**：`for p in /proc/[0-9]*; do e=$(readlink $p/exe 2>/dev/null); case "$e" in *openlist*) echo "$(basename $p) $e";; esac; done` —— 必须 **1 个**且不带 `(deleted)`（10-20 曾 3 个抢 15244，把 config 写成非法 UTF-8 拒启）。
- SSH cwd `/root` ⇒ 绝对路径 + 同条 `mkdir -p`；起后台服务必须 `< /dev/null`，起服务+探测同一条 exec。busybox 无 `curl`/`pkill`/`setsid`、`wget` 无 `--header`；`chmod 755` 对 scp 上传的文件**实测有效**。
- **本机 `tools/deploy_device.py` 跑不了**（依赖 paramiko，pip 无源装不上）；改用 `scp` + `ssh` 手工三步（上传 → `chmod 755` → `cd /tmp/olz && (nohup ./openlist server --config /tmp/olz/cfg.json --port 15399 >run.log 2>&1 </dev/null &)`）。密钥已授权，`ssh -p 10022 root@192.168.1.1` 免密。无凭据回归：`tools/driver_matrix.py <base> --user admin --password ...`（base 位置参数，`--expect`/`--only`）。
- **留档**：`/opt/armbian/...` → `D:/workspace/server/armbian/...`；`/opt/script`、`/opt/apps`、`/root` → `D:/workspace/server/f4610u/...`；只留最新。easytier 配置在 `/opt/armbian/bin/easytier/easytier.yaml`。
- 改设备上**运行中脚本**：put 到**同盘** `/opt/script/<name>.new` → `sh -n` → `mv -f`；**绝不能从 /tmp mv**（跨 fs 是 copy+truncate）。

## ★ 前端走 CDN，绝不在设备养前端副本（用户强烈要求）

- 设备放 dist = 把要消除的东西装回去，还掩盖「CDN 为什么取不到」。**先在沙箱诊断再动设备**。
- **quark/UC TLS 失败 = 缺 ECDSA 套件补丁**（非 CA 问题）：Zig 0.17 std 只 offer ECDHE-RSA ⇒ 必须 offer c02b/c02c/cca9，补丁 `tools/ziglib_patch.py` 改 `crypto/tls/Client.zig` 四处。**症状静默**：`TlsInitializationFailed`，挂载 14→12，服务照常 200。
- **Zig 0.17 std resolv.conf bug**：`HostName.zig` 遇文末无换行报 `EndOfStream` ⇒ 全部外网请求 `ResolvConfParseFailed`。确保 `/etc/resolv.conf` 末尾有 `\n`。
- `zig.cdn_fallbacks` 逐个重试 2 次；`RawIndex` 要带出**实际生效**的 cdn 覆盖 `site.cdn`；`registry.npmmirror.com` 专拦 .html（451）⇒ 不能做外壳源。

## 血的教训

1. 手拼 JSON：`Buf.append` 不转义，只有 `Buf.print` 转义 `{{}}` ⇒ 严格 JSON 测试兜底；前端 JSON.parse 失败静默降级成字符串。
2. 字符串里有 ≠ 浏览器能跑：内联 `<script>` 不解 HTML 实体 ⇒ `&amp;&amp;` 语法错、整段不执行。改前端至少 `node --check`（`tools/check_builtin_js.py` 已接 build 第 0 步）。
3. 前端自动化用 `playwright-core` + 系统 Chrome；按文字/role 定位，`.first()` 会点到「清除」。
4. 契约字段 bug 光看状态码发现不了：`/api/me` 曾缺 `sso_id`/`allow_ldap`/`otp`、多输出 `otp_secret` ⇒ 登录转圈；必须逐字段对 Go struct tag。
5. `permission` 曾硬编码 0 ⇒ 前端按位禁按钮；应为 `0x71FF`（真机 29183）。
6. catch 里的 `try` 会跳过配对 unlock ⇒ 死锁；catch 里一律 `_ = f() catch |e| {...}`。
7. 临时目录生命周期必须长过会写它的配置对象（defer 太早 ⇒ 实测 500）。
8. 189 个人云 list 有秒级最终一致性延迟（家庭云无）⇒ 轮询容忍，不是 bug。
9. `driver.ProgressFn` 是 0–100 百分比；`addition` 是字符串不是对象。
10. 路由白名单：`handle()` 只放行已知前缀进 `handleAuthed`，加端点必须同步改白名单。
11. 架构：每请求一个 ArenaAllocator（`http.zig:622`）；`Client` 每实例一把全局锁（`client.zig:159`），并发靠每 worker 一个 Client；`model.Obj` 无 ID ⇒ 189 靠路径逐段翻页找 ID。
12. busybox ash 的 `trap 'cmd' INT TERM` 跑完会从中断处继续循环 ⇒ trap 里必须显式 `exit`；TERM 要等当前 `sleep` 跑完。

## 边界与 API 契约

- **刻意不做**：分享 / SSH 公钥 / webauthn / 2FA / LDAP / 多用户·SQLite·SSO / 搜索索引 / 离线下载 / S3·FTP·SFTP·MCP 服务。中心思想：单管理员管整个存储。
- **Zig 特有**：itvsh 驱动、CDN fallback、`@zig-setup`、`zig.*` 配置块、编译期驱动白名单、内置页首装面板。
- 用户 Go 备份实况：`/baidu`、`/onedrive` 在用但暂不移植。
- **分片上传**（10-30 晚落地，STATUS §57/§58）：`/api/fs/multipart/*` 全实现，`multipart_enabled=true`；`mp_*` 四槽位（189pc 直传=零落盘），其余驱动回退（分片落 `temp_dir` 稀疏文件）；`mp_begin` 回写生效片大小（189 partSize 阶梯，8MiB 会被抬到 10MiB）；会话表 30min TTL；真机 25MiB 乱序 3 片 + 11MiB MD5 一致。
- **回退路径单文件上限 = `zig.max_upload_mb`**（10-31 加，`App.mp_max_bytes`）：整份落 temp_dir ⇒ 与 `fs/put` 同一笔账，超限 init 回**真实 413 JSON**；直传路径不受限。分片 pwrite 撞 `NoSpaceLeft/DiskQuota` ⇒ 会话判死 + 413 可读消息（此前是静默掐连接）。
- **请求体安全阀 `zig.max_upload_mb`（默认 64 MiB）**：>4MiB 请求体落 `temp_dir`（生产 = tmpfs 占 RAM），150–220MB 会 OOM，>220MB ENOSPC 掐连接；超限回 **413 JSON**（中文 message）。0 = 恢复 8GiB；WebDAV PUT 同用此上限。
- **`/api/*` 未注册路径 = 真实 501 JSON**（`not implemented: <METHOD> <PATH>`，刻意偏差 Go 的 200+HTML）；`/api/` 之外仍是 200+shell / 405。**不能用 `res.jsonError`**（对齐 Go `c.JSON(200,…)` 恒回 200）。前端 4.2.6 无条件调用的未实现端点只有 archive_extensions / offline_download_tools，已在 `handle()` 放行（200 空列表）。调试可用 `config.zig.json` 的 `zig.token` 当 `Authorization`。

## 文档与留档

- **权威待办 `zig-src/TODO.md`**（只放未做项）；状态与编年 `zig-src/docs/STATUS.md`；驱动审计 `docs/AUDIT_2026-10-18-drivers.md`。基线：467 单测 + 3 skip。分片上传真机验收用 `tools/multipart_upload.py`（Git Bash 要给 `--path` 加 `MSYS_NO_PATHCONV=1`，否则路径被改写成 `D:/Program Files/Git/...` ⇒ 服务端回 `storage not found`）。
- **根目录整洁铁律**：根只允许上游文件 + `zig-src/ .github/ .workbuddy/ .workbuddy-ai/`；Zig 脚本一律 `zig-src/tools/`，新脚本用 `Path(__file__).resolve().parents[2]` 定位根。
- **pan115 fixture 铁律**：`src/drivers/115list_fixture.json`（`tools/gen_115_fixture.py` 生成）**必须入库**；真机原文 `115list_sample.json` **永不入库**。
- **外部二进制留档**：`D:/workspace/server/armbian/bin/openlist/` = 二进制（= 设备现役 `935ab9fc`，10-31 版）+ 设备现役 `config.zig.json`；`_backup/` 已清空，设备侧不留 .bak。换二进制走设备脚本规定的流程：传 `openlist.new` → `chmod 755` → `openlist_start.sh stop` → `mv -f` → `openlist_start.sh`。
- 磁盘紧张是老问题（D 盘曾 100%）；npm pack 的 23MB 前端包用完立刻删。一次性脚本已清理（commit 97a4b7d2）；素材暂存 `D:/workspace/_olz-staging/2026-10-24-cleanup/`。
