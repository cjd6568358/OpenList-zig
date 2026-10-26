# openlist-zig —— 项目长期记忆（2026-10-26 二次精简）

## 项目与目录

- 仓库 `D:\workspace\OpenList-zig` = Go 上游（`drivers/ server/ internal/ pkg/ main.go`）+ Zig 移植（`zig-src/src`）；
  **交付/构建以 Zig 为主**，Go 树只作上游事实来源。**上游唯一事实来源 = 本仓库 Go 树**，别去 GitHub 拉。
- Zig 版前端：`cdn`（302 jsdelivr）或 `dist_dir`；都不配 ⇒ 内置占位页。2026-10-21 起用**内嵌外壳**（`shell from the binary`），启动不再拉 index.html。
- 记忆目录只有一个：`D:/workspace/OpenList-zig/.workbuddy-ai/memory/`。

## 驱动状态（15 存储 / 14 挂载；全部有单测）

| 驱动 | Go Name | 状态 |
|---|---|---|
| local/webdav/strm | `Local`/`WebDav`/`Strm` | ✅ 真机 |
| itvsh（私有） | `Itvsh` | ✅ 真机 |
| 189 个人/家庭 | `189Cloud`/`189CloudPC` | ✅ 真机（签名逐字节一致） |
| 123 / quark+UC / 115 | `123Pan`/`Quark`,`UC`/`115 Cloud` | ✅ 实现完成 |
| aliyun | `AliyundriveOpen` | ✅ 真机（401 会自动 refresh） |
| wopan | `WoPan` | ✅ 实现，未真机 |
| 迅雷（+专家） | `Thunder`/`ThunderExpert` | ✅ 真机；**`/thunder`=ThunderExpert 长期 errored**（见下） |
| 迅雷网页版 | `ThunderWeb` | ✅ 生产 `/thunderweb`（当前唯一可用的迅雷） |
| 123 Open/QuarkOpen/115 Open | 同名 | ⚠️ 编译期可选（`opted()`），缺真实凭据 |

- **铁律**：`factory.key` 逐字节等于 Go `driver.Config.Name`，不设别名。
- **label 不是展示名**：前端中文名来自 bundle `assets/entry-*.js` 的 109 条映射，Zig `label` 只进启动日志；**用户要求 label 保持中文**。
- `pan123`/`quarkuc`/`itvsh` 上游 Copy 即 NotSupport ⇒ `.copy=null`，有测试钉住别补。
- **编译期可选驱动用 `opted()` 而非 `has()`**（`has()` 在默认全量构建下恒 true）。`-Ddrivers=` 按 `,` 和空格分词 ⇒ 只能传 Zig 文件名（`115open`）。
- **addition_schema 键必须等于 Go 的 json tag**（不是 Go 字段名）；每驱动有"schema 键 == parse 键"单测。
- **select 的 `options` 必须是逗号字符串**（Go `driver.Item.Options` 是 string）；JSON 数组会被静默降级成空串。
- 迅雷：S3 上传必须 virtual-hosted；上游登录限频（`shield_reject: Operation too frequent`）⇒ 别在循环里重建存储。
- **迅雷 `/thunder`（ThunderExpert，login_type=user）长期 `userinfo_expired`**：设备出口 IP 被风控 + 安卓端点必发滑块；`login_type=refresh_token` 能绕登录但业务接口 `captcha_invalid`。**结论：这条路走不通，日常用 `/thunderweb`**。要停用就在存储编辑里勾禁用。
- **WoPan refresh_token 一次性轮换**：只能用驱动去刷（成功即 `save()` 落盘）；外部探针刷一次就消费掉必丢。令牌在 `zig-src/tools/creds.local.json`（gitignored，0600）。
- **迅雷网页版**（权威 `zig-src/docs/THUNDER_WEB_RE_2026-10-20.md`）：`captcha_sign="1."+15 轮 md5(prev+salt)`，盐表随发版变化 ⇒ `tools/thunder_web_sign_harness.js` 重取；captcha token 300s；网页 refresh_token **不轮换**，`4126 has been refresh at` 真因是**多实例并发 refresh**。登录 4 步纯 HTTP（SSO cid `XW5SkOhLDjnOZP7J` + PKCE S256，手机号 `+86 <11位>`）。回归 `tools/thunder_web_probe.py` / `thunder_web_e2e.py`。
- `115`/`WoPan` 依赖外部 SDK（不在仓库内）⇒ 只能真实 API 回归。
- **BaiduNetdisk / Onedrive 暂不移植**（用户 2026-10-16 明确）。重启信号 = 用户说"百度网盘也要"。

## 构建约定（本机有工具链）

- 本机 Zig 0.17.0：`C:\Program Files\zig-x86_64-windows-0.17.0\zig.exe`；`zig build test` = **459 pass + 3 skip**。
  必须：① 先 `tools/ziglib_patch.py "<toolchain>/lib" C:/zigcache/olz-ziglib`；② 用 **`ZIG_LIB_DIR`** 环境变量（`--zig-lib-dir` 0.17 不认）；③ `ZIG_GLOBAL_CACHE_DIR`/`ZIG_LOCAL_CACHE_DIR` 都指 `C:/zigcache/olz`。
- **🔴 裸调 `zig build`（漏 export ZIG_LIB_DIR）= 静默丢 TLS 补丁**：编译不报错，部署后 Quark/UC 挂载消失（14→12）。
  判据：带补丁 **1,352,536 B / `52d38eea`**（2026-10-26 版）、1,352,552 B / `47648f5c`（10-24 版）；裸构建 1,352,624 B / `af22fd5f`。
  **部署后必须 grep `mount(s) published`，应为 14**。
- 打包机 `10.0.0.4` 可选（`tools/build_remote.py`，`/tmp/olz-build`）。`-Ddrivers=` 白名单必须 comptime 分支。`build_remote.py` 必须走 `zig build test`。
- ⚠ `zig build` 吞 "All tests passed" 且末尾打误导性 `failed command`（退出码 0）；判成功看 `--summary all` 的 `test success`。
- 单测一律 `std.testing.allocator`。**D 盘满会假报 NoSpaceLeft/泄漏**。
- **Zig 0.17 坑**：裸 `assert` 已移除 → `std.debug.assert`；`**` 数组重复非法 → 定长数组 + `@memset`；驱动新方法必须放进 struct；`_ = self;` 在 self 已用时是编译错误。
- **写盘边界**：构建/调试只写 `/tmp`；工具链 cache 只读（裸调 `zig cc` 曾 +60MB）。编 Go 先 `. /root/build-env.sh`（见 `D:/workspace/server/0806/BUILD-ENV.md` §0.5.3）。
- 下载 GitHub 产物走 `https://ghfast.top/<原始URL>`；api.github.com JSON 可直连（60 次/小时）。
- `remote.py` 坑：argv 空格拼接 ⇒ 远端命令作**单个带引号参数**；内联命令用**绝对路径**（cwd=/root）；`--put` 远端路径**去掉前导斜杠**（MSYS 改写）。别设 `MSYS_NO_PATHCONV=1`。
- **沙箱限制**：经 SSH 执行**远程文件删除/移动**被 sandbox-center 拦截（rm/mv/unlink 均如此，`dangerouslyDisableSandbox` 同样报错）——远程删除需用户手动；`--put` 上行不受影响。

## ★ 用户明确要求（不得以"简化/体积/困难"跳过）

- **Go 配置必须无缝迁移**（`tools/import_go_config.py` 为无损版）。
- **允许 SQLite（C 桥接）；无 1MB 体积上限；交叉编译不是 Zig 弱项**。
- **核心算法逐函数对齐 Go，不得自创**：密码哈希（`TwoHashPwd` 双层加盐 + `StaticHashSalt="https://github.com/alist-org/alist"`）、签名、JWT claim、时间格式。
- 不支持的驱动/端点要给**明确可查询**的理由，不能静默丢弃（进 `zig-src/docs/STATUS.md`）。

## 真机部署铁律（光猫 192.168.1.1:10022，测试只在 `/tmp/olz`）

- **绝不碰** `/opt/sq/openlist`、Go 的 `config.json`/`data.db`。**绝不用命令行子串筛进程**（10-15 误杀过生产）：只按 pidfile / `--port <n>` 匹配。
- **生产实例**：`/opt/armbian/bin/openlist/openlist server --config /opt/armbian/bin/openlist/config.zig.json`，日志 `/tmp/openlist.log`，端口仅 **15244**；启停 `/opt/script/openlist_start.sh [stop]`（幂等 + 重试），崩溃后重跑它。
  - **日志口径（2026-10-26 起）**：`client.zig` 那 4 行请求打点（10-18 加的诊断）已降级 `log.debug`
    ⇒ 稳态 **≈0–1 行/分钟**（只剩 189 的 `HttpConnectionClosing` WARN）。要复现旧行为用
    `--log-level debug` / `OPENLIST_LOG_LEVEL=debug`。默认 info，`config` 里无级别字段（同 Go）。
  - `/tmp` 是 tmpfs **220.9 MB**（2026-10-26 已用 125 MB）⇒ 日志不轮转仍是隐患，别再让 INFO 刷请求级日志。
- **🔴 绝不对光猫执行重启/停机类命令**：无 `reboot` 二进制（rc=127 空操作）；`ubus call system reboot` 会杀掉 easytier/xray/rtp2httpd 等但重启不走完（极具迷惑性）。**重启只有用户本人能发起**。
- **★ 重启生产前必须数进程**：`for p in /proc/[0-9]*; do e=$(readlink $p/exe 2>/dev/null); case "$e" in *openlist*) echo "$(basename $p) $e";; esac; done` —— 必须 **1 个**且不带 `(deleted)`（10-20 曾同时活 3 个抢 15244，把 config 写成非法 UTF-8 拒启）。
- SSH 默认 cwd `/root` ⇒ 写盘用绝对路径并同条命令 `mkdir -p`；起后台服务必须 `< /dev/null`，起服务+探测同一条 exec。设备 busybox：`chmod` 失效（用 sftp.chmod）、无 `curl`/`pkill`/`setsid`、`wget` 无 `--header`。
- 工具：`zig-src/tools/deploy_device.py start|stop|status|restart [bin] [--port]`（默认 15399）。⚠ **换二进制前必须先 `stop`**（覆盖运行中二进制会 ETXTBSY）。
- 无凭据回归：`tools/driver_matrix.py <base> --user admin --password ...`（base 是位置参数；`--expect`/`--only`）。
- **设备文件留档**：`/opt/armbian/...` → `D:/workspace/server/armbian/...`；`/opt/script`、`/opt/apps`、`/root` → `D:/workspace/server/f4610u/...`；只留最新。
- 光猫 easytier 配置实际是 `/opt/armbian/bin/easytier/easytier.yaml`。
- 改设备上的**运行中脚本**：先 put 到**同盘** `/opt/script/<name>.new` → `sh -n` → `mv -f`。**绝不能从 /tmp mv**（跨文件系统是 copy+truncate，会破坏运行中脚本）。

## ★ 前端一律走 CDN，绝不在设备上养前端副本（用户强烈要求）

- 设备放 dist 副本 = 把要消除的东西装回去，且掩盖"CDN 为什么取不到"。**先在沙箱诊断再动设备**。
- **quark/UC 的 TLS 失败 = 缺 ECDSA 套件补丁**（不是 CA 库问题）：Zig 0.17 std 只 offer ECDHE-RSA，quark 的该路径服务端有缺陷 ⇒ 必须 offer c02b/c02c/cca9。补丁 `tools/ziglib_patch.py` 改 `crypto/tls/Client.zig` 四处。**症状静默**：`TlsInitializationFailed`，挂载 14→12，服务照常 200。
- **Zig 0.17 std resolv.conf bug**：`HostName.zig` 遇文末无换行报 `EndOfStream` ⇒ 全部外网请求 `ResolvConfParseFailed`。确保 `/etc/resolv.conf` 末尾有 `\n`。
- CDN fallback：`zig.cdn_fallbacks`（逐个重试 2 次）。`RawIndex` 要带出**实际生效**的 cdn 覆盖 `site.cdn`。`registry.npmmirror.com` 专拦 .html（451）⇒ 不能做外壳源。

## 血的教训

1. **手拼 JSON**：`Buf.append` 不转义，只有 `Buf.print` 转义 `{{}}` ⇒ 严格 JSON 解析测试兜底；前端 JSON.parse 失败会静默降级成字符串。
2. **字符串里有 ≠ 浏览器里能跑**：内联 `<script>` 里 HTML 实体不解码 ⇒ `&amp;&amp;` 语法错误、整段不执行。改前端至少 `node --check`（`tools/check_builtin_js.py` 已接 build 第 0 步）。
3. **前端自动化**：`playwright-core` + 系统 Chrome；按文字/role 定位，`.first()` 会点到「清除」。
4. **契约字段 bug 只看状态码发现不了**：`/api/me` 曾缺 `sso_id`/`allow_ldap`/`otp`、多输出 `otp_secret` ⇒ 登录转圈。必须拿 Go struct tag 逐字段对。
5. **`permission` 曾硬编码 0** ⇒ 前端按位禁用按钮；应为 `0x71FF`（真机 29183）。
6. **catch 里的 `try` 会跳过配对 unlock** ⇒ 死锁。catch 里一律 `_ = f() catch |e| {...}`。
7. **临时目录生命周期必须长过会写它的配置对象**（defer cleanup 太早 ⇒ 实测 500）。
8. **189 个人云 list 有秒级最终一致性延迟**（家庭云无）⇒ 轮询容忍，不是 bug。
9. `driver.ProgressFn` 是 0–100 百分比；`addition` 是字符串不是对象。
10. 路由白名单：`handle()` 只放行已知前缀进 `handleAuthed`，加端点必须同时改白名单。
11. **架构事实**：每请求一个 ArenaAllocator（`http.zig:622`）；`Client` 每实例一把全局锁（`client.zig:159`），并发靠每 worker 一个 Client；`model.Obj` 无 ID ⇒ 189 靠路径逐段翻页找 ID。
12. **busybox ash 的 `trap 'cmd' INT TERM` 跑完会从中断处继续循环，不退出** ⇒ trap 里必须显式 `exit`（`trap 'rm -f "$PIDF"; exit 0' EXIT INT TERM`）；TERM 要等当前 `sleep` 跑完。

## 功能边界（STATUS.md §22）

- **刻意不做**：分享 / SSH 公钥 / webauthn / 2FA / LDAP / 多用户·SQLite·SSO / 搜索索引 / 离线下载 / 分片上传 / S3·FTP·SFTP·MCP 服务。中心思想：单管理员管整个存储。
- **Zig 特有**：itvsh 驱动、CDN fallback、`@zig-setup`、`zig.*` 配置块、编译期驱动白名单、内置页首装面板。
- 用户 Go 备份实况：`/baidu`、`/onedrive` 在用但暂不移植。

## 待办与文档入口

- **权威待办 = `zig-src/TODO.md`**；审计 = `zig-src/docs/STATUS.md`（§22/§23）、驱动审计 = `docs/AUDIT_2026-10-18-drivers.md`。
- 已知欠项：全驱动真实 API+UI 回归、`model.Storage` 无 `modified`、配置项 `delayed_start`/`cors`/`tasks`。
- 验证基线：459 单测 + 3 skip；生产 aarch64 **1,352,536 B / `52d38eea`**（2026-10-26）；真机 e2e 32/32。
- **根目录整洁铁律**：仓库根只允许上游文件 + `zig-src/ .github/ .workbuddy/ .workbuddy-ai/`；Zig 脚本一律 `zig-src/tools/`，新脚本用 `Path(__file__).resolve().parents[2]` 定位仓库根。
- **pan115 fixture 铁律**：`src/drivers/115list_fixture.json`（`tools/gen_115_fixture.py` 生成）**必须入库**；真机原文 `115list_sample.json` 含真实文件名**永不入库**。
- **外部二进制留档**：`D:/workspace/server/armbian/bin/openlist/` = 现役 openlist（1,352,536 B / `52d38eea`）+ 设备现役 `config.zig.json`；`_backup/` 收旧版（10-24 版 1,352,552 B 与 10-22/10-21 版）。设备侧 `.bak` 按规矩只留切换当次一份，现为 `openlist.bak-20261026`（=10-24 版，带补丁，可直接回滚）。
- 磁盘紧张是老问题（D 盘曾 100%）；npm pack 的 23MB 前端包用完立刻删。
- 一次性调查脚本已清理（commit 97a4b7d2）；不可恢复素材暂存 `D:/workspace/_olz-staging/2026-10-24-cleanup/`。
