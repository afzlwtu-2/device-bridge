import 'dart:async';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

class AgentActionsScreen extends StatefulWidget {
  const AgentActionsScreen({super.key, required this.core, required this.peer});

  final CoreBridge core;
  final Map<String, dynamic> peer;

  @override
  State<AgentActionsScreen> createState() => _AgentActionsScreenState();
}

class _AgentActionsScreenState extends State<AgentActionsScreen> {
  static const _labels = {
    'agent-status': 'Agent status',
    'disk-space': 'Agent storage space',
    'recent-activity': 'Recent activity',
  };

  final _outgoing = <String, Map>{};
  final _requestIds = <String, String>{};
  List<Map> _presets = [];
  List<Map> _incoming = [];
  bool _busy = false;
  String? _message;

  String get _peer => widget.peer['id'] as String;
  String get _name => '${widget.peer['name'] ?? _peer}';

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final inbox = await widget.core.run(['action-inbox', _peer]) as List;
      if (mounted) setState(() => _incoming = inbox.whereType<Map>().toList());
      try {
        final presets = await widget.core.run(['agent-actions', _peer]) as List;
        if (mounted) {
          setState(() => _presets = presets.whereType<Map>().toList());
        }
      } catch (error) {
        if (mounted) {
          setState(() {
            _presets = [];
            if (!error.toString().contains(
              'does not offer approved agent actions',
            )) {
              _message = 'Connect to $_name to load its agent actions.';
            }
          });
        }
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _request(String preset) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final random = Random.secure();
    final id = _requestIds.putIfAbsent(
      preset,
      () => List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
    );
    try {
      final state = await widget.core.run(['action', _peer, preset, id]) as Map;
      if (mounted) setState(() => _outgoing[preset] = state);
      if (state['state'] == 'completed' || state['state'] == 'failed') {
        _requestIds.remove(preset);
      }
    } catch (error) {
      final message = error.toString();
      if (message.contains('action_approval_expired_or_revoked')) {
        _requestIds.remove(preset);
        if (mounted) {
          setState(() {
            _outgoing.remove(preset);
            _message =
                'Approval expired or was withdrawn. You can request it again.';
          });
        }
      } else if (mounted) {
        setState(() => _message = message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _respond(Map request, {required bool approve}) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.core.run([
        approve ? 'action-approve' : 'action-revoke',
        _peer,
        '${request['preset']}',
        '${request['id']}',
      ]);
      if (mounted) await _refresh();
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _incoming.where(
      (entry) =>
          const {'pending', 'approved', 'running'}.contains(entry['state']),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent actions'),
        actions: [
          IconButton(
            tooltip: 'Refresh action requests',
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_message case final message?)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(message),
            ),
          if (_presets.isNotEmpty)
            Text(
              'Run on $_name',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          for (final preset in _presets)
            if (preset['id'] case final String id)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_labels[id] ?? id),
                        trailing: OutlinedButton(
                          onPressed: _busy ? null : () => _request(id),
                          child: Text(
                            _requestIds.containsKey(id)
                                ? 'Check approval'
                                : 'Request',
                          ),
                        ),
                      ),
                      if (_outgoing[id]?['state'] == 'pending')
                        Text(
                          'Approve this request on $_name, then check approval here.',
                        ),
                      if (_outgoing[id]?['state'] == 'running')
                        const Text('Action running.'),
                      if (_outgoing[id]?['output'] case final String output)
                        SelectableText(output),
                    ],
                  ),
                ),
              ),
          const SizedBox(height: 20),
          Text(
            'Requests from $_name',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (pending.isEmpty && !_busy) const Text('No open requests.'),
          for (final request in pending)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_labels[request['preset']] ?? '${request['preset']}'),
                    if (request['state'] == 'approved')
                      const Text('Approved for one run.'),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (request['state'] == 'pending')
                          FilledButton(
                            onPressed: _busy
                                ? null
                                : () => _respond(request, approve: true),
                            child: const Text('Allow once'),
                          ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _respond(request, approve: false),
                          child: Text(
                            request['state'] == 'pending'
                                ? 'Decline'
                                : 'Withdraw',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
