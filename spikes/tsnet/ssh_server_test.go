package main

import (
	"net/netip"
	"strings"
	"testing"
	"time"

	"tailscale.com/tailcfg"
)

func TestEvalSSHPolicyRules(t *testing.T) {
	now := time.Unix(1700000000, 0)
	expired := now.Add(-time.Minute)
	future := now.Add(time.Hour)
	src := netip.MustParseAddrPort("100.64.0.9:51234")
	node := (&tailcfg.Node{
		ID:       42,
		StableID: "node-laptop-1",
	}).View()
	uprof := tailcfg.UserProfile{LoginName: "alice@example.com"}

	pol := &tailcfg.SSHPolicy{
		Rules: []*tailcfg.SSHRule{
			{
				RuleExpires: &expired,
				Principals:  []*tailcfg.SSHPrincipal{{Any: true}},
				SSHUsers:    map[string]string{"*": "="},
				Action:      &tailcfg.SSHAction{Accept: true},
			},
			{
				RuleExpires: &future,
				Principals:  []*tailcfg.SSHPrincipal{{UserLogin: "alice@example.com"}},
				SSHUsers:    map[string]string{"*": "="},
				AcceptEnv:   []string{"COLORTERM", "LC_*"},
				Action:      &tailcfg.SSHAction{Accept: true, Message: "welcome"},
			},
		},
	}

	action, localUser, acceptEnv, rule, res := evalSSHPolicy(pol, now, src, node, uprof, "afzl")
	if res != policyAccepted || action == nil || !action.Accept || localUser != "afzl" || rule == nil {
		t.Fatalf("expected accepted for afzl, got res=%v action=%+v localUser=%q", res, action, localUser)
	}
	if len(acceptEnv) != 2 || !allowEnvKey("LC_ALL", acceptEnv) || allowEnvKey("LD_PRELOAD", acceptEnv) {
		t.Fatalf("unexpected acceptEnv behavior: %v", acceptEnv)
	}

	// autogroup:nonroot ("*": "=") must not permit root.
	_, _, _, _, rootRes := evalSSHPolicy(pol, now, src, node, uprof, "root")
	if rootRes != policyRejectedUser {
		t.Fatalf("expected policyRejectedUser for root under = rule, got %v", rootRes)
	}

	// Non-matching userLogin must be rejected.
	_, _, _, _, bobRes := evalSSHPolicy(pol, now, src, node, tailcfg.UserProfile{LoginName: "bob@example.com"}, "afzl")
	if bobRes != policyRejected {
		t.Fatalf("expected policyRejected for bob, got %v", bobRes)
	}
}

func TestTailscaleSSHHostKeysAndShellResolution(t *testing.T) {
	tmp := t.TempDir()
	varRoot := tmp + "/devicebridge/tailnet/node"
	keys, err := getTailscaleSSHHostKeyPublicStrings(varRoot, func(string, ...any) {})
	if err != nil || len(keys) == 0 || !strings.HasPrefix(keys[0], "ssh-ed25519 ") {
		t.Fatalf("unexpected host keys: %v (err=%v)", keys, err)
	}
	shell, _ := resolveTailscaleSSHShell(varRoot)
	if shell == "" {
		t.Fatal("expected non-empty fallback shell")
	}
}
