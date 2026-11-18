# DeviceBridge handoff — user requested stop

2026-11-18, approximately 13:18 UTC / 18:18 PKT. **Work stopped at the user's explicit request.** No subagents, publication, phone root, system/partition/SELinux/boot changes, or Termux session termination. Laptop repository remains authoritative.

## Ownership and repository

- HEAD remains `81890e7a042d509d9c9155f0fb7da8a673ccf5c1`. This session's changes are **uncommitted**, including new files. Do not discard them.
- Handoff is complete and the session lock has been released per the user’s clarification. Resume pointers for Codex session `01a1ee8d-5cca-7730-b6e2-aff93d3f6f4c` and previous owners are preserved in ignored `.work/session-handoffs/01a1ee8d-5cca-7730-b6e2-aff93d3f6f4c.json`. The chat transcript is `/home/afzl/.aisw/profiles/codex/afzlwtu/sessions/2026/11/18/rollout-2026-11-18T17-06-44-01a1ee8d-5cca-7730-b6e2-aff93d3f6f4c.jsonl`. Unfinished implementation does not keep a completed handoff locked.
- No current feature milestone is declared complete. `docs/IMPLEMENTATION_STATUS.md` historical claims predate some current source.

## User steering that must persist

1. All physical testing now targets USB POCO `JBKJF6JFAAIZUGP7`, not WayDroid.
2. **XXH64 / `xxhsum -H1` only for file-content, transfer and build-artifact checksums**, including target verification after completed copies. Remove SHA-256 from that path. Cryptographic identity/token/SSH hashing remains cryptographic.
3. Run focused tests after each fix; broader suite at a coherent milestone gate only.
4. Global Settings is for non-module/app-wide controls (Root, Shizuku, screen awake). Hidden files/storage stay in the file manager; Wi-Fi recovery in Connections; per-device settings inside each Device.
5. Matte route changes flashed light cream. Keep charcoal on light olive/cream and cream on dark olive controls; no all-white text on the light olive background.
6. Internal/shared phone storage uses one-time Android All files access, not repeated per-folder grants.
7. File manager must show Internal storage, SAF, and **Termux Home `/data/data/com.termux/files/home`**; both panes may select the same phone for copy/move, opening/live preview, and per-transfer subtree/file exclusions. Excluded items remain on the source during a move.
8. User wants supported direct Termux API/tool access without root. RUN_COMMAND requires its Android permission plus `allow-external-apps=true`. Termux:API is a different Android-function API. SAF can expose Termux Home through Termux's own DocumentsProvider; it cannot read arbitrary apps' private repositories.
9. User offered root/Shizuku permission if actually needed. None was needed or used this session. Protected phone system changes remain forbidden.

## Implemented and evidenced

- XXH64 manifests version 2, range header `X-Chunk-XXH64`, completed target reread for normal/TAR pulls, `manifest_xxh64` receipts, CLI `checksum`, SAF post-copy reread/check, copy/build scripts using xxhsum. Both peers must update; old manifests/staging fail closed.
- Narrow global Settings screen with real Shizuku API/provider 13.1.5 permission flow and bounded optional `su -c 'id -u'` check, persisted screen-awake setting. Root permission itself was not exercised. Shizuku service was not running. Screenshots `poco-settings-global.png`, APK verification `poco-settings-install.json`.
- Held physical drag/drop across classic panes passed; completed target `drop.txt` XXH64 `4ff0381d98288073`. See `poco-usb-xxh64-drag-drop.json`.
- Physical 64 MiB native and GUI LAN disruption -> USB ADB reverse resume passed; target XXH64 `2763167e436ad40d`. See `poco-usb-{native,gui}-route-recovery.json`. Tests disabled Wi-Fi after ~3 MiB through a deliberately throttled transparent LAN proxy and closed disconnected proxy sockets after two seconds. This is not an unthrottled benchmark or hotspot proof.
- Fixed LanCoordinator's unconditional CLI cancellation so explicitly approved fallback survives network changes; CLI ADB/SSH and switched-progress labels corrected.
- Matte transitions use a transparent animation background to preserve art outside Navigator. Intermediate-frame pixel push/pop regression passed. Palette explicitly defines warm olive secondary text and containers. Final physical transition video still pending.
- Native Termux tests/vet/build through USB with pinned SSH host key and optional vendored offline dependencies passed. Latest completed snapshot `/data/data/com.termux/files/usr/tmp/devicebridge-build.4F1Jp8xD`, log `termux-20261118T123344Z-35426.log`; this snapshot predates the later exclusions/documents/tools additions. Earlier source archive failed downloading a Go dependency; failure retained.
- Flutter milestone log had 7/7 passing tests and analyzer clean before later file-manager additions. Later focused Same-phone panes and exclusion-picker tests passed. Go focused exclusion/archive, native no-overwrite publish, and documents-adapter token/scope/Unicode/seek tests passed. Do not call this a final full-suite result for the latest source.

## Added later, built but hardware acceptance incomplete

- `phone_files.dart`: two selectable device/storage panes; same-phone Internal/SAF/Termux operations, copy/move confirmation, exclusions, local and remote bounded live text preview, Open with, hidden files and New folder.
- `folder_exclusions.dart`, `folder_name_dialog.dart`: lazy subtree selection and route-owned input controller.
- `LocalFiles.kt`: unprivileged internal and granted document providers, completed XXH64 comparisons, source-deletion preflight for moves, excluded source content retained, native atomic no-overwrite publication via Go `publish-local`. SAF providers that lack rename use new-document creation + full verification (atomic folder publication is not claimed there). Termux opened-FD path checks reject symlinks/grant escapes.
- `DocumentsGateway.kt` + Go `filesproviders.Documents`: token-authenticated loopback, read-only SAF/Termux agent provider, typed virtual exports via `Store.ExportDocuments`; no remote shell. Still needs physical real-Termux grant, list/read/Unicode/pull proof.
- Remote manifests and TAR streams support exact relative exclusions. Client checks returned exclusions match the request. `preview` CLI returns at most 64 KiB. New Go tests exist.
- Remote destinations/uploads/deletes in the new manager remain unavailable without a write feature/grant implementation. UI reports that limitation. **Do not claim remote uploads or moves work.**
- `TermuxControl.kt` / `termux_tools.dart`: local RUN_COMMAND screen under the file manager, dangerous permission flow, explicit tool+argument confirmation, PendingIntent result callback, 60-second timeout wrapper. No peer-facing command API. Built and installed; successful tool execution has **not** been proven.

## Immediate unresolved Termux issue

The phone granted `com.termux.permission.RUN_COMMAND` to DeviceBridge (`USER_SET`). A harmless `pwd` invoked from the actual Tools UI returned Termux's own error: `allow-external-apps` must be true, **despite** the setting being true on disk and `termux-reload-settings` having run. Do not invent successful RUN_COMMAND/UID proof.

- Enabled one documented property in `/data/data/com.termux/files/home/.termux/termux.properties`, preserving the original **on the phone only** in `/data/data/com.termux/files/home/.local/share/devicebridge/termux-integration-20261118/termux.properties.before` when the original existed. `setup.json` in that directory records the marker, previous state and checksum. Backup and completed updated file were independently XXH64 checked on the phone.
- Marker appended: `# DeviceBridge: user-requested RUN_COMMAND integration` then `allow-external-apps=true`.
- `.termux` and its properties file are ordinary paths, not symlinks; `.config/termux` does not exist. Regex confirms the active setting is `true`.
- Installed Termux is a fork with LauncherCtl features. Official upstream docs may not fully describe its cache/settings behavior. Investigate the *specific setting/cache read* without dumping private sessions/configuration or restarting/killing Termux sessions. Do not force-stop Termux to refresh this.
- Last UI test ended with `PlatformException(termux_failed, Error Code: 2 ... allow-external-apps ...)`; it produced no successful `poco-termux-run-command.json`.

## Picker correction

The system picker repeatedly reopened the previous shared-storage location. An earlier Termux grant selected a shared DeviceBridge test folder. Current source requires authority `com.termux.documents` for Termux Home and rejects the mismatched old grant. Initial URI changed to the proper Termux document URI. Actual Termux Home grant remains pending; choose **Termux from the provider drawer**, not POCO/internal storage. User explicitly corrected this mistake. Do not label an internal-storage directory as Termux Home.

## Artifacts and phone state

- Latest installed **debug** APK XXH64 `5d6f2d86d255d243`; install helper `.work/poco-usb-20261118/install.py` compares source APK with actual installed `base.apk` via xxhsum in Termux after every subsequent install. Latest source may differ from that APK by subsequent small edits; rebuild before acceptance.
- Release APK/LINUX bundle/artifact manifest are stale relative to the latest features. Do not present `artifacts/android-arm64/devicebridge.apk` as the current final release.
- All files access was granted through Android's own UI; keep as intentional owner preference.
- Termux external-command property and Android RUN_COMMAND grant remain as intentional setup for the requested integration; record/undo precisely if requested, preserving later edits.
- Wi-Fi was initially OFF and temporarily enabled for LAN tests. It is still ON; restoration deferred because the user is using the phone. No cellular/relay fallback was approved or used.
- Last phone screen: DeviceBridge Termux tools with the external-apps error. User confirmed availability for UI tests shortly before stop. All UI automation must continue using focus guards.
- Owned Termux fixture: `$HOME/DeviceBridge-USB-20261118/` with `move-fixture/{keep.txt,space λ.txt,excluded-cache/large.tmp}`, `return-destination/`, `live.txt`. These were created, not successfully moved. Do not touch unrelated home files.
- Test pairing, app-private downloads, prior owned shared SAF folder and unique snapshots remain. Keep their scope isolated.

## Cleanup / exact resumption

At handoff, stopped positively identified laptop fixture agents PID 14839 (loopback18731) and 39654 (LAN8731), removed the one temporary scoped UFW8731 rule, USB SSH forward18022 and reverse18731. No Termux/user sessions were stopped. No active build/test is intentionally left running.

On authorized continuation, inspect Git changes and current phone availability, then acquire a fresh session lock after checking for another live owner. Recreate only needed routes:

```bash
adb -s JBKJF6JFAAIZUGP7 forward tcp:18022 tcp:8022
ssh -o 'HostKeyAlias=[10.100.102.33]:8022' -o BatchMode=yes -p 18022 afzl@127.0.0.1 'bash -s'
```

Existing helpers/fixture state are in ignored `.work/poco-usb-20261118/`; **inspect before running** because some scripts assume an old APK native-library path, destination absence, or running test agents. Do not rerun setup or move fixtures blindly. Next gates: resolve direct Termux callback/property behavior; grant actual Termux provider if retained; focused local move/exclusion/return-copy/live-preview/no-overwrite tests on owned fixtures; physical remote SAF/Termux serving proof; final matte visual check; one coherent broad verification; release packaging with XXH64; authorized local checkpoint commit; cleanup and session-lock release after completion or a fully written handoff.
