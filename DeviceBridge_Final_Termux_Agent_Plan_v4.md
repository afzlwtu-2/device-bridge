# DeviceBridge — Final Modular Super-App Build Specification (v4, Termux-first)

**Status:** Authoritative, self-contained Termux coding-agent brief; v4 supersedes all previous DeviceBridge plans  
**Date:** 2026-11-18  
**Primary development host:** Android Termux (one authoritative source tree and one coding agent); Linux laptop is an SSH-connected build and real-device test worker.  
**Product:** Secure, extensible bridge among paired Linux/Android devices, with independent feature modules, interchangeable transport providers, optional Syncthing, and future owner-consented remote support for external SSH hosts.

**Primary success criterion:** From the phone, immediately browse and pull authorized files/folders on another paired device over a direct LAN/hotspot path without manual IP entry or uploading the data to a cloud service.

## 0. Agent mission and non-negotiable constraints

Build a working DeviceBridge, not another design document. Start with an inventory of the actual toolchains, repository, permissions, networks, and available Android APIs. Deliver functioning end-to-end slices with automated tests and documented manual tests.

**Product scope:** remote browsing and pulling authorized files/directories, one-time file/folder sending, clipboard/text sharing, peer discovery and network selection, optional registered-folder synchronization through a separately installed Syncthing daemon, Git-aware filtering, versions and single-writer ownership, optional privileged Android adapters, optional remote connectivity.

**Do not build in MVP:** embedded terminal, tmux viewer, AI agent manager, agent conversation interface, separate Files top-level tab, custom replacement for Syncthing's block-sync algorithm, cloud-first data storage. **Future optional features** may include scoped remote commands, a terminal view, and consent-based SSH remote assistance. These must not be prerequisites for core sharing and remote filesystem access.

**Hard policies:**
- All pairs are explicitly authenticated and granted capability-scoped permissions. No arbitrary shell endpoint in the initial release. Future remote-command and terminal modules require separate explicit, time-limited permissions and authorization.
- Remote listing/reading/writing may occur only within approved filesystem roots; no default whole-disk access.
- Prefer direct LAN / hotspot / Wi-Fi Direct, with user-approved network changes. No public discovery, relay, or cellular bulk transfer by default.
- Registered-folder synchronization is explicitly approved per transaction and paused/disabled otherwise.
- Each sync group has exactly one current authorized writer; stale holders cannot hand off or upload edits. Owner handoffs require verified revision state. Block on ambiguity, split-brain risk, or unsupported enforcement; never silently overwrite local changes.
- DeviceBridge never sends Git-tracked content or `.git` metadata in its sync module. It must verify compatible Git branches/commits and reject tracked dirty files or non-shared commits before handoff. Git remains the delivery mechanism for these files.
- Never transfer regenerable content (build outputs, caches, dependencies recreated from lockfiles, and device-specific ephemeral state). Use conservative classification. Generated source needed to build is NOT automatically regenerable.
- One-off transfers are distinct from sync: the user may intentionally share any authorized file/folder, including a Git file, without changing sync revisions.
- Treat root and Shizuku as optional, explicit capabilities, not prerequisites; don't assume Shizuku grants root or private-app access.
- No automatic modification of `/etc/hosts`, SSH config, firewall, package manager, Git remotes, existing Tailscale daemon, privileged startup services, or user project trees without prior approval.

## 1. Development strategy / system roles

**Source of truth:** a single Git working tree **inside Termux** (prefer `$HOME/projects/devicebridge`, but inspect existing directories and choose a non-conflicting path). Keep all unrelated Termux data untouched. Do not move source into Android shared `/sdcard` storage: Git/Unix permissions and symlinks may not behave correctly there. Back up to a Git remote and optionally create independent persistent archives.

**Coding agent:** run Codex (or equivalent) **inside Termux** and edit only this authoritative Termux working tree. Run Go tools and Termux-native tests locally. Use the Linux laptop via SSH as a remote *build/test worker*, not a second writing agent. Sync a **temporary non-authoritative source snapshot** from Termux to a clearly isolated Linux build directory for Flutter, Kotlin, Linux binaries, Android APK builds and tests. Do not run a second agent that edits the Linux snapshot. If both devices are connected, prefer LAN/hotspot SSH; use an already-authorized Tailscale path only when needed. Never expose credentials or root privileges to unrelated processes.

**Android/Termux:** act as both the main development host and a real app/companion test target. Keep the Go companion in Termux `$HOME`; test filesystem access, Syncthing REST and network discovery locally. Android APK builds should ordinarily run on the Linux build worker and deploy via `adb` or a user-approved package-install action. Avoid assuming Android Tailscale runs all the time. Use authorized SSH keys/aliases; do not assume a particular peer IP or SSH username.

**Privilege tiers:** read-only discovery is allowed after connectivity approval. Installation, permission changes, `su`/sudo, filesystem mounts, daemon persistence, package upgrades, and network reconfiguration must be explicitly scoped and approved. Despite passwordless sudo, default to unprivileged operations.

**Build artifacts:** Termux-native Go agent + CLI (built/tested in Termux), Linux Go agent + CLI (built/tested on laptop), Flutter Linux app, Flutter Android APK with Kotlin integrations, and optional Go hub on Dubai VM only when explicitly authorized. Do not assume `GOOS=android` automatically produces a binary with the right Termux runtime assumptions. Prove each deployment path on real hardware.

## 2. Stack and principles

- **Go:** shared wire protocol, pairing, device identity, capability authorization, discovery, filesystem API on Linux/Termux, streaming transfers, integrity checks, sync control client, local SQLite revisions, optional hub.
- **Flutter/Dart:** shared Linux and Android UI. Keep presentation separate from protocol logic.
- **Kotlin:** Android ConnectivityManager/NSD, Wi-Fi Direct/hotspot where permitted, SAF, Android share sheet and clipboard APIs, background service/notification lifecycle, FCM, optional Shizuku/root adapters.
- **Syncthing:** independently installed and updated daemon for *registered folders only*. Control with localhost JSON REST, never expose its administrative API or key to peers.
- **Persistent state:** SQLite with explicit schema migrations; transport protobuf or typed versioned JSON messages (choose once and document); cryptography via maintained standard libraries.
- **Optional remote:** use a process-local Tailscale client via Go `tailscale.com/tsnet` on Android (without Android VPNService) when technical spike validates it; use existing Linux tailscaled or tsnet as appropriate. Do not build a custom ICE/STUN/TURN implementation in MVP. User-approved DERP/peer relay fallback is acceptable and must be labeled; direct LAN/hotspot/Wi-Fi Direct transport remains independently usable without a tailnet.

Design for Android non-root baseline. Any Go-to-Android embedded binding via gomobile must be validated in a small proof of concept before being made an architectural dependency; fallback is Kotlin platform service speaking the shared versioned protocol and optional Go companion in Termux. **Do not use Go native `plugin`/`dlopen` dynamic modules as the general extension system:** Android support, cross-compilation and ABI compatibility make them unsuitable. Prefer compile-time provider registration, versioned interfaces and optional supervised external binaries with explicit contracts.

## 2A. Mandatory modular/plugin architecture — build interfaces now, implementations in stages

The application is a **modular super-app**, not one giant file-transfer daemon. Keep the *transport* (how bytes travel), *feature* (what the user does), *sync engine* (how a persistent folder reconciles), *filesystem provider* (what is exposed) and *platform capability provider* (OS permissions/APIs) independent and testable.

### Module types and contracts

1. **TransportProvider** (LAN TCP, mobile hotspot TCP, Wi-Fi Direct IP, app-only tsnet; future WireGuard kernel/userspace, SSH tunnel, USB): `ID`, `Capabilities`, `DiscoverCandidates`, `Probe`, `Dial/Listen/OpenStream`, `NetworkCost`, `Close`. Route offers report real interface, endpoint, direct/relay, metering, RTT, bandwidth, setup time and required user actions. The connection manager accepts a chosen authenticated byte stream and stays independent of the filesystem/sharing/sync implementation.
2. **FeatureModule** (RemoteFiles, QuickShare, Clipboard, RegisteredSync; future Commands, RemoteTerminal, SSHAssistance): `ID`, `RequiredGrants`, `RequiredCapabilities`, `RegisterBackend`, `RegisterUIActions`, `FeatureFlags`, `ProtocolVersion`. Only show supported modules/actions in the selected device detail. Core navigation remains Home / Devices / Share / Sync.
3. **SyncProvider** (SyncthingExternal initially; future rsync, restic snapshots or another protocol if explicitly requested): `Detect`, `Prepare`, `Plan`, `StartApprovedSession`, `Status`, `Stop`, `Recover`. It must use the central policy/ownership controller rather than embed its own conflicting rules.
4. **FileProvider** (Linux native POSIX, Termux sandbox, Android SAF, optional root, Shizuku; future SFTP/remote object storage): `List`, `Stat`, `OpenRead`, `OpenWriteStaged`, `Commit`, `Cancel`, plus scope and capability descriptors. Privilege is granted per operation, never globally by default.
5. **PlatformServiceProvider** (Android connectivity/FCM/background/SAF, Linux systemd/network manager/notifications, Termux shell APIs): the UI and business modules depend on typed capabilities, not Android-specific calls.

Implement these as **plain Go interfaces and explicit registries** for backend; Flutter interfaces and route/action descriptors for GUI; Kotlin platform adapters for Android. Use dependency injection and mockable interfaces. Do not use Go native dynamically loaded plugins. Later third-party modules, if desired, can be isolated subprocess/sidecar protocols with authenticated versioned RPC; do not implement arbitrary downloaded code execution in the MVP.

### Wire protocol and extensibility rules

- Version all RPCs and capability schemas; negotiate minimum supported versions; new fields must be backward compatible where practical.
- Each feature owns its own storage/migrations and security scopes; shared pairing and transport never grant default access to new modules.
- Transport providers may share a destination physical interface; do not infer physical route from the overlay name. Require independent metering/route verification.
- Prevent two transport providers from silently duplicating ongoing transfers or handing privileged credentials to peers.
- Register built-in modules statically in the first release; UI should not require a new permanent tab for future commands/terminal features.
- Add a test fake transport and fake file provider early so multi-device behavior can be integration-tested on one host.

## 3. UI and user journeys

Only **Home, Devices, Share, Sync** in primary navigation. No top-level Files, Agents or Terminal tab in MVP. Each device detail contains a capability-driven action screen, including authorized remote filesystem browsing. Design navigation as an extensible feature registry so future Commands, Remote Terminal, SSH Help and related integrations can appear as contextual device actions rather than forcing permanent tabs.

### Home
Show paired devices, online/sleeping/offline with uncertainty, current path (LAN/hotspot/Wi-Fi Direct/Tailscale/relay), recent transfers, quick Share and Sync actions.

### Devices
Pair via QR or one-time code + public-key verification. Show each device's editable name, stable cryptographic ID, current LAN/hotspot/Tailscale candidate IPs with interface and last-seen timestamp, route latency/speed estimates, allowed exported directories, device capabilities, revocation and direct-only policy. Device detail includes Browse / Pull / Upload actions. Browse only approved roots and lazy-load directory metadata (no automatic copy).

### Share
Instant text/clipboard exchange, Android Share Sheet integration, files/folders send or request pull, transfer progress, pause/cancel/resume, recent history. A received text does not automatically overwrite the system clipboard unless approved; respect Android clipboard background limitations.

### Sync
Manage registered folders, current owner/writable state, signed revision/epoch + parent, remote revision, pending persistent non-Git data, Git HEAD/branch/cleanliness, divergence/blocked diagnostics, exclusion policy, preflight, approval and history. Provide a clear **Handoff to Device** action after verification.

### Critical UX distinction
**Pull** downloads remote data as a one-off action and does not create a sync relationship. **Sync** updates registered folder state through Syncthing and obeys the single-writer/Git/regen rules.

## 4. Identity, pairing, authorization and transport security

- Generate stable device keypairs. Pair with mutual approval plus QR/short-code identity verification; never trust IP or advertised hostname as identity.
- Use mutually authenticated encrypted sessions (mTLS or well-maintained Noise implementation); rotate/revoke keys; authenticate requests and responses.
- Capability grants: `browse(root)`, `read(root)`, `write(root)`, `share_receive`, `sync(group)`, `clipboard_send`, `clipboard_receive`, `privileged_op` (separately consented). Apply quotas, expiration and audit logs.
- Directory handles are scoped to roots: canonicalize and resolve paths; defend against `..`, symlink escape, races/TOCTOU, renamed files and unsafe archive entries. Avoid shell command concatenation.
- Secrets/API keys only in OS-protected private storage; never in logs or cloud registry. Peer-facing DeviceBridge API never accepts Syncthing administrator credentials.
- Incoming transfers enter a staging location; verify expected metadata/hash; atomically publish where supported, with safe retry/rollback on failure. Explicit overwrite confirmation for one-off operations.

## 5. Discovery and route selection

- Network-change notifications first; mDNS/DNS-SD on LAN; UDP discovery only if permitted; hotspot gateway/client endpoint detection; cached authenticated candidates with TTL; optional hub presence for remote.
- Probe candidate paths *after* pairing, run an authenticated handshake, record IP/interface, RTT, reachability, measured throughput and whether route is metered/internet/relay.
- Prefer direct LAN. If changed bytes and file count justify it, offer hotspot or Wi-Fi Direct setup with an estimated time saved including switching overhead. Ask before modifying network state because online agents/SSH may disconnect.
- Linux Wi-Fi Direct requires driver/supplicant capabilities; Android must establish P2P network first. Do not assume Wi-Fi 6 PHY or 100 MiB/s; benchmark and fall back cleanly.
- By default deny relayed/public discovery/cellular bulk transfer. Prefer direct authenticated DeviceBridge LAN/hotspot/Wi-Fi Direct transport for local peers; for remote, use app-specific `tsnet` or an existing authorized Tailscale path. Verify whether the tailnet path is direct or relayed; allow a DERP or peer relay only after network/bandwidth policy permits it. There is no custom STUN/TURN server in MVP. Do not silently switch to a metered or relay route when local goes down.
- Optional device-name resolution: display actual IPs; provide a `devicebridge resolve <name>` CLI and optional SSH `ProxyCommand` / isolated `Include` snippet. Do not write `/etc/hosts` by default.

## 6. Independent remote filesystem module (highest priority)

Linux/Termux Go agent exposes only authorized operations:

```
ListRoots
ListDirectory(root_id, relative_path, page_token)
Stat(root_id, relative_path)
ReadRange(root_id, path, offset, length)
Preview(root_id, path, type, max_bytes)
Search(root_id, query, bounded_scope)       # later
DownloadFile/DownloadFolder(request)
UploadFile/UploadFolder(request)             # requires write scope
TransferStatus/Cancel/Resume
```

- Support lazy browsing, paging, metadata, bounded previews and ranged reads. Never download entire directories just to display their contents.
- Downloads choose direct chunked transfer or archive streaming after scanning and estimating the workload.
- For a huge new tree of tiny files, allow streaming tar+adaptive zstd **without building a temporary archive**; extraction still requires creating every file, so benchmark actual metadata overhead. Use download-first archive when robust resume/verification is more valuable and free storage allows it.
- For huge binary files, prefer chunk/range transfer with verified resumability; no pointless compression. Queue transfers across reconnects, but only automatically resume on approved routes.
- Integrate Android SAF for granted folders, rootless and Shizuku/root adapters for explicitly extended capabilities; do not assume unrestricted private app data.
- A small Termux companion is allowed for `$HOME` and Syncthing control, but DeviceBridge must not provide a terminal UI.

## 7. Independent quick-share module

- Send/receive one-off files/folders (including intentional user-chosen Git-managed files), short text and clipboard; pairing and approval policies apply.
- Android Share Sheet as a primary entrypoint. Implement file/folder picker and destination picker; desktop drag-and-drop if easy.
- Small text uses signed encrypted messages. Large directory transfers can use streaming tar/zstd; file transfer supports checksums, staging, progress and resumption.
- No implicit permanent sync registration or ownership revision changes.

## 8. Optional external Syncthing module (registered folders only)

**Integration design:** detect existing installed Syncthing daemon; use authenticated local REST on loopback. Prefer a dedicated *Syncthing profile/config instance using the existing installed binary*, if global defaults or other user folders conflict with DeviceBridge's strict approval/direct-only policy. Do not modify a user's other Syncthing folders or global preferences silently. Show a compatibility warning when adopting an existing daemon.

- Build typed REST client with version detection and capability checks; do not hardcode assumptions from a single version.
- Initial configured state: no automatic acceptance; public/global discovery disabled; relays disabled; NAT mapping disabled; explicit approved endpoints; no unaudited dynamic addresses; enforce direct-connection route restrictions.
- Control local daemon startup/lifecycle separately from app UI; Android can stop when idle, subject to Android restrictions. Never expose REST key to remote peers.
- Sync only after a complete preflight and user approval, then permit a narrowly scoped session, verify completion and quiescence, record signed revision and pause/restrict again. A paused daemon is not a transactional lock: build fail-closed controller logic, session expiry, transfer route checks and crash recovery.
- Use Syncthing send-only owner/receive-only destination as a supporting mechanism, not as proof of filesystem immutability. Reject unmanaged remote changes, stale owners and conflicting revisions.

### Git-aware exclusion challenge — solve before enabling project sync

Syncthing's `.stignore` patterns do **not** automatically understand Git status. A naive `ignore .git` setup would still send tracked project source and violate the user's hard rule.

Implement an auditable allowlist/projection step:
1. Detect Git roots and recursively enumerate tracked paths, untracked paths and ignored paths with Git-native commands (properly handle submodules, worktrees, whitespace/null-delimited names, renamed files and nested repos).
2. Exclude `.git`, tracked paths, regenerable directories, device-local config, secrets by default, and unidentified/unsafe file categories. Explicitly allow eligible persistent untracked or Git-ignored paths by profile/user policy.
3. Build a **separate DeviceBridge-managed filtered sync projection/staging directory** for eligible files (safest initial implementation). Do not hardlink writable staged files back into working directories; use verified copy/import or an equivalent safe design.
4. Syncthing syncs only the filtered projection, never the whole project. On receipt, validate manifests and ownership before importing into project paths; preserve destination local-only files and never delete files based solely on an exclusion.
5. Optimize projection performance only after correctness tests. If user opts into a non-Git plain data folder with no filtering requirement, Syncthing may operate directly on it with strict policies.

Tracked dirty changes -> block and require user to commit. Unpushed commits / mismatched branch or HEAD -> block handoff until user uses Git to reconcile; do not copy Git content through DeviceBridge. Confirm destination Git state before ownership transfer. No silent `git reset/clean/pull/push`.

### Regenerable-file exclusions

Mandatory policy for Flutter/Dart caches, build/, `.dart_tool`, Android `.gradle`, `.cxx`, iOS DerivedData, Go caches, Node `node_modules` when lockfile reproducible, temporary logs, and similar. Portable dependency manifests and lockfiles that Git manages remain Git's responsibility, not DeviceBridge's. Never assume generated source needed for building is recreatable: require an explicit reproducibility classification.

### Single-writer revision and handoff

- Create revision record containing group_id, owner_id, generation/epoch, parent_hash, filtered manifest hash, Git branch+HEAD evidence, issue timestamp, acknowledgment receipts. The highest integer alone isn't proof of authority; validate the chain and signed ownership transfer.
- Ownership transfers only from current verified owner to a fully up-to-date destination, with both parties accepting; mark previous owner read-only/stale. If coordinator/peer is unreachable or state diverges, deny new ownership transfers (especially offline split-brain).
- Prevent writes through DeviceBridge; advertise read-only state; optionally configure filesystem permissions on explicitly approved managed folders. Explain that external programs running as the user can still write unless separately sandboxed/enforced. Detect unauthorized mutations and block further sync, preserving copies for recovery.
- Version records are not backups; provide optional versioned file backups / snapshots for recoverability.

## 9. Android architectures and lifecycle

**Non-root Android:** Flutter + Kotlin, SAF-approved roots, platform-native filesystem service/protocol, notification/foreground transfer lifecycle, no requirement for Termux. Confirm if a gomobile Go core is robust enough by proof of concept; otherwise keep a common protocol and targeted Kotlin adapter. User-initiated transfer work should use Android-supported execution patterns.

**Termux Android:** standalone native Go companion has access to its own `$HOME`, and can control local Syncthing via REST. DeviceBridge UI and Termux are separate UIDs: pair their local bridge securely; never assume GUI can directly read Termux private files. Avoid running a separate Tailscale instance inside Termux automatically.

**Shizuku:** optional, capability-probed, ADB-shell permissions not root; may require restarting/re-authorizing after reboot. Never depend on it for basic file sharing.

**Root:** optional scoped privileged broker, disabled until user grants consent; avoid exposing a general-purpose root shell or bypassing protected data unrelated to a granted user operation.

**Battery:** don't hold Wi-Fi locks overnight or poll continuously. Use network callbacks and optional FCM requests, user-visible notifications for remote requests, Android-compliant foreground/user-initiated transfer jobs. FCM cannot guarantee waking a force-stopped phone. Distinguish device offline / sleeping / probably reachable; do not fake online presence.

## 10. App-only Tailscale integration, optional hub and Android lifecycle

**Critical design:** `tailscale.com/tsnet` is the preferred *app-only remote transport*, not the Android system VPN. It uses a userspace stack and creates its own tailnet node identity. Users explicitly authenticate their app to a tailnet; do not embed permanent auth keys or reuse another app's private Tailscale state. Persist state inside DeviceBridge private storage, protect secrets, and offer logout/revocation. `tsnet` is BSD-3-Clause; verify transitive dependency license notices.

- Keep direct DeviceBridge LAN/hotspot/Wi-Fi Direct transport separate from tailnet transport. Tailscale can often create local direct paths itself, but do not rely on that for offline LAN, guaranteed best throughput, or proof that no relay is used. Direct local DeviceBridge transfer should still use mutual authentication and encryption.
- Linux: initially connect to a DeviceBridge agent reachable through existing `tailscale0`/tailscaled when permitted. Do not replace or reconfigure an already working Linux Tailscale deployment. Avoid duplicate tsnet identities on Linux without a user-visible reason.
- Android: perform a **dedicated proof-of-concept** before adopting tsnet production integration: compile/bridge Go for Android arm64, interactive login, persist node state, direct dial to laptop, report direct vs DERP status, reconnect after Wi-Fi/hotspot changes, close/suspend without draining battery, ensure no `VpnService` entitlement used. If tsnet-in-app is problematic, use an optionally installed separately managed userspace tailscaled/SOCKS5 provider and document limitations.
- `tsnet` makes **DeviceBridge's own connections** reachable; it does not create a system-wide VPN or automatically give Termux/SSH/other apps route access. A future built-in SSH client can use the app's own network dialer. Devices must still be allowed by tailnet ACL/grants and DeviceBridge's own per-root permissions.
- A direct Tailscale connection may still use the local Wi-Fi or hotspot physical interface while remaining encrypted, and path selection can change over time. Report measured actual path/status and avoid unjustified claims that WireGuard encryption is the performance bottleneck. Do not disable DeviceBridge transport authentication/encryption on local paths.
- Tailscale already handles NAT discovery and can use DERP or peer relays. Do **not** deploy independent Pion ICE, STUN, TURN, DERP or an internet file relay in the initial version. Relayed transfer may use internet bandwidth, so make it a clearly labeled, user-controlled policy (especially on cellular).
- Tailscale can require internet for control-plane/auth/bootstrap, and relays if direct paths fail. An offline local network must remain usable through direct discovery and pairing without Tailscale, FCM or Dubai.
- Optional Dubai hub only for FCM signaling, relay/path policy coordination if demonstrably needed, and time-limited invitations. No arbitrary command execution or storage of user project files, private clipboard, or third-party credentials.
- Android cannot be guaranteed remotely reachable while asleep merely because tsnet is embedded. For an actively used phone, connect on demand; for sleeping receiver, use optional FCM request with visible approval and Android-compliant user-initiated transfer or foreground work. Never claim push can indefinitely run a background daemon; avoid idle sockets/wake locks by default.

## 10A. Future super-app extensions — architecture now, code later

**Principle:** feature modules are capability-driven, discoverable in device details, separately permissioned and independently installable/disableable. Existing Home / Devices / Share / Sync navigation stays simple. Avoid making users install a terminal or remote-control service to share files.

**Future feature #1 — One-click remote commands:** named allowlisted tasks (disk usage, logs, service status, backup, etc.) that run on the remote agent only after the owner approves the exact command/action and expiry. Use command ID plus validated arguments, not shell string concatenation. By default no arbitrary shell and no sudo. Record requester identity, execution time, arguments, exit code, output limits and audit logs. Each action can be individually authorized/denied and revoked.

**Future feature #2 — Optional remote terminal:** a real audited remote PTY/SSH session, launched from a device detail. On Android only, consider embedded keyboard from Termux Launcher subject to GPL compliance, or implement independently. Entirely optional and **not an MVP requirement**. It must not create separate tmux sessions without user intent or expose existing Termux/SSH credentials to other peers.

**Future feature #3 — Consent-based helping other people:** explicitly distinguish personal *paired device* trust from a **guest/assistance connection** to another person's machine. Offer manual SSH connection using verified host keys; potentially support a one-time remote agent invite with limited roots/operations, expiration and immediate revoke. Require remote owner's informed consent for any interactive terminal, screen support, uploads, admin tasks or execution. Do not automatically pair the guest device into the owner's tailnet or inherit all personal-device grants. No unattended root, no credential harvesting or undisclosed monitoring.

**Future feature #4 — External SSH hosts:** optional built-in SSH/SFTP client for third-party systems, using per-host credentials protected by OS secure storage and authentic host-key pinning; may run through app-local tsnet only when that host is legitimately tailnet reachable. Arbitrary external SSH devices do not become directly reachable just because DeviceBridge supports Tailscale; they need reachable IP/port or an approved overlay/relay. SSH-based browses/downloads may use SFTP when the DeviceBridge agent isn't installed.

**Feature extension contract:** each module declares name, icon, supported platforms, required capabilities, permission scopes, background requirements, protocol version, feature flags and presentation entry points. The app shows only actions available on a selected device. No permanent top-level Agents, Files or Terminal tabs.

## 10B. Reserved transport provider: WireGuard (FUTURE ONLY)

Do **not** implement a WireGuard tunnel, import user credentials, configure interfaces, or modify routing in the initial release. Design the `TransportProvider` interface and UI capability negotiation so that a future module can accept an explicitly approved `.conf` profile and expose a stream to DeviceBridge features.

Support these as distinct future backends, with different privilege and operating-system requirements:
- **Linux kernel WireGuard**: use an existing `wg` interface and userspace configuration tools (`wg`, `wg-quick`, `wgctrl-go`) where available; may require network administration permissions. Do not overwrite the user's existing routes or interface configuration.
- **Linux userspace WireGuard**: a `wireguard-go`-based tunnel may still need TUN privileges; investigate netstack-based application-only dialing separately.
- **Android non-root**: a standard full-device WireGuard VPN typically requires Android `VpnService` and occupies the VPN slot. Investigate an application-only userspace netstack in the future, but do not promise ordinary `wireguard-go` CLI alone bypasses VPN/system permission requirements.
- **Android rooted**: kernel-backed or privileged userspace tunnel only behind a separate permission grant and device-specific checks.

Future UI: *Add Transport → WireGuard → Import configuration → Validate (without revealing secrets) → Inspect allowed IP ranges/routes → Request approval → Test reachability*. Store private keys only in protected local storage and never upload them to Dubai. Display whether the selected path is direct or relayed where known and never assume WireGuard automatically solves NAT traversal.

Official references: https://www.wireguard.com/embedding/ and https://www.wireguard.com/xplatform/ .

## 11. Repository skeleton

```
devicebridge/
  cmd/bridge-agent/             # Linux/Termux Go agent
  cmd/bridge-cli/               # debugging, discovery, SSH name resolution
  cmd/bridge-hub/               # optional later
  internal/auth/                # identity, pairing, tokens, grants
  internal/discovery/           # mDNS, endpoints, network transitions
  internal/route/               # selection, benchmarks, metering
  internal/transport/            # TransportProvider interfaces + registry
  internal/transport/direct/     # LAN/hotspot/P2P IP transports
  internal/transport/tailnet/    # tsnet remote transport (optional)
  internal/transport/wireguard/  # interface/test stub only, FUTURE (no tunnel code)
  internal/filesproviders/       # scoped native/Termux/SAF capabilities
  internal/platform/             # platform lifecycle/capability abstractions
  internal/tailnet/              # optional Tailscale login/state management
  internal/features/            # future capability feature registry
  internal/files/               # authorized filesystem API
  internal/transfer/            # chunks, tar streams, verification
  internal/share/               # clipboard/text/one-off transfers
  internal/remotetasks/         # future, opt-in command presets (NOT in MVP)
  internal/synccontroller/      # versioning, ownership, Git, profiles
  internal/syncproviders/       # SyncProvider registry (Syncthing initially)
  internal/syncthing/           # typed localhost REST client
  internal/storage/             # migrations, SQLite
  protocol/                     # versioned messages/schema
  app/                          # Flutter Android and Linux application
  app/lib/features/             # UI feature registry, devices/share/sync
  app/android/                  # Kotlin plugins/notifications/SAF/etc.
  test/integration/
  test/e2e/
  docs/ARCHITECTURE.md
  docs/SECURITY.md
  docs/IMPLEMENTATION_STATUS.md
  docs/TEST_MATRIX.md
  scripts/termux_to_linux_build.sh  # authorized, isolated snapshot build worker
  scripts/
```

Adjust directory names if they conflict with standard Flutter layout; optimize for easy builds and code navigation.

## 11A. Termux agent operating procedure (must follow)

1. **Start locally, no assumptions:** run read-only inventory (`pwd`, `whoami`, `go version`, `uname -a`, `command -v ...`, `git status` in candidate directory). Identify if an existing DeviceBridge repo or plan already exists; do not overwrite it. Inventory optional `syncthing` / `offdesk-tui` / `tailscale` presence without changing their setup.
2. **Choose one authoritative repo** under Termux `$HOME` (not shared `/sdcard`). If a user-repo already exists, work there with preserved history. Set up `.gitignore` for build artifacts and private keys; create `AGENTS.md` with safe workspace rules. Use Git commits only if permitted by user/session policy; never force push.
3. **Discover Linux build worker** using existing SSH configuration, one explicit alias/address or a user-approved lookup; try direct LAN/hotspot first. If not reachable, work locally and document blockers rather than changing Tailscale or using a cloud server without approval.
4. **Stage disposable copies** into a unique isolated build folder on Linux, e.g. `$HOME/.cache/devicebridge-build/<commit-or-run-id>/` after permission. Do not synchronize the user's other projects. Use `rsync` with safe exclude rules, preserve source hashes and avoid overwriting a previous run. The **Linux copy is never an independently writable source of truth**; build-generated files may change there, but source edits are returned as a patch for explicit review before merging into Termux repo.
5. **Use laptop for Flutter/Android builds** and Linux integration tests. Return APKs, logs, screenshots, diagnostics and binaries to Termux under `artifacts/` or `docs/test-evidence/` (not committing large binaries). Do not assume root or passwordless sudo is required for routine builds.
6. **Deploy APK and test deliberately.** First verify Termux agent peer-to-peer via Go CLI; then Android GUI via safe install steps. Ask before package installs/upgrades, `adb` pairing changes, root/Shizuku changes, Wi-Fi changes, Syncthing settings, firewall changes, or persistent service setup.
7. **Maintain one concise status log** `docs/IMPLEMENTATION_STATUS.md` with tests, command results, genuine measured routes, known limitations, current milestone and next action. If Linux goes offline, continue safe Termux/Go progress and don't fake Android UI build completion.
8. **Security of privilege:** treat passwordless `sudo`/`su` as technical capability only, never unrestricted permission. Never print/private-copy SSH keys, Tailscale node state, Syncthing API keys, Firebase tokens, WireGuard configs, or secrets into logs.

## 12. Agent execution milestones and acceptance gates

**M0 — Termux-first inventory and build pipeline.** Inspect the Termux environment, its Go toolchain, Android capabilities, current working tree, and available Linux SSH endpoints. On Linux inspect Flutter/Android SDK, JDK, Gradle, `adb`, Go, Syncthing, `iw`, SSH and graphics toolchain. Record sanitized details; do not change packages/services or use `su`/sudo without scoped approval. Build a reproducible **Termux source → SSH isolated Linux build directory → artifact/log return** workflow, a buildable skeleton, and CI.

**M1 — Pairing + direct LAN transport.** Implement identity/key verification, mutual auth, local discovery, authenticated endpoint handshake. Two local test agents, then Linux-to-Termux, connect over a known physical interface without cloud/discovery relay. Show actual source/destination IP, route and transport ID.

**M2 — Remote browse and pull (first mandatory deliverable).** Android can pair with Linux, list approved directories lazily, retrieve/save a small file, and pull a folder with integrity verification; deny traversal and unauthorized paths. Both Termux CLI and GUI (once available) should reach the same agent API. DeviceBridge must not require Syncthing.

**M3 — Share and clipboard.** Send text/clipboard and one-off files; Android Share Sheet; arbitrary folder transfer with archive and chunk strategy; progress, failure recovery and limits. Nothing becomes a sync relationship implicitly.

**M4 — Flutter UI + network intelligence.** Home/Devices/Share/Sync navigation, actual state not mock; route benchmarks, IP list, dynamic SSH alias helper, hotspot recommendation and approved switching; experimental Wi-Fi Direct after baseline.

**M5 — External Syncthing control.** Detect installed daemon / optional dedicated profile, authenticate localhost REST, manage approved folders and status, enforce no public discovery/relays and default-off sync, test pausing/quiescence and crash recovery.

**M6 — Project policy + single-writer handoff.** Implement filtered projection, Git-aware exclusion validation, regen policies, signed revision chain, owner handoff, stale-device lockout within app, snapshot option, clean Git preflight; perform controlled Android↔Linux sync without transferring tracked content.

**M7 — Non-root Android, optional Shizuku/root and Termux.** Test SAF, app lifecycle, non-root file server, root/Shizuku capability detection and privilege boundaries. Ensure base functionality works without those tools. Battery/doze overnight testing.

**M8 — Remote access and hardening.** First perform an Android tsnet proof-of-concept (no Android VPNService); integrate explicit remote tailnet paths with existing Linux tailscaled and label direct/DERP status, plus optional FCM for sleeping phones. No custom ICE/STUN/TURN in MVP. Test firewalls, NAT, fallback behavior, failure recovery and no hidden internet traffic. Release packaging, license notices for all used dependencies, documentation and benchmark reports. **Future WireGuard support is architected but NOT implemented in this milestone.**

**M9 — Future modular remote actions (not MVP).** After core transfer/sync features are stable, add a feature registry and audited, allowlisted remote command presets. Prove per-device consent/revocation and output-limiting without exposing general shell.

**M10 — Future terminal and guest remote support (not MVP).** Add opt-in SSH/SFTP guest-host connections with verified host keys, then optional fully interactive terminal with keyboard, explicit session grants and revocation. Never require these features for basic bridging.

Each milestone must produce a working artifact, test evidence, limitations and `docs/IMPLEMENTATION_STATUS.md` updates. Do not claim a feature works based only on mocked UI.

## 13. Required test matrix

- Linux↔Termux paired on home Wi-Fi and 5 GHz hotspot; IP changes; multicast blocked; hotspot changes gateway.
- Android standalone without Termux/root; SAF permitted and restricted paths; separate Termux companion access when installed.
- Files: empty, unicode/space paths, very long paths, symlinks, malicious relative paths, nested directories, huge single file, hundreds of thousands of small files, limited free space, interrupted stream, corrupted checksums, simultaneous sender/receiver restart.
- Transfer: no unwanted data on cellular; approve/deny route; speed benchmarks vs measured hotspot baseline; tar streaming vs chunked transfer and resume semantics.
- Auth: unpaired device denied; revoked device denied; stale/replayed token denied; root/Shizuku disabled baseline; remote API never exposes Syncthing key.
- Sync: Git clean vs dirty, unpushed commits, wrong branch, nested repo/submodule, Git-ignored persistent file, generated caches, secrets, conflicting non-Git changes, stale owner, simultaneous handoff, crashed controller, offline destination, deletion attempt, recovery snapshots.
- Syncthing integration: daemon missing, API unreachable, wrong key, incompatible version, paused folders, route changes during sync, unexpected external Syncthing activity, existing user Syncthing config left intact.
- Android background: sleeping phone, FCM late/missing, airplane mode, battery restrictions, app killed, reboot, no background data transfer unless authorized and supported.
- Android tsnet spike: no VPN permission, persistent identity/login/logout, reconnect on hotspot/LAN change, tailnet ACL enforcement, direct vs DERP labeling, on-demand shutdown, non-root operation and actual power measurements.
- Future remote assistance: unauthorized command denied, command output size limits, arbitrary shell disabled by default, guest host-key mismatch blocked, time-limited help token expires, revocation terminates session and audit logging excludes secrets.

## 14. Deliverables and success metrics

Deliver native Go Linux/Termux builds, Android APK, Linux GUI build, source with reproducible build instructions, migrations, test suite, concise design docs, threat model, and real-network benchmark report.

The first practical milestone is **from Android, browse and pull an approved Linux directory over LAN without knowing its IP**. Next: send text/files; then Syncthing-controlled registered-folder handoff, then app-local tailnet remote access. Keep large-folder speed near measured direct-link capacity when not storage/CPU bound, but never promise a fixed throughput. Unchanged registered-folder sync should transfer no file-content bytes. Idle Android app should avoid custom polling/wake locks.

## 15. Rules for coding agent conducting the work

1. Implement, don't only plan. Work on **one writable source tree in Termux**. Send disposable copies to the laptop for builds/tests, and return logs/artifacts rather than editing source there.
2. Read `AGENTS.md` and existing repository conventions if present. Don't override unrelated files.
3. Validate uncertain Android, Syncthing and Go APIs against current official docs before implementing.
4. Request authorization before writes outside the DeviceBridge repository or designated isolated Linux build/test directory, root commands, package/service installs, remote VM changes, or firewall/SSH edits. Passwordless sudo isn't permission to change everything.
5. Commit at coherent milestones if the user has approved commits; never force-push or rewrite Git history.
6. Run formatting, linting, tests, build and manual E2E; report truthful pass/fail output.
7. Use actual connected devices, not fabricated network addresses or mock completion status.
8. If a feature requires unsupported platform permission, implement an explicitly labeled fallback and document it rather than working around sandbox protections invisibly.
9. Preserve security, version integrity, battery usage and direct-route preference over chasing maximum throughput.
10. Begin immediately with M0, then complete M1 and M2 before broad UI expansion. If Linux is unavailable, complete local tests, mock loopback multi-agent tests and infrastructure work, but do not claim cross-device success until hardware tests pass.

## 16. Official references for implementation

- Syncthing REST API: https://docs.syncthing.net/dev/rest.html
- Syncthing config API: https://docs.syncthing.net/rest/config
- Syncthing connection/privacy tuning: https://docs.syncthing.net/users/tuning.html
- Syncthing ignore patterns: https://docs.syncthing.net/users/ignoring
- Syncthing GitHub and MPL-2.0: https://github.com/syncthing/syncthing
- Tailscale tsnet: https://tailscale.com/docs/features/tsnet
- Tailscale tsnet Server: https://tailscale.com/docs/reference/tsnet-server-api
- Tailscale userspace mode: https://tailscale.com/docs/concepts/userspace-networking
- Tailscale connection types: https://tailscale.com/docs/reference/connection-types
- Tailscale BSD-3-Clause license: https://github.com/tailscale/tailscale/blob/main/LICENSE
- TailSocks (Android no-VPN reference): https://github.com/bropines/tailsocks
- Android Wi-Fi Direct: https://developer.android.com/develop/connectivity/wifi/wifi-direct
- WireGuard embed integration (future): https://www.wireguard.com/embedding/
- WireGuard kernel vs userspace (future): https://www.wireguard.com/xplatform/
- Android user-initiated data transfer: https://developer.android.com/develop/background-work/background-tasks/uidt
- Termux Syncthing package: https://github.com/termux/termux-packages/blob/master/packages/syncthing/build.sh
