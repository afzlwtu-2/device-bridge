# Networks and device connections refactor

Design pass: 2026-11-25. Implementation is pending. This records the user's
Networks request and subsequent clarification that Agent SSH, tsnet SSH and
Termux OpenSSH on LAN port 8022 must be independently toggleable. The laptop
repository remains authoritative. Later user instructions override v4 where
they differ.

## 1. Product model

Keep three user-facing layers, with a shared capability and route evaluator:

| Layer | Choices | Responsibility |
| --- | --- | --- |
| Connections | Agent, SSH | Authenticated application service on a device |
| Transports | Direct TCP, Tailscale, WireGuard, ADB tunnel | Reach a service endpoint |
| Links | Wi-Fi, Ethernet, hotspot, Wi-Fi Direct, USB, mobile data, future Bluetooth | Local physical connectivity and peer setup roles |

Files, terminal and sharing are device actions, not additional connection
types. Direct TCP does not require an agent: ordinary OpenSSH also uses direct
TCP. TLS 1.3 mTLS belongs to the Agent connection; ordinary SSH uses its own
authentication and encryption. Keep existing internal transport IDs compatible
while separating these responsibilities.

A route describes both devices' endpoints and observed underlays. Mobile data
is an uplink, not a promise that two devices are directly on the same network.
The two endpoints need not use the same link type: a phone on cellular can reach
a laptop on Ethernet through an approved overlay. Multiple links can coexist.

Do not describe these product categories as exact OSI layers in the UI.

## 2. SSH: one device action, three independently controlled backends

| SSH backend | Authentication and endpoint | Incoming control |
| --- | --- | --- |
| Via DeviceBridge agent | Existing paired mTLS Agent stream upgraded to SSH; no separate OpenSSH daemon or port 8022 required | Enable agent SSH |
| Tailscale SSH | Existing app-private tsnet SSH listener, currently port 22; tailnet authorization applies | Enable Tailscale SSH |
| Termux OpenSSH | Key-only LAN/direct TCP listener on port 8022 under the integrated Termux environment | Enable Termux OpenSSH |

Agent SSH can itself run over an Agent connection carried by Direct TCP,
Tailscale, WireGuard or an appropriate ADB tunnel. Agent SSH over Tailscale is
different from the independent tsnet SSH listener. Do not render duplicate SSH
connections simply because several backends exist.

Global Networks → Connections → SSH contains the three incoming switches and
each backend's actual Off / Starting / Listening / Error state, endpoint scope
and session count. Keep switches independent of Agent file service, tailnet
login and the local terminal. Disabling Tailscale SSH must not log out tsnet;
disabling Agent SSH must leave Agent files/sharing usable. Stopping the Agent
service necessarily makes its SSH backend unavailable without changing the
saved SSH preference.

Disabling an incoming backend rejects new connections and closes sessions owned
by that backend; identify affected sessions before applying the operation.
Do not leave a switch Off while its listener or sessions remain active.
Rollback/reconcile the displayed state if the platform cannot apply a change.

These switches control incoming access, not the SSH client. A per-peer SSH
method setting separately provides Automatic and explicit backend selection,
plus allowed methods. Automatic respects an explicitly saved method first;
otherwise prefer permitted Agent SSH, then other verified methods ranked by
actual path cost and directness. Never switch authentication identity silently
after a host-key or certificate mismatch. A failed interactive session is shown
as disconnected; do not replay terminal input or commands on a replacement.

The primary **SSH** action opens the terminal using the selected usable method.
Show its method and current path in the terminal header. When setup or login is
required, take the user to that specific prerequisite. Incoming services run as
their configured account/app UID; connecting does not imply Root.

On Linux, use the corresponding built-in Agent, existing Tailscale and system
OpenSSH capabilities. Do not present Termux-specific controls or claim ownership
of an unrelated system sshd. Apply only explicitly scoped service configuration.

## 3. Devices and adding devices

Show two groups:

- **DeviceBridge devices**: paired or pending Agent identities, including those
  that also have ordinary SSH endpoints.
- **SSH devices**: saved, host-key-verified SSH hosts without a paired Agent.

Keep unpaired discoveries and pending approvals visually separate from trusted
devices. No duplicate device card merely because a device supports both SSH and
Agent. Never merge records by shared IP, hostname or guessed hardware model.
Link an SSH record to a verified Agent identity only through explicit verified
association; preserve both trust identities and allow undo.

Devices has **Pair device** and **Add SSH device**, with refresh/discovery as a
secondary action. Pair device combines nearby Agent selection, scan/paste an
invitation, and show/copy this device's invitation. Remove the standalone
Create invitation button. Do not expose invitation tokens through discovery.

Add SSH device verifies a host key, chooses an account and authentication
method, tests SSH, and saves a persistent host record. Agent installation is
optional and appears inside that SSH device's details as **Install DeviceBridge
agent**. Do not reuse the existing installation wizard as the mandatory add
flow. An SSH device can offer Terminal without SFTP support.

Remove the top-level **Guest files** and **Setup via SSH** buttons. Guest files
currently means a temporary SSH/SFTP browse session. Retain its scoped session
and path protections internally and expose **Files (SFTP)** from the SSH device
when its SFTP subsystem is supported. SSH-only hosts do not gain Agent share,
sync or remote-management features by being saved.

Device details contains applicable actions followed by Connections. Agent is
shown as a connection only for a verified paired Agent or a verified installed
Agent awaiting pairing. An SSH-only device instead offers contextual Install
agent. An offline previously paired Agent remains visible with stale/last-known
state; a missing probe response is not proof of uninstall.

## 4. Screen responsibilities

| Screen | Owns | Does not start here |
| --- | --- | --- |
| Global Networks → Connections | Local Agent service; SSH backend switches/status | Peer-specific SSH login or link negotiation |
| Global Networks → Transports | Local tailnet login/status; WireGuard configuration; transport availability policy | Selecting or pretending to configure the remote device |
| Global Networks → Links | Current local interfaces, radio state, supported link availability policies, Android settings shortcuts | Hotspot/Wi-Fi Direct hosting or joining for an unspecified peer |
| Network settings | Allow use of each supported provider; automation preferences | Implicit radio changes, installs or account logins |
| Device → Connections | Agent/SSH state and methods; active route; available transports; peer-specific links and setup | Global permission grants disguised as peer settings |
| Device → Connections → Link setup | Host/join roles, both devices' prerequisites, manual steps, switch/restore | Silent change to unrelated networking |

Use explicit labels such as **Allow hotspot connections** for policy switches.
They are not OS radio power switches. Turning a policy off prevents future use
and requires resolving owned active sessions before completion; it must not
silently switch traffic to another costly route. Root and Shizuku permission
grants remain in Global Settings, with contextual links from network setup.

## 5. Visibility and state rules

Represent support, preference, installation, configuration, authorization,
physical presence, reachability, freshness and active use independently.
Unknown support is different from unsupported. Capture reason codes and the
next possible action, instead of embedding decisions in individual widgets.

| Evidence | Peer Connections behavior |
| --- | --- |
| Verified unsupported hardware/platform/provider | Hide the option |
| Supported and enabled, prerequisites missing but actionable | Show Needs setup with the precise prerequisite |
| Explicitly disabled by local/per-peer policy | Omit from normal choices; expose under Manage availability |
| Remote support unknown | Offer Check support/manual setup where meaningful; never claim ready |
| Configured but unreachable | Show unavailable with last checked time and Retry |
| Authenticated service reachable | Show Ready; only mark Active when selected/in use |
| Previously active route disappears | Retain its failed state so the loss is understandable |

Global settings may explain supported-but-disabled or temporarily absent
providers. Do not fill peer screens with unimplemented placeholder options.
Preserve access to stop/restore controls for owned active sessions even if a
policy, privilege grant or capability changes.

USB: hide an absent cable from normal peer Link choices. With cable present,
distinguish charge-only/data, debugging unavailable, unauthorized ADB, authorized
ADB and verified tunnel. A global USB help entry can explain how to connect.
USB Ethernet/tethering and USB ADB are separate capabilities.

Hotspot and Wi-Fi Direct: evaluate host and join roles on BOTH endpoints. Show
**This device hosts** and **Peer hosts** only when that role can work. Common
Wi-Fi uses Join/select existing network; Ethernet usually needs observation
and guidance rather than an artificial setup wizard.

Mobile data: show only on a device with a cellular capability or observed
cellular interface. Offer Android network settings when manual activation is
needed; do not imply a generic unrestricted app toggle. Enforce per-device
cellular/public/relay bulk approval separately from radio availability.

## 6. Transport compatibility

- Direct TCP works over a verified IP path: Wi-Fi, Ethernet, hotspot, Wi-Fi
  Direct or USB networking. Public/cellular direct reachability must be proved
  and allowed, not inferred from an IP address.
- Tailscale and WireGuard are not categorically hidden on hotspot or Wi-Fi
  Direct. Prefer Direct TCP for a nearby peer. Keep configured usable overlays
  as alternatives, reporting actual underlay, endpoint reachability and costs.
  Missing internet may block fresh tailnet setup without proving every existing
  overlay path impossible. A local-only hotspot itself has no internet access.
- WireGuard setup requires compatible endpoints, keys/routes and a reachable
  peer endpoint. It does not automatically arrange NAT traversal. Do not show
  Ready because a configuration merely imported successfully.
- ADB is an endpoint-specific port tunnel, not a full IP network. Laptop →
  Android commonly needs `adb forward`; Android → laptop needs `adb reverse`.
  Reuse authorized ADB infrastructure with explicit serials and owned mappings.
  Either Agent or ordinary SSH can use a mapping to its actual listener.
- Preserve the existing SSH-tunnel transport during migration. It is a tunnel
  implemented over an SSH service/control route, not another physical link or
  an extra connection type. Do not accidentally delete working saved routes.

An app-private tsnet or WireGuard netstack is not automatically reachable by
the system SSH client. Shared dialers must explicitly support each connection
backend; test the actual SSH or Agent authentication over that dialer.

## 7. Coordinated setup and switching

Use a bounded, idempotent operation with an operation ID and states:

`preflight → prepare both → await user steps → establish candidate → verify
identity/service → commit route → retire old owned path`.

On cancel, timeout, crash, permission loss or verification failure, restore only
the DeviceBridge-owned changes where still safe and report unresolved steps.
Keep an operation journal without credentials so startup can reconcile partial
setup. Both sides receive rollback deadlines before a disruptive change.

Use an authenticated existing Agent or SSH control path when available. For an
SSH-only host, probe bounded known commands and platform support through its
verified account; do not assume an Agent negotiation API exists. Without a
working control path, show local/remote manual instructions or QR exchange.

Preflight radio concurrency, host/join permissions, active transfers, SSH
sessions and internet loss. Prepare the peer first when losing the current
path is unavoidable. Keep the old path until verification when hardware allows;
otherwise use the prearranged deadlines and local restoration. Arm and verify
the laptop's existing network restore guard before an uplink-disrupting test.

For ADB setup, the desktop can run the scoped command directly; a phone can
request it from the laptop Agent or verified SSH control path. If neither is
available, show the exact manual command. Detecting a local port alone never
establishes that it reaches the intended authenticated peer.

## 8. Android tiers

Use live, operation-specific capability probes, not a single "has Root" flag.
Standard uses public APIs, Android consent dialogs and manual settings as
needed. Shizuku automates only operations allowed by its live shell grant and
enabled feature settings. Root is separately enabled and verified with live
`su -c id -u`; it does not authorize protected system changes.

The three SSH servers and app-private direct TCP/overlay data paths should not
require Root or Shizuku. Those tiers primarily improve supported network setup
and lifecycle operations; do not claim faster transfer or lower battery use
solely from a privilege label. Preserve a usable Standard path. Explain actual
differences, equal-speed paths, permissions and hardware/OEM limits in the
built-in Wiki whenever implementation changes these behaviors.

## 9. Bluetooth extension

Do not assume ordinary Bluetooth or BLE provides IP connectivity. Bluetooth
Classic RFCOMM offers a byte stream suitable for a future authenticated stream
provider. BLE GATT is a separate messaging mechanism; use it first for bounded
discovery/control/negotiation rather than advertising bulk TCP transfers.

A future RFCOMM provider needs platform adapters, framing/backpressure,
cancellation, authenticated device identity, reconnect policy and real tests.
Agent protocols and SSH could use an authenticated stream adapter; existing
TCP-only implementations cannot simply be relabeled Bluetooth. Bluetooth PAN
can use Direct TCP only when the OS actually exposes a usable IP interface.
Hide unimplemented Bluetooth choices from usable route lists.

Sources: [Android RFCOMM connections](https://developer.android.com/develop/connectivity/bluetooth/connect-bluetooth-devices),
[BLE GATT](https://developer.android.com/develop/connectivity/bluetooth/ble/connect-gatt-server),
[local-only hotspot](https://developer.android.com/develop/connectivity/wifi/localonlyhotspot),
[ADB architecture](https://developer.android.com/tools/adb),
[ADB forward/reverse commands](https://android.googlesource.com/platform/system/core/+/d2b15dd6749eefaa76a12e0466693e4336e9b8a7/adb/client/commandline.cpp).

## 10. Implementation sequence and gates

1. **Shared model and SSH switches.** Versioned connection/backend/provider
   descriptors, capability evidence and policy evaluation. Add persisted Agent
   SSH toggle and propagate it into listeners, advertisement and active-session
   lifecycle. Preserve existing tsnet/OpenSSH switches and defaults; do not
   enable a previously disabled listener during migration. Test independent
   toggles, runtime apply failures, restart persistence and files remaining
   functional when Agent SSH is off.
2. **Persistent SSH hosts and Devices.** Add a separate versioned SSH host
   record with stable local ID, host-key identity, account, endpoints,
   credential reference and provider preferences. Keep passwords/passphrases
   ephemeral; never copy expired guest grants into persistent trust. Verify
   terminal independently of SFTP. Implement both groups, unified pairing and
   contextual installation. Test identity mismatch, removal, restart and
   explicit verified association with an Agent.
3. **Global/peer UI split.** Render the shared evaluator in Networks and device
   details; move peer setup out of the global page. Add the primary SSH action
   and backend chooser. Test absent/unsupported/unknown/offline states and
   portrait layouts on both live Waydroid profiles. Update Wiki alongside UI.
4. **Setup coordinator and transport dialers.** Extract existing hotspot/P2P
   and ADB flows into recoverable operations. Provide connection-independent
   dialers and verify Agent and ordinary SSH over each implemented provider.
   Test cancellation, stale capabilities, wrong serial/peer, occupied ports,
   lost control path and crash recovery. Restrict changes to owned mappings,
   networks and scoped service operations.
5. **Hardware acceptance, then Bluetooth spike.** Run the broader suite once
   at the coherent milestone. Validate phone↔laptop and phone↔phone role
   combinations, Standard/Shizuku/Root, real USB forward/reverse and mobile-data
   policy separately from Waydroid. Only then prototype RFCOMM/BLE; advertise
   each capability after evidence, not merely hardware detection.

Relevant current seams: `app/lib/features/connections_hub.dart`,
`network_card.dart`, `network_setup_settings.dart`, `remote_files.dart`,
`device_commands.dart`, `guest_files.dart`, `guest_terminal.dart`,
`app/lib/main.dart`, `app/lib/core/bridge.dart`, Android `DeviceSettings.kt`,
`MainActivity.kt`, `LanCoordinator.kt`, `TailnetCoordinator.kt`,
`WireguardCoordinator.kt`, Go `internal/transport`, `internal/storage`,
`internal/bootstrap`, `internal/server/ssh.go`, `internal/sshserver`,
`cmd/bridge-agent/main.go` and `protocol/types.go`.

Existing evidence: built-in mTLS Agent SSH and its contextual terminal action
already exist (`agent-ssh-v1`). The CLI can disable Agent SSH, but Android does
not currently expose a matching persisted switch. Existing guest-open requires
SFTP and creates an expiring grant, so it cannot be the persistent SSH-only
host model. Existing capability booleans need freshness/unknown semantics.
These observations are source review, not new hardware acceptance.
