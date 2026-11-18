# Test evidence and remaining acceptance

| Area | Evidence | Level / result |
| --- | --- | --- |
| Identity persistence, pinned mTLS | `test/integration/remote_files_test.go` | automated Linux and physical Termux tests pass |
| Unpaired/pending/revoked/expired/replay | storage + integration tests, `core-security-additional.log` | automated; real phone revocation also verified |
| Scoped paths/symlinks/paging | `internal/filesproviders/native_test.go` | automated native tests pass |
| Resume, corruption, destination race | `internal/transfer/pull_test.go` | automated native tests pass; staging never publishes failed payloads |
| Transport independence | fake stream + memory filesystem integration | automated; no direct transport import in file feature |
| LAN discovery/pair/browse/pull | `physical-lan-20261118T062210Z.json` | actual phone → laptop over wlan0; PASS |
| Native Android binaries | `termux-20261118T062135Z-41682.log` | native Go tests/vet/build PASS |
| NDK standalone executable | `android-core-build*.log`, `android-gui-20261118T063651Z.json` | executable POC and installed native-library execution PASS under app UID 10408 |
| Flutter navigation/browse/approval | `flutter-widget-tests.log` | fake-core widget journey PASS; not hardware GUI acceptance |
| Linux UI package | `flutter-linux-build.log` | release build PASS; actual visual journey pending |
| Android APK | `flutter-android-release-final.log`, `android-release-final-verification.json` | optimized arm64 APK built, signature/core hash verified; development key |
| Real standalone GUI | `android-gui-20261118T063651Z.json` + PNG | physical invitation/pair/browse/nested-folder pull PASS, no Termux dependency |
| SAF/FGS/app UID | `android-saf-20261118T064118Z.json`, GUI JSON service observation | folder export hashes match; foreground service observed; normal app UID verified |
| IP changes, hotspot, blocked multicast | retries/cache implemented after observed loss | full transitions/alternate network tests pending |
| Very large folders, storage exhaustion, battery/doze | no acceptance yet | pending; current manifest limit 20,000 entries/100 GiB |
| Syncthing/Git projections/single writer | sync registry contract only | disabled; M5–M6 pending |
| tsnet/no-VPN, direct/relay, Shizuku/root | no implementation | M7–M8 pending; WireGuard future only |

`scripts/lan_e2e.py` makes only DeviceBridge fixtures, records hashes/timings and always stops its own agent. It never changes firewalls, installs packages or invokes root. Its phone destination IP is used only for existing SSH control; application endpoint selection uses mDNS and public-key identity. Retained failed runs show the genuine UFW block and single-packet multicast loss before fixes. Successful folder-command time includes SSH, discovery, TLS, hashing, disk writes and fsync; it is not a physical-link benchmark.
