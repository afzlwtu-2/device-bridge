// Package transport describes byte streams independently of application features.
package transport

import (
	"context"
	"errors"
	"net"
	"sync"
	"time"
)

const ContractVersion = 1

type Capabilities struct {
	Version            int
	Streams, Discovery bool
}
type NetworkCost struct {
	Metered, Internet, Relayed bool
	Known                      bool
}
type Candidate struct {
	DeviceID        string        `json:"device_id"`
	DeviceName      string        `json:"device_name,omitempty"`
	Endpoint        string        `json:"endpoint"`
	Interface       string        `json:"interface"`
	Transport       string        `json:"transport"`
	PathKind        string        `json:"path_kind,omitempty"`
	Relay           string        `json:"relay,omitempty"`
	Observed        time.Time     `json:"observed"`
	Cost            NetworkCost   `json:"cost"`
	Direct          bool          `json:"direct"`
	RTT             time.Duration `json:"rtt"`
	BytesPerSecond  float64       `json:"bytes_per_second"`
	MiBPerSecond    float64       `json:"mib_per_second"`
	RequiredActions []string      `json:"required_actions,omitempty"`
}
type Provider interface {
	ID() string
	Capabilities() Capabilities
	DiscoverCandidates(context.Context) ([]Candidate, error)
	Probe(context.Context, Candidate) (Candidate, error)
	Dial(context.Context, Candidate) (net.Conn, error)
	Listen(context.Context, string) (net.Listener, error)
	NetworkCost(Candidate) NetworkCost
	Close() error
}
type Registry struct {
	mu        sync.RWMutex
	providers map[string]Provider
}

func (r *Registry) Register(p Provider) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if p == nil || p.ID() == "" || p.Capabilities().Version != ContractVersion {
		return errors.New("unsupported transport contract")
	}
	if r.providers == nil {
		r.providers = map[string]Provider{}
	}
	if _, ok := r.providers[p.ID()]; ok {
		return errors.New("duplicate transport")
	}
	r.providers[p.ID()] = p
	return nil
}
func (r *Registry) Get(id string) (Provider, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p, ok := r.providers[id]
	return p, ok
}
