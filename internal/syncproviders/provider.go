// Package syncproviders reserves engine integration. No engine may bypass policy approval.
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
}

// Approval must be issued by the central ownership/policy controller, not a provider.
type Approval interface {
	Validate(context.Context, Plan) error
}
type Status struct {
	State    string
	Complete bool
	Error    string
}
type Provider interface {
	ID() string
	Version() int
	Detect(context.Context) error
	Prepare(context.Context, string) error
	Plan(context.Context, string) (Plan, error)
	StartApprovedSession(context.Context, Plan, Approval) error
	Status(context.Context, string) (Status, error)
	Stop(context.Context, string) error
	Recover(context.Context) error
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
