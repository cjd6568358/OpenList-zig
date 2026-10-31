# openlist-zig

用 Zig 重写的 OpenList 兼容服务 —— 目标是把一个 OpenList 兼容的服务塞进
中兴 F4610U 光猫（aarch64 / musl / squashfs）的极小空间里。

**12 个注册项 / 11 个驱动实现，已全部真机验证（12/12）。** 驱动集已于 2026-10-12 更换为
「正确变体」：`123Pan`（用户名+密码）、`Quark`+`UC`（Cookie）、`115 Cloud`（Cookie）取代
原 `123 Open`/`QuarkOpen`/`115 Open`（后三者代码保留但不再注册）。
`115 Cloud` 的上传链是协议最重的部分（P-224 ECDH `ec115` + RSA/XOR `m115` + OSS），
2026-10-12 补齐；**2026-10-13 晚加做联通沃云盘 `WoPan`**（不在原 9 清单内）。
当前状态与最新结论见 [`docs/STATUS.md`](docs/STATUS.md) 顶部的「当前基线」表。

功能边界：
远程 Range 仍经现有 HTTP client 缓冲响应；归档暂只支持本地 ZIP/TAR 列表，不支持远程归档、解压下载、ZIP64/加密。上传进度回调已全线接通（所有驱动按 Go `model.UpdateProgress` 报 0–100 百分比），并已通过 `PUT /api/fs/put` 暴露给前端。SFTP SSH 服务端**明确暂缓**（2026-10-11 决策 defer，备选 SSH 实现见 [`docs/STATUS.md`](docs/STATUS.md) §9，恢复时从该处继续）。

Zig **0.17.0** 下 **411/411** 单元测试通过（打包机）；真机 e2e（13 挂载点）
**464 通过 / 0 失败 / 1 跳过**（跳过 = 坚果云根目录 403 服务商规则），见
[`docs/STATUS.md`](docs/STATUS.md) §3/§45；
交叉编译出的 aarch64 静态二进制 **1,260,816 B**（Go 版全量驱动为 45,154,464 B，裸小约 36 倍）。
本机端到端既有冒烟覆盖登录 / 文件操作 /
12 MiB 上传下载 / 并发 / 路径穿越防护 / 前端三种加载模式 / WebDAV 服务端；真机
e2e 覆盖 13 挂载点全操作（见 [`docs/STATUS.md`](docs/STATUS.md) §3）。

当前注册的 **12 个驱动**（对应用户真实配置与需求；与 `build_sqfs.yml` 默认清单的关系
及逐驱动与上游对比见 [`docs/STATUS.md`](docs/STATUS.md) §2、逐条差异见
[`docs/AUDIT_2026-10-18-drivers.md`](docs/AUDIT_2026-10-18-drivers.md)）：

| 驱动 | 注册名 | xz 边际（2026-10-13 快照） | 备注 |
|---|---|---|---|
| `189pc`（家庭云） | `189CloudPC` | 24,268 B | 最大（5.4%）。RSA + AES-CBC + HMAC 签名；move/delete 走批处理签名 |
| `pan115` | `115 Cloud` | 23,388 B | T2 新增：Cookie + `ec115` P-224 ECDH 上传链 + `m115` RSA/XOR + 闪传/OSS |
| `itvsh` | `Itvsh` | 15,944 B | 协议最复杂：登录链 + 分块并发；**私有驱动**，上游没有 |
| `aliyundrive_open` | `AliyundriveOpen` | 12,560 B | 两阶段秒传（`PreHashMatched`） |
| `pan123` | `123Pan` | 12,536 B | T2 新增：用户名+密码 + CRC32 签名 + 16 MiB 分片 |
| `189`（个人云） | `189Cloud` | 11,088 B | RSA 表单登录 + cookie 会话 |
| `quarkuc` | `Quark` | 9,900 B | T2 新增：Cookie + __puus 滚动 + OSS 分片 |
| `quarkuc`（同一实现） | `UC` | —（与 Quark 同实现，边际不单独计） | OnlyProxy 变体，2026-10-17 真机全矩阵通过 |
| `webdav`（客户端） | `WebDav` | 9,548 B | 含迷你 XML 解析器 |
| `local` | `Local` | 5,696 B | |
| `wopan`（联通沃云盘） | `WoPan` | — | 2026-10-13 晚新增：dispatcher + AES-128-CBC + MD5 签名；未重测边际 |
| `strm`（其他挂载→.strm） | `Strm` | — | 虚拟驱动，经 fs bridge 回调同实例其他挂载；未重测边际 |

> 边际体积按 **2026-10-13 上午**（T2 三驱动补齐后、审计 P1/P2 修复前）的注册表重测
> （`dist/driver_size.log`）：全量基线 **1,071,776 B** 裸 / **450,416 B** xz，九驱动合计
> **+296,096 B** 裸 / **+124,928 B** xz，框架地板 775,680 B 裸 / 325,488 B xz。
> 此后每轮修复都把基线往上推（当前 1,260,816 B），**本表数字是 2026-10-13 快照、
> 未随每轮刷新**；要看当前产物大小看顶部那句。
> 三个 `_open` 变体（123 Open / QuarkOpen / 115 Open）已下线未注册，
> 其历史边际（9,868 / 9,312 / 16,188 B）属 `_open` 时代的测量。

## 这个仓库里有什么

```
src/
  main.zig           入口：参数、配置、挂载、监听、信号、`admin` 子命令
  rt.zig             进程级 Io 与 gpa（0.17 把 fs/net 搬进了 std.Io）
  config.zig         config.json（OpenList 兼容子集 + 写回）
  log.zig            分级日志
  model.zig          Obj / File / Link / Storage / Source
  driver.zig         驱动 vtable + 注册表 + 持久化钩子
  http.zig           手写 HTTP/1.1 服务端（std.Io.net）
  client.zig         上游 HTTP 客户端（std.http 的唯一接触面）
  frontend.zig       前端服务：CDN / dist_dir / 内置占位页三选一
  cookiejar.zig      cookie jar（Go http.Cookie 兼容持久化）
  api.zig            /api/* 路由、挂载解析、JWT 鉴权、静态资源与 SPA 兜底
  webdav.zig         WebDAV **服务端**（/dav：PROPFIND/MKCOL/GET/PUT/COPY/MOVE…）
  archive.zig        本地 ZIP/TAR 只读浏览（读中央目录，不整包进内存）
  util/
    buf.zig          Buf / List（绕开 std.ArrayList 的版本漂移）
    json.zig         手写 JSON
    url.zig          URL 解析、percent 编码、query 构建
    aes.zig          AES-ECB/CBC + PKCS7 + hex
    xml.zig          WebDAV PROPFIND 用的迷你 XML 解析器
    hash.zig         MD5/SHA1/SHA256、HMAC-SHA1、base64、流式 hasher
    rsa.zig          RSA PKCS#1 v1.5 加密 + PEM/SPKI 解析（189 / 189pc 用）
    ec115.zig        115 上传口令：P-224 ECDH + EncodeToken + AES-CBC/LZ4
    m115.zig         115 下载口令：RSA-1024 裸模数 + 多层异或
    time.zig         日历算术、RFC3339 / CN 时间解析、两种固定格式输出
    mime.zig         扩展名 → MIME（固定表；Go 在 Linux 上读 /etc/mime.types）
    random.zig       Go `random.Token()/String()` 同形生成（token / 首启口令）
  drivers/
    local.zig        本地存储
    webdav.zig       WebDAV 客户端
    itvsh.zig        Itvsh（协议最复杂的一个）
    aliyundrive.zig  阿里云盘开放平台
    cloud189.zig     天翼云盘个人版
    cloud189pc.zig   天翼云盘 PC 端 / 家庭云
    pan123.zig       123 网盘（用户名+密码版，T2 新增）
    quarkuc.zig      夸克 / UC 网盘（Cookie 版，T2 新增）
    pan115.zig       115 网盘（Cookie 版，T2 新增：ec115 P-224 ECDH + OSS 上传链）
    wopan.zig        联通沃云盘（2026-10-13 晚新增）
    strm.zig         STRM 虚拟驱动（映射同实例其他挂载）
    123open.zig      123 开放平台（已下线，代码保留）
    quark.zig        夸克开放平台（已下线，代码保留）
    115open.zig      115 开放平台（已下线，代码保留）
  tests.zig          测试聚合入口
tools/
  build_remote.py       **唯一交付构建路径**：打包机 10.0.0.4 上 test + 交叉编译
  deploy_device.py      部署到光猫测试实例（/tmp/olz，pidfile/端口隔离）
  e2e_test.py           端到端全操作测试（Local 写 + 可选 --write-cloud）
  ui_smoke.js           Playwright UI 冒烟（登录 / 列表 / 管理页）
  import_go_config.py   Go 备份 → Zig 配置（无损迁移）
  merge_import.py       备份存储增量合并进现役配置
  size.py / driver_size.py   裸体积 + xz 体积 / 逐驱动边际体积
  ziglib_patch.py       给 std TLS 打 ECDSA 套件补丁（quark 服务器需要）
docs/
  STATUS.md             当前状态 + 编年日志（先看顶部「当前基线」）
  AUDIT_2026-10-18-drivers.md  驱动维度对账（权威，逐条落地状态）
  MODULAR_DRIVERS.md    .so 运行时插件可行性调研（结论：用编译期白名单）
  regression/           真机 e2e 日志存档
TODO.md                 待办（权威，仓库根目录）
```

> 更早的 6 份审计（2026-10-11 台账/摘要、10-17 v1/v2、REVIEW v1/v2、DS 复核）
> 已于 2026-10-18 清理，结论已并入 STATUS §28–§46；需要原文用
> `git show 7356589e:<path>` 取回。

## 构建

> **规则：交付产物一律走打包机 `10.0.0.4`（工作目录 `/tmp`）。**
> `tools/build_remote.py` 封装了「打包源码 → 打包机 `zig build test` →
> 交叉编译（默认 `aarch64-linux-musl`，`-lc -fstrip`）→ 校验 ELF → 取回
> `dist/openlist-<arch>`」全流程。判成功看 `--summary all` 里的 `test success`
> —— `zig build` 会吞掉 "All tests passed"，末尾还可能打一条误导性的
> `failed command`（退出码实为 0）。本机只负责读源码、写代码；**本机产物只能
> 自测，不能当交付**。
>
> 单测始终在打包机**原生**（x86_64）跑一轮，两个目标架构共用同一批用例。

```sh
python tools/build_remote.py                                      # aarch64（光猫）
python tools/build_remote.py --target x86_64-linux-musl           # x86_64 服务器
python tools/build_remote.py --drivers "local,webdav,quark,strm"  # 白名单
```

产物名随架构走：`dist/openlist-aarch64` / `dist/openlist-x86_64`（`dist/` 不入库，
现役 aarch64 二进制留档在 `D:/workspace/server/armbian/bin/openlist/openlist`）。

**Zig 版本：0.17.0**（0.15 把 `std.fs`/`std.net` 搬进 `std.Io`，0.16 搬完，
0.17 又改了入口签名 `main(std.process.Init)` 与优化档位 `std.lang.Optimize`）。
PyPI 的 `ziglang` 最高只到 0.16，**没有 0.17 的 wheel**；打包机上用的是
`/root/.cache/zig/zig`，本机不保留工具链。

> **注意：单元测试全绿不等于能编出二进制。** Zig 按函数惰性分析，
> 测试没触发的代码路径不会实例化 —— 实测有 4 个 `std.http` 相关的错误只有
> 交叉编译才暴露。流程必须是 test → build，两个都过才算数（`build_remote.py`
> 两段都跑）。

首次启动会在 `data/config.json`（或 `--config` 指定的路径）生成默认配置、
一个随机 `jwt_secret` 和一个随机 `zig.token`（CLI 认证 + 下载签名共用）。
然后：

```sh
# 创建管理员（仅首次可用；Go 的官方途径，**没有** /api/auth/register）
curl -s -X POST localhost:5244/api/public/init/setup \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"changeme"}'

# 拿 token（前端走 /api/auth/login/hash，命令行用明文这个）
TOKEN=$(curl -s -X POST localhost:5244/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"changeme"}' | sed 's/.*"token":"\([^"]*\)".*/\1/')

curl -s -X POST localhost:5244/api/fs/list \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"path":"/"}'
```

## 前端

`/`、`/@manage/*`、`/manifest.json` 和 `/assets|images|streamer|static/*` 由
`frontend.zig` 提供，逻辑照抄 OpenList 的 `server/static/`。三种模式：

| 条件 | 行为 |
|---|---|
| `cdn` 为空、`dist_dir` 为空 | 内置占位页（本项目**不**把前端编进二进制） |
| `dist_dir` 非空 | 从该目录读 `index.html` 并服务四个资源前缀，`Cache-Control: max-age=15552000` |
| `cdn` 非空 | 启动时拉 `{cdn}/index.html`，四个资源前缀 302 到 CDN |

`cdn` 里的 `$version` 会替换成 `web_version` 去掉前导 `v`（`v4.2.6` → `4.2.6`），
这是原版 `build.sh` 把前端 release tag 喂进 CDN 模板的方式。

**推荐做法**：下载官方 lite 前端（约 2.9 MB，完整版约 20 MB）解压到
`data/dist`，然后 `"dist_dir": "data/dist"`。这样既有完整界面，二进制又不受影响。

```json
{ "dist_dir": "data/dist" }
```

## 配置

直接读 OpenList 的 `config.json`。未知字段原样保留，`storages[].addition`
仍然是 JSON **字符串**（Go 版就是这么存的），所以两种构建可以互相迁移。
Zig 特有的东西放在 `zig` 块里，Go 版会忽略它：

```json
{
  "scheme": { "address": "0.0.0.0", "http_port": 5244 },
  "site_url": "",
  "cdn": "",
  "dist_dir": "data/dist",
  "storages": [
    { "id": 1, "mount_path": "/nas", "driver": "Itvsh",
      "addition": "{\"mobile\":\"138...\",\"password\":\"...\"}",
      "status": "work" }
  ],
  "zig": {
    "ca_bundle": "data/ca.pem",
    "http_timeout": 60,
    "web_version": "rolling",
    "site_title": "OpenList (zig)",
    "main_color": "#1890ff",
    "admin_user": "admin",
    "admin_password_hash": "..."
  }
}
```

`site_url` / `cdn` / `dist_dir` 是原版的键；`web_version` 及之后的展示类设置
原版存在数据库里（本工程没有数据库），所以挪到了 `zig` 块。

## 已实现 / 未实现

**已实现**：配置加载与写回、挂载点解析（最长前缀 + 段边界）、JWT 鉴权、
`/api/fs/{list,get,dirs,mkdir,rename,move,copy,remove,put}`、本地与代理下载（本地支持单 Range 流式，代理转发 Range）、
本地 ZIP/TAR 归档目录列表（`/api/fs/archive/list`）、**驱动层上传进度 callback 全线接通并已由 `PUT /api/fs/put` 暴露给前端**、
**分片上传**（`/api/fs/multipart/{init,chunk,complete,status,abort}`：实现了 `mp_*` 槽位的驱动
—— 目前是 189pc —— 走**直传、本地零落盘**；其余驱动回退到 `temp_dir` 稀疏 spool 文件）、
设置接口（`/api/admin/setting/{list,get,default,save,delete,reset_token}`，仅 config-backed 项）、
**存储管理面全量 CRUD**（`/api/admin/storage/{list,get,create,update,delete,enable,disable,load_all}`，
落盘回 config.json + 挂载热更新，2026-10-15 补齐）、
**配置导出/导入**（`/api/admin/config/{export,import}`，2026-10-17）、
**驱动表单元数据**（`/api/admin/driver/{list,names,info}`，Go `driver.Info` 形状）、
`/api/me/update`（改用户名/密码）、`/api/auth/logout`、
任务中心空的 undone/done 列表、cookie 持久化、itvsh 完整协议（登录链 / 列表 / 上传分块并发 / 可回滚收尾 / 会话自愈）、
**前端服务**（CDN / `dist_dir` / 内置占位页，含占位符替换与 PWA manifest）、
**WebDAV 服务端**（`/dav`：PROPFIND/MKCOL/GET/PUT/DELETE/COPY/MOVE，Windows 资源管理器可挂载）。

**已冒烟验证**：CLI、启动加载、
注册/登录/重启后登录、目录列举、`mkdir`/`rename`/`move`/`remove`、
4 KiB 与 12 MiB 上传下载逐字节一致、12 MiB 落盘 spool 路径、20 并发、
未授权 401、路径穿越沙箱、挂载段边界（`/local2` 不匹配 `/local`）、
前端三种模式与全部路由（含 302 跟随到 CDN）。

**已真机验证**（2026-10-18，`tools/e2e_test.py --write-cloud`，详见 [`docs/STATUS.md`](docs/STATUS.md) §3/§44/§45）：
**13 个挂载点 / 12 个注册驱动全覆盖，464 通过 / 0 失败 / 1 跳过**（跳过 = 坚果云根目录
403 服务商规则，需 WEB 手动删）—— 列出/详情/下载/Range/sign（含篡改 401）/条件请求
（304/412/If-Range）/WebDAV 全套（PROPFIND 207、PUT 201+Etag、MOVE/COPY、OPTIONS Allow）/
写操作（mkdir/上传/重命名/移动/复制/删除）/边界与稳定性（路径穿越、信封、并发）。

**分片上传真机验收**（2026-10-31，`tools/multipart_upload.py`，详见 [`docs/STATUS.md`](docs/STATUS.md) §58）：
1 GiB 直传 `/ecloud_self` 成功（103 片 × 10 MiB，complete 后 `size` 一致、首尾各 1 MiB
与本地数据 MD5 一致；进程 RSS 峰值 23.2 MB，设备 `/tmp` 占用全程 5.6 MB）；
回退路径 200 MiB 被 `zig.max_upload_mb` 以 413 拒掉，10 MiB 正常放行。

**未实现或仅部分实现**（见 [`docs/STATUS.md`](docs/STATUS.md) §9/§22/§45.3）：
数据库与多用户体系、搜索、分享链接、SSO/2FA/LDAP/WebAuthn、后台任务/离线下载/torrent、
归档**解压与下载**（`/ad` `/ae`）、远程归档浏览（本地 ZIP/TAR 列表已支持）、
远程 Range 的真正响应流式（当前缓冲）、任务中心操作接口、`fs/form`（multipart）、
`fs/archive/meta`（依赖未实现的 `/ae`）。
**SFTP SSH 服务端：明确暂缓（defer）**，非本轮目标；备选 SSH 实现分析见 [`docs/STATUS.md`](docs/STATUS.md) §9。

## 上传上限

两条通道的限制不一样，别混：

- `PUT /api/fs/put` 与 WebDAV `PUT`：受 `zig.max_upload_mb`（默认 **64 MiB**）约束，
  超限回 **413 JSON**（中文 message）。原因是请求体超过 16 MiB 会整份落进
  `temp_dir`，而光猫上那是 tmpfs（220 MB，占 RAM）—— 放行更大的上传只会把进程
  OOM 掉或 ENOSPC 掐断连接。
- `/api/fs/multipart/*`（网页端 >10 MiB 的文件默认走它）：
  - 驱动实现了 `mp_*` 槽位（目前 **189pc**）⇒ **直传**，分片直接推给上游会话，
    本地零落盘，**大小只受上游配额限制**；
  - 其余驱动 ⇒ 回退到 `temp_dir` 的稀疏 spool 文件，落盘量 = 整份文件，因此
    **同样受 `zig.max_upload_mb` 约束**（`init` 阶段就回 413，不会等到写满盘）。

把 `temp_dir` 指到大容量存储后可以调高 `zig.max_upload_mb`；设 0 恢复 8 GiB 硬上限。

## 已知平台差异

`std.Io.Dir.statFile` 在 **Windows 上对目录返回 `error.IsDir`**（把目录当文件打开
需要 `FILE_FLAG_BACKUP_SEMANTICS`，std 不传）。`local` 驱动因此做了回退：`statFile`
失败时用 `entry.kind`（Windows 上它是准的），`details` 用 `openDir` 探一次。
Linux 目标上不会触发，但回归测试会覆盖。

`std.posix.setsockopt` 在 Windows 上是 `@compileError`（std 要求用 `std.Io`），
所以 `http.zig` 的读写超时是 `comptime` 跳过 Windows 分支 —— 该超时只在
Linux 目标上生效。

## 许可

与 OpenList 一致。

> AI生成