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

## 5. 导入工具用法

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

## 6. 环境速查

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

## 7. 铁律（违反会出事）

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
