package thunder_web

// 迅雷云盘·网页版（pan.xunlei.com）—— 请求核心与纯函数。
//
// 本包是 Zig 侧 `zig-src/src/drivers/thunder.zig` 的 `Variant.web` 分支的 Go
// 移植（逆向记录：zig-src/docs/THUNDER_WEB_RE_2026-10-20.md）。与安卓家族
// （drivers/thunder）的差异只有两处，全部集中在本文件：
//
//   1. `refreshCaptchaToken` 的请求体是**浏览器形态**：不带 captcha_token /
//      redirect_uri，meta 里带三个空占位（username/phone_number/email）。
//      安卓形态的对照实现见 drivers/thunder/util.go。
//   2. `captcha_sign` 用网页版 15 盐表自签（盐表逆向自前端 bundle），所以
//      用户不再需要像 ThunderBrowser 那样手动从浏览器抄 captcha_sign。
//
// 与安卓家族逐字一致的部分（错误信封判定、GetAction、generateDeviceSign、
// GetCaptchaSign 算法骨架）直接照抄 drivers/thunder/util.go，两边同时改动时
// 保持同步。

import (
	"crypto/md5"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/pkg/utils"
	"github.com/go-resty/resty/v2"
)

const (
	API_URL             = "https://api-pan.xunlei.com/drive/v1"
	FILE_API_URL        = API_URL + "/files"
	XLUSER_API_BASE_URL = "https://xluser-ssl.xunlei.com"
	XLUSER_API_URL      = XLUSER_API_BASE_URL + "/v1"
)

const (
	FOLDER = "drive#folder"
	FILE   = "drive#file"
)

const UPLOAD_TYPE_RESUMABLE = "UPLOAD_TYPE_RESUMABLE"

// review_data 里 devicesign 用的 appId/appKey 与安卓客户端同款
// （drivers/thunder/util.go 的 APPID/APPKey）。
const (
	APPID  = "40"
	APPKey = "34a062aaa22f906fca4fefe9fb3a3021"
)

// ---------------------------------------------------------------------------
// 网页版（pan.xunlei.com）客户端参数
// ---------------------------------------------------------------------------
// 与网页前端 utils-initial 配置模块 32 的 pan.xunlei.com 条目逐字一致
// （RE 文档 §2.1）。

const (
	WebClientID      = "Xqp0kJBXWhwaTpB6"
	WebClientSecret  = "" // 网页版 refresh grant 不需要 client_secret（实测空串即可）
	WebClientVersion = "1.93.12"
	// 网页版的 package_name 同时充当 captcha_sign base 里的 location.host，
	// 两者都是 pan.xunlei.com，所以签名算法骨架不用改。
	WebPackageName = "pan.xunlei.com"
	WebUserAgent   = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)

// `i.xunlei.com` 账号中心（SSO）的 client_id。**不是** pan 的那个：
// signin 必须用它，authorize/token 才用 WebClientID（RE 文档 §2.5）。
const SSOClientID = "XW5SkOhLDjnOZP7J"

const (
	WebRedirectURI = "https://pan.xunlei.com/login?sso_sign_in_in_iframe="
	WebSignOutURI  = "https://pan.xunlei.com/login?sso_sign_out="
	WebScope       = "profile offline pan sso user"
)

// 网页版签名盐表：15 轮 `md5(prev + salt)`，顺序即调用顺序。
// ⚠️ 前端重新打包就会变。失效时用 tools/thunder_web_sign_harness.js 重取
// （步骤见 RE 文档 §4.3），改这里即可，driver_test.go 的黄金向量会兜底。
var WebAlgorithms = []string{
	"QT5gqd1eSINZe+K",
	"9TafMwqVWgh45hLntDm6HLcOXE",
	"L0nOen58D2cCsOSRaRRYt1Mj+XTVM",
	"gu4CPVQhQU",
	"X/6jue5AUYt56MbqopFv",
	"EuBhpIhdLUh37zvuzrOA3t8HL2HBtlCw",
	"3LSRoSaxM6YKIbhtx7RxaBpf",
	"OOnBZYkw3kRrfGD8",
	"ytWf",
	"psUOt",
	"+0izM",
	"tF53Ovo+aqLG00zho+b",
	"OnrcYC9y8",
	"cv2tHyrFOPhJUFkk6KhecIHJDUKK",
	"NnkQ2lQy",
}

const WebAlgorithmsStr = "QT5gqd1eSINZe+K,9TafMwqVWgh45hLntDm6HLcOXE,L0nOen58D2cCsOSRaRRYt1Mj+XTVM,gu4CPVQhQU,X/6jue5AUYt56MbqopFv,EuBhpIhdLUh37zvuzrOA3t8HL2HBtlCw,3LSRoSaxM6YKIbhtx7RxaBpf,OOnBZYkw3kRrfGD8,ytWf,psUOt,+0izM,tF53Ovo+aqLG00zho+b,OnrcYC9y8,cv2tHyrFOPhJUFkk6KhecIHJDUKK,NnkQ2lQy"

// 网页版 captcha token 实测 `expires_in = 300` 秒；提前 60 秒主动换新，
// 而不是等业务接口报 `error_code == 9` 再补救（那会多烧一次往返）。
const (
	WebCaptchaTTL  = 300 * time.Second
	WebCaptchaSkew = 60 * time.Second
)

// GetAction 与安卓家族同一个正则：`://[^/]+((/[^/\s?#]+)*)` 取 path 部分，
// 去掉 query/fragment。
func GetAction(method string, url string) string {
	urlpath := regexp.MustCompile(`://[^/]+((/[^/\s?#]+)*)`).FindStringSubmatch(url)[1]
	return method + ":" + urlpath
}

// Common 请求核心。字段集与 drivers/thunder 的 Common 一致；网页版不用的
// creditKey / Timestamp / CaptchaSign 保留字段以维持家族同构（恒为空值）。
type Common struct {
	client *resty.Client

	captchaToken string
	// 网页版专属：captcha token 的取得时刻，供 300 秒 TTL 的主动续期判断。
	captchaAt time.Time

	creditKey string

	// 签名相关。网页版恒走算法表（Timestamp/CaptchaSign 留空不参与）。
	Algorithms             []string
	Timestamp, CaptchaSign string

	// 必要值，签名相关
	DeviceID          string
	ClientID          string
	ClientSecret      string
	ClientVersion     string
	PackageName       string
	UserAgent         string
	DownloadUserAgent string
	Space             string

	// 验证码 token 刷新成功回调（把新 token 写回存储配置）
	refreshCTokenCk func(token string)
}

func (c *Common) SetCaptchaToken(captchaToken string) {
	c.captchaToken = captchaToken
}

func (c *Common) GetCaptchaToken() string {
	return c.captchaToken
}

func (c *Common) SetCreditKey(creditKey string) {
	c.creditKey = creditKey
}

func (c *Common) GetCreditKey() string {
	return c.creditKey
}

// captchaSignAt GetCaptchaSign 的纯函数形态（可单测）：
// `"1." + md5(...md5(clientID+clientVersion+packageName+deviceID+timestamp+alg))`。
// 与安卓家族 GetCaptchaSign 的循环体逐字一致，只是抽出来让黄金向量测试
// 不用碰 time.Now。
func captchaSignAt(clientID, clientVersion, packageName, deviceID, timestamp string, algorithms []string) string {
	str := fmt.Sprint(clientID, clientVersion, packageName, deviceID, timestamp)
	for _, algorithm := range algorithms {
		str = utils.GetMD5EncodeStr(str + algorithm)
	}
	return "1." + str
}

// GetCaptchaSign 获取验证码签名（与 drivers/thunder/util.go 的实现逐字一致）。
func (c *Common) GetCaptchaSign() (timestamp, sign string) {
	if len(c.Algorithms) == 0 {
		return c.Timestamp, c.CaptchaSign
	}
	timestamp = fmt.Sprint(time.Now().UnixMilli())
	sign = captchaSignAt(c.ClientID, c.ClientVersion, c.PackageName, c.DeviceID, timestamp, c.Algorithms)
	return
}

// RefreshCaptchaTokenAtLogin 刷新验证码 token（登录后，业务请求前）。
func (c *Common) RefreshCaptchaTokenAtLogin(action, userID string) error {
	metas := map[string]string{
		// 浏览器实测带三个空占位（RE 文档 §2.4）—— 照抄，别"优化"掉。
		"username":       "",
		"phone_number":   "",
		"email":          "",
		"client_version": c.ClientVersion,
		"package_name":   c.PackageName,
		"user_id":        userID,
	}
	metas["timestamp"], metas["captcha_sign"] = c.GetCaptchaSign()
	return c.refreshCaptchaToken(action, metas)
}

// refreshCaptchaToken 刷新验证码 token。
//
// 与安卓形态（drivers/thunder/util.go）的两个差异，均对齐浏览器实际抓包
// （RE 文档 §2.4）：
//   - 不带 `captcha_token`（安卓版是「拿旧 token 续期」，网页版没有这一步）；
//   - 不带 `redirect_uri`（那是安卓 SDK 的 `xlaccsdk01://` 回调）。
func (c *Common) refreshCaptchaToken(action string, metas map[string]string) error {
	param := CaptchaTokenRequest{
		Action:   action,
		ClientID: c.ClientID,
		DeviceID: c.DeviceID,
		Meta:     metas,
	}
	req := c.client.R().SetHeaders(map[string]string{
		"user-agent":       c.UserAgent,
		"accept":           "application/json;charset=UTF-8",
		"x-device-id":      c.DeviceID,
		"x-client-id":      c.ClientID,
		"x-client-version": c.ClientVersion,
	}).SetBody(param)
	res, err := req.Execute(http.MethodPost, XLUSER_API_URL+"/shield/captcha/init")
	if err != nil {
		return err
	}

	var e ErrResp
	utils.Json.Unmarshal(res.Body(), &e)
	if e.IsError() {
		// 网页版最常见的失败是盐表过期（前端重新打包）。给一句能直接查的指引。
		if strings.Contains(res.String(), "captcha_sign") {
			return fmt.Errorf("captcha_sign rejected — xunlei likely rebuilt its frontend and the web salt table is stale; see zig-src/docs/THUNDER_WEB_RE_2026-10-20.md §4.3. upstream: %s", snippet(res.Body()))
		}
		return &e
	}

	var resp CaptchaTokenResponse
	utils.Json.Unmarshal(res.Body(), &resp)

	// 给了 url 就是"要人去过验证码"。
	if resp.Url != "" {
		return fmt.Errorf("need verify: %s", resp.Url)
	}
	if resp.CaptchaToken == "" {
		return fmt.Errorf("empty captchaToken")
	}

	if c.refreshCTokenCk != nil {
		c.refreshCTokenCk(resp.CaptchaToken)
	}
	c.captchaToken = resp.CaptchaToken
	c.captchaAt = time.Now()
	return nil
}

// Request 只有基础信息的请求。错误信封判定（只看 body 里的
// `{error_code, error, error_description}`，**完全不看** HTTP 状态码）与
// drivers/thunder/util.go 的 Common.Request 逐字一致。
func (c *Common) Request(url, method string, callback base.ReqCallback, resp interface{}) ([]byte, error) {
	req := c.client.R().SetHeaders(map[string]string{
		"user-agent":       c.UserAgent,
		"accept":           "application/json;charset=UTF-8",
		"x-device-id":      c.DeviceID,
		"x-client-id":      c.ClientID,
		"x-client-version": c.ClientVersion,
	})

	if callback != nil {
		callback(req)
	}
	if resp != nil {
		req.SetResult(resp)
	}
	res, err := req.Execute(method, url)
	if err != nil {
		return nil, err
	}

	var erron ErrResp
	utils.Json.Unmarshal(res.Body(), &erron)
	if erron.IsError() {
		// review_panel 表示需要人工验证
		if erron.ErrorMsg == "review_panel" {
			return nil, c.getReviewData(res)
		}

		return nil, &erron
	}

	return res.Body(), nil
}

// getReviewData 获取验证所需内容。
//
// ⚠️ 前端把 error_msg 当**纯文本**渲染（不解析 HTML），所以这里不能学安卓
// 家族包 HTML 外壳——否则用户看到的就是"全是代码"。信息一个不少：JSON 仍
// 完整内嵌（官方 credit_key 流程要照抄含大括号的全部内容），指导语三行中文
// 照着做即可。与 Zig thunder.zig 的 reviewDetail 逐字对齐。
//
// 注：网页版 addition 没有 credit_key 字段（Zig 的 web 变体同样共用这段文案），
// 真触发 review 时按文案操作完后需要改用安卓家族驱动，或等上游开放网页侧的
// 信任密钥通道。
func (c *Common) getReviewData(res *resty.Response) error {
	var reviewResp LoginReviewResp
	if err := utils.Json.Unmarshal(res.Body(), &reviewResp); err != nil {
		return err
	}

	deviceSign := generateDeviceSign(c.DeviceID, c.PackageName)

	reviewData := ReviewData{
		Creditkey:  reviewResp.Creditkey,
		Reviewurl:  reviewResp.Reviewurl + "&deviceid=" + deviceSign,
		Deviceid:   deviceSign,
		Devicesign: deviceSign,
	}
	reviewDataJSON, _ := json.MarshalIndent(reviewData, "", "  ")

	return fmt.Errorf(`本次登录需要验证（新设备 / 风控）。
把下面这段 JSON（含大括号）复制到 https://i.xunlei.com/xlcaptcha/android.html ，
按 F12 打开控制台执行 reviewCb(<粘贴>) ；完成后把得到的 creditkey 填到本存储的
「信用密钥」再保存即可。
%s`, string(reviewDataJSON))
}

// generateDeviceSign 与 drivers/thunder/util.go 逐字一致：
// `div101.<deviceID><md5(hex(sha1(deviceID+package+APPID+APPKey)))>`。
func generateDeviceSign(deviceID, packageName string) string {
	signatureBase := fmt.Sprintf("%s%s%s%s", deviceID, packageName, APPID, APPKey)

	sha1Hash := sha1.New()
	sha1Hash.Write([]byte(signatureBase))
	sha1String := hex.EncodeToString(sha1Hash.Sum(nil))

	md5Hash := md5.New()
	md5Hash.Write([]byte(sha1String))
	md5String := hex.EncodeToString(md5Hash.Sum(nil))

	return fmt.Sprintf("div101.%s%s", deviceID, md5String)
}

// WebUsername 网页登录的账号规范化：`/v1/auth/signin` 要求手机号形如
// `+86 138...`（抓包实测，带空格）。邮箱 / 已带国家码的原样返回。
func WebUsername(u string) string {
	t := strings.Trim(u, " \t\r\n")
	if t == "" {
		return t
	}
	if t[0] == '+' {
		return t
	}
	if strings.Contains(t, "@") {
		return t
	}
	allDigit := true
	for _, c := range t {
		if c < '0' || c > '9' {
			allDigit = false
			break
		}
	}
	if allDigit && len(t) == 11 {
		return "+86 " + t
	}
	return t
}

// ---------------------------------------------------------------------------
// PKCE（RFC 7636 S256）—— 网页登录第 3 步用。
// ---------------------------------------------------------------------------

// 与浏览器一致的字母数字表（Zig randommod.randomString 同款）。
const pkceCharset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

// randomString n 位字母数字，取自 crypto/rand。
func randomString(n int) (string, error) {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	out := make([]byte, n)
	for i, b := range buf {
		out[i] = pkceCharset[int(b)%len(pkceCharset)]
	}
	return string(out), nil
}

// pkceChallenge `base64url(sha256(verifier))` 无填充，43 字符。
func pkceChallenge(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// randomHex32 32 位小写 hex（16 随机字节 → hex），与网页前端 deviceID 的
// 形态一致（前端就是 crypto 随机生成后存 localStorage；这里生成后落盘）。
func randomHex32() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}

// snippet 错误信息里的 body 摘录，最长 300 字节（与 Zig 一致）。
func snippet(b []byte) string {
	if len(b) > 300 {
		return string(b[:300])
	}
	return string(b)
}
