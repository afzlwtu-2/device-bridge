#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/check.sh
bash scripts/build_android_core.sh
bash scripts/build_tsnet.sh
cd app
flutter analyze
flutter test
flutter build linux --release
flutter build apk --debug --target-platform android-arm64
flutter build apk --release --target-platform android-arm64
cd ..
cp app/build/app/outputs/flutter-apk/app-debug.apk artifacts/android-arm64/devicebridge-debug.apk
python3 scripts/package_artifacts.py
