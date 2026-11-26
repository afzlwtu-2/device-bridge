import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'tailnet_panel.dart';
import 'traffic_details.dart';
import 'traffic_light.dart';
import 'wiki_screen.dart';

class _HomeAlert {
  const _HomeAlert({
    required this.level,
    required this.title,
    required this.detail,
    required this.actionLabel,
    required this.onAction,
  });

  final TrafficLightLevel level;
  final String title;
  final String detail;
  final String actionLabel;
  final VoidCallback onAction;
}

/// Live traffic, SSH listener status, and alerts that need attention.
class HomeDashboard extends StatefulWidget {
  const HomeDashboard({
    super.key,
    required this.core,
    required this.identity,
    required this.peers,
    required this.listenerState,
    required this.onOpenTerminal,
    required this.onOpenFiles,
    required this.onOpenNetworks,
    required this.onGoToTab,
    this.permissionsStatus,
    this.onOpenPermissions,
  });

  final CoreBridge core;
  final Map<String, dynamic>? identity;
  final List<dynamic> peers;
  final String? listenerState;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenFiles;
  final Future<void> Function() onOpenNetworks;
  final ValueChanged<int> onGoToTab;
  final Map<String, dynamic>? permissionsStatus;
  final VoidCallback? onOpenPermissions;

  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard>
    with WidgetsBindingObserver {
  Map<String, dynamic> _runtime = {};
  bool _loading = true;
  bool _refreshing = false;
  int _shareInboxCount = 0;

  int? _prevRx;
  int? _prevTx;
  int? _prevTsMs;
  double _rxRateBps = 0;
  double _txRateBps = 0;
  final List<double> _rateHistory = <double>[];

  Map<String, dynamic>? _activeTransfer;
  StreamSubscription<Map<String, dynamic>>? _transferSub;
  StreamSubscription<Map<String, dynamic>>? _networkSub;
  Timer? _pollTimer;
  bool _routeVisible = false;
  bool _monitoring = false;
  AppLifecycleState? _lifecycleState;

  @override
  void initState() {
    super.initState();
    _lifecycleState = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
    _transferSub = widget.core.transferProgress.listen((p) {
      if (!mounted) return;
      final state = '${p['transfer_state'] ?? ''}';
      final done = const {
        'done',
        'completed',
        'cancelled',
        'finished',
      }.contains(state);
      final transfer = done ? null : Map<String, dynamic>.from(p);
      if (_monitoring) {
        setState(() => _activeTransfer = transfer);
      } else {
        _activeTransfer = transfer;
      }
    });
    _networkSub = widget.core.networkEvents.listen((_) {
      unawaited(_refresh());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeVisible = ModalRoute.isCurrentOf(context) ?? true;
    _syncMonitoring();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _syncMonitoring();
  }

  void _syncMonitoring() {
    final visible =
        _routeVisible &&
        (_lifecycleState == null ||
            _lifecycleState == AppLifecycleState.resumed);
    if (visible == _monitoring) return;
    _monitoring = visible;
    _pollTimer?.cancel();
    _prevTsMs = null;
    if (!visible) return;
    unawaited(_refresh());
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    unawaited(_transferSub?.cancel());
    unawaited(_networkSub?.cancel());
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!_monitoring || _refreshing) return;
    _refreshing = true;
    try {
      final results = await Future.wait([
        widget.core.runtimeStatus().catchError((_) => <String, dynamic>{}),
        widget.core
            .run(['share-inbox'])
            .then((v) => (v as List).length)
            .catchError((_) => 0),
      ]);
      if (!mounted || !_monitoring) return;
      final snap = results[0] as Map<String, dynamic>;
      final inboxCount = results[1] as int;

      final traffic = snap['traffic'] is Map
          ? Map<String, dynamic>.from(snap['traffic'] as Map)
          : const <String, dynamic>{};
      final rx = (traffic['uid_rx_bytes'] as num?)?.toInt() ?? 0;
      final tx = (traffic['uid_tx_bytes'] as num?)?.toInt() ?? 0;
      final tsMs =
          (snap['timestamp_ms'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;

      double nextRxRate = _rxRateBps;
      double nextTxRate = _txRateBps;
      if (_prevTsMs != null && tsMs > _prevTsMs!) {
        final dtSec = (tsMs - _prevTsMs!) / 1000.0;
        if (dtSec >= 0.2) {
          final dRx = math.max(0, rx - (_prevRx ?? rx));
          final dTx = math.max(0, tx - (_prevTx ?? tx));
          nextRxRate = dRx / dtSec;
          nextTxRate = dTx / dtSec;
          _rateHistory.add(nextRxRate + nextTxRate);
          if (_rateHistory.length > 20) {
            _rateHistory.removeAt(0);
          }
          _prevRx = rx;
          _prevTx = tx;
          _prevTsMs = tsMs;
        }
      } else {
        _prevRx = rx;
        _prevTx = tx;
        _prevTsMs = tsMs;
        nextRxRate = 0;
        nextTxRate = 0;
      }

      setState(() {
        _runtime = snap;
        _shareInboxCount = inboxCount;
        _rxRateBps = nextRxRate;
        _txRateBps = nextTxRate;
        _loading = false;
      });
    } finally {
      _refreshing = false;
    }
  }

  Map<String, dynamic> _map(String key) {
    final v = _runtime[key];
    return v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
  }

  List<Map<String, dynamic>> _list(String key) {
    final v = _runtime[key];
    if (v is! List) return const [];
    return v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList();
  }

  Future<void> _openTailnetSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => TailnetPanel(core: widget.core)),
    );
    if (mounted) unawaited(_refresh());
  }

  Future<void> _openSshSettings() async {
    await widget.onOpenNetworks();
    if (mounted) unawaited(_refresh());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ssh = _map('ssh');
    final tailnet = _map('tailnet_status');
    final traffic = _map('traffic');
    final totalRxBytes = (traffic['uid_rx_bytes'] as num?)?.toInt() ?? 0;
    final totalTxBytes = (traffic['uid_tx_bytes'] as num?)?.toInt() ?? 0;
    final transferMiB =
        (_activeTransfer?['mib_per_second'] as num?)?.toDouble() ?? 0;
    final liveTotalBps = _rxRateBps + _txRateBps;
    final trafficLight = switch (_activeTransfer?['transfer_state']) {
      'metered' || 'waiting' => TrafficLightLevel.amber,
      _ when _activeTransfer != null || liveTotalBps > 512 =>
        TrafficLightLevel.green,
      _ => TrafficLightLevel.off,
    };
    final maxRate = _rateHistory.isEmpty
        ? 1.0
        : math.max(1024.0, _rateHistory.reduce(math.max));
    final tailnetRunning = tailnet['state'] == 'Running';
    final tailnetSshEnabled =
        (tailnet['tailscale_ssh_enabled'] ?? ssh['tailscale_ssh_enabled']) ==
        true;
    final proxyAddress = '${tailnet['socks5_addr'] ?? ''}';
    final proxyStats = tailnet['proxy_stats'];
    final listenerState = widget.listenerState ?? _map('agent')['state'];
    final pendingCount = widget.peers
        .where((p) => p is Map && p['status'] == 'pending')
        .length;

    final alerts = <_HomeAlert>[
      if (widget.permissionsStatus?['all_essential_granted'] == false &&
          widget.onOpenPermissions != null)
        _HomeAlert(
          level: TrafficLightLevel.amber,
          title: 'Permissions needed',
          detail:
              'Grant storage or Wi-Fi permissions for File manager and Direct links.',
          actionLabel: 'Review',
          onAction: widget.onOpenPermissions!,
        ),
      if (listenerState == 'receiver_error')
        _HomeAlert(
          level: TrafficLightLevel.red,
          title: 'Local connection unavailable',
          detail: 'Check the listener and discovery in Networks.',
          actionLabel: 'Networks',
          onAction: () => unawaited(widget.onOpenNetworks()),
        ),
      if (listenerState == 'approval_required')
        _HomeAlert(
          level: TrafficLightLevel.amber,
          title: 'Choose a local network',
          detail: 'Select a network to connect directly to nearby devices.',
          actionLabel: 'Networks',
          onAction: () => unawaited(widget.onOpenNetworks()),
        ),
      if (tailnet['state'] == 'NeedsLogin')
        _HomeAlert(
          level: TrafficLightLevel.amber,
          title: 'Tailscale login required',
          detail: 'Sign in to connect to your tailnet.',
          actionLabel: 'Open Tailscale',
          onAction: () => unawaited(_openTailnetSettings()),
        ),
      if (pendingCount > 0)
        _HomeAlert(
          level: TrafficLightLevel.amber,
          title: '$pendingCount pending device pairing request(s)',
          detail: 'Review incoming pairing requests in Devices.',
          actionLabel: 'Devices',
          onAction: () => widget.onGoToTab(1),
        ),
      if (_shareInboxCount > 0)
        _HomeAlert(
          level: TrafficLightLevel.green,
          title: '$_shareInboxCount item(s) in Quick Share inbox',
          detail: 'Open Share to inspect or save received items.',
          actionLabel: 'Share',
          onAction: () => widget.onGoToTab(2),
        ),
    ];

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        key: const ValueKey('home-dashboard'),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              widget.identity?['name'] as String? ?? 'Starting DeviceBridge…',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Card(
            key: const ValueKey('home-traffic-monitor'),
            child: InkWell(
              key: const ValueKey('open-live-traffic'),
              borderRadius: BorderRadius.circular(16),
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => TrafficDetails(core: widget.core),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.swap_vert_circle_outlined, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Live traffic & bandwidth',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        TrafficLightPill(
                          level: trafficLight,
                          label: _activeTransfer != null
                              ? '${_activeTransfer!['transfer_state'] ?? 'active'}'
                              : (_loading
                                    ? 'Checking'
                                    : (liveTotalBps > 512 ? 'Active' : 'Idle')),
                          compact: true,
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    if (_activeTransfer != null) ...[
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value:
                            (_activeTransfer!['total_bytes'] as num? ?? 0) > 0
                            ? (((_activeTransfer!['verified_bytes'] ??
                                                  _activeTransfer!['sent_bytes'])
                                              as num? ??
                                          0) /
                                      (_activeTransfer!['total_bytes'] as num))
                                  .clamp(0.0, 1.0)
                            : null,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Transferring${transferMiB > 0 ? ' · ${transferMiB.toStringAsFixed(2)} MiB/s' : ''}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _TrafficStatBox(
                            icon: Icons.arrow_downward_rounded,
                            label: 'RX rate',
                            rate: formatRateCompact(_rxRateBps),
                            total: 'Total ${formatBytesCompact(totalRxBytes)}',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _TrafficStatBox(
                            icon: Icons.arrow_upward_rounded,
                            label: 'TX rate',
                            rate: formatRateCompact(_txRateBps),
                            total: 'Total ${formatBytesCompact(totalTxBytes)}',
                          ),
                        ),
                      ],
                    ),
                    if (_rateHistory.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 28,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            for (var i = 0; i < 20; i++)
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 1,
                                  ),
                                  child: Container(
                                    height: i < _rateHistory.length
                                        ? math.max(
                                            3.0,
                                            28.0 *
                                                (_rateHistory[i] / maxRate)
                                                    .clamp(0.0, 1.0),
                                          )
                                        : 3.0,
                                    decoration: BoxDecoration(
                                      color:
                                          (i < _rateHistory.length &&
                                              _rateHistory[i] > 512)
                                          ? scheme.primary
                                          : scheme.outlineVariant.withValues(
                                              alpha: 0.45,
                                            ),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            key: const ValueKey('home-signal-ssh'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.lock_outline, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('SSH', style: theme.textTheme.titleMedium),
                      ),
                      IconButton(
                        tooltip: 'SSH settings',
                        icon: const Icon(Icons.settings_outlined, size: 20),
                        onPressed: _openSshSettings,
                      ),
                    ],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: _SshStatus(
                          key: const ValueKey('home-ssh-agent'),
                          label: 'Agent SSH',
                          enabled: _map('agent')['agent_ssh_enabled'] == true,
                          listening:
                              _map('agent')['agent_ssh_enabled'] == true &&
                              (_map('agent')['running'] == true ||
                                  _map('agent')['file_running'] == true),
                          connections:
                              (_map('agent')['active_ssh'] as num?)?.toInt() ??
                              0,
                          loading: _loading,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SshStatus(
                          key: const ValueKey('home-ssh-openssh'),
                          label:
                              'OpenSSH · :${(ssh['openssh_port'] as num?)?.toInt() ?? 8022}',
                          enabled: ssh['openssh_enabled'] == true,
                          listening: ssh['openssh_running'] == true,
                          connections:
                              (ssh['openssh_conns'] as num?)?.toInt() ?? 0,
                          loading: _loading,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _SshStatus(
                          key: const ValueKey('home-ssh-tailnet'),
                          label: 'Tailscale SSH · :22',
                          enabled: tailnetSshEnabled,
                          listening: tailnetRunning && tailnetSshEnabled,
                          connections:
                              ((tailnet['active_ssh_conns'] ??
                                          ssh['active_ssh_conns'])
                                      as num?)
                                  ?.toInt() ??
                              0,
                          loading: _loading,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: widget.onOpenTerminal,
                  icon: const Icon(Icons.terminal_outlined, size: 18),
                  label: const Text('Termux'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('home-open-file-manager'),
                  onPressed: widget.onOpenFiles,
                  icon: const Icon(Icons.folder_outlined, size: 18),
                  label: const Text('Files'),
                ),
                OutlinedButton.icon(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => WikiScreen(core: widget.core),
                    ),
                  ),
                  icon: const Icon(Icons.menu_book_outlined, size: 18),
                  label: const Text('Wiki'),
                ),
              ],
            ),
          ),
          if (alerts.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              key: const ValueKey('home-alerts-card'),
              child: Column(
                children: [
                  for (final alert in alerts)
                    ListTile(
                      leading: TrafficLightDot(level: alert.level, size: 10),
                      title: Text(alert.title),
                      subtitle: Text(alert.detail),
                      trailing: TextButton(
                        onPressed: alert.onAction,
                        child: Text(alert.actionLabel),
                      ),
                    ),
                ],
              ),
            ),
          ],
          if (proxyAddress.isNotEmpty ||
              _map('tailnet')['socks5_enabled'] == true) ...[
            const SizedBox(height: 8),
            _ProxyUsageCard(
              address: proxyAddress,
              stats: proxyStats is Map ? proxyStats : const {},
              apps: _list('proxy_client_apps'),
              routed: tailnetRunning,
            ),
          ],
        ],
      ),
    );
  }
}

class _SshStatus extends StatelessWidget {
  const _SshStatus({
    super.key,
    required this.label,
    required this.enabled,
    required this.listening,
    required this.connections,
    required this.loading,
  });

  final String label;
  final bool enabled;
  final bool listening;
  final int connections;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = switch (true) {
      _ when loading => 'Checking',
      _ when listening && connections > 0 => 'On · $connections active',
      _ when listening => 'On',
      _ when enabled => 'Standby',
      _ => 'Off',
    };
    final level = listening
        ? TrafficLightLevel.green
        : (enabled ? TrafficLightLevel.amber : TrafficLightLevel.off);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Row(
          children: [
            TrafficLightDot(level: level, size: 8),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                status,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ProxyUsageCard extends StatelessWidget {
  const _ProxyUsageCard({
    required this.address,
    required this.stats,
    required this.apps,
    required this.routed,
  });

  final String address;
  final Map stats;
  final List<Map<String, dynamic>> apps;
  final bool routed;

  String _bytes(Object? value) =>
      formatBytesCompact(value is num ? value.toInt() : 0);

  @override
  Widget build(BuildContext context) {
    final destinations = (stats['destinations'] as List? ?? const [])
        .whereType<Map>();
    final active = stats['active_clients'];
    final clients = active is num ? active.toInt() : null;
    return Card(
      key: const ValueKey('home-socks5-usage'),
      child: ExpansionTile(
        leading: const Icon(Icons.hub_outlined),
        title: const Text('Local SOCKS5 proxy'),
        subtitle: Text(
          [
            if (address.isEmpty) 'Waiting for listener' else address,
            if (address.isNotEmpty && !routed) 'Waiting for Tailscale',
            if (clients != null) '$clients active connections',
          ].join(' · '),
        ),
        children: [
          if (stats.isEmpty)
            const ListTile(
              dense: true,
              subtitle: Text('Proxy counters are unavailable.'),
            )
          else
            ListTile(
              dense: true,
              title: const Text('Traffic since listener start'),
              subtitle: Text(
                '↓ ${_bytes(stats['rx_bytes'])} · ↑ ${_bytes(stats['tx_bytes'])} · ${stats['connections']} connections',
              ),
            ),
          if (clients != null && clients > 0)
            ListTile(
              dense: true,
              title: const Text('Connected apps'),
              subtitle: Text(
                apps.isEmpty
                    ? 'App identity unavailable for these connections.'
                    : apps
                          .map((app) {
                            final names = (app['packages'] as List? ?? const [])
                                .whereType<String>();
                            return names.isEmpty
                                ? 'UID ${app['uid']}'
                                : names.join(' / ');
                          })
                          .join(', '),
              ),
            ),
          for (final item in destinations)
            ListTile(
              dense: true,
              title: Text('${item['host']}', overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '↓ ${_bytes(item['rx_bytes'])} · ↑ ${_bytes(item['tx_bytes'])}',
              ),
            ),
        ],
      ),
    );
  }
}

class _TrafficStatBox extends StatelessWidget {
  const _TrafficStatBox({
    required this.icon,
    required this.label,
    required this.rate,
    required this.total,
  });

  final IconData icon;
  final String label;
  final String rate;
  final String total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: scheme.primary),
              const SizedBox(width: 4),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            rate,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(
            total,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
