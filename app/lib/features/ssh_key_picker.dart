import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

/// Lets the user pick an SSH private key from Termux ~/.ssh, Termux Home, or Android/device storage.
Future<String?> pickSshPrivateKey(BuildContext context, CoreBridge core) async {
  List<Map<String, String>> sshKeys = const [];
  try {
    sshKeys = await core.listSshKeys();
  } catch (_) {}
  if (!context.mounted) return null;

  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => _SshKeyPickerDialog(core: core, sshKeys: sshKeys),
  );
  return choice;
}

class _SshKeyPickerDialog extends StatefulWidget {
  const _SshKeyPickerDialog({required this.core, required this.sshKeys});

  final CoreBridge core;
  final List<Map<String, String>> sshKeys;

  @override
  State<_SshKeyPickerDialog> createState() => _SshKeyPickerDialogState();
}

class _SshKeyPickerDialogState extends State<_SshKeyPickerDialog> {
  bool _browsingTermuxHome = false;
  String _path = '';
  List<Map<String, dynamic>> _entries = const [];
  bool _busy = false;
  String? _error;

  Future<void> _loadTermuxFolder(String path) async {
    setState(() {
      _browsingTermuxHome = true;
      _busy = true;
      _error = null;
      _path = path;
    });
    try {
      final resp = await widget.core.localFiles('list', {
        'kind': Platform.isAndroid ? 'termux_home' : 'home',
        'path': path,
        'next': '',
      }) as Map;
      final list = (resp['entries'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      if (mounted) {
        setState(() {
          _entries = list;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  Future<void> _selectKeyRef(Map<String, String> ref) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pem = await widget.core.readSshKey(ref);
      if (!mounted) return;
      if (pem == null || pem.trim().isEmpty) {
        setState(() {
          _busy = false;
          _error = 'Selected key file is empty or unreadable.';
        });
        return;
      }
      Navigator.of(context).pop(pem.trim());
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _browseSystemPicker() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pem = await widget.core.pickSshKeyText();
      if (!mounted) return;
      if (pem != null && pem.trim().isNotEmpty) {
        Navigator.of(context).pop(pem.trim());
      } else {
        setState(() => _busy = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final homeLabel = Platform.isAndroid ? 'Termux Home' : 'Home folder';
    return AlertDialog(
      key: const ValueKey('ssh-key-picker-dialog'),
      title: Text(
        _browsingTermuxHome ? '$homeLabel/${_path.isEmpty ? '' : _path}' : 'Choose SSH private key',
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (!_browsingTermuxHome) ...[
                Text(
                  Platform.isAndroid
                      ? 'Keys in Termux ~/.ssh'
                      : 'Keys in ~/.ssh',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 6),
                if (widget.sshKeys.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text('No private keys found in ~/.ssh yet.'),
                  )
                else
                  for (final key in widget.sshKeys)
                    ListTile(
                      key: ValueKey('ssh-key-item-${key['name']}'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.vpn_key_outlined),
                      title: Text(key['name'] ?? key['path'] ?? 'key'),
                      subtitle: key['path'] != null ? Text(key['path']!) : null,
                      onTap: _busy ? null : () => _selectKeyRef(key),
                    ),
                const Divider(),
                ListTile(
                  key: const ValueKey('ssh-key-browse-termux'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.terminal_outlined),
                  title: Text('Browse $homeLabel'),
                  subtitle: const Text('Pick any key file inside Termux storage'),
                  onTap: _busy ? null : () => _loadTermuxFolder(''),
                ),
                ListTile(
                  key: const ValueKey('ssh-key-browse-device'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_open_outlined),
                  title: const Text('Browse device storage'),
                  subtitle: const Text('Open Android / system file picker'),
                  onTap: _busy ? null : _browseSystemPicker,
                ),
              ] else ...[
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () {
                              if (_path.isEmpty) {
                                setState(() => _browsingTermuxHome = false);
                              } else {
                                final idx = _path.lastIndexOf('/');
                                _loadTermuxFolder(
                                  idx < 0 ? '' : _path.substring(0, idx),
                                );
                              }
                            },
                      icon: const Icon(Icons.arrow_upward, size: 16),
                      label: Text(_path.isEmpty ? 'Back' : 'Up'),
                    ),
                  ],
                ),
                for (final entry in _entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      entry['kind'] == 'directory'
                          ? Icons.folder_outlined
                          : Icons.description_outlined,
                    ),
                    title: Text('${entry['name'] ?? ''}'),
                    onTap: _busy
                        ? null
                        : () {
                            final rel = '${entry['path'] ?? entry['name'] ?? ''}';
                            if (entry['kind'] == 'directory') {
                              _loadTermuxFolder(rel);
                            } else {
                              _selectKeyRef({
                                'name': '${entry['name'] ?? rel}',
                                'path': rel,
                              });
                            }
                          },
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
