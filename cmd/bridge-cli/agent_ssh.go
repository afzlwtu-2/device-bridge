package main

import (
	"bufio"
	"bytes"
	"context"
	"devicebridge/internal/auth"
	"devicebridge/internal/bootstrap"
	"devicebridge/internal/client"
	"devicebridge/internal/discovery"
	"devicebridge/internal/storage"
	"devicebridge/internal/tailnetipc"
	"devicebridge/internal/transport"
	"devicebridge/internal/transport/direct"
	"devicebridge/internal/transport/wireguard"
	"devicebridge/protocol"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

func slugifyPeerName(name string) string {
	var b strings.Builder
	prevDash := false
	for _, r := range strings.ToLower(strings.TrimSpace(name)) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			prevDash = false
		} else if !prevDash {
			b.WriteByte('-')
			prevDash = true
		}
	}
	return strings.Trim(b.String(), "-")
}

func matchAgentSSHPeer(store *storage.Store, query string) (storage.Peer, bool) {
	q := strings.TrimSpace(query)
	if q == "" {
		return storage.Peer{}, false
	}
	q = strings.TrimPrefix(q, "db.")
	qLower := strings.ToLower(q)
	peers, err := store.Peers()
	if err != nil {
		return storage.Peer{}, false
	}
	var exact []storage.Peer
	var slugs []storage.Peer
	for _, p := range peers {
		if p.Status != "paired" {
			continue
		}
		if p.ID == qLower || (len(qLower) >= 8 && strings.HasPrefix(p.ID, qLower)) {
			exact = append(exact, p)
			continue
		}
		disp := protocol.DeviceDisplayName(p.Name)
		if strings.EqualFold(p.Name, q) || strings.EqualFold(disp, q) ||
			(p.Alias != "" && (strings.EqualFold(p.Alias, q) || slugifyPeerName(p.Alias) == qLower)) {
			slugs = append(slugs, p)
			continue
		}
		if slugifyPeerName(disp) == qLower || slugifyPeerName(p.Name) == qLower {
			slugs = append(slugs, p)
		}
	}
	if len(exact) == 1 {
		return exact[0], true
	}
	if len(exact) == 0 && len(slugs) == 1 {
		return slugs[0], true
	}
	return storage.Peer{}, false
}

func normalizeAgentSSHTransport(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "", "auto":
		return ""
	case "lan", "direct", "direct-lan", "direct-lan-v1", "lan-v1", "wifi-direct", "wifi-direct-v1", "hotspot", "direct-hotspot-v1", "p2p":
		return "lan"
	case "wireguard", "wireguard-v1", "wg":
		return "wireguard"
	case "tailnet", "tailscale", "tailscale-v1", "tsnet":
		return "tailnet"
	case "adb", "adb-v1", "usb", "usb-v1":
		return "adb"
	case "ssh":
		return "ssh"
	default:
		return strings.ToLower(strings.TrimSpace(raw))
	}
}

func dialAgentSSHStream(
	ctx context.Context,
	store *storage.Store,
	id *auth.Identity,
	peerID string,
	stateDir, ifaceName, cidrVal, controlSock, tailnetModeVal, wgBackendVal string,
	wgTunnelOnly bool,
	preferredTransport, preferredEndpoint string,
) (net.Conn, string, error) {
	preferredTransport = normalizeAgentSSHTransport(preferredTransport)
	type attempt struct {
		tr string
		ep string
	}
	var attempts []attempt
	seen := map[attempt]struct{}{}
	add := func(tr, ep string) {
		ep = strings.TrimSpace(ep)
		tr = normalizeAgentSSHTransport(tr)
		if tr == "" || ep == "" {
			return
		}
		a := attempt{tr: tr, ep: ep}
		if _, ok := seen[a]; ok {
			return
		}
		seen[a] = struct{}{}
		attempts = append(attempts, a)
	}

	if preferredEndpoint != "" {
		tr := preferredTransport
		if tr == "" {
			tr = "lan"
		}
		add(tr, preferredEndpoint)
	}
	if conn, err := store.Connection(peerID, nil); err == nil {
		connTr := normalizeAgentSSHTransport(conn.Transport)
		if preferredTransport == "" || preferredTransport == connTr {
			add(connTr, conn.Endpoint)
		}
		if preferredTransport == "" || preferredTransport == "lan" {
			add("lan", conn.LanEndpoint)
		}
		if preferredTransport == "" || preferredTransport == "wireguard" {
			add("wireguard", conn.WireGuardEndpoint)
		}
		if preferredTransport == "" || preferredTransport == "tailnet" {
			add("tailnet", conn.TailnetEndpoint)
		}
		if preferredTransport == "" || preferredTransport == "adb" {
			add("adb", conn.AdbEndpoint)
		}
	}
	if preferredTransport == "" || preferredTransport == "lan" {
		if recs, err := store.EndpointRecords(peerID); err == nil {
			for _, rec := range recs {
				add("lan", rec.Endpoint)
			}
		}
	}

	var lanProv *direct.Provider
	if dp, err := direct.NewCIDR(ifaceName, cidrVal); err == nil {
		lanProv = dp
		lanProv.Discovery = func(dctx context.Context) ([]transport.Candidate, error) {
			return discovery.Browse(dctx, lanProv)
		}
	}
	discoverLAN := func() {
		if lanProv == nil || (preferredTransport != "" && preferredTransport != "lan") {
			return
		}
		dctx, dcancel := context.WithTimeout(ctx, 2*time.Second)
		if cands, err := lanProv.DiscoverCandidates(dctx); err == nil {
			for _, cand := range cands {
				if cand.DeviceID == peerID {
					add("lan", cand.Endpoint)
				}
			}
		}
		dcancel()
	}
	if len(attempts) == 0 {
		discoverLAN()
	}

	var overlayTailnet transport.Provider
	var overlayWG transport.Provider
	providerFor := func(tr string) (transport.Provider, error) {
		policy, err := store.NetworkPolicy(ctx, nil)
		if err != nil {
			return nil, err
		}
		policyID := tr
		if policyID == "lan" {
			policyID = "direct"
		}
		if allowed, known := policy["network_"+policyID]; known && !allowed {
			return nil, errors.New("SSH route disabled in Network settings")
		}
		switch tr {
		case "lan":
			if lanProv == nil {
				return nil, errors.New("LAN interface unavailable")
			}
			return lanProv, nil
		case "adb", "ssh":
			return direct.NewCIDR("lo", "127.0.0.1/8")
		case "tailnet":
			if overlayTailnet == nil {
				p, err := openOverlay(ctx, stateDir, controlSock, tailnetModeVal, true)
				if err != nil {
					return nil, err
				}
				overlayTailnet = p
			}
			return overlayTailnet, nil
		case "wireguard":
			if overlayWG == nil {
				overlayWG = &wireguard.Provider{
					StateDir:       stateDir,
					Control:        tailnetipc.Client{Socket: filepath.Join(stateDir, "wireguard", "control.sock")},
					RemoteApproved: true,
					BackendMode:    wgBackendVal,
					TunnelOnly:     wgTunnelOnly,
				}
			}
			return overlayWG, nil
		default:
			return nil, fmt.Errorf("unsupported transport %q", tr)
		}
	}

	var lastErr error
	var serviceRejection error
	tryIdx := func(start int) (net.Conn, string, bool) {
		for i := start; i < len(attempts); i++ {
			a := attempts[i]
			prov, err := providerFor(a.tr)
			if err != nil {
				lastErr = err
				continue
			}
			cand := transport.Candidate{
				DeviceID:  peerID,
				Endpoint:  a.ep,
				Transport: a.tr,
				Direct:    a.tr == "lan" || a.tr == "adb",
			}
			if lanProv != nil && a.tr == "lan" {
				cand.Interface = lanProv.Interface
			}
			dctx, dcancel := context.WithTimeout(ctx, 6*time.Second)
			conn, err := client.DialAgentSSH(dctx, id, store, prov, cand)
			dcancel()
			if err == nil {
				return conn, a.ep, true
			}
			lastErr = err
			var rejection *client.AgentSSHError
			if errors.As(err, &rejection) {
				serviceRejection = err
				return nil, "", false
			}
		}
		return nil, "", false
	}

	if conn, ep, ok := tryIdx(0); ok {
		return conn, ep, nil
	}
	if serviceRejection != nil {
		return nil, "", serviceRejection
	}
	beforeDiscover := len(attempts)
	discoverLAN()
	if conn, ep, ok := tryIdx(beforeDiscover); ok {
		return conn, ep, nil
	}
	if len(attempts) == 0 && lastErr == nil {
		return nil, "", errors.New("no reachable DeviceBridge endpoint for paired peer; open Devices or pass --endpoint")
	}
	if lastErr == nil {
		lastErr = errors.New("unable to connect to peer agent SSH")
	}
	return nil, "", lastErr
}

type agentSSHRunRequest struct {
	PeerID    string `json:"peer_id"`
	Command   string `json:"command"`
	Endpoint  string `json:"endpoint,omitempty"`
	Transport string `json:"transport,omitempty"`
}

func runAgentSSHCommand(
	ctx context.Context,
	store *storage.Store,
	id *auth.Identity,
	stateDir, ifaceName, cidrVal, controlSock, tailnetModeVal, wgBackendVal string,
	wgTunnelOnly bool,
	req agentSSHRunRequest,
	onChunk func(stream, chunk string),
) (bootstrap.ExecResult, error) {
	if strings.TrimSpace(req.Command) == "" {
		return bootstrap.ExecResult{}, errors.New("command required")
	}
	conn, ep, err := dialAgentSSHStream(
		ctx, store, id, req.PeerID,
		stateDir, ifaceName, cidrVal, controlSock, tailnetModeVal, wgBackendVal, wgTunnelOnly,
		req.Transport, req.Endpoint,
	)
	if err != nil {
		return bootstrap.ExecResult{}, err
	}
	sshClient, err := bootstrap.NewAgentSSHClient(ctx, conn, ep)
	if err != nil {
		return bootstrap.ExecResult{}, err
	}
	defer sshClient.Close()

	sess, err := sshClient.NewSession()
	if err != nil {
		return bootstrap.ExecResult{}, err
	}
	defer sess.Close()

	stdoutPipe, err := sess.StdoutPipe()
	if err != nil {
		return bootstrap.ExecResult{}, err
	}
	stderrPipe, err := sess.StderrPipe()
	if err != nil {
		return bootstrap.ExecResult{}, err
	}
	if err = sess.Start(req.Command); err != nil {
		return bootstrap.ExecResult{}, err
	}

	var stdoutBuf, stderrBuf bytes.Buffer
	var cbMu sync.Mutex
	var readersWG sync.WaitGroup
	readPipe := func(streamName string, r io.Reader, dst *bytes.Buffer) {
		defer readersWG.Done()
		buf := make([]byte, 4096)
		for {
			n, rerr := r.Read(buf)
			if n > 0 {
				chunk := string(buf[:n])
				dst.WriteString(chunk)
				if onChunk != nil {
					cbMu.Lock()
					onChunk(streamName, chunk)
					cbMu.Unlock()
				}
			}
			if rerr != nil {
				return
			}
		}
	}
	readersWG.Add(2)
	go readPipe("stdout", stdoutPipe, &stdoutBuf)
	go readPipe("stderr", stderrPipe, &stderrBuf)
	readersWG.Wait()
	waitErr := sess.Wait()
	exitCode := 0
	if waitErr != nil {
		var exitErr interface{ ExitStatus() int }
		if errors.As(waitErr, &exitErr) {
			exitCode = exitErr.ExitStatus()
		} else {
			return bootstrap.ExecResult{
				Host:     ep,
				Stdout:   stdoutBuf.String(),
				Stderr:   stderrBuf.String(),
				ExitCode: -1,
			}, waitErr
		}
	}
	return bootstrap.ExecResult{
		Host:     ep,
		Stdout:   stdoutBuf.String(),
		Stderr:   stderrBuf.String(),
		ExitCode: exitCode,
	}, nil
}

type agentTerminalRequest struct {
	PeerID    string `json:"peer_id"`
	Endpoint  string `json:"endpoint,omitempty"`
	Transport string `json:"transport,omitempty"`
	Columns   int    `json:"columns"`
	Rows      int    `json:"rows"`
}

func runAgentTerminalSession(
	ctx context.Context,
	store *storage.Store,
	id *auth.Identity,
	stateDir, ifaceName, cidrVal, controlSock, tailnetModeVal, wgBackendVal string,
	wgTunnelOnly bool,
	req agentTerminalRequest,
	frames *bufio.Scanner,
) error {
	peer, err := store.Peer(req.PeerID)
	if err != nil || peer.Status != "paired" {
		return storage.ErrDenied
	}
	conn, ep, err := dialAgentSSHStream(
		ctx, store, id, peer.ID,
		stateDir, ifaceName, cidrVal, controlSock, tailnetModeVal, wgBackendVal, wgTunnelOnly,
		req.Transport, req.Endpoint,
	)
	if err != nil {
		return err
	}
	sshClient, err := bootstrap.NewAgentSSHClient(ctx, conn, ep)
	if err != nil {
		return err
	}
	defer sshClient.Close()
	return bootstrap.StreamSSHClientTerminal(ctx, sshClient, req.Columns, req.Rows, frames, os.Stdout, nil)
}
