package thunder_web

import (
	"crypto/md5"
	"encoding/hex"

	"github.com/OpenListTeam/OpenList/v4/internal/driver"
	"github.com/OpenListTeam/OpenList/v4/internal/op"
)

// Addition ThunderWeb 的存储配置。键名、默认值、help 文案与 Zig 侧
// thunder.zig 的 web_factory.addition_schema 一致，前端表单按 struct tag
// 生成。运行时空字段一律回落到网页客户端默认值（见 driver.go 的 Init）。
type Addition struct {
	driver.RootID

	Username string `json:"username" help:"迅雷账号（手机号/邮箱）。填了它驱动就能自动续期，只需录一次"`
	Password string `json:"password" help:"登录密码（与 username 配套）"`

	// 可选。填了优先用 refresh_token；失效会自动用上面的账号密码重新登录
	RefreshToken string `json:"refresh_token" help:"可选。填了优先用 refresh_token；失效会自动用上面的账号密码重新登录"`

	DeviceID      string `json:"device_id" default:"" help:"设备 ID（32 位 hex），留空自动生成并持久化"`
	ClientID      string `json:"client_id" default:"Xqp0kJBXWhwaTpB6" help:"网页版 client_id，勿改成安卓的（会 invalid_grant）"`
	ClientVersion string `json:"client_version" default:"1.93.12" help:"网页前端版本，与签名盐表绑定"`
	PackageName   string `json:"package_name" default:"pan.xunlei.com" help:"同时充当签名 base 里的 location.host"`
	Algorithms    string `json:"algorithms" default:"QT5gqd1eSINZe+K,9TafMwqVWgh45hLntDm6HLcOXE,L0nOen58D2cCsOSRaRRYt1Mj+XTVM,gu4CPVQhQU,X/6jue5AUYt56MbqopFv,EuBhpIhdLUh37zvuzrOA3t8HL2HBtlCw,3LSRoSaxM6YKIbhtx7RxaBpf,OOnBZYkw3kRrfGD8,ytWf,psUOt,+0izM,tF53Ovo+aqLG00zho+b,OnrcYC9y8,cv2tHyrFOPhJUFkk6KhecIHJDUKK,NnkQ2lQy" help:"网页版签名盐表（15 个，逗号分隔）；迅雷前端发版后可能需要更新"`
	CaptchaToken  string `json:"captcha_token" default:"" help:"验证码 token，留空自动获取（有效期 300 秒，驱动会主动续）"`
	UserAgent     string `json:"user_agent" default:"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36" help:"网页版 UA"`
	Space         string `json:"space" default:"" help:"远程设备 ID，留空 = 个人云盘"`
}

// GetIdentity 登录特征，用于判断是否重新登录。
//
// 与 Zig thunder.zig identity() 的 web 分支一致：网页版恒走 refresh_token
// （变体决定，不给用户切换余地），摘要输入 =
// refresh_token + algorithms + device_id + client_id + client_secret
// (网页版为空串) + client_version + package_name。
//
// ⚠️ Init 里必须先把 device_id / 各默认值落定再调本函数（Zig 特意调过序），
// 否则首轮用空 device_id 算一次、生成后再算一次就变了，下次启动必然多烧
// 一次 refresh grant。
func (i *Addition) GetIdentity() string {
	hash := md5.New()
	hash.Write([]byte(i.RefreshToken))
	hash.Write([]byte(i.Algorithms))
	hash.Write([]byte(i.DeviceID))
	hash.Write([]byte(i.ClientID))
	hash.Write([]byte(WebClientSecret))
	hash.Write([]byte(i.ClientVersion))
	hash.Write([]byte(i.PackageName))
	return hex.EncodeToString(hash.Sum(nil))
}

var config = driver.Config{
	Name:      "ThunderWeb",
	LocalSort: true,
}

func init() {
	op.RegisterDriver(func() driver.Driver {
		return &ThunderWeb{}
	})
}
