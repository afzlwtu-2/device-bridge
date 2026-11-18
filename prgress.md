# DeviceBridge progress

2026-11-18 ~10:07 UTC (15:07 +05:00). Resumed from `a609a7c`. Implemented unified `ConnectionsHub` under the top-bar Wi-Fi icon, explicit per-device alternate-route resume on transfer disruption, side-by-side Source & Target dual-pane browser (hidden files toggle + Termux Storage), and Tailscale `tsnet` login lifecycle persistence.

## Authority and safety

Laptop `/home/afzl/@Projects/mine/device-bridge` is the sole authoritative repository. Phone: `ssh -p 8022 afzl@10.100.102.33` (fish shell; pass `bash -c` / `bash -s`). Latest disposable Termux native snapshot: `/data/data/com.termux/files/usr/tmp/devicebridge-build.mBrfJBIP`. All read-only/safely reversible work and local commits are authorized; no subagents/publication authorized. Never modify phone system files/partitions, boot/AVB/verity, bootloader, root modules or SELinux. Compile unprivileged. No laptop firewall rules were left active.

## Completed and verified in this session

- **Unified `ConnectionsHub` under Wi-Fi icon (`connections_hub.dart`, `main.dart`, `LanCoordinator.kt`, `MainActivity.kt`)**:
  - Removed the separate top-bar Tailscale cloud icon and consolidated Wi-Fi LAN, Hotspot & Wi-Fi Direct (`ap*`/`swlan*`/`p2p*`/`wlan*`/`rndis*` interface detection), Tailscale (`tsnet` / system), USB/Wireless ADB, and SSH/Termux Bridge into `Connections` (`Icons.wifi`).
  - Verified visually on WayDroid (`192.168.240.112:5555`): top bar shows only `Appearance` and `Connections`; `ConnectionsHub` renders all transport cards cleanly in Matte theme; widget test verifies all transport sections.
- **Alternate-route transfer resume (`internal/storage/connection.go`, `internal/transfer/fallback.go`, `pull.go`, `cmd/bridge-cli/main.go`, `CoreRuntime.kt`, `connection_picker.dart`)**:
  - Added explicit per-peer `FallbackApproved`, `FallbackTransports`, `AdbEndpoint`, and `SshEndpoint` (`127.0.0.1:port` loopback or tailnet overlay IP port `8731`), `ResumePullOnAlternates` for chunked + tar pulls, `--transport lan|adb|ssh|tailnet`, `--allow-route-fallback`, and live `route_switched` notices in UI.
  - Verified via `TestTransferDisruptionResumesOverAlternateRoute` in `go test -count=1 -race ./...` (Linux) and native Termux `scripts/phone_build_test.sh` (`docs/test-evidence/termux-20261118T100256Z-21164.log`).
- **Side-by-side Source & Target browser + hidden files + Termux Storage (`remote_files.dart`, `bridge.dart`, `MainActivity.kt`)**:
  - Upgraded `FileBrowser` to responsive dual-pane Source (remote device) & Target (local `Downloads`, `SAF Folder` / `Home`, or `Termux Storage` via SAF `com.termux.documents` + folder creation), with `Show hidden files` dotfile filter toggle and live `MiB/s` progress. Verified via `flutter test` (`4/4` PASS) and `flutter analyze` (`0` issues).
- **Tailscale `tsnet` login lifecycle persistence (`TailnetCoordinator.kt`, `MainActivity.kt`, `tailnet_panel.dart`)**:
  - Root cause: `MainActivity.onStop()` immediately killed `libbridge_tailnet.so` when opening `login.tailscale.com`, cancelling registration mid-login (`context canceled` in phone `tailscaled.log2.txt`).
  - Fixed with `awaitingLogin()` (5-min login timeout), 120s background grace period across `onStop()`, `WidgetsBindingObserver` resume polling in `TailnetPanel`, and clean user-facing off-state messaging (`tailnet-panel-updated.png` verified on WayDroid).
- **Builds & verification**:
  - `go test -count=1 -race ./...` PASS; `scripts/phone_build_test.sh` (Termux `go1.27.2 android/arm64`) PASS; `flutter analyze` (0 issues) PASS; `flutter test` (4/4) PASS; `bash scripts/build_apps.sh` PASS.
  - `artifacts/android-arm64/devicebridge.apk`: `24,137,933` bytes, SHA-256 `202f7b539c0a71abeda1c54e095fafae56b812012842ed4e8a34416a21c4199f`, `apksigner verify --print-certs` PASS. Installed (`adb install -r`) on both `JBKJF6JFAAIZUGP7` (POCO, currently PIN-locked so live phone UI walkthrough skipped without bypassing lockscreen) and `192.168.240.112:5555` (WayDroid).

## Pending / next steps

1. Once user unlocks POCO phone (`JBKJF6JFAAIZUGP7`), tap `Connections -> Tailscale -> Enable app-only Tailscale -> Log in to Tailscale` to complete interactive `login.tailscale.com` authentication and verify `Running` state persists across app relaunch + tailnet transfer.
2. Physical dual-pane UI + ADB/Hotspot/Wi-Fi fallback E2E on unlocked POCO, then M3–M6.
