package filesproviders

import (
	"context"
	"devicebridge/protocol"
	"errors"
	"io"
)

const ContractVersion = 1

var ErrReadOnly = errors.New("provider is read-only; write capability unavailable")

type Scope struct {
	Version      int
	RootID, Kind string
	Read, Write  bool
}
type StagedWrite interface {
	io.WriteCloser
	Commit(context.Context) error
	Cancel() error
}
type Provider interface {
	ID() string
	Scope() Scope
	List(context.Context, string, string, int) (protocol.Listing, error)
	Stat(context.Context, string) (protocol.Entry, error)
	OpenRead(context.Context, string) (io.ReadSeekCloser, error)
	OpenWriteStaged(context.Context, string) (StagedWrite, error)
	Close() error
}
type Registry struct{ providers map[string]Provider }

func (r *Registry) Register(p Provider) error {
	if p == nil || p.Scope().Version != ContractVersion || p.ID() == "" {
		return errors.New("unsupported filesystem contract")
	}
	if r.providers == nil {
		r.providers = map[string]Provider{}
	}
	if _, ok := r.providers[p.ID()]; ok {
		return errors.New("duplicate filesystem root")
	}
	r.providers[p.ID()] = p
	return nil
}
func (r *Registry) Get(id string) (Provider, bool) { p, ok := r.providers[id]; return p, ok }
func (r *Registry) All() []Provider {
	p := []Provider{}
	for _, v := range r.providers {
		p = append(p, v)
	}
	return p
}
func (r *Registry) Close() {
	for _, v := range r.providers {
		v.Close()
	}
}
