package thunder_web

// 类型定义。ErrResp / TokenResp / Files / FileList / UploadTaskResponse /
// AboutResponse / ReviewData 与 drivers/thunder/types.go 逐字一致（同一个
// drive/v1 API），新增的只有网页 OAuth 登录两步的响应类型。

import (
	"fmt"
	"strconv"
	"time"

	"github.com/OpenListTeam/OpenList/v4/internal/model"
	"github.com/OpenListTeam/OpenList/v4/pkg/utils"
	hash_extend "github.com/OpenListTeam/OpenList/v4/pkg/utils/hash"
)

type ErrResp struct {
	ErrorCode        int64  `json:"error_code"`
	ErrorMsg         string `json:"error"`
	ErrorDescription string `json:"error_description"`
}

func (e *ErrResp) IsError() bool {
	if e.ErrorMsg == "success" {
		return false
	}

	return e.ErrorCode != 0 || e.ErrorMsg != "" || e.ErrorDescription != ""
}

func (e *ErrResp) Error() string {
	return fmt.Sprintf("ErrorCode: %d ,Error: %s ,ErrorDescription: %s ", e.ErrorCode, e.ErrorMsg, e.ErrorDescription)
}

/*
* 验证码 Token
**/
// CaptchaTokenRequest 网页版形态：不带 captcha_token / redirect_uri
// （浏览器实测如此，见 util.go refreshCaptchaToken 的注释）。
type CaptchaTokenRequest struct {
	Action   string            `json:"action"`
	ClientID string            `json:"client_id"`
	DeviceID string            `json:"device_id"`
	Meta     map[string]string `json:"meta"`
}

type CaptchaTokenResponse struct {
	CaptchaToken string `json:"captcha_token"`
	ExpiresIn    int64  `json:"expires_in"`
	Url          string `json:"url"`
}

/*
* 登录
**/
type TokenResp struct {
	TokenType    string `json:"token_type"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"`

	Sub    string `json:"sub"`
	UserID string `json:"user_id"`
}

func (t *TokenResp) Token() string {
	return fmt.Sprint(t.TokenType, " ", t.AccessToken)
}

// 网页 OAuth 四步登录的中间响应：第 2 步（SSO 令牌）与第 3 步（授权码）。
type SignInResp struct {
	AccessToken string `json:"access_token"`
	TokenType   string `json:"token_type"`
	ExpiresIn   int64  `json:"expires_in"`
}

type AuthorizeResp struct {
	Code      string `json:"code"`
	ExpiresIn int64  `json:"expires_in"`
}

/*
* 文件
**/
type FileList struct {
	Kind            string  `json:"kind"`
	NextPageToken   string  `json:"next_page_token"`
	Files           []Files `json:"files"`
	Version         string  `json:"version"`
	VersionOutdated bool    `json:"version_outdated"`
}

type Link struct {
	URL    string    `json:"url"`
	Token  string    `json:"token"`
	Expire time.Time `json:"expire"`
	Type   string    `json:"type"`
}

var _ model.Obj = (*Files)(nil)

type Files struct {
	Kind           string    `json:"kind"`
	ID             string    `json:"id"`
	ParentID       string    `json:"parent_id"`
	Name           string    `json:"name"`
	Size           string    `json:"size"`
	WebContentLink string    `json:"web_content_link"`
	CreatedTime    time.Time `json:"created_time"`
	ModifiedTime   time.Time `json:"modified_time"`
	IconLink       string    `json:"icon_link"`
	ThumbnailLink  string    `json:"thumbnail_link"`
	Hash           string    `json:"hash"`
	Medias         []struct {
		Link Link `json:"link"`
	} `json:"medias"`
	Trashed     bool   `json:"trashed"`
	DeleteTime  string `json:"delete_time"`
	OriginalURL string `json:"original_url"`
}

func (c *Files) GetHash() utils.HashInfo {
	return utils.NewHashInfo(hash_extend.GCID, c.Hash)
}

func (c *Files) GetSize() int64        { size, _ := strconv.ParseInt(c.Size, 10, 64); return size }
func (c *Files) GetName() string       { return c.Name }
func (c *Files) CreateTime() time.Time { return c.CreatedTime }
func (c *Files) ModTime() time.Time    { return c.ModifiedTime }
func (c *Files) IsDir() bool           { return c.Kind == FOLDER }
func (c *Files) GetID() string         { return c.ID }
func (c *Files) GetPath() string       { return "" }
func (c *Files) Thumb() string         { return c.ThumbnailLink }

/*
* 上传
**/
type UploadTaskResponse struct {
	UploadType string `json:"upload_type"`

	//UPLOAD_TYPE_RESUMABLE
	Resumable struct {
		Kind   string `json:"kind"`
		Params struct {
			AccessKeyID     string    `json:"access_key_id"`
			AccessKeySecret string    `json:"access_key_secret"`
			Bucket          string    `json:"bucket"`
			Endpoint        string    `json:"endpoint"`
			Expiration      time.Time `json:"expiration"`
			Key             string    `json:"key"`
			SecurityToken   string    `json:"security_token"`
		} `json:"params"`
		Provider string `json:"provider"`
	} `json:"resumable"`

	File Files `json:"file"`
}

// 添加存储详情
type AboutResponse struct {
	Quota struct {
		Limit string `json:"limit"`
		Usage string `json:"usage"`
	} `json:"quota"`
}

// LoginReviewResp 登录验证响应
type LoginReviewResp struct {
	Creditkey        string `json:"creditkey"`
	Error            string `json:"error"`
	ErrorCode        string `json:"errorCode"`
	ErrorDesc        string `json:"errorDesc"`
	ErrorDescURL     string `json:"errorDescUrl"`
	ErrorIsRetry     int    `json:"errorIsRetry"`
	ErrorDescription string `json:"error_description"`
	IsCompressed     string `json:"isCompressed"`
	PlatformVersion  string `json:"platformVersion"`
	ProtocolVersion  string `json:"protocolVersion"`
	Reviewurl        string `json:"reviewurl"`
	SequenceNo       string `json:"sequenceNo"`
	UserID           string `json:"userID"`
	VerifyType       string `json:"verifyType"`
}

// ReviewData 验证数据
type ReviewData struct {
	Creditkey  string `json:"creditkey"`
	Reviewurl  string `json:"reviewurl"`
	Deviceid   string `json:"deviceid"`
	Devicesign string `json:"devicesign"`
}
