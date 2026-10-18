# openlist-zig —— 项目长期记忆

## 项目目标与驱动状态

**最终目标（用户 2026-10-10）**：基于 `build_sqfs.yml`，用 Zig 重写完整应用，9 个驱动
全部落地并编译通过：`local`/`webdav`/`189`(个人+家庭)/`123`/`aliyun`/`quark`/`115`/`itvsh`。
**验收标准 = 9 个驱动全部写完 + 编译 + 真机验证。**

| 驱动 | Go 目录 / Name | Zig 实现 | 状态 |
|---|---|---|---|
| local | `Local` | `local.zig` | ✅ 真机验证 |
| webdav(客户端) | `WebDav` | `webdav.zig` | ✅ 真机验证（PROPFIND 207 / GET 200 逐字节） |
| itvsh 上海电信智家硬盘 | `上海电信智家硬盘` | `itvsh.zig` | ✅ 样板驱动 |
| 189 个人 | `189Cloud` | `cloud189.zig` | ✅ 真机验证 |
| 189 家庭(PC) | `189CloudPC` | `cloud189pc.zig` | ✅ 真机验证 |
| 123 | `123Pan`(用户名+密码) | `pan123.zig` | ✅ 实现完成（T2 补课变体） |
| aliyun | `AliyundriveOpen` | `aliyundrive.zig` | ✅ 真机验证 |
| quark | `Quark`(Cookie) | `quarkuc.zig` | ✅ 实现完成（T2 补课变体） |
| 115 | `115 Cloud`(Cookie) | `pan115.zig` | ✅ 实现完成（T2 补课变体） |
| **WoPan 联通沃云盘** | `WoPan`(refresh_token) | `wopan.zig` | ✅ 2026-10-13 实现+注册，**未真机**（无凭据配置） |

**T2（2026-10-12）补课**：同网盘常有两个不兼容驱动，用户配置用 `123Pan`/`Quark`/`115 Cloud`
（非 `_open` 系列）。三者已补齐并注册；`123_open`/`quark_open`/`115_open` 代码保留不注册。
**2026-10-13 加做 WoPan**（用户临时要求的额外驱动，不在 9 个清单内）。

## 关键工程约定

- **本地打包/编译一律走打包机 10.0.0.4**（工作目录 `/tmp`，即 `tools/build_remote.py`
  的 `/tmp/olz-build`）—— 本地性能不行、磁盘不够，**且本机已无 Zig 工具链**
  （`~/.workbuddy-ai/binaries/` 只有 git/go/node/python）。打包机 Debian 13 x86_64，
  root/REDACTED，zig 0.17.0 在 `/root/.cache`（只读用）。**本机产物只能自测，不能当交付。**
- **Zig 0.17.0 硬下界**；`tools/build_remote.py` 一条命令跑完「上传 → test → 交叉编译 → 取回」。
- **手拼 JSON 的坑（2026-10-13 踩过）**：`Buf.append` 写**原始字节、不转义**，只有
  `Buf.print` 才把 `{{`/`}}` 转义成 `{`/`}`。收尾写 `append("}}}")` 会多一个 `}`，
  整个 body 变非法 JSON；axios 把 `JSON.parse` 失败**静默降级成字符串**，前端只报
  「获取设置失败： Undefined」。Go 版走 struct/map 序列化天然免疫。**必须靠严格 JSON
  解析测试兜住**（子串 `indexOf` 测不出；e2e 的 `json.loads` 失败还会静默降级误判成功）。
- **每个驱动都要有单元测试**（`std.testing.allocator` 抓泄漏）。提交前 `zig test` 和
  交叉编译都要过（`tools/build_remote.py` 走打包机，目标 `aarch64-linux-musl`，加 `-lc -fstrip`）。
- **D 盘满 → 测试假报 NoSpaceLeft/泄漏**：先看磁盘。清理大头是 `openlist-zig/.zig-cache`
  （构建缓存）。删大目录用 `cmd //c "rd /s /q"`，别用 Git Bash `rm -rf`。
- **驱动名铁律**：`factory.key` 必须逐字节等于 Go 的 `driver.Config.Name`
  （即写进 `Storage.driver` 的字符串）。历史名只能进 `Factory.aliases`。
- **上游唯一事实来源 = 本地 `D:\workspace\OpenList` 树**（`drivers/<name>/`）。
  不要去 GitHub 拉；`itvsh` 是用户私有驱动，只存在于本地树。
- **SFTP 驱动（2026-10-11 拍板 defer）**：存档 `docs/FEASIBILITY.md` §5.3，非本轮目标。

## ★ 用户明确要求（2026-10-13，不得再以"简化/体积/困难"为由跳过）

> 我曾把下面几点当成"可接受的简化取舍"并写进文档，被用户明确驳回。详见
> `openlist-zig/docs/STATUS.md` §11（含进度）。

- **Go 配置必须无缝迁移**：Zig 配置应当是 Go 的**子集**，理论上不该有差异。
  `tools/import_go_config.py` 现在是有损转换（驱动名映射、丢不支持的驱动、凭据不迁移、
  settings 落默认值）—— 要重做成**直读** Go 的来源。
- **允许 SQLite（C 桥接）；没有 1 MB 体积上限；交叉编译不是 Zig 的弱项**
  （Zig 本身就是 C 交叉编译器）。用"体积/依赖"排除 SQLite 是判断错误，
  要落地 `libsqlite3` + `aarch64-linux-musl`，直读 Go 的 `data.db`。
- **核心算法一律对齐 Go，不得自创**：密码哈希（Go `TwoHashPwd` 双层加盐 +
  `StaticHashSalt="https://github.com/alist-org/alist"` + 每用户 salt；Zig 目前是
  单层 `sha256`）、签名、JWT claim、时间格式……都要逐函数对照，沿用 189pc 那种
  **逐字节**验证法。
- **驱动名映射不是难点**：`factory.key` 逐字节等于 Go `driver.Config.Name`，
  只是一张确定性对照表；不支持的驱动要给**明确可查询**的理由，不能静默丢弃。

## 真机部署（光猫 192.168.1.1:10022，隔离目录 `/tmp/olz`）

- **大二进制必须用 SCP 传**（WinSCP SCP 协议，或 paramiko `scp -t` 模式）。SFTP 传
  1.1MB 必断（EOFError）；10KB 配置正常。端口 15344（先 `netstat -ltn` 选空闲）。
- 设备 busybox 阉割：`chmod` 完全失效（用 SFTP `sftp.chmod()`）；无 `pkill`/`stat`；
  ash 不支持 `for..do`；`umask` 恒 0；`base64` 不在 PATH。
- **只留一个进程**：SO_REUSEPORT 下多进程同监听同端口会被随机分发，造出
  「register 成功但 login 报 no administrator yet」假 bug。杀用 `kill -9`（SIGTERM 无效），
  杀完 `ps`+`netstat` 双确认。
- Zig 版显示前端须配 **线上 CDN**（`cdn`+`web_version=rolling`，`dist_dir` 留空）：
  `https://cdn.jsdelivr.net/npm/@openlist-frontend/openlist-frontend@latest/dist`。
- 配置转换 `tools/import_go_config.py <go备份> <out.json>`；测完清理 `/tmp/olz` + 自进程，
  **绝不动 `/opt/sq/openlist` 与 Go 的 config.json/data.db**。

## 下载签名 sign（2026-10-13）

- 算法逐字对齐 Go `pkg/sign/hmac.go`：带 padding 的 URL-safe base64(HMAC-SHA256) + `:expire`，
  `expire=0` 永不过期，secret 用 `jwt_secret`。config 新增 `sign_all`/`link_expiration`。
- **⚠️ `/d/`、`/p/` 必须是独立于 `handleAuthed` 的路由**（对齐 Go 的 Down 中间件）。曾因挂在
  `handleAuthed` 下被开头 `checkAuth` 拦掉，sign 下载恒 401 —— 已修，并加路由级回归测试
  （`/d/` 带合法 sign 无 token 必须放行；无 sign 无 token → 401）。

## 移植踩坑（复用）

- **189 列表项 `id` 是 JSON 数字**：缺 id 报 `InvalidResponse`，不静默返空串（否则
  rename/move/delete 被拒、mkdir 落根目录静默错位）。
- **189 个人云 list 有秒级最终一致性延迟**（家庭云无）→ 不是 bug，e2e 轮询容忍。
- **Zig 0.17 std.http 坑**：① TLS 下 `BodyWriter.end()` 不 flush 底层 stream，需补
  `connection.flush()`；② `redirect_behavior=.not_allowed` 遇 3xx 直接报错，跟跳须 `.unhandled`；
  坚果云 DELETE 204 无定界头 → `Request.skip_body` 别读正文。
- **itvsh/123/quark 上游 `Copy` 就是 `NotSupport`** —— 这三个驱动**故意不实现 copy**
  （vtable `.copy=null`），有显式测试钉住「别顺手补上」。
- **`driver.ProgressFn` 是 0–100 百分比**（Go `model.UpdateProgress`），勿传字节数。
- **WoPan 协议**：单一 `dispatcher` 入口（POST `panservice.mail.wo.cn/{channel}/dispatcher`，
  channel∈api-user/wohome）；header 签名 = `md5(key+resTime毫秒+reqSeq+channel)` 小写 hex；
  body 的 `param` = AES-128-CBC+PKCS7（IV=`wNSOYIB1k1DjY5lA`，key：api-user 用 clientSecret
  `XFmi9GS2hzk98jGX`，wohome 用 accessToken 前 16 字节）后 base64；响应 `RSP.DATA` 若是
  `"..."` 包裹的密文则同样解密。上传走 `{zoneURL}/openapi/client/upload2C` 的 multipart。

## 验证历史（压缩）

- 2026-10-12：242/242 单测 + 真机六存储挂载；e2e 106 通过/1 跳过（坚果云根级删除）。
- 2026-10-13 晚（sign 路由修复 + WoPan 实现）：本机 328 通过/3 跳过/0 失败；打包机 **331 全过**；
  aarch64 二进制 1,144,608 B；光猫 `/api/admin/driver/names` 含 `WoPan`（共 10 驱动）。
- **2026-10-13 深夜（终态）**：Zig↔Go 重新核对 7 个在用驱动（全部 faithful，189pc 签名逐字节一致），
  修 Local move 子树防护 + Quark makeDir 冲突语义；交叉编译 1,144,432 B；光猫用真实配置重跑 e2e
  **32 通过 / 0 失败 / 0 跳过**。
- 最新结论统一收敛到 `openlist-zig/docs/STATUS.md`（旧审计报告 GO_ZIG_AUDIT/AUDIT_VERIFY/
  DRIVER_COMPARE/CHECKLIST/T2_COMPLETE/TODO 已删除）。

## 项目未来放置（2026-10-13 用户计划）

- `openlist-zig` 后续会放进 `D:\workspace\OpenList` 作为**子目录**，紧挨 Go 的 `drivers/` 树，
  方便逐文件对比上游。届时 Zig 驱动 = `openlist-zig/src/drivers/<name>.zig`，Go = `drivers/<name>/`。
- 本 `.workbuddy-ai/memory/` 当前挂在 `OpenList` 项目下；项目移动后应随 `openlist-zig` 一起搬迁到
  `OpenList/openlist-zig/.workbuddy-ai/memory/`，使其成为自包含子项目。

## ★ 真机隔离铁律与一个差点犯大错的坑（2026-10-15）

**规则**：光猫上的真机测试**只允许在 `/tmp/olz`**（tmpfs，重启即失），
绝不碰 `/opt/sq/openlist` 与 Go 的 `config.json` / `data.db`。

**踩过的坑（必须记住）**：
1. SSH 命令的**默认 cwd 是 `/root`，不是 `/`**。用 paramiko 直接传
   `"tmp/olz/x"` 这种相对路径，落点实际是 `/root/tmp/olz/x` ——
   `tools/remote.py` 的"无前导斜杠 → `abs_remote()` 补回斜杠"那套规则，
   **只对走它自己的 `put()` 的路径生效**；绕过它直接用 paramiko 就会踩坑。
2. **要写盘一律用绝对路径 `/tmp/olz/...`**，并在同一条命令里 `mkdir -p /tmp/olz`。
3. 这台设备没有 `setsid`，busybox 也没有 `curl`（用 `wget`）；
   `nohup ... &` 跨会话不存活——起服务 + 探测必须放在同一条 exec_command 里。
4. `/root/tmp` 会被周期性清理，不能当可靠暂存。
5. **诊断出路径错了就不要将错就错**：我已经打出 `pwd` = `/root`、
   `ls /tmp/olz` = No such directory，却继续用 `$(pwd)/tmp/olz` ——
   发现问题时立刻停下改路径，而不是换个写法重复同一个错误。

## Zig 编译期驱动白名单 `-Ddrivers=`（2026-10-15）

- `build.zig` 加 `-Ddrivers=`；`driver.zig` 的 `builtin` 改成 `blk:` + 一串
  `if (has(basename))` 在 comptime 生成。
- **关键坑**：必须用 comptime **分支**，不能把 `Factory` 收集进数组再过滤 ——
  factory 里是 fn 指针，一持有就强制生成**全部**驱动代码，裁剪直接失效。
- 名字两种拼写都收：Go 驱动名（`189Cloud`）或 Zig 源文件名（`cloud189`）。
  `quarkuc` 一个文件出两个驱动（`Quark`+`UC`），所以 4 个文件 = 5 个注册项。
- `tools/build_remote.py` 必须走 `zig build test`：`driver.zig` 现在
  `@import("build_options")`，裸 `zig test src/tests.zig` 编不过。
- ⚠️ **`zig build` 会吞掉 "All N tests passed."**，并在末尾打一行误导性的
  `failed command: <test bin>`（实测退出码其实是 0）。判成功看
  `--summary all` 打出的 `test success`，别找汇总串。
- 实测：全量 1,183,352 B；`local,webdav,Quark,strm` = 893,352 B（省 24.5%）。

## CI workflow 重组（2026-10-15）

- `build_minimal.yml` → `build_go_minimal.yml`：并入原 build_sqfs.yml 为
  `build_sqfs` job（多产一个 aarch64 sqfs 镜像），另发 `ci-sqfs-<sha>` Release。
- `build_sqfs.yml` 已删除，其 §0–§12 方法论文档搬进 build_go_minimal 头部。
- 新增 `build_zig_minimal.yml`：只产 Zig 版 aarch64 白名单 sqfs。
  打包参数与 Go 版逐项一致（xz -b 1M -all-root、stage/openlist、openlist、755）。
- 校验用 `zig build --help -Ddrivers="..."`（**不是 `-Dhelp`**，那不是合法选项）。

## 内置前端与账号（2026-10-15）

- `src/frontend.zig` 的 `BUILTIN_INDEX` 是**静态占位页**，原先既无安装向导也无
  登录框 ⇒ 普通用户无法在浏览器里初始化。已补一个默认隐藏的 `#setup` 面板：
  fetch `api/public/init_status`，`initialized:false` 才亮出，提交即 POST
  `api/public/init/setup`，成功后 reload。
- **OpenList 没有"注册账号"**（Go 上游也没有）：单管理员设计。public 组只有
  settings/init_status/init/setup，auth 组只有 login、login/hash、me。
  Zig 曾自造 `/api/auth/register`，按"对齐 Go"已删。
- 改 admin 密码只能 CLI：`openlist admin set/random`。且 **`admin set` 在没有
  任何管理员时会报 NoAdministrator** —— 首次只能走 web setup 或
  `OPENLIST_ADMIN_PASSWORD` 环境变量。

## 真机后台进程踩坑（2026-10-15）

- SSH 里起后台服务**必须 `< /dev/null`**：否则子进程继承 channel 的 stdout，
  paramiko 的 read() 永远等不到 EOF，脚本会一直挂着（实测挂了 14 分钟）。
- busybox 的 `wget` **不支持 `--header`**，也没有 `curl` ⇒ 带 Authorization 的
  请求要从本机 Python 直连设备端口（LAN 可达）来发。
- `wget -q` 对非 2xx 不输出 body，验证"被拒绝"的场景别用它。

## workflow 收尾（2026-10-15）

- **UPX 已全部移除**（用户要求）：compress 输入、matrix 的 upx 变体、两个
  Compress with UPX 步骤。原因写在文件里：stub 把解压体放进匿名内存，
  128 MB 的 F4610U 上等于凭空多吃一份二进制大小。
- `build_go_minimal.yml` 的 `drivers` 默认值已与 Zig 的 12 项对齐：
  `local,webdav,itvsh,aliyundrive_open,189,189pc,123,quark_uc,115,wopan,strm`
  ⚠ `123` 是 AWS 系，会把 aws-sdk-go 拖回来（约 +7.7 MiB）。
