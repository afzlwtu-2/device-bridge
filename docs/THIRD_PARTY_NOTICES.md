# Third-party notices

Go runtime/standard-library [BSD license](licenses/go-standard-library.txt).

Resolved Go modules and Dart packages used by this development build. SQLite engine is public domain; go-sqlite3 bindings use MIT. Copies below come from the exact resolved local sources. See go.mod/go.sum and app/pubspec.lock for version pins.

| Component | Version | License file |
| --- | --- | --- |
| Syncthing external sync engine | v2.1.7 | [MPL-2.0 license](licenses/syncthing-v2.1.7.txt); unmodified upstream [source](https://github.com/syncthing/syncthing/tree/v2.1.7), reproducible wrapper `scripts/build_syncthing.sh` |
| Shizuku API/provider/aidl/shared | 13.1.5 | [MIT license](licenses/shizuku-api-v13.1.5.txt) (license URL from the published Maven POM) |
| github.com/cespare/xxhash/v2 | v2.3.0 | [license](licenses/github.com_cespare_xxhash-v2.3.0.txt) |
| github.com/mattn/go-sqlite3 | v1.14.32 | [license](licenses/github.com_mattn_go-sqlite3-v1.14.32.txt) |
| github.com/miekg/dns | v1.1.73 | [license](licenses/github.com_miekg_dns-v1.1.73.txt) |
| golang.org/x/net | v0.63.0 | [license](licenses/golang.org_x_net-v0.63.0.txt) |
| golang.org/x/sync | v0.22.0 | [license](licenses/golang.org_x_sync-v0.22.0.txt) |
| golang.org/x/sys | v0.50.0 | [license](licenses/golang.org_x_sys-v0.50.0.txt) |
| Dart async | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-async.txt) |
| Dart boolean_selector | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-boolean_selector.txt) |
| Dart characters | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-characters.txt) |
| Dart clock | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-clock.txt) |
| Dart collection | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-collection.txt) |
| Dart cupertino_icons | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-cupertino_icons.txt) |
| Dart cupertino_ui | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-cupertino_ui.txt) |
| Dart fake_async | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-fake_async.txt) |
| Dart flutter | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-flutter.txt) |
| Dart flutter_lints | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-flutter_lints.txt) |
| Dart intl | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-intl.txt) |
| Dart leak_tracker | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-leak_tracker.txt) |
| Dart leak_tracker_flutter_testing | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-leak_tracker_flutter_testing.txt) |
| Dart leak_tracker_testing | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-leak_tracker_testing.txt) |
| Dart lints | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-lints.txt) |
| Dart listen | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-listen.txt) |
| Dart matcher | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-matcher.txt) |
| Dart material_color_utilities | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-material_color_utilities.txt) |
| Dart material_ui | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-material_ui.txt) |
| Dart meta | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-meta.txt) |
| Dart mobile_scanner | 7.5.0 | [license](licenses/dart-mobile_scanner.txt) |
| Dart path | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-path.txt) |
| Dart plugin_platform_interface | 2.1.8 | [license](licenses/dart-plugin_platform_interface.txt) |
| Dart qr | 3.0.3 | [license](licenses/dart-qr.txt) |
| Dart qr_flutter | 4.1.0 | [license](licenses/dart-qr_flutter.txt) |
| Google ML Kit Barcode Scanning (Android) | 17.3.0 | [ML Kit Terms of Service](https://developers.google.com/ml-kit/terms) |
| Dart sky_engine | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-sky_engine.txt) |
| Dart source_span | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-source_span.txt) |
| Dart stack_trace | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-stack_trace.txt) |
| Dart stream_channel | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-stream_channel.txt) |
| Dart string_scanner | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-string_scanner.txt) |
| Dart term_glyph | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-term_glyph.txt) |
| Dart test_api | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-test_api.txt) |
| Dart vector_math | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-vector_math.txt) |
| Dart vm_service | see app/pubspec.lock / Flutter SDK | [license](licenses/dart-vm_service.txt) |
| Dart xterm3 | 6.4.0 | [license](licenses/dart-xterm3.txt) |
| Dart convert | 3.1.2 | [license](licenses/dart-convert.txt) |
| Dart typed_data | 1.4.0 | [license](licenses/dart-typed_data.txt) |
| Dart zmodem | 0.0.6 | [license](licenses/dart-zmodem.txt) |

Android SDK/NDK tooling and Syncthing are separately installed. Flutter engine notices are included in its app license registry. Android packages include app-private Tailscale and userspace WireGuard sidecars. Packaging reads the exact linked Go dependency versions from each binary and includes their licenses, notices and patent files in `artifacts/THIRD_PARTY_NOTICES-GO.txt` and the Linux bundle.
