package platform

import (
	"context"
	"errors"
)

const ContractVersion = 1

type Capability struct {
	ID                         string
	Available, RequiresConsent bool
	Reason                     string
}
type Event struct {
	Kind         string
	Capabilities []Capability
}
type Provider interface {
	ID() string
	Version() int
	Capabilities(context.Context) []Capability
	Watch(context.Context) (<-chan Event, error)
	Close() error
}
type Registry struct{ providers map[string]Provider }

func (r *Registry) Register(p Provider) error {
	if p == nil || p.Version() != ContractVersion || p.ID() == "" {
		return errors.New("unsupported platform contract")
	}
	if r.providers == nil {
		r.providers = map[string]Provider{}
	}
	if _, ok := r.providers[p.ID()]; ok {
		return errors.New("duplicate platform provider")
	}
	r.providers[p.ID()] = p
	return nil
}
func (r *Registry) Get(id string) (Provider, bool) { p, ok := r.providers[id]; return p, ok }
