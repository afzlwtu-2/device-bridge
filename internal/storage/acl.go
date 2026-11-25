package storage

import (
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"regexp"
	"slices"
	"sort"
	"strings"
)

const (
	aclPolicyKey    = "acl-policy-v1"
	peerTagsPrefix  = "peer-tags-v1:"
	maxACLGroups    = 64
	maxACLRules     = 256
	maxTagsPerPeer  = 32
	ACLResourceAll  = "*"
	ACLActionAccept = "accept"
	ACLActionDeny   = "deny"
)

var (
	aclNameRe   = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)
	aclRuleIDRe = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,64}$`)
)

// AllACLResources lists canonical ACL destination resource scopes.
var AllACLResources = []string{
	"files:browse",
	"files:read",
	"ssh",
	"share:text",
	"share:file",
	"sync",
	"termux",
	"actions",
	"link",
}

type ACLRule struct {
	ID          string   `json:"id"`
	Action      string   `json:"action"` // accept | deny
	Src         []string `json:"src"`
	Dst         []string `json:"dst"`
	Description string   `json:"description,omitempty"`
}

type ACLPolicy struct {
	Version int                 `json:"version"`
	Enabled bool                `json:"enabled"`
	Groups  map[string][]string `json:"groups"`
	Rules   []ACLRule           `json:"rules"`
}

type ACLDecision struct {
	Resource    string `json:"resource"`
	Allowed     bool   `json:"allowed"`
	MatchedRule string `json:"matched_rule,omitempty"`
	Reason      string `json:"reason"`
}

type PeerACLEvaluation struct {
	PeerID    string        `json:"peer_id"`
	Name      string        `json:"name"`
	Status    string        `json:"status"`
	Tags      []string      `json:"tags"`
	Groups    []string      `json:"groups"`
	Enabled   bool          `json:"enabled"`
	Decisions []ACLDecision `json:"decisions"`
}

func defaultACLPolicy() ACLPolicy {
	return ACLPolicy{
		Version: 1,
		Enabled: false,
		Groups:  map[string][]string{},
		Rules:   []ACLRule{},
	}
}

// PresetTrustedACLPolicy returns a Tailscale-style starter policy where tag:trusted
// devices have full access and tag:guest devices only get text sharing + file browse.
func PresetTrustedACLPolicy(existingGroups map[string][]string) ACLPolicy {
	groups := map[string][]string{}
	for k, v := range existingGroups {
		groups[k] = append([]string(nil), v...)
	}
	return ACLPolicy{
		Version: 1,
		Enabled: true,
		Groups:  groups,
		Rules: []ACLRule{
			{
				ID:          "trusted-all",
				Action:      ACLActionAccept,
				Src:         []string{"tag:trusted"},
				Dst:         []string{"*"},
				Description: "Trusted devices can access all services on this device",
			},
			{
				ID:          "guest-limited",
				Action:      ACLActionAccept,
				Src:         []string{"tag:guest"},
				Dst:         []string{"share:text", "files:browse"},
				Description: "Guest devices can send text and browse shared folders only",
			},
		},
	}
}

func normalizePeerID(raw string) (string, bool) {
	id := strings.ToLower(strings.TrimSpace(raw))
	if len(id) != 64 {
		return "", false
	}
	if _, err := hex.DecodeString(id); err != nil {
		return "", false
	}
	return id, true
}

func NormalizeACLTag(raw string) (string, error) {
	tag := strings.ToLower(strings.TrimSpace(raw))
	tag = strings.TrimPrefix(tag, "tag:")
	if !aclNameRe.MatchString(tag) {
		return "", errors.New("invalid tag name: use lowercase letters, digits, '-' or '_'")
	}
	return "tag:" + tag, nil
}

func NormalizeACLGroup(raw string) (string, error) {
	grp := strings.ToLower(strings.TrimSpace(raw))
	grp = strings.TrimPrefix(grp, "group:")
	if !aclNameRe.MatchString(grp) {
		return "", errors.New("invalid group name: use lowercase letters, digits, '-' or '_'")
	}
	return "group:" + grp, nil
}

func normalizeACLSource(raw string) (string, error) {
	s := strings.ToLower(strings.TrimSpace(raw))
	switch {
	case s == "*":
		return "*", nil
	case strings.HasPrefix(s, "tag:"):
		return NormalizeACLTag(s)
	case strings.HasPrefix(s, "group:"):
		return NormalizeACLGroup(s)
	case strings.HasPrefix(s, "peer:"):
		id, ok := normalizePeerID(strings.TrimPrefix(s, "peer:"))
		if !ok {
			return "", errors.New("invalid peer selector")
		}
		return "peer:" + id, nil
	default:
		if id, ok := normalizePeerID(s); ok {
			return "peer:" + id, nil
		}
		return "", errors.New("invalid ACL source selector")
	}
}

func normalizeACLDest(raw string) (string, error) {
	d := strings.ToLower(strings.TrimSpace(raw))
	switch d {
	case "*", "files", "files:browse", "files:read", "ssh", "share", "share:text", "share:file", "sync", "termux", "actions", "link":
		return d, nil
	default:
		return "", errors.New("invalid ACL resource scope: " + raw)
	}
}

func sanitizeACLPolicy(in ACLPolicy) (ACLPolicy, error) {
	out := defaultACLPolicy()
	if in.Version != 0 && in.Version != 1 {
		return out, errors.New("unsupported ACL policy version")
	}
	out.Enabled = in.Enabled
	if len(in.Groups) > maxACLGroups {
		return out, errors.New("too many ACL groups")
	}
	for rawGrp, members := range in.Groups {
		grp, err := NormalizeACLGroup(rawGrp)
		if err != nil {
			return out, err
		}
		seen := map[string]bool{}
		clean := make([]string, 0, len(members))
		for _, m := range members {
			id, ok := normalizePeerID(m)
			if !ok {
				return out, errors.New("invalid peer ID in group " + grp)
			}
			if !seen[id] {
				seen[id] = true
				clean = append(clean, id)
			}
		}
		sort.Strings(clean)
		out.Groups[grp] = clean
	}
	if len(in.Rules) > maxACLRules {
		return out, errors.New("too many ACL rules")
	}
	seenIDs := map[string]bool{}
	for idx, r := range in.Rules {
		act := strings.ToLower(strings.TrimSpace(r.Action))
		if act == "" {
			act = ACLActionAccept
		}
		if act != ACLActionAccept && act != ACLActionDeny {
			return out, errors.New("invalid ACL action")
		}
		id := strings.TrimSpace(r.ID)
		if id == "" {
			id = "rule-" + string(rune('0'+idx%10))
		}
		if !aclRuleIDRe.MatchString(id) {
			return out, errors.New("invalid ACL rule id")
		}
		if seenIDs[id] {
			return out, errors.New("duplicate ACL rule id: " + id)
		}
		seenIDs[id] = true
		if len(r.Src) == 0 || len(r.Dst) == 0 {
			return out, errors.New("ACL rule requires at least one source and destination")
		}
		cleanSrc := make([]string, 0, len(r.Src))
		for _, s := range r.Src {
			ns, err := normalizeACLSource(s)
			if err != nil {
				return out, err
			}
			if !slices.Contains(cleanSrc, ns) {
				cleanSrc = append(cleanSrc, ns)
			}
		}
		cleanDst := make([]string, 0, len(r.Dst))
		for _, d := range r.Dst {
			nd, err := normalizeACLDest(d)
			if err != nil {
				return out, err
			}
			if !slices.Contains(cleanDst, nd) {
				cleanDst = append(cleanDst, nd)
			}
		}
		desc := strings.TrimSpace(r.Description)
		if len(desc) > 256 {
			desc = desc[:256]
		}
		out.Rules = append(out.Rules, ACLRule{
			ID:          id,
			Action:      act,
			Src:         cleanSrc,
			Dst:         cleanDst,
			Description: desc,
		})
	}
	return out, nil
}

func (s *Store) ACLPolicy(ctx context.Context) (ACLPolicy, error) {
	var raw string
	err := s.DB.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", aclPolicyKey).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return defaultACLPolicy(), nil
	}
	if err != nil {
		return defaultACLPolicy(), err
	}
	var p ACLPolicy
	if err = json.Unmarshal([]byte(raw), &p); err != nil {
		return defaultACLPolicy(), err
	}
	if p.Groups == nil {
		p.Groups = map[string][]string{}
	}
	if p.Rules == nil {
		p.Rules = []ACLRule{}
	}
	if p.Version == 0 {
		p.Version = 1
	}
	return p, nil
}

func (s *Store) SaveACLPolicy(ctx context.Context, in ACLPolicy) (ACLPolicy, error) {
	clean, err := sanitizeACLPolicy(in)
	if err != nil {
		return clean, err
	}
	b, err := json.Marshal(clean)
	if err != nil {
		return clean, err
	}
	_, err = s.DB.ExecContext(ctx, "INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", aclPolicyKey, string(b))
	return clean, err
}

func (s *Store) PeerTags(ctx context.Context, peer string) ([]string, error) {
	id, ok := normalizePeerID(peer)
	if !ok {
		return nil, ErrDenied
	}
	var raw string
	err := s.DB.QueryRowContext(ctx, "SELECT value FROM preferences WHERE key=?", peerTagsPrefix+id).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	var tags []string
	if err = json.Unmarshal([]byte(raw), &tags); err != nil {
		return nil, err
	}
	if tags == nil {
		tags = []string{}
	}
	return tags, nil
}

func (s *Store) SetPeerTags(ctx context.Context, peer string, tags []string) ([]string, error) {
	p, err := s.Peer(peer)
	if err != nil || p.Status == "revoked" {
		return nil, ErrDenied
	}
	if len(tags) > maxTagsPerPeer {
		return nil, errors.New("too many tags on one device")
	}
	seen := map[string]bool{}
	clean := make([]string, 0, len(tags))
	for _, t := range tags {
		nt, err := NormalizeACLTag(t)
		if err != nil {
			return nil, err
		}
		if !seen[nt] {
			seen[nt] = true
			clean = append(clean, nt)
		}
	}
	sort.Strings(clean)
	if len(clean) == 0 {
		_, err = s.DB.ExecContext(ctx, "DELETE FROM preferences WHERE key=?", peerTagsPrefix+p.ID)
		return []string{}, err
	}
	b, _ := json.Marshal(clean)
	_, err = s.DB.ExecContext(ctx, "INSERT INTO preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", peerTagsPrefix+p.ID, string(b))
	return clean, err
}

func (s *Store) SetACLGroup(ctx context.Context, name string, members []string, deleteGroup bool) (ACLPolicy, error) {
	grp, err := NormalizeACLGroup(name)
	if err != nil {
		return ACLPolicy{}, err
	}
	policy, err := s.ACLPolicy(ctx)
	if err != nil {
		return policy, err
	}
	if deleteGroup {
		delete(policy.Groups, grp)
	} else {
		policy.Groups[grp] = members
	}
	return s.SaveACLPolicy(ctx, policy)
}

func matchACLDest(ruleDst, resource string) bool {
	if ruleDst == ACLResourceAll || ruleDst == resource {
		return true
	}
	if ruleDst == "files" && (resource == "files:browse" || resource == "files:read") {
		return true
	}
	if ruleDst == "share" && (resource == "share:text" || resource == "share:file") {
		return true
	}
	return false
}

func matchACLSource(src, peerID string, peerTags []string, groups map[string][]string) bool {
	if src == "*" {
		return true
	}
	if src == "peer:"+peerID {
		return true
	}
	if strings.HasPrefix(src, "tag:") {
		return slices.Contains(peerTags, src)
	}
	if strings.HasPrefix(src, "group:") {
		return slices.Contains(groups[src], peerID)
	}
	return false
}

func evaluateRuleSet(policy ACLPolicy, peerID string, peerTags []string, resource string) ACLDecision {
	if !policy.Enabled {
		return ACLDecision{Resource: resource, Allowed: true, Reason: "ACL enforcement disabled (per-peer grants apply)"}
	}
	// Explicit deny rules always take precedence over accept rules.
	var matchedAccept string
	for _, r := range policy.Rules {
		srcMatch := slices.ContainsFunc(r.Src, func(src string) bool {
			return matchACLSource(src, peerID, peerTags, policy.Groups)
		})
		if !srcMatch {
			continue
		}
		dstMatch := slices.ContainsFunc(r.Dst, func(dst string) bool {
			return matchACLDest(dst, resource)
		})
		if !dstMatch {
			continue
		}
		if r.Action == ACLActionDeny {
			return ACLDecision{Resource: resource, Allowed: false, MatchedRule: r.ID, Reason: "Denied by rule " + r.ID}
		}
		if matchedAccept == "" {
			matchedAccept = r.ID
		}
	}
	if matchedAccept != "" {
		return ACLDecision{Resource: resource, Allowed: true, MatchedRule: matchedAccept, Reason: "Allowed by rule " + matchedAccept}
	}
	return ACLDecision{Resource: resource, Allowed: false, Reason: "Denied by default-deny ACL"}
}

// CheckPeerACL checks whether ACL enforcement is active and whether the paired peer
// is permitted to access the given resource.
func (s *Store) CheckPeerACL(ctx context.Context, peer, resource string) (enabled bool, allowed bool, err error) {
	p, err := s.Peer(peer)
	if err != nil || p.Status != "paired" {
		return false, false, ErrDenied
	}
	policy, err := s.ACLPolicy(ctx)
	if err != nil {
		return false, false, err
	}
	if !policy.Enabled {
		return false, true, nil
	}
	tags, err := s.PeerTags(ctx, p.ID)
	if err != nil {
		return true, false, err
	}
	dec := evaluateRuleSet(policy, p.ID, tags, resource)
	return true, dec.Allowed, nil
}

func (s *Store) EvaluatePeerACL(ctx context.Context, peer string) (PeerACLEvaluation, error) {
	p, err := s.Peer(peer)
	if err != nil {
		return PeerACLEvaluation{}, err
	}
	policy, err := s.ACLPolicy(ctx)
	if err != nil {
		return PeerACLEvaluation{}, err
	}
	tags, err := s.PeerTags(ctx, p.ID)
	if err != nil {
		return PeerACLEvaluation{}, err
	}
	groups := []string{}
	for g, members := range policy.Groups {
		if slices.Contains(members, p.ID) {
			groups = append(groups, g)
		}
	}
	sort.Strings(groups)
	decisions := make([]ACLDecision, 0, len(AllACLResources))
	for _, res := range AllACLResources {
		if p.Status != "paired" {
			decisions = append(decisions, ACLDecision{Resource: res, Allowed: false, Reason: "Peer status is " + p.Status})
			continue
		}
		decisions = append(decisions, evaluateRuleSet(policy, p.ID, tags, res))
	}
	return PeerACLEvaluation{
		PeerID:    p.ID,
		Name:      p.Name,
		Status:    p.Status,
		Tags:      tags,
		Groups:    groups,
		Enabled:   policy.Enabled,
		Decisions: decisions,
	}, nil
}
