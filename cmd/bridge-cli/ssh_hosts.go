package main

import (
	"context"
	"devicebridge/internal/bootstrap"
	"devicebridge/internal/storage"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"os"
	"strings"
	"time"
)

type sshHostLinkInfo struct {
	Interface string `json:"interface"`
	CIDR      string `json:"cidr"`
	Kind      string `json:"kind"`
}

func parseSSHLinkInterfaces(raw string) (string, []sshHostLinkInfo) {
	lines := strings.Split(strings.ReplaceAll(raw, "\r\n", "\n"), "\n")
	osName := ""
	links := []sshHostLinkInfo{}
	seen := map[string]bool{}
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if osName == "" && !strings.Contains(trimmed, "inet") {
			osName = trimmed
			continue
		}
		fields := strings.Fields(trimmed)
		// Parse `ip -o -4 addr show`: `<idx>: <iface> inet <ip/prefix> ...`
		if len(fields) >= 4 && fields[2] == "inet" {
			iface := strings.TrimSuffix(fields[1], ":")
			cidr := fields[3]
			if prefix, err := netip.ParsePrefix(cidr); err == nil && !prefix.Addr().IsLoopback() {
				key := iface + "|" + cidr
				if !seen[key] {
					seen[key] = true
					links = append(links, sshHostLinkInfo{
						Interface: iface,
						CIDR:      cidr,
						Kind:      classifySSHInterfaceKind(iface, prefix.Addr()),
					})
				}
			}
			continue
		}
		// Parse `ifconfig` / BSD `inet <ip>` fallback.
		for i, f := range fields {
			if f == "inet" && i+1 < len(fields) {
				addrStr := strings.Split(fields[i+1], "/")[0]
				if addr, err := netip.ParseAddr(addrStr); err == nil && !addr.IsLoopback() {
					key := addr.String()
					if !seen[key] {
						seen[key] = true
						links = append(links, sshHostLinkInfo{
							Interface: "",
							CIDR:      addr.String(),
							Kind:      classifySSHInterfaceKind("", addr),
						})
					}
				}
				break
			}
		}
	}
	return osName, links
}

func classifySSHInterfaceKind(iface string, addr netip.Addr) string {
	low := strings.ToLower(iface)
	switch {
	case strings.HasPrefix(low, "tailscale") || netip.MustParsePrefix("100.64.0.0/10").Contains(addr):
		return "tailnet"
	case strings.HasPrefix(low, "wg"):
		return "wireguard"
	case strings.HasPrefix(low, "p2p") || strings.HasPrefix(low, "dbp2p"):
		return "wifi_direct"
	case strings.HasPrefix(low, "ap") || strings.HasPrefix(low, "swlan"):
		return "hotspot"
	case strings.HasPrefix(low, "usb") || strings.HasPrefix(low, "rndis"):
		return "usb"
	case strings.HasPrefix(low, "rmnet") || strings.HasPrefix(low, "wwan"):
		return "cellular"
	case strings.HasPrefix(low, "eth") || strings.HasPrefix(low, "en"):
		return "ethernet"
	case strings.HasPrefix(low, "wl"):
		return "wifi"
	default:
		return "lan"
	}
}

func networkAllowsTransport(policy map[string]bool, transportName string) bool {
	if transportName == "lan" {
		transportName = "direct"
	}
	if allowed, known := policy["network_"+transportName]; known && !allowed {
		return false
	}
	usb, set := policy["network_usb"]
	return transportName != "adb" || !set || usb
}

func sshOptions(ctx context.Context, s *storage.Store, opts bootstrap.TailnetOptions) (bootstrap.TailnetOptions, error) {
	switch opts.SSHTransport {
	case "", "auto", "direct", "tailnet", "wireguard", "adb":
	default:
		return opts, errors.New("unsupported SSH transport")
	}
	policy, err := s.NetworkPolicy(ctx, nil)
	if err != nil {
		return opts, err
	}
	opts.NetworkPolicy = policy
	if !networkAllowsTransport(policy, opts.SSHTransport) {
		return opts, errors.New("SSH transport disabled in Network settings")
	}
	if (opts.SSHTransport == "wireguard" || opts.SSHTransport == "tailnet") && !opts.RemoteApproved {
		return opts, errors.New("remote SSH transport approval required")
	}
	return opts, nil
}

func recordBootstrapSSHAccount(ctx context.Context, s *storage.Store, req bootstrap.Request, res bootstrap.Result, upgrade *storage.SSHHost) error {
	if upgrade != nil {
		_, err := s.AssociateUpgradedSSHHost(ctx, *upgrade, res.PairedPeerID, req.ServiceUser)
		return err
	}
	hosts, err := s.SSHHosts(ctx)
	if err != nil {
		return err
	}
	for _, host := range hosts {
		if host.Host == req.Host && host.Port == req.Port && host.User == req.User &&
			host.Fingerprint == res.HostKeySHA256 {
			if host.AgentPeerID == res.PairedPeerID && (req.ServiceUser == "" || host.ServiceUser == req.ServiceUser) {
				return nil
			}
			if host.AgentPeerID != "" && host.AgentPeerID != res.PairedPeerID {
				return errors.New("this SSH account is associated with another DeviceBridge identity")
			}
			_, err := s.AssociateUpgradedSSHHost(ctx, host, res.PairedPeerID, req.ServiceUser)
			return err
		}
	}
	peer, err := s.Peer(res.PairedPeerID)
	if err != nil || peer.Status != "paired" {
		return errors.New("the DeviceBridge identity is no longer paired")
	}
	_, err = s.SaveSSHHost(ctx, storage.SSHHost{
		Version: 1, Name: res.RemoteHostname, Host: req.Host, Port: req.Port, User: req.User,
		Fingerprint: res.HostKeySHA256, Transport: req.Transport, RemoteApproved: req.RemoteApproved,
		AgentPeerID: res.PairedPeerID, ServiceUser: req.ServiceUser,
	})
	return err
}

func sshHostsCommand(s *storage.Store, opts bootstrap.TailnetOptions, a []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if len(a) == 4 && a[1] == "associate" {
		peer := a[3]
		if peer == "none" {
			peer = ""
		}
		h, err := s.AssociateSSHHost(ctx, a[2], peer)
		if err != nil {
			return err
		}
		return output(h)
	}
	if len(a) == 1 {
		hosts, err := s.SSHHosts(ctx)
		if err != nil {
			return err
		}
		return output(hosts)
	}
	if len(a) == 3 && a[1] == "remove" {
		if err := s.RemoveSSHHost(ctx, a[2]); err != nil {
			return err
		}
		return output(map[string]bool{"removed": true})
	}
	if len(a) != 3 || a[2] != "-" {
		return errors.New("ssh-hosts [save - | open - | check - | probe - | remove ID | associate ID PEER]")
	}
	var req struct {
		storage.SSHHost
		bootstrap.GuestCredentials
	}
	dec := json.NewDecoder(io.LimitReader(os.Stdin, 65537))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		return err
	}
	if dec.Decode(new(any)) != io.EOF {
		return errors.New("invalid request")
	}
	if a[1] == "open" || a[1] == "check" {
		host, err := s.SSHHost(ctx, req.ID)
		if err != nil {
			return err
		}
		req.SSHHost = host
	} else if a[1] != "save" && a[1] != "probe" {
		return errors.New("unknown SSH host operation")
	}
	opts.SSHTransport = req.Transport
	opts.RemoteApproved = req.RemoteApproved
	opts, err := sshOptions(ctx, s, opts)
	if err != nil {
		return err
	}
	if a[1] == "probe" {
		probe, err := bootstrap.InspectHostWithOptions(ctx, req.Host, req.Port, opts)
		if err != nil {
			return err
		}
		return output(probe)
	}
	if a[1] == "check" {
		res, err := bootstrap.RunCommand(ctx, bootstrap.ExecRequest{
			Host:            req.Host,
			Port:            req.Port,
			User:            req.User,
			Password:        req.Password,
			PrivateKeyPEM:   req.PrivateKeyPEM,
			KeyPassphrase:   req.KeyPassphrase,
			ExpectedHostKey: req.Fingerprint,
			Command:         "uname -s 2>/dev/null || echo unknown; (ip -o -4 addr show 2>/dev/null || ifconfig 2>/dev/null | grep 'inet ') || true",
			Tailnet:         opts,
		})
		if err != nil {
			return err
		}
		osName, links := parseSSHLinkInterfaces(res.Stdout)
		return output(map[string]any{
			"id":             req.ID,
			"os":             osName,
			"interfaces":     links,
			"checked_at_utc": time.Now().Unix(),
			"exit_code":      res.ExitCode,
		})
	}
	grant, err := bootstrap.OpenSSHSession(ctx, opts, s, req.Host, req.Port, req.User, req.Fingerprint, req.GuestCredentials)
	if err != nil {
		return err
	}
	if a[1] == "save" {
		defer s.RevokeGuest(ctx, grant.ID)
		req.AgentPeerID = ""
		host, err := s.SaveSSHHost(ctx, req.SSHHost)
		if err != nil {
			return err
		}
		return output(host)
	}
	return output(grant)
}
