# TODO — openlist-zig 待办清单

> 最后更新：2026-10-31（回退路径容量闸 + 1 GiB 分片直传真机验收，见
> `docs/STATUS.md` §58）。历史与事故记录一律在 `docs/STATUS.md`，这里只放
> **还没做的事**。

---

## 1. 驱动功能缺口（P1，每项都有 Go 参考实现）

| # | 驱动 | 缺口 | 位置 |
|---|---|---|---|
| 1 | webdav | `vendor=sharepoint` 分支 + odrvcookie（RtFa/FedAuth SOAP）整支未实现 | `webdav.zig:763`；Go `odrvcookie/fetch.go:49-140` |
| 2 | cloud189pc | `family_transfer` 转存全链路零实现（Go：建中转夹 → 改投家庭云 → `SaveFamilyFileToPersonCloud` → 删源 → 节流） | Go `driver.go:392-441`、`utils.go:1441-1511` |
| 3 | cloud189pc | `upload_method=old` 静默降级为 streamUpload；`rapid_upload` 旧秒传缺失 | Go `driver.go:374-389`；`cloud189pc.zig:2295` |
| 4 | cloud189pc | `generate_torrent`（上传后生成 `.cas.torrent`）未实现 | `cloud189pc.zig:165` |
| 5 | local | 缩略图整块：list 的 thumb URL、`?type=thumb` 生成 PNG、缓存目录、token_bucket 限速。schema 已标 `[未实现]` | `local.zig:362`、`792-796`；Go `driver.go:152-160`、`:236-266` |
| 6 | aliyundrive | `Other("video_preview")`（实况/预览播放信息）未实现 | Go `driver.go:269-291` |
| 7 | pan115 | OSS 分片的 **token 中期刷新**未移植（3 次重试已补；刷新 ticker 在 SDK 默认值里，不在 Go 树内） | `pan115.zig` |

## 2. 缺真实凭据（外部阻塞，不是代码问题）

- `123 Open`：开发者 ClientID/Secret 或 renewtoken。
- `QuarkOpen`：refresh_token + sign_key。
- `115 Open`：access/refresh_token。

三个变体是编译期可选注册（`opted()`），真机目前只到「注册表 + 表单 + 哑凭据
添加/删除闭环」。拿到凭据后按 `tools/driver_matrix.py --only "<驱动名>"` 挂真实
存储，补 list/下载/上传/删除矩阵（流程同 STATUS §36）。

`115 Cloud` / `WoPan` 依赖仓库外 SDK，同样只能真实 API 回归。

## 3. 边界内明确不做（不打算补）

- `PUT /api/fs/form`：全仓没有 multipart 解析器；前端默认走分片/Stream，只有
  用户手工把上传方式切到 "Form" 才会调它。
- `GET/POST /api/fs/archive/meta`：依赖未实现的 `/ad` `/ae` 归档下载端点，
  只做 meta 会返回一个必然 404 的 `raw_url`，属半套功能。

理由详见 `docs/STATUS.md` §45.3；功能边界的完整清单见 §22.1。

## 4. 暂缓（等用户信号）

`BaiduNetdisk` / `Onedrive` 未移植。Go 树里都有，备份配置里 `/baidu` 是在用的、
`/onedrive` 是 disabled 的。唯一重启信号：用户说「百度网盘也要」。

## 5. SFTP 服务端（进行中：五层已通，认证已接真校验）

2026-10-31 动手，分层落地。已完成的两层**零依赖、可纯单测**（不需要密钥、
不需要起服务、不需要真实客户端）：

| 文件 | 内容 | 测试 |
|---|---|---|
| `src/sftp/protocol.zig` | v3 线协议编解码：帧、`PacketType`/`Status`/`OpenFlags`/`AttrFlags`、`Attributes`、流式 `parse`、`writeStatus/Handle/Data/Attrs` | 16 |
| `src/sftp/session.zig` | 句柄表（上限 512、id 不复用、重复 close 不致命）、虚拟路径纯词法归一化（`..` 越根钳制而非报错） | 13 |
| `src/sftp/handler.zig` | 请求分发：`INIT`/`REALPATH`/`STAT`/`LSTAT`/`FSTAT`/`OPENDIR`/`READDIR`（64 条一页）/`MKDIR`/`RMDIR`/`REMOVE`/`RENAME`/`OPEN`(只读)/`READ`（1 MiB 窗口缓存）/`CLOSE`/`SETSTAT` | 13 |
| `src/sftp_wire.zig` | 生产接线：`Resolver` 包 `App.resolve`（含虚拟根列挂载点）、`Fetcher` 包 `client.zig` 的 Range 请求、`--sftp-plain` 裸 TCP 监听（仅 127.0.0.1、无认证）、`--sftp-ssh` SSH 监听 | — |
| `src/sftp/ssh.zig` | SSH-2 传输层：版本交换、KEXINIT、`curve25519-sha256`、`ssh-ed25519` host key、二进制包协议、`aes128-ctr`+`hmac-sha2-256`、NEWKEYS 密钥派生 | 7 |
| `src/sftp/channel.zig` | 连接层（RFC 4254）+ 认证（RFC 4252）+ SFTP 桥接：单 channel、`subsystem sftp`、窗口补给、`max_packet` 分片 | 1 |
| `src/sftp.zig` | 模块入口，汇总四层 | — |
| `tools/sftp_probe.py` | 裸 SFTP 探针（不依赖 SSH / paramiko），端到端验证协议 → 分发 → 真实驱动 | — |

`handler.zig` 用两个窄接口隔离依赖，所以分发逻辑能纯单测（内存驱动 + 内存
fetcher，不起服务、不联网）：`Resolver`（路径 → 驱动 + 相对路径）、`Fetcher`
（link → 一段字节）。

**已验证**：

* 裸 SFTP 链路（2026-10-31，local 驱动 + `--sftp-plain`）：INIT、REALPATH、
  OPENDIR/READDIR（根与子目录）、STAT、OPEN+READ（内容逐字节一致）、CLOSE、
  MKDIR/RMDIR、RENAME 全部通过（写路径当时未实现，现已补齐）。
* SSH 传输层（同日，`--sftp-ssh` + OpenSSH 10.3 客户端）：版本交换、算法协商
  （curve25519-sha256 / ssh-ed25519 / aes128-ctr / hmac-sha2-256）、**host key
  验签通过**、NEWKEYS、加密通道双向工作。
* **OpenSSH `sftp` 客户端端到端**（同日）：`pwd` / `ls /` / `ls /local` /
  `ls /local/sub` / `get`（两个文件，内容逐字节一致）/ `mkdir` / `rename`
  （往返）/ `rmdir` 全部通过；`put` 正确报
  `dest open "...": Operation unsupported`（写路径未实现，不静默）。
* **认证已接真校验**（同日）：`twoHashPwd` 比对 `admin_hash`，与 HTTP 登录
  **共用同一份失败计数**（换协议不能绕过限速）。实测：错口令被拒、对口令
  通过、连续 5 次失败后即使口令正确也被锁 5 分钟并打 WARN。
* **写路径已通**（同日）：`OPEN` 写模式在 `temp_dir` 建稀疏文件，`WRITE` 按
  offset pwrite，`CLOSE` 时整份 `put`。实测：29 B / 1 MiB 上传往返 MD5 一致；
  9 MiB 超 `zig.max_upload_mb`(8) 被拒且**磁盘上不留截断文件**、temp 零残留。
* **配置面已接**（同日）：`sftp.{enable,address,port,host_key}`，**默认关闭**；
  同时兼容 Go 的 `sftp.listen`（`":2022"` / `"0.0.0.0:2022"`）。实测三种启动
  方式：`address+port`、Go 的 `listen`、`enable=false` 不监听。
* **复核与修复**（同日，见 `docs/STATUS.md` §60.33）：修掉一处 P0（未认证即可
  开 channel —— RFC 4253 不要求先认证，`authenticated` 只写不读 ⇒ 谁都能读
  写全部挂载）、三处 P1（SFTP 启动失败拖垮 HTTP、`sftp.port` 恒压过 `listen`、
  `openForWrite` 的 fd/temp 泄漏），并把发送窗口从「不足时照发」改成「同步等
  `WINDOW_ADJUST`」。单测 520 pass + 3 skip。

剩余（按依赖顺序）：

1. **失败计数按 IP 分桶**：现在是**全局**计数（`std.Io.net.Stream` 不暴露对端
   地址），副作用是任何人都能把管理员账户锁 5 分钟、并顺带锁住 HTTP 登录。
   拿到 IP 后 key **必须用纯 IP 不带端口** —— 上游用 `IP:端口`，扫描器源端口
   每次都变，限速形同虚设（`docs/STATUS.md` §9）。
2. **断点续传**：`OPEN` 带 `write` 但没有 `trunc`、且目标已存在时明确回
   `op_unsupported`（要先下载现有内容到 temp 才能续写）。主流客户端上传都用
   `write|creat|trunc`，不受影响。
3. **互通**：OpenSSH `sftp` 已通过；WinSCP、FileZilla、`rclone lsd :sftp:`
   待测。落地后删掉 `--sftp-plain`（无认证端点不该长期存在）。
4. **前端开关**：管理页「存储/设置」里没有 SFTP 入口，目前只能手改
   `config.json`。等配置面稳定后再决定要不要暴露到 UI。
5. **客户端 rekey**：长传输后（OpenSSH 约 1 GB / 1 h）客户端会主动发
   `KEXINIT` 重协商，现在 `channel.dispatch` 只回 `UNIMPLEMENTED` ⇒ 连接随即
   断开。要支持得把 `ssh.kex` 接进消息循环，并且**沿用首次的 session_id**
   （RFC 4253 §7.2）。代码里已用 `TODO(rekey)` 标出。
6. **`READ` 依赖驱动上报的 size**：`details().size <= 0` 时句柄 size 归 0，
   `offset >= size` ⇒ 恒回 EOF，表现为「能列出来但读出来是空」。要支持得改成
   「size 未知时按 Range 请求的实际返回判断 EOF」。
7. **host key 文件权限**：`data/ssh_host_ed25519_key` 是 32 字节私钥 seed，目前
   按默认权限写出。应落成 0600（`0600` 在 Windows 上要显式设置 ACL）。

密码学**不需要任何 C 库**（2026-10-31 核对 `lib/std/crypto/`）：
`std.crypto.dh.X25519`（KEX）、`25519/ed25519.zig`（host key）、
`crypto.sign.ecdsa`（P-256 host key）、`crypto.ff`（RSA，
`Modulus.powWithEncodedExponent`；smart-iot 的 `core/net/rsa.zig` 已用 128 行纯
Zig 实证）、`aes*` / `chacha20` / `hmac` / `sha2` 齐全。**不引 libssh / BearSSL**：
前者要 OpenSSL 或 mbedTLS 静态链（+1.2~3 MB），后者的 TLS 服务端引擎与 SSH
无关，唯一能替的 RSA 已被 `std.crypto.ff` 覆盖。

⚠ 实现认证时失败计数 key **必须用纯 IP、不带端口** —— 上游 Go 版用 `IP:端口`，
扫描器每次源端口都不同，限速形同虚设（见 `docs/STATUS.md` §9）。

## 6. 导入工具用法

```bash
python tools/import_go_config.py <backup.json> <out_config.json> \
    [--go-config <go config.json>] [--port 15399] [--temp-dir /tmp/olz/temp] \
    [--only id,id,...] [--include-disabled]
```

- **驱动名原样搬**（Zig `factory.key` 逐字节 == Go `Config.Name`）。
- **迁移 settings**：site_title/logo/favicon/main_color/customize_head/body/sign_all/link_expiration → `zig.*`。
- **迁移 admin**：username + permission。**密码哈希迁移不了** —— Go 的
  `PwdHash`/`Salt`/`PwdTS` 都是 `json:"-"`，导出里根本没有；首次启动要用
  `openlist admin set <密码>` 或 setup 页面设。
- **明确报告**跳过的驱动（含理由）与未实现的 setting。
- ⚠ 未传 `--go-config` 时 `jwt_secret` 为空（重启会重新生成）、`cdn` 为空
  （前端走 CDN，cdn 空了就是占位页）。

## 7. 环境速查

**测试机（光猫，SSH `192.168.1.1:10022`，root，口令在 `~/.olz_root_pwd`）**

- 密钥已授权，`ssh -p 10022 root@192.168.1.1` 免密可用。
- **`tools/deploy_device.py` 在本机跑不起来**：它依赖 paramiko，而本机 pip
  无源（`No matching distribution found`）。部署走 `scp` + `ssh` 手工三步：
  `scp` 二进制到 `/tmp/olz/openlist` → `chmod 755` → `cd /tmp/olz &&
  (nohup ./openlist server --config /tmp/olz/cfg.json --port 15399 >run.log
  2>&1 </dev/null &)`。
- 测试实例：`/tmp/olz`（tmpfs，重启即失），端口 15399，日志 `/tmp/olz/run.log`。
- **生产实例**：`/opt/armbian/bin/openlist/openlist server --config
  /opt/armbian/bin/openlist/config.zig.json`，端口 15244。**绝不能碰。**
- 跑真机回归要一份隔离配置：拷生产 `config.zig.json`，改 `http_port` 与
  `temp_dir`，**并把 115 / WoPan / 迅雷 这类一次性 token 的存储 `disabled`
  掉** —— 两个实例并发 refresh 会互相消费令牌。

**本机**

- Zig 0.17.0：`C:\Program Files\zig-x86_64-windows-0.17.0\zig.exe`，产物与
  打包机逐字节相同。跑法：

  ```bash
  cd zig-src
  python tools/ziglib_patch.py "C:/Program Files/zig-x86_64-windows-0.17.0/lib" C:/zigcache/olz-ziglib
  ZIG_LIB_DIR=C:/zigcache/olz-ziglib ZIG_GLOBAL_CACHE_DIR=C:/zigcache/olz \
  ZIG_LOCAL_CACHE_DIR=C:/zigcache/olz "C:/Program Files/zig-x86_64-windows-0.17.0/zig.exe" build test --summary all
  ```

  ⚠ 必须用 `ZIG_LIB_DIR`（`--zig-lib-dir` 不是 `zig build` 的参数）。
  ⚠ `zig build` 会吞掉 "All N tests passed."，判成功看 `--summary all` 里的
  `test success`。
- 交叉编译：`... build -Dtarget=aarch64-linux-musl -Doptimize=small`，产物
  `zig-out/bin/openlist`。
- 分片上传真机验收：`tools/multipart_upload.py`（用法见模块头；Git Bash 下
  要给 `--path` 加 `MSYS_NO_PATHCONV=1`）。
- 前端自动化：`playwright-core` + 系统 Chrome
  （`C:/Program Files/Google/Chrome/Application/chrome.exe`），
  `NODE_PATH=<workspace>/node_modules node <script>.js`。
  ⚠ 别用 agent-browser（下载 Chromium 必失败）。
  ⚠ 点按钮必须按文字/role 定位 —— 登录页有「清除」和「登录」两个按钮。
- UI 回归：`NODE_PATH=<workspace>/node_modules node tools/ui_smoke.js`
  （`OLZ_URL` / `OLZ_USER` / `OLZ_PASS` 可覆盖）。

## 8. 铁律（违反会出事）

1. **真机测试只在 `/tmp/olz`**，绝不碰 `/opt/armbian/bin/openlist` 与生产的
   `config.zig.json`。
2. **杀进程只按 pidfile / `--port <n>`**，绝不用命令行子串匹配 —— 生产与测试
   命令行都含 "openlist server"。
3. **驱动名铁律**：`factory.key` 必须逐字节等于 Go 的 `driver.Config.Name`。
4. **加新 API 端点要同时改 `handle()` 的前缀白名单**（`src/api.zig`），只往
   `handleAuthed` 里加分支不够 —— `/api/me/update` 就是这样 404 的。
5. **核心算法一律对齐 Go，不得自创**（密码哈希、签名、JWT claim、时间格式）。
6. **上游唯一事实来源 = 本地 Go 树**（`drivers/<name>/`），不要去 GitHub 拉；
   `itvsh` 是用户私有驱动，只存在于本地树。
7. **catch 分支里的 `try` 要检查会不会跳过配对 unlock**（会 → 死锁）。
8. **`/api/*` 未注册路径返回真实 501 JSON**（不是 200+HTML）；要真实状态码时
   不能直接用 `res.jsonError`（它恒写 200）—— 先 `jsonError` 再覆盖
   `res.status`，或手写信封。
