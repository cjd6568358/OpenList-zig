package thunder_web

// 移植自 Zig thunder.zig 的黄金向量单测（THU-22/23/26/27/1/9），逐条对齐。
// 这几条测试是网页版驱动的地基：盐表、盐顺序、拼接方式、PKCE、手机号
// 规范化 —— 任一改动都会红。

import (
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/OpenListTeam/OpenList/v4/internal/errs"
)

func TestRequestReturnsErrorWhenTokenIsMissing(t *testing.T) {
	xc := &WebCommon{Common: &Common{}}

	_, err := xc.Request(API_URL+"/about", http.MethodGet, nil, nil)
	if !errors.Is(err, errs.EmptyToken) {
		t.Fatalf("expected EmptyToken, got %v", err)
	}
}

// THU-22：黄金对来自浏览器 2026-10-20 的真实请求，并且已在服务端换到
// captcha_token。盐表、盐顺序、拼接方式、base 组成任一改动都会红。
func TestCaptchaSignWebGolden(t *testing.T) {
	sign := captchaSignAt(
		WebClientID,
		WebClientVersion,
		WebPackageName,
		"28419a6fe0b7e47c355bbd8a95777fef",
		"1792491447693",
		WebAlgorithms,
	)
	const want = "1.68270948a01b031830b45681bb1da55f"
	if sign != want {
		t.Fatalf("captcha sign mismatch:\n got  %s\n want %s", sign, want)
	}
}

// THU-26：RFC 7636 附录 B 的官方例子：verifier → challenge。
// 网页登录第 3 步的 code_challenge 算错了 /v1/user/authorize 会直接拒。
func TestPkceChallengeRfc7636(t *testing.T) {
	verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	const want = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
	got := pkceChallenge(verifier)
	if got != want {
		t.Fatalf("pkce challenge mismatch:\n got  %s\n want %s", got, want)
	}
	if len(got) != 43 {
		t.Fatalf("challenge must be 43 chars, got %d", len(got))
	}
}

// THU-27：/v1/auth/signin 要求手机号形如 `+86 138...`（带空格）。
func TestWebUsername(t *testing.T) {
	cases := []struct{ in, want string }{
		{"18616132763", "+86 18616132763"},
		{" 18616132763 ", "+86 18616132763"},
		{"+86 18616132763", "+86 18616132763"}, // 已带国家码原样
		{"a@b.com", "a@b.com"},                 // 邮箱原样
		{"alice", "alice"},                     // 用户名原样
		{"12345", "12345"},                     // 非 11 位数字不硬加国家码
	}
	for _, c := range cases {
		if got := WebUsername(c.in); got != c.want {
			t.Fatalf("WebUsername(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// THU-23：盐表字符串与数组必须是同一批 15 个盐、同一顺序。两者漂移过一次
// 就会出现「配置里看着对、签名却错」这种最难查的 bug。盐里也不能有逗号。
func TestWebAlgorithmsStrMatchesArray(t *testing.T) {
	parts := strings.Split(WebAlgorithmsStr, ",")
	if len(parts) != len(WebAlgorithms) {
		t.Fatalf("salt count mismatch: str=%d array=%d", len(parts), len(WebAlgorithms))
	}
	if len(parts) != 15 {
		t.Fatalf("web salt table must have 15 salts, got %d", len(parts))
	}
	for i := range parts {
		if parts[i] != WebAlgorithms[i] {
			t.Fatalf("salt #%d mismatch: str=%q array=%q", i, parts[i], WebAlgorithms[i])
		}
		if strings.Contains(parts[i], ",") {
			t.Fatalf("salt #%d contains a comma; split would mis-parse", i)
		}
	}
}

// THU-1：GetAction 只取 path，去掉 query/fragment（与家族正则逐字一致）。
func TestGetAction(t *testing.T) {
	cases := []struct{ method, url, want string }{
		{http.MethodPost, XLUSER_API_URL + "/auth/signin/token", "POST:/v1/auth/signin/token"},
		{http.MethodGet, "https://api-pan.xunlei.com/drive/v1/files?space=&limit=100", "GET:/drive/v1/files"},
		{http.MethodPatch, "https://api-pan.xunlei.com/drive/v1/files/abc/trash?space=x", "PATCH:/drive/v1/files/abc/trash"},
		{http.MethodGet, "https://api-pan.xunlei.com", "GET:"},
		{http.MethodGet, "http://user@host:8080/a/b#frag", "GET:/a/b"},
	}
	for _, c := range cases {
		if got := GetAction(c.method, c.url); got != c.want {
			t.Fatalf("GetAction(%s, %s) = %q, want %q", c.method, c.url, got, c.want)
		}
	}
}

// THU-9：ErrResp 判定与 Go 家族 errs 逐字一致。
func TestErrResp(t *testing.T) {
	// "success" 优先：即使同时带 error_code 也不算错误（IsError 第一条判断）
	if (&ErrResp{ErrorMsg: "success", ErrorCode: 1}).IsError() {
		t.Fatal(`IsError(&{"success", code 1}) must be false`)
	}
	if (&ErrResp{}).IsError() {
		t.Fatal("IsError(&{}) must be false")
	}
	if !(&ErrResp{ErrorCode: 4122}).IsError() {
		t.Fatal("IsError(&{code 4122}) must be true")
	}
	if !(&ErrResp{ErrorMsg: "invalid_grant"}).IsError() {
		t.Fatal(`IsError(&{"invalid_grant"}) must be true`)
	}

	e := &ErrResp{ErrorCode: 9, ErrorMsg: "captcha_invalid", ErrorDescription: "expired"}
	const want = "ErrorCode: 9 ,Error: captcha_invalid ,ErrorDescription: expired "
	if e.Error() != want {
		t.Fatalf("Error() = %q, want %q", e.Error(), want)
	}
}

// identity 必须只随登录特征变化：refresh_token 变了 identity 就得变；
// 同一份配置算两次必须稳定。
func TestGetIdentity(t *testing.T) {
	base := Addition{
		RefreshToken:  "a1.RT",
		Algorithms:    WebAlgorithmsStr,
		DeviceID:      "0123456789abcdef0123456789abcdef",
		ClientID:      WebClientID,
		ClientVersion: WebClientVersion,
		PackageName:   WebPackageName,
	}
	if base.GetIdentity() != base.GetIdentity() {
		t.Fatal("identity must be deterministic")
	}
	changed := base
	changed.RefreshToken = "a1.RT2"
	if base.GetIdentity() == changed.GetIdentity() {
		t.Fatal("identity must change when refresh_token changes")
	}
	// 网页版 client_id 绝不能与安卓的混用（会 invalid_grant）——默认值钉住
	if base.ClientID != "Xqp0kJBXWhwaTpB6" || WebClientID == "Xp6vsxz_7IYVw2BB" {
		t.Fatal("web client_id default must be the pan.xunlei.com one")
	}
}
