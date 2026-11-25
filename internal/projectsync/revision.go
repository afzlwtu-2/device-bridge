package projectsync

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"devicebridge/internal/auth"
)

const (
	MaxRevisions  = 1024
	MaxChainBytes = 4 << 20
	offerLifetime = 15 * time.Minute
)

var groupID = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)

type Revision struct {
	Version  int    `json:"version"`
	Group    string `json:"group"`
	Sequence uint64 `json:"sequence"`
	Epoch    uint64 `json:"epoch"`
	Parent   string `json:"parent,omitempty"`
	Owner    string `json:"owner"`
	Manifest string `json:"manifest_xxh64"`
	Branch   string `json:"branch"`
	Head     string `json:"head"`
	Issued   int64  `json:"issued_utc"`
	Expires  int64  `json:"handoff_expires_utc,omitempty"`
	Nonce    string `json:"handoff_nonce,omitempty"`
}

type Proof struct {
	Certificate []byte `json:"certificate"`
	Signature   []byte `json:"signature"`
	Signed      int64  `json:"signed_utc"`
}

type SignedRevision struct {
	Revision Revision `json:"revision"`
	Author   Proof    `json:"author"`
	Accepted *Proof   `json:"accepted,omitempty"`
}

type JournalState struct {
	Chain    []SignedRevision `json:"chain"`
	Pending  *SignedRevision  `json:"pending,omitempty"`
	Rejected []string         `json:"rejected_handoffs,omitempty"`
}

type Rejection struct {
	Group    string `json:"group"`
	Revision string `json:"revision_hash"`
	Target   Proof  `json:"target"`
}

func (r Revision) Hash() string {
	data, _ := json.Marshal(r)
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

func (r Revision) matches(git GitState, digest string) bool {
	return r.Branch == git.Branch && r.Head == git.Head && r.Manifest == digest
}

func hexString(s string, n int) bool {
	if len(s) != n || s != strings.ToLower(s) {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}

func (r Revision) valid() bool {
	return r.Version == 1 && groupID.MatchString(r.Group) && r.Sequence > 0 && r.Epoch > 0 &&
		hexString(r.Owner, 64) && hexString(r.Manifest, 16) &&
		(hexString(r.Head, 40) || hexString(r.Head, 64)) &&
		len(r.Branch) > 0 && len(r.Branch) <= 512 && !strings.ContainsAny(r.Branch, "\x00\r\n") &&
		r.Issued > 0
}

func proofMessage(r Revision, role string, signed int64) []byte {
	return []byte(fmt.Sprintf("devicebridge-project/v1/%s/%d/%s", role, signed, r.Hash()))
}

func signProof(id *auth.Identity, r Revision, role string, signed int64) (Proof, error) {
	key, ok := id.Certificate.PrivateKey.(ed25519.PrivateKey)
	if !ok || len(id.Certificate.Certificate) != 1 {
		return Proof{}, errors.New("an Ed25519 DeviceBridge identity is required")
	}
	return Proof{
		Certificate: id.Certificate.Certificate[0],
		Signature:   ed25519.Sign(key, proofMessage(r, role, signed)),
		Signed:      signed,
	}, nil
}

func verifyProof(p Proof, r Revision, role, signer string) error {
	if len(p.Certificate) > 4096 || len(p.Signature) != ed25519.SignatureSize {
		return errors.New("invalid project proof")
	}
	cert, err := x509.ParseCertificate(p.Certificate)
	if err != nil {
		return err
	}
	at := time.Unix(p.Signed, 0)
	key, ok := cert.PublicKey.(ed25519.PublicKey)
	if !ok || auth.Fingerprint(cert) != signer || at.Before(cert.NotBefore) || at.After(cert.NotAfter) ||
		cert.CheckSignature(cert.SignatureAlgorithm, cert.RawTBSCertificate, cert.Signature) != nil ||
		!ed25519.Verify(key, proofMessage(r, role, p.Signed), p.Signature) {
		return errors.New("untrusted project proof")
	}
	return nil
}

func validateRevision(item SignedRevision, previous *Revision, offer bool) error {
	r := item.Revision
	if !r.valid() || item.Author.Signed != r.Issued {
		return errors.New("invalid project revision")
	}
	signer := r.Owner
	handoff := false
	if previous == nil {
		if r.Sequence != 1 || r.Epoch != 1 || r.Parent != "" || r.Expires != 0 || r.Nonce != "" {
			return errors.New("invalid project genesis")
		}
	} else {
		handoff = r.Owner != previous.Owner
		signer = previous.Owner
		if r.Parent != previous.Hash() || r.Group != previous.Group ||
			r.Sequence != previous.Sequence+1 || r.Issued < previous.Issued {
			return errors.New("invalid project revision history")
		}
		if handoff {
			if r.Epoch != previous.Epoch+1 || !hexString(r.Nonce, 32) ||
				r.Expires-r.Issued != int64(offerLifetime/time.Second) ||
				r.Manifest != previous.Manifest || r.Branch != previous.Branch || r.Head != previous.Head {
				return errors.New("handoff requires the current approved project contents")
			}
		} else if r.Epoch != previous.Epoch || r.Expires != 0 || r.Nonce != "" {
			return errors.New("invalid project ownership epoch")
		}
	}
	if err := verifyProof(item.Author, r, "author", signer); err != nil {
		return err
	}
	if offer {
		if !handoff || item.Accepted != nil {
			return errors.New("invalid handoff offer")
		}
		return nil
	}
	if !handoff {
		if item.Accepted != nil {
			return errors.New("unexpected handoff receipt")
		}
		return nil
	}
	ack := item.Accepted
	if ack == nil || ack.Signed < r.Issued || ack.Signed > r.Expires {
		return errors.New("handoff needs a timely signed receipt")
	}
	return verifyProof(*ack, r, "accept", r.Owner)
}

func (j JournalState) Validate() error {
	if len(j.Chain) == 0 || len(j.Chain) > MaxRevisions || len(j.Rejected) > MaxRevisions {
		return errors.New("invalid project chain length")
	}
	for _, hash := range j.Rejected {
		if !hexString(hash, 64) {
			return errors.New("invalid rejected handoff reference")
		}
	}
	var previous *Revision
	for _, item := range j.Chain {
		if err := validateRevision(item, previous, false); err != nil {
			return err
		}
		revision := item.Revision
		previous = &revision
	}
	if j.Pending != nil {
		if len(j.Chain) == MaxRevisions {
			return errors.New("project chain exceeds its supported size")
		}
		return validateRevision(*j.Pending, previous, true)
	}
	return nil
}

func (j JournalState) Current() Revision {
	return j.Chain[len(j.Chain)-1].Revision
}

func (j JournalState) CanWrite(id string) bool {
	return len(j.Chain) > 0 && j.Pending == nil && j.Current().Owner == id
}

func chainPrefix(known, incoming []SignedRevision) bool {
	if len(known) > len(incoming) {
		return false
	}
	for i := range known {
		if known[i].Revision.Hash() != incoming[i].Revision.Hash() {
			return false
		}
	}
	return true
}
