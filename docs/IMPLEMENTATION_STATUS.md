# Implementation status

> **Updated 2026-11-18 14:37 UTC.** Continued and verified on physical POCO `JBKJF6JFAAIZUGP7` (with laptop/phone on Wi-Fi `192.168.1.23` ↔ `192.168.1.10`): XXH64 transfer/manifest/target verification, global Settings, transparent Matte paper transitions with topbar/bottombar/list-background meadow flowers & bird across all screens, local dual-pane file manager (Internal + SAF + `com.termux.documents` Termux Home, `New folder`, local move with `excluded-cache` exclusion, no-overwrite denial, return copy, live text preview refresh), Termux `RUN_COMMAND` (`pwd` exit 0 after reloading properties while visible), physical remote SAF and Termux Home serving over LAN (list, Unicode `space λ.txt`, preview, excluded pull, 8 MiB SAF pull), native Termux tests/build (`termux-20261118T142230Z-...` / `artifacts/termux-arm64/`), broad Go + Flutter checks (9/9 widget tests, 0 analyzer issues), and XXH64 release packaging. Remote uploads/deletes and M3–M8 remain pending.

> **Updated 2026-11-18 10:07 UTC.** Builds on `a609a7c` with unified `ConnectionsHub` under the Wi-Fi icon (Wi-Fi LAN, Hotspot & Wi-Fi Direct, Tailscale `tsnet`/system, USB/Wireless ADB, SSH/Termux), explicit per-device alternate-route resume (`ResumePullOnAlternates`), side-by-side Source & Target dual-pane browser (hidden files toggle + Termux Storage SAF), and `tsnet` login lifecycle persistence (`awaitingLogin` + 120s background grace). Interactive Android `tsnet` login on unlocked POCO, hotspot/ADB physical link-switch E2E, M3 Quick Share/Clipboard, and M5–M8 remain pending.

Updated 2026-11-18. **The primary Android ↔ Linux LAN discovery, pairing, browse, and verified chunked/streaming-tar pull journeys pass on physical hardware.** This is pre-M3/M4 hardening; M3–M8 remain pending.

## Authority and safety

The full v4 specification was read. The user's later correction makes `/home/afzl/@Projects/mine/device-bridge` the authoritative source/development repository. Phone copies are disposable build/test snapshots, never editable competing repositories. The directory initially contained only the specification, with no Git history to preserve.

The user authorized all read-only and safely reversible work on both devices, including local commits, and specifically approved temporary laptop firewall rules, APK installation/app testing and wireless ADB if needed. **Never modify phone system files/partitions, boot/AVB/verity, root modules, bootloader or SELinux.** Root was used only for authorized package-manager installation and bounded app/UI observation. No phone ADB/network settings or system partitions were changed. App operations run as ordinary UID 10408, without root or Termux.

## M0: actual inventory and build workflow

- Laptop: probook-450-g9, Linux x86_64, Go 1.27.3, Flutter 3.50.0/Dart 3.14.0, JDK 21, Android SDK 34–37, NDK 27/28/30, GTK 3.24.52, CMake/Ninja/Clang. No Syncthing/offdesk-tui in PATH.
- Physical phone: existing verified SSH key at `afzl@10.100.102.33:8022`, POCO/Termux Android 16 arm64, Go 1.27.2 and clang/git/python/ssh/Flutter/Dart. Syncthing/rsync/tailscale absent from PATH. Phone login shell is fish; scripts explicitly use bash. Read phone home AGENTS/development reference.
- Actual laptop route: `10.100.102.33 dev wlan0 src 10.100.102.69`. Existing Tailscale inspected, unchanged and unused for tests. Laptop ADB lists Waydroid only; phone's TCP ADB was disabled and stayed disabled.
- `scripts/phone_build_test.sh` sends hashed, unique disposable snapshots, runs native Go tests/vet/build and returns binaries/logs. Latest snapshot: `/data/data/com.termux/files/usr/tmp/devicebridge-build.IZZx3Jme`. No installs/services/network changes in that workflow.
- Buildable Go CLI/agent, Flutter Linux/Android apps, NDK app-private Go core, CI configuration, packaging/checksum scripts and resolved dependency license notices exist. CI is authored, not remotely run; no Git remote/publication configured.

## M1–M2 implementation

Five versioned interfaces/registries cover transport, features, filesystems, sync engines and platform capabilities. Implemented: Ed25519 identity; SQLite migrations 1–2; TLS 1.3 mutual certificates and pinned peer keys; single-use expiring invitations; explicit pending owner approval; per-root browse/read grants, expiry, quotas and revocation; private audit records; approved on-link IPv4 TCP and DNS-SD; 30-second authenticated endpoint cache.

Remote files provide scoped roots, lazy paged listings, stat, bounded preview/ranges and recursive SHA-256 manifests. Pulls resume into locked private staging, verify chunk/full-file hashes, fsync and atomically publish with no overwrite. Symlinks, traversal and special files are rejected. Limits and route-attestation caveats are in `SECURITY.md`.

Flutter uses this same Go core through subprocess/platform channels. Android packages its own NDK PIE executable in the APK; Kotlin supplies Wi-Fi discovery context, a foreground transfer service and SAF export. Home / Devices / Share / Sync are the only top-level destinations; browsing lives in device detail. Share/Sync are visibly unavailable.

## Real evidence

| Check | Evidence/result |
| --- | --- |
| Linux formatting/vet/race/integration/build | `linux-core-3.log`, `core-security-additional.log`: PASS |
| Native physical Termux tests/vet/build | `termux-20261118T062135Z-41682.log`: PASS |
| Pinned TLS, unpaired/pending/revoked/expired/replay, root/path policy | automated native tests: PASS; server boundary is tested independently of client policy |
| Interrupted resume, corruption, destination race, staging symlink | automated native tests: PASS; failed downloads never publish |
| Physical phone CLI discovery/pair/browse/pull/revoke | `physical-lan-20261118T062210Z.json`: PASS, no peer IP entry or relay |
| Installed standalone Android GUI pair/browse/folder pull | `android-gui-20261118T063651Z.json` + PNG: PASS, actual core under app UID 10408 |
| Android foreground transfer | GUI evidence records `isForeground=true`, app UID u0a408; stopped after transfer |
| SAF folder export | `android-saf-20261118T064118Z.json`: PASS; all three exported hashes match, including 8 MiB binary and empty file |
| Optimized installed APK individual-file pull | `android-release-20261118T064643Z.json` + PNG: PASS, SHA-256 verified |
| Flutter analyzer/widget regression tests | `flutter-analyze-3.log`, `flutter-widget-tests-4.log`: PASS |
| Linux actual GUI startup | `linux-ui-smoke.log`: bundled core initialized, app survived bounded startup and was stopped; cursor-theme warning only |
| Optimized Linux/Android builds | `flutter-linux-build-final.log`, `flutter-android-release-final.log`: PASS |
| APK signatures and bundled core hash | `android-release-final-signature.log`, `android-release-final-verification.json`, plus latest `apksigner verify` on `48bd056a20...`: PASS |
| Go known-vulnerability scan | `govulncheck.log`: no known vulnerabilities; not an external audit |
| Two-way LAN mDNS discovery & Linux → Android pull | Standalone Android UID `u0_a408` discovered at `10.100.102.33:33715`; Android UI discovered Linux at `10.100.102.69:8731`; Linux paired/approved/pulled 8 files (`8,389,711` bytes): PASS (no UFW edit) |
| Streaming tar + adaptive gzip & live MiB/s | `internal/transfer/tar_test.go`, `TestStreamingTarPullOverMTLS`, `tar-speed-cli-verify.json` (`2.23 MiB/s`), and physical POCO GUI `android-tar-speed-20261118T093415Z.json` (24 files, `2.05 MiB/s`, SHA-256 verified): PASS |
| Wi-Fi recovery & app-only `tsnet` sidecar readiness | `android-recovery-tsnet-check.json` on POCO `JBKJF6JFAAIZUGP7`: `svc wifi disable/enable` paused and auto-recovered `libbridge_agent.so`; `libbridge_tailnet.so` (`u0_a408`, no `VpnService`) reached `NeedsLogin` and cleanly disconnected: PASS |
| Matte paper & AMOLED Neon Green/Red themes | `flutter test` (4/4) + `flutter analyze` (0 issues): PASS; verified visually on physical POCO phone and WayDroid (unified Matte paper with white/cream right-side AppBar icons & active nav pill; AMOLED Neon Green/Red edge lines matching glowing gradient active tab pill & buttons) |
| TCP continuous stream, full-storage defaults, SSH systemd/UFW bootstrap & WireGuard (`userspace`/`kernel`, LAN-first) | `go test -count=1 -race ./...` (`TestStreamPullAndResume`, `TestHostKeyMismatchRejectedAndSystemdUnitValid`, `TestBackendSelectionAndDirectLANFirst`), `spikes/wireguard` (`TestUserspaceWireGuardTunnelHandshakeAndTCPStream` `-race`), `flutter analyze` (0 issues), `flutter test` (5/5): PASS. Packaged `libbridge_wg.so` + updated APK verified visually on WayDroid `192.168.240.112:5555`. Native Termux build & POCO install pending while POCO is disconnected |
| Live POCO ↔ Laptop Direct Tailscale pair, probe & file transfer E2E | Authenticated POCO `devicebridge-phone` (`100.127.71.119`) paired with laptop `probook-450-g9` (`100.100.78.84:8731`) over Tailscale without mDNS (`--no-discovery`, temporary `tailscale0` UFW rule added & deleted). Verified `Path: direct (10.100.102.69:41641)`, `Tailscale · direct` (`33.3 ms` handshake), MT Manager dual-pane + hidden files toggle, and 2 MiB `payload-2mib.bin` transfer (`1.39 MiB/s`, SHA-256 `b60901579c8a33196620a6548d7d28858cccee8f7d7e717d9b9d68681849f729` matched byte-for-byte) |

Failures were retained: initial Linux fixture permissions, laptop UFW denial, lost single mDNS packet, outdated APK core caught by hash comparison, a real Flutter dialog/controller lifecycle assertion, `TextStyle` `inherit` mismatch during theme animation, `package_artifacts.py` catching a stale debug APK, raw `PlatformException` string shown on off-state `TailnetPanel`, and POCO lockscreen blocking unlocked hardware UI capture (reported honestly rather than bypassed). Fixes have targeted regression tests and passing follow-up evidence. No failed run is presented as successful.

The physical CLI folder command transferred 4,194,335 bytes in 4.098625 seconds **including SSH, discovery, hashing and fsync**; this is not a link-throughput benchmark. The 24-file streaming tar CLI check measured `2.23 MiB/s` over 30 ms for 72,448 bytes on `wlan0`. No fabricated bandwidth or battery figures.

## Artifacts and cleanup

- Development-signed release APK: `artifacts/android-arm64/devicebridge.apk`, 27,421,460 bytes, XXH64 `2b038dfe596c17da` (`apksigner verify` PASS; includes `libbridge_cli.so` XXH64 `43e1602c5eeb8979`, `libbridge_agent.so`, `libbridge_tailnet.so` XXH64 `2e0c2fb548a7b521`, and `libbridge_wg.so` XXH64 `7cc099599d05769d`). Installed (`Installed target xxhsum PASS: 2b038dfe596c17da`) and visually verified on physical POCO `JBKJF6JFAAIZUGP7` (`poco-matte-home.png`, `poco-matte-files-tab.png`, `poco-matte-files-dropdown.png`, `poco-amoled-files-dropdown.png`, `poco-matte-files-popup.png`, `poco-matte-device-detail.png`, `poco-matte-editor.png`). Debug APK: `artifacts/android-arm64/devicebridge-debug.apk` (94,056,874 bytes, XXH64 `6815ea973abd7d42`).
- Linux GUI bundle: `app/build/linux/x64/release/bundle/`; packaged archive: `artifacts/linux/devicebridge-linux-x64.tar.gz` (30,105,952 bytes, XXH64 `cce0fa51e656ddc0`); Linux (`bridge-agent` `14158cfcda9047a0`, `bridge-cli` `af708f760d1348ab`) and Termux (`bridge-agent` `9010261b5cd165bd`, `bridge-cli` `072c56c7b71c075f`) Go binaries. `artifacts/MANIFEST.json` and `docs/test-evidence/artifact-manifest.json` record XXH64 hashes.
- All experiment-owned laptop agents stopped. All temporary wlan0 TCP8731 rules (phone10.100.102.33 → laptop10.100.102.69 only) were deleted after baseline tests; no UFW rules were added in this session. No persistent device service was installed.
- SAF retained only the test folder `DeviceBridge-Test-20261118T064118Z` with verified sample copies. Owned temporary UI XML is removed. Private test identities/state remain in ignored `.work/` and disposable phone snapshots for reproducibility.

## Remaining work

M2 baseline plus two-way LAN discovery, streaming tar, live/persisted MiB/s, and Matte/AMOLED theme UI are verified at unit/integration/CLI/build levels; full alternate-network and hardening acceptance is not. Linux GUI's complete visual journey, hotspot/Wi-Fi Direct and IP transitions, very large trees, storage exhaustion, process-restart resume, battery/doze/force-stop, and a non-rooted physical handset remain untested. Interactive Android `tsnet` login/path proof (`libbridge_tailnet.so`) awaits user authentication.

M3: quick sending/clipboard/share sheet and richer transfer history. M4: broader network intelligence/UI refinement. M5–M6: independently installed Syncthing, filtered Git-aware projection, signed single-writer controller and recovery. M7: SAF-backed serving, companion lifecycle and optional privileged providers. M8: app-only tsnet login/path/battery proof and hardening. WireGuard/commands/terminal/guest assistance remain future contracts only.

No uploads, sync ownership, Syncthing management, authenticated `tsnet` tunnel, root/Shizuku broker or WireGuard connectivity is claimed. APKs use a development signing key. See `prgress.md` and `docs/HANDOFF.md`; local milestone commit is authorized, publication is not.
