# openlist-zig —— 当前状态与结论（2026-10-15 更新）

> 本文是项目**唯一的最新结论文档**。历史审计报告（GO_ZIG_AUDIT / AUDIT_VERIFY /
> DRIVER_COMPARE / CHECKLIST / T2_COMPLETE / TODO）与早期可行性评估（FEASIBILITY.md）
> 均已删除 —— 它们承载的过时结论已汇入此处，设计/可行性背景因项目已完成而不再适用。
>
> **2026-10-14**：重新拉取上游后做了一轮全量比对（基准见 §12.0），比对结果与
> 待二次校验的疑问点全部列在 **§12**。此前 §1–§11 的结论除 §12 特别标注的外均未变。
>
> **2026-10-15**：按本文 §12 的清单逐条核实并修复，详见 **§13**。
> A2 / A3 / A4 / A5 / A10 **已修**（含回归测试，打包机 350 全绿）；
> A6 / A7 经核实属"需真机验证 / 需先定并发模型"，维持现状并说明理由。

## 1. 目标与验收

- 用 Zig 重写 OpenList 兼容服务，塞进中兴 F4610U 光猫（aarch64 / musl / squashfs）。
- **验收标准**：驱动全部写完 + 编译 + 真机验证。
- **当前状态**：**12 个注册驱动**（含 2026-10-15 补的 `UC`，见 §13.5）；单元/交叉编译全绿
  （**350 通过 / 0 失败**）；真机 e2e **32 通过 / 0 失败 / 0 跳过**。

## 2. 驱动清单（12 个注册项 / 11 个驱动实现）

| 驱动 | 注册名（= Go `driver.Config.Name`） | Zig 文件 | 真机验证 |
|---|---|---|---|
| local | `Local` | `local.zig` | ✅ |
| webdav（客户端） | `WebDav` | `webdav.zig` | ✅（PROPFIND 207 / GET 200 逐字节） |
| itvsh 上海电信智家硬盘 | `上海电信智家硬盘` | `itvsh.zig` | ✅ 样板驱动；**私有驱动**：fork 后独立实现，与上游无关（见 §12.A1） |
| 189 个人云 | `189Cloud` | `cloud189.zig` | ✅ |
| 189 家庭云（PC） | `189CloudPC` | `cloud189pc.zig` | ✅ |
| 123 网盘 | `123Pan`（用户名+密码） | `pan123.zig` | ✅ |
| 阿里云盘开放平台 | `AliyundriveOpen` | `aliyundrive.zig` | ✅ |
| 夸克网盘 | `Quark`（Cookie） | `quarkuc.zig` | ✅ |
| UC 网盘 | `UC`（Cookie，`OnlyProxy` 变体） | `quarkuc.zig`（共用实现） | ⚠️ 2026-10-15 注册（§13.5），未真机 |
| 115 网盘 | `115 Cloud`（Cookie） | `pan115.zig` | ✅ |
| 联通沃云盘 WoPan | `WoPan`（refresh_token） | `wopan.zig` | ⚠️ 仅注册 + 单测，未真机（配置无凭据） |
| STRM（其他挂载→.strm） | `Strm`（paths 行） | `strm.zig` | ✅ 2026-10-14 真机验证（挂载/列表/详情/内容/OnlyProxy 全链路） |

**铁律**：`factory.key` 必须逐字节等于 Go 的 `driver.Config.Name`（即写进 `Storage.driver` 的字符串）；历史名只能进 `Factory.aliases`。
**故意不实现 copy**：itvsh / 123 / quark 上游 `Copy` 即 `NotSupport`，Zig 故意把 vtable `.copy` 置 `null`，并有显式测试钉住「别顺手补上」。

## 3. 验证结果

- **打包机 10.0.0.4**（唯一构建路径；本机无 Zig 工具链）：`zig test` **350 passed / 0 failed**（2026-10-15，含本轮新增的 3 个回归测试），无内存泄漏。其中 `every JSON endpoint emits strict, parseable JSON` 把**所有**已注册 JSON 端点跑一遍做严格解析。
- **交叉编译**（目标 `aarch64-linux-musl`，加 `-lc -fstrip`）通过。
- **真机 e2e**（光猫，用户真实配置 10 存储）：**32 通过 / 0 失败 / 0 跳过** —— 9 挂载点全部列出、详情/下载/Range/sign 校验、WebDAV 读、Local 全量写操作 13 项全过。
- **前端页面**：光猫 `15344` 首页由「获取设置失败： Undefined」恢复为正常登录页（`登录到 OpenList (zig)`），logo 正常渲染（`src="https://res.oplist.org/logo/logo.svg"`）。
- **`/api/public/settings`**：返回 **47** 个字段（对齐 Go `db.GetPublicSettingItems()` 的 `flag IN (PUBLIC, READONLY)`），值**全部是字符串**。
- **`/api/fs/list`**：顶层 7 字段齐全（`content`/`total`/`readme`/`header`/`write`/`write_content_bypass`/`provider`），`write=true`；`fs/get` 含 `header`/`related`，`provider` 为驱动名。
- **管理员途径（真机全链路）**：`init_status:false` → `POST /public/init/setup` 建 admin → **前端路径 `/auth/login/hash`（StaticHash）登录成功拿到 token** → `/api/me` 鉴权通过 → `openlist admin set 新密码`（**热重载，服务未重启**）→ 新密码登录成功、旧密码 400。
- **最终 aarch64 二进制**：`1,183,824 B`（sha256 `b97feba6…`），**350 tests passed**（2026-10-15，见 §13）。

## 4. 本轮关键修复（2026-10-13 晚）

1. **sign 下载路由**：`/d/`、`/p/` 必须是**独立于 `handleAuthed`** 的路由（对齐 Go 的 Down 中间件）。曾挂在 `handleAuthed` 下，被开头的 `checkAuth` 401 拦掉，sign 体系形同虚设。已修，并加路由级回归测试（`/d/` 带合法 sign 无 token 必须放行；无 sign 无 token → 401）。
2. **Zig ↔ Go 重新核对**（7 个在用驱动：itvsh / webdav / 123Pan / aliyundrive / quark / 189pc / local）：云盘协议**全部 faithful**，其中 **189pc 的 HMAC/AES 签名逐字节验证一致**（安全关键）。修掉 2 个会动行为的差异：
   - Local `move` 缺 `IsSubPath(src,dst)` 防护（防把目录移进自己子树）→ 对齐 Go `driver.go:293`，已加守卫。
   - Quark `makeDir` 同名冲突返回 `NotSupported` → 改返回 `error.TargetExists`（api.zig `mapDriverError` → 409），对齐 Go `ObjectAlreadyExists`。
   - 余下 cosmetic 未动：aliyundrive 强制 `order_by` + link 缺 `Expiration`；Local `put` 不写 mtime —— 均不影响功能。
3. **`/api/public/settings` 响应体多一个 `}`（2026-10-13 深夜）**：`handlePublicSettings` 收尾写成 `append("}}}")` —— `append` 写**原始字节**，不做 `print` 那样的 `{{`/`}}` 转义，于是 337 字节的 body 里只有前 336 是合法 JSON。后果不是 500，而是前端静默出错：axios 的 `JSON.parse` 抛错被 `silentJSONParsing` 降级成字符串，`e.code === 200` 永远为假，首页只显示「获取设置失败： Undefined」（看起来像 CDN/网络问题）。已修为 `append("}}")`，并加两层回归：`public settings body is strict JSON` + `every JSON endpoint emits strict, parseable JSON`（遍历全部端点做严格解析）。
4. **`/api/public/settings` 字段缺失（2026-10-13 深夜）**：修完 #3 后页面能开，但 logo 是 `<img src="">`。根因是同一个 handler 只返回 10 个**自造**字段（`initial_done` / `api` / `cdn` / `token_expires_in` / `enable_register` …），而前端真正读的键（`logo`、`favicon`、`home_icon`、`settings_layout`、`pagination_type`…）一个都没有。已按 Go 的字段集重写为 47 项**表驱动**输出（键名/默认值照抄 `internal/bootstrap/data/setting.go` 里 `flag != PRIVATE` 的项），值**一律字符串** —— Go 侧是 `map[string]string`，前端用 `t === 'true' || t === '1'` 判布尔，给原生 bool/int 会让判断恒为 false。新增 `public settings carries the keys the frontend actually reads`，把前端代码实际引用的 33 个键逐个钉住（清单由扫描 dist 的 `(\`key\`)` 取值点得出）。
5. **`/api/fs/list` 信封字段缺失（2026-10-13 深夜）**：Go `FsListResp`（`server/handles/fsread.go:49-58`）带 `readme`/`header`/`write`/`write_content_bypass`/`provider`，我们一个都没发。前端 store 用 `setWrite(e.write)` 决定是否渲染上传/新建/删除按钮 —— 字段缺失会让 `write` 变 `undefined`、目录被判成只读，**按钮整片消失**。已加 `appendFsListTail`（根目录与挂载目录共用）；同时给 `fs/get` 补 `header`/`related`，并把 `provider` 从空串改成驱动名（对齐 `fsread.go:309-311`）。新增 `fs list carries the envelope fields the frontend reads`，并用自签 token 在真机逐个核过。
6. **首次安装 / 忘记密码的途径（2026-10-13 深夜）**：此前只有 Zig **自造**的 `POST /api/auth/register`（Go 根本没有这个端点），且没实现 Go 的官方途径 —— 于是空环境下前端既不引导注册、CLI 也改不了密码。已补齐三条官方途径并删掉自造端点：
   - **Web 安装向导**：`GET /api/public/init_status` + `POST /api/public/init/setup`（对齐 `server/router.go:105-106` + `server/handles/setup.go`）。
   - **CLI**：`openlist admin` / `admin random` / `admin set NEW_PASSWORD` / `admin token`（对齐 `cmd/admin.go` 与官方 FAQ「忘记密码怎么办」）。改完凭据后会 POST `/api/admin/user/del_cache` 通知在线服务**热重载**（对齐 `cmd/user.go:DelAdminCacheOnline`），**无需重启**；端点用 `zig.token` 认证（对齐 Go 用 settings 表的 token）。
   - **环境变量**：`OPENLIST_ADMIN_PASSWORD`（对齐 `internal/bootstrap/data/user.go:initAdmin`，仅首次启动、无管理员时生效）。
   - 首次启动自动生成 `zig.token`（对齐 Go 首次启动把 `random.Token()` 写进 settings 表），服务与 CLI 共用。
   - 真机验证：`init_status:false → init/setup → 登录 → admin set 新密码（未重启）→ 新密码可登录、旧密码 400` 全链路通过。
7. **前端登录路径 `/api/auth/login/hash` 缺失 + 密码哈希未对齐 Go（2026-10-13 深夜）**：前端登录页 POST 的是 `/auth/login/hash`，body 里的 `password` **已经**是 `StaticHash(明文)` = `sha256(pw + "-" + StaticHashSalt)`；这个端点此前缺失 ⇒ **前端恒登不上**，而 curl 直接打 `/auth/login` 却是通的 —— 「curl 验证过」≠「前端能登录」。同时把密码存储对齐 Go 的 `User.SetPassword`（`internal/model/user.go:96`）：现生成 16 位随机 salt（`zig.admin_salt`），存 `TwoHashPwd(pwd, salt)` = `sha256(sha256(pw + "-" + StaticHashSalt) + "-" + salt)`。向量测试钉住了用户抓包里的真实哈希（`7f3de24c…`）。这是 §11.3「核心算法对齐 Go」的第一块落地。

## 5. 工程约定（硬规则）

- **⚠️ 本地需要打包 / 编译时，务必一律走打包编译机 `10.0.0.4`（工作目录 `/tmp`，即 `tools/build_remote.py` 用的 `/tmp/olz-build`）—— 这是唯一交付路径。** 原因：本地机器**性能不行、磁盘空间不够**。打包机 Debian 13 x86_64，root/REDACTED；zig 0.17.0 在 `/root/.cache`（只读使用）。**本机产物只能自测，不能当交付。**
- **Zig 0.17.0 硬下界**。**本机当前没有 Zig 工具链**（`~/.workbuddy-ai/binaries/` 下只有 git/go/node/python），`zig test` 与交叉编译都只能在打包机跑 —— 一条命令走 `tools/build_remote.py`（打包源码 → 打包机 test → 交叉编译 → 取回，全包）。
- **本机 D 盘不能 `zig build`**（maker.exe 无法在 D 盘建子进程）→ 一律 `zig build-exe`/`zig test` 直接调用 + 独立 `ZIG_GLOBAL_CACHE_DIR` + 非沙箱执行。
- **每个驱动必须有单元测试**（`std.testing.allocator` 抓泄漏）。提交前 `zig test` 与交叉编译都要过。
- **D 盘满 → 测试假报 NoSpaceLeft/泄漏**：先看磁盘，清理大头是 `openlist-zig/.zig-cache`（用 `cmd //c "rd /s /q"`，别用 Git Bash `rm -rf`）。
- **单测全绿 ≠ 能编出二进制**（Zig 按函数惰性分析，未触发的路径不实例化）—— 流程必须 test → build 都过。
- **上游事实来源 = 本地 `D:\workspace\OpenList` 仓库**，但有两个视图，比对时必须分清（见 §12.0）：
  - `origin/main`（f239f67d）= 上游**最新**代码（用户 fetch 过来，未 merge 进当前分支）；
  - 当前检出分支 `feat/zhijiadisk`（2bd6da93）= Zig 开发时的基线，额外含 `itvsh` 私有驱动
    （用户 fork 后独立实现，与上游无关，上游 main 本来就没有它 —— 见 §12.A1）。
  - 不去 GitHub 拉代码；比对用 `git diff <baseline> origin/main -- <path>` 与 `git show origin/main:<path>`。

## 6. 真机部署（光猫 `192.168.1.1:10022`，隔离目录 `/tmp/olz`）

- **大二进制必须 SCP 传**（WinSCP SCP 协议，或 paramiko `scp -t` 模式）。SFTP 传 1.1MB 必断（EOFError）；10KB 配置正常。端口 `15344`（先 `netstat -ltn` 选空闲）。
- 设备 busybox 阉割：`chmod` **完全失效**（用 SFTP `sftp.chmod()`）；无 `pkill`/`stat`；ash 不支持 `for..do`；`umask` 恒 0；`base64` 不在 PATH。
- **只留一个进程**：SO_REUSEPORT 下多进程同监听同端口会被随机分发，造出「register 成功但 login 报 no administrator yet」假 bug。杀用 `kill -9`（SIGTERM 无效），杀完 `ps` + `netstat` 双确认。
- Zig 版显示前端须配**线上 CDN**（`cdn` + `web_version=rolling`，`dist_dir` 留空）：`https://cdn.jsdelivr.net/npm/@openlist-frontend/openlist-frontend@latest/dist`。

### 6.1 重启光猫后如何恢复（`/tmp` 是 tmpfs，重启全丢）

光猫分区实测：`/tmp` = tmpfs（220.9M，**重启必丢**）；`/` = overlay **可写且持久**
（upperdir=`/opt/cu/apps/apps`，仅剩 15.3M）。部署约定放在 `/tmp/olz` ⇒ 重启后
二进制和 config.json（含管理员凭据）都会消失。恢复路径（三选一，**A 推荐**）：

- **A. 部署时用环境变量定死密码**（对齐 Go `initAdmin`）：
  ```sh
  cd /tmp/olz && OPENLIST_ADMIN_PASSWORD='你的固定密码' \
    nohup ./openlist server --config /tmp/olz/config.json >> /tmp/olz/olz.log 2>&1 &
  ```
  首次启动（无管理员）会自动创建 `admin` + 这个密码并**打印到控制台**。密码是
  你自己定的，不是系统随机生成的 —— 所以不存在"获取"，每次部署用同一个值即可。
- **B. 本机留一份 config.json，部署时一起上传**：salt / hash / jwt_secret / 存储
  配置全部原样恢复。⚠️ 里面有网盘凭据，别提交进 git。
- **C. 把部署目录挪到持久分区**（如 `/opt/olz`）：重启什么都不丢，但根分区只剩
  15.3M，且当前约定是"临时部署在 /tmp" —— 要挪需先明确。

> 登录姿势提醒：前端发的是 `/api/auth/login/hash`（body 里的 password 已是
> `StaticHash(明文)`）；手工 curl 才会用 `/api/auth/login`（明文）。
- 配置转换 `tools/import_go_config.py <go备份> <out.json>`；测完清理 `/tmp/olz` + 自进程，**绝不动 `/opt/sq/openlist` 与 Go 的 `config.json`/`data.db`**。

## 7. 下载签名 sign

- 算法逐字对齐 Go `pkg/sign/hmac.go`：带 padding 的 URL-safe base64(HMAC-SHA256) + `:expire`，`expire=0` 永不过期，secret 用 `jwt_secret`。config 新增 `sign_all` / `link_expiration`。
- `/d/`、`/p/` 独立于 `handleAuthed`（见 §4.1）。无 sign 无 token → 401；有合法 sign 无 token → 放行（对齐 Go `needSign`）。

## 8. WoPan 协议要点（联通沃云盘）

- 单一 `dispatcher` 入口（POST `panservice.mail.wo.cn/{channel}/dispatcher`，channel ∈ api-user / wohome）；header 签名 = `md5(key + resTime毫秒 + reqSeq + channel)` 小写 hex；body 的 `param` = AES-128-CBC + PKCS7（IV = `wNSOYIB1k1DjY5lA`；key：api-user 用 clientSecret `XFmi9GS2hzk98jGX`，wohome 用 accessToken 前 16 字节）后 base64；响应 `RSP.DATA` 若为 `"..."` 包裹的密文则同规则解密。上传走 `{zoneURL}/openapi/client/upload2C` 的 multipart。
- 注册名 `WoPan` 已进驱动表（共 10 驱动），但当前光猫配置无 wopan 存储实例（无 refresh_token），**未真机**。要验证需往 `/tmp/olz/config.json` 加一个 `WoPan` 存储后重启。

## 9. 未实现 / 功能边界

- 数据库与多用户体系、搜索、分享链接、后台任务/离线下载、归档解压与文件下载、远程归档浏览、远程 Range 的真正响应流式、完整设置/存储 CRUD、任务中心操作接口。
- **SFTP SSH 服务端：明确 defer**。单用户虽可缩授权范围（仅开放一个管理员账号、复用现有 `driver.Driver` vtable），但仍需 SSH transport + SFTP 协议，而 Zig 标准库无现成 SSH server，需移植/引依赖；恢复前应先选定可信 SSH 实现并以 OpenSSH/Paramiko 验证互通与 xz 体积，不直接自写密码学传输层。
- **★ 未来移植 SFTP/FTP 服务端时的安全要点（用户 2026-10-13 提出的上游 bug）**：上游 Go 版的 SFTP/FTP 登录**失败计数 key 用了 `IP:端口`** —— 互联网扫描器每次连接源端口都不同，计数永远到不了阈值，**限速/锁定形同虚设**（已被真实爆破验证）。这条值得反馈上游 OpenList。我们将来实现时：**失败计数的 key 必须用纯 IP**（不带端口），阈值判定、锁定时长（Go `model.DefaultMaxAuthRetries` / `DefaultLockDuration`，见 `server/handles/auth.go` 的 `model.LoginCache` 用法）也要对齐并自查一遍 key 的粒度。同理适用于 HTTP 登录接口现有限流逻辑的复查。
- 上传进度 callback 全线接通（所有驱动按 Go `model.UpdateProgress` 报 0–100 百分比；itvsh 因并发上传用原子计数 + 独立轮询线程），但**尚无 `/api` 端点把它暴露给前端**。

## 10. 与上游代码对比（项目将作为 `D:\workspace\OpenList` 子目录）

> 用户计划把 `openlist-zig` 放进 `D:\workspace\OpenList` 作为子目录，紧挨 Go 的 `drivers/` 树，
> 方便逐文件比对。届时布局：
> - Zig：`D:\workspace\OpenList\openlist-zig\src\drivers\<name>.zig`
> - Go ：`D:\workspace\OpenList\drivers\<name>\`
>
> 快速逐驱动 diff（注意 Go 一个驱动是多文件，Zig 合并为单文件）：
>
> ```sh
> diff "D:/workspace/OpenList/openlist-zig/src/drivers/pan123.zig" "D:/workspace/OpenList/drivers/123/driver.go"
> ```
>
> 上游事实来源永远是**本地** OpenList 树，不要去 GitHub 拉；`itvsh` 是 fork 后独立实现的
> **私有驱动**，上游 main 本就没有它，比对基准与两个"事实来源视图"的区别见 §12.0。

## 11. 待处理（用户 2026-10-13 明确要求）

> 用户对当前若干"简化取舍"提出明确反对。以下四项**必须做**，不得再以"工程简化 /
> 体积受限 / 实现困难"为由跳过。此前把它们当成可接受的取舍，是判断错误。
>
> **进度（2026-10-13 深夜）**：**11.3 已完成** —— 注册/初始化端点（§4.6）与
> **密码哈希算法**（§4.7，`salt` + `TwoHashPwd`，向量测试钉住前端真实抓包）都已
> 对齐 Go；**11.1 / 11.2 / 11.4 仍未动**。

### 11.1 Go 配置必须**无缝迁移**；Zig 配置应是 Go 的**子集**

- 现状：`tools/import_go_config.py` 做的是**有损转换** —— 驱动名映射、不支持的驱动丢弃、
  管理员凭据不迁移、settings 一律落默认值。
- 用户要求：**理论上 Zig 配置就是 Go 的子集，不应存在差异**。任何字段都不该在迁移中
  被改写或丢失。
- 待办：重新设计配置层，使其能直接消费 Go 的配置来源（`config.json` + `data.db` 里的
  storages / settings / users），不丢字段、不做语义改写；把 `import_go_config.py` 从
  "转换器"降级为（或替换为）"直读器"。

### 11.2 允许使用 SQLite（C 桥接）；**没有** 1 MB 体积上限；交叉编译不是 Zig 弱项

- 我此前以"体积 / 依赖 / 交叉编译复杂度"为由排除了 SQLite，用户明确否掉：
  - **没有禁止使用 SQLite**；
  - 可以通过 **C 桥接**（`@cImport` / 链接 `libsqlite3`）调用；
  - **没有** 1 MB 的体积硬限制；
  - **交叉编译不是** Zig 的弱项（Zig 本身就是 C 交叉编译器）。
- 待办：落地 SQLite 支持（链接 libsqlite3 + `aarch64-linux-musl` 交叉编译），直接读
  Go 的 `data.db`；据此重新评估体积预算与 musl 静态链接方案。

### 11.3 核心算法必须与 Go **完全一致**，不得自创

- 用户反复强调：核心算法一律对齐 Go，否则后续无法与上游同步。
- 已知不一致（需逐项审计并修正）：
  - ✅ **密码哈希**：已于 2026-10-13 对齐（§4.7）—— `zig.admin_salt`（16 位随机 salt，
    对齐 `User.SetPassword`）+ `TwoHashPwd(pwd, salt)`，`StaticHashSalt` 与 Go 逐字节一致，
    前端真实抓包哈希（`7f3de24c…`）有向量测试钉住。
  - ✅ **注册 / 初始化端点**：Go 只有 `GET /public/init_status` + `POST /public/init/setup`
    （`server/router.go:105-106`），**没有** `/auth/register`。Zig 自造的那个已于
    2026-10-13 删除，两条官方端点已实现，CLI / 环境变量途径也补齐（见 §4.6）。
  - 待办：建立"逐函数对照 Go"的审计清单（沿用 189pc 那种**逐字节**验证的做法），
    覆盖签名、JWT claim、时间格式等其余安全/协议相关算法。

### 11.4 驱动名 / 字段映射**不是**难点，是必须做对的基础工作

- 我此前把"驱动名需映射、不支持驱动需丢弃"描述成工程难点，用户不认可 ——
  驱动名映射只是一张**确定性对照表**（`factory.key` 逐字节等于 Go 的
  `driver.Config.Name`），不存在技术难点。
- 待办：补全**所有** Go 驱动的映射；不支持的驱动要给出**明确、可查询**的理由，
  而不是在转换脚本里静默丢弃。

## 12. 与上游最新代码的二次比对（2026-10-14，疑问点待二次校验）

### 12.0 比对基准

- **Zig 侧**：工作区 `openlist-zig/src`（11 个注册驱动 + 3 个未注册变体，见 §2/§5）。
- **上游侧**：`origin/main` = `f239f67d`（Merge 'OpenListTeam:main'，用户已 fetch 未 merge）。
  与 Zig 开发基线 `feat/zhijiadisk`（`2bd6da93`）之间共 **29 个提交**（28 个上游变更 +
  1 个 merge 点），核心目录（`drivers/ server/ pkg/ internal/`）90 个文件变更。
- 本轮逐项核对了与 Zig 已实现功能相关的全部变更，结果分三类：**A 疑问点（需二次校验/决策）**、
  **B 已确认对齐**、**C 上游有变但 Zig 无对应功能（记录）**。

**上游 29 个提交逐条过账**（⭐=与 Zig 已实现功能相关，其余为不相关/未实现驱动）：

| 提交 | 与 Zig 的关系 |
|---|---|
| f239f67d merge 点 | 基准本身 |
| 482464c2 net gzip 错误处理 | C（Zig 无该抽象层） |
| 6bb4c880 s3 驱动 direct upload 签名 | C（s3 驱动未实现） |
| 4f70daad storage 更新后刷根目录 | C（Zig 无存储 CRUD/目录缓存；补 CRUD 时按新语义）⭐ |
| 3d3d10a1 139 大文件上传 | C（139 驱动未实现） |
| 8cfe906e webdav 条件 PUT | ⭐ **A4** |
| f27748d9 s3 服务端 common prefixes | C（无 S3 服务端） |
| 61e535c9 189pc 家庭云转存保留扩展名 | ⭐ **A6**（Zig 无转存流程，未跟进） |
| 4c39bbe9 189pc 登录对齐官方 PC 端 | ⭐ **B 已对齐** + A8/A9 |
| e1d88b07 lanzou 新下载页 | C（lanzou 未实现） |
| ea10624f 加固请求处理 | ⭐ **A2**（fsmanage）+ **A3**（setting）+ B（代理 header 不适用） |
| 54ae9d74 searchnode 索引路径 | C（无搜索） |
| c16701b9 cgo-actions 构建 | 无关（CI 构建） |
| 893457cd aliyundrive callback 并发闸门 | ⭐ **A7** |
| 90acfa18 请求 origin 访问集中化 | C（put/copy_move/link 仅调用方迁移，无行为变化） |
| 1462d63a net 分片下载取消错误 | C（无分片下载器） |
| cadbf872 teldrive 根路径 | C（teldrive 未实现） |
| 9de3f69b fs/get related 限视频文件 | ⭐ **A5** |
| e73a80c7 pikpak 自动重登 | C（pikpak 未实现） |
| 6c600910 fs/get 目录返 FOLDER | ⭐ **B 已对齐**（objTypeFor） |
| b51d1c82 s3 ranged body 关闭 | C（无 S3 服务端） |
| f286862c stream parked readers 索引 | C（无此抽象层） |
| 40f4f654 ftp EOF/嗅探 | C（无 FTP） |
| 3a31b438 offline 工具集中化 | C（无离线下载） |
| 56064d19 link 缓存生命周期策略 | C（无 link 缓存，见 12.C 首条） |
| d894a398 115_open OSS 凭证过期重试 | ⭐ **B 已对齐**（OssTokenExpired 三处） |
| 084c0081 构建邮箱域名 | 无关（构建配置） |
| 4580c4db alist_v3 子路径 | C（alist_v3 未实现） |
| 5447ecb0 s3 测试 fixture 编码 | 无关（测试） |

### 12.A 疑问点（按优先级，待用户安排二次校验；A1 已澄清保留编号供交叉引用）

**A1.【已澄清，非差异】itvsh 是 fork 后独立实现的私有驱动，与上游无关**
（用户 2026-10-14 确认）。此前误将「origin/main 的 drivers/ 目录里没有 itvsh」
当作"上游删除了 itvsh"——实际是上游**本来就没有**这个目录，它只存在于用户的
fork 分支（`feat/zhijiadisk`），Zig `itvsh.zig` 的注册名依据 `drivers/itvsh/meta.go:34`
在本地分支树中有效。结论：Zig 继续注册「上海电信智家硬盘」不受任何影响；
后续把分支 merge/rebase 到新上游 main 时，`drivers/itvsh/` 属于本地新增文件，
正常合并即可保留，不需要当作冲突处理。

**A2.【高】✅ 已修（2026-10-15，见 §13.1）fs/move、fs/copy、fs/remove 缺「纯文件名」校验（上游安全加固 ea10624f）。**
上游给 `FsMove`/`FsCopy`/`FsRemove` 补了 `checkRelativePath(name)`：
name 含 `/` 或 `\`、或为空、或为 `.`/`..` → 直接 403 `using relative path is not allowed`
（`FsRename` 原本就有此校验）。Zig 的 `handleFsMove/…Copy/…Remove/…Mkdir`（api.zig:980-1068）
均无等价校验，且 `urlmod.joinPath`（util/url.zig:253）是纯字符串拼接、不归一化 `..`：
- `name="a/b"` → 拼出 `src_dir/a/b` 继续操作**子路径**（上游 403）；
- `name=".."` → 拼出 `src_dir/..` 直接交给驱动（local 有 `cleanPath` 防穿越兜底，
  云盘驱动多半 404，但行为与上游不一致）。
缓解因素：本工程单管理员（无多用户越权面）、local 驱动有 `cleanPath` 段级 `..` 防护。
待二次校验：分别给两侧发 `names:["../x"]`、`["a/b"]`、`[""]` 对比响应；
决策是否补一个 `checkRelativePath` 等价校验（含 rename 的 `name` 字段，Go 是五个端点都查）。

**A3.【高】✅ 已修（2026-10-15，见 §13.2）public settings 缺新增键 `sso_postmessage_origin`。**
上游新增 `conf.SSOPostMessageOrigin = "sso_postmessage_origin"`（TypeString、
默认 `""`、Flag=PUBLIC，setting.go/const.go 各 +1）。Go 的
`/api/public/settings` 现在是 **48** 个字段；Zig 的
`public_setting_defaults`（api.zig:496）仍是 47 项，SSO 段缺这一项。
其余 47 项键名/默认值与 origin/main 逐项核对无差异。
待办：表里 SSO 段补一行 `.key = "sso_postmessage_origin", .value = ""` 即可
（前端 SSO postMessage 校验读它；Zig 无 SSO，键值恒默认空串不影响）。

**A4.【中】✅ 已修（2026-10-15，见 §13.3）WebDAV 服务端 PUT 缺条件请求与新状态码（上游 8cfe906e）。**
上游 `handlePut`（server/webdav/webdav.go）现在：PUT 前先 `fs.Get`——
目标已存在且是目录 → 405；用 `net.CheckPreconditions`（新公开函数，自
`internal/net/preconditions.go`）处理 If-Match/If-None-Match/If-Modified-Since/
If-Unmodified-Since/If-Range → 满足则 304/412；成功后**已存在→204、新建→201**
（此前恒 201），且 PUT 后 `fs.Get` 失败→500（不再回退到内存 obj）。
Zig `src/webdav.zig:297` 的 PUT 恒 201、无条件请求处理。
影响面：标准 WebDAV 客户端（挂载盘/rsync 类）做「不存在才写入」时会出错。
待二次校验：`curl -T file -H "If-None-Match: *"` 对已存在文件，两侧状态码对比。

**A5.【中】fs/get 的 `related` 上游改为只对视频文件计算（9de3f69b）。**
上游 `FsGet` 现在**仅当 `!obj.IsDir() && GetFileType(name)==VIDEO`** 才列父目录算
`related`（此前所有文件都列）；Zig `handleFsGet` 恒返回 `"related":[]`
（api.zig:976，注释"前端当前不读"）。前端视频播放器用 related 做同目录剧集/关联文件，
Zig 恒空意味着该功能恒缺。待决策：是否按上游新语义实现（VIDEO 文件列一次父目录）。

**A6.【中】189pc 家庭云上传机制与上游不同（上游 61e535c9 同时改了细节）。**
Go 的家庭云（`isFamily`）上传：先以临时名 `0{uuid}{ext}` 上传（本次修复：保留
**原文件扩展名**，此前固定 `.transfer`，转存后扩展名会丢），完成后
`FamilyTransfer` 转存为目标名。Zig `cloud189pc.zig` 的 `put` 对家庭云
**直接以目标名上传**（无临时名/转存流程，文件头也声明 FamilyTransfer 未实现）。
真机 32 用例通过，但未见覆盖「家庭云 + 中文/特殊字符文件名」——Go 绕临时名
可能正是因为家庭云上传通道对目标名有限制（待证）。待二次校验：真机往家庭云
传中文名/长名文件对比两侧成功率；若 Zig 直传稳定则记录为有意差异，否则需移植
「临时名 + 转存」。

**A7.【中】aliyundrive_open 代理下载的 per-user 并发闸门未实现（893457cd）。**
上游 `Link()` 非 redirect 时不再返回直链，改返回 `RangeReader`
（`callback.go` 新增 295 行）：同一阿里**用户**共享并发上限
`callback_concurrency`（默认 1；permit 获取超时 1s、重试 3 次、超限报
新错误 `errs.TemporaryCapacity`）；`Drop` 时注销。Zig `aliyundrive.zig` 的 link
对非 redirect 返回 `.{ .url, .proxy = true }`，代理在 `api.zig handleDownload`
完成，**没有任何并发限制**（配置项保留但不起作用，注释自述"驱动没有插手的位置"）。
风险：光猫上多设备同时播放/下载同一阿里账号文件会并发打满，可能触发阿里限流。
注意 Zig 的限速器是**每驱动实例**一份，与上游"每用户全局共享"本就不同（文件头已记）。
待决策：是否在 API 层补一个简单的 per-storage（或 per-user）信号量。

**A8.【低】189pc 扫码登录上游改为「本地轮询」（4c39bbe9 配套）。**
上游 `loginByQRCode` 现在在服务端本地轮询（2s 间隔、20s 超时，`QR_CLIENT_TYPE="1"`，
表单加 `cb_SaveName=3`、`isOauth2=false`、`state`），扫码确认后**自动完成**，
超时才把二维码交回前端再保存一次（此前要用户反复保存）。Zig 不支持扫码
（`login_type=qrcode` → `NeedInteractiveAuth`，addition schema 里也有提示）。
维持现状即可；将来若实现，参数须按新流程（尤其 clientType 用 "1" 而非 10020）。

**A9.【低】189pc 上传断点续传：上游进度缓存 key 新增扩展名维度。**
上游 fastUpload 的 `UploadProgress` 持久化 key 从 `(sessionKey, fileMD5)` 变为
`(sessionKey, fileMD5, path.Ext(fileName))`——同名不同扩展名的文件不再互相污染。
Zig 无断点续传（无 `GetUploadProgress` 等价物），中断重传从头开始。记录为既有缺口。

**A10.【低】quark_uc 的 `UC` 变体驱动未实现（既有差异，非本次变更）。**
上游 `drivers/quark_uc/meta.go` 一向有两个 Config：`Quark` 与 `UC`（OnlyProxy 变体），
本次未变。Zig 只注册 `Quark`（quarkuc.zig）。若用户 Go 配置里存有 `driver:"UC"`
的存储，Zig 会报驱动不存在。其余驱动（115/123/189/strm/wopan/local/webdav）均单
Config，已逐一核对无此问题。

### 12.B 本轮确认已对齐（无需动作，附二次校验建议）

- **189pc 登录对齐官方 PC 客户端（4c39bbe9，上游 utils.go 442 行）**：
  `APP_ID 8025431004→9317140619`、`VERSION 6.2→7.2.4.0`、短信二次校验
  （`sms_code`/`device_id`(DEVICEID cookie)/`user_finger` 自动生成保存/
  `client_sn`/`jg_open_id`）、`loginHeaders` 带 `user-finger`+`Referer`、
  `appConf.do` 下发 paramId（新版登录页从 redirect URL 取 lt/reqId）、登录表单
  新字段（`version=v2.0`/`apToken`/`pageKey=normal`/`epd`）、
  `getSessionForPC` 带 `deviceParams`+`X-Request-ID`、refreshToken **HTTP 200 也可能
  失败**（`RefreshTokenResp.HasError()`：result≠0 或 accessToken 空）、
  `username/password` 不再必填（有 token 可空）。—— **Zig cloud189pc.zig 已全部实现**
  （其注释自述实现时本地 Go 树还是旧值 `8025431004`/`6.2`，即当时是对着上游最新写的）。
  二次校验建议：以 `git show origin/main:drivers/189pc/utils.go` 为准逐函数再对一遍，
  重点 `keepLoginParam` 语义（二次校验未完成时保留 loginParam、错误文本进 `Status`）。
- **115_open OSS 临时凭证过期重试**：上游 `retryExpiredToken`（Initiate/UploadPart/
  Complete 三处，保 uploadId 只重放被拒操作）；Zig `115open.zig` 的
  `OssTokenExpired` 在同样三处调用点（:1025/:1045/:1056）有等价两轮循环。✅
- **fs/get `type` 字段**：上游改用 `GetObjType(name, isDir)`（目录→FOLDER，6c600910）；
  Zig `model.objTypeFor(name, is_dir)` 同语义（FOLDER=1）。✅
- **aliyundrive_open 配置**：上游 meta.go 新增 `callback_concurrency`；Zig addition
  schema 已含（保留字段、不起作用，见 A7）。✅
- **代理回源 header 安全**：上游 `ProcessHeader` 新增硬剥离 19 个不安全 header
  （authorization/cookie/host/referer/forwarded/x-forwarded-* 等，ea10624f）。
  Zig 的代理回源（api.zig:1677-1693）只透传**驱动 Link.header** + 自造 Range，
  从不转发客户端请求头——天然不涉及此问题，无需跟进。✅
- **fs/get 虚拟根/provider/sign 等既有对齐项**：相关 Go 文件（fsread.go 其余部分、
  sign、router）本轮无行为变更。✅

### 12.C 上游有变但 Zig 无对应功能（记录，暂无动作）

- **link 缓存生命周期重构**：新增 `internal/op/link_lifecycle.go`（admitLink/acquire，
  Expiration 与 SyncClosers 引用计数二选一）、`Link.Clone()` 不再继承 `Expiration`、
  link 缓存 key 加 `proxy/`/`redirect/` 前缀（同一路径的代理链接与 302 链接分开缓存）。
  Zig **无 link 缓存**：每次 fs/get、下载都现调 `driver.link`——多一次上游 API 往返
  （有触发限流的代价），但永远不会拿到过期直链。将来若加缓存须按新语义实现。
- **direct upload 的 `content_type`**：`FsGetDirectUploadInfoReq` 新增 `content_type`
  字段（mime 校验后经 `conf.DirectUploadContentTypeKey` 透传）。Zig 无 direct upload
  端点（fs list 信封里 `direct_upload_tools` 本就 omitempty）。
- **UpdateStorage 先丢缓存再重建**（4f70daad）：`UpdateStorage` 现在**无条件**先
  `Cache.DeleteDirectoryTree(driver, "/")` + `InvalidateStorageDetails`（此前只在挂载
  路径改名时清理）——修复"改存储配置后根目录仍返回旧缓存"。Zig 仅 `GET /api/admin/storage`
  （只读），无存储 CRUD、无目录缓存，不适用；将来补 CRUD/缓存时须按新语义
  （**每次更新无条件清缓存**，且在 Drop/重建驱动**之前**清）。
- **SSO**：`ssologin.go` 87 行重构（postMessage origin 校验，读 A3 的新设置键）+ 新增
  `internal/conf/context.go`（请求 origin 访问集中化）。Zig 无 SSO。
- **搜索**：`searchnode.go` 索引路径修复 + `search.go` 目录节点 meta 判定重构。Zig 无搜索。
- **S3 服务端**：common prefixes 补 `/`（f27748d9）、ranged body 关闭等多处。Zig 无 S3。
- **离线下载**：`offline_download.go` 大幅重构（工具注册集中化）。Zig 无离线下载。
- **net/stream 内部**：gzip 错误处理（482464c2）、分片下载取消错误保留（1462d63a）、
  并发 slot 改为入队后启动、`RangeReadCloserIF` 删除、`orderedReaders` 排序索引
  （f286862c）。Zig 无分片下载器/这些抽象层，不适用。
- **errs**：新增 `TemporaryCapacity`（仅 A7 场景用）。Zig `mapDriverError` 无需映射
  （除非实现 A7）。
- **Zig 未实现的驱动**上游有小改：139（大文件上传 3d3d10a1）、alias、alist_v3、lanzou、
  onedrive、pikpak（token 过期自动重登 e73a80c7）、s3、teldrive。—— 不在 Zig 驱动清单内。
- **锚点确认（Zig 对齐的依据均未变）**：`pkg/sign/hmac.go`、`server/router.go`、
  `internal/model/user.go`（TwoHashPwd/SetPassword）、`internal/bootstrap/data/user.go`
  （OPENLIST_ADMIN_PASSWORD）、`cmd/admin.go`、以及
  `drivers/{local,webdav,strm,wopan,189,123,quark_uc,115,123_open,quark_open}` 全部
  无变更——§7 sign、§4.6/§4.7 的对齐结论继续有效。

## 13. 2026-10-15 按 §12 清单逐条核实与修复

> 本轮把 §12 的每条都先在代码里核对过再动手。核对脚本改用
> `tools/check_public_settings.py`（常驻、可反复跑、返回非零即失败），
> 不再是临时脚本 —— 上游 setting.go 再变时能第一时间发现。

### 13.1 A2 ✅ fs/move、fs/copy、fs/remove、fs/rename 补 `checkRelativePath`

- 新增 `isPlainFileName`（`api.zig`）：与 Go `fsmanage.go:338` 等价 ——
  含 `/` 或 `\`、空串、`.`、`..` 一律 403 `errs.RelativePath`
  （`internal/errs/errors.go:13`，文案 `using relative path is not allowed`）。
- 四个端点全部在**碰到驱动之前**校验（上游调用点 `FsMove:116` / `FsCopy:223` /
  `FsRename:306` / `FsRemove:384`）。
- 另外补齐 Go 的 `len(req.Names) == 0 → 400 "Empty file names"`
  （`FsMove:76` / `FsCopy:182` / `FsRemove:358`）—— 此前是"什么都不做然后返回 200"。
- 回归测试：`fs move/copy/remove/rename reject relative names like Go
  checkRelativePath`（纯逻辑 9 例 + 四个端点 × 5 种坏名字 + 空数组 400）。
  注意测试里必须有 body：`parseBodyJson` 把空 body 当 `{}`，所以加了
  `doRequestJson` 辅助函数（此前测试全靠 `doRequestWith`，请求体传不进去）。

### 13.2 A3 ✅ public settings 补 `sso_postmessage_origin`；发现并纠正一处误判

- 按上游 `conf.SSOPostMessageOrigin`（`const.go:120` + `setting.go:214`，
  TypeString、Flag PUBLIC）补一行，键数回到 **48**。
- **误判纠正**：同时用脚本做了 Go↔Zig 的**逐项默认值比对**，发现
  `announcement` 的默认值 Zig 是空串、Go 是欢迎语，我一度"顺手补齐"。**这是错的** ——
  用户确认那是**有意删除**：本工程没有前台入口编辑公告，把欢迎语加回来会让用户
  看到一段删不掉的文案。已回退为空串，并在 `api.zig` 里写明原因；
  `check_public_settings.py` 用 `DELIBERATE` 表登记这项，不再误报。
  要真正补平成 Go，需要同时实现 `/api/admin/setting` 对 announcement 的读写
  和前台编辑入口。

### 13.3 A4 ✅ WebDAV PUT 补条件请求与正确状态码

- 对齐上游 `8cfe906e` + `internal/net/preconditions.go`（从 `golang.org/x/net`
  v0.58.0 取原文核对）：PUT 前先 `fs.Get`，已存在且是目录 → **405**；
  按 Go `server/common/proxy.go:90` 的 `GetEtag` 生成 ETag（有 hash 用 hash，
  否则 `"<hex(mtime秒)>-<hex(size)>"`，**秒而非纳秒**——上游注释说明后端不保证
  亚秒精度可复现，用纳秒会让条件请求永不成立）。
- 完整移植 `CheckPreconditions`：`If-Match` / `If-Unmodified-Since` /
  `If-None-Match` / `If-Modified-Since`，按 RFC 9110 §13.2.2 的顺序求值；
  不满足 → **412** 且不上传；GET/HEAD 走 304（`writeNotModified`）。
- 新增 `parseHttpTime`，支持 HTTP 要求的 IMF-fixdate 及 RFC 850 / asctime 两种
  旧格式；解析失败按 Go 语义当 `condNone`（忽略该头），不会误判成 412。
- 成功后**已存在 → 204 / 新建 → 201**（此前恒 201，客户端无法区分覆盖与新建），
  并重新 stat 回填新 ETag。
- 影响：rclone / 挂载盘类客户端靠 `If-None-Match: *` 做"不存在才写入"，
  此前会整份重传且冲突覆盖无从谈起。

### 13.4 A5 ✅ fs/get 的 `related` 按上游新语义实现

- 对齐 `9de3f69b`：**仅当** `!isDir && GetFileType(name) == VIDEO` 才列一次父目录，
  用 `filterRelated`（`strings.TrimSuffix(name, Ext(name))` 前缀匹配兄弟文件）。
- 列目录失败不影响 fs/get 整体（Go 的 `if err == nil` 语义）。

### 13.5 A10 ✅ 注册 `UC` 变体驱动

- 上游 `drivers/quark_uc/meta.go` 注册**两个** Config：`Quark` 与 `UC`（OnlyProxy）。
  Zig 此前只注册 `Quark`，用户配置里 `driver:"UC"` 会直接报"驱动不存在"。
- 做法是**参数化而不是复制**：`quarkuc.zig` 新增 `Conf{name,ua,referer,api,pr,
  only_proxy}` 与 `quark_conf` / `uc_conf` 两份常量，模块级常量改为
  `self.conf.*`；`drvName` 改为从 `self.conf.name` 取（否则 fs/get 的 `provider`
  会把 UC 存储显示成"Quark"）；`link` 对 OnlyProxy 返回 `proxy = true`
  （UC 直链靠 Cookie 认身份，302 出去必失效）。
- 注册表新增 `uc_factory`，注册项 10 → 12（11 个驱动实现，quarkuc 出两个）。
- 回归测试钉住两份 conf 的站点参数/OnlyProxy/schema 一致、驱动自报名字、`createUc`。

### 13.6 未修项（附理由，不做静默跳过）

- **A7 aliyundrive 代理下载的 per-user 并发闸门**：上游 `893457cd` 给 `Link()`
  加了 `callback_concurrency`（默认 1，1s 超时、3 次重试、`errs.TemporaryCapacity`）。
  Zig 的 `link` 对非 redirect 返回 `.{ .url, .proxy = true }`，代理在 api.zig 完成，
  **无限流**。风险是同一阿里账号被多设备并发打满触发阿里限流。
  暂缓原因：Zig 的限速器是**每驱动实例**一份，与上游"每用户全局共享"本就不同，
  直接照搬会改变语义。实现前需要先确定这个设备上的并发模型。
- **A6 189pc 家庭云上传**：上游 `61e535c9` 用临时名 `0{uuid}{ext}` + `FamilyTransfer`
  （本次修的是保留扩展名）。Zig 是直接以目标名上传。真机 e2e 32 用例已过，
  但中文/特殊字符长名未覆盖。需要真机对比后才能确定是有意差异还是缺功能。
- **A8 189pc 扫码登录本地轮询**：Zig 不支持扫码（`NeedInteractiveAuth`），
  上游已改成本地轮询（clientType 用 `"1"` 而非 10020）。维持现状，将来实现时
  按新流程参数。
- **A9 189pc 断点续传**：Zig 无 `GetUploadProgress` 等价物，中断从头重传。
- **§11.1 Go 配置无缝迁移 / §11.2 SQLite 直读 data.db / §11.4 全驱动映射**：
  仍未动，见 §11。

### 13.7 驱动编译成 .so 模块化的调研结论：**不建议**

用户 2026-10-15 提出把驱动编成独立 .so、运行时删文件裁剪、下拉框按可用 .so 渲染。
已实测后否决（详见 `docs/MODULAR_DRIVERS.md`），三条硬数据：

1. 当前 aarch64 二进制是**完全静态**（`Type: EXEC`、无 INTERP、无 dynamic 段），
   静态 musl **不能 dlopen** ⇒ 必须先把部署改成动态 libc，把
   `ld-musl-aarch64.so.1` + `libc.so` 一起塞进光猫（`/` overlay 只剩 15.3 MB）。
2. `pan115.zig` 编成**自包含** .so = 177,536 raw / 69,652 xz，是它静态边际
   （+52,736 / +23,388）的 **3.4 倍** —— 每个 .so 都重复编了一份 client /
   cookiejar / util。要共享 core 就必须把驱动接口层全部改写成 C ABI。
3. Zig 的惰性分析会**静默**吞掉驱动代码：`comptime { _ = @import(...); }` 编出的
   .so 只有 1,320 B，必须 `export fn` 引用 `factory.create` 才能拖进整条代码链。

替代方案（编译期白名单 + 注册表裁剪，等价实现"按需裁剪 + 下拉框只列可用驱动"，
零 ABI 风险）已写入同一文档待用户确认。

### 13.8 本轮验证结果

- 打包机 `zig test`：**350 passed / 0 failed / 0 skipped**（原 338，新增 3 个回归
  测试：checkRelativePath 端点层、stemOf、UC 变体）。
- 交叉编译：`aarch64-linux-musl` 通过，**1,183,624 B**，
  sha256 `368bf2d0…`。
- `tools/check_public_settings.py`：`go=46 zig=46 OK`（`announcement` 作为
  DELIBERATE 登记，`version` 由 `EXEMPT` 放行）。

### 13.9 清理兼容性包袱：删除 `Factory.aliases` 与大小写宽容匹配（用户 2026-10-15）

用户要求："不要有兼容性包袱，一些错误的配置、结论全部删除，我这边会按照最新
配置重新添加驱动"。

已删的三样东西：

1. **`Factory.aliases` 字段整个机制**。只有两处用到过，都是本工程早期版本
   自己写进配置的历史名，Go 侧从来没有：
   - `itvsh.zig` 的 `.aliases = &.{"Itvsh"}`（Go 真名是「上海电信智家硬盘」）；
   - `pan123.zig` 的 `.aliases = &.{"123"}`（Go `driver.Config.Name` 是 `123Pan`，
     目录名叫 `123` 只是 Go 的**目录**名，不是驱动名）。
2. **`driver.find` 的大小写宽容匹配**。原来用 `std.ascii.eqlIgnoreCase`，
   现在改成 `std.mem.eql` —— 与 Go `internal/op/driver.go:26` 的
   `map[string]DriverConstructor` 精确查找逐字对齐。Go 遇到 `"quark"` 一样报
   `no driver named: quark`，Zig 现在也报。
3. `main.zig` 的 `normalizeDriverNames` 注释原文写着"允许别名与忽略大小写
   （只为读得进老配置）"，已改成解释精确匹配语义与报错预期。

顺带核实：这些历史名**不在你任何现存配置里**。光猫上 `/opt/sq/openlist/config.json`
与 `/tmp/olz/config.json` 均已不存在（按 §6 约定测完清理），
`tools/import_go_config.py` 的 `SUPPORTED` 表用的也全是 Go 正式名
（`Local`/`WebDav`/`123Pan`/`Quark`/`115 Cloud`/…）。所以删除零影响。

新增回归测试：`find matches the Go Config.Name byte for byte — no aliases,
no case folding`（历史名与大小写变体必须查不到）+ `keys()` 无重复且自洽。
`driver.zig` 因此需要 `const testing = std.testing;`，并加了一个 `test { ... }`
块把注册表拉进测试二进制。

### 13.10 本轮验证结果

- 打包机 `zig test`：**353 passed / 0 failed / 0 skipped**（原 350，新增 2 个
  `driver.zig` 回归测试）。
- `tools/check_public_settings.py`：`go=46 zig=46 OK`。
- 交叉编译：`aarch64-linux-musl` 通过，**1,183,320 B**，sha256 `e1bfaeae…`。
  （删掉 aliases 后比上一版 1,183,624 B 只小了 304 B —— 两个字符串常量的代价
  本来就微不足道，本项的价值是**语义对齐 Go + 去掉误导性注释**，不是省体积。）


---

## 14. 2026-10-15 CI：驱动白名单落地 + workflow 重组（用户拍板）

### 14.1 Zig 侧编译期驱动白名单（`-Ddrivers=`，即原方案 A）

- `build.zig`：新增 `-Ddrivers=`（默认空 = 全量），内部先把用户传的名字
  翻译成 **basename**（`src/drivers/<name>.zig` 去扩展名）并**校验**，未知
  名字在编译前就以非零码失败并列全部合法值 —— 不会静默产出缺驱动的二进制。
- `driver.zig`：`builtin` 由 `blk:` + 一串 `if (has(...))` 在 comptime 生成。
  此处**不能**把 `Factory` 值收集进数组再过滤：一旦持有 factory 就等于持有
  里面每个 fn 指针，**所有驱动的代码都会被强制生成**（Zig 惰性分析只认"被
  引用"）。用 comptime 分支时未选中的 `@import(...).factory` 连同分支一起消掉。
- 名字接受两种拼写：Go 驱动名（`189Cloud`，也就是写进 config.json 的
  `Storage.driver`）或 Zig 源文件名（`cloud189`）—— 后者顺带解决了 itvsh
  的 key 是中文「上海电信智家硬盘」、命令行不方便打的问题。
- `tools/build_remote.py`：改走 `zig build test` / `zig build`（裸 CLI 没有
  build.zig 参与，`@import("build_options")` 会直接编译失败），并支持
  `--drivers "..."`。
- 真机实测（打包机 + 光猫 `/tmp/olz`）：`local,webdav,Quark,strm` →
  二进制 **893,352 B**（全量 1,183,352 B，省 **24.5%**），
  `/api/admin/driver/names` 返回 `["Local","WebDav","Quark","UC","Strm"]` ——
  注意 **4 个驱动文件出 5 个注册项**，因为 `quarkuc` 一个文件同时注册
  `Quark` 与 `UC`。
- 白名单集下单测同样要全绿：为此把 `driver.zig` 的两个回归测试改成
  白名单感知（全量下 12 项 / 裁剪下 5 项都成立，断言的都是不变量）。
- ⚠️ 判定信号：`zig build` 的 Run 步骤走 runner 协议，会吞掉
  `All N tests passed.` 汇总行、末尾还打一行误导性的 `failed command:`。
  必须用 `--summary all` 打出的 `test success`（打包机实测 ZIGBUILD_RC=0）。

### 14.2 workflow 重组（用户 2026-10-15 要求）

- `build_minimal.yml` → **`build_go_minimal.yml`**：并入原 `build_sqfs.yml`
  的整套逻辑，作为新增的 `build_sqfs` job，因此它现在产普通二进制之外**还
  额外产一个 aarch64 squashfs 镜像**。两个 job 各自发各自的 Release
  （`ci-<sha>` / `ci-sqfs-<sha>`）；`summarize` 仍只 `needs: build`，因为
  sqfs 走的是另一个 Release，与 proxy 清单无关。
  原 build_sqfs.yml 的 §0–§12 方法论文档随文件删除一并搬进本 workflow 头部。
- 原 `.github/workflows/build_sqfs.yml` **已删除**。
- 新增 **`build_zig_minimal.yml`**：只产 Zig 版 aarch64 白名单 squashfs 镜像。
  安装 Zig 0.17.0（官方 tarball，不用 snap —— 那会给最新 beta，而
  build.zig.zon 对 0.17.0 是硬下界）→ 校验白名单 → 交叉编译 →
  静态链接断言 → 同白名单跑单测 → 打包 sqfs → 发布。
  打包参数与 Go 版逐项一致（`-comp xz -b 1M -noappend -all-root`、
  源目录 `stage/openlist`、镜像内文件名 `openlist`、`chmod 755`、
  打包后断言 `-rwxr-xr-x root/root`），所以两个产物可直接互换。
- CI 侧踩到并修掉的一个假失败：`zig build -Dhelp` 不是合法选项，
  会让校验步骤自己触发失败；`zig build --help -Ddrivers=...` 才是对的
  （打包机实测三态：合法 → 0、非法 → 1、留空 → 0）。
- 两个 workflow 均通过 PyYAML 结构校验；`build_sqfs` 引用的 9 个输入全部
  已声明。

### 14.3 本轮验证结果

- 打包机：全量 `352/352 tests passed`，二进制 **1,183,352 B**；
  裁剪（`local,webdav,Quark,strm`）`352/352 tests passed`，**893,352 B**。
- 光猫 `/tmp/olz`：web setup 建管理员 → 登录 → `/api/admin/driver/names`
  返回 `["Local","WebDav","Quark","UC","Strm"]`，验证后零残留、端口释放。
- `tools/check_public_settings.py`：`go=46 zig=46 OK`。

---

## 15. 2026-10-15 第二轮：内置前端首装面板 + workflow 收尾

### 15.1 内置 shell 补上首装面板（用户指出的问题）

用户指出：`POST /api/public/init/setup` 普通用户在浏览器里根本发不出去。
核实后确认这是真的 —— `src/frontend.zig` 的 `BUILTIN_INDEX` 是个**静态占位页**，
既没有安装向导也没有登录框，用户只能上服务器敲 curl，对一台只连着光猫的机器
来说太远了。

已补：页面里加一个默认隐藏的 `#setup` 面板，加载时先打
`api/public/init_status`（public 路由，不需要令牌），只有 `initialized:false`
才亮出来；提交即 POST `api/public/init/setup`，成功后 `location.reload()`。
密码下限 `minlength="4"` 与后端一致（后端是 `<4` 拒绝）。

真机验证（光猫 `/tmp/olz`，走完整浏览器链路）：
```
=== shell contains the setup form ===  api/public/init/setup / id="setup" / 首次安装
=== init_status ===                    {"data":{"initialized":false}}
=== POST init/setup ===                {"code":200,...}
=== init_status again ===              {"data":{"initialized":true}}
```
新增回归测试 `the built-in shell carries a first-run setup panel` 钉住表单各要素。

顺带把账号这块的完整事实说清楚（Go 上游也如此）：
- **没有"注册账号"**：OpenList 是**单管理员**设计，`server/router.go` 的 public
  组只有 settings / init_status / init/setup，auth 组只有 login、login/hash、
  me —— 没有任何 register 端点。Zig 侧曾自造过一个 `/api/auth/register`，
  按"对齐 Go"已删除（`api.zig` 有注释记录）。
- **改 admin 密码**：只能 CLI，`openlist admin set NEW_PASSWORD` /
  `openlist admin random`。Zig 未实现 `/api/me/update` 与
  `/api/admin/user/update`（Go 有）。
- `admin set` 在**还没有任何管理员**时会报 `NoAdministrator` —— 首次只能靠
  web setup（现在浏览器里就能做）或 `OPENLIST_ADMIN_PASSWORD` 环境变量。

### 15.2 build_go_minimal.yml 收尾（用户要求）

- **`drivers` 默认值改为与 Zig 的 12 项一一对应**：
  `local,webdav,itvsh,aliyundrive_open,189,189pc,123,quark_uc,115,wopan,strm`
  （Go 侧 11 个目录 = Zig 侧 12 个注册项，`quarkuc` 一个文件出 `Quark`+`UC`）。
  之前的默认值 `local,alias,crypt,virtual,strm,url_tree,itvsh,115,139,
  quark_uc,webdav,ftp,smb,sftp` **缺了你实际在用的 5 个**
  （189/189pc/123/aliyundrive_open/wopan），按它构建会让那些存储启动时报
  `no driver named: xxx`。
  ⚠ 代价：`123` 是 AWS 系驱动，勾选会把 aws-sdk-go 拖回来，按本文件 §3/§11
  实测约 **+7.7 MiB** 裸二进制。若设备不用 123Pan，把它从名单里去掉即可。
- **UPX 全清**（用户要求）：删掉 `compress` 输入、matrix 里 6 个 upx 变体、
  build job 的 "Compress with UPX" 步骤、build_sqfs job 的 "Optional UPX"
  步骤，以及产物名/release notes 里的 `COMPRESS`。剩下的只是说明性文字
  （记录为什么不用：UPX 的 stub 会把整个解压体放进**匿名**内存，在只有
  128 MB 的 F4610U 上等于凭空多吃一份二进制大小）。
  校验：两个 workflow 均 PyYAML 通过，且 `build_go_minimal.yml` 里
  **没有任何活的 upx 引用**（只有注释）。

### 15.3 两个 workflow 的产物与裁剪方式（用户问）

| | build_go_minimal.yml | build_zig_minimal.yml |
|---|---|---|
| `build` job | 普通二进制 ×3 目标（windows-amd64、linux-amd64-nocgo、linux-arm64-nocgo）→ Release `ci-<sha>`，asset 名 `openlist_<target>` | **不产** |
| `build_sqfs` job | aarch64 squashfs → Release `ci-sqfs-<sha>`，asset 名 `openlist.sqfs_linux-arm64` | — |
| 唯一 job | — | aarch64 squashfs → Release `ci-zig-sqfs-<sha>`，asset 名 `openlist-zig.sqfs_<zig版本>_<drivers>` |
| `summarize` job | proxy 清单 + WebDAV + 邮件，只 `needs: build`（sqfs 走另一个 Release） | **不产** |

**怎么配置驱动裁剪**：
- Go 版：`workflow_dispatch` 的 `drivers` 输入，逗号/空格分隔，名字是**Go 驱动
  目录名**（`189`、`189pc`、`123`、`quark_uc`…）。留空或 `all` = 全量 87 个。
  另有 `strip_offline` / `strip_ffmpeg` / `db_backends` / `search_backends` /
  `strip_protocols` 几项精简开关（Zig 版没有 —— 那个实现里没有这些功能点）。
- Zig 版：`drivers` 输入，名字可以是**Go 驱动名**（`189Cloud`）也可以是 **Zig
  源文件名**（`cloud189`）。留空 = 全量 12 项。未知名字在编译前就以非零码失败
  并列出全部合法值。

**默认驱动清单**：两个都是上面那同一份 11 个 Go 目录 / 12 个 Zig 注册项，
一一对应，所以两边的镜像可以直接互换、不挑构建方式。
