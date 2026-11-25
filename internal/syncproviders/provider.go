// Package syncproviders defines the registered sync engines and approval contract.
package syncproviders

import (
	"context"
	"errors"
	"time"
)

const ContractVersion = 1

type Plan struct {
	ID, Group, Owner, ManifestHash string
	Epoch                          uint64
	Expires                        time.Time
	Interface, CIDR                string
	Listen, PeerEndpoint           string
	Route                          string
	RemoteApproved                 bool
	// Host-constructed descriptor lease; never accepted from a peer request.
	SourcePath string
	// Host-owned endpoint adapters preserve Android's approved socket binding.
	EngineListen, EnginePeerEndpoint string
}

// Approval must be issued by the central ownership/policy controller, not a provider.
type Approval interface {
	Validate(context.Context, Plan) error
}
type Digest struct {
	XXH64 string `json:"manifest_xxh64"`
	Bytes int64  `json:"bytes"`
	Items int    `json:"items"`
}

type Receipt struct {
	Group    string `json:"group"`
	Role     string `json:"role"`
	Activity string `json:"activity"`
	Digest
}

type Provider interface {
	ID() string
	Version() int
	Run(context.Context, Plan, Approval) (Receipt, error)
}
type Registry struct{ providers map[string]Provider }

func (r *Registry) Register(p Provider) error {
	if p == nil || p.Version() != ContractVersion || p.ID() == "" {
		return errors.New("unsupported sync contract")
	}
	if r.providers == nil {
		r.providers = map[string]Provider{}
	}
	if _, ok := r.providers[p.ID()]; ok {
		return errors.New("duplicate sync provider")
	}
	r.providers[p.ID()] = p
	return nil
}
func (r *Registry) Get(id string) (Provider, bool) { p, ok := r.providers[id]; return p, ok }
