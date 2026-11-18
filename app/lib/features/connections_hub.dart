import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'tailnet_panel.dart';

/// Unified Connections hub under the top-bar Wi-Fi icon: Wi-Fi LAN, Hotspot,
/// Wi-Fi Direct, Tailscale (tsnet / system tailscaled), ADB, and SSH / Termux.
class ConnectionsHub extends StatefulWidget {
  const ConnectionsHub({
    super.key,
    required this.core,
    required this.listenerState,
    required this.onSelectNetwork,
  });
  final CoreBridge core;
  final String? listenerState;
  final Future<void> Function() onSelectNetwork;
  @override
  State<ConnectionsHub> createState() => _ConnectionsHubState();
}

class _ConnectionsHubState extends State<ConnectionsHub> {
  bool busy = true;
  String? error;
  List<Map<String, dynamic>> availableNetworks = [];
  Map<String, dynamic> caps = {};
  Map<dynamic, dynamic>? tailnetStatus;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) {
      setState(() {
        busy = true;
        error = null;
      });
    }
    try {
      availableNetworks = await widget.core.networks();
      caps = await widget.core.platformCapabilities();
      try {
        tailnetStatus = await widget.core.run(['tailnet', 'status']) as Map;
      } catch (_) {
        tailnetStatus = null;
      }
    } catch (e) {
      error = e.toString();
    }
    if (mounted) {
      setState(() => busy = false);
    }
  }

  Future<void> openSetup(String kind) async {
    try {
      await widget.core.openConnectionSetup(kind);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeNet = widget.core.network;
    final hotspotNets = availableNetworks
        .where((n) => n['kind'] == 'hotspot' || n['kind'] == 'wifi_direct')
        .toList();
    final tsMode = tailnetStatus?['mode'] == 'system'
        ? 'Existing system Tailscale'
        : 'App-only Tailscale (tsnet)';
    final tsState = tailnetStatus?['state'] as String? ?? 'Not running';
    final tsIps = (tailnetStatus?['ips'] as List? ?? []).join(', ');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connections'),
        actions: [
          IconButton(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh connections',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: SelectableText(error!),
            ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.wifi),
                    title: Text('Wi-Fi LAN'),
                    subtitle: Text(
                      'Primary direct local transfer path with mTLS and mDNS discovery.',
                    ),
                  ),
                  Text(
                    activeNet != null
                        ? 'Approved: ${activeNet['interface']} · ${activeNet['cidr']}'
                        : 'No Wi-Fi LAN approved yet (${widget.listenerState ?? 'idle'})',
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            await widget.onSelectNetwork();
                            await load();
                          },
                    icon: const Icon(Icons.wifi_lock),
                    label: const Text('Select / approve local network'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.wifi_tethering),
                    title: Text('Hotspot & Wi-Fi Direct'),
                    subtitle: Text(
                      'High-speed direct links without an external router. Establish link, then approve its interface.',
                    ),
                  ),
                  if (hotspotNets.isEmpty)
                    const Text('No active hotspot or Wi-Fi Direct interface detected.')
                  else
                    for (final n in hotspotNets)
                      Text('Detected: ${n['interface']} · ${n['cidr']}'),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => openSetup('hotspot'),
                        icon: const Icon(Icons.wifi_tethering),
                        label: const Text('Set up hotspot'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => openSetup('wifi_direct'),
                        icon: const Icon(Icons.wifi_find),
                        label: const Text('Set up Wi-Fi Direct'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.hub_outlined),
                    title: const Text('Tailscale (tsnet / system)'),
                    subtitle: Text(
                      '$tsMode · $tsState${tsIps.isNotEmpty ? ' · $tsIps' : ''}',
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => TailnetPanel(core: widget.core),
                        ),
                      );
                      await load();
                    },
                    icon: const Icon(Icons.settings),
                    label: const Text('Manage Tailscale'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.usb),
                    title: const Text('USB / Wireless ADB'),
                    subtitle: Text(
                      caps['adb_enabled'] == true
                          ? 'ADB available. Forward local port (adb forward tcp:8731 tcp:<agent_port>) and choose ADB 127.0.0.1:8731 per device.'
                          : 'Enable USB or Wireless debugging in Developer options, then select 127.0.0.1:<port> per device.',
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => openSetup('adb'),
                    icon: const Icon(Icons.developer_mode),
                    label: const Text('Developer / ADB settings'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.terminal),
                    title: const Text('SSH & Termux Bridge'),
                    subtitle: Text(
                      caps['termux_installed'] == true
                          ? 'Termux detected. Grant Termux storage via SAF for dual-pane transfers, or tunnel with ssh -L 8731:127.0.0.1:<port>.'
                          : 'Forward an authenticated SSH local tunnel (ssh -L 8731:127.0.0.1:<port>) and select 127.0.0.1:8731 per device.',
                    ),
                  ),
                  if (caps['termux_tree_name'] != null)
                    Text('Granted Termux folder: ${caps['termux_tree_name']}'),
                  const SizedBox(height: 8),
                  if (caps['termux_installed'] == true)
                    OutlinedButton.icon(
                      onPressed: () async {
                        await widget.core.pickTargetTree(termux: true);
                        await load();
                      },
                      icon: const Icon(Icons.folder_special),
                      label: const Text('Grant Termux folder (SAF)'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
