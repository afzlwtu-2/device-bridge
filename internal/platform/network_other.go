//go:build !android

package platform

import "errors"

func BindApprovedNetwork() error          { return nil }
func BindApprovedSocket(fd uintptr) error { return nil }
func RebindApprovedNetwork(string) error  { return nil }

func BindSocketToNetwork(uintptr, string) error {
	return errors.New("Android network binding is unavailable")
}
