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
  bool approved = false, busy = true;
  double? lastRate;
  String? lastRateTransport;
  List<dynamic> nodes = [];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final current = await widget.core.run(['connection', widget.peer]) as Map;
      mode = current['transport'] as String? ?? 'lan';
      endpoint = current['endpoint'] as String?;
      approved = current['remote_approved'] == true;
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
              'Choose the route for this device. LAN does not automatically fall back to the internet.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: mode,
              decoration: const InputDecoration(labelText: 'Connection'),
              items: const [
                DropdownMenuItem(
                  value: 'lan',
                  child: Text('Direct local network'),
                ),
                DropdownMenuItem(value: 'tailnet', child: Text('Tailscale')),
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
              const Text(
                'LAN, hotspot and Wi-Fi Direct use the same authenticated file-transfer protocol. Establish the physical link, then select/approve its network.',
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
                  'Remote transfers can change between direct and relay paths. Approved Wi-Fi only on Android.',
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
                  if (mode == 'tailnet') {
                    if (!approved || endpoint == null) {
                      setState(
                        () => error = 'Select a tailnet device and approve remote data first.',
                      );
                      return;
                    }
                    await widget.core.run([
                      'connection',
                      widget.peer,
                      'tailnet',
                      endpoint!,
                      'allow-internet-and-relays',
                    ]);
                  } else {
                    await widget.core.run(['connection', widget.peer, 'lan']);
                  }
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
