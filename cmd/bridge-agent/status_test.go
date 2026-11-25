package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestAgentStatusSkipsUnchangedSamples(t *testing.T) {
	path := filepath.Join(t.TempDir(), "agent-status.json")
	publisher := agentStatusPublisher{path: path}
	status := agentStatus{Running: true, PID: 7}
	if err := publisher.publish(status); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := publisher.publish(status); err != nil {
		t.Fatal(err)
	}
	same, err := os.Stat(path)
	if err != nil || !os.SameFile(before, same) {
		t.Fatalf("idle sample replaced the status file: %v", err)
	}
	status.ActiveConns = 1
	if err := publisher.publish(status); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var got agentStatus
	if err := json.Unmarshal(data, &got); err != nil || got != status {
		t.Fatalf("changed sample not published: %+v, %v", got, err)
	}
}
