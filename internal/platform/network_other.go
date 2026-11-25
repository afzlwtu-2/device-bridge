//go:build !android

package platform

func BindApprovedNetwork() error          { return nil }
func BindApprovedSocket(fd uintptr) error { return nil }
func RebindApprovedNetwork(string) error  { return nil }
