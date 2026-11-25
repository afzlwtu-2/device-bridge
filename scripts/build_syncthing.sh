#!/usr/bin/env bash
# Build a pinned external engine for DeviceBridge's app UID, never Termux/root.
set -euo pipefail
cd "$(dirname "$0")/.."
project_root=$PWD
version=2.1.7
archive_xxh64=51e3f5a20c6ed3d3
cache="$project_root/.work/syncthing-native"
target=${DEVICEBRIDGE_BUILD_TARGET:-both}
mkdir -p "$cache" app/assets/bin
if [[ "$target" != linux ]]; then
  source scripts/android_target.sh
  mkdir -p "$android_output" "$android_jni"
fi
if [[ "$target" != android ]]; then mkdir -p artifacts/linux; fi
if [[ ! -f "$cache/source.tar.gz" ]]; then
  curl --fail --location --max-time 120 "https://codeload.github.com/syncthing/syncthing/tar.gz/refs/tags/v$version" -o "$cache/source.tar.gz.part"
  mv "$cache/source.tar.gz.part" "$cache/source.tar.gz"
fi
printf '%s  %s\n' "$archive_xxh64" "$cache/source.tar.gz" | xxhsum -H1 --check --strict
if [[ ! -f "$cache/syncthing-$version/go.mod" ]]; then
  tar -xzf "$cache/source.tar.gz" -C "$cache"
fi
cd "$cache/syncthing-$version"
go run ./script/genassets.go gui > lib/api/auto/gui.files.go
# Match upstream's external-engine build: no automatic upgrades, C SQLite,
# and no root or system modifications. Keep dependencies outside our go.mod.
engine_flags="-s -w -checklinkname=0 -X github.com/syncthing/syncthing/lib/build.Version=v$version"
if [[ "$target" != android ]]; then
  CGO_ENABLED=1 go build -trimpath -tags noupgrade -ldflags="$engine_flags" -o "$project_root/artifacts/linux/bridge-sync" ./cmd/syncthing
fi
if [[ "$target" == linux ]]; then exit 0; fi
GOOS=android GOARCH="$android_arch" CGO_ENABLED=1 CC="$compiler" go build -trimpath -buildmode=pie -tags noupgrade -ldflags="$engine_flags -extldflags=-Wl,-z,max-page-size=16384" -o "$project_root/$android_output/libbridge_sync.so" ./cmd/syncthing
cd "$project_root"
cp "$android_output/libbridge_sync.so" "$android_jni/libbridge_sync.so"
gzip -9 -n -c "$android_output/libbridge_sync.so" > "app/assets/bin/android-$android_arch-libbridge_sync.gzbin"
cp "$cache/syncthing-$version/LICENSE" docs/licenses/syncthing-v2.1.7.txt
xxhsum -H1 "$android_output/libbridge_sync.so"
