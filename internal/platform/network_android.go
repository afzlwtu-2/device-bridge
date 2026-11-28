//go:build android && cgo

package platform

/*
#cgo LDFLAGS: -landroid
#include <android/multinetwork.h>
*/
import "C"
import (
	"errors"
	"os"
	"strconv"
)

// Bind only this native process to the explicitly selected Android Network.
// When Wi-Fi disappears sockets fail instead of moving bulk data to cellular.
// This creates no VPN and changes no system network settings.
func BindApprovedNetwork() error {
	value := os.Getenv("DEVICEBRIDGE_NETWORK_HANDLE")
	if value == "" {
		return nil
	}
	return bindNetwork(value)
}

// RebindApprovedNetwork updates future sockets after the Android app selects
// a replacement through its LAN approval policy.
func RebindApprovedNetwork(handle string) error {
	if err := bindNetwork(handle); err != nil {
		return err
	}
	return os.Setenv("DEVICEBRIDGE_NETWORK_HANDLE", handle)
}

func bindNetwork(value string) error {
	handle, err := strconv.ParseUint(value, 10, 64)
	if err != nil || handle == 0 {
		return errors.New("invalid approved Android network handle")
	}
	if C.android_setprocnetwork(C.net_handle_t(handle)) != 0 {
		return errors.New("approved Android network is unavailable")
	}
	return nil
}

func BindApprovedSocket(fd uintptr) error {
	value := os.Getenv("DEVICEBRIDGE_NETWORK_HANDLE")
	if value == "" {
		return nil
	}
	return BindSocketToNetwork(fd, value)
}

func BindSocketToNetwork(fd uintptr, value string) error {
	handle, err := strconv.ParseUint(value, 10, 64)
	if err != nil || handle == 0 {
		return errors.New("invalid approved Android network")
	}
	if C.android_setsocknetwork(C.net_handle_t(handle), C.int(fd)) != 0 {
		return errors.New("cannot bind socket to approved Android network")
	}
	return nil
}
