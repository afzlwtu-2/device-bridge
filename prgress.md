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
- **Side-by-side Source & Target browser + hidden files + Termux Storage (`remote_files.dart`, `bridge.dart`, `MainActivity.kt`, `main.dart`)**:
  - Upgraded `FileBrowser` to an MT Manager-style always-side-by-side (`Row`) Source (remote) & Target (local `Downloads`, `SAF Folder` / `Home`, or `Termux Storage` via `com.termux.documents` + folder creation) dual-pane browser with `LongPressDraggable`/`DragTarget` drag-and-drop onto Target or subfolders, `Show hidden files` toggle, clickable connection chip (`Wi-Fi LAN`, `Wi-Fi Direct`, `Hotspot`, `Tailscale`, `USB / Wireless ADB`, `SSH`), live `MiB/s` + `Method: TAR` / `Direct` (`transfer.Progress.Method` & `Transport`), and an interactive **Continue on `<route>`** recovery panel when transfers are interrupted. Fixed `AppBar` portrait overflow in `main.dart`. Verified via `flutter test` (`5/5` PASS, including 390x844 portrait test) and `flutter analyze` (`0` issues).
- **Tailscale `tsnet` login lifecycle & Chrome crash fix (`LanCoordinator.kt`, `TailnetCoordinator.kt`, `CoreRuntime.kt`, `MainActivity.kt`, `tailnet_panel.dart`)**:
  - Root cause 1: `MainActivity.onStop()` immediately killed `libbridge_tailnet.so` when Chrome opened (`context canceled`).
  - Root cause 2 (diagnosed via POCO `dumpsys dropbox`): destroying `libbridge_agent.so` / `libbridge_tailnet.so` in `onStop()` threw uncaught `java.io.InterruptedIOException: read interrupted by close() on another thread` in unguarded background `BufferedReader` threads (`LanCoordinator.kt`, `TailnetCoordinator.kt`), crashing the app process when Chrome opened (`ApplicationExitInfo` `APP CRASH` at 15:17:25).
  - Fixed by guarding all reader threads in `LanCoordinator.kt`, `TailnetCoordinator.kt`, and `CoreRuntime.kt`, plus `awaitingLogin()` + 120s grace period. Verified directly on **POCO (`JBKJF6JFAAIZUGP7`)**: app survived `KEYCODE_HOME`, resumed `HOT` (`149ms`), kept `libbridge_tailnet.so` running across `onStop()`, and had zero new crash entries in `dumpsys activity exit-info`.
- **Builds & verification (Android-only target focus)**:
  - `go test -count=1 -race ./...` PASS; `scripts/phone_build_test.sh` (`termux-20261118T102655Z-30055.log`, `go1.27.2 android/arm64`) PASS; `flutter analyze` (0 issues) PASS; `flutter test` (5/5) PASS; `bash scripts/build_apps.sh` PASS.
  - `artifacts/android-arm64/devicebridge.apk`: `24,163,813` bytes, SHA-256 `42eb1077bebd588df1becd20f159d6e1aaa02db148f58a4459c0cd3895e7107f`, `apksigner verify --print-certs` PASS. Installed (`adb install -r`) on `JBKJF6JFAAIZUGP7` (`stay_on_while_plugged_in=3` enabled for USB sessions).
- **Keep device awake (`MainActivity.kt`)**: added `WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON` in `onResume()` and cleared it in `onPause()` so the Android screen stays awake during foreground DeviceBridge sessions (`dumpsys window windows` verified).

## Pending / next steps

1. Once user unlocks POCO phone (`JBKJF6JFAAIZUGP7`), tap `Connections -> Tailscale -> Enable app-only Tailscale -> Log in to Tailscale` to complete interactive `login.tailscale.com` authentication and verify `Running` state persists across app relaunch + tailnet transfer.
2. Physical dual-pane UI + ADB/Hotspot/Wi-Fi fallback E2E on unlocked POCO, then M3–M6.
