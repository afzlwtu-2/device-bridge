package bootstrap

import (
	"bufio"
	"context"
	"devicebridge/internal/storage"
	"devicebridge/internal/tailnetipc"
	"net"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type DiscoverNetworkInput struct {
	Interface string `json:"interface"`
	CIDR      string `json:"cidr"`
	Kind      string `json:"kind,omitempty"`
}

type DiscoverRequest struct {
	Networks             []DiscoverNetworkInput `json:"networks,omitempty"`
	Ports                []int                  `json:"ports,omitempty"`
	TailnetOnly          bool                   `json:"tailnet_only,omitempty"`
	IncludePairedTailnet bool                   `json:"include_paired_tailnet,omitempty"`
	Tailnet              TailnetOptions         `json:"-"`
}

type DiscoveredTarget struct {
	Source        string  `json:"source"`       // "lan" | "hotspot" | "wifi_direct" | "adb" | "tailnet"
	SourceLabel   string  `json:"source_label"` // Human-readable route label
	Name          string  `json:"name,omitempty"`
	Host          string  `json:"host"`
	ConnectHost   string  `json:"connect_host,omitempty"`
	Port          int     `json:"port"`
	RemotePort    int     `json:"remote_port,omitempty"`
	Interface     string  `json:"interface,omitempty"`
	Banner        string  `json:"banner,omitempty"`
	PingMs        float64 `json:"ping_ms,omitempty"`
	SSHEnabled    bool    `json:"ssh_enabled"`
	TailscaleSSH  bool    `json:"tailscale_ssh,omitempty"`
	AlreadyPaired bool    `json:"already_paired,omitempty"`
	Endpoint      string  `json:"endpoint,omitempty"`
}

func probeSSHBanner(conn net.Conn, timeout time.Duration) (string, bool) {
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	line, err := bufio.NewReaderSize(conn, 256).ReadString('\n')
	line = strings.TrimSpace(line)
	if strings.HasPrefix(line, "SSH-") {
		return line, true
	}
	if err == nil && len(line) > 0 && strings.Contains(line, "SSH") {
		return line, true
	}
	return "", false
}

func subnetScanHosts(cidr string) ([]netip.Addr, netip.Addr, error) {
	prefix, err := netip.ParsePrefix(strings.TrimSpace(cidr))
	if err != nil || !prefix.Addr().Is4() {
		return nil, netip.Addr{}, err
	}
	self := prefix.Addr()
	scan := prefix.Masked()
	if scan.Bits() < 24 {
		scan = netip.PrefixFrom(self, 24).Masked()
	}
	var out []netip.Addr
	base := scan.Addr()
	bits := scan.Bits()
	hostCount := 1 << (32 - bits)
	for i := 1; i < hostCount-1; i++ {
		b := base.As4()
		v := ((uint32(b[0]) << 24) | (uint32(b[1]) << 16) | (uint32(b[2]) << 8) | uint32(b[3])) + uint32(i)
		ip := netip.AddrFrom4([4]byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)})
		if ip == self {
			continue
		}
		out = append(out, ip)
	}
	return out, self, nil
}

func sourceInfoForKind(kind, iface string) (string, string) {
	if kind == "wifi_direct" || strings.HasPrefix(iface, "p2p") || strings.HasPrefix(iface, "dbp2p") {
		return "wifi_direct", "Wi-Fi Direct"
	}
	if kind == "hotspot" || kind == "wifi_join" || strings.HasPrefix(iface, "ap") || strings.HasPrefix(iface, "swlan") || strings.HasPrefix(iface, "rndis") {
		return "hotspot", "Hotspot"
	}
	return "lan", "Wi-Fi LAN"
}

func DiscoverSSH(ctx context.Context, s *storage.Store, req DiscoverRequest) ([]DiscoveredTarget, error) {
	ports := req.Ports
	if len(ports) == 0 {
		ports = []int{8022, 22, 2222}
	}

	pairedHosts := map[string]bool{}
	pairedTailnetIPs := map[string]bool{}
	if s != nil {
		if peers, err := s.Peers(); err == nil {
			for _, p := range peers {
				if p.Status != "paired" {
					continue
				}
				if conn, ce := s.Connection(p.ID, nil); ce == nil {
					for _, ep := range []string{conn.Endpoint, conn.LanEndpoint, conn.TailnetEndpoint} {
						if h, _, se := net.SplitHostPort(strings.TrimSpace(ep)); se == nil && h != "" {
							pairedHosts[h] = true
							if isTailnetIPString(h) {
								pairedTailnetIPs[h] = true
							}
						}
					}
				}
				if recs, re := s.EndpointRecords(p.ID); re == nil {
					for _, r := range recs {
						if h, _, se := net.SplitHostPort(strings.TrimSpace(r.Endpoint)); se == nil && h != "" {
							pairedHosts[h] = true
						}
					}
				}
			}
		}
	}

	var mu sync.Mutex
	var results []DiscoveredTarget
	addResult := func(t DiscoveredTarget) {
		mu.Lock()
		results = append(results, t)
		mu.Unlock()
	}

	var wg sync.WaitGroup

	// Scan ordinary local networks for SSH setup targets unless tailnet-only is requested.
	if !req.TailnetOnly {
		type scanJob struct {
		source      string
		sourceLabel string
		iface       string
		localIP     netip.Addr
		ip          netip.Addr
		port        int
	}
	var jobs []scanJob
	seenJob := map[string]bool{}
	for _, n := range req.Networks {
		src, srcLabel := sourceInfoForKind(n.Kind, n.Interface)
		if src != "lan" {
			continue
		}
		hosts, self, err := subnetScanHosts(n.CIDR)
		if err != nil || (!self.IsPrivate() && !self.IsLoopback()) {
			continue
		}
		for _, ip := range hosts {
			for _, port := range ports {
				key := n.Interface + ":" + ip.String() + ":" + strconv.Itoa(port)
				if seenJob[key] {
					continue
				}
				seenJob[key] = true
				jobs = append(jobs, scanJob{
					source:      src,
					sourceLabel: srcLabel,
					iface:       n.Interface,
					localIP:     self,
					ip:          ip,
					port:        port,
				})
			}
		}
	}

	if len(jobs) > 0 {
		jobCh := make(chan scanJob, len(jobs))
		for _, j := range jobs {
			jobCh <- j
		}
		close(jobCh)
		workers := 96
		if len(jobs) < workers {
			workers = len(jobs)
		}
		for i := 0; i < workers; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for j := range jobCh {
					if ctx.Err() != nil {
						return
					}
					addr := net.JoinHostPort(j.ip.String(), strconv.Itoa(j.port))
					d := net.Dialer{
						Timeout:   400 * time.Millisecond,
						LocalAddr: &net.TCPAddr{IP: net.ParseIP(j.localIP.String())},
					}
					start := time.Now()
					conn, err := d.DialContext(ctx, "tcp4", addr)
					if err != nil {
						continue
					}
					rttMs := float64(time.Since(start).Microseconds()) / 1000.0
					banner, isSSH := probeSSHBanner(conn, 450*time.Millisecond)
					_ = conn.Close()
					if !isSSH {
						continue
					}
					name := ""
					lctx, lcancel := context.WithTimeout(ctx, 150*time.Millisecond)
					if names, le := net.DefaultResolver.LookupAddr(lctx, j.ip.String()); le == nil && len(names) > 0 {
						name = strings.TrimSuffix(names[0], ".")
					}
					lcancel()
					addResult(DiscoveredTarget{
						Source:        j.source,
						SourceLabel:   j.sourceLabel,
						Name:          name,
						Host:          j.ip.String(),
						ConnectHost:   j.ip.String(),
						Port:          j.port,
						Interface:     j.iface,
						Banner:        banner,
						PingMs:        rttMs,
						SSHEnabled:    true,
						AlreadyPaired: pairedHosts[j.ip.String()],
					})
				}
			}()
		}
	}

	// 1b. Hotspot clients that may not run SSH (DeviceBridge agent on 8731)
	for _, n := range req.Networks {
		src, srcLabel := sourceInfoForKind(n.Kind, n.Interface)
		if src != "hotspot" && src != "wifi_direct" {
			continue
		}
		hosts, self, err := subnetScanHosts(n.CIDR)
		if err != nil {
			continue
		}
		hCh := make(chan netip.Addr, len(hosts))
		for _, ip := range hosts {
			hCh <- ip
		}
		close(hCh)
		workers := 48
		if len(hosts) < workers {
			workers = len(hosts)
		}
		for i := 0; i < workers; i++ {
			wg.Add(1)
			go func(local netip.Addr, iface, sType, sLabel string) {
				defer wg.Done()
				for ip := range hCh {
					if ctx.Err() != nil {
						return
					}
					ep := net.JoinHostPort(ip.String(), "8731")
					d := net.Dialer{
						Timeout:   350 * time.Millisecond,
						LocalAddr: &net.TCPAddr{IP: net.ParseIP(local.String())},
					}
					start := time.Now()
					c, err := d.DialContext(ctx, "tcp4", ep)
					if err != nil {
						continue
					}
					rttMs := float64(time.Since(start).Microseconds()) / 1000.0
					_ = c.Close()
					addResult(DiscoveredTarget{
						Source:        sType,
						SourceLabel:   sLabel,
						Host:          ip.String(),
						ConnectHost:   ip.String(),
						Port:          0,
						Interface:     iface,
						PingMs:        rttMs,
						SSHEnabled:    false,
						AlreadyPaired: pairedHosts[ip.String()],
						Endpoint:      ep,
					})
				}
			}(self, n.Interface, src, srcLabel)
		}
	}
	}

	// 2. Tailscale / tsnet peers with SSH enabled (ports 8022, 22, 2222)
	wg.Add(1)
	go func() {
		defer wg.Done()
		st, systemDaemon, sock, ok, _ := queryTailnetStatus(ctx, req.Tailnet)
		if !ok {
			return
		}
		type tsJob struct {
			name string
			ip   string
			port int
		}
		var tsJobs []tsJob
		for _, peer := range st.Peers {
			if !peer.Online {
				continue
			}
			ip := preferredTailnetIP(peer.IPs)
			if ip == "" || (!req.IncludePairedTailnet && pairedTailnetIPs[ip]) {
				continue
			}
			displayName := strings.TrimSpace(peer.Name)
			if dns := strings.TrimSuffix(strings.TrimSpace(peer.DNSName), "."); dns != "" {
				if dot := strings.IndexByte(dns, '.'); dot > 0 {
					displayName = dns[:dot]
				} else {
					displayName = dns
				}
			}
			for _, port := range ports {
				tsJobs = append(tsJobs, tsJob{name: displayName, ip: ip, port: port})
			}
		}
		if len(tsJobs) == 0 {
			return
		}
		ch := make(chan tsJob, len(tsJobs))
		for _, j := range tsJobs {
			ch <- j
		}
		close(ch)
		workers := 24
		if len(tsJobs) < workers {
			workers = len(tsJobs)
		}
		var tswg sync.WaitGroup
		for i := 0; i < workers; i++ {
			tswg.Add(1)
			go func() {
				defer tswg.Done()
				for j := range ch {
					if ctx.Err() != nil {
						return
					}
					target := net.JoinHostPort(j.ip, strconv.Itoa(j.port))
					pctx, pcancel := context.WithTimeout(ctx, 2200*time.Millisecond)
					start := time.Now()
					var conn net.Conn
					var err error
					if !systemDaemon && sock != "" {
						_, conn, err = (tailnetipc.Client{Socket: sock}).Exchange(pctx, tailnetipc.Request{
							Operation:      "stream",
							Target:         target,
							RemoteApproved: true,
							Purpose:        "ssh",
							TimeoutMS:      2000,
						})
					} else {
						conn, err = (&net.Dialer{Timeout: 1500 * time.Millisecond}).DialContext(pctx, "tcp", target)
					}
					pcancel()
					if err != nil {
						continue
					}
					rttMs := float64(time.Since(start).Microseconds()) / 1000.0
					banner, isSSH := probeSSHBanner(conn, 1000*time.Millisecond)
					_ = conn.Close()
					if !isSSH {
						continue
					}
					srcLabel := "Tailscale (tsnet)"
					if systemDaemon {
						srcLabel = "Tailscale"
					}
					addResult(DiscoveredTarget{
						Source:       "tailnet",
						SourceLabel:  srcLabel,
						Name:         j.name,
						Host:         j.name,
						ConnectHost:  j.ip,
						Port:         j.port,
						Banner:        banner,
						PingMs:        rttMs,
						SSHEnabled:    true,
						TailscaleSSH:  strings.Contains(strings.ToLower(banner), "tailscale"),
						AlreadyPaired: pairedTailnetIPs[j.ip],
					})
				}
			}()
		}
		tswg.Wait()
	}()

	wg.Wait()

	// Deduplicate hotspot non-SSH :8731 entry if SSH entry already exists for same host/iface,
	// and keep only one best entry per Tailscale peer (preferring Tailscale SSH on :22, then :22, :8022, :2222).
	sshHostIface := map[string]bool{}
	bestTailnet := map[string]DiscoveredTarget{}
	tailnetScore := func(t DiscoveredTarget) int {
		score := 0
		if t.TailscaleSSH {
			score += 100
		}
		switch t.Port {
		case 22:
			score += 30
		case 8022:
			score += 20
		case 2222:
			score += 10
		}
		return score
	}
	for _, r := range results {
		if r.SSHEnabled && r.Source != "tailnet" {
			sshHostIface[r.Interface+":"+r.Host] = true
		}
		if r.Source == "tailnet" {
			k := r.ConnectHost
			if k == "" {
				k = r.Host
			}
			prev, exists := bestTailnet[k]
			if !exists || tailnetScore(r) > tailnetScore(prev) {
				bestTailnet[k] = r
			}
		}
	}
	dedup := make([]DiscoveredTarget, 0, len(results))
	seenKey := map[string]bool{}
	for _, r := range results {
		if !r.SSHEnabled && sshHostIface[r.Interface+":"+r.Host] {
			continue
		}
		if r.Source == "tailnet" {
			k := r.ConnectHost
			if k == "" {
				k = r.Host
			}
			best := bestTailnet[k]
			if r.Port != best.Port {
				continue
			}
		}
		key := r.Source + ":" + r.Host + ":" + strconv.Itoa(r.Port)
		if seenKey[key] {
			continue
		}
		seenKey[key] = true
		dedup = append(dedup, r)
	}

	order := map[string]int{"hotspot": 0, "wifi_direct": 1, "lan": 2, "tailnet": 3}
	sort.Slice(dedup, func(i, j int) bool {
		oi, oj := order[dedup[i].Source], order[dedup[j].Source]
		if oi != oj {
			return oi < oj
		}
		if dedup[i].SSHEnabled != dedup[j].SSHEnabled {
			return dedup[i].SSHEnabled
		}
		if dedup[i].Host != dedup[j].Host {
			return dedup[i].Host < dedup[j].Host
		}
		return dedup[i].Port < dedup[j].Port
	})
	return dedup, nil
}
