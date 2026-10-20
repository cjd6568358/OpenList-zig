# 迅雷网页版（pan.xunlei.com）逆向记录

> 2026-10-20 晚。承接 `STATUS.md` §48（旧安卓 SDK 驱动）与交接笔记。
> **本文件是 thunder_web 的唯一事实来源**：算法、参数、验证结果、复现方法都记在这里。

---

## 0. 结论摘要

| 项目 | 结论 |
|---|---|
| 网页版登录是否受风控 | **不受**（OAuth 表单登录，账号密码即可，无短信/滑块） |
| 业务接口能否直连 | **能**，`api-pan.xunlei.com/drive/v1/*`，与安卓驱动同一套 |
| 卡点 `captcha_sign` | **已破解**：15 轮加盐 MD5 链，纯 JS，无 WASM、无子资源、无 `crypto.subtle` |
| 离线复算是否可信 | **逐字节命中**浏览器实抓的黄金对，并在**真实服务端**换到了 `captcha_token` |
| captcha token 寿命 | **300 秒**（实测 `expires_in:300`，不是先前估的 ~10 分钟） |
| 与安卓算法的关系 | **同一函数**，只差算法表：网页版是 15 个固定盐，安卓是 `amaze` 下发的算法表 |

一句话：`captcha_sign = "1." + MD5(MD5(...MD5(base+s1)+s2...)+s15)`，盐表见 §3.2。

---

## 1. 两套登录体系

| | 风控驱动（旧安卓 SDK） | 网页版（官方） |
|---|---|---|
| 端点 | `xluser-ssl.xunlei.com/xluser.core.login/v3/login` | `pan.xunlei.com/login` OAuth |
| 风控 | 数美，账号+设备+IP 组合触发 | 无 |
| 首登 | 必被 `review_panel`（1007 / MEA） | 无 |
| 验证 | 短信/滑块/图形码，挑战类型随机 | 表单有「账号密码」tab，无需短信 |
| 长期令牌 | `/v1/auth/signin/token` 响应**不带** refresh_token | localStorage 有 refresh_token（轮换） |

上游三个迅雷驱动（`thunder` / `thunder_browser` / `thunderx`）**全部**走 core login，
没有一个接网页版 —— 这就是本驱动存在的理由。

---

## 2. 网页版链路（全部实测）

### 2.1 凭据

`localStorage.credentials_Xqp0kJBXWhwaTpB6`：

```json
{
  "token_type": "Bearer",
  "access_token": "<JWT，12h>",
  "refresh_token": "a1.…",
  "expires_in": 43200,
  "user_id": "832926495"
}
```

### 2.2 刷新令牌

```
POST https://xluser-ssl.xunlei.com/v1/auth/token
{"client_id":"Xqp0kJBXWhwaTpB6","client_secret":"","grant_type":"refresh_token",
 "provider":"refresh_token","refresh_token":"a1.…"}
```

* 返回 `access_token` + `refresh_token` 等字段。
  **refresh_token 实测可重复使用**：同一枚连续 7 次 grant 全 200，且返回值与传入
  完全相同（**不轮换**）。
* 曾经出现过一次 `4126 invalid_grant — refresh token … has been refresh at …`。
  **真因已查明（2026-10-20 22:52）**：当时光猫上有**3 个 openlist 实例**同时活着
  （SO_REUSEPORT 抢同一个 15244），同一枚 token 被多个进程并发 refresh，服务端
  判定为重复刷新。清理成单实例后不再复现。
  已排除 `x-device-id` / `x-client-id` 绑定（换任意值仍 200）。
  ⇒ **不是令牌轮换，也不是 TTL**。但驱动仍然每次 grant 后落盘（零成本保险）。
* 网页 refresh_token **只认网页 client_id** `Xqp0kJBXWhwaTpB6`；用安卓 cid 报 `invalid_grant`。
* 这个端点**不过风控**（这是整条路线的立足点）。

### 2.5 网页登录（可程序化，已实测）

**关键结论：网页版「手机号 + 密码」登录可以纯 HTTP 复现，无短信、无滑块、
不需要 `captcha_sign`。** 这让驱动能「只录一次账号密码」，而不是让用户定期
去浏览器抓 token。

抓包（2026-10-20 22:41）得到的四步：

```
1) POST https://xluser-ssl.xunlei.com/v1/shield/captcha/init
   {"client_id":"XW5SkOhLDjnOZP7J","action":"POST:/v1/auth/signin",
    "device_id":"<32hex>","meta":{"phone_number":"+86 18616132763"}}
   → {"captcha_token":"…"}
   ★ 注意 client_id 是 i.xunlei.com 账号中心的，不是 pan 的；
     这个 action 的 init **不校验 captcha_sign**（这正是能程序化的原因）。

2) POST https://xluser-ssl.xunlei.com/v1/auth/signin
   header: X-Captcha-Token: <上一步>
   {"username":"+86 18616132763","password":"…","client_id":"XW5SkOhLDjnOZP7J"}
   → {"access_token":"…"}          # SSO 令牌，scope="user pan profile offline"

3) POST https://xluser-ssl.xunlei.com/v1/user/authorize
   header: Authorization: Bearer <SSO access_token>
   {"client_id":"Xqp0kJBXWhwaTpB6","response_type":"code",
    "redirect_uri":"https://pan.xunlei.com/login?sso_sign_in_in_iframe=",
    "state":"state-<rand>","scope":"profile offline pan sso user",
    "code_challenge":"<base64url(sha256(verifier))>","code_challenge_method":"S256",
    "sign_out_uri":"https://pan.xunlei.com/login?sso_sign_out="}
   → {"code":"a1.…","expires_in":120}      # code 只活 120 秒

4) POST https://xluser-ssl.xunlei.com/v1/auth/token
   {"code":"a1.…","grant_type":"authorization_code","code_verifier":"<32 位随机>",
    "redirect_uri":"<同上>","client_id":"Xqp0kJBXWhwaTpB6"}
   → {"access_token":"…","refresh_token":"a1.…","expires_in":43200,"user_id":"…"}
```

PKCE 细节：`code_verifier` 是 **32 位**字母数字；`code_challenge` =
base64url(sha256(verifier)) 去填充，**43 字符**（RFC 7636 标准做法，
单测用 RFC 附录 B 的向量钉住）。

手机号格式必须是 `+86 18616132763`（**带空格**）。纯 11 位数字会被拒，
驱动里由 `webUsername()` 规范化。

实测（2026-10-20 22:47，纯 urllib，无浏览器、无 cookie）：
四步全部 200，拿到 `refresh_token: a1.Bdzn…`。

### 2.3 业务接口

```
GET https://api-pan.xunlei.com/drive/v1/files?space=&limit=N&parent_id=<id>
```

请求头三件套：

```
Authorization:   Bearer <access_token>
X-Captcha-Token: <captcha_token>
X-Device-Id:     <device_id>
（另有 X-Client-Id / X-Client-Version）
```

### 2.4 captcha 初始化

```
POST https://xluser-ssl.xunlei.com/v1/shield/captcha/init
{
  "action": "get:/drive/v1/about",
  "client_id": "Xqp0kJBXWhwaTpB6",
  "device_id": "<32-hex>",
  "meta": {
    "username":"", "phone_number":"", "email":"",
    "package_name":"pan.xunlei.com",
    "client_version":"1.93.12",
    "captcha_sign":"1.<32hex>",
    "timestamp":"<毫秒>",
    "user_id":"832926495"
  }
}
→ {"captcha_token":"ck0.…","expires_in":300}
```

* `action` = `<METHOD>:<path>`，**不带** query/fragment。
* 签名里的 `timestamp` 必须与 `meta.timestamp` 一致。
* 前端的时间戳在**页面加载时**就冻结了（`utils-initial` 模块 22 顶层
  `var c = String(Date.now())`），所以服务端对时间戳的容忍窗口至少覆盖一个页面会话；
  驱动直接用当前毫秒时间即可。

---

## 3. captcha_sign 算法（已破解）

### 3.1 公式

顶层逻辑在 `utils-async` 分片**模块 1643**（导出 `a`，被 `service-captcha` 模块 609 调用）：

```
base = clientId + clientVersion + location.host + deviceID + timestamp_ms

if A():                       # funFile ∈ {BEGIN_FUN_FILE_PAN, BEGIN_FUN_FILE_XLPAN}
    for alg in amaze算法表:  base = md5(base + alg)      # 安卓路线
else:
    base = getPubKeySignUtil(funFile, funName)(base)     # 网页路线

return algVersion + "." + base
```

`pan.xunlei.com` 的 `funFile = "captcha"`，**不在** `BEGIN_*` 名单 ⇒ 走 else 分支。
`getPubKeySignUtil` 只是 `import()` 分发表，`"captcha"` → 模块 22。

模块 22 不是算法本体，而是一张**导出表**：把随机名 `pubXXXX` 映射到本地函数。
`pubIHrxR93yM8iZPRb1X2XWnkng0JpG8p3I` → 函数 `N`：

```js
function N(e){
  var n=t(0), r="QT5gqd1eSINZe+K";            // t(0) = blueimp-md5（hex）
  if("end"!=="undefined"){                     // 恒真（混淆的不透明谓词）
    var o=t(20).pubQZUCC…, c=t(21).pub3dHO…;
    return o(n(e+r)) || c(n(e+r));             // 第二支是死代码
  }
  return e;
}
```

模块 20 / 21 里每一个 `pubXXX` 都是同构的一层：

```js
function X(e){ var n=t(0), r="<salt>"; … return t(A).pubYYY(n(e+r)) || t(B).pubZZZ(n(e+r)); }
```

**实测（插桩 blueimp-md5）整条链恰好 15 次 md5 调用、完全线性**，`||` 右支一次都没执行。
所以算法就是：

```
h = clientId + clientVersion + host + deviceId + timestamp_ms
h = md5(h + s1)
h = md5(h + s2)
…
h = md5(h + s15)
sign = "1." + h
```

### 3.2 盐表（2026-10-20 版本，`client_version = 1.93.12`）

```
 1  QT5gqd1eSINZe+K
 2  9TafMwqVWgh45hLntDm6HLcOXE
 3  L0nOen58D2cCsOSRaRRYt1Mj+XTVM
 4  gu4CPVQhQU
 5  X/6jue5AUYt56MbqopFv
 6  EuBhpIhdLUh37zvuzrOA3t8HL2HBtlCw
 7  3LSRoSaxM6YKIbhtx7RxaBpf
 8  OOnBZYkw3kRrfGD8
 9  ytWf
10  psUOt
11  +0izM
12  tF53Ovo+aqLG00zho+b
13  OnrcYC9y8
14  cv2tHyrFOPhJUFkk6KhecIHJDUKK
15  NnkQ2lQy
```

⚠ **盐是构建期随机生成的**，迅雷重新打包就会变（连带 `pubXXX` 导出名、模块号也会变）。
失效时按 §4.3 重取。

### 3.3 黄金测试向量

```
client_id      = Xqp0kJBXWhwaTpB6
client_version = 1.93.12
host           = pan.xunlei.com
device_id      = 28419a6fe0b7e47c355bbd8a95777fef
timestamp_ms   = 1792491447693

base = Xqp0kJBXWhwaTpB61.93.12pan.xunlei.com28419a6fe0b7e47c355bbd8a95777fef1792491447693
sign = 1.68270948a01b031830b45681bb1da55f
```

中间结果（可用于定位「第几轮开始错」）：

| # | md5 输入（= 上一轮输出 + 盐） | 输出 |
|---|---|---|
| 0 | `base` + `QT5gqd1eSINZe+K` | `59ec4e1b1ba6123c8b018458577e06f0` |
| 1 | `59ec4e1b…` + `9TafMwqVWgh45hLntDm6HLcOXE` | `d6a418769bf3e5bf842a7ee96a56b568` |
| 2 | `d6a41876…` + `L0nOen58D2cCsOSRaRRYt1Mj+XTVM` | `eacb11dd5e4a71571f8bb0575abf5983` |
| 3 | `eacb11dd…` + `gu4CPVQhQU` | `897ec6c375cae0afd7bf1912db1d7a41` |
| 4 | `897ec6c3…` + `X/6jue5AUYt56MbqopFv` | `bdde80b30c46f1619262d0a8d6e16e03` |
| 5 | `bdde80b3…` + `EuBhpIhdLUh37zvuzrOA3t8HL2HBtlCw` | `58c3b5709ec8cb01d1870c2b3d8b20f0` |
| 6 | `58c3b570…` + `3LSRoSaxM6YKIbhtx7RxaBpf` | `6afbaef6b266a3e2e22a95829faf6340` |
| 7 | `6afbaef6…` + `OOnBZYkw3kRrfGD8` | `849ebad20a974d71d1f5704c5cb58ce6` |
| 8 | `849ebad2…` + `ytWf` | `cca1604215b509716a31ece7914e71d1` |
| 9 | `cca16042…` + `psUOt` | `99ae40a6b32560fd638f5775bcf8a7df` |
| 10 | `99ae40a6…` + `+0izM` | `ea36f9bd0998ecb1ed93c3ff519ab491` |
| 11 | `ea36f9bd…` + `tF53Ovo+aqLG00zho+b` | `ed2fd6910195b1a895b5ce1724b02224` |
| 12 | `ed2fd691…` + `OnrcYC9y8` | `ec54dd6883f71503bf247676334583b4` |
| 13 | `ec54dd68…` + `cv2tHyrFOPhJUFkk6KhecIHJDUKK` | `4dc6b84d20f9073ecf5aa11e25fecfc0` |
| 14 | `4dc6b84d…` + `NnkQ2lQy` | `68270948a01b031830b45681bb1da55f` |

### 3.4 验证

1. **离线复算**：迷你 webpack runtime 加载真实分片，直接调签名函数 ⇒ 与黄金对逐字节一致
   （Node 与 Python 两条独立实现都命中）。
2. **在线**：用算出的签名打真实 `captcha/init`
   → `HTTP 200 {"captcha_token":"ck0.…","expires_in":300}`。
   **服务端认可**，签名卡点解除。

### 3.5 与安卓算法的关系

两者是**同一个函数**（模块 1643 的 `a`），差异只在「算法表」：

* 安卓：`A()` 为真 → 从 `amaze` 接口拉算法列表，逐个 `md5(base + salt)`。
* 网页：`A()` 为假 → 用 `captcha` 公钥签名器（就是上面 15 个固定盐）。

所以 Zig 里**不需要两套代码**：`captchaSignAt()` 的签名是
`(client_id, client_version, package_name, device_id, timestamp, algorithms)`，
网页版只要把 `package_name` 填 `pan.xunlei.com`（恰好等于 `location.host`）、
`algorithms` 填 15 个盐，**同一个函数直接产出正确结果**。

---

## 4. 逆向方法（可复用）

### 4.1 模块定位链

```
service-captcha(cap.js) 模块 609 createCaptchaService
  └─ request() → Object(v.a)(timestamp)          v = 模块 1643
       └─ utils-async(ua.js) 模块 1643 a()
            ├─ A() 真 → amaze 算法表（安卓）
            └─ A() 假 → n.e(93) → 模块 1648.getPubKeySignUtil(funFile, funName)
                          └─ loaders["captcha"] = import(22)
                               └─ utils-initial 模块 22 导出表 → 模块 20/21 嵌套包装器
                                    └─ 模块 0 = blueimp-md5（在数组形式的 app.<hash>.js 里）
```

关键点：`t(0)` 不是「编码器」而是 **blueimp-md5**，所以整条链从头到尾都是 MD5，
不存在 RSA/EC/公钥签名 —— 「pubKeySign」这个名字是障眼法。

### 4.2 离线复算器

`tools/thunder_web_sign_harness.js`：

```bash
node tools/thunder_web_sign_harness.js <分片目录>
```

它做三件事：
1. 迷你 webpack runtime（支持对象形式与**数组形式** chunk，后者模块 id 是下标）；
2. 拦截模块 0 的每次 md5 调用，打印 `输入 -> 输出` 全序列；
3. 从序列里反推盐表，最后一行直接输出可粘贴进 Zig 的 JSON 数组。

参考实现（Python，含在线探针）：`tools/thunder_web_sign.py`
（`golden` 自检 / `sign` 打印 / `probe` 打真实 captcha init）。

回归工具：

* `tools/thunder_web_probe.py` —— 本机全链路（refresh → captcha → files → about），
  不依赖 OpenList，用来快速判断「是驱动坏了还是接口变了」。
* `tools/thunder_web_e2e.py --base http://<host>:<port> [--write] [--upload]`
  —— 走管理面建/更新存储 → 等 `status=work` → 列目录 → 写操作 → 上传/直链/下载。
  上传步骤内置了最终一致性轮询。
* 网页版登录（拿 refresh_token）：Chrome + CDP，`i.xunlei.com` 的 OAuth iframe
  里切「账号密码登录」tab，填手机号/密码直接提交，**无短信、无滑块**；
  成功后读 `localStorage.credentials_Xqp0kJBXWhwaTpB6`。

### 4.3 盐表失效后怎么重取

1. 浏览器打开 `pan.xunlei.com`（登录状态），F12 → Network → JS，把下列分片存到同一目录：
   * 含 `0:function` 的**数组形式**大分片（通常 `app.<hash>.js`）
   * `utils-initial.<hash>.js`、`utils-async.<hash>.js`
   * `service-captcha.<hash>.js`、`service-device-sign.<hash>.js`（可选）
2. 在分片里 grep `"pan.xunlei.com":{clientId:` → 取 `funName`（形如 `pubXXXX`）
   与 `client_version`；`funName` 变了就传 `XL_FUN_NAME=<新值>`。
3. 从浏览器抓一次真实请求的 `timestamp` 与 `captcha_sign` 作新黄金对，
   传 `XL_TS` / `XL_EXPECT` 跑 harness 验证。
4. 把新盐表替换进 `thunder.zig` 的 `web_algorithms_str`，单测自动回归。

---

## 5. 已排除的弯路

* `service-device-sign.b8991286b9c3cbc6214a.js`（`ds.js`）名字误导：内容是 OAuth2
  common-sdk（模块 726），与签名器无关。
* `amaze` 算法接口 `risk-account-ssl.office.k8s.xunlei.cn/amaze/v1.0/algorithms`：
  三个网络出口 TCP 全不通；且只服务 `BEGIN_FUN_FILE_PAN/XLpan` 那套配置，与
  `pan.xunlei.com` 无关。
* 页面无算法缓存（localStorage / sessionStorage / SW / Cache API 均无）。
* 无 WASM：全部相关分片里 `WebAssembly` / `instantiate` / `.wasm` / `crypto.subtle`
  出现次数均为 0。
* 不需要伪装 Chrome：数美看 TLS/JA3 指纹，Zig std.http 的指纹与 Chrome 天然不同，
  挂 Chrome UA 反而更可疑。**网页版路线不过数美**，UA 用真实浏览器 UA 即可。

---

## 6. 旧 Thunder 驱动为何在光猫上不可用

（完整版见 STATUS §48，这里只留结论）

1. 首登必被 `review_panel`（1007 / verifyType MEA），挑战类型随机。
2. `creditkey` 一次性：登录成功那刻即被消耗，「一次验证长期免验证」不成立。
3. 挑战/信任按**发起 IP** 绑定：家宽解的 key 在光猫出口（139.227.20.164）无效。
4. 合成事件拖滑块服务端虽返成功并换新 key，设备用仍 `NeedVerify`；只有真人操作授予信任。
5. `ThunderExpert` + 账号密码能登录成功，但 `/v1/auth/signin/token` **不返回 refresh_token**
   ⇒ 安卓端拿不到长期令牌。
6. 反复重试会把账号打进风控（`shield_reject: Operation too frequent`），需数小时冷却。

⇒ 结论：安卓 SDK 路线在固定 IP 的设备上不可持续，**必须换网页版 refresh_token**。

---

## 7. thunder_web 驱动设计

### 7.1 为什么不是新文件

`thunder.zig` 的 API 层（`drive/v1/files`、上传、S3 分片、rename/move/remove/copy）
与网页版**完全共用**，差异只在「认证 + 签名」。所以实现为**同一文件的第三个 factory**
（`Variant.web`），与 `factory`(Thunder) / `expert_factory`(ThunderExpert) 并列。

| factory | key | 登录 | 签名 |
|---|---|---|---|
| `factory` | `Thunder` | 用户名密码（硬编码） | 安卓算法表 |
| `expert_factory` | `ThunderExpert` | user / refresh_token | 算法表 或 固定 sign |
| `web_factory` | `ThunderWeb` | **手机号+密码自动登录**（网页 OAuth），refresh 优先 | **网页 15 盐** |

### 7.2 配置项

| 键 | 默认 | 说明 |
|---|---|---|
| `username` | — | 迅雷账号（手机号/邮箱）。**填它就能只录一次** |
| `password` | — | 登录密码 |
| `refresh_token` | 空 | 可选。有就优先用；失效自动回落到账号密码重登 |
| `client_id` | `Xqp0kJBXWhwaTpB6` | 网页版 cid，别改成安卓的 |
| `client_version` | `1.93.12` | 与盐表版本绑定，换版本要同步换盐 |
| `package_name` | `pan.xunlei.com` | 同时充当签名 base 里的 host |
| `device_id` | 空 | 留空则生成 32-hex 并持久化 |
| `algorithms` | 15 盐 | 一般不用改 |
| `space` / `root_folder_id` | 空 | 同安卓 |
| `user_agent` | Chrome UA | 网页版接口用 |

### 7.3 续期模型（为什么只需录一次账号密码）

```
init:
  refresh_token 非空 ? ──refresh 成功──▶ 用返回的令牌
        │                     └─失败─┐
        └─空──────────────────────────┴──▶ webLogin(手机号+密码)
                                             └─▶ 新 access_token + refresh_token
                                                   └─▶ 落盘 refresh_token

运行期 error_code ∈ {4122,4121,10,16}: refreshFlow
  网页版：refresh 失败**不**报错，直接 webLogin 重登（用户无感）
```

要点：

* refresh grant 不过风控；实测令牌可重复使用（§2.2），但仍每次落盘。
* 网页登录（§2.5）无短信、无滑块 ⇒ 令牌链断在任何一环都能自愈。
* 安卓变体的「自愈」是 core login（会被数美拦）；网页版的自愈是 OAuth 表单登录
  （不过数美）—— 这是两者可靠性的根本差别。
* `webUsername()` 负责把 `18616132763` 规范成 `+86 18616132763`。
* 网页变体**不做** core login 回退。
* captcha token 缓存 **300s**，提前 ~60s 主动刷新（`error_code==9` 的重试路径保留作兜底）。
* 业务请求带 `X-Captcha-Token` + `X-Device-Id` + `X-Client-Id` / `X-Client-Version`（已有）。
* 单测钉死黄金向量（§3.3），盐表一改就红。

---

## 8. 验证状态 / 未完成 / 风险

### 8.1 已通过（2026-10-20 22:30）

| 层级 | 结果 |
|---|---|
| 签名离线复算 | 命中浏览器黄金对（Node + Python 双实现） |
| 签名在线 | `captcha/init` → 200 + captcha_token |
| 全链路（本机） | refresh → captcha → `files`（真实目录）→ `about`，全 200 |
| **驱动真机**（设备隔离实例 `:15399`） | `status=work`；`fs/list` 出 3 个目录；`mkdir`/`rename`/`remove` 全 200 |
| 上传 / 直链 / 下载 | `fs/put` 200 → S3 PUT 200 → 列表可见 → 直链 `GET` 200 且**内容逐字节一致** → 删除 200 |
| 打包机单测 | **435/435**，aarch64 1,308,080 B |

> 注 1：`fs/list` 出 3 项而探针出 20 项，是因为驱动按 Go 的行为带了
> `filters={"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}`；
> 探针没带过滤，把回收站里的 e2e 目录也列出来了。**不是 bug**。
>
> 注 2：**上传后有秒级最终一致性延迟**（同 189 个人云）：`put` 返回 200 后立刻
> `list` 看不到文件，等几秒才出现。回归脚本已内置轮询，别把它当成上传失败。

### 8.2 生产部署（2026-10-20 22:57）

- 生产二进制已换成含 `ThunderWeb` 的版本（1,314,560 B，sha256 `3f361898…`）。
- `/thunderweb` = `ThunderWeb`，**addition 里只填了 `username` + `password`**，
  驱动自动走 §2.5 四步登录，拿到令牌并把 `refresh_token` 落盘 ⇒ `status=work`。
- 重启一次后无需任何人工输入即恢复 `work`（续期链验证通过）。
- 生产上传 → 直链 → 下载内容逐字节一致 → 删除，全 200。
- `/thunder`（ThunderExpert，安卓）仍为 `errored / userinfo_expired` —— 正是
  本次要取代的那条路线；两个挂载点并存，互不影响。

### 8.3 未完成
- [ ] 光猫出口 IP（139.227.20.164）下 captcha token 是否仍被接受（是否绑 IP）：
      本次 e2e 是在光猫上跑的，**已隐含验证通过**（隔离实例就在光猫上）。
- [ ] 下载（`link`）与上传（S3 分片）走的是与安卓驱动同一套代码，未单独针对
      网页版 access_token 复测；如需 100% 把握，跑一次 `--write` 之外的上传。

### 8.4 风险

* 盐表随前端发版失效 ⇒ 驱动会在错误信息里直接指向本文 §4.3。
* 网页 refresh_token 的**有效期**未确认（access_token 12h；refresh 未见过期提示）。
  若某天报 `invalid_grant`，重新登录网页版取新 token 即可。
* 账号对登录/刷新有频率限制，回归时别在循环里重建存储。
