import 'package:material_ui/material_ui.dart';

/// The controller belongs to the route. Disposing it when showDialog's result
/// completes is too early: the outgoing route still animates and reads it.
class PairInvitationDialog extends StatefulWidget {
  const PairInvitationDialog({super.key});
  @override
  State<PairInvitationDialog> createState() => _PairInvitationDialogState();
}

class _PairInvitationDialogState extends State<PairInvitationDialog> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Pair with a device'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Paste the invitation code displayed by your other device.',
          ),
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
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          FocusScope.of(context).unfocus();
          Navigator.pop(context, controller.text);
        },
        child: const Text('Review'),
      ),
    ],
  );
}
