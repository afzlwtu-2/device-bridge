//go:build !android

package discovery

import "net"

func networkInterface(name string) (*net.Interface, error) { return net.InterfaceByName(name) }
