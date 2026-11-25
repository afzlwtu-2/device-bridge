# Folder sync and project handoff

Folder sync is managed in the Flutter file manager. Open **Files** from Home. The toolbar opens **Synced folders**, and each supported pane offers **Sync this folder** in its folder actions menu. There is no separate Sync navigation tab and no required Termux or user-run tool command. DeviceBridge packages an independently supervised Syncthing v2.1.7 engine for Android and Linux. Each session has its own approval, pinned peer identity, expected XXH64 manifest and byte budget. Public Syncthing discovery, relays, NAT mappings, STUN, upgrades and reporting remain disabled; existing personal Syncthing profiles are untouched.

## Using the GUI

1. In **Files**, choose a source device/storage and open the folder menu → **Sync folder…**, or use **Sync this folder** for the open directory. Choose the destination device and folder in the other pane or the folder picker.
2. Select **Full folder, hidden and Git files** or **All working files except .git**. **Register these folders** prepares both engines and their matching registrations. No engine IDs, ports, checksums or commands need to be entered by the user.
3. **Approve and sync now** hashes the source, verifies endpoint reachability, starts bounded jobs on both devices and checks the completed data. A selected Tailscale or routed connection also needs **Allow remote route** for this session. **Stop both endpoints** cancels the two sync jobs, including a local job that is still preparing. Successful sessions pause and close their listeners. The registration remains for the next intentional session.
4. Open **Files → Synced folders** to manage existing pairs, change their mode, run again, stop or remove them. Registered directories carry a sync badge, including while paused and after reopening Files.

Phone storage and app Downloads use the native Android app UID with normal storage permissions. Root, Shizuku, Termux and a VPN are not prerequisites. Use Android’s SAF folder grant for shared storage and SD cards. Browse and sync Termux Home through the paired companion. The Linux app hosts the same Flutter UI in a GTK window. Its Files panes expose Home, DeviceBridge Downloads and Filesystem under the signed-in user’s permissions.

## Termux Home

If the standalone Termux app is installed, open **Networks → Services → Termux tools** and choose **Set up Termux folder sync**. Connect to the arm64 Termux SSH server at its approved Wi-Fi address, confirm the SSH host key, and sign in with your existing SSH credentials. Select **Pair and grant Termux Home access** and **Allow this device to manage folder sync**. After setup, choose the paired **Termux** device and its **home** root in either Files pane.

The installer deploys the same arm64 DeviceBridge executables and bundled Syncthing engine under the Termux app user. Its state and keys live in a private Termux directory outside exported Home. The agent binds the selected Wi-Fi address. Syncthing starts for approved sessions and pauses after verification. If Android ends Termux or its Wi-Fi address changes, run setup again to start the companion on the approved address.

## The phone can coordinate two other machines

Source and destination are independent of the controller. A phone can select two paired laptops, VMs or servers and issue metadata-only setup, approval, start, status and stop requests. The source and destination transfer directly through their own pinned Syncthing connections. The controller does not download or forward their files.

The app tries a common private LAN first, then explicitly approved Tailscale or routed interfaces. A TLS handshake pinned to the other DeviceBridge endpoint checks reachability from an endpoint itself. No reachable approved route produces a clear error; there is no implicit phone relay. Using Tailscale/routed bulk connections requires both endpoint owners' remote-sync permission and the session's remote-route approval; overlay relays or internet traffic may incur data usage.

On an endpoint, **Files → Synced folders → Allow other devices to manage sync here** grants a paired controller permission to configure and update selected folders inside its still-live filesystem grants. Remote routes have a separate switch. Revocation or grant expiry stops an active job. For a headless machine, the Flutter **Setup via SSH** dialog can install/update DeviceBridge and its engine and grant these permissions explicitly. No user command entry is needed.

Android native-engine streams use an endpoint-local socket adapter to preserve the app's approved Network binding. This adapter is part of a transferring endpoint, not a third-device relay. It retains the engine's end-to-end TLS and rejects incoming sockets from outside the selected peer address. Network loss cancels or fails the scoped session rather than silently switching bulk bytes to mobile data. App-private tsnet/WireGuard nodes without a native OS interface need an additional engine adapter for local-phone overlay sync; they are not advertised as ordinary routed interfaces. Two remote machines with native Tailscale/WireGuard interfaces can exchange data without involving the phone in the data path.

## Modes, verification and local changes

| Mode | Data | Destination behavior |
| --- | --- | --- |
| Full folder | Hidden files, `.git`, tracked and uncommitted files; explicit opt-in includes secrets/caches. Syncthing control files are excluded. | Direct selected folder. A new destination must be empty or byte-identical. Later runs require the previous verified baseline; unrelated local changes block. Syncthing simple versioning retains replaced copies in `.stversions`. |
| All working files except `.git` | Verified private projection of working files at all depths, including hidden and uncommitted data. Git metadata and engine/recovery control paths are excluded. | Imports into the selected destination, preserving its Git metadata and unrelated local files. Changed baseline files have recovery copies in `.devicebridge-sync-recovery-*`; concurrent local edits block import. |
| Legacy untracked/ignored project mode | Explicitly approved persistent untracked/ignored paths; tracked, Git, secret, generated and nested-repository content stay excluded. | Existing signed single-writer project workflow. See the developer reference below. |

Working mode does not require Git to be installed or a clean repository. It does not silently delete destination-local files. Folder directory leases and scoped operations prevent a renamed/replaced root from redirecting a session outside the grant. Content is verified with XXH64 on the receiving endpoint after the engine finishes; authentication cryptography and Syncthing's internal block protocol retain their own algorithms. Jobs expire after the approved duration. Closing Folder sync stops its status checks. Reopen the pair to inspect the bounded jobs again.

## Full pull remains a separate native copy

From a registered pair's menu, choose **Full pull from [device] to this device**. The destination is explicitly this device, not the other member of the sync pair. This copies the actual remote folder, independent of its filter, with hidden and uncommitted files and `.git` included by default. The checkbox can omit the root `.git`; nested Git metadata requires explicit exclusions. A verified new destination under Downloads is published without overwriting an existing path. Sync registrations and revisions are unchanged.

Ordinary transfers and Full pull use DeviceBridge's TLS 1.3 mutually authenticated TCP stream, streaming tar, resumable staging and target XXH64 verification. They require neither Syncthing nor rsync. **Full pull…** in the synced-folders manager also works without any registration.

## Why rsync is optional

Syncthing already reuses matching blocks for registered-folder updates. Rsync is useful for repeated mirroring over an SSH-accessible filesystem, but an additional provider would still need Android packaging, filesystem adapters, permissions, route consent, verification and conflict handling. It would not remove those requirements. No comparative speed or battery result has been measured; rsync is not integrated or required. [Syncthing synchronization](https://docs.syncthing.net/users/syncing.html), [rsync manual](https://download.samba.org/pub/rsync/rsync.1)

## Developer reference: legacy signed Git project workflow

The following command reference documents the existing low-level project engine and its tests. Ordinary GUI folder sync above does not require these commands.

### Git-managed projects

Prepare and register the pair as above. Bind each registration to the other device's **DeviceBridge** identity using `project bind GROUP PAIRED_DEVICEBRIDGE_ID`. The project workflow can then use the advanced controls in **Files → Synced folders** after setup or the following CLI operations. Prepend `bridge-cli --state STATE` to each CLI operation.

| Operation | Result |
| --- | --- |
| `project preflight WORKTREE` | Checks a clean tracked worktree, a checked-out branch and matching HEAD and locally known upstream. |
| `project prepare GROUP WORKTREE [--snapshot] APPROVED_PATH...` | Builds and signs a projection from explicitly selected persistent paths. Include `--snapshot` to keep the previous projection as a recoverable copy. |
| `project export GROUP` then `project follow -` on the peer | Shares and verifies the signed revision bundle on the read-only member. |
| `--interface INTERFACE --lan-cidr LOCAL_ADDRESS/CIDR --approve-sync project run GROUP WORKTREE LOCAL_IP:PORT PEER_IP:PORT` | Uses the signed manifest and runs a direct session after both devices independently verify the same Git branch and HEAD. |
| `project import GROUP WORKTREE APPROVED_PATH...` | Imports verified approved files. Identical files are a no-op. Different existing files surface a conflict and keep the staged version available. |

Git supplies tracked, ignored and untracked inventories. DeviceBridge stages approved persistent untracked or ignored files. It excludes tracked paths, nested repositories, submodules, common secrets, temporary files and caches. Review each approved path to classify project-specific secrets and files that can be regenerated. Fetch or reconcile upstream changes through Git before Sync if needed.

### Writer handoff and recovery

1. After the target has the verified current projection, the writer runs `--interface INTERFACE --lan-cidr LOCAL_ADDRESS/CIDR project offer GROUP WORKTREE`. The writer authenticates the live DeviceBridge peer, signs the offer and freezes its own write operations before emitting the bundle.
2. The target runs `--interface INTERFACE --lan-cidr LOCAL_ADDRESS/CIDR project accept WORKTREE -` with that bundle as input. It checks its Git state, projection, signed chain and the reachable paired writer. Acceptance records the new epoch and emits a signed receipt.
3. The former writer runs `project finalize -` with the receipt. The old device is read-only and the new one can prepare a later revision. Use `project status GROUP` or the registered group's **Project ownership** menu to see the local state.
4. If the reply is lost after acceptance, repeat the target's accept command with the original offer to recover the same receipt. If the target declines, it runs `project reject -` with the offer and sends the signed rejection back for `project cancel -`. A canceled offer stays rejected. This recovery also works after the 15-minute acceptance window expires.

DeviceBridge enforces writer status in its project workflow. External programs can still change files in the working tree. Import checks local contents and preserves different existing files for reconciliation. Signed revision history records authority while snapshots preserve copies of data.
