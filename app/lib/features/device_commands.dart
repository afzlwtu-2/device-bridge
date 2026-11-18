import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

class DeviceCommandsSection extends StatefulWidget {
  const DeviceCommandsSection({
    super.key,
    required this.core,
    required this.peer,
    this.defaultHost,
  });

  final CoreBridge core;
  final Map<String, dynamic> peer;
  final String? defaultHost;

  @override
  State<DeviceCommandsSection> createState() => _DeviceCommandsSectionState();
}

class _DeviceCommandsSectionState extends State<DeviceCommandsSection> {
  final _cmdController = TextEditingController();
  List<Map<String, dynamic>> _actions = [];
  bool _loading = true;
  bool _running = false;
  String? _status;
  String? _output;

  // In-memory only SSH session credentials (never persisted to disk).
  String _host = '';
  int _port = 22;
  String _user = '';
  String _password = '';
  String _privateKeyPem = '';
  String _expectedHostKey = '';

  @override
  void initState() {
    super.initState();
    _host = widget.defaultHost ?? '';
    _loadActions();
  }

  @override
  void didUpdateWidget(covariant DeviceCommandsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_host.isEmpty && (widget.defaultHost ?? '').isNotEmpty) {
      _host = widget.defaultHost!;
    }
  }

  @override
  void dispose() {
    _cmdController.dispose();
    super.dispose();
  }

  Future<void> _loadActions() async {
    try {
      final raw = await widget.core.run([
        'peer-actions',
        widget.peer['id'] as String,
      ]);
      if (mounted && raw is List) {
        setState(() {
          _actions = raw
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          if (_host.isEmpty && _actions.isNotEmpty) {
            final savedHost = _actions.first['host'] as String?;
            if (savedHost != null && savedHost.isNotEmpty) {
              _host = savedHost;
            }
          }
        });
      }
    } catch (_) {
      // Optional if not yet supported on older/test cores.
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _saveActions(List<Map<String, dynamic>> next) async {
    try {
      final saved = await widget.core.run(
        ['peer-actions', widget.peer['id'] as String, '-'],
        input: jsonEncode(next),
      );
      if (mounted && saved is List) {
        setState(() {
          _actions = saved
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          _status = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e');
      }
    }
  }

  bool get _hasSessionCreds =>
      _host.isNotEmpty &&
      _user.isNotEmpty &&
      _expectedHostKey.isNotEmpty &&
      (_password.isNotEmpty || _privateKeyPem.isNotEmpty);

  Future<bool> _configureSsh() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _SshSessionDialog(
        core: widget.core,
        initialHost: _host.isNotEmpty ? _host : (widget.defaultHost ?? ''),
        initialPort: _port,
        initialUser: _user,
        initialPassword: _password,
        initialPrivateKeyPem: _privateKeyPem,
        initialHostKey: _expectedHostKey,
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _host = result['host'] as String;
        _port = result['port'] as int;
        _user = result['user'] as String;
        _password = result['password'] as String;
        _privateKeyPem = result['privateKeyPem'] as String;
        _expectedHostKey = result['expectedHostKey'] as String;
      });
      return true;
    }
    return false;
  }

  Future<bool> _execRemote(String command) async {
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    if (!_hasSessionCreds) {
      final ready = await _configureSsh();
      if (!ready) {
        return false;
      }
    }
    setState(() {
      _running = true;
      _status = null;
      _output = null;
    });
    try {
      final res = await widget.core.run(
        ['ssh-run', '-'],
        input: jsonEncode({
          'host': _host,
          'port': _port,
          'user': _user,
          if (_password.isNotEmpty) 'password': _password,
          if (_privateKeyPem.isNotEmpty) 'private_key_pem': _privateKeyPem,
          'expected_host_key': _expectedHostKey,
          'command': trimmed,
        }),
      ) as Map;
      final code = res['exit_code'] as int? ?? 0;
      final stdoutText = '${res['stdout'] ?? ''}'.trim();
      final stderrText = '${res['stderr'] ?? ''}'.trim();
      final buf = StringBuffer('Exit $code · $_user@$_host:$_port');
      if (stdoutText.isNotEmpty) {
        buf.write('\n$stdoutText');
      }
      if (stderrText.isNotEmpty) {
        buf.write('\n[stderr] $stderrText');
      }
      if (mounted) {
        setState(() => _output = buf.toString());
      }
      return code == 0;
    } catch (e) {
      if (mounted) {
        setState(() => _status = '$e');
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  Future<void> _addActionDialog({required String kind}) async {
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _ActionEditorDialog(
        kind: kind,
        host: _host,
        port: _port,
        user: _user,
      ),
    );
    if (created != null) {
      await _saveActions([..._actions, created]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final toggles = _actions.where((a) => a['kind'] == 'toggle').toList();
    final quickCmds = _actions.where((a) => a['kind'] == 'command').toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Toggles & target commands',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: _running ? null : _configureSsh,
                  child: Text(_hasSessionCreds ? 'SSH ready' : 'SSH setup'),
                ),
              ],
            ),
            const Text(
              'Runs over user-authorized SSH (host key verified; credentials kept in memory only).',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _running ? null : () => _addActionDialog(kind: 'toggle'),
                  icon: const Icon(Icons.toggle_on_outlined),
                  label: const Text('Create toggle'),
                ),
                OutlinedButton.icon(
                  onPressed: _running ? null : () => _addActionDialog(kind: 'command'),
                  icon: const Icon(Icons.terminal),
                  label: const Text('Add command'),
                ),
              ],
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
            for (final t in toggles) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${t['label']}'),
                subtitle: Text(
                  'ON: ${t['command']}\nOFF: ${t['off_command']}',
                  style: const TextStyle(fontSize: 12),
                ),
                value: t['active'] == true,
                onChanged: _running
                    ? null
                    : (nextVal) async {
                        final cmd = nextVal
                            ? '${t['command']}'
                            : '${t['off_command']}';
                        final ok = await _execRemote(cmd);
                        if (ok) {
                          final updated = _actions
                              .map(
                                (a) => a['id'] == t['id']
                                    ? {...a, 'active': nextVal}
                                    : a,
                              )
                              .toList();
                          await _saveActions(updated);
                        }
                      },
                secondary: IconButton(
                  tooltip: 'Delete toggle',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _running
                      ? null
                      : () => _saveActions(
                          _actions.where((a) => a['id'] != t['id']).toList(),
                        ),
                ),
              ),
            ],
            if (quickCmds.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in quickCmds)
                    InputChip(
                      avatar: const Icon(Icons.play_arrow, size: 18),
                      label: Text('${c['label']}'),
                      tooltip: '${c['command']}',
                      onPressed: _running
                          ? null
                          : () => _execRemote('${c['command']}'),
                      onDeleted: _running
                          ? null
                          : () => _saveActions(
                              _actions
                                  .where((a) => a['id'] != c['id'])
                                  .toList(),
                            ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _cmdController,
                    decoration: const InputDecoration(
                      labelText: 'Run command on target',
                      hintText: 'e.g. hostname && df -h',
                    ),
                    onSubmitted: _running
                        ? null
                        : (v) => _execRemote(v),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _running
                      ? null
                      : () => _execRemote(_cmdController.text),
                  child: Text(_running ? 'Running…' : 'Run'),
                ),
              ],
            ),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(
                _status!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
            if (_output != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  _output!,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SshSessionDialog extends StatefulWidget {
  const _SshSessionDialog({
    required this.core,
    required this.initialHost,
    required this.initialPort,
    required this.initialUser,
    required this.initialPassword,
    required this.initialPrivateKeyPem,
    required this.initialHostKey,
  });

  final CoreBridge core;
  final String initialHost;
  final int initialPort;
  final String initialUser;
  final String initialPassword;
  final String initialPrivateKeyPem;
  final String initialHostKey;

  @override
  State<_SshSessionDialog> createState() => _SshSessionDialogState();
}

class _SshSessionDialogState extends State<_SshSessionDialog> {
  late final TextEditingController hostCtrl;
  late final TextEditingController portCtrl;
  late final TextEditingController userCtrl;
  late final TextEditingController passCtrl;
  late final TextEditingController keyCtrl;
  late String fp;
  String? err;
  bool probing = false;

  @override
  void initState() {
    super.initState();
    hostCtrl = TextEditingController(text: widget.initialHost);
    portCtrl = TextEditingController(text: '${widget.initialPort}');
    userCtrl = TextEditingController(text: widget.initialUser);
    passCtrl = TextEditingController(text: widget.initialPassword);
    keyCtrl = TextEditingController(text: widget.initialPrivateKeyPem);
    fp = widget.initialHostKey;
  }

  @override
  void dispose() {
    hostCtrl.dispose();
    portCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
    keyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('SSH target session'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Credentials stay in memory for this screen only and are never saved to disk.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: hostCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Host / LAN / Tailscale IP',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: portCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    fp.isEmpty
                        ? 'Verify SSH host fingerprint before running'
                        : 'Host key: $fp',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: probing
                      ? null
                      : () async {
                          setState(() {
                            probing = true;
                            err = null;
                          });
                          try {
                            final res = await widget.core.run([
                              'ssh-probe',
                              hostCtrl.text.trim(),
                              portCtrl.text.trim().isEmpty
                                  ? '22'
                                  : portCtrl.text.trim(),
                            ]) as Map;
                            if (mounted) {
                              setState(
                                () =>
                                    fp = res['host_key_sha256'] as String? ?? '',
                              );
                            }
                          } catch (e) {
                            if (mounted) {
                              setState(() => err = '$e');
                            }
                          } finally {
                            if (mounted) {
                              setState(() => probing = false);
                            }
                          }
                        },
                  child: Text(probing ? 'Probing…' : 'Probe key'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: userCtrl,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password (optional if key set)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: keyCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Private key PEM (optional)',
              ),
            ),
            if (err != null) ...[
              const SizedBox(height: 8),
              Text(
                err!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ],
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
          if (hostCtrl.text.trim().isEmpty ||
              userCtrl.text.trim().isEmpty ||
              fp.isEmpty ||
              (passCtrl.text.isEmpty && keyCtrl.text.trim().isEmpty)) {
            setState(
              () => err =
                  'Host, verified host key fingerprint, username, and password or key are required.',
            );
            return;
          }
          Navigator.pop(context, {
            'host': hostCtrl.text.trim(),
            'port': int.tryParse(portCtrl.text.trim()) ?? 22,
            'user': userCtrl.text.trim(),
            'password': passCtrl.text,
            'privateKeyPem': keyCtrl.text.trim(),
            'expectedHostKey': fp,
          });
        },
        child: const Text('Use session'),
      ),
    ],
  );
}

class _ActionEditorDialog extends StatefulWidget {
  const _ActionEditorDialog({
    required this.kind,
    required this.host,
    required this.port,
    required this.user,
  });

  final String kind;
  final String host;
  final int port;
  final String user;

  @override
  State<_ActionEditorDialog> createState() => _ActionEditorDialogState();
}

class _ActionEditorDialogState extends State<_ActionEditorDialog> {
  final labelCtrl = TextEditingController();
  final cmdCtrl = TextEditingController();
  final offCtrl = TextEditingController();
  String? err;

  @override
  void dispose() {
    labelCtrl.dispose();
    cmdCtrl.dispose();
    offCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isToggle = widget.kind == 'toggle';
    return AlertDialog(
      title: Text(isToggle ? 'Create target toggle' : 'Add quick command'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: labelCtrl,
                decoration: InputDecoration(
                  labelText: 'Label',
                  hintText: isToggle ? 'Bridge Agent' : 'System uptime',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: cmdCtrl,
                decoration: InputDecoration(
                  labelText: isToggle ? 'Enable (ON) command' : 'Command',
                  hintText: isToggle
                      ? 'systemctl --user start devicebridge-agent'
                      : 'uptime -p',
                ),
              ),
              if (isToggle) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: offCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Disable (OFF) command',
                    hintText: 'systemctl --user stop devicebridge-agent',
                  ),
                ),
              ],
              if (err != null) ...[
                const SizedBox(height: 8),
                Text(
                  err!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
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
            final l = labelCtrl.text.trim();
            final c = cmdCtrl.text.trim();
            final off = offCtrl.text.trim();
            if (l.isEmpty || c.isEmpty || (isToggle && off.isEmpty)) {
              setState(() => err = 'Fill in label and command fields.');
              return;
            }
            Navigator.pop(context, {
              'id': '${DateTime.now().microsecondsSinceEpoch}',
              'label': l,
              'kind': widget.kind,
              'command': c,
              if (isToggle) 'off_command': off,
              'active': false,
              if (widget.host.isNotEmpty) 'host': widget.host,
              'port': widget.port,
              if (widget.user.isNotEmpty) 'user': widget.user,
            });
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
