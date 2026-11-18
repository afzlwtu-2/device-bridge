# DeviceBridge

Go core + Flutter Android/Linux app + Kotlin Android adapters. The first working slice is secure pairing, discovery, approved remote browsing and verified file/folder pulls over LAN. Syncthing and remote transports are not required.

**Authoritative source is this laptop repository**, per the user's correction to the supplied v4 specification. Phone snapshots are disposable build/test inputs. Read [current status](docs/IMPLEMENTATION_STATUS.md), [handoff](prgress.md), [architecture](docs/ARCHITECTURE.md) and [security limits](docs/SECURITY.md).

## Build and verify

Requires existing Go with CGO/C compiler, Flutter/Dart and Android SDK/NDK. No script installs tools or changes system configuration.

```bash
bash scripts/check.sh                  # Linux race tests, vet, native binaries
bash scripts/phone_build_test.sh       # native physical Termux tests/builds over existing SSH
bash scripts/build_android_core.sh     # NDK arm64 PIE, packaged app-private core
cd app
flutter analyze
flutter test
flutter build linux --release
flutter build apk --debug --target-platform android-arm64
flutter build apk --release --target-platform android-arm64
```

Linux bundle: `app/build/linux/x64/release/bundle/` (includes Go CLI/agent). Optimized Android APK: `artifacts/android-arm64/devicebridge.apk`; debug APK: `artifacts/android-arm64/devicebridge-debug.apk`. Go binaries: `artifacts/linux/`, `artifacts/termux-arm64/`. Both Android variants use the development signing key; they are not production-signed releases.

`scripts/phone_build_test.sh` creates a uniquely named snapshot under Termux's temporary directory, records a source archive SHA-256, tests/builds natively and returns binaries/logs. It never creates an editable phone Git repository or installs anything. Snapshots are retained for evidence and contain no private local runtime state. SSH host key verification is mandatory.

## First LAN session

Choose the actual local IP/CIDR and interface on each device. The CIDR is an explicit approval to use that local network; it is **not** the other device's address. The following laptop values were verified on the test LAN and will change on other networks.

```bash
artifacts/linux/bridge-cli --state .work/my-laptop init 'My laptop'
artifacts/linux/bridge-cli --state .work/my-laptop export shared /absolute/approved/directory
artifacts/linux/bridge-agent --state .work/my-laptop --interface wlan0 --lan-cidr 10.100.102.69/24
```

Keep that user-started agent running while connecting. In another terminal generate an invitation:

```bash
artifacts/linux/bridge-cli --state .work/my-laptop invite
```

In the Android app, approve your current Wi-Fi network, tap **Pair device**, paste that invitation and verify the fingerprint on the laptop. The invitation contains a five-minute secret: share it only with your intended device. No peer IP is entered.

On the laptop, review the pending phone identity and grant only the intended root:

```bash
artifacts/linux/bridge-cli --state .work/my-laptop peers
artifacts/linux/bridge-cli --state .work/my-laptop approve FULL_PHONE_DEVICE_ID shared 24h 10737418240
```

Tap the pending/outbound device on the phone to finish pairing. Open its detail screen, choose the approved folder, browse and pull. Downloads are verified into app-private storage; **Save a copy…** uses Android's storage picker. Pulls never enable synchronization. The standalone Android app carries its own Go core; physical installed-app pairing, browse, pull and SAF export passed under the normal app UID. No Termux or root is needed for those app operations.

For native Termux CLI use, the same commands apply with its returned `bridge-cli`, a private `--state`, `--interface wlan0 --lan-cidr 10.100.102.33/24`, and `pair -` reading the invitation on stdin. Then `finish DEVICE_ID`, `roots DEVICE_ID`, `list DEVICE_ID shared .`, or `pull DEVICE_ID shared . NEW_DESTINATION`. Normal connections discover current peer endpoints by authenticated device identity. `resolve NAME_OR_ID` returns authenticated endpoint/interface/handshake timing for optional SSH helpers; it never edits SSH or `/etc/hosts`.

If the laptop firewall denies TCP8731, DeviceBridge will not bypass or change it. Ask the owner to approve a narrowly scoped LAN rule. Physical tests used a user-approved temporary rule and removed it afterward. No test script changes the firewall itself.

To revoke: `bridge-cli --state STATE revoke FULL_DEVICE_ID`. Expired grants, revoked keys, wrong roots, traversal and source corruption fail closed. Existing destinations are never overwritten. Interrupted transfers preserve private `.devicebridge-part` staging and can resume only with an identical manifest.

The GUI normally uses private state under `~/.local/share/devicebridge` on Linux. For isolated development set `DEVICEBRIDGE_CORE` to the Go CLI path and `DEVICEBRIDGE_STATE` to a project test directory. Linux serving/export registration currently uses the CLI; the GUI does not silently start a listener or export folders.
