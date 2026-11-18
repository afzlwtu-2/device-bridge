package main

import (
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/discovery"
	"devicebridge/internal/filesproviders"
	"devicebridge/internal/platform"
	"devicebridge/internal/server"
	"devicebridge/internal/storage"
	"devicebridge/internal/transport/direct"
	"devicebridge/internal/transport/tailscaled"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"syscall"
)

func run() error {
	if err := platform.BindApprovedNetwork(); err != nil {
		return err
	}
	state := flag.String("state", "", "private state directory (required)")
	name := flag.String("name", "", "device name for first initialization")
	iface := flag.String("interface", "wlan0", "approved unmetered LAN interface")
	cidr := flag.String("lan-cidr", "", "this device's approved local LAN IPv4/CIDR")
	port := flag.Int("port", 8731, "listen port")
	noDiscovery := flag.Bool("no-discovery", false, "disable mDNS (diagnostic only)")
	systemTailnet := flag.Bool("system-tailnet", false, "also listen on existing system Tailscale IP; never reconfigure daemon")
	flag.Parse()
	if *state == "" {
		return fmt.Errorf("--state required")
	}
	p, err := direct.NewCIDR(*iface, *cidr)
	if err != nil {
		return err
	}
	s, err := storage.Open(*state)
	if err != nil {
		return err
	}
	defer s.Close()
	id, err := auth.Load(s, *name)
	if err != nil {
		return err
	}
	providers := &filesproviders.Registry{}
	defer providers.Close()
	exports, err := s.Exports()
	if err != nil {
		return err
	}
	for _, e := range exports {
		f, err := filesproviders.NewNative(e.ID, e.Path)
		if err != nil {
			return err
		}
		if err = providers.Register(f); err != nil {
			f.Close()
			return err
		}
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	ln, err := p.Listen(ctx, net.JoinHostPort(p.Address.String(), strconv.Itoa(*port)))
	if err != nil {
		return err
	}
	defer ln.Close()
	discoveryOK := false
	discoveryError := ""
	if !*noDiscovery {
		stop, e := discovery.Advertise(ctx, p, id.ID, ln.Addr().(*net.TCPAddr).Port)
		if e != nil {
			fmt.Fprintln(os.Stderr, "mDNS unavailable:", e)
			discoveryError = e.Error()
		} else {
			discoveryOK = true
			defer stop()
		}
	}
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"id": id.ID, "name": id.Name, "endpoint": ln.Addr().String(), "interface": p.Interface, "transport": p.ID(), "approved_lan": p.Prefix.String(), "discovery": discoveryOK, "discovery_error": discoveryError})
	if *systemTailnet {
		st, e := (&tailscaled.Provider{}).Status(ctx)
		if e != nil || st.State != "Running" {
			return fmt.Errorf("existing system Tailscale unavailable")
		}
		bound := false
		for _, address := range st.IPs {
			if ip := net.ParseIP(address); ip != nil && ip.To4() != nil {
				extra, e := net.Listen("tcp4", net.JoinHostPort(address, strconv.Itoa(*port)))
				if e != nil {
					return e
				}
				defer extra.Close()
				bound = true
				go func() { _ = server.New(s, id, providers).Serve(ctx, extra) }()
				break
			}
		}
		if !bound {
			return fmt.Errorf("existing Tailscale has no IPv4 listener address")
		}
	}
	return server.New(s, id, providers).Serve(ctx, ln)
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
