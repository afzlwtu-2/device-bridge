# DeviceBridge progress

2026-11-18 ~08:08 UTC (13:08 +05:00). Resumed from Codex handoff (`a89db22` baseline). Implemented and verified two-way LAN mDNS discovery, streaming tar + safe extraction, live/persisted MiB/s throughput, and updated Matte paper + AMOLED Neon Green/Red themes.

## Authority and safety

Laptop `/home/afzl/@Projects/mine/device-bridge` is the sole authoritative repository. Phone: `ssh -p 8022 afzl@10.100.102.33` (fish shell; pass `bash -c` / `bash -s`). Latest disposable Termux native snapshot: `/data/data/com.termux/files/usr/tmp/devicebridge-build.ko1jQTaT`. All read-only/safely reversible work and local commits are authorized; no subagents/publication authorized. Never modify phone system files/partitions, boot/AVB/verity, bootloader, root modules or SELinux. Compile unprivileged. No laptop firewall rules were modified.

## Completed and verified in this session

- **Analyzer & tests**: fixed `connection_picker.dart:189` stray `;`. `go test -count=1 -race ./...` PASS (including `internal/transfer/tar_test.go` and `TestStreamingTarPullOverMTLS`), `spikes/tsnet` `gofmt`/`go vet` PASS, `scripts/phone_build_test.sh` (Termux native Go 1.27.2 tests/vet/build) PASS, `flutter analyze` (0 issues) PASS, `flutter test` (3/3) PASS.
- **Two-way LAN discovery**: updated `internal/discovery/mdns.go` so `Browse` listens on `:5353` multicast (`224.0.0.251`, accepted by UFW's built-in mDNS rule) alongside ephemeral unicast replies, while `Advertise` respects the RFC 6762 QU bit (`0x8000`). Verified on hardware:
  - Linux `bridge-cli discover` found standalone Android app `libbridge_agent.so` (UID `u0_a408`) at `10.100.102.33:33715`.
  - Android app UI discovered Linux `bridge-agent` at `10.100.102.69:8731`.
  - Full Linux → Android pair (via UI `Create invitation` + `IncomingPairDialog`), `resolve`, `roots`, `list`, and `pull` of 8 files (8,389,711 bytes) passed without `--endpoint`.
- **Streaming tar + safe extraction + live MiB/s**:
  - Added `internal/transfer/tar.go` (`WriteTar`, `PullTar`, `ShouldUseTar`), `GET /v1/files/tar` (`internal/server/server.go`), and `client.OpenTar` (`internal/client/client.go`). Zero temp archive on disk; rejects symlinks, hardlinks, traversal, absolute/special paths, duplicates, oversize/truncated streams, and checksum mismatches; publishes atomically with `renameat2(RENAME_NOREPLACE)`.
  - Added `MiBPerSecond` / `ElapsedMillis` to `transfer.Progress` & `Receipt`, persisted per-peer `rate.<peer>` in `internal/storage/connection.go`, streamed live stderr JSON progress via `EventChannel("dev.devicebridge/transfer")` on Android (`CoreRuntime.kt`, `MainActivity.kt`) and line-buffered stderr on Linux (`bridge.dart`), and wired live progress + measured `MiB/s` into `FileBrowser`, `DeviceDetail`, `ConnectionPicker`, and `TailnetPanel`.
  - Verified Linux CLI → Linux Agent 24-file streaming tar pull (`mode: "tar"`, `2.23 MiB/s`, 24 progress events, persisted in `connection` & `resolve`).
- **Themes (`appearance.dart`, `main.dart`, `store.go`)**:
  - **Matte paper**: olive-moss mottled paper canvas, white & golden-yellow 5-petal daisies, grass tufts, comic bursts, lounging cartoon crow with sunglasses (`MatteMeadowFooter`), ink-outlined cream cards & gold/cream pill buttons, and matching olive `MatteNavBarSurface` bottom bar with cream/white active pill and 2px ink border.
  - **AMOLED black · Neon green / Neon red**: selectable in Appearance menu & persisted in SQLite (`amoled-green`, `amoled-red`, `amoled`). Pure AMOLED black surfaces with two straight stationary vertical left/right lines (~80% height, centered vertically, saturated neon green/red center peak fading smoothly to transparent before the corners, narrow halo).
- **Artifacts**: `bash scripts/build_apps.sh` PASS; `artifacts/android-arm64/devicebridge.apk` (24,063,125 bytes, SHA-256 `0aaa31720c7f1702e20fd79851e3c0fa559a516ba519d4f4442225f9e84cc7ea`, `apksigner verify` PASS with all 3 `.so` libs verified), `devicebridge-debug.apk`, `devicebridge-linux-x64.tar.gz`, Linux & Termux binaries, and `artifacts/MANIFEST.json` updated.

## Pending / next steps

1. Install latest `artifacts/android-arm64/devicebridge.apk` on phone (not pushed during user's active phone use) and visually verify the final white-pill olive bottom bar + saturated AMOLED Neon Green/Red tweaks on device.
2. Android app-only `tsnet` runtime proof: obtain user authorization for interactive `login.tailscale.com` authentication on Android (`TailnetPanel`), verify `direct`/`derp`/`peer-relay` probe and actual tailnet browse/pull.
3. Hardware Wi-Fi ↔ hotspot / IP-change recovery test, Linux GUI E2E tar pull test, then M3 (Quick Share/Clipboard) and M5–M6 (Syncthing + Git-aware sync).
