#!/usr/bin/env bash
# Laptop-authoritative source -> unique disposable native Termux snapshot.
# No package/service/root/network changes; uses only existing authenticated SSH.
set -euo pipefail
cd "$(dirname "$0")/.."
phone_host=${1:-afzl@10.100.102.33}
phone_port=${2:-8022}
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
local_run=".work/phone-$run_id"
mkdir -p "$local_run" artifacts/termux-arm64 docs/test-evidence
tar --exclude=.git --exclude=.work --exclude=artifacts --exclude=app --exclude=.devicebridge-agent-session.lock -czf "$local_run/source.tar.gz" .
sha256sum "$local_run/source.tar.gz" > "$local_run/source.sha256"
remote_run=$(ssh -p "$phone_port" -o BatchMode=yes -o StrictHostKeyChecking=yes "$phone_host" 'mktemp -d /data/data/com.termux/files/usr/tmp/devicebridge-build.XXXXXXXX')
printf '%s\n' "$remote_run" > "$local_run/remote-path"
scp -q -P "$phone_port" "$local_run/source.tar.gz" "$phone_host:$remote_run/source.tar.gz"
ssh -p "$phone_port" -o BatchMode=yes -o StrictHostKeyChecking=yes "$phone_host" bash -s -- "$remote_run" <<'REMOTE' 2>&1 | tee "docs/test-evidence/termux-$run_id.log"
set -euo pipefail
cd "$1"
tar -xzf source.tar.gz
go version
sha256sum source.tar.gz
go test ./...
go vet ./...
mkdir -p out
go build -trimpath -o out/bridge-agent ./cmd/bridge-agent
go build -trimpath -o out/bridge-cli ./cmd/bridge-cli
sha256sum out/bridge-agent out/bridge-cli
REMOTE
scp -q -P "$phone_port" "$phone_host:$remote_run/out/bridge-agent" artifacts/termux-arm64/bridge-agent
scp -q -P "$phone_port" "$phone_host:$remote_run/out/bridge-cli" artifacts/termux-arm64/bridge-cli
printf 'Disposable phone snapshot retained at %s (no daemon started).\n' "$remote_run"
