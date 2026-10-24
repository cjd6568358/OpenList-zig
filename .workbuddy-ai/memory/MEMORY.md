# openlist-zig —— 项目长期记忆（2026-10-21 精简重整）

## 项目与目录

- 仓库 `D:\workspace\OpenList-zig` = Go 上游（`drivers/ server/ internal/ pkg/ main.go`）+ Zig 移植（`zig-src/src`）并存；
  **交付/构建以 Zig 为主**，Go 树只作上游事实来源与对照。**上游唯一事实来源 = 本仓库 Go 树**，不要去 GitHub 拉。
- Zig 版不内嵌前端：`cdn`（302 jsdelivr）或 `dist_dir` 二选一，都不配 ⇒ 内置占位页。
- 记忆目录只有一个：`D:/workspace/OpenList-zig/.workbuddy-ai/memory/`（旧 `.workbuddy/memory/` 已合并）。

## 驱动状态（15 注册项 / 12 实现，全部有单测；+3 编译期可选变体）

| 驱动 | Go Name | Zig | 状态 |
|---|---|---|---|
| local / webdav / strm | `Local`/`WebDav`/`Strm` | local/webdav/strm.zig | ✅ 真机 |
| itvsh（私有） | `Itvsh`（2026-10-19 由中文名改） | itvsh.zig | ✅ 真机 |
| 189 个人 / 家庭 | `189Cloud`/`189CloudPC` | cloud189.zig / cloud189pc.zig | ✅ 真机（签名逐字节一致） |
| 123 / quark+UC / 115 | `123Pan`/`Quark`,`UC`/`115 Cloud` | pan123 / quarkuc / pan115.zig | ✅ 实现完成 |
| aliyun | `AliyundriveOpen` | aliyundrive.zig | ✅ 真机 |
| wopan 沃云盘 | `WoPan` | wopan.zig | ✅ 实现，未真机（无凭据） |
| 迅雷（+专家） | `Thunder`/`ThunderExpert` | thunder.zig | ✅ 真机（e2e 62/63） |
| 迅雷网页版（本工程新增） | `ThunderWeb` | thunder.zig `Variant.web` | ✅ 生产 `/thunderweb` |
| 123 Open / QuarkOpen / 115 Open | 同名 | 123open / quark / 115open.zig | ⚠️ **编译期可选**（`opted()`，默认不进产物）；2026-10-22 真机注册表+表单+哑凭据闭环，**缺真实凭据** |

- **驱动名铁律**：`factory.key` 逐字节等于 Go `driver.Config.Name`，**不设别名**（2026-10-15 删别名机制）。
- **★ label 不是展示名、无 API 出口**：前端 bundle `assets/entry-*.js` 自带 109 条 key→中文名映射，
  前台中文名全来自它；Zig `label` 只进启动日志。**用户要求 label 保持中文**（曾误改成 key 已回退）。
- `pan123`/`quarkuc`/`itvsh` 上游 `Copy` 就是 NotSupport ⇒ vtable `.copy=null`，有测试钉住别补。
  （`123 Open`/`115 Open` 上游**有** Copy，Zig 已实现；`QuarkOpen` 是 NotSupport。）
- **★ 编译期可选驱动 = `opted()` 而不是 `has()`**：`has()` 在 `drivers_all`（默认全量构建）
  下为 true，`opted()` 只认 `-Ddrivers=` 显式点名 ⇒ 变体默认一个字节都不进产物、前端列表不变。
  `-Ddrivers=` 按 `,` **和空格**分词 ⇒ 只能传 Zig 文件名（`115open`），带空格的 key 会被拆碎。
- **★ addition_schema 的键必须等于 Go 的 json tag**（不是 Go 字段名）：`115 Open` 曾写
  `AccessToken` 而 parse 读 `access_token` ⇒ 从管理页添加恒 `NoToken`。每驱动有
  "schema 键 == parse 键"一致性单测（把 schema 每个键填 "probe" 再 parse）。
- **★ select 的 `options` 必须是逗号字符串**（Go `driver.Item.Options` 是 string，
  `internal/driver/item.go:11`）；写成 JSON 数组会被 `writeAdditionalItems` 静默降级成
  空串 ⇒ 前端下拉框没有选项。2026-10-22 修了 5 个驱动 16 处，有遍历 `builtin` 的防复发单测。
- 迅雷硬知识：① S3 上传必须 **virtual-hosted**（`https://<bucket>.<trimLeft(endpoint)>/<key>`），path-style 直接 403/DNS 失败；
  ② 上游登录限频（`shield_reject: Operation too frequent`）⇒ 回归别在循环里重建存储（每次重建=一次登录）。
- `115`/`WoPan` 依赖外部 SDK（Go 源码已 vendor 到 `zig-src/wopan-sdk-*.go` 供对照）⇒ 只能真实 API 回归。
- **★ WoPan refresh_token 是一次性轮换**：刷一次即换发新令牌，旧令牌立刻作废。
  **只能用驱动去刷**（刷新成功会立刻 `save()` 落盘，wopan.zig:273）；外部探针/变体矩阵刷一次
  就消费掉、新令牌只在响应里 ⇒ 必丢。令牌保存位置：`zig-src/tools/creds.local.json`（gitignored，0600）。
- **★ 迅雷网页版（权威文档 `zig-src/docs/THUNDER_WEB_RE_2026-10-20.md`）**：
  `captcha_sign = "1." + 15 轮 md5(prev+salt)`，纯 JS 无 WASM，`t(0)` = blueimp-md5（在数组形式 `app.<hash>.js` 里，下标即模块 id）；
  **盐表随前端发版变化** ⇒ `tools/thunder_web_sign_harness.js` 一键重取，`thunder_web_sign.py` 有 golden + probe。
  captcha token 寿命 **300 秒**。网页 refresh_token **不轮换**；`4126 has been refresh at` 真因是**多实例并发 refresh**。
  网页登录可程序化（4 步纯 HTTP，无短信/滑块/不需 captcha_sign）：signin 用 SSO cid `XW5SkOhLDjnOZP7J`，
  authorize/token 用 pan cid + PKCE S256，手机号要 `+86 <11位>`（带空格）。回归用 `tools/thunder_web_probe.py` / `thunder_web_e2e.py`
  （上传后有秒级最终一致性延迟，已内置轮询）。
- **BaiduNetdisk / Onedrive 暂不移植**（用户 2026-10-16 明确；`/baidu` 导入后 init 失败属预期）。重启信号 = 用户说"百度网盘也要"。

## 构建约定（2026-10-22 起：本机有工具链）

- **★ 本机 Zig 0.17.0 已装好**：`C:\Program Files\zig-x86_64-windows-0.17.0\zig.exe`。
  `zig build test`（448 pass + 3 skip，3 条 Linux-only）与交叉编译都能本机跑，
  **aarch64 产物与打包机逐字节相同**（1,320,952 B / `c90dd73e…`）。
  必须：① 先 `tools/ziglib_patch.py "<toolchain>/lib" C:/zigcache/olz-ziglib`；
  ② 用 **`ZIG_LIB_DIR`** 环境变量（`--zig-lib-dir` 不是 `zig build` 的参数，0.17 会报 unrecognized）；
  ③ `ZIG_GLOBAL_CACHE_DIR`/`ZIG_LOCAL_CACHE_DIR` 都指 `C:/zigcache/olz`（D 盘只剩 1.9G）。
  **🔴 2026-10-24 事故：裸调 `zig build`（忘了 export ZIG_LIB_DIR）= 静默丢补丁**——编译不报错，
  部署后 Quark/UC 两个挂载消失（14→12），只有看启动日志才发现。判据：带补丁产物
  `a468dbb2…`（1,352,552 B）vs 裸构建 `af22fd5f…`（1,352,624 B）。**部署后必须 grep
  `mount(s) published` 的条数**（当前应为 14）。
- 打包机 `10.0.0.4` 仍是可选路径（`zig-src/tools/build_remote.py`，`/tmp/olz-build`，zig 0.17.0）：
- **下载 GitHub 产物走 `https://ghfast.top/<原始URL>`**（release 资产域名直连卡死）；api.github.com JSON 可直连（共享 IP 60 次/小时）。
- `build.zig` 的 `-Ddrivers=` 白名单：收 Go 名或 Zig 源文件名，**必须 comptime 分支**（收进数组会强制生成全部驱动）。
- `build_remote.py` 必须走 `zig build test`（`driver.zig` 依赖 `build_options`）。
- ⚠ `zig build` 会吞 "All tests passed" 且末尾打误导性 `failed command`（退出码实为 0）；判成功看 `--summary all` 的 `test success`。
- 单测一律 `std.testing.allocator` 抓泄漏。**D 盘满会假报 NoSpaceLeft/泄漏**。
- **Zig 0.17 语言坑**：① 裸 `assert` 已移除 → `std.debug.assert`；② `**` 数组重复非法 → 定长数组 + `@memset(&buf, v)`；
  ③ 驱动 `init` 是 struct 外自由函数，`self.foo()` 只能调 struct 内声明的成员（新方法必须放进 struct）；
  ④ `_ = self;` 在 self 已被使用时是编译错误。
- **编译机产物**：`/tmp/olz-build`（build_remote.py）、`/tmp/olz-build/ziglib`（ziglib_patch.py 打过 TLS 补丁的 std 副本，每次重建）、
  `{zigcache,.zig-cache}`（`ZIG_GLOBAL_CACHE_DIR` 与 `ZIG_LOCAL_CACHE_DIR` **都指 zigcache**）、
  `/tmp/olz-thunder/*`（thunder_probe.py；server.log 用 ab 追加**不轮转**，跑前 `: > /tmp/olz-thunder/server.log`）、
  `/tmp/olz-x64-smoke/`（无脚本，手工 x86 冒烟）。
- **写盘边界**：构建/调试**只写 `/tmp`**；工具链 `/root/.cache/zig` **只读**，zig 必须显式给两个 cache 环境变量
  （裸调会把缓存写进工具链目录，实测一次 `zig cc` +60MB）。编 Go 先 `. /root/build-env.sh`。规则见 `D:/workspace/server/0806/BUILD-ENV.md` §0.5.3。
- `/tmp/olz-build` 是 tmpfs 不是仓库：**源码事实来源永远是本仓库 `zig-src/src`**，构建机副本可随时丢。

## ★ 用户明确要求（不得以"简化/体积/困难"跳过）

- **Go 配置必须无缝迁移**：Zig 配置 = Go 的**子集**，不该有差异（`tools/import_go_config.py` 为无损版）。
- **允许 SQLite（C 桥接）；无 1MB 体积上限；交叉编译不是 Zig 弱项**。
- **核心算法逐函数对齐 Go，不得自创**：密码哈希（Go `TwoHashPwd` 双层加盐 + `StaticHashSalt="https://github.com/alist-org/alist"`，
  Zig 若仍单层 sha256 即欠账）、签名、JWT claim、时间格式；验证沿用 189pc **逐字节**法。
- 不支持的驱动/端点要给**明确可查询**的理由，不能静默丢弃（结论进 `zig-src/docs/STATUS.md`）。

## 真机部署铁律（光猫 192.168.1.1:10022，测试只在 `/tmp/olz`）

- **绝不碰** `/opt/sq/openlist`、Go 的 `config.json`/`data.db`。**绝不用命令行子串筛进程**（2026-10-15 误杀过生产）：
  只按 pidfile / `--port <n>` 匹配，循环杀到 0 并 `netstat` 复核。
- **生产实例（Zig 持久部署）**：`/opt/armbian/bin/openlist/openlist server --config /opt/armbian/bin/openlist/config.zig.json`，
  日志 `/tmp/openlist.log`，端口仅 **15244**（Zig 无 SFTP/FTP）；启停 `/opt/script/openlist_start.sh [stop]`（幂等 + CDN 重试），崩溃后重跑它。
- **🔴 绝不对光猫执行重启/停机类命令**：容器里没有 `reboot` 二进制（rc=127 空操作）；`ubus call system reboot`
  会触发宿主机停机流程、杀掉 easytier/xray/rtp2httpd/onuproxy/smart-iot 等但重启不走完（uptime 不变、SSH 秒回，极具迷惑性）。
  **重启只有用户本人能发起**（① WEB 管理后台 ② telnet 宿主机 `reboot`）。自举验证只手工重跑 start.sh。
- **★ 重启生产前必须数进程（2026-10-20 事故）**：start.sh stop 只按 pidfile 杀一个，曾同时活 3 个实例（SO_REUSEPORT 抢 15244），
  互相覆盖 config 把 `config.zig.json` 写成非法 UTF-8 导致拒启。检查：
  `for p in /proc/[0-9]*; do e=$(readlink $p/exe 2>/dev/null); case "$e" in *openlist*) echo "$(basename $p) $e";; esac; done`
  —— 必须 **1 个**且 exe 不带 `(deleted)`。事故全文见归档 README.txt。
- SSH 默认 cwd `/root` ⇒ 写盘用绝对路径 `/tmp/olz/...` 且同条命令 `mkdir -p`；起后台服务必须 `< /dev/null`，
  起服务+探测放同一条 exec。设备 busybox：`chmod` 失效（用 sftp.chmod）、无 `curl`/`pkill`/`setsid`，`wget` 无 `--header`；大二进制用 SCP。
- 工具：`zig-src/tools/deploy_device.py start|stop|status|restart [bin] [--port]`（默认 15399）。
  ⚠ **换二进制前必须先 `stop`**：`start` 是「先 SFTP 上传、再杀旧进程」，覆盖正在运行的
  二进制会 `OSError: Failure`（ETXTBSY）。
- 无凭据回归：`tools/driver_matrix.py <base> --user admin --password ...`
  （base 是**位置参数**）；`--expect` 补期望注册名、`--only` 只跑指定驱动，
  用于点名构建验证 opt-in 变体。
- **设备文件留档**：`/opt/armbian/...` → `D:/workspace/server/armbian/...`（不带 opt）；`/opt/script`、`/opt/apps`、`/root` → `D:/workspace/server/f4610u/...`；只留最新一份。
- 光猫 easytier 配置实际是 `/opt/armbian/bin/easytier/easytier.yaml`。

## ★ 前端一律走 CDN，绝不在设备上养前端副本（用户强烈要求，已犯过一次）

设备上放 dist 副本 = 把要消除的东西装回去，且掩盖"CDN 为什么取不到"。正确做法：**先在沙箱（打包机）诊断再动设备**。
- **drive.quark.cn / UC 的 TLS 失败 = 缺 ECDSA 套件补丁，不是 CA 库问题**（2026-10-16 定案，旧记录"设备 CA 无
  GlobalSign"是错的，grep PEM 证明不了任何事）：Zig 0.17.0 std 只 offer ECDHE-RSA，而 quark 的 ECDHE-RSA 路径
  服务端有缺陷（ServerKeyExchange 处 internal_error）⇒ 客户端必须 offer ECDSA（c02b/c02c/cca9），
  补丁 = `tools/ziglib_patch.py`（改 std 的 `crypto/tls/Client.zig` 四处：两个 comptime 分支的 offer 列表 +
  两个 ServerHello switch）。**症状是静默的**：init 时 `TlsInitializationFailed`，挂载数 14→12，服务照常 200。
- **Zig 0.17 std resolv.conf bug**：`HostName.zig` `takeSentinel('\n')` 遇文末无换行报 `EndOfStream` ⇒ 全部外网请求
  `ResolvConfParseFailed`。部署确保 `/etc/resolv.conf` 末尾有 `\n`。
- CDN fallback：`zig.cdn_fallbacks`（逐个重试 2 次）。`RawIndex` 要带出**实际生效**的 cdn 覆盖 `site.cdn`，否则 `/assets` 全 302 到死域名。
  `registry.npmmirror.com` 专拦 .html（451）⇒ 不可用作外壳源。
- **CDN 取不到时二进制直接退出**（`CdnIndexFetchFailed`）—— 设计固有风险。

## 血的教训

1. **手拼 JSON**：`Buf.append` 不转义，只有 `Buf.print` 转义 `{{}}` ⇒ 用严格 JSON 解析测试兜底；前端 axios JSON.parse 失败会**静默降级成字符串**（只报"获取设置失败: Undefined"）。
2. **字符串里有 ≠ 浏览器里能跑**：内联 `<script>` 里 HTML 实体不解码 ⇒ `&amp;&amp;` 语法错误、整个 script 不执行。改动前端至少跑 `node --check`（`tools/check_builtin_js.py` 已接 build 第 0 步）。
3. **前端自动化**：`playwright-core` + 系统 Chrome（别用 agent-browser，下载卡死）；点按钮按文字/role 定位，`.first()` 会点到「清除」。
4. **契约字段 bug 只看状态码发现不了**：`/api/me` 曾缺 `sso_id`/`allow_ldap`/`otp`、多输出 `otp_secret`/`token` ⇒ 登录转圈。必须拿 Go struct tag 逐字段对。
5. **`permission` 曾硬编码 0** ⇒ 前端按位禁用按钮。Go `InitSetup` 写 `0x71FF`；Zig 已改 `App.admin_permission`（真机 29183）。
6. **catch 里的 `try` 会跳过配对 unlock** ⇒ 死锁。catch 里一律 `_ = f() catch |e| {...}`。
7. **临时目录生命周期必须长过会写它的配置对象**（defer cleanup 太早 ⇒ 实测 500）。
8. **189 个人云 list 有秒级最终一致性延迟**（家庭云无）⇒ e2e 轮询容忍，不是 bug。
9. `driver.ProgressFn` 是 0–100 百分比；`addition` 是字符串不是对象（原样落盘 cfg.json）。
10. 路由白名单：`handle()` 只放行已知前缀进 `handleAuthed`，加端点必须同时改白名单（曾漏 `/api/me` 前缀 ⇒ 404）。
11. **架构事实**：每请求一个 ArenaAllocator（`http.zig:622`），arena `free` 只在最近一次分配时回退；`Client` 每实例一把全局锁
    （`client.zig:159`），并发靠每 worker 一个 Client；`model.Obj` 无 ID（Go 有）⇒ 189/189pc 靠路径逐段翻页找 ID。
12. **busybox ash 的 `trap 'cmd' INT TERM` 跑完 cmd 会从中断处继续循环，不会退出**（2026-10-24 实测：
    看门狗被普通 kill 后只删了 pidfile、进程还活着，单实例锁失效）。信号 trap 里必须显式 `exit`
    （`trap 'rm -f "$PIDF"; exit 0' EXIT INT TERM`）；TERM 要等当前 `sleep` 跑完才处理，验证要等一个周期。

## 功能边界（STATUS.md §22）

- **刻意不做**：分享 / SSH 公钥 / webauthn / 2FA / LDAP / 多用户·SQLite·SSO / 搜索索引 / 离线下载 / 分片上传 / S3·FTP·SFTP·MCP 服务。中心思想：单管理员管理整个存储。
- **Zig 特有**：itvsh 驱动、CDN fallback、`@zig-setup`、`zig.*` 配置块、编译期驱动白名单、内置页首装面板。
- 用户 Go 备份实况：`/baidu`、`/onedrive` 在用但**暂不移植**；`/itvsh,/koofr,/jianguo,/123x2,/aliyun,/baidu,/quark,/ecloud_self,/ecloud_family,/hikvision`。

## 待办与文档入口

- **权威待办 = `zig-src/TODO.md`**；审计结论 = `zig-src/docs/STATUS.md`（§22/§23 边界与凭据）；驱动维度审计 = `zig-src/docs/AUDIT_2026-10-18-drivers.md`（权威）。
  更早六份审计（10-11 / 10-17 v1v2 / REVIEW / REVIEW-v1 / DS）已清理，原文 `git show 7356589e:<path>`。
- 已知欠项：全驱动真实 API+UI 回归（凭据 `zig-src/openlist_backup_2026_10_16 13_53_16.json`）、`model.Storage` 无 `modified`、配置项 `delayed_start`/`cors`/`tasks`。
- 验证基线：**438 单测全过**（打包机 `zig build test`，含 115 fixture），aarch64 ~1.21MB；真机 e2e 32/32。
- **remote.py 调用坑**：main() 把 argv 用空格拼接 ⇒ 远端命令必须作为**单个带引号参数**传；内联命令用**绝对路径**（cwd=/root）；
  `--put` 的远端路径**去掉前导斜杠**（MSYS 会改写 `/tmp/...`）。别设 `MSYS_NO_PATHCONV=1`。
- **根目录整洁铁律**：仓库根只允许 openlist 上游文件 + `zig-src/ .github/ .workbuddy/ .workbuddy-ai/`；Zig 脚本一律 `zig-src/tools/`，
  新脚本用 `Path(__file__).resolve().parents[2]` 定位仓库根。
- **pan115 fixture 铁律**：`src/drivers/115list_fixture.json`（`tools/gen_115_fixture.py` 生成）**必须入库**（被 `@embedFile`）；
  真机原文 `115list_sample.json` 含真实文件名**永不入库**。
- 磁盘紧张是老问题（D 盘曾 100%）；npm pack 的 23MB 前端包用完立刻删。
