import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

class QuickShare extends StatefulWidget {
  const QuickShare({
    super.key,
    required this.core,
    required this.peers,
    this.sharedDraft,
    this.onDraftAccepted,
  });

  final CoreBridge core;
  final List<dynamic> peers;
  final Map<String, dynamic>? sharedDraft;
  final ValueChanged<Map<String, dynamic>>? onDraftAccepted;

  @override
  State<QuickShare> createState() => _QuickShareState();
}

class _QuickShareState extends State<QuickShare> {
  static const _textLimit = 4096;
  static const _fileLimit = 64 * 1024 * 1024;
  final _draft = TextEditingController();
  List<dynamic> _inbox = [];
  List<dynamic> _receivedFiles = [];
  Map<String, dynamic>? _file;
  StreamSubscription<Map<String, dynamic>>? _progressEvents;
  double? _upload;
  String? _peerId, _messageId, _status;
  bool? _allowedText, _allowedFiles;
  bool _loading = true,
      _sending = false,
      _permissionBusy = false,
      _fileMode = false,
      _picking = false,
      _saving = false;

  List<Map> get _paired => widget.peers
      .whereType<Map>()
      .where((peer) => peer['status'] == 'paired')
      .toList();

  @override
  void initState() {
    super.initState();
    _peerId = _paired.firstOrNull?['id'] as String?;
    _acceptDraft();
    unawaited(_refresh());
  }

  @override
  void didUpdateWidget(QuickShare oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.sharedDraft, oldWidget.sharedDraft)) _acceptDraft();
    if (!_paired.any((peer) => peer['id'] == _peerId)) {
      _peerId = _paired.firstOrNull?['id'] as String?;
      _messageId = null;
      _allowedText = _allowedFiles = null;
      unawaited(_readAccess());
    }
  }

  void _acceptDraft() {
    final shared = widget.sharedDraft;
    if (shared == null) return;
    if (shared['text'] case final String text) {
      _fileMode = false;
      _draft.text = text;
      _messageId = null;
    } else if (shared['file'] case final Map file) {
      _fileMode = true;
      _file = Map<String, dynamic>.from(file);
      _status = null;
    } else if (shared['error'] case final String error) {
      _status = error;
    }
    final accepted = widget.onDraftAccepted;
    WidgetsBinding.instance.addPostFrameCallback((_) => accepted?.call(shared));
  }

  @override
  void dispose() {
    unawaited(_progressEvents?.cancel());
    _draft.dispose();
    super.dispose();
  }

  String _friendly(Object error) {
    final message = error.toString();
    if (message.contains('text_sharing_not_allowed')) {
      return 'The receiving device needs to allow text from this device.';
    }
    if (message.contains('file_sharing_not_allowed')) {
      return 'The receiving device needs to allow files from this device.';
    }
    if (message.contains('shared_file_already_exists')) {
      return 'An item with that name is already in the receiving inbox.';
    }
    return message;
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final inbox = await widget.core.run(['share-inbox']) as List;
      final files = await widget.core.run(['share-files']) as List;
      if (mounted) {
        setState(() {
          _inbox = inbox;
          _receivedFiles = files;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _status = _friendly(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    await _readAccess();
  }

  Future<void> _readAccess() async {
    final peer = _peerId;
    if (peer == null) return;
    try {
      final text = await widget.core.run(['share-text-access', peer]) as Map;
      final files = await widget.core.run(['share-file-access', peer]) as Map;
      if (mounted && peer == _peerId) {
        setState(() {
          _allowedText = text['allowed'] == true;
          _allowedFiles = files['allowed'] == true;
        });
      }
    } catch (error) {
      if (mounted && peer == _peerId) {
        setState(() => _status = _friendly(error));
      }
    }
  }

  Future<void> _changeAccess(bool value, {required bool files}) async {
    final peer = _peerId;
    if (peer == null) return;
    setState(() => _permissionBusy = true);
    try {
      final result = await widget.core.run([
        files ? 'share-file-access' : 'share-text-access',
        peer,
        value ? 'allow' : 'deny',
      ]) as Map;
      if (mounted && peer == _peerId) {
        setState(() {
          if (files) {
            _allowedFiles = result['allowed'] == true;
          } else {
            _allowedText = result['allowed'] == true;
          }
        });
      }
    } catch (error) {
      if (mounted) setState(() => _status = _friendly(error));
    } finally {
      if (mounted) setState(() => _permissionBusy = false);
    }
  }

  String _newMessageId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> _send() async {
    final peer = _peerId;
    final text = _draft.text;
    if (peer == null ||
        text.trim().isEmpty ||
        utf8.encode(text).length > _textLimit) {
      return;
    }
    final id = _messageId ??= _newMessageId();
    setState(() {
      _sending = true;
      _status = null;
    });
    try {
      await widget.core.run([
        'send-text',
        peer,
        '-',
      ], input: jsonEncode({'id': id, 'text': text}));
      if (!mounted) return;
      _draft.clear();
      setState(() {
        _messageId = null;
        _status = 'Text delivered.';
      });
    } catch (error) {
      if (mounted) setState(() => _status = _friendly(error));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!mounted || text == null) return;
    setState(() {
      _draft.text = text;
      _messageId = null;
    });
  }

  Future<void> _pickFile({bool directory = false}) async {
    setState(() => _picking = true);
    try {
      final file = await widget.core.pickShareFile(directory: directory);
      if (!mounted || file == null) return;
      if (!directory && (file['size'] as num? ?? 0) > _fileLimit) {
        throw StateError('Choose a file up to 64 MiB.');
      }
      setState(() {
        _file = file;
        _status = null;
      });
    } catch (error) {
      if (mounted) setState(() => _status = _friendly(error));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _sendFile() async {
    final peer = _peerId;
    final file = _file;
    if (peer == null || file == null) return;
    setState(() {
      _sending = true;
      _upload = null;
      _status = null;
    });
    _progressEvents = widget.core.transferProgress.listen((progress) {
      if (!mounted || progress['sent_bytes'] is! num) return;
      final sent = progress['sent_bytes'] as num;
      final total = progress['total_bytes'] as num? ?? 0;
      setState(() => _upload = total > 0 ? (sent / total).clamp(0.0, 1.0) : 1);
    });
    try {
      final receipt = await widget.core.sendShareFile(peer, file);
      if (mounted) {
        setState(() {
          if (identical(_file, file)) _file = null;
          final count = receipt['files'];
          _status = file['directory'] == true
              ? 'Folder delivered and verified. $count ${count == 1 ? 'file' : 'files'}.'
              : 'File delivered and verified. XXH64 ${receipt['xxh64']}.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _status = _friendly(error));
    } finally {
      unawaited(_progressEvents?.cancel());
      _progressEvents = null;
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _saveReceived(String name) async {
    setState(() => _saving = true);
    try {
      final location = await widget.core.saveSharedFile(name);
      if (mounted && location != null) setState(() => _status = 'Saved $name.');
    } catch (error) {
      if (mounted) setState(() => _status = _friendly(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    final bytes = utf8.encode(_draft.text).length;
    final busy = _sending || _permissionBusy || _loading || _picking || _saving;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Quick Share', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (_paired.isEmpty)
          const Text('Pair a device to share text or files.')
        else ...[
          DropdownButtonFormField<String>(
            initialValue: _peerId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'To'),
            items: [
              for (final peer in _paired)
                DropdownMenuItem(
                  value: peer['id'] as String,
                  child: Text('${peer['name']}'),
                ),
            ],
            onChanged: busy
                ? null
                : (peer) {
                    setState(() {
                      _peerId = peer;
                      _messageId = null;
                      _allowedText = _allowedFiles = null;
                    });
                    unawaited(_readAccess());
                  },
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Text')),
              ButtonSegment(value: true, label: Text('Files & folders')),
            ],
            selected: {_fileMode},
            onSelectionChanged: busy
                ? null
                : (values) => setState(() => _fileMode = values.first),
          ),
          const SizedBox(height: 12),
          if (_fileMode) ...[
            if (_file case final file?)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  file['directory'] == true
                      ? Icons.folder_outlined
                      : Icons.insert_drive_file_outlined,
                ),
                title: Text('${file['name']}'),
                subtitle: file['size'] == null
                    ? null
                    : Text('${file['size']} bytes'),
                trailing: IconButton(
                  tooltip: 'Remove attachment',
                  onPressed: busy ? null : () => setState(() => _file = null),
                  icon: const Icon(Icons.close),
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : _pickFile,
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Choose file'),
                ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _pickFile(directory: true),
                  icon: const Icon(Icons.folder_open_outlined),
                  label: const Text('Choose folder'),
                ),
                FilledButton.icon(
                  onPressed: busy || _file == null ? null : _sendFile,
                  icon: const Icon(Icons.send_outlined),
                  label: Text(
                    _file?['directory'] == true ? 'Send folder' : 'Send file',
                  ),
                ),
              ],
            ),
            if (_sending) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _upload),
              Text(
                _upload == 1
                    ? 'Waiting for verification…'
                    : 'Preparing or sending…',
              ),
              TextButton(
                onPressed: widget.core.cancel,
                child: const Text('Cancel transfer'),
              ),
            ],
          ] else ...[
            TextField(
              controller: _draft,
              readOnly: _sending,
              minLines: 3,
              maxLines: 8,
              decoration: InputDecoration(
                labelText: 'Message',
                errorText: bytes > _textLimit ? 'Limit: 4 KiB of text' : null,
              ),
              onChanged: (_) => setState(() => _messageId = null),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : _paste,
                  icon: const Icon(Icons.content_paste),
                  label: const Text('Paste'),
                ),
                FilledButton.icon(
                  onPressed:
                      busy || _draft.text.trim().isEmpty || bytes > _textLimit
                      ? null
                      : _send,
                  icon: const Icon(Icons.send_outlined),
                  label: const Text('Send'),
                ),
              ],
            ),
          ],
          if (_allowedText case final allowed?)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Accept text from this device'),
              value: allowed,
              onChanged: busy
                  ? null
                  : (value) => _changeAccess(value, files: false),
            ),
          if (_allowedFiles case final allowed?)
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Accept files from this device'),
              value: allowed,
              onChanged: busy
                  ? null
                  : (value) => _changeAccess(value, files: true),
            ),
        ],
        if (_status case final status?)
          Padding(padding: const EdgeInsets.only(top: 10), child: Text(status)),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Text(
                'Inbox',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'Refresh inbox',
              onPressed: busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_loading) const LinearProgressIndicator(),
        if (_inbox.isEmpty && _receivedFiles.isEmpty && !_loading)
          const Text('Nothing received.'),
        for (final file in _receivedFiles.whereType<Map>())
          Card(
            child: ListTile(
              leading: Icon(
                file['directory'] == true
                    ? Icons.folder_outlined
                    : Icons.insert_drive_file_outlined,
              ),
              title: Text('${file['name']}'),
              subtitle: Text(
                file['directory'] == true ? 'Folder' : '${file['size']} bytes',
              ),
              trailing: TextButton(
                onPressed: busy ? null : () => _saveReceived('${file['name']}'),
                child: Text(Platform.isAndroid ? 'Save' : 'Open folder'),
              ),
            ),
          ),
        for (final item in _inbox.whereType<Map>())
          Card(
            child: ListTile(
              title: Text('${item['peer_name'] ?? 'Paired device'}'),
              subtitle: SelectableText('${item['text'] ?? ''}'),
              trailing: IconButton(
                tooltip: 'Copy text',
                icon: const Icon(Icons.copy_outlined),
                onPressed: () => _copy('${item['text'] ?? ''}'),
              ),
            ),
          ),
      ],
    );
  }
}
