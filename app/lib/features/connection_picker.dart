import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'tailnet_panel.dart';

class ConnectionPicker extends StatefulWidget {
  const ConnectionPicker({super.key, required this.core, required this.peer});
  final CoreBridge core;
  final String peer;
  @override
  State<ConnectionPicker> createState() => _ConnectionPickerState();
}

class _ConnectionPickerState extends State<ConnectionPicker> {
  String mode = 'lan';
  String? endpoint, error;
  bool approved = false, fallbackApproved = false, busy = true;
  double? lastRate;
  String? lastRateTransport;
  List<dynamic> nodes = [];
  final adbController = TextEditingController();
  final sshController = TextEditingController();
  final wgController = TextEditingController();

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    adbController.dispose();
    sshController.dispose();
    wgController.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final current = await widget.core.run(['connection', widget.peer]) as Map;
      mode = current['transport'] as String? ?? 'lan';
      endpoint = current['endpoint'] as String?;
      approved = current['remote_approved'] == true;
      fallbackApproved = current['fallback_approved'] == true;
      adbController.text =
          current['adb_endpoint'] as String? ??
          (mode == 'adb' ? (endpoint ?? '127.0.0.1:8731') : '');
      sshController.text =
          current['ssh_endpoint'] as String? ??
          (mode == 'ssh' ? (endpoint ?? '127.0.0.1:8731') : '');
      wgController.text =
          current['wireguard_endpoint'] as String? ??
          (mode == 'wireguard' ? (endpoint ?? '10.77.0.1:8731') : '');
      lastRate = (current['last_mib_per_second'] as num?)?.toDouble();
      lastRateTransport = current['last_rate_transport'] as String?;
      try {
        final status = await widget.core.run(['tailnet', 'status']) as Map;
        nodes = status['peers'] as List? ?? [];
      } catch (_) {
        nodes = [];
      }
    } catch (e) {
      error = e.toString();
    }
    if (mounted) {
      setState(() => busy = false);
    }
  }

  Future<void> setup(String kind) async {
    try {
      await widget.core.openConnectionSetup(kind);
    } catch (e) {
      if (mounted) {
        setState(() => error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Connection for this device'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (busy) const LinearProgressIndicator(),
            const Text(
              'Choose the primary route and optionally approve alternate routes for automatic resume if a transfer is disrupted.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: mode,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Primary connection',
              ),
              items: const [
                DropdownMenuItem(
                  value: 'lan',
                  child: Text(
                    'Direct local network (Wi-Fi / Hotspot / P2P)',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(value: 'tailnet', child: Text('Tailscale')),
                DropdownMenuItem(
                  value: 'wireguard',
                  child: Text(
                    'WireGuard (Userspace / Kernel · LAN-direct first)',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                DropdownMenuItem(
                  value: 'adb',
                  child: Text('USB / Wireless ADB tunnel'),
                ),
                DropdownMenuItem(value: 'ssh', child: Text('SSH local tunnel')),
              ],
              onChanged: (v) => setState(() => mode = v ?? 'lan'),
            ),
            if (mode == 'lan') ...[
              const SizedBox(height: 12),
              Text(
                'Current interface: ${widget.core.network?['interface'] ?? 'not approved'}',
              ),
              Text(
                'Local IP: ${widget.core.network?['cidr'] ?? 'unavailable'}',
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => setup('hotspot'),
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('Set up hotspot'),
                  ),
                  TextButton.icon(
                    onPressed: () => setup('wifi_direct'),
                    icon: const Icon(Icons.wifi_find),
                    label: const Text('Set up Wi-Fi Direct'),
                  ),
                ],
              ),
            ] else if (mode == 'adb') ...[
              const SizedBox(height: 12),
              TextField(
                controller: adbController,
                decoration: const InputDecoration(
                  labelText: 'ADB forwarded loopback endpoint',
                  hintText: '127.0.0.1:8731',
                ),
              ),
            ] else if (mode == 'ssh') ...[
              const SizedBox(height: 12),
              TextField(
                controller: sshController,
                decoration: const InputDecoration(
                  labelText: 'SSH forwarded loopback endpoint',
                  hintText: '127.0.0.1:8731',
                ),
              ),
            ] else if (mode == 'wireguard') ...[
              const SizedBox(height: 12),
              TextField(
                controller: wgController,
                decoration: const InputDecoration(
                  labelText: 'WireGuard tunnel endpoint',
                  hintText: '10.77.0.1:8731',
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Uses userspace wireguard-go on non-rooted devices and kernel WireGuard module when rooted. Connects direct P2P on the same LAN before external servers.',
                style: TextStyle(fontSize: 12),
              ),
              CheckboxListTile(
                value: approved,
                onChanged: (v) => setState(() => approved = v ?? false),
                title: const Text(
                  'Allow remote server hop when outside local LAN',
                ),
              ),
            ] else ...[
              const SizedBox(height: 12),
              if (nodes.isEmpty)
                const Text(
                  'No tailnet peers available. Connect Tailscale first.',
                ),
              if (nodes.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue:
                      nodes.any(
                        (n) => (n['ips'] as List? ?? []).any(
                          (ip) => '$ip:8731' == endpoint,
                        ),
                      )
                      ? endpoint
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Tailnet device',
                  ),
                  items: [
                    for (final node in nodes)
                      for (final ip in (node['ips'] as List? ?? []))
                        if (!(ip as String).contains(':'))
                          DropdownMenuItem(
                            value: '$ip:8731',
                            child: Text(
                              '${node['name']} · $ip',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                  ],
                  onChanged: (v) => setState(() => endpoint = v),
                ),
              CheckboxListTile(
                value: approved,
                onChanged: (v) => setState(() => approved = v ?? false),
                title: const Text(
                  'Allow internet and relay data for this device',
                ),
                subtitle: const Text(
                  'Remote transfers can change between direct and relay paths.',
                ),
              ),
              TextButton(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => TailnetPanel(core: widget.core),
                    ),
                  );
                  await load();
                },
                child: const Text('Tailscale settings'),
              ),
            ],
            const Divider(height: 24),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: fallbackApproved,
              onChanged: (v) => setState(() => fallbackApproved = v ?? false),
              title: const Text(
                'Resume on approved alternate route if disrupted',
              ),
              subtitle: const Text(
                'Switches only across explicitly approved routes for this same verified peer (LAN/Hotspot, ADB/SSH loopback, or approved Tailscale).',
              ),
            ),
            if (fallbackApproved && mode != 'adb')
              TextField(
                controller: adbController,
                decoration: const InputDecoration(
                  labelText: 'Optional ADB fallback (127.0.0.1:port)',
                ),
              ),
            if (fallbackApproved && mode != 'ssh') ...[
              const SizedBox(height: 8),
              TextField(
                controller: sshController,
                decoration: const InputDecoration(
                  labelText: 'Optional SSH fallback (127.0.0.1:port)',
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              lastRate != null && lastRate! > 0
                  ? 'Measured speed: ${lastRate!.toStringAsFixed(2)} MiB/s${lastRateTransport != null && lastRateTransport!.isNotEmpty ? ' ($lastRateTransport)' : ''}'
                  : 'Measured speed: — MiB/s (measure during a transfer)',
            ),
            if (error != null) Text(error!),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy
            ? null
            : () async {
                try {
                  final adbEp = adbController.text.trim();
                  final sshEp = sshController.text.trim();
                  final wgEp = wgController.text.trim();
                  String? selectedEp = endpoint;
                  if (mode == 'tailnet' && (!approved || endpoint == null)) {
                    setState(
                      () => error = 'Select a tailnet device and approve remote data first.',
                    );
                    return;
                  }
                  if (mode == 'adb') {
                    selectedEp = adbEp.isEmpty ? '127.0.0.1:8731' : adbEp;
                  } else if (mode == 'ssh') {
                    selectedEp = sshEp.isEmpty ? '127.0.0.1:8731' : sshEp;
                  } else if (mode == 'wireguard') {
                    selectedEp = wgEp.isEmpty ? '10.77.0.1:8731' : wgEp;
                  }
                  final fallbacks = <String>[
                    if (mode != 'lan') 'lan',
                    if (wgEp.isNotEmpty) 'wireguard',
                    if (adbEp.isNotEmpty) 'adb',
                    if (sshEp.isNotEmpty) 'ssh',
                    if (approved && endpoint != null) 'tailnet',
                  ];
                  await widget.core.run(
                    ['connection', widget.peer, '-'],
                    input: jsonEncode({
                      'transport': mode,
                      'endpoint': ?selectedEp,
                      'remote_approved': approved,
                      'fallback_approved': fallbackApproved,
                      'fallback_transports': fallbacks,
                      if (adbEp.isNotEmpty) 'adb_endpoint': adbEp,
                      if (sshEp.isNotEmpty) 'ssh_endpoint': sshEp,
                      if (wgEp.isNotEmpty) 'wireguard_endpoint': wgEp,
                    }),
                  );
                  if (context.mounted) {
                    Navigator.pop(context, true);
                  }
                } catch (e) {
                  if (mounted) {
                    setState(() => error = e.toString());
                  }
                }
              },
        child: const Text('Use connection'),
      ),
    ],
  );
}
