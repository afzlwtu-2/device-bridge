#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test -z "$(gofmt -l cmd internal protocol test)"
go vet ./...
go test -race ./...
mkdir -p artifacts/linux
go build -trimpath -o artifacts/linux/bridge-agent ./cmd/bridge-agent
go build -trimpath -o artifacts/linux/bridge-cli ./cmd/bridge-cli
