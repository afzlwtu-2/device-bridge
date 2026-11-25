import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'guest_files.dart';
import 'guest_terminal.dart';
import 'ssh_bootstrap.dart';
import 'network_rules.dart';

/// Saved SSH identity and account; secrets live only for this screen/session.
class SshHostScreen extends StatefulWidget {
  const SshHostScreen({
    super.key,
    required this.core,
    this.host,
    this.initialHost,
    this.initialPort = 22,
  });
  final String? initialHost;
  final int initialPort;
  final CoreBridge core;
  final Map<String, dynamic>? host;
  @override
  State<SshHostScreen> createState() => _SshHostScreenState();
}

class _SshHostScreenState extends State<SshHostScreen> {
  late Map<String, dynamic>? _saved = widget.host;
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _pin = TextEditingController();
  final _password = TextEditingController();
  final _passphrase = TextEditingController();
  String _key = '';
  String _transport = 'direct';
  bool _remoteApproved = false;
  NetworkRules _rules = const NetworkRules();
  Map<String, dynamic> _runtime = {};
  Future<void> _loadProviders() async {
    try {
      final rules = await NetworkRules.load(widget.core);
      final runtime = await widget.core.runtimeStatus();
      if (mounted) {
        setState(() {
          _rules = rules;
          _runtime = runtime;
        });
      }
    } catch (_) {}
  }

  String? _error;
  bool _busy = false;
  bool _editing = false;
  Map<String, dynamic>? _linkCheck;
  @override
  void initState() {
    super.initState();
    _host.text = widget.initialHost ?? '';
    _port.text = '${widget.initialPort}';
    _loadProviders();
    final h = _saved;
    if (h != null) {
      _name.text = '${h['name']}';
      _host.text = '${h['host']}';
      _port.text = '${h['port']}';
      _user.text = '${h['user']}';
      _pin.text = '${h['expected_host_key']}';
      _transport = h['transport'] as String? ?? 'auto';
      _remoteApproved = h['remote_approved'] == true;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _host,
      _port,
      _user,
      _pin,
      _password,
      _passphrase,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String> get _credentials => {
    if (_password.text.isNotEmpty) 'password': _password.text,
    if (_key.isNotEmpty) 'private_key_pem': _key,
    if (_passphrase.text.isNotEmpty) 'key_passphrase': _passphrase.text,
  };
  Future<void> _perform(Future<void> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _inspect() => _perform(() async {
    final port = int.tryParse(_port.text);
    if (_host.text.trim().isEmpty || port == null || port < 1 || port > 65535) {
      throw ArgumentError('Enter a host and port from 1 to 65535.');
    }
    final probe = await widget.core.run(
      ['ssh-hosts', 'probe', '-'],
      input: jsonEncode({
        'host': _host.text.trim(),
        'port': port,
        'transport': _transport,
        'remote_approved': _remoteApproved,
      }),
    ) as Map;
    // Inspection does not establish trust. User must independently verify the key.
    final fingerprint =
        '${probe['host_key_sha256'] ?? probe['fingerprint'] ?? probe['host_key'] ?? ''}';
    if (fingerprint.isEmpty) throw StateError('Host returned no fingerprint.');
    if (!mounted) return;
    setState(() => _busy = false);
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verify SSH host key'),
        content: SelectableText(
          '${_host.text.trim()}:$port\n\n$fingerprint\n\nCompare this fingerprint with the host through a trusted source before accepting.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Fingerprint matches'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) setState(() => _pin.text = fingerprint);
  });
  Future<void> _save() => _perform(() async {
    if (_pin.text.trim().isEmpty) {
      throw StateError('Verify the SSH host key first.');
    }
    final result = await widget.core.run(
      ['ssh-hosts', 'save', '-'],
      input: jsonEncode({
        if (_saved != null) 'id': _saved!['id'],
        'transport': _transport,
        'remote_approved': _remoteApproved,
        'version': 1,
        'name': _name.text.trim().isEmpty
            ? _host.text.trim()
            : _name.text.trim(),
        'host': _host.text.trim(),
        'port': int.tryParse(_port.text) ?? 0,
        'user': _user.text.trim(),
        'expected_host_key': _pin.text.trim(),
        ..._credentials,
      }),
    ) as Map;
    if (mounted) {
      setState(() {
        _saved = Map<String, dynamic>.from(result);
        _editing = false;
      });
    }
  });
  Future<void> _checkLinks() => _perform(() async {
    final res = await widget.core.run([
      'ssh-hosts',
      'check',
      '-',
    ], input: jsonEncode({'id': _saved!['id'], ..._credentials})) as Map;
    if (mounted) {
      setState(() => _linkCheck = Map<String, dynamic>.from(res));
    }
  });
  Future<void> _terminal() => _perform(() async {
    final session = await widget.core.run([
      'ssh-hosts',
      'open',
      '-',
    ], input: jsonEncode({'id': _saved!['id'], ..._credentials})) as Map;
    try {
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => GuestTerminalScreen(
            core: widget.core,
            sessionId: session['id'] as String,
            host: '${_saved!['name']}',
            credentials: _credentials,
          ),
        ),
      );
    } finally {
      await widget.core.run(['guest-close', '${session['id']}']);
    }
  });
  Future<void> _associate() => _perform(() async {
    final peers = (await widget.core.run(['peers']) as List)
        .whereType<Map>()
        .where((p) => p['status'] == 'paired')
        .toList();
    if (!mounted) return;
    setState(() => _busy = false);
    final peerId = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Associate SSH with a paired device'),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Choose only if both verified identities belong to the same device. This groups the device once; it does not grant additional access.',
            ),
          ),
          for (final peer in peers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, '${peer['id']}'),
              child: Text('${peer['name']}'),
            ),
          if (_saved?['agent_peer_id'] != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'none'),
              child: const Text('Keep as a separate SSH device'),
            ),
        ],
      ),
    );
    if (peerId == null) return;
    final updated = await widget.core.run([
      'ssh-hosts',
      'associate',
      '${_saved!['id']}',
      peerId,
    ]) as Map;
    if (mounted) setState(() => _saved = Map<String, dynamic>.from(updated));
  });

  Widget _field(
    TextEditingController controller,
    String label, {
    bool secret = false,
    bool readOnly = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      obscureText: secret,
      readOnly: readOnly,
      decoration: InputDecoration(labelText: label),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final saved = _saved;
    return Scaffold(
      appBar: AppBar(
        title: Text(saved == null ? 'Add SSH device' : '${saved['name']}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (saved == null || _editing) ...[
            const Text(
              'Use the device’s LAN address or hostname and verify its SSH host key. Adding it here requires no DeviceBridge agent.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _transport,
              decoration: const InputDecoration(labelText: 'Transport'),
              items: [
                if (_transport == 'auto')
                  const DropdownMenuItem(
                    value: 'auto',
                    child: Text('Automatic'),
                  ),
                for (final choice in [
                  if (_rules.allows('direct') || _transport == 'direct')
                    ('direct', 'Direct TCP'),
                  if (_rules.allows('tailnet') || _transport == 'tailnet')
                    ('tailnet', 'Tailscale — sign-in required'),
                  if (_rules.allows('wireguard') || _transport == 'wireguard')
                    ('wireguard', 'WireGuard — configuration required'),
                  if (_rules.allows('adb') &&
                      (_runtime['usb'] as Map?)?['usb_adb_connected'] == true)
                    ('adb', 'ADB — loopback port mapping'),
                ])
                  DropdownMenuItem(value: choice.$1, child: Text(choice.$2)),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _transport = value!;
                      _pin.clear();
                    }),
            ),
            if (_transport == 'tailnet' || _transport == 'wireguard')
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Allow this SSH connection to use the selected overlay',
                ),
                subtitle: const Text(
                  'The route may use internet or cellular data. This does not approve bulk file transfers.',
                ),
                value: _remoteApproved,
                onChanged: _busy
                    ? null
                    : (value) =>
                          setState(() => _remoteApproved = value == true),
              ),
            const SizedBox(height: 12),
            _field(_name, 'Device name'),
            _field(_host, 'SSH host'),
            _field(_port, 'Port'),
            _field(_user, 'Username'),
            OutlinedButton.icon(
              onPressed: _busy ? null : _inspect,
              icon: const Icon(Icons.verified_user_outlined),
              label: const Text('Verify host key'),
            ),
            _field(_pin, 'Verified fingerprint', readOnly: true),
          ] else ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.terminal),
              title: const Text('SSH device'),
              subtitle: SelectableText(
                '${saved['user']}@${saved['host']}:${saved['port']}\n${saved['expected_host_key']}',
              ),
            ),
            const Text(
              'Credentials are used for this session and are not saved. No agent is required.',
            ),
            Text(
              'Transport: ${switch (saved['transport']) {
                'tailnet' => 'Tailscale',
                'wireguard' => 'WireGuard',
                'adb' => 'ADB tunnel',
                'direct' => 'Direct TCP',
                _ => 'Automatic',
              }}',
            ),
            TextButton.icon(
              onPressed: _busy ? null : () => setState(() => _editing = true),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit connection'),
            ),
            const Text(
              'Transport setup is in Networks → Transports. To change links, connect both devices to the chosen network, then edit and verify the endpoint here. SSH does not require installing an Agent.',
            ),
          ],
          const SizedBox(height: 12),
          _field(_password, 'Password (optional)', secret: true),
          OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () => _perform(() async {
                    final key = await widget.core.pickSshKeyText();
                    if (mounted && key != null) setState(() => _key = key);
                  }),
            icon: const Icon(Icons.key),
            label: Text(_key.isEmpty ? 'Choose SSH key' : 'SSH key selected'),
          ),
          _field(_passphrase, 'Key passphrase (optional)', secret: true),
          if (saved == null || _editing)
            FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Test and save SSH device'),
            )
          else ...[
            FilledButton.icon(
              key: const ValueKey('ssh-host-terminal'),
              onPressed: _busy ? null : _terminal,
              icon: const Icon(Icons.terminal),
              label: const Text('SSH'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => GuestFilesScreen(
                          core: widget.core,
                          initialHost: saved,
                          credentials: _credentials,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.folder_outlined),
              label: const Text('Files (SFTP)'),
            ),
            const Text(
              'Files needs the host’s SFTP subsystem. The SSH terminal works independently.',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('ssh-host-check-links'),
              onPressed: _busy ? null : _checkLinks,
              icon: const Icon(Icons.network_check_outlined),
              label: const Text('Check host & links'),
            ),
            if (_linkCheck != null) ...[
              const SizedBox(height: 8),
              Builder(
                builder: (_) {
                  final os = '${_linkCheck?['os'] ?? 'unknown'}';
                  final ifaces =
                      (_linkCheck?['interfaces'] as List? ?? const [])
                          .whereType<Map>()
                          .toList();
                  final lines = <String>[
                    'Host OS: $os',
                    if (ifaces.isEmpty)
                      'No non-loopback IPv4 interfaces reported.'
                    else
                      for (final iface in ifaces)
                        '${iface['kind'] ?? 'lan'}${('${iface['interface'] ?? ''}').isNotEmpty ? ' (${iface['interface']})' : ''}: ${iface['cidr'] ?? ''}',
                  ];
                  return SelectableText(
                    lines.join('\n'),
                    style: Theme.of(context).textTheme.bodySmall,
                  );
                },
              ),
            ],
            if (_transport == 'adb')
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: SelectableText(
                  'ADB SSH tunnel: run "adb -s <serial> forward tcp:2222 tcp:22" (or tcp:8022 for Termux) on the USB host and point this entry at 127.0.0.1:2222.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: _busy ? null : _associate,
              icon: const Icon(Icons.link),
              label: Text(
                saved['agent_peer_id'] == null
                    ? 'Associate with a paired device'
                    : 'Manage device association',
              ),
            ),
            if (saved['agent_peer_id'] == null)
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        await showDialog<bool>(
                          context: context,
                          builder: (_) => SshBootstrapDialog(
                            core: widget.core,
                            initialHost: '${saved['host']}',
                            initialPort: saved['port'] as int,
                          ),
                        );
                      },
                icon: const Icon(Icons.install_desktop),
                label: const Text('Install DeviceBridge agent'),
              ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _perform(() async {
                      await widget.core.run([
                        'ssh-hosts',
                        'remove',
                        '${saved['id']}',
                      ]);
                      if (mounted) Navigator.pop(this.context);
                    }),
              child: const Text('Remove saved SSH device'),
            ),
          ],
        ],
      ),
    );
  }
}
