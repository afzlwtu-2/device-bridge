import 'package:material_ui/material_ui.dart';

import 'network_rules.dart';

/// Renders available SSH transport choices and overlay-route approval consistently across SSH screens.
class SshTransportSelector extends StatelessWidget {
  const SshTransportSelector({
    super.key,
    required this.transport,
    required this.remoteApproved,
    required this.rules,
    required this.runtime,
    required this.onTransportChanged,
    required this.onRemoteApprovedChanged,
    this.enabled = true,
    this.allowAuto = true,
    this.approvalTitle = 'Allow this SSH connection to use the selected overlay',
  });

  final String transport;
  final bool remoteApproved;
  final NetworkRules rules;
  final Map<String, dynamic> runtime;
  final ValueChanged<String> onTransportChanged;
  final ValueChanged<bool> onRemoteApprovedChanged;
  final bool enabled;
  final bool allowAuto;
  final String approvalTitle;

  @override
  Widget build(BuildContext context) {
    final usbConnected =
        (runtime['usb'] as Map?)?['usb_adb_connected'] == true;
    final items = <DropdownMenuItem<String>>[
      if (allowAuto || transport == 'auto')
        const DropdownMenuItem(value: 'auto', child: Text('Automatic')),
      if (rules.allows('direct') || transport == 'direct')
        const DropdownMenuItem(value: 'direct', child: Text('Direct TCP')),
      if (rules.allows('tailnet') || transport == 'tailnet')
        const DropdownMenuItem(
          value: 'tailnet',
          child: Text('Tailscale — sign-in required'),
        ),
      if (rules.allows('wireguard') || transport == 'wireguard')
        const DropdownMenuItem(
          value: 'wireguard',
          child: Text('WireGuard — configuration required'),
        ),
      if ((rules.allows('adb') && usbConnected) || transport == 'adb')
        const DropdownMenuItem(
          value: 'adb',
          child: Text('ADB — loopback port mapping'),
        ),
    ];
    final current = items.any((item) => item.value == transport)
        ? transport
        : (items.first.value ?? 'direct');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: const ValueKey('ssh-transport-dropdown'),
          initialValue: current,
          decoration: const InputDecoration(labelText: 'Transport'),
          items: items,
          onChanged: !enabled
              ? null
              : (value) {
                  if (value != null) onTransportChanged(value);
                },
        ),
        if (current == 'tailnet' || current == 'wireguard')
          CheckboxListTile(
            key: const ValueKey('ssh-transport-remote-approval'),
            contentPadding: EdgeInsets.zero,
            title: Text(approvalTitle),
            subtitle: const Text(
              'The route may use internet or cellular data. This does not approve bulk file transfers.',
            ),
            value: remoteApproved,
            onChanged: !enabled
                ? null
                : (value) => onRemoteApprovedChanged(value == true),
          ),
      ],
    );
  }
}
