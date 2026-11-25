import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'traffic_light.dart';

class TrafficDetails extends StatefulWidget {
  const TrafficDetails({super.key, required this.core});

  final CoreBridge core;

  @override
  State<TrafficDetails> createState() => _TrafficDetailsState();
}

class _TrafficDetailsState extends State<TrafficDetails> {
  Map<String, dynamic> _snapshot = {};
  Map<String, dynamic> _diagnostics = {};
  Timer? _timer;
  bool _loading = true;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final life = WidgetsBinding.instance.lifecycleState;
    if (_refreshing || (life != null && life != AppLifecycleState.resumed)) {
      return;
    }
    _refreshing = true;
    try {
      final core = widget.core;
      final results = await Future.wait([
        core.runtimeStatus().catchError((_) => <String, dynamic>{}),
        if (core is LocalCore) core.trafficConnections(),
      ]);
      if (!mounted) return;
      setState(() {
        _snapshot = results.first;
        _diagnostics = results.length > 1 ? results.last : {};
        _loading = false;
      });
    } finally {
      _refreshing = false;
    }
  }

  String _bytes(Object? value) =>
      value is num ? formatBytesCompact(value.toInt()) : 'Unavailable';

  String _traffic(
    Map entry, {
    String rx = 'bytes_received',
    String tx = 'bytes_sent',
  }) => '↓ ${_bytes(entry[rx])}   ↑ ${_bytes(entry[tx])}';

  Widget _section(String title, List<Widget> children) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        ...children,
      ],
    ),
  );

  List<Widget> _processRows(List<Map> processes, String group) {
    final matches = processes.where((p) => p['group'] == group).toList();
    return [
      if (matches.isEmpty && group != 'termux')
        const ListTile(
          dense: true,
          title: Text('No visible running processes'),
        ),
      for (final process in matches)
        ExpansionTile(
          title: Text('${process['name']}'),
          subtitle: Text('PID ${process['pid']}'),
          children: [
            for (final connection
                in (process['connections'] as List? ?? []).whereType<Map>())
              ListTile(
                dense: true,
                title: Text('${connection['peer']}'),
                subtitle: Text(_traffic(connection)),
              ),
            if ((process['connections'] as List? ?? []).isEmpty)
              const ListTile(
                dense: true,
                title: Text('No visible remote sockets'),
              ),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final agent = _snapshot['agent'] as Map? ?? const {};
    final traffic = _snapshot['traffic'] as Map? ?? const {};
    final tailnet = _snapshot['tailnet_status'] as Map? ?? const {};
    final proxy = tailnet['proxy_stats'] as Map? ?? const {};
    final processes = (_diagnostics['processes'] as List? ?? [])
        .whereType<Map>()
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Live traffic'),
        actions: [
          IconButton(
            onPressed: _refresh,
            tooltip: 'Refresh traffic',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            if (_loading) const LinearProgressIndicator(),
            _section('DeviceBridge app & agents', [
              ListTile(
                title: Text(
                  _snapshot['os'] == 'linux'
                      ? 'Host network interfaces'
                      : 'DeviceBridge UID',
                ),
                subtitle: Text(
                  _traffic(traffic, rx: 'uid_rx_bytes', tx: 'uid_tx_bytes'),
                ),
              ),
              if (agent.isNotEmpty)
                ListTile(
                  title: const Text('DeviceBridge agent'),
                  subtitle: Text(
                    [
                      if ('${agent['endpoint'] ?? ''}'.isNotEmpty)
                        'Listener ${agent['endpoint']}',
                      '${agent['active_conns'] ?? 0} active connections · ${_traffic(agent)}',
                    ].join('\n'),
                  ),
                ),
              ..._processRows(processes, 'app'),
            ]),
            _section('SSH traffic', [
              if ((agent['active_ssh'] as num? ?? 0) > 0)
                ListTile(
                  title: const Text('DeviceBridge agent SSH (mTLS)'),
                  subtitle: Text('${agent['active_ssh']} active sessions'),
                ),
              for (final session
                  in (tailnet['ssh_sessions'] as List? ?? []).whereType<Map>())
                ListTile(
                  title: Text(
                    '${session['peer'] ?? session['remote'] ?? 'Tailscale SSH'}',
                  ),
                  subtitle: Text(
                    '${session['remote'] ?? ''} · ${_traffic(session, rx: 'rx_bytes', tx: 'tx_bytes')}',
                  ),
                ),
              if ((tailnet['ssh_sessions'] as List? ?? []).isEmpty)
                const ListTile(title: Text('No active Tailscale SSH sessions')),
              ..._processRows(
                processes
                    .where((p) => '${p['name']}'.startsWith('sshd'))
                    .toList(),
                'termux',
              ),
            ]),
            _section('tsnet peer traffic', [
              for (final peer
                  in (tailnet['peers'] as List? ?? []).whereType<Map>())
                ListTile(
                  title: Text('${peer['name']}'),
                  subtitle: Text(
                    _traffic(
                      peer['path'] as Map? ?? {},
                      rx: 'rx_bytes',
                      tx: 'tx_bytes',
                    ),
                  ),
                ),
              if ((tailnet['peers'] as List? ?? []).isEmpty)
                const ListTile(title: Text('No visible tailnet peers')),
            ]),
            _section('SOCKS5 traffic', [
              ListTile(
                title: Text('${proxy['active_clients'] ?? 0} active clients'),
                subtitle: Text(_traffic(proxy, rx: 'rx_bytes', tx: 'tx_bytes')),
              ),
              for (final row
                  in (proxy['active_connections'] as List? ?? [])
                      .whereType<Map>())
                ListTile(
                  dense: true,
                  title: Text('${row['host']}'),
                  subtitle: Text(_traffic(row, rx: 'rx_bytes', tx: 'tx_bytes')),
                ),
              if ((proxy['destinations'] as List? ?? []).isNotEmpty)
                ExpansionTile(
                  title: const Text('Recent destination totals'),
                  children: [
                    for (final row
                        in (proxy['destinations'] as List).whereType<Map>())
                      ListTile(
                        dense: true,
                        title: Text('${row['host']}'),
                        subtitle: Text(
                          _traffic(row, rx: 'rx_bytes', tx: 'tx_bytes'),
                        ),
                      ),
                  ],
                ),
            ]),
            _section(
              'Other DeviceBridge binaries',
              _processRows(processes, 'bundled'),
            ),
            _section('Termux binaries', _processRows(processes, 'termux')),
            if (_diagnostics['socket_access'] != true)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Per-process socket visibility depends on Android access. App counters are shared by the UID.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
