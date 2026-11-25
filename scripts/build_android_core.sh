#!/usr/bin/env bash
# NDK-built app-private executable. No gomobile dependency, Termux or root needed
# by the installed app. APK execution still requires separate device acceptance.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/android_target.sh
mkdir -p "$android_jni" "$android_output"
GOOS=android GOARCH="$android_arch" CGO_ENABLED=1 CC="$compiler" go build -trimpath -buildmode=pie -ldflags='-s -w -extldflags=-Wl,-z,max-page-size=16384' -o "$android_output/libbridge_cli.so" ./cmd/bridge-cli
GOOS=android GOARCH="$android_arch" CGO_ENABLED=1 CC="$compiler" go build -trimpath -buildmode=pie -ldflags='-s -w -extldflags=-Wl,-z,max-page-size=16384' -o "$android_output/libbridge_agent.so" ./cmd/bridge-agent
"$compiler" -shared -fPIC -O2 -Wl,-s -Wl,-z,max-page-size=16384 -ldl internal/bootstrap/termux_adapt/db_termux_adapt.c -o "$android_output/libdb_termux_adapt.so"
cp "$android_output/libbridge_cli.so" "$android_jni/libbridge_cli.so"
cp "$android_output/libbridge_agent.so" "$android_jni/libbridge_agent.so"
cp "$android_output/libdb_termux_adapt.so" "$android_jni/libdb_termux_adapt.so"
mkdir -p app/assets/bin
gzip -9 -n -c "$android_output/libbridge_cli.so" > "app/assets/bin/android-$android_arch-libbridge_cli.gzbin"
gzip -9 -n -c "$android_output/libbridge_agent.so" > "app/assets/bin/android-$android_arch-libbridge_agent.gzbin"
xxhsum -H1 "$android_output/libbridge_cli.so"
