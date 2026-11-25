#!/usr/bin/env bash
# Shared ABI mapping for Android package and executable builds.
android_arch=${DEVICEBRIDGE_ANDROID_ARCH:-arm64}
case "$android_arch" in
  arm64) android_abi=arm64-v8a; android_triple=aarch64-linux-android ;;
  amd64) android_abi=x86_64; android_triple=x86_64-linux-android ;;
  arm) android_abi=armeabi-v7a; android_triple=armv7a-linux-androideabi; export GOARM=7 ;;
  *) echo "Unsupported Android architecture: $android_arch" >&2; exit 2 ;;
esac
sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:?Android SDK path required}}
ndk_path=${DEVICEBRIDGE_NDK:-$sdk_root/ndk/28.2.13676358}
compiler="$ndk_path/toolchains/llvm/prebuilt/linux-x86_64/bin/${android_triple}28-clang"
test -x "$compiler"
android_output="artifacts/android-$android_arch"
android_jni="app/android/app/src/main/jniLibs/$android_abi"
