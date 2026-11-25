#!/usr/bin/env bash
# Isolated Go toolchain/dependencies; never replaces installed Go or Tailscale.
set -euo pipefail
cd "$(dirname "$0")/../spikes/tsnet"
target=${DEVICEBRIDGE_BUILD_TARGET:-both}
if [[ "$target" != android ]]; then
  mkdir -p ../../artifacts/linux
go build -trimpath -ldflags='-s -w' -o ../../artifacts/linux/bridge-tailnet .
fi
if [[ "$target" == linux ]]; then exit 0; fi
source ../../scripts/android_target.sh
mkdir -p "../../$android_output" "../../$android_jni"

ts_dir=$(go list -m -f '{{.Dir}}' tailscale.com)
tmp_mod=$(mktemp -d)
trap 'chmod -R u+w "$tmp_mod" 2>/dev/null || true; rm -rf "$tmp_mod"' EXIT
python3 - "$ts_dir" "$PWD" "$tmp_mod" <<'PY'
import os, shutil, sys
ts_dir, pwd, tmp_mod = sys.argv[1], sys.argv[2], sys.argv[3]
ts_dst = os.path.join(tmp_mod, "tailscale.com")
shutil.copytree(ts_dir, ts_dst, copy_function=shutil.copy)
for root, dirs, files in os.walk(ts_dst):
    os.chmod(root, 0o755)
    for fn in files:
        p = os.path.join(root, fn)
        if not os.path.islink(p):
            os.chmod(p, 0o644)
shutil.copy(os.path.join(pwd, "overlay", "featureknob_android.go"), os.path.join(ts_dst, "envknob", "featureknob", "featureknob.go"))
with open(os.path.join(pwd, "go.mod"), "r", encoding="utf-8") as f:
    gomod = f.read()
gomod = gomod.replace("replace devicebridge => ../..", f"replace devicebridge => {os.path.abspath(os.path.join(pwd, '../..'))}")
gomod += f"\nreplace tailscale.com => {ts_dst}\n"
with open(os.path.join(tmp_mod, "go.mod"), "w", encoding="utf-8") as f:
    f.write(gomod)
shutil.copy2(os.path.join(pwd, "go.sum"), os.path.join(tmp_mod, "go.sum"))
PY
GOOS=android GOARCH="$android_arch" CGO_ENABLED=1 CC="$compiler" go build -modfile="$tmp_mod/go.mod" -trimpath -buildmode=pie -ldflags='-s -w -extldflags=-Wl,-z,max-page-size=16384' -o "../../$android_output/libbridge_tailnet.so" .
cp "../../$android_output/libbridge_tailnet.so" "../../$android_jni/libbridge_tailnet.so"
mkdir -p ../../app/assets/bin
gzip -1 -n -c "../../$android_output/libbridge_tailnet.so" > "../../app/assets/bin/android-$android_arch-libbridge_tailnet.gzbin"
xxhsum -H1 "../../$android_output/libbridge_tailnet.so"
