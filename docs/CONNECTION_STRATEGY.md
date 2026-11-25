# Device connection workflow

## Setup and verification

1. Discover finds SSH targets on ordinary Wi-Fi/LAN and on the signed-in tailnet. SSH Setup verifies the host key, installs the agent and pairs with its DeviceBridge identity. The SSH route is an initial route candidate.
2. Device Detail checks ordinary LAN, configured Tailscale and configured WireGuard in parallel. It uses saved addresses, on-link discovery and endpoints advertised by the authenticated paired agent. A route is eligible only after the target answers over that transport with the pinned DeviceBridge key.
3. Eligibility for normal connections is automatic for paired devices. A tunnel login, a matching hostname or an IP address alone never adds a row. Selecting a route leaves file grants as they were. A per-device setting controls bulk traffic over internet, relay and cellular routes.

| Route | Evidence to show it | Selection |
| --- | --- | --- |
| Wi-Fi / LAN | Authenticated peer response on an ordinary on-link subnet | First default and first fallback |
| Tailscale | Local node running and authenticated response from the paired agent through the tailnet | Second fallback |
| WireGuard | Local backend usable and authenticated response from the same agent through its configured tunnel | Third fallback |
| ADB over USB | Android device physically attached and the Linux endpoint reports wired ADB | Start or select explicitly |
| Wi-Fi Direct | One device can host and the other can join | Start or select explicitly |
| Wi-Fi Hotspot | One device can provide an access point and the other can join | Start or select explicitly |
| SSH loopback tunnel | An explicitly configured tunnel reaches the paired identity | Select explicitly |

## Selection and recovery

- A selection made by the user saves the preferred route independently of the active route. Keep it while it authenticates. If it drops, use verified ordinary LAN, then Tailscale, then WireGuard. Restore a verified preferred route when it returns. A dormant USB, hotspot or Wi-Fi Direct connection needs an explicit Start even if it was preferred earlier.
- Failover never runs ADB, creates a Wi-Fi Direct group, starts a hotspot, changes system VPN settings or joins a manual link. It uses only existing eligible connections. An existing manual link can stay active once explicitly selected.
- USB discovery lists wired transports and existing forwards. Starting a USB connection can create a forward and must authenticate the selected paired peer through it. A failed attempt removes only the forward it created.
- Foreground device and connectivity events refresh the route list. Local Wi-Fi changes update LAN rows without disturbing a healthy user preference. A pending Tailscale startup gets bounded retries. Signs of logout or unsupported/unreachable peers remove the route from the list.
- Automatically resumed bulk transfers use the same LAN → Tailscale → WireGuard ordering. Internet, relay and cellular bulk routes require the paired device's explicit approval. The transfer engine still verifies the same peer and manifest before it resumes.
- An interrupted remote download keeps its staging and progress. The CLI retries the selected route and eligible alternatives with bounded backoff for up to two minutes without progress. Android supplies the currently approved Wi-Fi binding when it changes. A recovered connection authenticates the original peer and continues by file offset using the original manifest and final XXH64 checks. Interrupted tar downloads continue via file streams. The same destination can be resumed manually after the wait expires.
- Android remote downloads require separate approval for a metered Tailscale uplink, including cellular. The download pauses before starting file data on that uplink and offers **Use data for this download** or **Choose another connection**. The latter offers verified links and opens Wi-Fi Direct or hotspot setup when needed. The temporary approval expires when the download operation ends. Ordinary Wi-Fi recovery can continue automatically. Tailscale stream setup checks that the running app node is bound to the network Android reported.

## Screens

- Networks, Devices, and Files all open the same paired-device Connections view. Services shows the active transport, endpoint, Ping, and Speed test.
- Transports shows the verified paths and their Direct or DERP status where known. Its per-device settings control the preferred route and remote transfer permission. USB ADB setup is available for compatible wired pairs.
- A configured Tailscale route shows its reconnection status and a **Retry** action while peer verification is pending or unavailable. After a manual direct link stops, the row returns while the app checks reachability.
- Links holds Wi-Fi Direct and Hotspot setup, channel selection, and wireless capabilities. For interrupted downloads, use **Use selected connection** after verifying the route.
- Discover shows setup candidates from LAN and the tailnet. The global Connections screen still controls local transport login and configuration.

### Networks hub

| View | Operation | Prerequisite and result |
| --- | --- | --- |
| Services (L7) | Choose device | Open the existing paired-device Connections tab. It authenticates the peer over each eligible route and owns selection, preference, Ping, Speed test and bulk consent. |
| Services (L7) | Manage the listener | On Android, restart the local DeviceBridge agent, configure its Direct TLS listener link, or manage Tailscale SSH and its Tailscale dependency. Linux listener configuration belongs to the system service. OpenSSH keeps its own endpoint. |
| Transports (L3/L4) | Change Direct TLS link | Offer live local IP endpoints from the platform binding inventory. Revalidate the interface, CIDR and available network handle immediately before saving. Report a stale choice and leave the existing selection in place. |
| Transports (L3/L4) | Manage Tailscale and WireGuard | Tailscale follows the default internet link when available on Android and system routing on Linux. Android WireGuard shares the LAN setting and can retain ordinary Wi-Fi during a direct link. Linux resolves the configured tunnel endpoint using system routing. |
| Transports (L3/L4) | Set up USB ADB reverse | Require wired ADB and a detected serial before automatic activation on a paired Linux host. Report a detected reverse listener separately from the paired agent probe. On Linux, open the paired Android device to run the peer-specific USB operation. |
| Links (L1/L2) | Set up a radio or use an existing link | Start only a supported hotspot or Wi-Fi Direct group. Stop the current managed direct link before starting another. Once an interface has a local IP, use it for Direct TLS from its link card or the transport picker. A charging cable alone offers USB setup guidance. |

Link status, local listener status and authenticated peer reachability are distinct evidence. Mobile data can carry an eligible overlay and still requires existing transfer consent. A USB IP network and a USB ADB reverse tunnel have independent prerequisites. Starting a local hotspot or Wi-Fi Direct group leaves the saved Direct TLS link selection in place. Android controls whether the existing Wi-Fi association stays connected during setup.

On Android, the **Network settings** gear shows the preferred tier for hosting and joining. Global Settings controls permission grants. The gear changes the same feature switches as the Root and Shizuku submenus. Root direct-link setup covers both operations. Shizuku has independent hosting and joining switches. For each operation, choose verified and enabled Root first, granted and enabled Shizuku second, and Standard when neither helper applies. Standard may show Android consent prompts. An active direct link must be stopped or disconnected before changing the setup mode from this panel, so its cleanup can use the same settings. Settings changes do not start a link.

For acceptance, check simultaneous Wi-Fi and cellular, a local-only group, a link disappearing while its picker is open, a cable with USB debugging off, authorized ADB without a reverse listener, and a detected listener with an unreachable peer. Compare performance using the paired device’s speed test. Record both link and verified peer route when testing an alternative. [Android ADB](https://developer.android.com/tools/adb) · [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)

## Implementation and acceptance

1. Store preference, active link and bulk approval independently. Filter automatic CLI recovery, and retain compatibility with existing pair records.
2. Advertise transport hints from paired agents and check each candidate over its actual transport. Reject unrelated tailnet devices and unconfigured overlays.
3. Update Device Detail, connection preferences, Discover and the Wiki. Verify simultaneous route availability, failover ordering, preference restoration and manual capability gating.
4. Run targeted Linux and Flutter checks, then verify the POCO and laptop with Wi-Fi and LTE. Distinguish simulated cloud, Android-to-Android, USB and WireGuard capability cases from physical acceptance.
5. After the connection gate, resume the first incomplete v4 milestone, M3 Quick Share. Complete one verified slice at a time, starting with authenticated one-time text exchange before clipboard integration and file sending.

## Dynamic SSH alias on Linux

`scripts/devicebridge_ssh.py` opens the paired device by name or ID. It resolves the current authenticated DeviceBridge address before each session. Supply the SSH account and the confirmed host-key fingerprint. The helper verifies the server's key before invoking OpenSSH and removes its private temporary known-hosts file when the session ends.

On LAN pass the approved local interface and CIDR. The helper also supports the laptop's existing system Tailscale. A paired route still needs its own SSH service and SSH account. The Linux bundle includes the helper under `tools/`.

## Roaming and per-device preferences

- Treat a changed local network handle, subnet, or interface as a new LAN probe. Verify the saved peer identity over mTLS before storing a route on the new LAN. An IP address or matching Wi-Fi name is only a discovery hint.
- In automatic mode prefer verified direct LAN, then an available Tailscale route, then WireGuard. Recheck LAN while a paired device is open on an overlay so a peer that returns to the same LAN can be picked up even if the local network stayed the same. Honor explicit transport preferences and active manually started links. The app does not join Wi-Fi or start manual links on its own.
- Store the preferred transport and preferred local link type separately per paired device. A Wi-Fi link preference follows the interface type across networks. It does not save an SSID or credentials. Tailscale follows system routing. Transfer consent remains separate from route discovery and authenticated control.
- Add agent-free endpoints through Devices → Add SSH device. Direct SSH uses the supplied LAN address and verified host key. Files requires SFTP. Pairing, Quick Share, peer-managed links and DeviceBridge sync require the agent.
