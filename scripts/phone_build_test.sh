#!/usr/bin/env bash
# Laptop-authoritative source -> unique disposable native Termux snapshot.
# No package/service/root/network changes; uses only existing authenticated SSH.
set -euo pipefail
cd "$(dirname "$0")/.."
phone_host=${1:-afzl@10.100.102.33}
phone_port=${2:-8022}
# USB example: adb -s SERIAL forward tcp:18022 tcp:8022
# Keep verifying the already trusted phone identity when using that tunnel.
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes)
if [[ -n ${DEVICEBRIDGE_PHONE_HOST_KEY_ALIAS:-} ]]; then
  ssh_options+=(-o "HostKeyAlias=$DEVICEBRIDGE_PHONE_HOST_KEY_ALIAS")
fi
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
local_run=".work/phone-$run_id"
mkdir -p "$local_run" artifacts/termux-arm64 docs/test-evidence
vendor_archive=()
# Useful over USB when the handset cannot reach the public Go module proxy.
if [[ ${DEVICEBRIDGE_PHONE_OFFLINE_DEPS:-0} == 1 ]]; then
  go mod vendor -o "$local_run/vendor"
  vendor_archive=(-C "$PWD/$local_run" vendor)
fi
tar --exclude=.git --exclude=.work --exclude=artifacts --exclude=app --exclude=.agent-session-lock --exclude=.devicebridge-agent-session.lock -czf "$local_run/source.tar.gz" . "${vendor_archive[@]}"
source_xxh64=$(xxhsum -H1 -q < "$local_run/source.tar.gz" | cut -d ' ' -f 1)
printf '%s  source.tar.gz\n' "$source_xxh64" > "$local_run/source.xxh64"
remote_run=$(ssh -p "$phone_port" "${ssh_options[@]}" "$phone_host" 'mktemp -d /data/data/com.termux/files/usr/tmp/devicebridge-build.XXXXXXXX')
printf '%s\n' "$remote_run" > "$local_run/remote-path"
scp -q -P "$phone_port" "${ssh_options[@]}" "$local_run/source.tar.gz" "$phone_host:$remote_run/source.tar.gz"
ssh -p "$phone_port" "${ssh_options[@]}" "$phone_host" bash -s -- "$remote_run" "$source_xxh64" <<'REMOTE' 2>&1 | tee "docs/test-evidence/termux-$run_id.log"
set -euo pipefail
cd "$1"
printf '%s  source.tar.gz\n' "$2" | xxhsum -H1 --check --strict
tar -xzf source.tar.gz
go version
go test ./...
go vet ./...
mkdir -p out
go build -trimpath -o out/bridge-agent ./cmd/bridge-agent
go build -trimpath -o out/bridge-cli ./cmd/bridge-cli
xxhsum -H1 out/bridge-agent out/bridge-cli > out/binaries.xxh64
cat out/binaries.xxh64
REMOTE
scp -q -P "$phone_port" "${ssh_options[@]}" "$phone_host:$remote_run/out/bridge-agent" artifacts/termux-arm64/bridge-agent
scp -q -P "$phone_port" "${ssh_options[@]}" "$phone_host:$remote_run/out/bridge-cli" artifacts/termux-arm64/bridge-cli
scp -q -P "$phone_port" "${ssh_options[@]}" "$phone_host:$remote_run/out/binaries.xxh64" "$local_run/binaries.xxh64"
sed 's|out/|artifacts/termux-arm64/|' "$local_run/binaries.xxh64" | xxhsum -H1 --check --strict
printf 'Disposable phone snapshot retained at %s (no daemon started).\n' "$remote_run"
