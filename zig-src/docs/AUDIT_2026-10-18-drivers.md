# openlist-zig 驱动模块全量对账（2026-10-18，按驱动维度）

> 对账对象：Go 上游 `drivers/`（本仓库 Go 树 = 唯一事实来源）↔ Zig 移植
> `zig-src/src/drivers/*.zig`。方法：逐驱动读码比对，每条结论附 `go 文件:行号` /
> `zig 文件:行号`；高危项已由主审二次复核（进度回调、size=0、Content-Type、
> Referer、partNumberEnd、appver、psToken 均落到行号）。
> 分类沿用 §39.2 三分法：**A** = 语言/框架必须差异；**B** = Zig 自主决策；
> **C** = 疑似未对齐/未完成。itvsh 已完成专项对账（STATUS §39.2），本文不重复。
> 真机验证口径：STATUS §36B.5「12/12 驱动覆盖收官」+ §41 e2e 全绿。

---

## 1. 结论总表

| 驱动（Zig 文件） | Go 对应 | A | B | C | 一句话结论 |
|---|---|---|---|---|---|
| local.zig | drivers/local | 6 | 8 | 10 | **1 个真 bug**（进度传字节）；缩略图整块缺；其余为加固/等价 |
| webdav.zig | drivers/webdav | 3 | 14 | 6 | digest 三处修正属修正 Go；**SharePoint 分支未实现**（已知缺口） |
| strm.zig | drivers/strm | 6 | 6 | 6 | 字段级全对齐；Version schema 默认值自相矛盾；反代 URL 推断弱 |
| aliyundrive.zig | drivers/aliyundrive_open | 6 | 10 | 6 | 协议高度对齐；Link.Expiration 无承载字段；Other(video_preview) 缺 |
| cloud189.zig | drivers/189 | 6 | 7 | 5 | **1 个真 bug**（fs/get size 恒 0）；torrent 链 Go 侧亦死代码 |
| cloud189pc.zig | drivers/189pc | 6 | 11 | 11 | **family_transfer / rapid_upload / torrent 三大块零实现**；分片无重试 |
| pan123.zig | drivers/123 | 5 | 10 | 10 | 自签上传分支分片策略与 Go s3manager 不同（串行、16MiB）；err_detail 未接 |
| quarkuc.zig | drivers/quark_uc | 7 | 6 | 7 | err_detail 全链路已接；upCommit Referer 未随变体收窄 |
| pan115.zig | drivers/115 | 5 | 7 | 10 | **动态 appver 拉取未移植**；OSS 分片无重试/无 token 中期刷新 |
| wopan.zig | drivers/wopan | 5 | 3 | 8 | psToken 线上发字面量 "undefined"（实测通过，疑镜像 web 前端） |
| itvsh.zig | drivers/itvsh（私有） | 8 | 5 | 4 | 已专项对账（STATUS §39.2），协议逐字一致 |

合计约 **A 54 / B 71 / C 74** 条差异记录，其中**确认的真 bug 2 个**、**P1 功能缺口 12 项**、
待确认 4 项（见 §4）。驱动名 12/12 逐字节对齐、操作集 NotSupport 约定 12/12 一致
（§26.1 复检仍然成立）。

## 2. 全局架构差异（所有驱动 A 类差异的共同根因）

读任何具体差异前必须先接受这五条，否则会把框架必然差异误判成 bug：

1. **`model.Obj` 无 ID 字段**（Go 有）：Zig 驱动按 path-only 工作，aliyun / 189 /
   189pc / wopan 的写操作前需 `resolve()` 逐段列目录反查 file_id
   （如 aliyundrive.zig:821-842）⇒ 每次操作多 N 次 list，Go 直接用传入 Obj.ID。
2. **Zig error 无 payload**：Go 的 `fmt.Errorf("%s:%s", code, message)` 类人类
   可读消息在 Zig 侧只进日志；补偿机制是 `driver.Ctx.err_detail`
   （driver.zig:40-67）。**目前只有 quarkuc / quark / itvsh / pan115 四个驱动接入**，
   cloud189 / cloud189pc / aliyundrive / pan123 / webdav / local / wopan / strm
   均未接 ⇒ 这些驱动的上游错误用户只能看到泛化 message。
3. **`model.Link` 无 `Expiration` / `Concurrency` / `PartSize` 字段**：aliyun 的
   1 分钟过期重取语义（drivers/aliyundrive_open/driver.go:121-124）、quark 的
   Concurrency:3/PartSize:10MB（drivers/quark_uc/util.go:134-135）无承载处。
4. **写操作 vtable 返回 `void`**：Go 的 `PutResult`/`MkdirResult`/`MoveResult`/
   `RenameResult`（返回新 Obj）语义丢失，调用方拿不到新建项的 file_id。
5. **无 ctx 取消传播**：Go 上传循环里的 `utils.IsCanceled(ctx)`（如
   drivers/123/upload.go:108-120、drivers/aliyundrive_open/upload.go:227）在 Zig
   各上传驱动均无对应 ⇒ 客户端断连后上传仍跑到上游超时。

另外 Zig 未实现的 Go 可选接口（全驱动共通）：`Other`（aliyun video_preview）、
`PutURL`（离线下载）、`ArchiveReader`/`ArchiveGetter`、`DirectUploader`、
`InitReference`（引用驱动共享登录态）、`LinkCacheModeResolver`、`GetRooter`。
其中 aliyun 的 `Other("video_preview")` 是唯一有真实用户价值的（§4 清单）。

---

## 3. 逐驱动对账明细

### 3.1 local（drivers/local ↔ local.zig）

**A 类**：FileInfoToObj/Get 填 `Ctime`（driver.go:171-177、214-220）→ Zig
`created` 字段存在但恒 0（local.zig:301-307、337-342；model.zig:76,97），前端
创建时间列恒空；GetDetails 用 statfs（driver.go:437-445）→ statvfs extern、
非 Linux 返 0（local.zig:601-648）；Link 的 SyncClosers/RangeReader →
local_path 层（:372-376）。

**B 类（自主决策，均合理）**：符号链接默认拒（新增 follow_symlinks，
:36-38、224-246，Go 透明跟随 util.go:30-47）；put 改临时文件+rename+fsync
（:549-599，Go 直写 driver.go:409-435）；copy 走字节复制（Go 不支持时
NotImplement 交任务系统，util.go:515-521）；跨挂载 move 回退复制+删除
（:472-480）；根目录 move/copy 一律拒（Go 允许，driver.go:290-296）。

**C 类（真缺口）**：

| # | Go 行为 | Zig 现状 | 定级 |
|---|---|---|---|
| C1 | 进度回调契约 0–100 百分比（driver.zig:70-78，其余 8 驱动全部传 pct） | **`cb(ctx.progress_userdata, off)` 传累计字节数**（local.zig:585） | **P0 真 bug**：上传进度条溢出（1GB 文件=1073741824%） |
| C2 | put 后 `os.Chtimes(ModTime)`（driver.go:425-428） | 无 mtime 回写（local.zig:549-599） | P1：上传文件 mtime=服务器时间 |
| C3 | Init 遇非法 mkdir_perm 启动失败（driver.go:51-59） | 静默回落 0o777（local.zig:100-104） | P2：配置校验缺失 |
| C4 | 缩略图全链路：list 输出 thumb URL（driver.go:152-160）、Link `type=thumb` 生成 PNG（:236-266）、ThumbCacheFolder 创建（:79-84）、VideoThumbPos 校验（:98-122）、token_bucket 限速（token_bucket.go:66-76） | `_ = args` 完全忽略（local.zig:362）；字段仅解析+标 [未实现]（:48-53、776-780） | P1：整块功能缺失（schema 已诚实标注） |
| C5 | Move 跨设备返回 errs.NotImplement（driver.go:297-300） | 透传 rename 原始错误（:423） | P2 错误码差异 |
| C6 | FIFO/设备文件复制（copy_namedpipes.go:11-16） | 一律 NotSupported（:537） | P2：unix 丢能力 |
| C7 | 目录大小 Init 时算好+增量维护（driver.go:70-78、util.go:269-354） | 每目录现算（:293-298） | P2：值相同，IO 放大 |
| C8 | list 中符号链接 size=lstat 链长（util.go:107） | 默认 follow 后 size=目标大小（:289-292） | P2 |

### 3.2 webdav（drivers/webdav ↔ webdav.zig）

**A 类**：PathError 带路径+状态码 → Zig error 枚举无 payload（webdav.zig:363-368）；
cookiejar 自实现（cookiejar.zig）；键名 `address`/`root_folder_path` 双认
（webdav.zig:64-75、766-776）。

**B 类（其中 3 条是修正 Go）**：digest `nc` 八进制→8 位十六进制（RFC 7616，
Go 竟是 `nc=1`，digestAuth.go:82）；digest `uri` 传完整路径而非相对 root 路径
（Go util/requests.go:57 在 root 带前缀时不自洽）；PUT/507/409 错误码具体化
（:631、706）。Init 发一次 PROPFIND 探测（Go 不发，driver.go:35-44）；目录
Destination 补尾斜杠（Go 不加，requests.go:155）；12h cron 重建 client 未移植
（非 sharepoint 下无状态，影响≈0）。

**C 类（真缺口）**：

| # | Go 行为 | Zig 现状 | 定级 |
|---|---|---|---|
| C1 | `vendor=sharepoint` 分支：删 Authorization 改 Cookie 拦截器（meta.go:9、util.go:25-35）+ odrvcookie SOAP 换 RtFa/FedAuth（odrvcookie/fetch.go:49-140） | schema 无 vendor，注释自认不实现（webdav.zig:763-765） | **P1：SharePoint Online 完全不可挂载**（已知取舍，需在文档明示） |
| C2 | Put callback 设 `Content-Type: s.GetMimetype()`（driver.go:117-119 → gowebdav requests.go:57-58 `if intercept != nil { intercept(r) }` 实证会应用） | 不发 CT，且注释称「Go 根本不发 Content-Type」——**论断与 Go 事实相反**（webdav.zig:673-677） | P1 小缺口 + **注释必须改** |
| C3 | `args.Redirect` 时 NoRedirectClient 跟随 302/307/308 取最终 URL（driver.go:74-88） | `_ = args` 直发，改为按需 proxy（:484、503） | P2：redirect 解析缺失 |
| C4 | PROPFIND 发 Accept/Accept-Charset/Accept-Encoding（requests.go:126-130）+ body 含 displayname/getetag（client.go:182-191）+ href 解码失败名字兜底 p.Name（client.go:153-159） | 只有 Depth+Content-Type（:354-357），body 缺两项（:34-44），名字仅取 href basename（:395-400） | P2：漏头漏属性 |
| C5 | 连续进度（ReaderUpdatingProgress） | 仅 0/100 两点（:684、696）——Go gowebdav 的 PUT 本身也是一次 req，**此项实际等价** | 决议：非缺口 |

已核实 **webdav `.space = null` 正确**：Go drivers/webdav 未实现
WithDetails/GetDetails（方法集仅到 Get，driver.go:27-147）。

### 3.3 strm（drivers/strm ↔ strm.zig）

**A 类**：Config{LocalSort,OnlyProxy,NoCache,...}（meta.go:30-38）→ 无 Config
结构，OnlyProxy 表达为 link.proxy=true（strm.zig:422）；getLink 编码/签名逐句
复刻（util.go:109-137 ↔ strm.zig:442-491、826-843）；12 个 Addition 字段全对齐
（meta.go:14-28 ↔ strm.zig:43-56）；Get 的 .strm NotSupport 回退语义等价
（driver.go:169-173 ↔ :366-368）。

**B 类**：patricia trie 全局注册 → 8 槽实例注册表（hook.go:56-97 ↔ :553-569）；
isSameContent 用 sha256 → 全量 mem.eql（hook.go:181-189 ↔ :691-697，小文件等价）；
恒 proxy=true（Go 视 ShouldProxy 可 302，driver.go:205-225 ↔ :420-422）。

**C 类**：

| # | Go 行为 | Zig 现状 | 定级 |
|---|---|---|---|
| C1 | GetApiUrl：X-Forwarded-Host 优先于 Host；proto 仅 `=="https"` 才 https（common/base.go:18-27） | 只读 Host；X-Forwarded-Proto 原值透传（strm.zig:478-485） | P2：反代下 .strm 内容 URL 可能错 |
| C2 | Version 缺省 0 → 触发 Init 迁移（driver.go:100-120） | **schema `"default":5`（:870）与 parse 默认 0（:87）矛盾**——表单预填 5 会跳过迁移 | P2：真不一致，建议 schema 改 0 |
| C3 | sync 模式删多余目录用 os.RemoveAll（hook.go:224-232） | 只 deleteDir 非递归（:719，注释自认） | P2：非空陈旧目录删不掉 |
| C4 | listRoot 各 key 目录 Modified=d.Modified（util.go:24） | modified=0（:321） | P2：根目录时间显示 1970 |
| C5 | generateStrm 的 Link 在请求上下文执行、URL 取请求 Host（hook.go:110） | getLinkText 无请求上下文，回落 bridge.site_url（:639、486-488） | 待确认：仅钩子触发路径可见 |

### 3.4 aliyundrive_open（drivers/aliyundrive_open ↔ aliyundrive.zig）

**A 类**：error 带 `code:message`（util.go:177）→ 仅日志（:102-121）；
AccessToken 无 json tag 大小写双认（:292-296、319-320）；Put/MakeDir/Move/
Rename 返回 Obj → vtable void；List 用 dir.GetID() → resolveEntry 逐级反查
（:821-842，无状态必然代价）。已逐字对齐项：api_base、calPartSize 阶梯、
proof seed、两阶段秒传删 pre_hash、token 错误码三元组重放一次、sub 校验、
limit 200 + next_marker 分页、expire_sec=14400、internal_upload 前缀替换、
livp 回退键、space=personal_space_info 字段（:1042-1052 ↔ driver.go:293-306）。

**B 类**：rate.Limiter → 最小间隔调度（:139-145）；limiter map → 固定 32 条表
+私有桶兜底（:183-222）；refresh 重试加 sleep（:712-713，Go 无）；
分片 PUT 发 UA+gzip（:1149-1168，OSS V1 签名只含 CT/MD5 无功能差）；
removeDuplicateFiles 未移植（:987-990，上游也只 warn）。

**C 类**：

| # | Go 行为 | Zig 现状 | 定级 |
|---|---|---|---|
| C1 | Link 返回 `Expiration: &time.Minute`（driver.go:121-124） | model.Link 无 expiration 字段，不设（:944-945） | P2：直链 TTL 语义丢失（STATUS §4 早已记录为 cosmetic，实际 depends on 是否有 link 缓存） |
| C2 | `Other("video_preview")` → getVideoPreviewPlayInfo（driver.go:269-291） | vtable 无 other 槽 | **P1：实况/预览播放信息不可用** |
| C3 | 秒传条件含 `!stream.IsForceStreamUpload()`（upload.go:167） | 仅 size+rapid_upload（:1227），Source 无力流标志 | 待确认：取决于 API 层是否已保证 |
| C4 | renewapi GET 用 resty SetQueryParams 自动编码（util.go:40-47） | allocPrint 原样拼 query（:738-740） | 待确认：JWT 字符集内安全 |
| C5 | create 后 PartInfoList 空则零片 complete（upload.go:226-259） | parts.len==0 and count>0 → InvalidResponse（:1285-1288） | P2：边界更严 |
| C6 | `callback_concurrency` 字段——**本 Go 树不存在**（全 drivers/ 0 命中） | Zig 新增字段+schema（:269、1444）且自认不起作用 | 待确认：疑上游版本漂移，建议删 |

### 3.5 cloud189（drivers/189 ↔ cloud189.zig）

**A 类**：Obj.ID 直用 → resolve() 逐段反查（:778-814、1203-1212）；Link 带
redirect/proxy 分支（:867-871）；FileStreamer 无 MD5 时缓存整文件 → Source
两遍读（util.go:325-351 ↔ :1074-1087）。已核对：189（web）Go 侧**没有**
family API（家庭云全在 189pc）。

**B 类**：分页 count==0 或本页两列表均空即停（防死循环，:753、791）；
InvalidSessionKey 只重放一次（:482-486）；Link 第三跳是 Go 死代码故只解一跳
（driver.go:70-73 ↔ :850-864）；qs() 固定键序+测试钉死（:225-239）。

**C 类**：

| # | Go 行为 | Zig 现状 | 定级 |
|---|---|---|---|
| C1 | List/Get 返回文件 size（driver.go:211-221） | **details 对文件恒 size=0**（硬编码，:833；Entry 无 size 字段 :694-698）——189pc 已在 findChild 补上（cloud189pc.zig:1596-1598），189 没照做 | **P0 真 bug**：/api/fs/get 文件大小恒 0 |
| C2 | 上传后 goroutine 生成 .cas.torrent 并上传（util.go:457-493；注意其 oldUpload sessionKey 是字面量 "??"，util.go:231，**上游本身即残废**；RapidUploadFromTorrent 在 Go 仓库无调用方） | 未移植（文件头 :21-25 声明） | P3：影响限于 BT 生态 |
| C3 | 秒传/分片 commit 均无 isLog（drivers/189/util.go 全文 0 命中） | 非秒传 commit 多加 `isLog=0`（:1192-1199），且注释引的是 189pc/utils.go 行号——**引错文件** | P2：多余参数+注释错 |
| C4 | Link 跟跳用共享 cookie jar 的 client（driver.go:55-58） | use_cookies=false（:860） | 待确认：直链一般跨域 |
| C5 | 文件头称 Copy 未移植 | 与 :399/:924（vtable 有 copy）矛盾 | P3 注释 stale |

### 3.6 cloud189pc（drivers/189pc ↔ cloud189pc.zig）

**A 类**：GetDetails→space（:1862-1874）；写操作返回 Obj→void；InitReference
共享登录态→每次 init 独立登录（:790-826）；错误码无 payload。**签名逐字节
对齐已复核**：`SessionKey=&Operate=&RequestURI=path&Date=` 大写 hex
（help.go:38-47 ↔ :308-324）、AES-128-ECB+PKCS#7（help.go:58-67 ↔ :337-342）、
Params.Encode 排序不转义（types.go:401-419 ↔ :350-370）。**家庭云 family API
全覆盖**：list/makeDir/rename/link/容量/上传 familyId 均对齐
（:1490-1510、:1721-1733、:1771-1784、:1839-1851、:1867-1869、:866-868 ↔
utils.go:230-266、driver.go:162-182、219-243、283-287、462-464）。

**B 类**：**APP_ID/VERSION 用 9317140619/7.2.4.0（:59-61），本地 Go 树是旧的
8025431004/6.2（utils.go:44-46）**——注释已说明本地分支没跟上游， Zig 对齐的是
上游 main；loginSubmit 多 version/apToken/pageKey/epd 字段（:1240-1247）；
secondDeviceAuth 短信二验全流程（:1277-1328，本地 Go 无）；验证码 OCR→
NeedInteractiveAuth（:1226-1228）；扫码登录明确拒绝（:801-804）；
并发度=min(thread,片数,32MiB/单片)（:93-104，光猫内存夹锁）。

**C 类（本驱动缺口最重）**：

| # | Go 行为 | Zig 现状 | 定级 |
|---|---|---|---|
| C1 | **family_transfer 全链路**：Init 建中转文件夹（driver.go:120-124）；Put 改投家庭云+临时名 `.transfer`+SaveFamilyFileToPersonCloud+删源+节流（driver.go:392-441、utils.go:1441-1511） | 仅存字段，schema 自认未实现（:162、:2297） | **P1：Go 有完整实现，Zig 零实现** |
| C2 | **rapid_upload**（旧接口 MD5 秒传，driver.go:374-379、utils.go:904-920） | 仅存字段（:2298） | P1 |
| C3 | **upload_method=old → OldUpload 断点续传**（driver.go:387-389、utils.go:1205-1266） | schema 仅 stream/rapid（:2295），old **静默降级 streamUpload** | **P1：老配置行为静默改变** |
| C4 | **分片失败重试 3 次+1s+backoff**（utils.go:739-742、1060-1063） | 无重试，首批错即整体失败（:2128-2131） | **P1：弱网可靠性** |
| C5 | SaveUploadProgress/GetUploadProgress 断点续传（utils.go:1030、1096-1099） | 无 | P2 |
| C6 | torrent 生态：generate_torrent（utils.go:757-759、864-899）+ /torrent/generate 路由（router.go:236、handles/torrent.go:225）+ torrentFollowMove/Rename/Copy 联动（driver.go:266-349） | 仅存字段（:2300）；Zig 全仓无 torrent 路由 | P2（BT 生态） |
| C7 | rename 冲突 FileAlreadyExists→ObjectAlreadyExists（driver.go:306-308） | 裸 UpstreamError（:1859→:694-730） | P2 错误码映射 |
| C8 | keepAlive 每 5 分钟保活（driver.go:107-109、utils.go:685-698） | 无 cron，仅失效时刷新（:1012-1018） | P2：长空闲会话或过期 |
| C9 | 分片 PUT 用 Go-http-client UA（utils.go:174；内部 net/serve.go 默认） | 显式浏览器 UA（:1918）——而 189 web 侧 Zig 特意对齐了 go_default_ua（cloud189.zig:1158-1163） | 待确认：两侧不一致 |
| C10 | login_type/username/password required:true（meta.go:9-11） | schema 不标 required（:2280-2281） | P3 表单校验 |

### 3.7 pan123（drivers/123 ↔ pan123.zig）

**A 类**：error 无 payload（上游 message 只进 log.warn，:433）；LocalSort/
PreferProxy 无对应（list 不本地排序 :565-581、link 不置 proxy :653）；
S3 分支 aws-sdk s3manager → 自签 SigV4（:1048-1264）；进度粒度差
（Go 每片上报 upload.go:171-172）。

**B 类**：UploadThread 加 min:1,max:32 校验（:1296，Go 无限定）；
findChild page>10_000 兜底（:533）；root_folder_id 非数字回落 0（:503，Go 直接当串）；
登录空账密直接 AuthFailed（:320，Go 仍打接口拿上游 message util.go:170-188）；
per-worker Client 换取并发（:837-846）。

**C 类**：

| # | Go 行为 | Zig 现状 | 定级 |
|---|---|---|---|
| C1 | **全程不写 ctx.err_detail**（Go errors.New(message) 用户可见，util.go:244） | 用户只看到泛化 UpstreamError | **P1：透传缺口**（STATUS §31.9 机制已就位，pan123 漏接） |
| C2 | 自签分支：s3manager 默认 5MiB 片、仅 >50GiB 才放大（driver.go:226-228）、≤5MiB 单 PUT、**默认 5 并发** | 固定 16MiB、≤64MiB 单 PUT、**串行**逐片（:1033-1035、:1206-1233） | P2：性能差 + >160GiB 破 10000 片上限 |
| C3 | 上传循环 utils.IsCanceled（upload.go:108-120） | 无取消检查，仅 error 后 cancel（:920-934） | P2 |
| C4 | link 二跳非 302 且 ≥300 时**原样返回**带 Referer 的 u_（driver.go:106-118，不判错） | 返回 Error.UpstreamHttp（:640-642） | P2：失败开放 vs 关闭分叉（403 时行为不同） |
| C5 | OfflineDownload/GetOfflineTask/DeleteOfflineTasks（util.go:249-356） | 未移植（文件头 :22-23 自认） | P2（离线下载任务中心，边界内已定不做） |
| C6 | partNumberEnd：Go 发 `end`（=min(i+10,count+1)，upload.go:50-51、107-113），上传 [start,end-1] | 发 `end-1`（:856-861） | **已定性非 bug**：Go 每批多要 1 个 URL（浪费）；Zig 精确。单片路径 Go 发 [1,2] / Zig 发 [1,1] 且单片上传真机通过 ⇒ 上游 inclusive 语义，两者都覆盖所用分片。残留：Zig 无注释解释该偏差 |
| C7 | params base64 解出的 URL parse 失败报错（driver.go:92-95） | 静默保留原 URL（:620） | P3 |
| C8 | list 结束做 len(res)!=total 告警（util.go:397-399） | 无 | P3（仅日志） |

### 3.8 quarkuc / Quark+UC（drivers/quark_uc ↔ quarkuc.zig）

**A 类**：Link 的 Concurrency:3/PartSize:10MB（util.go:134-135）无承载字段；
Init 时置 WebProxy/WebdavPolicy（driver.go:39-45）未移植（用 Link.proxy 部分补偿）；
NoOverwriteUpload 配置（meta.go:31,47）无对应。

**B 类**：err_detail 透传（:267-272，替代 Go errors.New(e.Message)，**本驱动是
透传标杆**）；makeDir 冲突→TargetExists 用 requestUnchecked 识别（:544-561，
等价 Go driver.go:83-88）；建目录后 sleep 1s 照抄（:551）；upPart/upCommit
非 200 统一 UploadFailed（:801-805、850-854）。

**C 类**：

| # | Go 行为 | Zig 现状 | 定级 |
|---|---|---|---|
| C1 | upCommit Referer **硬编码** `https://pan.quark.cn/`（util.go:315） | 用 `conf.referer ++ "/"`（:843）——UC 变体实发 drive.uc.cn，与 Go 分叉。同文件 L18 注释只修了 upPart（:792-795），commit 漏修 | P2：已知偏差漏一处 |
| C2 | requestUnchecked 吸收 __pus 只判开关**不判变体**（:344）；request 正确判 isQuarkVariant（:259 ↔ util.go:55） | makeDir 路径下 UC+转码开会把夸克会话 cookie 写进 UC 配置 | 待确认（M4 只覆盖 request 路径） |
| C3 | 上传每片 IsCanceled（driver.go:183-186） | 无 | P2（全局通病） |
| C4 | 进度点 up(97)（driver.go:216） | 每片 95 比例后直接 100（:739、749） | P3 小差 |
| C5 | use_transcoding_address required:"true"（meta.go:13） | schema 未标（:869） | P3 UI 标记 |

### 3.9 pan115（drivers/115 ↔ pan115.zig；SDK 行为标「推断」）

**A 类**：Cookie 登录态手动塞头（:336-359、265，Go 靠 resty jar）；
LoginCheck 直连 check/sso state==0（:523-530，SDK 内部判据推断）；
time.Time → CST 字符串 parseCstMinutes（:390-425）；二维码登录未移植
（util.go:42-50 → init 直接 AuthFailed :515-518）。Go OfflineList/OfflineDownload/
DeleteOfflineTasks（driver.go:231-245）经全仓检索**无任何调用方=死方法**，Zig 缺失
不构成缺口。

**B 类**：请求级头按名替换客户端级 UA/Cookie（:267-281，防 resty 双头，必要修正）；
Link.Header 丢本次请求 CT（:732-738，有论证的有意偏差）；
UploadDigestRange → 一遍读同时算 128KB 预哈希+全量（:870-901，等价优化）；
秒传 701 显式放行（:974-978，推断对齐）；schema 补 "linux" option（:1329，
Go meta.go:11 漏了 default 值本身）。

**C 类**：

| # | Go 行为 | Zig 现状 | 定级 |
|---|---|---|---|
| C1 | **Init 动态拉取 app 版本**，失败回落 35.6.0.3（appver.go:44-47、driver.go:35） | 编译期常量 app_ver="35.6.0.3"（:64），无 ApiGetVersion 链路 | **P1**：版本号进 UA 与 GenerateToken/sig，上游改版后静默失效 |
| C2 | OSS 分片每片失败重试 3 次（util.go:339-359） | 单片失败即整链失败（:1235-1238） | **P1**：弱网可靠性 |
| C3 | TokenRefreshTime ticker ~50 分钟重取 OSS token（util.go:296,345,380；默认值在 SDK 推断） | 每次上传只取一次（:1178） | P1（长传，推断阈值） |
| C4 | UploadByOSS 流式 PUT（util.go:236-245） | 整文件读进 arena 再 PUT（:1307-1309） | P2：内存放大 |
| C5 | FileObj.Thumb() 返回 ThumbURL（types.go:25-27） | objFrom 不填 thumb（:404-411，model.zig:79 有字段） | P2：列表无缩略图 |
| C6 | GetDetails 走 client.GetInfo()（driver.go:248，端点不在树内） | 走 files/index_info 读 space_info（:650-656） | 待确认：是否同一端点 |
| C7 | List 容忍 ErrNotExist 返空表（driver.go:58-60） | NotFound 直接上抛（:449） | P2：边缘行为差异 |
| C8 | 分片上限 FileListLimit/1150 来自 SDK（util.go:65） | 硬编码 56/1150（:68、455） | 待确认：推断值 |
| C9 | 模块头「Copy vtable 没有槽位」（:23） | 与 :228（有 copy）不符 | P3 注释 stale |

### 3.10 wopan（drivers/wopan ↔ wopan.zig；SDK=v0.1.5）

**A 类**：core 直传 model.Obj.ID → findEntry/childByName 逐级列表（:809-863）；
密文判定按 json.Value string tag（:485-488，SDK 按 raw 首尾引号 request.go:53，
等效）；9999 重试重新加密不重放（:380-381、466-470，对齐 SDK）；
Addition.AccessToken 有解析但 **schema 未声明**（:976-982）⇒ 前端不显示该字段。

**B 类**：web/app/pc 三渠道身份依次刷新（:229-276，Go 仅 DefaultWithRefreshToken
单一身份，推断）；resp==nil 不解密走 want_payload=false（:484，对齐 SDK）；
签名 md5(key+resTime+reqSeq+channel+version) 逐字一致（wopan-sdk-header.go:16 ↔
:400）。

**C 类**：

| # | Go 行为 | Zig 现状 | 定级 |
|---|---|---|---|
| C1 | QueryAllFiles 的 sortRule **硬编码 0**（driver.go:56；getSortRule() util.go:11-28 全仓无引用=死代码） | 按配置传 1..6（:507-509、836-838） | 已定性：Zig 实质修正 Go（0 不是合法排序值），严格对账属下发值不同 |
| C2 | SDK 个人空间全链路要求 psToken 非空（wopan-sdk-api-fs.go:34-39、111-116、142-147、upload.go:55-60） | Zig 上传发字面量 `"psToken":"undefined"`（:734），其余个人空间操作不发 | **待确认**：Go 线上可用推断依赖 SDK InitData 内部取 psToken（不在 vendor 文件集）；Zig 上传真机已通过（§36B），疑镜像 web 前端行为（浏览器未初始化变量就是字面 undefined）。**建议真机抓包核对 list/mkdir 是否需要补 psToken** |
| C3 | uniqueId=UnixMilli+"_"+random(6)（wopan-sdk-upload.go:71） | 后缀固定 "olzzig"（:708-710） | P2：同毫秒并发上传撞 uniqueId |
| C4 | part 用 stream.GetMimetype()（wopan-sdk-upload.go:141） | 硬编码 application/octet-stream（:957-959） | P2：服务端是否介意待确认 |
| C5 | FamilyUserCurrentEncode 失败即 Init 失败（driver.go:39-43） | catch 后置空串（:218） | P2：失败严格度不同 |
| C6 | getTime 解析失败整页报错（types.go:13-15） | 容错返 0（:919-930） | P2：坏时间条目 Go 整页失败、Zig 留条目 |
| C7 | ByteTotalSize ParseInt 失败报错（driver.go:174-177） | catch 0（:792） | P2 |
| C8 | — | :22 注释「内层非 0000 即刷 token」与实现（仅 9999，:459-460）不符 | P3 注释 stale |
| C9 | — | :26 注释「未移植 Other、离线下载」——**Go 侧本就只有注释掉的死代码**（driver.go:186-188），无实际缺口 | P3 注释误导 |

### 3.11 itvsh 与三个未注册变体

- **itvsh**：专项对账已完成（STATUS §39.2，A8/B5/C4 三类），结论「协议行为与 Go
  逐字一致，未发现自作主张改逻辑」，本文不重复。err_detail 已接入。
- **未注册变体**（driver.zig:337-350 注释区，代码保留不编译）：
  `quark.zig`=QuarkOpen、`123open.zig`=123 Open、`115open.zig`=115 Open。
  用户 2026-10-12 指示保留代码不注册。注意 quark.zig 的 err_detail 已接入但
  整支不在产物内 ⇒ 实际生效的透传只有 quarkuc + itvsh + pan115 三支。

---

## 4. Zig 未完成功能/错误总账（按修复优先级）

### P0 — 确认的真 bug（2 个，均已修，2026-10-18）

| # | 位置 | 问题 | 影响 | 状态 |
|---|---|---|---|---|
| 1 | local.zig:585 | put 进度回调传**累计字节数**（契约是 0–100 百分比，driver.zig:70-78；其余 8 驱动全传 pct） | 上传进度条溢出 | ✅ **已修**：改传 `off*100/total`（u128 中间量防溢出）+ 回归测试「put reports upload progress as a 0-100 percentage, not bytes」（回调内断言 ≤100 且单调不减） |
| 2 | cloud189.zig:833 | details() 对文件**硬编码 size=0**（Go driver.go:211-221 返回真 size；189pc 已于 cloud189pc.zig:1596 修过，189 漏修） | /api/fs/get 与 WebDAV PROPFIND 文件大小恒 0 | ✅ **已修**：Entry 补 `size`/`modified`（照 189pc 方案），findChild 从 list 响应搬真值，details 透出；无网络路径单测（同 189pc），靠真机 fs/get 验证 |

验证：打包机构建 **408/408 单测通过**（新增 1 个进度回归测试），aarch64 产物
`c8797e16b9b0d722…`（1,254,784 B）。真机回归见 §6。

### P1 — 功能缺口（10 项）

| # | 驱动/模块 | 缺口 | 参考 |
|---|---|---|---|
| 1 | webdav | `vendor=sharepoint` 分支 + odrvcookie（RtFa/FedAuth SOAP）整支未实现 | webdav.zig:763-765；odrvcookie/fetch.go:49-140 |
| 2 | webdav | PUT 不发 `Content-Type: <streamer mimetype>`（Go callback 实证会应用，gowebdav requests.go:57-58） | webdav.zig:673-677 |
| 3 | cloud189pc | **family_transfer 转存全链路**零实现（Go 有完整实现） | driver.go:392-441、utils.go:1441-1511 |
| 4 | cloud189pc | **upload_method=old 静默降级**为 streamUpload（老配置行为改变）+ rapid_upload 旧秒传缺失 | driver.go:374-389；cloud189pc.zig:2295 |
| 5 | cloud189pc | 分片上传**无重试**（Go 3 次+backoff） | utils.go:739-742 ↔ cloud189pc.zig:2128-2131 |
| 6 | pan115 | **动态 appver 拉取**未移植（UA/sig 里带版本号，上游改版后静默失效） | appver.go:44-47 ↔ pan115.zig:64 |
| 7 | pan115 | OSS 分片无重试、无 token 中期刷新、整文件读内存 | pan115.zig:1235-1238、1178、1307-1309 |
| 8 | pan123 | **err_detail 未接**（上游 message 用户不可见；quarkuc 已是标杆） | pan123.zig:433 |
| 9 | aliyundrive | `Other("video_preview")` 未实现（实况/预览播放信息） | driver.go:269-291 |
| 10 | 全局 | err_detail 只接了 quarkuc/quark/itvsh/pan115；**cloud189 / cloud189pc / aliyundrive / pan123 / webdav / wopan / local / strm 八个驱动的上游错误用户只能看到泛化 message** | driver.zig:40-67 |
| 11 | api 层 | STATUS §22.4 遗留三端点仍缺：`POST /api/fs/form`（multipart 直传）、`GET/POST /api/fs/archive/meta`、`POST /api/admin/setting/reset_token`（现以 JSON 404 静默失败） | api.zig 白名单无匹配 |
| 12 | local | 缩略图整块：list thumb URL + `?type=thumb` + 缓存目录 + 限速（schema 已标 [未实现]） | local.zig:362、48-53 |

**2026-10-18 晚已落地 5 项**（同轮修完，构建 409/409 + 真机 e2e 465/0/1）：

| 原编号 | 项 | 落点 | 验证 |
|---|---|---|---|
| P1-6 | pan115 **动态 appver 拉取** | `init` 调 `fetchAppVer`（GET `appversion.115.com/1/web/1.0/api/chrome`，读 `data.win.version_code`，失败回落 `default_app_ver`）；`app_ver` 从常量改为驱动字段，UA/GenerateToken/sign 全部用运行期值 | 纯函数 `parseAppVersion` 单测 4 例；真机 run.log 实证 `appversion.115.com ... status=200` |
| P1-7（前半） | pan115 **OSS 分片 3 次重试** | `ossMultipart` 每片 3 次尝试（对齐 Go util.go:339-359）；**token 中期刷新仍未移植**（ticker 间隔在 SDK 默认值里、不在树内） | 编译 + e2e 写链路 |
| P1-5 | 189pc **分片 3 次重试 + 1s/2s 退避** | `partWorker`（并发路径）与 `put` 串行路径各一处，对齐 Go `retry.Attempts(3)+Delay(1s)+BackOffDelay` | 编译 + e2e 写链路 |
| P1-8 | pan123 **err_detail 接入** | `request/get/post/listPage/findChild/resolveEntry` 全链穿 `?*?[]const u8`；list/details/link/mkdir/move/rename/remove/space/put 传 `&ctx.err_detail`；**worker 线程的 refetch 传 null**（跨线程写请求栈帧 = 数据竞争） | 编译期验证（网络路径无单测，同 quarkuc 先例） |
| P1-2 | webdav **PUT 发 Content-Type** | `model.Source` 新增 `mime` 字段；`fs/put` 用 `mimeFor(basename)`、DAV PUT 优先用请求自身 CT；驱动侧 `src.mime` 非空即发。**顺带修正原注释的错误论断**（Go callback 实际会设 CT） | 编译 + e2e（WebDAV PUT 201/覆盖/ETag 全过） |

**P1 剩余**：webdav SharePoint、189pc family_transfer / old 上传 / rapid_upload /
torrent、local 缩略图、aliyun `Other(video_preview)`、api 三端点、err_detail
其余七驱动（cloud189/cloud189pc/aliyundrive/wopan/webdav/local/strm）。

### P2 — 取舍/待确认（记录在案，不阻塞）

- **待确认 4 项**：① wopan psToken 个人空间链路（建议真机抓包，§3.10-C2）；
  ② aliyun 秒传 `IsForceStreamUpload` 豁免（§3.4-C3）；③ quarkuc `__pus`
  变体收窄（§3.8-C2）；④ 189pc Zig APP_ID/VERSION 新于本地 Go 树
  （9317140619/7.2.4.0 vs 8025431004/6.2，§3.6-B）——Zig 对齐的是上游 main，
  **本地 Go 树已旧于上游**，后续对账需注意两套事实来源。
- **全局取消传播**：各上传驱动均无 ctx 取消检查（Go 有 IsCanceled）。
- **模型层**：Obj.created 永不填（local  ctime 丢失）；Link 无 Expiration/
  Concurrency/PartSize。
- **已定边界（STATUS §22，非缺口）**：Baidu/Onedrive 不移植、分享/SSO/2FA/
  LDAP/多用户/离线下载/torrent 路由/分片上传 API/S3·FTP·SFTP·MCP 服务不做；
  local 符号链接默认拒、strm 恒 proxy、匿名浏览 opt-in 默认关。

## 5. 文档/注释漂移清单（顺带修，成本低）

| 位置 | 漂移 |
|---|---|
| webdav.zig:673-677 | PUT Content-Type 注释论断与 Go 事实相反（Go callback 会设 CT） |
| pan115.zig:23 | 「Copy vtable 没有槽位」↔ :228 实际有 copy |
| wopan.zig:22 | 「内层非 0000 即刷 token」↔ 实现仅 9999 |
| wopan.zig:26 | 「未移植 Other、离线下载」↔ Go 侧只有注释掉的死代码，无缺口 |
| cloud189.zig:21-22 | 「Copy 未移植」↔ :399/:924 实际有 copy |
| cloud189.zig:1192-1199 | isLog 注释引 189pc/utils.go 行号（引错文件） |
| strm.zig:870 | schema Version default=5 ↔ parse 默认 0（矛盾，建议统一为 0 走迁移） |
| pan123.zig:856-861 | partNumberEnd 与 Go 差 1 无注释解释（已定性非 bug，建议补注） |
| STATUS.md §2 | 驱动表 UC/WoPan「未真机」已 stale（§36A/§36B 已补测收官） |
| aliyundrive.zig:269、1444 | callback_concurrency 字段本 Go 树不存在，自认不起作用，建议删 |
| local.zig:100-104 | mkdir_perm 非法值静默回落（Go 启动失败）——注释只说了回默认可 |

## 6. 修复验证记录（P0 两项，2026-10-18）

| 项 | 验证 | 结果 |
|---|---|---|
| P0-1 local 进度 | 单测「put reports upload progress as a 0-100 percentage, not bytes」（回调内断言 ≤100、单调不减，3×128KiB 文件 ≥3 次回调、收尾 100%）；真机 e2e 465 项全过（含 Local/WebDav/云盘 put 全链路） | ✅ |
| P0-2 189 web size | 打包机 408/408 单测；真机临时挂 `/ecloud_web`（189Cloud，账密同 §36.2）：put 15 字节文件 → fs/get `size=15, modified=2026-10-18T10:43:44Z`（修复前恒 0）；临时存储已删 | ✅ |

- 构建：打包机 `tools/build_remote.py` 全量，**408/408 单测通过**，aarch64 产物
  `c8797e16b9b0d722…`（1,254,784 B）。
- 真机回归：`tools/e2e_test.py --write-cloud` **465 通过 / 0 失败 / 1 跳过**
  （跳过 = 坚果云根级目录 403 服务商规则，需 WEB 手动删；日志
  `docs/regression/2026-10-18-p0-fix-e2e.log`）。中途曾一次 WebDAV MKCOL
  遭设备 TCP reset，实例无 panic、重跑全绿 ⇒ 设备一次性抖动，非回归。
- 环境备注：测试实例管理员口令已重设为 `openlist-zig-test`（原口令哈希未知，
  按 `openlist admin set` 流程重置；仅影响 /tmp/olz 测试实例）。
- 189 web 修复无网络路径单测（同 189pc 先例），验证 = 真机 fs/get，已覆盖。

## 7. 方法与局限

- 驱动名/操作集结构性检查沿用 §26.1 结论（12/12 逐字节、NotSupport 约定一致），
  本轮未重复。
- 115/WoPan 的 SDK 内部行为（appver 接口、psToken 获取、OSS token 刷新阈值）
  源码不在树内，相关结论标「推断」，真凭据在设备上可抓包钉死。
- 189pc 的「Zig 领先本地 Go 树」项（APP_ID/VERSION、短信二验、登录表单字段）
  以上游 main 为事实来源，本地树旧于上游；如需彻底对齐应先更新 Go 树。
- §3 全部结论只读代码得出；§4 P0 两项的修复改动仅限 local.zig（进度回调）
  与 cloud189.zig（Entry size/modified 透出），未触碰其他驱动。

