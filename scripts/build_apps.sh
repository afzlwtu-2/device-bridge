#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/check.sh
bash scripts/build_android_core.sh
bash scripts/build_syncthing.sh
bash scripts/build_tsnet.sh
bash scripts/build_wg.sh
bash scripts/prepare_bundled_bins.sh
cd app
flutter analyze
flutter test
flutter build linux --release
flutter build apk --debug --target-platform android-arm64
if [[ "${DEVICEBRIDGE_BUILD_RELEASE:-0}" == "1" ]]; then
  # Release APKs already bundle fresh jniLibs/*.so; skip duplicate android-*.gzbin assets.
  rm -f assets/bin/android-*.gzbin
  flutter build apk --release --target-platform android-arm64
fi
cd ..
cp app/build/app/outputs/flutter-apk/app-debug.apk artifacts/android-arm64/devicebridge-debug.apk
xxhsum -H1 app/build/app/outputs/flutter-apk/app-debug.apk | sed 's|app/build/app/outputs/flutter-apk/app-debug.apk|artifacts/android-arm64/devicebridge-debug.apk|' | xxhsum -H1 --check --strict
python3 scripts/package_artifacts.py
