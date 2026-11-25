package main

import (
	"context"
	"devicebridge/internal/sshserver"
	"devicebridge/internal/tailnetipc"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"
	"tailscale.com/feature"
	"tailscale.com/ipn/ipnlocal"
	"tailscale.com/net/tsaddr"
	"tailscale.com/tailcfg"
	"tailscale.com/types/logger"
)

func init() {
	feature.HookGetSSHHostKeyPublicStrings.Set(getTailscaleSSHHostKeyPublicStrings)
	ipnlocal.RegisterNewSSHServer(newTailscaleSSHServer)
}

func resolveTailscaleSSHShell(varRoot string) (string, string) {
	return sshserver.ResolveShell(varRoot)
}

func getTailscaleSSHHostKeys(varRoot string) ([]ssh.Signer, error) {
	if varRoot == "" {
		return nil, errors.New("no varRoot for SSH host keys")
	}
	return sshserver.LoadOrCreateHostKeys(varRoot)
}

func getTailscaleSSHHostKeyPublicStrings(varRoot string, _ logger.Logf) ([]string, error) {
	signers, err := getTailscaleSSHHostKeys(varRoot)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(signers))
	for _, s := range signers {
		out = append(out, strings.TrimSpace(string(ssh.MarshalAuthorizedKey(s.PublicKey()))))
	}
	return out, nil
}

var (
	sshServersMu sync.Mutex
	sshServers   = map[*tailscaleSSHServer]struct{}{}
)

func activeTailscaleSSHStats() (int, []tailnetipc.SSHSession) {
	sshServersMu.Lock()
	servers := make([]*tailscaleSSHServer, 0, len(sshServers))
	for s := range sshServers {
		servers = append(servers, s)
	}
	sshServersMu.Unlock()
	total := 0
	var sessions []tailnetipc.SSHSession
	for _, s := range servers {
		s.mu.Lock()
		for c := range s.conns {
			total++
			peer := ""
			if c.node.Valid() {
				peer = strings.TrimSpace(c.node.DisplayName(false))
				if peer == "" && c.node.Hostinfo().Valid() {
					peer = strings.TrimSpace(c.node.Hostinfo().Hostname())
				}
			}
			sessions = append(sessions, tailnetipc.SSHSession{
				User:    c.sshUser,
				Peer:    peer,
				Remote:  c.src.String(),
				RxBytes: c.traffic.rx.Load(),
				TxBytes: c.traffic.tx.Load(),
			})
		}
		s.mu.Unlock()
	}
	return total, sessions
}

type tailscaleSSHServer struct {
	lb       *ipnlocal.LocalBackend
	logf     logger.Logf
	mu       sync.Mutex
	conns    map[*tailscaleSSHConn]struct{}
	shutdown bool
}

func newTailscaleSSHServer(logf logger.Logf, lb *ipnlocal.LocalBackend) (ipnlocal.SSHServer, error) {
	s := &tailscaleSSHServer{
		lb:    lb,
		logf:  logf,
		conns: make(map[*tailscaleSSHConn]struct{}),
	}
	sshServersMu.Lock()
	sshServers[s] = struct{}{}
	sshServersMu.Unlock()
	return s, nil
}

func (s *tailscaleSSHServer) NumActiveConns() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.conns)
}

func (s *tailscaleSSHServer) Shutdown() {
	sshServersMu.Lock()
	delete(sshServers, s)
	sshServersMu.Unlock()
	s.mu.Lock()
	s.shutdown = true
	active := make([]*tailscaleSSHConn, 0, len(s.conns))
	for c := range s.conns {
		active = append(active, c)
	}
	s.mu.Unlock()
	for _, c := range active {
		c.close()
	}
}

func (s *tailscaleSSHServer) OnPolicyChange() {
	s.mu.Lock()
	active := make([]*tailscaleSSHConn, 0, len(s.conns))
	for c := range s.conns {
		active = append(active, c)
	}
	s.mu.Unlock()
	for _, c := range active {
		if c.authDone.Load() {
			go c.recheckPolicy()
		}
	}
}

func (s *tailscaleSSHServer) registerConn(c *tailscaleSSHConn) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.shutdown {
		return false
	}
	s.conns[c] = struct{}{}
	return true
}

func (s *tailscaleSSHServer) unregisterConn(c *tailscaleSSHConn) {
	s.mu.Lock()
	delete(s.conns, c)
	s.mu.Unlock()
}

type policyEvalResult int

const (
	policyNoPolicy policyEvalResult = iota
	policyRejected
	policyRejectedUser
	policyAccepted
)

func evalSSHPolicy(
	pol *tailcfg.SSHPolicy,
	now time.Time,
	src netip.AddrPort,
	node tailcfg.NodeView,
	uprof tailcfg.UserProfile,
	reqUser string,
) (*tailcfg.SSHAction, string, []string, *tailcfg.SSHRule, policyEvalResult) {
	if pol == nil {
		return nil, "", nil, nil, policyNoPolicy
	}
	failedOnUser := false
	for _, r := range pol.Rules {
		if r == nil || r.Action == nil {
			continue
		}
		if r.RuleExpires != nil && r.RuleExpires.Before(now) {
			continue
		}
		if !sshPrincipalsMatch(r.Principals, src, node, uprof) {
			continue
		}
		if r.Action.Reject {
			return r.Action, "", nil, r, policyAccepted
		}
		localUser := mapSSHLocalUser(r.SSHUsers, reqUser)
		if localUser == "" {
			failedOnUser = true
			continue
		}
		return r.Action, localUser, r.AcceptEnv, r, policyAccepted
	}
	if failedOnUser {
		return nil, "", nil, nil, policyRejectedUser
	}
	return nil, "", nil, nil, policyRejected
}

func sshPrincipalsMatch(ps []*tailcfg.SSHPrincipal, src netip.AddrPort, node tailcfg.NodeView, uprof tailcfg.UserProfile) bool {
	for _, p := range ps {
		if p == nil {
			continue
		}
		if p.Any {
			return true
		}
		if !p.Node.IsZero() && node.Valid() && p.Node == node.StableID() {
			return true
		}
		if p.NodeIP != "" {
			if ip, err := netip.ParseAddr(p.NodeIP); err == nil && ip == src.Addr() {
				return true
			}
		}
		if p.UserLogin != "" && uprof.LoginName == p.UserLogin {
			return true
		}
	}
	return false
}

func mapSSHLocalUser(ruleSSHUsers map[string]string, reqUser string) string {
	if len(ruleSSHUsers) == 0 {
		return ""
	}
	v, ok := ruleSSHUsers[reqUser]
	if !ok {
		v = ruleSSHUsers["*"]
	}
	if v == "" {
		return ""
	}
	if v == "=" {
		// autogroup:nonroot compiles to {"*": "="}; deny root unless explicitly mapped.
		if strings.EqualFold(reqUser, "root") || reqUser == "" {
			return ""
		}
		return reqUser
	}
	return v
}

func expandDelegateURL(actionURL string, dstNodeID string, src netip.AddrPort, dst netip.AddrPort, node tailcfg.NodeView, sshUser, localUser string) string {
	var srcNodeID string
	if node.Valid() {
		srcNodeID = fmt.Sprint(int64(node.ID()))
	}
	return strings.NewReplacer(
		"$SRC_NODE_IP", url.QueryEscape(src.Addr().String()),
		"$SRC_NODE_ID", srcNodeID,
		"$DST_NODE_IP", url.QueryEscape(dst.Addr().String()),
		"$DST_NODE_ID", dstNodeID,
		"$SSH_USER", url.QueryEscape(sshUser),
		"$LOCAL_USER", url.QueryEscape(localUser),
	).Replace(actionURL)
}

type tailscaleSSHConn struct {
	srv         *tailscaleSSHServer
	rawConn     net.Conn
	traffic     proxyBytes
	ctx         context.Context
	cancel      context.CancelFunc
	spac        ssh.ServerPreAuthConn
	src         netip.AddrPort
	dst         netip.AddrPort
	node        tailcfg.NodeView
	uprof       tailcfg.UserProfile
	sshUser     string
	localUser   string
	acceptEnv   []string
	latchedRule *tailcfg.SSHRule
	authDone    atomic.Bool
	mu          sync.Mutex
	sconn       *ssh.ServerConn
	ruleTimer   *time.Timer
}

type countedSSHStream struct {
	net.Conn
	traffic *proxyBytes
}

func (s *countedSSHStream) Read(buf []byte) (int, error) {
	n, err := s.Conn.Read(buf)
	s.traffic.rx.Add(uint64(n))
	return n, err
}

func (s *countedSSHStream) Write(buf []byte) (int, error) {
	n, err := s.Conn.Write(buf)
	s.traffic.tx.Add(uint64(n))
	return n, err
}

func (c *tailscaleSSHConn) close() {
	c.cancel()
	c.mu.Lock()
	sc := c.sconn
	if c.ruleTimer != nil {
		c.ruleTimer.Stop()
		c.ruleTimer = nil
	}
	c.mu.Unlock()
	if sc != nil {
		_ = sc.Close()
	}
	_ = c.rawConn.Close()
}

func (c *tailscaleSSHConn) sendBanner(msg string) {
	if c.spac != nil && msg != "" {
		_ = c.spac.SendAuthBanner(msg)
	}
}

func (c *tailscaleSSHConn) deny(msg string) error {
	if msg == "" {
		msg = "tailscale: access denied\r\n"
	}
	c.sendBanner(msg)
	return &ssh.PartialSuccessError{}
}

func (c *tailscaleSSHConn) fetchSSHAction(ctx context.Context, rawURL string) (*tailcfg.SSHAction, error) {
	fetchCtx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	delay := 250 * time.Millisecond
	for {
		if err := fetchCtx.Err(); err != nil {
			return nil, err
		}
		req, err := http.NewRequestWithContext(fetchCtx, http.MethodGet, rawURL, nil)
		if err != nil {
			return nil, err
		}
		res, err := c.srv.lb.DoNoiseRequest(req)
		if err == nil && res.StatusCode == http.StatusOK {
			var action tailcfg.SSHAction
			decErr := json.NewDecoder(res.Body).Decode(&action)
			_ = res.Body.Close()
			if decErr == nil {
				return &action, nil
			}
		} else if res != nil {
			_ = res.Body.Close()
		}
		select {
		case <-fetchCtx.Done():
			return nil, fetchCtx.Err()
		case <-time.After(delay):
		}
		if delay < 3*time.Second {
			delay *= 2
		}
	}
}

func (c *tailscaleSSHConn) authenticate(cm ssh.ConnMetadata) (*ssh.Permissions, error) {
	if !tsaddr.IsTailscaleIP(c.dst.Addr()) || !tsaddr.IsTailscaleIP(c.src.Addr()) {
		return nil, c.deny("tailscale: non-tailnet address rejected\r\n")
	}
	node, uprof, ok := c.srv.lb.WhoIs("tcp", c.src)
	if !ok {
		return nil, c.deny("tailscale: unknown tailnet peer\r\n")
	}
	c.node = node
	c.uprof = uprof
	c.sshUser = strings.TrimSuffix(cm.User(), "+password")

	if !c.srv.lb.ShouldRunSSH() {
		return nil, c.deny("tailscale: SSH is disabled on this node\r\n")
	}
	nm := c.srv.lb.NetMapNoPeers()
	if nm == nil {
		return nil, c.deny("tailscale: tailnet map unavailable\r\n")
	}
	action, localUser, acceptEnv, rule, res := evalSSHPolicy(nm.SSHPolicy, c.srv.lb.ControlNow(time.Now()), c.src, node, uprof, c.sshUser)
	switch res {
	case policyAccepted:
	case policyRejectedUser:
		return nil, c.deny(fmt.Sprintf("tailscale: tailnet policy does not permit you to SSH as user %q\r\n", c.sshUser))
	default:
		return nil, c.deny("tailscale: tailnet policy does not permit you to SSH to this node\r\n")
	}

	c.localUser = localUser
	c.acceptEnv = acceptEnv
	c.latchedRule = rule

	dstNodeID := fmt.Sprint(int64(nm.SelfNode.ID()))
	for {
		switch {
		case action.Accept:
			c.sendBanner(action.Message)
			if rule != nil && rule.RuleExpires != nil {
				d := time.Until(*rule.RuleExpires)
				if d <= 0 {
					return nil, c.deny("tailscale: SSH session rule expired\r\n")
				}
				c.mu.Lock()
				c.ruleTimer = time.AfterFunc(d, c.close)
				c.mu.Unlock()
			}
			return &ssh.Permissions{}, nil
		case action.Reject:
			return nil, c.deny(action.Message)
		case action.HoldAndDelegate != "":
			c.sendBanner(action.Message)
			expanded := expandDelegateURL(action.HoldAndDelegate, dstNodeID, c.src, c.dst, node, c.sshUser, localUser)
			next, err := c.fetchSSHAction(c.ctx, expanded)
			if err != nil {
				return nil, c.deny("tailscale: SSH check authorization failed or timed out\r\n")
			}
			action = next
		default:
			return nil, c.deny("tailscale: invalid SSH policy action\r\n")
		}
	}
}

func (c *tailscaleSSHConn) recheckPolicy() {
	if !c.srv.lb.ShouldRunSSH() {
		c.close()
		return
	}
	nm := c.srv.lb.NetMapNoPeers()
	if nm == nil || nm.SSHPolicy == nil {
		c.close()
		return
	}
	action, _, _, _, res := evalSSHPolicy(nm.SSHPolicy, c.srv.lb.ControlNow(time.Now()), c.src, c.node, c.uprof, c.sshUser)
	if res != policyAccepted || action == nil || !action.Accept {
		c.close()
	}
}

func allowEnvKey(key string, acceptEnv []string) bool {
	return sshserver.AllowEnvKey(key, acceptEnv, false)
}

func (s *tailscaleSSHServer) HandleSSHConn(nc net.Conn) error {
	defer nc.Close()

	src, srcErr := netip.ParseAddrPort(nc.RemoteAddr().String())
	dst, dstErr := netip.ParseAddrPort(nc.LocalAddr().String())
	if srcErr != nil || dstErr != nil {
		return errors.New("tailscale ssh: invalid peer or local address")
	}

	varRoot := s.lb.TailscaleVarRoot()
	signers, err := getTailscaleSSHHostKeys(varRoot)
	if err != nil || len(signers) == 0 {
		return fmt.Errorf("tailscale ssh: host keys unavailable: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	c := &tailscaleSSHConn{
		srv:     s,
		rawConn: nc,
		ctx:     ctx,
		cancel:  cancel,
		src:     src,
		dst:     dst,
	}
	c.rawConn = &countedSSHStream{Conn: nc, traffic: &c.traffic}
	if !s.registerConn(c) {
		cancel()
		return errors.New("tailscale ssh: server is shutting down")
	}
	defer s.unregisterConn(c)
	defer c.close()

	cfg := &ssh.ServerConfig{
		ServerVersion: "SSH-2.0-Tailscale",
		NoClientAuth:  true,
		PreAuthConnCallback: func(spac ssh.ServerPreAuthConn) {
			c.spac = spac
		},
		NoClientAuthCallback: func(cm ssh.ConnMetadata) (*ssh.Permissions, error) {
			perms, err := c.authenticate(cm)
			if err != nil {
				return nil, err
			}
			if strings.HasSuffix(cm.User(), "+password") {
				return nil, &ssh.PartialSuccessError{
					Next: ssh.ServerAuthCallbacks{
						PasswordCallback: func(_ ssh.ConnMetadata, _ []byte) (*ssh.Permissions, error) {
							return perms, nil
						},
					},
				}
			}
			return perms, nil
		},
		PasswordCallback: func(cm ssh.ConnMetadata, _ []byte) (*ssh.Permissions, error) {
			return c.authenticate(cm)
		},
		PublicKeyCallback: func(cm ssh.ConnMetadata, _ ssh.PublicKey) (*ssh.Permissions, error) {
			return c.authenticate(cm)
		},
		AuthLogCallback: func(_ ssh.ConnMetadata, _ string, err error) {
			if err == nil {
				c.authDone.Store(true)
			}
		},
	}
	for _, signer := range signers {
		cfg.AddHostKey(signer)
	}

	sconn, chans, reqs, err := ssh.NewServerConn(c.rawConn, cfg)
	if err != nil {
		return nil
	}
	c.mu.Lock()
	c.sconn = sconn
	c.mu.Unlock()
	go ssh.DiscardRequests(reqs)

	shellPath, homeDir := resolveTailscaleSSHShell(varRoot)
	for newChan := range chans {
		if newChan.ChannelType() != "session" {
			_ = newChan.Reject(ssh.UnknownChannelType, "unknown channel type")
			continue
		}
		ch, requests, err := newChan.Accept()
		if err != nil {
			continue
		}
		go sshserver.ServeSessionChannel(ctx, ch, requests, shellPath, homeDir, c.acceptEnv, false)
	}
	return nil
}
