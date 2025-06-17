package _115_open

import (
	"errors"
	"fmt"
	"github.com/OpenListTeam/OpenList/drivers/base"
	"github.com/OpenListTeam/OpenList/internal/errs"
	"github.com/OpenListTeam/OpenList/internal/op"
)

func (d *Open115) refreshToken() error {
	err := d._refreshToken()
	if err != nil && errors.Is(err, errs.EmptyToken) {
		err = d._refreshToken()
	}
	return err
}

func (d *Open115) _refreshToken() error {
	// 使用在线API刷新Token，无需ClientID和ClientSecret
	if d.Addition.UseOnlineAPI && len(d.Addition.APIAddress) > 0 {
		u := d.APIAddress
		var resp struct {
			RefreshToken string `json:"refresh_token"`
			AccessToken  string `json:"access_token"`
		}
		_, err := base.RestyClient.R().
			SetResult(&resp).
			SetQueryParams(map[string]string{
				"refresh_ui": d.Addition.RefreshToken,
				"server_use": "true",
				"driver_txt": "115cloud_go",
			}).
			Get(u)
		if err != nil {
			return err
		}
		if resp.RefreshToken == "" || resp.AccessToken == "" {
			return fmt.Errorf("empty token returned from official API")
		}
		d.AccessToken = resp.AccessToken
		d.RefreshToken = resp.RefreshToken
		op.MustSaveDriverStorage(d)
		return nil
	}
	return nil
}

// do others that not defined in Driver interface
