package thunder_web

// 迅雷云盘·网页版驱动 —— Zig `src/drivers/thunder.zig` `Variant.web` 分支的
// Go 移植。
//
// 与上游安卓家族（drivers/thunder）的本质区别：**不走 xluser.core.login**。
// 上游三个迅雷驱动全走安卓 core login，必被数美风控拦；本驱动改用网页
// （pan.xunlei.com）OAuth 的 refresh_token，并用逆向出的网页签名盐表自签
// `captcha_sign`，因此：
//
//   * 用户只需录一次手机号密码（或直接填 refresh_token），令牌链断在任何
//     一环都能自动恢复（refresh 失败 → 静默重走网页登录，用户无感）；
//   * 无需人工过滑块/短信，也无需像 ThunderBrowser 那样从浏览器抄
//     captcha_sign + timestamp。
//
// 登录四步（纯 HTTP，抓包 2026-10-20，见 RE 文档 §2.5）：
//
//	1) POST /v1/shield/captcha/init  SSO client，action=POST:/v1/auth/signin
//	2) POST /v1/auth/signin          带 X-Captcha-Token ⇒ SSO access_token
//	3) POST /v1/user/authorize       Bearer SSO，PKCE S256 ⇒ code（120 秒有效）
//	4) POST /v1/auth/token           authorization_code + code_verifier ⇒ pan 令牌
//
// 文件操作（List/Link/MakeDir/Move/Rename/Copy/Remove/Put/GetDetails）与
// drivers/thunder 的 XunLeiCommon 逐字一致——同一个 drive/v1 API，只有
// 认证与签名不同。

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/OpenListTeam/OpenList/v4/drivers/base"
	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/errs"
	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
	"github.com/OpenListTeam/OpenList/v4/internal/stream"
	"github.com/OpenListTeam/OpenList/v4/pkg/utils"
	hash_extend "github.com/OpenListTeam/OpenList/v4/pkg/utils/hash"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/s3/s3manager"
	"github.com/go-resty/resty/v2"
	log "github.com/sirupsen/logrus"
)

// ThunderWeb 迅雷云盘（网页版）。
type ThunderWeb struct {
	*WebCommon
	model.Storage
	Addition

	identity string
}

func (x *ThunderWeb) Config() driver.Config {
	return config
}

func (x *ThunderWeb) GetAddition() driver.Additional {
	return &x.Addition
}

// Init 对齐 Zig initExpert 的 web 分支。
//
// 顺序是刻意的（Zig 特意调过序，见 Addition.GetIdentity 的注释）：
// 默认值 → device_id 落定并落盘 → identity → （变了 / 未登录才）登录。
func (x *ThunderWeb) Init(ctx context.Context) (err error) {
	if x.WebCommon == nil {
		x.WebCommon = &WebCommon{Common: &Common{client: base.NewRestyClient()}}
	}
	xc := x.WebCommon
	xc.mu.Lock()
	defer xc.mu.Unlock()

	// 0. addition 空字段 → 网页客户端默认值（Zig defaultsFor(.web)）。
	//    写回 addition：让 identity 与后续落盘的 addition 形态一致。
	if x.Addition.ClientID == "" {
		x.Addition.ClientID = WebClientID
	}
	if x.Addition.ClientVersion == "" {
		x.Addition.ClientVersion = WebClientVersion
	}
	if x.Addition.PackageName == "" {
		x.Addition.PackageName = WebPackageName
	}
	if x.Addition.UserAgent == "" {
		x.Addition.UserAgent = WebUserAgent
	}
	if x.Addition.Algorithms == "" {
		x.Addition.Algorithms = WebAlgorithmsStr
	}

	// 1. device id：配置优先，否则随机 32 位 hex 并落盘。
	//    网页版没有「由账号派生」这回事（前端就是随机生成存 localStorage），
	//    稳定即可。
	xc.DeviceID = x.Addition.DeviceID
	if xc.DeviceID == "" {
		deviceID, err := randomHex32()
		if err != nil {
			return err
		}
		xc.DeviceID = deviceID
		x.Addition.DeviceID = deviceID
		op.MustSaveDriverStorage(x)
	}
	xc.ClientID = x.Addition.ClientID
	xc.ClientSecret = WebClientSecret
	xc.ClientVersion = x.Addition.ClientVersion
	xc.PackageName = x.Addition.PackageName
	xc.UserAgent = x.Addition.UserAgent
	xc.DownloadUserAgent = x.Addition.UserAgent // 网页版下载同 UA
	xc.Space = x.Addition.Space
	xc.Algorithms = strings.Split(x.Addition.Algorithms, ",")
	if x.Addition.CaptchaToken != "" {
		// 与 Zig 一致：网页变体不 trim captcha_token（只有安卓 normal 会 trim）。
		xc.SetCaptchaToken(x.Addition.CaptchaToken)
	}

	xc.refreshCTokenCk = func(token string) {
		x.Addition.CaptchaToken = token
		op.MustSaveDriverStorage(x)
	}
	xc.refreshTokenFunc = func() error {
		token, err := xc.loginOrRefreshLocked(x.Addition.RefreshToken, x.Addition.Username, x.Addition.Password)
		if err != nil {
			return err
		}
		x.SetTokenResp(token)
		return nil
	}

	// 2. identity —— 此时 device_id 与各默认值均已落定，首轮即稳定。
	identity := x.Addition.GetIdentity()
	if x.identity != identity || !xc.isLoginLocked() {
		x.identity = identity
		token, err := xc.loginOrRefreshLocked(x.Addition.RefreshToken, x.Addition.Username, x.Addition.Password)
		if err != nil {
			return err
		}
		x.SetTokenResp(token)
	}
	return nil
}

func (x *ThunderWeb) Drop(ctx context.Context) error {
	return nil
}

// SetTokenResp 轮换后的 refresh_token 必须写回配置并落盘：万一哪天上游开始
// 真轮换（2026-10-20 实测暂不轮换），不写回就等于「用一次就把自己锁在门外」。
func (x *ThunderWeb) SetTokenResp(token *TokenResp) {
	x.WebCommon.SetTokenResp(token)
	if token != nil && token.RefreshToken != "" {
		x.Addition.RefreshToken = token.RefreshToken
		op.MustSaveDriverStorage(x)
	}
}

// ---------------------------------------------------------------------------
// 协议核心
// ---------------------------------------------------------------------------

// WebCommon 网页版协议核心（Zig 侧 Thunder struct 的 web 变体分支）。
type WebCommon struct {
	*Common
	*TokenResp

	// 一把锁覆盖全部：token / captchaToken / captchaAt 都是共享可变状态，
	// 而且刷新本身要发请求。Zig 侧同样是一把 req_mu；Go 上游家族反而没有
	// 锁（并发刷新会互踩，见 RE 文档 §50.4 的三实例事故），这里按 Zig 补上。
	// 只在导出入口（Request / IsLogin / Init）上锁，内部 *_Locked 一律不加。
	mu sync.Mutex

	refreshTokenFunc func() error
}

// maxRefreshDepth Go 家族的 Request 是无界递归（刷新成功但上游仍报错时
// 一直重试）；这里对齐 Zig 限深 3，防打转。
const maxRefreshDepth = 3

// Request 携带 Authorization + X-Captcha-Token 的请求，带自动重试。
//
// 重试矩阵与安卓家族逐条对齐：
//   - `error_code == 0` → 当成功（即便 body 里带了 error 文本——上游行为
//     如此，调用方靠 resty 已填充的 result 对象拿数据）；
//   - `4122/4121/10/16` → 走令牌链自愈（refresh 失败则网页重登）后重试；
//   - `9` → 刷新 captcha_token 后重试；
//   - 其余 → 失败。
//
// 网页版差异：发请求前先确保 captcha token 新鲜（300 秒 TTL，提前 60 秒
// 主动换），不等 `error_code == 9` 兜底。
func (xc *WebCommon) Request(url, method string, callback base.ReqCallback, resp interface{}) ([]byte, error) {
	xc.mu.Lock()
	defer xc.mu.Unlock()
	return xc.requestLocked(url, method, callback, resp, 0)
}

func (xc *WebCommon) requestLocked(url, method string, callback base.ReqCallback, resp interface{}, depth int) ([]byte, error) {
	if xc.TokenResp == nil {
		return nil, errs.EmptyToken
	}
	if err := xc.ensureCaptchaLocked(GetAction(method, url)); err != nil {
		return nil, err
	}
	data, err := xc.Common.Request(url, method, func(req *resty.Request) {
		req.SetHeaders(map[string]string{
			"Authorization":   xc.Token(),
			"X-Captcha-Token": xc.GetCaptchaToken(),
		})
		if callback != nil {
			callback(req)
		}
	}, resp)
	if err == nil {
		return data, nil
	}
	errResp, ok := err.(*ErrResp)
	if !ok {
		// review_panel（人工验证文案）/ 网络错误，直接透出。
		return nil, err
	}
	if depth >= maxRefreshDepth {
		return nil, err
	}
	switch errResp.ErrorCode {
	case 0:
		// data 为 nil，但 resty 已把 body 填进调用方的 resp 对象——与家族一致。
		return data, nil
	case 4122, 4121, 10, 16:
		if xc.refreshTokenFunc == nil {
			return nil, err
		}
		if err = xc.refreshTokenFunc(); err != nil {
			return nil, err
		}
	case 9:
		if err = xc.RefreshCaptchaTokenAtLogin(GetAction(method, url), xc.TokenResp.UserID); err != nil {
			return nil, err
		}
	default:
		return nil, err
	}
	return xc.requestLocked(url, method, callback, resp, depth+1)
}

// ensureCaptchaLocked 网页版 captcha token 只活 300 秒（实测
// `expires_in:300`），临期（超过 240 秒）就主动换新，省一次业务往返。
func (xc *WebCommon) ensureCaptchaLocked(action string) error {
	if xc.captchaToken != "" && !xc.captchaAt.IsZero() &&
		time.Since(xc.captchaAt) < WebCaptchaTTL-WebCaptchaSkew {
		return nil
	}
	if xc.TokenResp == nil {
		return errs.EmptyToken
	}
	return xc.RefreshCaptchaTokenAtLogin(action, xc.TokenResp.UserID)
}

// IsLogin GET /user/me 只要不报错就算登录态。
func (xc *WebCommon) IsLogin() bool {
	xc.mu.Lock()
	defer xc.mu.Unlock()
	return xc.isLoginLocked()
}

func (xc *WebCommon) isLoginLocked() bool {
	if xc.TokenResp == nil {
		return false
	}
	_, err := xc.requestLocked(XLUSER_API_URL+"/user/me", http.MethodGet, nil, nil, 0)
	return err == nil
}

// SetTokenResp 设置令牌（轮换的 refresh_token 由 ThunderWeb.SetTokenResp
// 负责写回配置）。
func (xc *WebCommon) SetTokenResp(tr *TokenResp) {
	xc.TokenResp = tr
}

// loginOrRefreshLocked 有 refresh_token 就先 refresh，失败再走手机号密码
// 重登——这就是「只录一次」的自愈点：令牌链断在任何一环都能恢复，用户无感。
func (xc *WebCommon) loginOrRefreshLocked(refreshToken, username, password string) (*TokenResp, error) {
	if refreshToken != "" {
		token, err := xc.refreshTokenLocked(refreshToken)
		if err == nil {
			return token, nil
		}
		log.Warnf("[thunder_web] refresh_token 失效（%v），改用手机号密码重新登录", err)
	}
	return xc.webLoginLocked(username, password)
}

// refreshTokenLocked `grant_type=refresh_token`。网页版 refresh 不需要
// client_secret（实测空串即可）；空 refresh_token 视为上游没给新令牌。
func (xc *WebCommon) refreshTokenLocked(refreshToken string) (*TokenResp, error) {
	var resp TokenResp
	_, err := xc.Common.Request(XLUSER_API_URL+"/auth/token", http.MethodPost, func(req *resty.Request) {
		req.SetBody(&base.Json{
			"grant_type":    "refresh_token",
			"refresh_token": refreshToken,
			"client_id":     xc.ClientID,
			"client_secret": xc.ClientSecret,
		})
	}, &resp)
	if err != nil {
		return nil, err
	}
	normalizeTokenType(&resp)
	if resp.RefreshToken == "" {
		return nil, errs.EmptyToken
	}
	return &resp, nil
}

// webLoginLocked 网页版「手机号 + 密码」登录，产出 pan 令牌（含
// refresh_token）。四步纯 HTTP，**无短信、无滑块、不需要 captcha_sign**
// （这个 action 的 captcha init 只认手机号，不校验签名——这正是网页登录
// 能程序化的根本原因）。
func (xc *WebCommon) webLoginLocked(username, password string) (*TokenResp, error) {
	user := WebUsername(username)
	if user == "" || password == "" {
		return nil, fmt.Errorf("网页版登录需要 username + password（也可以直接填 refresh_token）")
	}

	// ---- 1. SSO captcha init（不校验 captcha_sign；失败不致命，空着继续）----
	captchaToken := ""
	if res, err := xc.webPost(XLUSER_API_URL+"/shield/captcha/init", base.Json{
		"client_id": SSOClientID,
		"action":    "POST:/v1/auth/signin",
		"device_id": xc.DeviceID,
		"meta":      base.Json{"phone_number": user},
	}, "", ""); err == nil && res.StatusCode() < 300 {
		var r1 CaptchaTokenResponse
		if utils.Json.Unmarshal(res.Body(), &r1) == nil {
			captchaToken = r1.CaptchaToken
		}
	}

	// ---- 2. signin ⇒ SSO access_token ----
	res2, err := xc.webPost(XLUSER_API_URL+"/auth/signin", base.Json{
		"username":  user,
		"password":  password,
		"client_id": SSOClientID,
	}, "", captchaToken)
	if err != nil {
		return nil, err
	}
	if res2.StatusCode() >= 300 {
		return nil, fmt.Errorf("web signin HTTP %d: %s", res2.StatusCode(), snippet(res2.Body()))
	}
	var sso SignInResp
	if err := utils.Json.Unmarshal(res2.Body(), &sso); err != nil {
		return nil, err
	}
	if sso.AccessToken == "" {
		return nil, fmt.Errorf("%s", snippet(res2.Body()))
	}

	// ---- 3. authorize（PKCE S256）⇒ code ----
	// verifier 32 位字母数字（与浏览器一致）；challenge 43 字符。
	verifier, err := randomString(32)
	if err != nil {
		return nil, err
	}
	res3, err := xc.webPost(XLUSER_API_URL+"/user/authorize", base.Json{
		"client_id":             xc.ClientID,
		"response_type":         "code",
		"redirect_uri":          WebRedirectURI,
		"state":                 "state-" + verifier[:12],
		"scope":                 WebScope,
		"code_challenge":        pkceChallenge(verifier),
		"code_challenge_method": "S256",
		"sign_out_uri":          WebSignOutURI,
	}, sso.AccessToken, "")
	if err != nil {
		return nil, err
	}
	if res3.StatusCode() >= 300 {
		return nil, fmt.Errorf("web authorize HTTP %d: %s", res3.StatusCode(), snippet(res3.Body()))
	}
	var auth AuthorizeResp
	if err := utils.Json.Unmarshal(res3.Body(), &auth); err != nil {
		return nil, err
	}
	if auth.Code == "" {
		return nil, fmt.Errorf("%s", snippet(res3.Body()))
	}

	// ---- 4. authorization_code + verifier ⇒ pan 令牌 ----
	res4, err := xc.webPost(XLUSER_API_URL+"/auth/token", base.Json{
		"code":          auth.Code,
		"grant_type":    "authorization_code",
		"code_verifier": verifier,
		"redirect_uri":  WebRedirectURI,
		"client_id":     xc.ClientID,
	}, "", "")
	if err != nil {
		return nil, err
	}
	if res4.StatusCode() >= 300 {
		return nil, fmt.Errorf("web token HTTP %d: %s", res4.StatusCode(), snippet(res4.Body()))
	}
	var tok TokenResp
	if err := utils.Json.Unmarshal(res4.Body(), &tok); err != nil {
		return nil, err
	}
	normalizeTokenType(&tok)
	// 网页版必须有 refresh_token —— 它是后续所有自动续期的根。
	if tok.RefreshToken == "" {
		return nil, fmt.Errorf("web login 没返回 refresh_token")
	}
	log.Infof("[thunder_web] web login ok (user_id=%s)", tok.UserID)
	return &tok, nil
}

// webPost 网页 OAuth 端点专用 POST：自己拼头（要带 Bearer / X-Captcha-Token，
// 且**不能**像业务请求那样无条件塞 x-client-id——SSO 端点会拿到错的 client）。
// OAuth 端点按 HTTP 状态码判错（与业务端点只看错误信封不同），调用方自行检查
// StatusCode()。
func (xc *WebCommon) webPost(url string, body base.Json, bearer, captchaToken string) (*resty.Response, error) {
	req := xc.client.R().
		SetHeaders(map[string]string{
			"user-agent":   xc.UserAgent,
			"accept":       "application/json",
			"content-type": "application/json",
			"origin":       "https://pan.xunlei.com",
			"referer":      "https://pan.xunlei.com/",
			"x-device-id":  xc.DeviceID,
		}).
		SetBody(body)
	if bearer != "" {
		req.SetHeader("Authorization", "Bearer "+bearer)
	}
	if captchaToken != "" {
		req.SetHeader("X-Captcha-Token", captchaToken)
	}
	return req.Execute(http.MethodPost, url)
}

// normalizeTokenType token 响应偶发不带 token_type 时按 Bearer 处理
// （Authorization 头 = token_type + " " + access_token，空了就发不出去）。
func normalizeTokenType(t *TokenResp) {
	if t.TokenType == "" {
		t.TokenType = "Bearer"
	}
}

// ---------------------------------------------------------------------------
// 文件操作 —— 与 drivers/thunder 的 XunLeiCommon 逐字一致
// ---------------------------------------------------------------------------

func (xc *WebCommon) List(ctx context.Context, dir model.Obj, args model.ListArgs) ([]model.Obj, error) {
	files := make([]model.Obj, 0)
	var pageToken string
	for {
		var fileList FileList
		_, err := xc.Request(FILE_API_URL, http.MethodGet, func(r *resty.Request) {
			r.SetContext(ctx)
			r.SetQueryParams(map[string]string{
				"space":      xc.Space,
				"__type":     "drive",
				"refresh":    "true",
				"__sync":     "true",
				"parent_id":  dir.GetID(),
				"page_token": pageToken,
				"with_audit": "true",
				"limit":      "100",
				"filters":    `{"phase":{"eq":"PHASE_TYPE_COMPLETE"},"trashed":{"eq":false}}`,
			})
			// 挂在"远程设备"（space 非空）时，要这几个 with 参数
			if xc.Space != "" {
				r.SetQueryParamsFromValues(url.Values{
					"with": []string{
						"withCategoryDiskMountPath",
						"withCategoryDriveCachePath",
						"withCategoryHistoryDownloadPath",
						"withReadOnlyFS",
					},
				})
			}
		}, &fileList)
		if err != nil {
			return nil, err
		}

		for i := range fileList.Files {
			files = append(files, &fileList.Files[i])
		}

		if fileList.NextPageToken == "" {
			break
		}
		pageToken = fileList.NextPageToken
	}
	return files, nil
}

func (xc *WebCommon) Link(ctx context.Context, file model.Obj, args model.LinkArgs) (*model.Link, error) {
	var lFile Files
	_, err := xc.Request(FILE_API_URL+"/{fileID}", http.MethodGet, func(r *resty.Request) {
		r.SetContext(ctx)
		r.SetPathParam("fileID", file.GetID())
		r.SetQueryParam("space", xc.Space)
	}, &lFile)
	if err != nil {
		return nil, err
	}
	// 上游没给直链属于异常（比 Go 家族多一道检查，与 Zig 一致）：返回空 URL
	// 只会让下游报更难懂的错误。
	if lFile.WebContentLink == "" {
		return nil, fmt.Errorf("upstream returned an empty download url")
	}
	return &model.Link{
		URL: lFile.WebContentLink,
		Header: http.Header{
			"User-Agent": {xc.DownloadUserAgent},
		},
	}, nil
}

func (xc *WebCommon) MakeDir(ctx context.Context, parentDir model.Obj, dirName string) error {
	_, err := xc.Request(FILE_API_URL, http.MethodPost, func(r *resty.Request) {
		r.SetContext(ctx)
		r.SetBody(&base.Json{
			"kind":      FOLDER,
			"name":      dirName,
			"parent_id": parentDir.GetID(),
			"space":     xc.Space,
		})
	}, nil)
	return err
}

func (xc *WebCommon) Move(ctx context.Context, srcObj, dstDir model.Obj) error {
	_, err := xc.Request(FILE_API_URL+":batchMove", http.MethodPost, func(r *resty.Request) {
		r.SetContext(ctx)
		r.SetBody(&base.Json{
			"to":    base.Json{"parent_id": dstDir.GetID()},
			"ids":   []string{srcObj.GetID()},
			"space": xc.Space,
		})
	}, nil)
	return err
}

func (xc *WebCommon) Rename(ctx context.Context, srcObj model.Obj, newName string) error {
	_, err := xc.Request(FILE_API_URL+"/{fileID}", http.MethodPatch, func(r *resty.Request) {
		r.SetContext(ctx)
		r.SetPathParam("fileID", srcObj.GetID())
		r.SetBody(&base.Json{
			"name":  newName,
			"space": xc.Space,
		})
	}, nil)
	return err
}

func (xc *WebCommon) Copy(ctx context.Context, srcObj, dstDir model.Obj) error {
	_, err := xc.Request(FILE_API_URL+":batchCopy", http.MethodPost, func(r *resty.Request) {
		r.SetBody(&base.Json{
			"to":    base.Json{"parent_id": dstDir.GetID()},
			"ids":   []string{srcObj.GetID()},
			"space": xc.Space,
		})
	}, nil)
	return err
}

func (xc *WebCommon) Remove(ctx context.Context, obj model.Obj) error {
	_, err := xc.Request(FILE_API_URL+"/{fileID}/trash", http.MethodPatch, func(r *resty.Request) {
		r.SetContext(ctx)
		r.SetPathParam("fileID", obj.GetID())
		r.SetQueryParam("space", xc.Space)
		r.SetBody("{}")
	}, nil)
	return err
}

func (xc *WebCommon) Put(ctx context.Context, dstDir model.Obj, file model.FileStreamer, up driver.UpdateProgress) error {
	gcid := file.GetHash().GetHash(hash_extend.GCID)
	var err error
	if len(gcid) < hash_extend.GCID.Width {
		_, gcid, err = stream.CacheFullAndHash(file, &up, hash_extend.GCID, file.GetSize())
		if err != nil {
			return err
		}
	}

	var resp UploadTaskResponse
	_, err = xc.Request(FILE_API_URL, http.MethodPost, func(r *resty.Request) {
		r.SetContext(ctx)
		r.SetBody(&base.Json{
			"kind":        FILE,
			"parent_id":   dstDir.GetID(),
			"name":        file.GetName(),
			"size":        file.GetSize(),
			"hash":        gcid,
			"upload_type": UPLOAD_TYPE_RESUMABLE,
			"space":       xc.Space,
		})
	}, &resp)
	if err != nil {
		return err
	}

	param := resp.Resumable.Params
	if resp.UploadType == UPLOAD_TYPE_RESUMABLE {
		param.Endpoint = strings.TrimLeft(param.Endpoint, param.Bucket+".")
		s, err := session.NewSession(&aws.Config{
			Credentials: credentials.NewStaticCredentials(param.AccessKeyID, param.AccessKeySecret, param.SecurityToken),
			Region:      aws.String("xunlei"),
			Endpoint:    aws.String(param.Endpoint),
		})
		if err != nil {
			return err
		}
		uploader := s3manager.NewUploader(s)
		if file.GetSize() > s3manager.MaxUploadParts*s3manager.DefaultUploadPartSize {
			uploader.PartSize = file.GetSize() / (s3manager.MaxUploadParts - 1)
		}
		_, err = uploader.UploadWithContext(ctx, &s3manager.UploadInput{
			Bucket:  aws.String(param.Bucket),
			Key:     aws.String(param.Key),
			Expires: aws.Time(param.Expiration),
			Body:    driver.NewLimitedUploadStream(ctx, &driver.ReaderUpdatingProgress{Reader: file, UpdateProgress: up}),
		})
		return err
	}
	// 与 Go 家族一致：非 RESUMABLE 直接当成功返回（文件其实没上传，但改行为
	// 会与上游分叉）；Zig 侧同样只多打一条 warn。
	log.Warnf("[thunder_web] upload_type=%s (not resumable); file NOT uploaded", resp.UploadType)
	return nil
}

func (xc *WebCommon) GetDetails(ctx context.Context) (*model.StorageDetails, error) {
	var about AboutResponse
	_, err := xc.Request(API_URL+"/about", http.MethodGet, func(r *resty.Request) {
		r.SetContext(ctx)
	}, &about)
	if err != nil {
		return nil, err
	}

	// limit/usage 解析失败是硬错误（与 Go 家族一致）。
	total, err := strconv.ParseInt(about.Quota.Limit, 10, 64)
	if err != nil {
		return nil, err
	}
	used, err := strconv.ParseInt(about.Quota.Usage, 10, 64)
	if err != nil {
		return nil, err
	}

	return &model.StorageDetails{
		DiskUsage: model.DiskUsage{
			TotalSpace: total,
			UsedSpace:  used,
		},
	}, nil
}
