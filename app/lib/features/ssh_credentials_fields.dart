import 'package:material_ui/material_ui.dart';

class SshCredentialsFields extends StatefulWidget {
  const SshCredentialsFields({
    super.key,
    required this.password,
    required this.passphrase,
    required this.hasKey,
    required this.chooseKey,
    required this.enabled,
    required this.tailnet,
  });

  final TextEditingController password;
  final TextEditingController passphrase;
  final bool hasKey, enabled, tailnet;
  final VoidCallback chooseKey;

  @override
  State<SshCredentialsFields> createState() => _SshCredentialsFieldsState();
}

class _SshCredentialsFieldsState extends State<SshCredentialsFields> {
  bool? _keyMode;

  @override
  Widget build(BuildContext context) {
    final keyMode = _keyMode ?? widget.hasKey;
    final fields = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Password')),
            ButtonSegment(value: true, label: Text('SSH key')),
          ],
          selected: {keyMode},
          onSelectionChanged: widget.enabled
              ? (selection) => setState(() => _keyMode = selection.single)
              : null,
        ),
        const SizedBox(height: 8),
        if (keyMode) ...[
          OutlinedButton.icon(
            key: const ValueKey('ssh-host-choose-key'),
            onPressed: widget.enabled ? widget.chooseKey : null,
            icon: const Icon(Icons.key),
            label: Text(widget.hasKey ? 'SSH key selected' : 'Choose SSH key'),
          ),
          if (widget.hasKey)
            TextField(
              controller: widget.passphrase,
              enabled: widget.enabled,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Key passphrase'),
            ),
        ] else
          TextField(
            key: const ValueKey('ssh-credential-password'),
            controller: widget.password,
            enabled: widget.enabled,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'SSH password'),
          ),
      ],
    );
    if (!widget.tailnet) return fields;
    return ExpansionTile(
      title: const Text('SSH credentials (optional)'),
      initiallyExpanded: widget.hasKey || widget.password.text.isNotEmpty,
      tilePadding: EdgeInsets.zero,
      children: [fields],
    );
  }
}
