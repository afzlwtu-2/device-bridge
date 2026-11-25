import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'guest_terminal.dart';

class GuestFilesScreen extends StatefulWidget {
  const GuestFilesScreen({
    super.key,
    required this.core,
    this.initialHost,
    this.credentials = const {},
  });
  final Map<String, dynamic>? initialHost;
  final Map<String, String> credentials;

  final CoreBridge core;

  @override
  State<GuestFilesScreen> createState() => _GuestFilesScreenState();
}

class _GuestFilesScreenState extends State<GuestFilesScreen> {
  final _form = GlobalKey<FormState>();
  String _host = '', _user = '', _pin = '', _root = '', _port = '22';
  String _password = '', _key = '', _passphrase = '';
  String _path = '.';
  String? _message, _download;
  bool _busy = false;
  Map<String, dynamic>? _session;
  List<Map> _entries = [];

  @override
  void initState() {
    super.initState();
    final h = widget.initialHost;
    if (h != null) {
      _host = '${h['host']}';
      _port = '${h['port']}';
      _user = '${h['user']}';
      _pin = '${h['expected_host_key']}';
    }
    _password = widget.credentials['password'] ?? '';
    _key = widget.credentials['private_key_pem'] ?? '';
    _passphrase = widget.credentials['key_passphrase'] ?? '';
  }

  @override
  void dispose() {
    if (_session?['id'] case final String id) {
      unawaited(
        widget.core
            .run(['guest-close', id])
            .then<void>((_) {}, onError: (_, _) {}),
      );
    }
    super.dispose();
  }

  Map<String, String> get _credentials => {
    if (_password.isNotEmpty) 'password': _password,
    if (_key.trim().isNotEmpty) 'private_key_pem': _key,
    if (_passphrase.isNotEmpty) 'key_passphrase': _passphrase,
  };

  Future<void> _operate(Future<void> Function() operation) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await operation();
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() async {
    if (!_form.currentState!.validate()) return;
    await _operate(() async {
      final response = await widget.core.run(
        ['guest-open', '-'],
        input: jsonEncode({
          ..._credentials,
          'host': _host,
          if (widget.initialHost?['transport'] != null)
            'transport': widget.initialHost!['transport'],
          if (widget.initialHost?['remote_approved'] != null)
            'remote_approved': widget.initialHost!['remote_approved'],
          'port': int.parse(_port),
          'user': _user,
          'root': _root,
          'expected_host_key': _pin,
        }),
      ) as Map;
      if (!mounted) {
        await widget.core.run(['guest-close', response['id'] as String]);
        return;
      }
      setState(() => _session = Map<String, dynamic>.from(response));
      await _list('.');
    });
  }

  Future<void> _list(String path) async {
    final id = _session?['id'];
    if (id == null) return;
    final rows = await widget.core.run([
      'guest-list',
      '-',
    ], input: jsonEncode({..._credentials, 'id': id, 'path': path})) as List;
    if (mounted) {
      setState(() {
        _path = path;
        _entries = rows.whereType<Map>().toList();
      });
    }
  }

  Future<void> _pull(Map entry) => _operate(() async {
    final id = _session?['id'];
    if (id == null) return;
    final saved = await widget.core.run(
      ['guest-pull', '-'],
      input: jsonEncode({..._credentials, 'id': id, 'path': entry['path']}),
    ) as Map;
    if (mounted) {
      setState(() {
        _download = saved['destination'] as String?;
        final name = entry['name'];
        _message = 'Downloaded $name · XXH64 ${saved['xxh64']}.';
      });
    }
  });

  Future<void> _close() => _operate(() async {
    final id = _session?['id'];
    if (id == null) return;
    await widget.core.run(['guest-close', id as String]);
    if (mounted) {
      setState(() {
        _session = null;
        _entries = [];
        _path = '.';
        _password = _key = _passphrase = '';
        _download = null;
      });
    }
  });

  Future<void> _openTerminal(
    LocalCore core,
    Map<String, dynamic> session,
  ) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Open SSH shell'),
        content: const Text(
          'The shell uses the SSH account’s permissions. Closing it revokes the session.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow this session'),
          ),
        ],
      ),
    );
    if (approved == true && mounted) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => GuestTerminalScreen(
            core: core,
            sessionId: session['id'] as String,
            host: session['host'] as String,
            credentials: _credentials,
          ),
        ),
      );
    }
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;

  Widget _login() => Form(
    key: _form,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextFormField(
          initialValue: _host,
          decoration: const InputDecoration(labelText: 'SSH host'),
          validator: _required,
          onChanged: (value) => _host = value.trim(),
        ),
        TextFormField(
          initialValue: _port,
          decoration: const InputDecoration(labelText: 'Port'),
          keyboardType: TextInputType.number,
          validator: (value) {
            final port = int.tryParse(value?.trim() ?? '');
            return port != null && port > 0 && port < 65536
                ? null
                : 'Enter a port from 1 to 65535.';
          },
          onChanged: (value) => _port = value.trim(),
        ),
        TextFormField(
          initialValue: _user,
          decoration: const InputDecoration(labelText: 'SSH username'),
          validator: _required,
          onChanged: (value) => _user = value.trim(),
        ),
        TextFormField(
          initialValue: _pin,
          decoration: const InputDecoration(
            labelText: 'Verified host fingerprint',
            hintText: 'SHA256:…',
            helperText: 'Get this fingerprint from the server owner.',
          ),
          validator: (value) => (value?.trim().startsWith('SHA256:') ?? false)
              ? null
              : 'Enter the verified SHA256 fingerprint.',
          onChanged: (value) => _pin = value.trim(),
        ),
        TextFormField(
          initialValue: _root,
          decoration: const InputDecoration(
            labelText: 'Starting folder',
            hintText: 'SSH home folder',
          ),
          onChanged: (value) => _root = value.trim(),
        ),
        TextFormField(
          obscureText: true,
          decoration: const InputDecoration(labelText: 'SSH password'),
          onChanged: (value) => _password = value,
        ),
        ExpansionTile(
          title: const Text('Use a private key'),
          children: [
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _operate(() async {
                      final selected = await widget.core.pickSshKeyText();
                      if (selected != null && mounted) {
                        setState(() => _key = selected);
                      }
                    }),
              icon: const Icon(Icons.key),
              label: Text(_key.isEmpty ? 'Choose key file' : 'Key selected'),
            ),
            TextFormField(
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Key passphrase'),
              onChanged: (value) => _passphrase = value,
            ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _open,
          child: const Text('Connect SFTP'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Files (SFTP)'),
        actions: [
          if (_busy)
            IconButton(
              tooltip: 'Cancel file operation',
              onPressed: widget.core.cancel,
              icon: const Icon(Icons.stop_outlined),
            ),
          if (session != null)
            TextButton(
              onPressed: _busy ? null : _close,
              child: const Text('Close session'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_message case final message?)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(message),
            ),
          if (_download case final source?)
            if (Platform.isAndroid)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _operate(() async {
                          final saved = await widget.core.saveDownload(source);
                          if (mounted && saved != null) {
                            setState(() => _message = 'Saved file.');
                          }
                        }),
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Save to device'),
                ),
              ),
          if (session == null)
            _login()
          else ...[
            Text(
              '${session['user']}@${session['host']}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              _path == '.' ? '${session['root']}' : '${session['root']}/$_path',
            ),
            if (widget.core case final LocalCore local)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : () => _openTerminal(local, session),
                  icon: const Icon(Icons.terminal),
                  label: const Text('Open SSH shell'),
                ),
              ),
            if (_path != '.')
              ListTile(
                leading: const Icon(Icons.arrow_upward),
                title: const Text('Parent folder'),
                onTap: _busy
                    ? null
                    : () => _operate(() {
                        final split = _path.lastIndexOf('/');
                        return _list(
                          split < 0 ? '.' : _path.substring(0, split),
                        );
                      }),
              ),
            for (final entry in _entries)
              ListTile(
                leading: Icon(
                  entry['kind'] == 'directory'
                      ? Icons.folder_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text('${entry['name']}'),
                subtitle: entry['kind'] == 'file'
                    ? Text('${entry['size']} bytes')
                    : null,
                trailing: entry['kind'] == 'file'
                    ? const Icon(Icons.download_outlined)
                    : null,
                onTap: _busy
                    ? null
                    : () {
                        if (entry['kind'] == 'directory') {
                          unawaited(
                            _operate(() => _list(entry['path'] as String)),
                          );
                        } else {
                          unawaited(_pull(entry));
                        }
                      },
              ),
          ],
        ],
      ),
    );
  }
}
