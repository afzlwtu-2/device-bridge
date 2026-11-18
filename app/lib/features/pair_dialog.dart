import 'package:material_ui/material_ui.dart';

class PairInvitationResult {
  const PairInvitationResult(this.invite, {this.tailnetEndpoint});
  final String invite;
  final String? tailnetEndpoint;
}

/// The controller belongs to the route. Disposing it when showDialog's result
/// completes is too early: the outgoing route still animates and reads it.
class PairInvitationDialog extends StatefulWidget {
  const PairInvitationDialog({super.key, this.tailnetPeers = const []});
  final List<Map<String, dynamic>> tailnetPeers;
  @override
  State<PairInvitationDialog> createState() => _PairInvitationDialogState();
}

class _PairInvitationDialogState extends State<PairInvitationDialog> {
  final controller = TextEditingController();
  String? selectedTailnetEndpoint;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peerItems = <DropdownMenuItem<String?>>[
      const DropdownMenuItem(
        value: null,
        child: Text('Direct local network (Wi-Fi / Hotspot LAN)'),
      ),
      for (final node in widget.tailnetPeers)
        for (final ip in (node['ips'] as List? ?? const []))
          if (!(ip as String).contains(':'))
            DropdownMenuItem(
              value: '$ip:8731',
              child: Text(
                'Tailscale · ${node['name']} · $ip${node['online'] == true ? '' : ' (offline)'}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
    ];
    return AlertDialog(
      title: const Text('Pair with a device'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Paste the invitation code displayed by your other device.',
              ),
              if (peerItems.length > 1) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: selectedTailnetEndpoint,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Connect via',
                    border: OutlineInputBorder(),
                  ),
                  items: peerItems,
                  onChanged: (v) =>
                      setState(() => selectedTailnetEndpoint = v),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Invitation code',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.pop(
              context,
              PairInvitationResult(
                controller.text,
                tailnetEndpoint: selectedTailnetEndpoint,
              ),
            );
          },
          child: const Text('Review'),
        ),
      ],
    );
  }
}
