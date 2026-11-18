# DeviceBridge implementation

The laptop source tree is authoritative per the user's 2026-11-18 correction. Termux receives disposable, hashed snapshots for native builds/tests. There is no second editable repository. The original v4 specification remains authoritative except for this explicit workflow correction and the absolute phone system/partition safety rule in AGENTS.md.

## Processes and responsibilities

- `bridge-agent`: user-started Go HTTPS/mTLS service, bound to one approved private IPv4 address; scoped read-only filesystem providers and DNS-SD responder. No shell execution endpoint, root, automatic daemon setup, Syncthing, relay or overlay.
- `bridge-cli`: Go identity, pairing, policy, discovery and verified transfers. Also provides JSON operations to Flutter. SQLite state is private and shared safely between local processes; schema versions 1–2 migrate transactionally.
- `app/`: Flutter Android/Linux presentation. Four main destinations: Home, Devices, Share, Sync. File browsing is nested within a device. Share/Sync explain their unavailable state rather than pretending to operate.
- Android Kotlin: runs only the packaged app-private Go PIE executable, discovers Wi-Fi link properties, scopes multicast reception to operations, cancels on network loss, runs a user-started dataSync foreground service during pulls, and exports verified downloads through SAF. No Android-wide VPN, boot receiver or wake lock.
- Termux CLI/agent: optional native companion, particularly for rootless access to Termux private directories. The standalone APK bundles its own NDK-built Go executable; it does not invoke Termux. Installed-APK execution is a separate acceptance gate.

The bundled executable approach was tested before adoption. NDK PIE execution, persistent identity, execution from the installed APK's native-library directory and the complete GUI pairing/browse/pull journey passed on the physical phone. The app runs as UID 10408, not root; root was used only for authorized installation and test observation. No gomobile binding or Go plugin ABI is assumed.

## Independent versioned extension systems

All contracts start at version 1, reject incompatible or duplicate registrations, and use compile-time dependency injection:

| Type | Contract and registry | Current implementation |
| --- | --- | --- |
| Transport | `internal/transport` | approved on-link TCP, `direct-lan-v1` |
| Feature | `internal/features` and Flutter `features/registry.dart` | remote files, contextual device action |
| Filesystem | `internal/filesproviders` | race-resistant scoped native/Termux read-only roots |
| Sync engine | `internal/syncproviders` | contract only, empty registry; no sync runs |
| Platform | `internal/platform` | contract registry; Android typed platform-channel adapters |

File features consume providers and clients consume authenticated transport streams. Integration tests substitute both a memory filesystem and a fake stream transport. Future modules do not inherit existing grants.

Reserved future integrations: kernel WireGuard and userspace WireGuard are distinct transport providers; configuration import, route inspection and explicit consent must precede dialing. No tunnel/config import code exists. Future tsnet requires the dedicated Android login/path/battery/no-VPN proof in v4. Additional sync engines must accept the central policy controller's approved session; a provider cannot authorize its own writes. Future commands/terminal/SSH assistance require independent expiring grants and a separate guest-consent model.

## Storage and filesystem consistency

SQLite uses foreign keys, WAL, FULL synchronous durability, a busy timeout and one connection per process. It stores identity keys, invitation hashes, peers, expiring per-root grants/quotas, audit events and a 30-second authenticated endpoint cache. Private keys never leave the core state directory.

Go `os.Root` anchors each explicitly exported directory. Traversal, absolute paths, backslashes and colon paths are rejected. Symlinks and special files block folder transfers. Nonblocking/no-follow opens avoid FIFO hangs and final-component link races. Metadata uses scoped root operations rather than unconfined directory-entry stat calls.

Pulls obtain bounded manifests with SHA-256 per file, request verified 1 MiB ranges, fsync staging, rehash complete files, and atomically publish with Linux/Android `renameat2(RENAME_NOREPLACE)`. A staging lock prevents two writers. Partial staging is retained on failure; resume requires identical peer and manifest metadata. Existing destinations are never overwritten. Folder sources are not filesystem snapshots: per-file integrity is guaranteed, but concurrent directory mutation can change which entries appear in a manifest. Symlinks are not copied.
