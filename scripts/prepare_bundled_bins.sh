#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts/linux app/assets/bin

host_arch=$(uname -m)
case "$host_arch" in
  x86_64|amd64) linux_key=linux-x86_64 ;;
  aarch64|arm64) linux_key=linux-arm64 ;;
  *) linux_key="linux-$host_arch" ;;
esac

# Build stripped Linux binaries for bundling inside Flutter apps (SSH bootstrap target upload).
go build -trimpath -ldflags='-s -w' -o artifacts/linux/bridge-agent ./cmd/bridge-agent
go build -trimpath -ldflags='-s -w' -o artifacts/linux/bridge-cli ./cmd/bridge-cli

rm -f app/assets/bin/*.gz "app/assets/bin/${linux_key}-"*.gzbin app/assets/bin/android-aarch64-*.gzbin
gzip -9 -n -c artifacts/linux/bridge-agent > "app/assets/bin/${linux_key}-bridge-agent.gzbin"
gzip -9 -n -c artifacts/linux/bridge-cli > "app/assets/bin/${linux_key}-bridge-cli.gzbin"
if [[ -x artifacts/linux/bridge-sync ]]; then
  gzip -1 -n -c artifacts/linux/bridge-sync > "app/assets/bin/${linux_key}-bridge-sync.gzbin"
fi

# The SSH installer reuses the Android arm64 executables from these same assets.
if [[ -f artifacts/android-arm64/libbridge_cli.so && -f artifacts/android-arm64/libbridge_agent.so ]]; then
  gzip -9 -n -c artifacts/android-arm64/libbridge_cli.so > app/assets/bin/android-arm64-libbridge_cli.gzbin
  gzip -9 -n -c artifacts/android-arm64/libbridge_agent.so > app/assets/bin/android-arm64-libbridge_agent.gzbin
fi

ls -lh app/assets/bin/*.gzbin
