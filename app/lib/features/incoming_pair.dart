import 'package:material_ui/material_ui.dart';

class IncomingPairDialog extends StatefulWidget {
  const IncomingPairDialog({super.key, required this.peer});
  final Map<String, dynamic> peer;
  @override
  State<IncomingPairDialog> createState() => _IncomingPairDialogState();
}

class _IncomingPairDialogState extends State<IncomingPairDialog> {
  bool downloads = false;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Pair with ${widget.peer['name']}?'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Verify this fingerprint on the requesting device.'),
          const SizedBox(height: 12),
          SelectableText('${widget.peer['id']}'),
          CheckboxListTile(
            value: downloads,
            onChanged: (v) => setState(() => downloads = v ?? false),
            title: const Text(
              'Allow browsing and pulling DeviceBridge downloads',
            ),
            subtitle: const Text('Read only · 24 hours · 10 GiB limit'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, downloads),
        child: const Text('Approve pairing'),
      ),
    ],
  );
}
