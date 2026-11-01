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

## 5. SFTP 服务端（可用：五层已通，认证接真校验，三客户端互通通过）

2026-10-31 动手，分层落地。已完成的两层**零依赖、可纯单测**（不需要密钥、
不需要起服务、不需要真实客户端）：

| 文件 | 内容 | 测试 |
|---|---|---|
| `src/sftp/protocol.zig` | v3 线协议编解码：帧、`PacketType`/`Status`/`OpenFlags`/`AttrFlags`、`Attributes`、流式 `parse`、`writeStatus/Handle/Data/Attrs` | 16 |
| `src/sftp/session.zig` | 句柄表（上限 512、id 不复用、重复 close 不致命）、虚拟路径纯词法归一化（`..` 越根钳制而非报错） | 13 |
| `src/sftp/handler.zig` | 请求分发：`INIT`/`REALPATH`/`STAT`/`LSTAT`/`FSTAT`/`OPENDIR`/`READDIR`（64 条一页）/`MKDIR`/`RMDIR`/`REMOVE`/`RENAME`/`OPEN`(读写/续传)/`READ`（1 MiB 窗口缓存）/`WRITE`/`CLOSE`/`SETSTAT` | 18 |
| `src/sftp_wire.zig` | 生产接线：`Resolver` 包 `App.resolve`（含虚拟根列挂载点）、`Fetcher` 包 `client.zig` 的 Range 请求、`--sftp-plain` 裸 TCP 监听（仅 127.0.0.1、无认证）、`--sftp-ssh` SSH 监听 | — |
| `src/sftp/ssh.zig` | SSH-2 传输层：版本交换、KEXINIT、`curve25519-sha256`、`ssh-ed25519` host key、二进制包协议、`aes128-ctr`+`hmac-sha2-256`、NEWKEYS 密钥派生、双向 rekey（含 stash） | 14 |
| `src/sftp/channel.zig` | 连接层（RFC 4254）+ 认证（RFC 4252）+ SFTP 桥接：单 channel、`subsystem sftp`、窗口补给、`max_packet` 分片、服务端主动 rekey 触发 | 3 |
| `src/util/peeraddr.zig` | 对端 IP 提取（POSIX `getpeername`，**只取 IP 不带端口**；Windows 无对应 API ⇒ null） | 4 |
| `src/sftp.zig` | 模块入口，汇总四层 | — |
| `tools/sftp_probe.py` | 裸 SFTP 探针（不依赖 SSH / paramiko），端到端验证协议 → 分发 → 真实驱动 | — |
| `tools/sftp_ssh_e2e.py` | 走真 SSH 的端到端：认证闸门、大文件往返、rekey（双向）、断点续传 | — |
| `tools/sftp_interop.py` | 第三方客户端互通：PuTTY `psftp` / WinSCP / `rclone` 各跑一遍 ls/put/get/rm 并逐字节比对 | — |

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
* **重协商 + 第二个客户端实现**（2026-11-01，见 §60.35）：客户端主动 rekey
  已接（连续两次，之后 300 KiB `get` 仍逐字节一致）；PuTTY `pscp` 列目录 /
  下载 / 上传全部通过 —— 它暴露了一个 OpenSSH 测不出的收尾缺陷（只发 `EOF`
  就等服务端关，我们不回 `CLOSE` 就永远不退出）。单测 525 pass + 3 skip。
* **复核后的五项收尾**（2026-11-01，见 §60.37）：①失败计数按 IP 分桶（64 桶
  LRU，HTTP/SSH 仍共用同一份，换协议绕不过去）；②断点续传（不带 `trunc` 打开
  已存在文件时先把原内容拉进 temp 再接受 `WRITE`）；③`READ` 不再把「驱动没报
  size」当成空文件（`size_known` + 短读判 EOF）；④服务端主动 rekey
  （`sftp.rekey_mb`，默认 1024 MiB；KEX 期间对端继续发的包进 stash，NEWKEYS
  后补投）；⑤host key 落成 0600。单测 537 pass + 4 skip。
* **互通抓到一个收尾缺陷**（同日，见 §60.38）：psftp 连跑 15 次挂 6 次，报
  `Software caused connection abort` / `Remote side unexpectedly closed network
  connection`，而且**文件传完、rm 都成功了，就 quit 那一下报错**。根因是收到
  `CHANNEL_EOF` 后发完 `EOF`+`CLOSE` 就关 socket，对端回的 `CLOSE` 还没读走 ⇒
  Winsock 用 RST 收尾。改成 §5.3 的双向握手（等对端 CLOSE 再关）后 15/15 全过，
  pscp 这种「只发 EOF 就等我们关」的客户端也不受影响。单测 538 pass + 4 skip。
* **互通三客户端自动化**（同日）：`tools/sftp_interop.py` 把 PuTTY `psftp`、
  WinSCP、`rclone`（临时 `:sftp:` 远端，不写配置）三个第三方客户端串起来跑
  `ls`/`put`/`get`/`rm` 并逐字节比对 —— 512 KiB 往返全过；OpenSSH `sftp`
  因「没有 sshpass 就传不进口令」只能手工跑，脚本里明确报 SKIP 而不是假装通过。
  `--kib` 可调数据量，用来把「传输量」这个变量从一次失败里摘出去；
  **连跑才有意义**（上面那个收尾缺陷单跑一次是 60% 概率溜过去的）。
* **独立复核后的修复**（同日，见 §60.39 / `docs/REVIEW_2026-11-01-sftp.md`）：
  ①**WebDAV 完全不参与失败计数** ⇒ `/dav` 是整套限速的后门（`curl -u admin:猜`
  无限试），现按 Go `WebDAVAuth` 补上，且区分「没带凭据」（不计数）与「凭据错」
  （计数）；②已知大小时的**上游短读**被当成 EOF ⇒ 下载静默截断，改回 `FAILURE`；
  ③续传把「驱动不报大小」当成「空文件」⇒ 上传静默缺一块，改成明确拒绝；
  ④锁定期内继续尝试会续期（对齐 Go `Expire`）、成功登录不再新建桶；
  ⑤更正「上游用 `IP:端口`」的错误归因（FTP 带端口，HTTP 是纯 IP，上游 SFTP
  无 `LoginCache`）。单测 **550 pass + 4 skip**。

剩余：

1. **前端开关**：管理页「存储/设置」里没有 SFTP 入口，只能手改 `config.json`。
   **这一条在当前仓库里做不了**，缺的东西是具体的：①仓库没有前端产物
   （`public/dist/` 只有一个 README，`dist_dir` 默认空 ⇒ 服务端只发占位页），
   没有页面可加控件；②`setting/save` 写的是 `zig.*`，SFTP 读的是根上的
   `sftp.*`，不是同一张表，得先加映射；③就算存进去了也不会生效 —— 监听器是
   `accept` 死循环跑在 detached 线程里，没有 stop 句柄，运行时起停要先解决
   「怎么唤醒阻塞中的 accept」。等前端构建进发布物再做，见 §60.37 末尾。

> `--sftp-plain`（无认证、固定绑 `127.0.0.1`、启动打 WARN）**保留**：TODO 原
> 来说互通落地后就删，但它是 `tools/sftp_probe.py`（唯一零第三方依赖的探针）
> 的唯一入口，且只存在于 CLI、不在配置文件里，不存在「线上误开」的路径。
> 要删的话连探针一起删，说一声即可。

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
