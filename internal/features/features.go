package features

import (
	"errors"
	"net/http"
)

const ContractVersion = 1

type Action struct {
	ID, Label, Icon, Location            string
	RequiredGrants, RequiredCapabilities []string
}
type Module interface {
	ID() string
	ProtocolVersion() int
	RequiredGrants() []string
	RequiredCapabilities() []string
	FeatureFlags() []string
	RegisterBackend(*http.ServeMux)
	RegisterUIActions() []Action
}
type Registry struct{ modules map[string]Module }

func (r *Registry) Register(m Module) error {
	if m == nil || m.ID() == "" || m.ProtocolVersion() != ContractVersion {
		return errors.New("unsupported feature")
	}
	if r.modules == nil {
		r.modules = map[string]Module{}
	}
	if _, ok := r.modules[m.ID()]; ok {
		return errors.New("duplicate feature")
	}
	r.modules[m.ID()] = m
	return nil
}
func (r *Registry) Actions() []Action {
	a := []Action{}
	for _, m := range r.modules {
		a = append(a, m.RegisterUIActions()...)
	}
	return a
}
func (r *Registry) RegisterBackend(mux *http.ServeMux) {
	for _, m := range r.modules {
		m.RegisterBackend(mux)
	}
}
