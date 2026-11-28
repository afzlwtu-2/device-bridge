import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

class TailnetDevicePicker extends StatefulWidget {
  const TailnetDevicePicker({
    super.key,
    required this.core,
    required this.onSelected,
    this.enabled = true,
  });

  final CoreBridge core;
  final ValueChanged<String> onSelected;
  final bool enabled;

  @override
  State<TailnetDevicePicker> createState() => _TailnetDevicePickerState();
}

class _TailnetDevicePickerState extends State<TailnetDevicePicker> {
  late final _devices = _loadDevices();

  Future<Map<String, String>> _loadDevices() async {
    try {
      final status = await widget.core.run(['tailnet', 'status']) as Map;
      final devices = <String, String>{};
      for (final node in (status['peers'] as List? ?? []).whereType<Map>()) {
        if (node['online'] != true) continue;
        for (final ip in (node['ips'] as List? ?? []).whereType<String>()) {
          if (ip.contains(':')) continue;
          devices[ip] = '${node['dns_name'] ?? node['name'] ?? ip} · $ip';
          break;
        }
      }
      return devices;
    } catch (_) {
      return {};
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, String>>(
    future: _devices,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const LinearProgressIndicator();
      }
      final devices = snapshot.data ?? {};
      if (devices.isEmpty) {
        return const Text(
          'No online Tailscale devices. Enter the address below.',
        );
      }
      return DropdownButtonFormField<String>(
        key: const ValueKey('tailnet-device-picker'),
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Tailscale device'),
        items: [
          for (final device in devices.entries)
            DropdownMenuItem(
              value: device.key,
              child: Text(device.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: widget.enabled
            ? (value) {
                if (value != null) widget.onSelected(value);
              }
            : null,
      );
    },
  );
}
