#!/usr/bin/env bash
# Isolated Go toolchain/dependencies; never replaces installed Go or Tailscale.
set -euo pipefail
cd "$(dirname "$0")/../spikes/tsnet"
sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:?Android SDK path required}}
ndk_path=${DEVICEBRIDGE_NDK:-$sdk_root/ndk/28.2.13676358}
compiler="$ndk_path/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang"
test -x "$compiler"
mkdir -p ../../artifacts/linux ../../artifacts/android-arm64 ../../app/android/app/src/main/jniLibs/arm64-v8a
go build -trimpath -ldflags='-s -w' -o ../../artifacts/linux/bridge-tailnet .
GOOS=android GOARCH=arm64 CGO_ENABLED=1 CC="$compiler" go build -trimpath -buildmode=pie -ldflags='-s -w -extldflags=-Wl,-z,max-page-size=16384' -o ../../artifacts/android-arm64/libbridge_tailnet.so .
cp ../../artifacts/android-arm64/libbridge_tailnet.so ../../app/android/app/src/main/jniLibs/arm64-v8a/libbridge_tailnet.so
xxhsum -H1 ../../artifacts/android-arm64/libbridge_tailnet.so
