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
- **Live POCO ↔ Laptop Direct Tailscale (`tsnet` ↔ system `tailscaled`) pairing, probe & file transfer E2E**:
  - Added Tailscale peer path probe UI in `tailnet_panel.dart`, Tailscale peer picker (`Connect via`) in `pair_dialog.dart` / `main.dart`, and `'finish'` support in `bridge.dart`.
  - **Physical POCO (`JBKJF6JFAAIZUGP7`, `devicebridge-phone` `100.127.71.119`) ↔ Laptop (`probook-450-g9` `100.100.78.84:8731`) E2E (`bridge-agent --system-tailnet --no-discovery`, temporary scoped `tailscale0` UFW rule added & deleted)**:
    - Laptop `tailscale ping`: direct (`via 10.100.102.33:51593`).
    - Phone `TailnetPanel` Probe: `probook-450-g9 · 100.100.78.84`, `Path: direct (10.100.102.69:41641) · 257.9 ms`.
    - Phone `Pair device` -> `Connect via: Tailscale · probook-450-g9 · 100.100.78.84` paired cleanly over Tailscale mTLS without mDNS, approved & finished, opened `DeviceDetail` (`Tailscale · direct`, `Handshake 33.3 ms`), toggled hidden files (`.hidden-tailnet.txt`), pulled 2 MiB `payload-2mib.bin` in MT Manager dual-pane browser (`Verified download (direct) · 1.39 MiB/s`, SHA-256 `b60901579c8a33196620a6548d7d28858cccee8f7d7e717d9b9d68681849f729` exact match), and removed test peer cleanly.
- **High-efficiency TCP streaming (`server.go`, `client.go`, `pull.go`)**:
  - Chose tuned **TCP streaming** over UDP: added continuous `GET /v1/files/stream` (`OpenStream` + `StreamSource`) using `4 MiB` chunks and batched `16 MiB` / completion `f.Sync()` (eliminating 1 MiB chunk round-trip and flash stalls) while preserving byte-offset resume, SHA-256 verification, and `RENAME_NOREPLACE`. Verified via `TestStreamPullAndResume` + `go test -count=1 -race ./...`.
- **Full default storage access (`cmd/bridge-cli/main.go`, `cmd/bridge-agent/main.go`, `native.go`, `bridge.dart`, `MainActivity.kt`, `incoming_pair.dart`)**:
  - Updated `AGENTS.md`: owner-paired devices default to full laptop storage (`home` = `$HOME`, `filesystem` = `/`) and phone storage (`/storage/emulated/0` when `MANAGE_EXTERNAL_STORAGE` granted via `"Grant full phone storage access"` + readable Termux home), with `approve <ID> all` (`IncomingPairDialog` defaults owner full storage; per-device ACL / guest / support roles reserved for later). Unprivileged `EACCES`/`ENOENT` entries skipped cleanly when browsing `/` (`native.go`).
- **SSH bootstrap + `systemd` + UFW + auto-pair (`internal/bootstrap/ssh.go`, `ssh_bootstrap.dart`)**:
  - Added `ssh-probe` & `ssh-bootstrap` (`golang.org/x/crypto/ssh`): host-key fingerprint verification, optional binary upload, `init`, `~/.config/systemd/user/devicebridge-agent.service` enable/start, UFW TCP `8731` allowance, and automatic `invite`/`pair`/`approve`/`finish`. Verified via mock SSH server test `TestHostKeyMismatchRejectedAndSystemdUnitValid`.
- **WireGuard transport (`internal/transport/wireguard/wireguard.go`, `spikes/wireguard/`, `connection.go`, `connection_picker.dart`, `connections_hub.dart`, `remote_files.dart`)**:
  - Added `wireguard-v1` supporting **userspace (`wireguard-go` + `netstack`, zero root / zero `VpnService`)** and **kernel WireGuard module (when rooted/available)**, with **direct-on-LAN preference** before server relay hops (`TestBackendSelectionAndDirectLANFirst`, `TestUserspaceWireGuardTunnelHandshakeAndTCPStream` PASS). Packaged `libbridge_wg.so` (`arm64-v8a`) and `bridge-wg`.
- **Builds & verification (WayDroid `192.168.240.112:5555` while POCO disconnected)**:
  - `go test -count=1 -race ./...` PASS; `spikes/wireguard` `-race` PASS; `spikes/tsnet` `go vet` PASS; `flutter analyze` (0 issues) PASS; `flutter test` (5/5) PASS; `bash scripts/build_apps.sh` PASS.
  - `artifacts/android-arm64/devicebridge.apk`: `27,217,104` bytes, SHA-256 `ee5b548d40076269c10ee682628ce7697e9aa6e37e0c841c1d235ac0e08817c6`, `apksigner verify --print-certs` PASS. Installed (`adb install -r`) and visually verified (`01-home-ssh-button.png`, `02-ssh-bootstrap-dialog.png`, `03-connections-wireguard.png`) on WayDroid (`192.168.240.112:5555`). Termux native test & physical POCO install await POCO reconnection (`No route to host` / unplugged at ~16:51).

## Pending / next steps

1. Live interactive touch drag-and-drop & Hotspot/ADB fallback physical switch tests on POCO, then M3–M6.
