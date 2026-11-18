import 'package:material_ui/material_ui.dart';

class FolderNameDialog extends StatefulWidget {
  const FolderNameDialog({super.key});
  @override
  State<FolderNameDialog> createState() => _FolderNameDialogState();
}

class _FolderNameDialogState extends State<FolderNameDialog> {
  final controller = TextEditingController();
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New folder'),
    content: TextField(
      controller: controller,
      autofocus: true,
      decoration: InputDecoration(labelText: 'Folder name', errorText: error),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final name = controller.text.trim();
          if (name.isEmpty ||
              name == '.' ||
              name == '..' ||
              name.contains(RegExp(r'[/\\\x00]'))) {
            setState(
              () => error = 'Enter a folder name without path separators',
            );
            return;
          }
          Navigator.pop(context, name);
        },
        child: const Text('Create'),
      ),
    ],
  );
}
