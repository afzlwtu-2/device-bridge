import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

/// Built-in architecture, permissions, battery/efficiency, and runtime binary guide.
class WikiScreen extends StatefulWidget {
  const WikiScreen({super.key, required this.core, this.initialTopic = 'all'});

  final CoreBridge core;
  final String initialTopic;

  @override
  State<WikiScreen> createState() => _WikiScreenState();
}

class _WikiScreenState extends State<WikiScreen> {
  late String topic = widget.initialTopic;
  String query = '';
  Map<String, dynamic> settings = {};
  Map<String, dynamic> caps = {};
  Map<String, dynamic> goStatus = {};
  bool loading = true;

  static const _topics = <(String id, String label)>[
    ('all', 'All'),
    ('modes', 'Privilege Modes'),
    ('connections', 'Connections & Battery'),
    ('files', 'File Access'),
    ('binaries', 'Binaries & Termux'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await widget.core.appSettings();
      Map<String, dynamic> c = {};
      try {
        c = await widget.core.platformCapabilities();
      } catch (_) {}
      Map<String, dynamic> g = {};
      if (s['go_runtime'] is Map) {
        g = Map<String, dynamic>.from(s['go_runtime'] as Map);
      } else {
        try {
          g = await widget.core.goBinariesStatus();
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          settings = s;
          caps = c;
          goStatus = g;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  bool _showSection(String sectionId, String searchableText) {
    if (topic != 'all' && topic != sectionId) {
      return false;
    }
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return true;
    }
    return searchableText.toLowerCase().contains(q);
  }

  Widget _badge(BuildContext context, String label, {bool highlight = false}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: highlight ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: highlight
              ? cs.primary.withValues(alpha: 0.45)
              : cs.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: highlight ? cs.onPrimaryContainer : cs.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _sectionHeader(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: cs.onPrimaryContainer, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoCard(
    BuildContext context, {
    required String title,
    required List<(String label, bool highlight)> badges,
    required String summary,
    required List<(String heading, String detail)> rows,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            if (badges.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final b in badges)
                    _badge(context, b.$1, highlight: b.$2),
                ],
              ),
            ],
            const SizedBox(height: 10),
            Text(summary),
            const SizedBox(height: 10),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: RichText(
                  text: TextSpan(
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: cs.onSurface, height: 1.38),
                    children: [
                      TextSpan(
                        text: '${r.$1}: ',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(text: r.$2),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final android = settings['android'] == true;
    final execMode = '${settings['execution_mode'] ?? 'standard'}';
    final goVer = '${goStatus['version'] ?? '1.4.0'}';
    final modeText = switch (execMode) {
      'root' => 'Root (UID 0 verified)',
      'shizuku' => 'Shizuku (ADB shell)',
      _ => android ? 'Standard (no Root / Shizuku)' : 'Linux desktop',
    };

    return Scaffold(
      appBar: AppBar(title: const Text('DeviceBridge Wiki')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Container(
                  padding: const EdgeInsets.all(20),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: LinearGradient(
                      colors: [
                        cs.primaryContainer,
                        cs.tertiaryContainer.withValues(alpha: 0.65),
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.menu_book_rounded,
                            size: 28,
                            color: cs.onPrimaryContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Architecture, Permissions & Efficiency Guide',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(
                                    color: cs.onPrimaryContainer,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Active on this device: $modeText · Go core v$goVer'
                        '${caps['all_files_access'] == true ? ' · All Files granted' : ''}'
                        '${caps['termux_installed'] == true ? ' · Termux detected' : ''}',
                        style: TextStyle(color: cs.onPrimaryContainer),
                      ),
                    ],
                  ),
                ),
                if (loading) const LinearProgressIndicator(),
                TextField(
                  onChanged: (v) => setState(() => query = v),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search modes, battery, Wi-Fi Direct, SAF, Termux, targetSdk…',
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final t in _topics)
                      ChoiceChip(
                        label: Text(t.$2),
                        selected: topic == t.$1,
                        onSelected: (_) => setState(() => topic = t.$1),
                      ),
                  ],
                ),
                const SizedBox(height: 8),

                if (_showSection(
                  'modes',
                  'privilege modes root shizuku standard su uid 2000 nearby_wifi_devices location permissions verify safety',
                )) ...[
                  _sectionHeader(
                    context,
                    Icons.admin_panel_settings_outlined,
                    'Privilege Modes & Required Permissions',
                    'How DeviceBridge adapts to Root, Shizuku, or unprivileged Android',
                  ),
                  _infoCard(
                    context,
                    title: '1. Root mode (UID 0)',
                    badges: const [
                      ('Highest Link Control', true),
                      ('Live su -c id -u Check', false),
                    ],
                    summary: 'When enabled in Settings, DeviceBridge verifies live root on every Settings/capability read and automatically disables the toggle if root is removed.',
                    rows: const [
                      (
                        'Permissions',
                        'Superuser grant (Magisk / KernelSU / APatch). Android Nearby/Location prompts are bypassed for shell link control.',
                      ),
                      (
                        'Connection strategy',
                        'Runs cmd wifi start-lohs (-b 5/-b 6 -w 80), cmd wifip2p create-group-with-config (5 GHz + P2P HAL reset recovery), cmd wifi connect-network, and ip -4 neigh lookups. Supports kernel WireGuard module on rooted/supported peers.',
                      ),
                      (
                        'File manager & Termux monitor strategy',
                        'Does NOT use root to browse files or touch /system, boot/AVB/verity, or SELinux. Keeps file serving inside owner-approved app/Downloads/SAF/Termux scopes. Termux top-bar monitor reads CPU (/proc/stat) and GPU sysfs (ged/gpufreqv2/kgsl) via one persistent su shell only while Root access is enabled, plus Binder MemoryInfo for RAM.',
                      ),
                      (
                        'Notification-free Termux sessions',
                        'Settings → Root features → Keep Termux running applies to new tabs. A compatible su starts a detached supervisor under the original DeviceBridge UID, groups and security context. Reopen Termux to attach to the same shell and recent output. Close a tab or turn the setting off to end its session. The supervisor requests no wake lock and starts only when you open a terminal.',
                      ),
                      (
                        'Package-adaptive Termux & sudo/tsu',
                        'sudo and tsu request Android superuser access and restore the app’s Termux environment for the requested command. sudo su opens a root shell with the same tools. Use pkg, apt and dpkg as the regular Termux user.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: '2. Shizuku mode (ADB Shell UID 2000)',
                    badges: const [
                      ('Recommended Non-Root', true),
                      ('No Root Required', false),
                    ],
                    summary: 'Runs privileged shell commands via Shizuku.newProcess without rooting the phone.',
                    rows: const [
                      (
                        'Permissions',
                        'Shizuku service running (via Wireless Debugging / USB ADB) + user permission grant inside Shizuku app.',
                      ),
                      (
                        'Connection strategy',
                        'Uses cmd wifi & cmd wifip2p for 5 GHz Hotspot / Wi-Fi Direct creation and automatic peer Wi-Fi join + forget-network cleanup.',
                      ),
                      (
                        'File manager & Termux monitor strategy',
                        'Unprivileged storage APIs for Internal storage and SAF. When Root is off, Termux top-bar CPU monitor falls back cleanly to Shizuku (/proc/stat), while GPU sysfs remains disabled if kernel permissions restrict UID 2000 to Root.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: '3. Standard mode (No Root, No Shizuku)',
                    badges: const [
                      ('Works Out of the Box', true),
                      ('Strict Android APIs', false),
                    ],
                    summary:
                        'Uses pure public Android APIs and never calls su.',
                    rows: const [
                      (
                        'Permissions',
                        'Runtime ACCESS_FINE_LOCATION and NEARBY_WIFI_DEVICES (Android 13+) for Hotspot / Wi-Fi Direct.',
                      ),
                      (
                        'Connection strategy',
                        'Uses WifiManager.startLocalOnlyHotspot, WifiP2pManager.createGroup (5 GHz preference + auto-band fallback), and Android 10+ WifiNetworkSpecifier for peer Wi-Fi joins. Android OS controls exact AP credentials & channel.',
                      ),
                      (
                        'File manager & Termux monitor strategy',
                        'Same scoped storage providers (Internal, MANAGE_EXTERNAL_STORAGE if granted, and persistable SAF trees). Termux top-bar monitor keeps RAM active via Binder MemoryInfo while disabling CPU & GPU monitors until Root or Shizuku is enabled.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'What Root adds over Shizuku & Standard (Efficiency, Battery & Extra Features)',
                    badges: const [
                      ('Shortest 5/6 GHz Airtime', true),
                      ('Instant ARP & HAL Recovery', false),
                    ],
                    summary: 'Root improves direct wireless link bring-up, channel selection, and kernel tunnel efficiency—while never bypassing file/system safety rules.',
                    rows: const [
                      (
                        'Channel & airtime battery savings',
                        'Forces 5 GHz (or 6 GHz) 80 MHz on the very first AP/P2P attempt (cmd wifi start-lohs -b 5 -w 80 / cmd wifip2p 5745 MHz) instead of retrying or falling back to crowded 2.4 GHz; shorter radio transmission time per GiB reduces battery heat and drain.',
                      ),
                      (
                        'Faster neighbor discovery (fewer radio wakeups)',
                        'Root ip -4 neigh reads AP/P2P peer IPs instantaneously when unprivileged netlink is restricted, cutting repeated 3–5s mDNS multicast wakeups.',
                      ),
                      (
                        'MediaTek / driver P2P HAL reset',
                        'Recovers busy p2p0 sockets automatically (reason 2 reset) when switching between Hotspot and Wi-Fi Direct without manual Wi-Fi toggles.',
                      ),
                      (
                        'Kernel WireGuard option',
                        'On rooted/supported peers, native kernel WireGuard avoids userspace wireguard-go packet-copy CPU cycles and battery draw.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'What Shizuku adds over Standard mode',
                    badges: const [
                      ('Zero-Prompt Automation', true),
                      ('No Superuser Required', false),
                    ],
                    summary: 'Bridges almost all of Root\'s network-automation convenience onto stock unrooted phones using ADB shell privileges (UID 2000).',
                    rows: const [
                      (
                        'Clean Wi-Fi join & forget',
                        'cmd wifi connect-network and forget-network join and tear down temporary Hotspot/Direct SSIDs silently, avoiding WifiNetworkSpecifier popups and sticky OS saved networks.',
                      ),
                      (
                        'No location/nearby runtime popups',
                        'Executes cmd wifi / cmd wifip2p directly without triggering foreground ACCESS_FINE_LOCATION / NEARBY_WIFI_DEVICES permission prompts.',
                      ),
                      (
                        'Battery edge over Standard Hotspot/Join',
                        'Exact band/width arguments (-b 5 -w 80) and deterministic teardown prevent lingering 2.4 GHz sessions.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'Same speed & battery without Root or Shizuku',
                    badges: const [
                      ('Equal Bulk Speed', true),
                      ('Zero Privilege Needed', false),
                    ],
                    summary: 'Once a link is connected or a storage permission is granted, unprivileged mode matches Root/Shizuku throughput and battery efficiency.',
                    rows: const [
                      (
                        'Bulk file manager (All Files Access / MANAGE_EXTERNAL_STORAGE)',
                        'Reads and writes /storage/emulated/0 directly via kernel syscalls + streaming tar + XXH64. Root gives zero file-transfer speed advantage over All Files Access or App-Private storage.',
                      ),
                      (
                        'Wired ADB over USB & existing Wi-Fi LAN',
                        'All three tiers use the same unprivileged TLS 1.3 and streaming transfer code. Link quality, storage and device load determine actual throughput and battery use.',
                      ),
                      (
                        'Userspace WireGuard & app-private Tailscale (tsnet)',
                        'Operates identically across all 3 tiers using app-owned UDP/netstack sockets with zero VpnService or Root dependency.',
                      ),
                      (
                        'Go binary hot-swap (targetSdk = 28)',
                        'Unpacked updates in filesDir/hotbin execute cleanly on unrooted Standard devices just like Root/Shizuku.',
                      ),
                    ],
                  ),
                ],

                if (_showSection(
                  'connections',
                  'connections battery efficient wired usb adb wifi lan direct hotspot 5ghz 6ghz wifi 6 channel 161 5805 80mhz 160mhz iw reg us regulatory wireguard tailscale derp ssh',
                )) ...[
                  _sectionHeader(
                    context,
                    Icons.bolt_outlined,
                    'Networks, Monitoring & Battery Efficiency',
                    'Agent uses mTLS; ordinary SSH uses SSH authentication. File verification uses XXH64.',
                  ),
                  _infoCard(
                    context,
                    title: 'Connections, transports and links',
                    badges: const [],
                    summary: 'Global Networks manages this device. A device’s Connections screen manages how the two devices communicate.',
                    rows: const [
                      (
                        'SSH backends',
                        'Agent SSH, Tailscale SSH and Termux LAN OpenSSH :8022 have independent incoming controls. Switching a server off does not disable the SSH client or other backends.',
                      ),
                      (
                        'Paired Agent SSH',
                        'Uses the paired mTLS identity automatically: no password, key picker or fingerprint confirmation. The receiving owner separately approves SSH access in that paired device’s Connections screen. File access alone does not grant a shell. Revoking approval closes Agent SSH sessions.',
                      ),
                      (
                        'SSH devices',
                        'Save an ordinary SSH host without installing an agent. Verify its host key through a trusted source. Passwords and key passphrases remain session-only. SFTP Files is optional and independent of terminal access. Check host & links probes active interfaces over the verified SSH account without assuming an Agent.',
                      ),
                      (
                        'Visibility',
                        'Unsupported providers and absent USB cables are omitted from normal peer choices. Unchecked peer capabilities appear as support unknown with a Check support action and last-checked age. Offline paired devices remain saved; failed discovery never proves an agent was uninstalled.',
                      ),
                      (
                        'Where setup belongs',
                        'Choose the peer before hosting or joining a hotspot or Wi-Fi Direct group. Global settings control availability and automation preferences; they do not silently switch radios.',
                      ),
                      (
                        'Standard',
                        'Public Android APIs, consent dialogs and manual network settings. Agent SSH, tsnet, OpenSSH and direct app traffic do not need Root or Shizuku.',
                      ),
                      (
                        'Shizuku',
                        'A live authorized shell grant can automate supported hosting and joining operations. It cannot bypass all Android restrictions or access arbitrary private app data. Lost grants fall back to Standard instructions.',
                      ),
                      (
                        'Root',
                        'Live verified, explicitly enabled Root can automate additional supported network setup and app lifecycle operations. It does not authorize protected system changes. Root is optional.',
                      ),
                      (
                        'Equal speed and battery',
                        'The same app-private TCP, mTLS, SSH and userspace overlay data paths have identical permissions and efficiency in Standard, Shizuku and Root. Privilege can reduce manual setup steps; it does not inherently make transfers faster or save power.',
                      ),
                      (
                        'Overlays on local links',
                        'Do not hide a usable overlay merely because a hotspot or Wi-Fi Direct exists. Prefer direct local TCP; show the real underlay, direct/relay status and costs. Cellular and relay bulk traffic still require per-device approval.',
                      ),
                      (
                        'Standard hotspot setup',
                        'When Android cannot preserve a control link or accept custom hotspot credentials, DeviceBridge shows the actual network name/password for the peer to join manually. It verifies the paired identity before committing. Root/Shizuku can automate only the operations their live grants permit.',
                      ),
                      (
                        'Timed restoration',
                        'New compatible peers coordinate with a two-minute lease. The receiving Agent owns its restore deadline independently of the network connection. The local Android controller or desktop watcher owns a second deadline. Interrupted operations remain recoverable. Android force-stop can defer local cleanup until the app runs again; it is not a guaranteed background execution mechanism.',
                      ),
                      (
                        'SSH device association',
                        'Explicitly associate an SSH account only with the same verified paired device. The device then appears once, while the SSH host key and Agent identity remain separate trust records. Association grants no new permissions.',
                      ),
                      (
                        'ACL rules & device groups',
                        'Assign device tags (such as tag:trusted or tag:guest) and groups (group:<name>) in Devices → ACL & Groups or Settings. When ACL enforcement is enabled, DeviceBridge applies Tailscale-style default-deny: unmatched devices are blocked from Files, Agent SSH, Quick Share, Folder Sync, Termux files, Agent actions, and Link setup. Explicit Deny rules override Allow rules.',
                      ),
                      (
                        'Bluetooth',
                        'Not implemented as a usable route. RFCOMM streams and BLE GATT need separate adapters; Bluetooth pairing alone does not provide TCP/IP.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'Networks',
                    badges: const [],
                    summary: 'Open Networks from the Wi-Fi icon to manage this device. Open Devices → select a device → Connections to choose a route, test it, or set up a link with that device.',
                    rows: const [
                      (
                        'Services · L7',
                        'Inspect the DeviceBridge agent, mTLS agent SSH, and local SSH listeners. Paired devices can open a direct Termux/shell SSH session over the DeviceBridge mTLS agent on any verified transport without enabling port 8022 or Tailscale SSH, with identical speed and battery cost in Standard, Shizuku and Root. Tailscale SSH uses Tailscale. Termux OpenSSH binds non-loopback, non-Tailscale interfaces on port 8022 with public/private key auth only. The paired device’s Overview has verified route selection and Speed test. Use Connections for SSH access and manual ADB reverse, hotspot, and Wi-Fi Direct setup.',
                      ),
                      (
                        'Transports · L3/L4',
                        'Direct TLS uses a connected local IP interface. WireGuard on Android shares the LAN setting and may keep Wi-Fi while hosting a direct link. Tailscale follows the Android default internet link when available or system routing on Linux. Check Direct or Relay under the paired device.',
                      ),
                      (
                        'Links · L1/L2',
                        'Set up a hotspot or Wi-Fi Direct with a peer from its Connections screen. Global Networks → Links shows local interface status and lets you bind the Direct TCP listener to an existing local interface. Mobile data is shown for awareness and stays outside Direct TLS. USB networking needs an IP interface. USB ADB needs an authorized Android-to-computer data connection and its own reverse tunnel.',
                      ),
                      (
                        'Setup permissions and efficiency',
                        'Root permits additional radio controls and unattended setup on supported hardware. Shizuku automates setup where Android grants shell access. Standard can use Android’s hotspot and Wi-Fi Direct APIs and may prompt for permission. After setup, the same link and transfer engine have the same throughput and battery efficiency in all three modes.',
                      ),
                      (
                        'Screen and monitoring',
                        'Open Live traffic on Home for agent totals, proxy destinations and visible app and Termux sockets. Standard and Shizuku get the same app and agent counters at the same speed and battery cost. If Android restricts socket visibility, opted-in Root diagnostics can read more socket addresses and available TCP counters. Opening this screen samples diagnostics while it is active. Networks holds link and agent settings.',
                      ),
                      (
                        'Battery & CPU',
                        'Open Battery & CPU diagnostics in Settings to sample usage on demand. Standard, Shizuku and Root use the same app CPU counter, Android UID traffic counters, device battery readings and readable process CPU samples. Root shell diagnostics adds Android’s available UID battery estimates, wakeup alarms and partial wake lock duration. Android does not attribute network-triggered device wakeups to individual DeviceBridge requests or shell tools here.',
                      ),
                      (
                        'Local SOCKS5 proxy',
                        'Enable it under Networks → Tailscale and configure the other app to use the displayed loopback address. In all three privilege tiers an Android foreground service keeps the proxy available after leaving DeviceBridge. The service requests no CPU wake lock. Doze can restrict network access. Use Stop proxy in its notification to end proxy sessions.',
                      ),
                      (
                        'Termux by privilege tier',
                        'Standard, Shizuku and Root run ordinary Termux commands directly at the same speed and power cost. The app translates legacy Termux paths and script interpreters in the local shell. APT keeps packages in the app-private prefix. Root can keep an opted-in session after leaving the app without holding a wake lock.',
                      ),
                      (
                        'SOCKS5 usage',
                        'Home shows bytes and recent connected destinations from in-memory counters for the current proxy listener. Root shell diagnostics can identify active local TCP clients by Android UID when the kernel exposes their sockets. Shared UIDs may represent more than one package. Standard and Shizuku use the same proxy and byte counters.',
                      ),
                      (
                        'Pairing a new installation',
                        'Keep DeviceBridge open on both devices. In Devices, Discover lists nearby unpaired DeviceBridge installations on local Wi-Fi. On one device, create an invitation. On the other, open Pair device and scan its QR on Android or paste the invitation code. Verify the fingerprint and approve the request on the inviting device. The requesting device completes pairing automatically while the app is open. New invitations include the current LAN address so they work when the router filters multicast.',
                      ),
                      (
                        'Pairing permissions and efficiency',
                        'Standard, Shizuku and Root use the same foreground Wi-Fi discovery and TLS pairing, with the same speed and battery use. Android asks for camera access when you open the scanner, and the camera stops when you leave it. Paste the code if camera access is unavailable. Android can use the current unmetered Wi-Fi automatically. Select a network in Networks when a metered link or multiple local networks require a choice.',
                      ),
                      (
                        'Network settings',
                        'Open the gear in Networks to choose automation for the next direct link. Global Settings grants Root and Shizuku access. Root direct-link setup covers hosting and joining. Shizuku has separate hosting and Wi-Fi join switches. Each operation prefers enabled Root, then enabled Shizuku, then Standard. Turn off both applicable switches to use Android’s prompts. Stop or disconnect an active direct link before changing setup mode.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'Choosing a connection',
                    badges: const [],
                    summary: 'Select the connection, transport, and compatible verified link in the device’s Overview. Use Connections to set up links, manage access and fallback, and inspect route details.',
                    rows: const [
                      (
                        'Automatic recovery',
                        'Automatic routing prefers authenticated direct LAN, then Tailscale, then WireGuard. While Device Details is open it checks for a direct route even when the peer changes networks and this device stays put. An explicit transport preference takes precedence. A preferred local link type follows the interface across Wi-Fi networks. The same route policy applies in Standard, Shizuku and Root.',
                      ),
                      (
                        'Interrupted downloads',
                        'An active download waits for the current connection or an approved alternate route, then resumes from saved bytes. The app keeps the partial download if the wait expires. Standard, Shizuku and Root use the same streaming and recovery code, with the same transfer efficiency.',
                      ),
                      (
                        'Tailscale on mobile or metered data',
                        'An Android download asks before using a metered Tailscale uplink, even when remote transfers are enabled for that device. Use data for this download applies only to the current download. Let Wi-Fi return automatically or choose another connection to set up Wi-Fi Direct or a hotspot. Standard, Shizuku and Root use the same approval and streaming path.',
                      ),
                      (
                        'Connection setup',
                        'Open Transports for USB ADB or Links for Wi-Fi Direct and hotspot setup. Hardware and peer capabilities control which actions appear. Ethernet-only Waydroid does not offer hotspot or Wi-Fi Direct setup. Root and Shizuku can automate parts of a manual wireless setup. Route verification and fallback work the same way in Standard mode.',
                      ),
                      (
                        'Terminal and Files',
                        'Terminal opens paired Agent SSH in the app terminal. It starts a named tmux window when tmux is available. On Android the SSH server uses the app user’s initialized Termux shell and Home. Open Termux locally first if its runtime needs setup. Standard, Shizuku and Root use the same unprivileged SSH session and have the same efficiency. Files opens the paired device’s Home when its file permissions allow it.',
                      ),
                      (
                        'Transfer permission',
                        'Connection preferences controls file transfers over internet, relay and mobile routes for this device. Route discovery and authentication work separately.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'Quick Share and registered Sync',
                    badges: const [],
                    summary: 'Quick Share sends a draft once. Folder sync is managed in Files with a packaged engine on Android and Linux. Use a folder’s Sync action; Files → Synced folders manages registered pairs. Termux and tool commands are optional. Full pull stays a separate one-time copy.',
                    rows: const [
                      (
                        'Quick Share',
                        'Use the system picker to send a file or folder. Each peer controls incoming text and files separately. Save verified Android inbox items through the document picker.',
                      ),
                      (
                        'Full folder mode',
                        'Opt-in mirror of the real folder: hidden files, .git history, tracked and uncommitted work all sync. Review the folder first — secrets and caches are included. The manifest still skips Syncthing control files.',
                      ),
                      (
                        'Non-git modes',
                        'Untracked & ignored only stages approved persistent files and keeps the signed single-writer project handoff. All working files except .git stages every working file (including uncommitted and hidden) without Git metadata and without a clean-worktree gate.',
                      ),
                      (
                        'Full pull',
                        'A pair’s menu offers Full pull from either remote endpoint to this device; the destination is explicitly this device. It copies the actual folder including uncommitted files and .git by default, independent of its sync filter. Native verified streaming needs neither rsync, Syncthing nor Termux and leaves registrations and revisions alone.',
                      ),
                      (
                        'Phone storage, permissions and efficiency',
                        'Native phone storage with All Files Access and app Downloads use the same app-managed engine in Standard, Shizuku and Root modes. Root and Shizuku add no speed advantage for these accessible folders. If the standalone Termux app is installed, use Networks → Services → Termux tools to set up its companion over SSH, then choose the paired device in Files. The companion uses the bundled Syncthing engine during approved sessions. The native engine runs as the Android app user or the Linux state owner. Linux Files uses the signed-in user’s Home, Downloads and filesystem permissions.',
                      ),
                      (
                        'Phone as controller',
                        'Choose any two paired machines or permitted phone folders. If neither folder is on the phone, it sends setup and status messages while file bytes flow between the endpoints. The Connection row opens the paired device’s Connections view. Choose a verified route in Overview or set up a radio under Connections → Links, then return. Approve and sync now maps the selected connection onto the two folders’ networks and probes reachability. A dedicated link such as Wi-Fi Direct is usually fastest. The phone never silently relays files.',
                      ),
                      (
                        'Exclusions and symlink safety',
                        'The Exclude folders field lists relative subtrees (one per line or comma-separated) to leave out of both the verified manifest and the engine transfer, for example regenerable build artifacts such as flutter/ephemeral/.plugin_symlinks. Excluding a directory skips its whole subtree. Symlinks and special files in the folders that remain in scope are still blocked, and the error names the offending path. A managed .stignore mirrors the exclusions during the session; any foreign .stignore still fails closed.',
                      ),
                      (
                        'Approval, badges and network binding',
                        'Registered folders show a sync badge even while paused. Enable each paired controller in Files → Synced folders on the endpoint, or through Flutter SSH setup for a headless machine. Remote data routes require separate approval. Android endpoint-local socket adapters keep encrypted engine streams on the selected Network without a VPN or root; these are not controller relays. No idle background synchronization starts automatically.',
                      ),
                      (
                        'Projects',
                        'The legacy untracked/ignored project workflow retains signed single-writer revisions and matching clean Git branch/HEAD gates. Ordinary full-folder and working-file modes use the file-manager GUI and do not require Git or a Termux session. Working imports preserve Git, keep recovery copies and refuse concurrent local changes.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'ADB over USB (Wired)',
                    badges: const [
                      ('Most Battery Friendly', true),
                      ('Lowest Overhead & Latency', true),
                    ],
                    summary: 'Best choice whenever a USB cable is plugged in. Wireless ADB is ignored because it shares the Wi-Fi radio.',
                    rows: const [
                      (
                        'Why it is most efficient',
                        'Zero Wi-Fi beacon TX/RX, zero mDNS multicast wakeups, shielded wired USB transfer, and phone stays powered/charging via USB.',
                      ),
                      (
                        'Strategy',
                        'Detects wired USB serial only (adbEnabled && usbConnected && usbAdb) and configures adb reverse tcp:18731 tcp:8731 cleanly.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'Wi-Fi (Existing Router / LAN)',
                    badges: const [
                      ('Best Everyday Balance', true),
                      ('Low Battery · High Speed', false),
                    ],
                    summary: 'Best wireless option when phone and laptop share a router (especially 5 GHz Wi-Fi 5/6).',
                    rows: const [
                      (
                        'Why it saves battery vs Hotspot',
                        'Reuses your existing wlan0 association in Wi-Fi power-save mode instead of running an AP/P2P beacon transmitter on the phone.',
                      ),
                      (
                        'Strategy',
                        'Laptop agent runs --lan-cidr auto (re-binding within ~2.5s on subnet switches). Foreground mDNS multicast lock pauses automatically when the app leaves foreground.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'Wi-Fi Direct (P2P GO) & Wi-Fi Hotspot (Local AP)',
                    badges: const [
                      ('Fastest Off-Router Wireless', true),
                      ('Higher Battery Draw While Hosting', false),
                    ],
                    summary: 'Ideal when no router exists or router Wi-Fi is slow/isolated; targets 5 GHz (80 MHz / Wi-Fi 6 when hardware supports it).',
                    rows: const [
                      (
                        'Battery note',
                        'Hosting p2p-p2p0-* or ap0 keeps the phone Wi-Fi radio transmitting beacons continuously. Always tap Stop when finished so DeviceBridge restores wlan0.',
                      ),
                      (
                        'Strategy',
                        'Uses Root, Shizuku, or the Standard API to start the link. DeviceBridge normally tells the peer what to join first. When Android can keep router Wi-Fi while hosting a hotspot, it starts the hotspot first and sends the credentials Android actually chose.',
                      ),
                      (
                        'Linux and router Wi-Fi',
                        'A supported Linux laptop hosts Wi-Fi Direct on a separate interface and keeps its router Wi-Fi. The temporary interface gets its own MAC address if the driver copies the router interface address. The Linux agent needs network administration, wpa_supplicant and dnsmasq. When the phone hosts, the laptop joins by SSID on its regular Wi-Fi interface and returns to its previous network when you tap Stop.',
                      ),
                      (
                        'Overview transport picker',
                        'An open Wi-Fi Direct or hotspot link hides Tailscale. After you tap Stop, reachable Tailscale routes return to the Overview picker.',
                      ),
                      (
                        'After an app restart',
                        'Android keeps the last direct link for its paired device. Reconnect joins a laptop-hosted link that is still open and verifies the paired device. Restart recreates a phone-hosted link when Android released it. Standard mode can show the system Wi-Fi confirmation. Stop forgets the saved link.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'Direct Link Channels, Width (80 vs 160 MHz) & Regulatory Domains',
                    badges: const [
                      ('Auto (Highest · Ch 161)', true),
                      ('Manual Channel & Width', false),
                    ],
                    summary: 'Control exact operating channel and channel width on Wi-Fi Direct and Hotspot to avoid congested lower channels or 20/40 MHz fallbacks.',
                    rows: const [
                      (
                        'Why Ch 161 (5805 MHz) & 80 MHz',
                        'UNII-3 spans 5735–5835 MHz (channels 149, 153, 157, 161 = one 80 MHz block; Ch 165 / 5825 MHz is 20 MHz only). Auto (Highest) picks Ch 161 on UNII-3 first for clean 80 MHz speed instead of congested Ch 36/149.',
                      ),
                      (
                        'Why 160 MHz is unavailable on UNII-3 / some pairs',
                        'Contiguous 160 MHz requires UNII-1+2 (Ch 36–64) or UNII-2e (Ch 100–128) AND 160 MHz hardware support on BOTH phone and laptop. If your laptop Wi-Fi card tops out at 80 MHz (VHT80/HE80), links negotiate 80 MHz.',
                      ),
                      (
                        'Linux 5 GHz & "sudo iw reg set US"',
                        'Some regulatory domains (e.g. country PK) disable Ch 36–144 in "iw list" and only enable Ch 149–165. When Setup via SSH installs the system systemd unit (/etc/systemd/system/devicebridge-agent.service with CAP_NET_ADMIN), the laptop daemon automatically runs "iw reg set US" on the fly whenever mobile requests a locked 5 GHz channel.',
                      ),
                      (
                        'Privilege tier difference',
                        'Root & Shizuku pass exact width (-w 160 → -w 80) and frequency (-f) to "cmd wifi start-lohs" and "cmd wifip2p create-group-with-config". Standard mode passes custom frequency on Wi-Fi Direct via WifiP2pConfig.setGroupOperatingFrequency (Android 10+), while OS LocalOnlyHotspot picks its own channel.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'WireGuard',
                    badges: const [
                      ('Most Battery Friendly Tunnel', true),
                      ('Stateless UDP Crypto', false),
                    ],
                    summary: 'App-scoped WireGuard tunnel (.conf import strips default routes so system traffic never hijacks battery/data).',
                    rows: const [
                      (
                        'Why it is battery friendly',
                        'Stateless UDP Noise handshake with silent idle periods and lower userspace wakeups than persistent control-plane overlays; prefers direct LAN endpoints before external server hops.',
                      ),
                      (
                        'Strategy',
                        'Runs userspace wireguard-go/netstack (non-root Android & fallback) or kernel WireGuard module on Linux/rooted hosts.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'Tailscale (App-Private tsnet / System tailscaled)',
                    badges: const [
                      ('Best NAT Traversal & Anywhere Access', true),
                      ('Direct UDP Preferred Over DERP', false),
                    ],
                    summary: 'Reaches peers across CGNAT/firewalls without root or VpnService on Android (uses system tailscaled on Linux).',
                    rows: const [
                      (
                        'Efficiency',
                        'Starts app-private tsnet only while visible/transferring (120s grace). Prefers direct UDP peer-to-peer (even using dual-interface rule 20000 on wlan0 during Hotspot); DERP relays increase latency and battery usage.',
                      ),
                      (
                        'Wi-Fi and mobile data',
                        'Uses Android’s default internet connection and reconnects when it changes. Signed-out nodes and unreachable peers stay out of the Overview transport picker. Root, Shizuku and Standard use the same tunnel with the same permissions and efficiency.',
                      ),
                    ],
                  ),
                ],

                if (_showSection(
                  'files',
                  'file manager storage permissions internal termux home recycle bin delete drag drop manage_external_storage all files xxh64',
                )) ...[
                  _sectionHeader(
                    context,
                    Icons.folder_outlined,
                    'File Manager Permissions & Storage Strategy',
                    'Verified with XXH64 (xxhsum -H1), atomic no-overwrite staging, and symlink safety',
                  ),
                  _infoCard(
                    context,
                    title: 'Termux Home (Built-in Terminal)',
                    badges: const [
                      ('Zero Permissions Needed', true),
                      ('Fastest Local I/O', false),
                    ],
                    summary: 'Always available inside app-private filesDir/terminal/files/home with zero Android dialogs or SAF overhead.',
                    rows: const [
                      (
                        'Strategy',
                        'Direct POSIX file/tar streaming with atomic staging and XXH64 target verification before publishing.',
                      ),
                      (
                        'Settings → Termux backup',
                        'Back up hidden files, projects, configs and installed package names. '
                            'Links are stored as links. DeviceBridge verifies the saved archive '
                            'and reports unreadable or disappearing entries. Restore validates '
                            'the archive before switching Homes, keeps the previous Home and '
                            'saves a package install command. Standard, Shizuku and Root use '
                            'the same file access, picker, and verification.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'All Files Access (MANAGE_EXTERNAL_STORAGE)',
                    badges: const [
                      ('Most Efficient Shared Storage', true),
                      ('Android 11+ Direct POSIX', false),
                    ],
                    summary: 'Recommended on Android for serving or copying large /storage/emulated/0 folders.',
                    rows: const [
                      (
                        'Why it beats ContentProvider IPC',
                        'Reads and writes files directly via kernel syscalls instead of per-file ContentProvider Binder IPC round-trips, saving CPU and battery on large folder transfers.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'Recycle Bin & Drag-and-Drop',
                    badges: const [
                      ('Recoverable Trash', true),
                      ('Verified Copy & Move', false),
                    ],
                    summary: 'Move local files or folders to the Recycle Bin to restore later, permanently delete them, or drag items onto the other panel or directly onto any folder to copy or move.',
                    rows: const [
                      (
                        'Safety',
                        'Recycle Bin uses atomic same-filesystem moves when possible and refuses to overwrite existing files on restore.',
                      ),
                    ],
                  ),
                  _infoCard(
                    context,
                    title: 'Termux RUN_COMMAND Permission',
                    badges: const [('Optional Command Helper', false)],
                    summary: 'Allows explicit Termux tool runs. For browsing and sync, choose the paired Termux device and its home root in Files.',
                    rows: const [
                      (
                        'Note',
                        'Requires com.termux allow-external-apps=true in ~/.termux/termux.properties and com.termux.permission.RUN_COMMAND.',
                      ),
                    ],
                  ),
                ],

                if (_showSection(
                  'binaries',
                  'termux targetSdk 28 29 36 selinux w^x untrusted_app app_data_file gobinarymanager hot swap flutter run apk',
                )) ...[
                  _sectionHeader(
                    context,
                    Icons.memory_outlined,
                    'Go Core Binaries, Hot-Swap & How Termux Differs',
                    'Why APK packaging, SELinux W^X, and targetSdk affect binary execution',
                  ),
                  _infoCard(
                    context,
                    title: 'Why Termux runs unpacked binaries without APK rebuilds',
                    badges: const [
                      ('Termux: targetSdk 28', true),
                      ('DeviceBridge: targetSdk 28', true),
                    ],
                    summary: 'Android enforces strict SELinux W^X rules based on an app\'s targetSdkVersion, not whether the phone has internet or Play Store.',
                    rows: const [
                      (
                        'targetSdk >= 29 (Android 10+ W^X)',
                        'Apps targeting SDK 29+ run in the untrusted_app SELinux domain where execve() on writable app_data_file directories (filesDir) is denied by the kernel (Permission denied / error=13). Only nativeLibraryDir executables inside the APK (apk_data_file) may be execve()d directly.',
                      ),
                      (
                        'targetSdk 28 (Termux & DeviceBridge hot-swap)',
                        'Both Termux and DeviceBridge (build.gradle.kts) pin targetSdk = 28, placing the process in untrusted_app_28 where app_data_file retains execute rights. That allows GoBinaryManager to extract, verify, and execute updated Go binaries directly in filesDir/devicebridge/hotbin without rebuilding the APK.',
                      ),
                      (
                        'DeviceBridge GoBinaryManager & Hot Iteration',
                        'GoBinaryManager (Settings -> Go core libraries) tracks loaded versions & XXH64, replaces and deletes old binaries cleanly on Flutter Hot Restart or Reload, and falls back safely to bundled libbridge_*.so if needed. Keep flutter run -d <serial> -v attached for ~1s Dart UI Hot Reload.',
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
