#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../spikes/wireguard"
target=${DEVICEBRIDGE_BUILD_TARGET:-both}
if [[ "$target" != android ]]; then
  mkdir -p ../../artifacts/linux
go build -trimpath -ldflags='-s -w' -o ../../artifacts/linux/bridge-wg .
fi
if [[ "$target" == linux ]]; then exit 0; fi
source ../../scripts/android_target.sh
mkdir -p "../../$android_output" "../../$android_jni"

GOOS=android GOARCH="$android_arch" CGO_ENABLED=1 CC="$compiler" go build -trimpath -buildmode=pie -ldflags='-s -w -extldflags=-Wl,-z,max-page-size=16384' -o "../../$android_output/libbridge_wg.so" .
cp "../../$android_output/libbridge_wg.so" "../../$android_jni/libbridge_wg.so"
gzip -1 -n -c "../../$android_output/libbridge_wg.so" > "../../app/assets/bin/android-$android_arch-libbridge_wg.gzbin"
xxhsum -H1 "../../$android_output/libbridge_wg.so"
