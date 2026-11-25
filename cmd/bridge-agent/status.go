package main

import (
	"devicebridge/internal/server"
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

type agentStatus struct {
	AgentSSHEnabled bool   `json:"agent_ssh_enabled"`
	Running         bool   `json:"running"`
	PID             int    `json:"pid"`
	Endpoint        string `json:"endpoint"`
	Interface       string `json:"interface"`
	CIDR            string `json:"cidr"`
	Discovery       bool   `json:"discovery"`
	server.AgentStatsSnapshot
}

type agentStatusPublisher struct {
	path string
	last *agentStatus
}

func (p *agentStatusPublisher) publish(status agentStatus) error {
	if p.last != nil && *p.last == status {
		return nil
	}
	f, err := os.CreateTemp(filepath.Dir(p.path), ".agent-status-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	err = json.NewEncoder(f).Encode(struct {
		agentStatus
		UpdatedUnix int64 `json:"updated_unix"`
	}{status, time.Now().Unix()})
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err := os.Rename(f.Name(), p.path); err != nil {
		return err
	}
	p.last = &status
	return nil
}
