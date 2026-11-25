import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:xterm3/xterm.dart';

import '../core/bridge.dart';

class GuestTerminalScreen extends StatefulWidget {
  const GuestTerminalScreen({
    super.key,
    required this.core,
    required this.sessionId,
    required this.host,
    required this.credentials,
    this.agentMode = false,
    this.peerId,
    this.endpoint,
    this.transport,
  });

  final CoreBridge core;
  final String sessionId;
  final String host;
  final Map<String, String> credentials;
  final bool agentMode;
  final String? peerId;
  final String? endpoint;
  final String? transport;

  @override
  State<GuestTerminalScreen> createState() => _GuestTerminalScreenState();
}

class _GuestTerminalScreenState extends State<GuestTerminalScreen> {
  final _terminal = Terminal(
    maxLines: 1000,
    allowRemoteResize: false,
    onClipboardQuery: (_) => null,
    onClipboardStore: (_, _) {},
  );
  final _rawOutput = StreamController<List<int>>();
  GuestTerminalLink? _link;
  StreamSubscription<String>? _frames;
  StreamSubscription<String>? _text;
  bool _ready = false;
  String _status = 'Connecting…';

  @override
  void initState() {
    super.initState();
    _text = _rawOutput.stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_terminal.write);
    _terminal.onOutput = _input;
    _terminal.onResize = (columns, rows, _, _) {
      unawaited(_send({'columns': columns, 'rows': rows}));
    };
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final GuestTerminalLink link;
      if (widget.agentMode) {
        link = await widget.core.openAgentTerminal({
          'peer_id': widget.peerId ?? '',
          if ((widget.endpoint ?? '').isNotEmpty) 'endpoint': widget.endpoint,
          if ((widget.transport ?? '').isNotEmpty)
            'transport': widget.transport,
          'columns': _terminal.viewWidth,
          'rows': _terminal.viewHeight,
        });
      } else {
        final localCore = widget.core as LocalCore;
        await localCore.run(['guest-terminal-approve', widget.sessionId]);
        if (!mounted) {
          await localCore.run(['guest-terminal-revoke', widget.sessionId]);
          return;
        }
        link = await localCore.openGuestTerminal({
          ...widget.credentials,
          'id': widget.sessionId,
          'columns': _terminal.viewWidth,
          'rows': _terminal.viewHeight,
        });
      }
      if (!mounted) {
        await link.close();
        return;
      }
      _link = link;
      _frames = link.frames.listen(
        _frame,
        onError: (Object error) {
          if (mounted) {
            setState(
              () => _status = error.toString().contains('ssh_approval_required')
                  ? 'SSH approval required. On the other device, open this device’s Connections and allow Agent SSH.'
                  : error.toString(),
            );
          }
        },
      );
    } catch (error) {
      if (mounted) {
        setState(
          () => _status = error.toString().contains('ssh_approval_required')
              ? 'SSH approval required. On the other device, open this device’s Connections and allow Agent SSH.'
              : error.toString(),
        );
      }
      unawaited(_revoke());
    }
  }

  void _frame(String event) {
    if (!mounted) return;
    try {
      final frame = jsonDecode(event) as Map;
      if (frame['data'] case final String data) {
        _rawOutput.add(base64Decode(data));
      }
      if (frame['state'] == 'ready') {
        setState(() {
          _ready = true;
          _status = 'Connected';
        });
        unawaited(
          _send({'columns': _terminal.viewWidth, 'rows': _terminal.viewHeight}),
        );
      } else if (frame['state'] == 'closed') {
        setState(() {
          _ready = false;
          _status = frame['error']?.toString() ?? 'Session ended';
        });
      }
    } on FormatException {
      setState(() => _status = 'The SSH shell returned an invalid frame.');
    }
  }

  void _input(String text) {
    if (!_ready) return;
    final bytes = utf8.encode(text);
    unawaited(() async {
      const frameBytes = 8 * 1024;
      for (
        var index = 0;
        index < bytes.length && mounted && _ready;
        index += frameBytes
      ) {
        final end = (index + frameBytes).clamp(0, bytes.length);
        await _send({'data': base64Encode(bytes.sublist(index, end))});
      }
    }());
  }

  Future<void> _send(Map<String, dynamic> frame) async {
    if (!_ready) return;
    try {
      await _link?.send(frame);
    } catch (error) {
      if (mounted) {
        setState(() {
          _ready = false;
          _status = error.toString();
        });
      }
      unawaited(_revoke());
    }
  }

  Future<void> _revoke() async {
    if (widget.agentMode) return;
    try {
      await widget.core.run(['guest-terminal-revoke', widget.sessionId]);
    } catch (_) {
      // The child also releases its lease when it exits.
    }
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    unawaited(_text?.cancel());
    unawaited(_rawOutput.close());
    unawaited(_link?.close().catchError((Object _) {}));
    unawaited(_revoke());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.agentMode
            ? 'Termux · ${widget.host}'
            : 'SSH shell · ${widget.host}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close SSH shell'),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: TerminalView(_terminal, autofocus: true, readOnly: !_ready),
          ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const SizedBox(width: 8),
              TextButton(
                onPressed: _ready ? () => _input('\x1b') : null,
                child: const Text('Esc'),
              ),
              TextButton(
                onPressed: _ready ? () => _input('\t') : null,
                child: const Text('Tab'),
              ),
              TextButton(
                onPressed: _ready ? () => _input('\x03') : null,
                child: const Text('Ctrl+C'),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(_status, textAlign: TextAlign.start),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
