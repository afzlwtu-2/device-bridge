import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import '../core/debug_trace.dart';
import 'registry.dart';
import 'network_card.dart';
import 'network_rules.dart';
import 'network_setup_settings.dart';
import 'guest_terminal.dart';
import 'local_terminal.dart';
import 'ssh_hosts.dart';
import 'phone_files.dart';
import 'folder_exclusions.dart';
import 'folder_name_dialog.dart';
import 'sync_screen.dart';
import 'folder_pair_sync.dart';
import 'ssh_bootstrap.dart';
import 'acl_screen.dart';

class DeviceDetail extends StatefulWidget {
  const DeviceDetail({
    super.key,
    required this.core,
    required this.peer,
    required this.registry,
    this.candidates = const [],
    this.openConnections = false,
    this.forDownload = false,
  });
  final CoreBridge core;
  final Map<String, dynamic> peer;
  final FeatureRegistry registry;
  final List<dynamic> candidates;
  final bool openConnections;
  final bool forDownload;
  @override
  State<DeviceDetail> createState() => _DeviceDetailState();
}

class _ReachablePath {
  const _ReachablePath({
    required this.transport,
    required this.label,
    required this.endpoint,
    this.interfaceName,
    this.cidr,
    this.kind,
    this.rttMs,
    this.pathKind,
    this.relay,
    this.remoteApproved = false,
    this.networkMap,
    this.resolved,
  });

  final String transport;
  final String label;
  final String endpoint;
  final String? interfaceName;
  final String? cidr;
  final String? kind;
  final double? rttMs;
  final String? pathKind;
  final String? relay;
  final bool remoteApproved;
  final Map<String, dynamic>? networkMap;
  final Map<String, dynamic>? resolved;

  String get id => '$transport:${interfaceName ?? ''}:$endpoint';
}

class _DeviceDetailSnapshot {
  Map<String, dynamic>? connectionCfg;
  Map<String, dynamic>? route;
  List<dynamic> roots = const [];
  List<_ReachablePath> reachablePaths = const [];
  Map<String, dynamic> platformCaps = const {};
  Map<String, dynamic>? peerCaps;
  int? localLeaseDeadlineMs;
  Map<String, dynamic> localLinkInfo = const {};
  Map<String, dynamic>? resumedDirect;
  Map<String, dynamic> directLinkMeta = const {};
  String? activeDirectKind;
  bool keptUnconnectedDirect = false;
  bool tailnetRunning = false;
  List<dynamic> tailnetNodes = const [];
  List<dynamic> wgPeers = const [];
  double? measuredSpeedMiBs;
  Map<String, double> pathSpeeds = const {};
}

class _DeviceDetailState extends State<DeviceDetail>
    with SingleTickerProviderStateMixin {
  static final Expando<Map<String, _DeviceDetailSnapshot>> _peerCache =
      Expando<Map<String, _DeviceDetailSnapshot>>('deviceDetailCache');
  late final TabController _tabController;
  NetworkRules _rules = const NetworkRules();
  String? _renamedDevice;
  String get _deviceName => _renamedDevice ?? '${widget.peer['name']}';
  Map<String, dynamic> get _namedPeer => {...widget.peer, 'name': _deviceName};
  Map<String, dynamic> _sshAccess = {};
  Map<String, dynamic> _aclEval = {};
  Map<String, dynamic> _linkOperation = {};
  String? _localLeaseStage;
  int? _localLeaseDeadlineMs;
  bool _peerCapsCached = false;
  bool _leasedRemoteOperation = false;
  String _sshMethod = 'auto';
  List<Map<String, dynamic>> _sshHosts = [];
  bool busy = true;
  bool probingPaths = false;
  String? offlineNote;
  String? testingPathId, testMessage;
  bool? testSuccess;
  List<dynamic> roots = [];
  List<dynamic> tailnetNodes = [];
  List<dynamic> wgPeers = [];
  List<_ReachablePath> reachablePaths = [];
  bool tailnetRunning = false;
  bool _tailnetStarting = false;
  bool _tailnetReconnecting = false;
  Timer? _tailnetRetry;
  Timer? _lanRefresh;
  Timer? _routeHealth;
  StreamSubscription<Map<String, dynamic>>? _networkEvents;
  int _tailnetProbeRevision = 0;
  int _lanProbeRevision = 0;
  int _loadRevision = 0;
  bool _recoveringPath = false;
  bool _checkingRoute = false;
  bool _lanRefreshPending = false;
  bool wgRunning = false;
  Map<String, dynamic>? route;
  Map<String, dynamic>? connectionCfg;
  Map<String, dynamic> platformCaps = {};
  Map<String, dynamic>? peerCaps;
  Map<String, dynamic> _localLinkInfo = {};
  Map<String, dynamic> _directLinkMeta = {};
  Map<String, dynamic>? _resumedDirect;
  Map<String, dynamic>? _savedDirect;
  bool _savedHostOpen = false;
  bool _keptUnconnectedDirect = false;
  String? activeDirectKind;
  String? _preDirectLanEndpoint;
  Map<String, dynamic>? _preDirectNetwork;
  List<_ReachablePath> _preDirectPaths = const [];
  bool _startingDirect = false;
  bool _cancellingDirect = false;
  int? _selectedChannel;
  int _selectedBandwidthMhz = 0;
  double? measuredSpeedMiBs;
  final Map<String, double> _pathSpeeds = {};
  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.openConnections ? 1 : 0,
    );
    final peerId = widget.peer['id'] as String;
    final snap = _peerCache[widget.core]?[peerId];
    if (snap != null) {
      connectionCfg = snap.connectionCfg;
      route = snap.route;
      roots = List<dynamic>.from(snap.roots);
      reachablePaths = List<_ReachablePath>.from(snap.reachablePaths);
      platformCaps = Map<String, dynamic>.from(snap.platformCaps);
      peerCaps = snap.peerCaps == null
          ? null
          : Map<String, dynamic>.from(snap.peerCaps!);
      _peerCapsCached = snap.peerCaps != null;
      _localLeaseDeadlineMs = snap.localLeaseDeadlineMs;
      _localLinkInfo = Map<String, dynamic>.from(snap.localLinkInfo);
      _resumedDirect = snap.resumedDirect == null
          ? null
          : Map<String, dynamic>.from(snap.resumedDirect!);
      _directLinkMeta = Map<String, dynamic>.from(snap.directLinkMeta);
      activeDirectKind = snap.activeDirectKind;
      _keptUnconnectedDirect = snap.keptUnconnectedDirect;
      tailnetRunning = snap.tailnetRunning;
      tailnetNodes = List<dynamic>.from(snap.tailnetNodes);
      wgPeers = List<dynamic>.from(snap.wgPeers);
      measuredSpeedMiBs = snap.measuredSpeedMiBs;
      _pathSpeeds.addAll(snap.pathSpeeds);
      busy = false;
      probingPaths = false;
    }
    _networkEvents = widget.core.networkEvents.listen(_onNetworkEvent);
    _routeHealth = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_checkForegroundRoute()),
    );
    unawaited(load(background: snap != null));
  }

  String? get _connectedTransport => switch (route?['transport']) {
    'direct-lan-v1' => 'lan',
    'tsnet-v1' || 'tailscaled-v1' => 'tailnet',
    'wireguard-v1' => 'wireguard',
    final String transport => transport,
    _ => null,
  };

  bool get _directLinkOpen =>
      _resumedDirect?['active'] == true ||
      activeDirectKind != null ||
      _isDirectSubPath(
        iface: widget.core.network?['interface'] as String?,
        kind: widget.core.network?['kind'] as String?,
      );

  bool get _canAutoConnectTailnet => !_directLinkOpen && !_savedHostOpen;

  String get _preferredTransport =>
      '${connectionCfg?['preferred_transport'] ?? connectionCfg?['transport'] ?? 'auto'}';

  String get _preferredLink =>
      connectionCfg?['preferred_link'] as String? ?? 'auto';

  String _linkPreference(_ReachablePath path) {
    final kind = _pathKind(path);
    if (kind != 'lan') return kind;
    final iface = path.interfaceName ?? '';
    if (path.kind == 'ethernet' ||
        iface.startsWith('eth') ||
        iface.startsWith('en')) {
      return 'ethernet';
    }
    if (path.kind == 'usb_net' ||
        iface.startsWith('rndis') ||
        iface.startsWith('usb')) {
      return 'usb_net';
    }
    return 'wifi';
  }

  int _compareAutomaticPaths(_ReachablePath a, _ReachablePath b) {
    final transport = _automaticRank(_pathKind(a))
        .compareTo(_automaticRank(_pathKind(b)));
    if (transport != 0 || _preferredLink == 'auto') return transport;
    return (_linkPreference(a) == _preferredLink ? 0 : 1).compareTo(
      _linkPreference(b) == _preferredLink ? 0 : 1,
    );
  }

  String _pathKind(_ReachablePath path) {
    if (path.transport != 'lan') return path.transport;
    if (path.kind == 'wifi_direct' ||
        (path.interfaceName ?? '').startsWith('p2p') ||
        (path.interfaceName ?? '').startsWith('dbp2p')) {
      return 'wifi_direct';
    }
    return _isDirectSubPath(iface: path.interfaceName, kind: path.kind)
        ? 'hotspot'
        : 'lan';
  }

  int _automaticRank(String kind) {
    final order = const ['lan', 'tailnet', 'wireguard'];
    final rank = order.indexOf(kind);
    if (rank < 0) return 4;
    return kind == _preferredTransport ? -1 : rank;
  }

  bool _manualPath(_ReachablePath path) => _automaticRank(_pathKind(path)) == 4;

  bool get _canUseUsbAdb {
    final localOS =
        platformCaps['os'] ?? (Platform.isAndroid ? 'android' : 'linux');
    final peerOS = peerCaps?['os'];
    if (!((localOS == 'linux' && peerOS == 'android') ||
        (localOS == 'android' && peerOS == 'linux'))) {
      return false;
    }
    return (platformCaps['usb_adb_connected'] == true ||
            platformCaps['usb_adb'] == true) &&
        peerCaps?['usb_adb'] == true;
  }

  Future<void> _selectAutomaticPath(int revision) async {
    if (!mounted || busy || revision != _loadRevision) return;
    final current = _activeReachablePath();
    if (route != null && current != null && _manualPath(current)) return;
    final candidates = reachablePaths
        .where(
          (path) =>
              !_manualPath(path) &&
              (path.transport != 'tailnet' || _canAutoConnectTailnet),
        )
        .toList();
    if (candidates.isEmpty) return;
    candidates.sort(_compareAutomaticPaths);
    final next = candidates.first;
    if (route == null && _lanRefreshPending && next.transport != 'lan') return;
    if (route == null &&
        _tailnetReconnecting &&
        next.transport == 'wireguard') {
      return;
    }
    if (route != null) {
      if (current == null || _compareAutomaticPaths(current, next) <= 0) {
        return;
      }
    }
    await _recoverPath(next, revision);
  }

  Future<void> _checkForegroundRoute() async {
    if (!mounted ||
        busy ||
        probingPaths ||
        _checkingRoute ||
        _recoveringPath ||
        widget.peer['status'] == 'revoked' ||
        ModalRoute.of(context)?.isCurrent == false ||
        (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed)) {
      return;
    }
    if (_tailnetReconnecting || _lanRefreshPending) return;
    _checkingRoute = true;
    final previous = route;
    final revision = _loadRevision;
    try {
      final active = _activeReachablePath();
      if (previous == null || active == null) {
        await load(background: true, checkStored: false);
        return;
      }
      final result = await _probeOne([
        ..._controlPrefixArgs(active),
        'resolve',
        widget.peer['id'] as String,
      ]);
      if (!mounted ||
          revision != _loadRevision ||
          !identical(route, previous)) {
        return;
      }
      if (result == null) {
        setState(() {
          route = null;
          roots = [];
          reachablePaths = reachablePaths
              .where((path) => path.id != active.id)
              .toList();
        });
        await load(background: true, checkStored: false);
      } else if (result['capabilities'] case final Map caps) {
        final changed =
            caps['tailnet_endpoint'] != peerCaps?['tailnet_endpoint'] ||
            jsonEncode(caps['wireguard_endpoints']) !=
                jsonEncode(peerCaps?['wireguard_endpoints']) ||
            caps['usb_adb'] != peerCaps?['usb_adb'];
        if (changed) {
          setState(
            () => peerCaps = _mergePeerCaps(caps, features: result['features']),
          );
          await load(background: true);
        }
      }
      if (result != null &&
          active.transport != 'lan' &&
          _automaticRank('lan') < _automaticRank(_pathKind(active))) {
        final lanPaths = await _probeReachablePaths(lanOnly: true);
        if (!mounted ||
            revision != _loadRevision ||
            !identical(route, previous)) {
          return;
        }
        setState(
          () => reachablePaths = [
            ...lanPaths,
            ...reachablePaths.where((path) => path.transport != 'lan'),
          ],
        );
        await _selectAutomaticPath(revision);
        _savePeerCache();
      }
    } finally {
      _checkingRoute = false;
    }
  }

  bool get _reconnectingSelectedTailnet =>
      _tailnetReconnecting &&
      route == null &&
      connectionCfg?['transport'] == 'tailnet';

  void _onNetworkEvent(Map<String, dynamic> event) {
    if (!mounted || widget.peer['status'] == 'revoked') return;
    final tailnetChanged = event['tailnet_network_changed'] == true;
    final state = event['state'];
    final nextNetwork = event['network'];
    final active = _activeReachablePath();
    final changedLan =
        state == 'active' &&
        nextNetwork is Map &&
        active?.transport == 'lan' &&
        ((active?.cidr != null && nextNetwork['cidr'] != active?.cidr) ||
            (active?.interfaceName != null &&
                nextNetwork['interface'] != active?.interfaceName) ||
            (active?.networkMap?['network_handle'] != null &&
                nextNetwork['network_handle'] !=
                    active?.networkMap?['network_handle']));
    final lostLan =
        (state == 'offline' || state == 'approval_required' || changedLan) &&
        !_directLinkOpen;
    if (state == 'offline') {
      _lanRefresh?.cancel();
      _lanProbeRevision++;
      _lanRefreshPending = false;
    } else if (state == 'active' ||
        state == 'receiver_error' ||
        state == 'approval_required') {
      _lanRefresh?.cancel();
      _lanRefreshPending = true;
      final revision = ++_lanProbeRevision;
      _lanRefresh = Timer(const Duration(milliseconds: 250), () async {
        final lanPaths = await _probeReachablePaths(lanOnly: true);
        if (!mounted || revision != _lanProbeRevision) return;
        _lanRefreshPending = false;
        setState(
          () => reachablePaths = [
            ...lanPaths,
            ...reachablePaths.where((path) => path.transport != 'lan'),
          ],
        );
        await _selectAutomaticPath(_loadRevision);
        _savePeerCache();
      });
    }
    if (!tailnetChanged && !lostLan) return;

    final activeLost =
        (lostLan && _connectedTransport == 'lan') ||
        (tailnetChanged && _connectedTransport == 'tailnet');
    setState(() {
      reachablePaths = reachablePaths.where((path) {
        return !(lostLan && path.transport == 'lan') &&
            !(tailnetChanged && path.transport == 'tailnet');
      }).toList();
      if (activeLost) {
        if (!busy) {
          _loadRevision++;
          probingPaths = false;
        }
        route = null;
        roots = [];
      }
      if (tailnetChanged) _tailnetStarting = true;
    });
    if (tailnetChanged || (activeLost && _canAutoConnectTailnet)) {
      _retryTailnetPath();
    }
  }

  @override
  void dispose() {
    _tailnetRetry?.cancel();
    _lanRefresh?.cancel();
    _routeHealth?.cancel();
    unawaited(_networkEvents?.cancel());
    _tabController.dispose();
    super.dispose();
  }

  void _savePeerCache() {
    final peerId = widget.peer['id'] as String;
    final map = _peerCache[widget.core] ?? (_peerCache[widget.core] = {});
    map[peerId] = _DeviceDetailSnapshot()
      ..connectionCfg = connectionCfg == null
          ? null
          : Map<String, dynamic>.from(connectionCfg!)
      ..route = route == null ? null : Map<String, dynamic>.from(route!)
      ..roots = List<dynamic>.from(roots)
      ..reachablePaths = List<_ReachablePath>.from(reachablePaths)
      ..platformCaps = Map<String, dynamic>.from(platformCaps)
      ..peerCaps = peerCaps == null
          ? null
          : Map<String, dynamic>.from(peerCaps!)
      ..localLeaseDeadlineMs = _localLeaseDeadlineMs
      ..localLinkInfo = Map<String, dynamic>.from(_localLinkInfo)
      ..resumedDirect = _resumedDirect == null
          ? null
          : Map<String, dynamic>.from(_resumedDirect!)
      ..directLinkMeta = Map<String, dynamic>.from(_directLinkMeta)
      ..activeDirectKind = activeDirectKind
      ..keptUnconnectedDirect = _keptUnconnectedDirect
      ..tailnetRunning = tailnetRunning
      ..tailnetNodes = List<dynamic>.from(tailnetNodes)
      ..wgPeers = List<dynamic>.from(wgPeers)
      ..measuredSpeedMiBs = measuredSpeedMiBs
      ..pathSpeeds = Map<String, double>.from(_pathSpeeds);
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('device not discovered on the approved LAN') ||
        s.contains('device not discovered on the selected LAN')) {
      return 'Not currently discovered on the selected LAN.';
    }
    final match = RegExp(r'"message":"([^"]+)"').firstMatch(s);
    if (match != null) {
      return match.group(1)!;
    }
    return s;
  }

  bool _isDirectSubPath({String? iface, String? kind}) {
    final i = iface ?? '';
    final k = kind ?? '';
    return k == 'wifi_direct' ||
        k == 'hotspot' ||
        k == 'wifi_join' ||
        i.startsWith('p2p') ||
        i.startsWith('dbp2p') ||
        i.startsWith('ap') ||
        i.startsWith('swlan') ||
        i.startsWith('rndis');
  }

  Future<void> _readTailnetStatus(int revision) async {
    try {
      final status = await widget.core.run(['tailnet', 'status']) as Map;
      if (!mounted || revision != _tailnetProbeRevision) return;
      tailnetRunning = status['state'] == 'Running';
      tailnetNodes = status['peers'] as List? ?? [];
      _tailnetStarting =
          status['state'] == 'Starting' || status['state'] == 'NoState';
    } catch (error) {
      if (!mounted || revision != _tailnetProbeRevision) return;
      tailnetRunning = false;
      tailnetNodes = [];
      _tailnetStarting = '$error'.contains('app-only Tailscale is not running');
    }
  }

  Set<String> _configuredTailnetEndpoints(String activeTransport) => {
    if (connectionCfg?['tailnet_endpoint'] case final String endpoint
        when endpoint.trim().isNotEmpty)
      endpoint.trim(),
    if (activeTransport == 'tailnet')
      if (connectionCfg?['endpoint'] case final String endpoint
          when endpoint.trim().isNotEmpty)
        endpoint.trim(),
    if (peerCaps?['tailnet_endpoint'] case final String endpoint
        when endpoint.trim().isNotEmpty)
      endpoint.trim(),
  };

  Future<_ReachablePath?> _probeTailnetPath(
    String peerId,
    String activeTransport,
  ) async {
    if (_connectedTransport == 'tailnet') {
      return _pathFromResolve('tailnet', route!, remoteApproved: true);
    }
    if (!tailnetRunning) return null;
    final peerLower =
        '${widget.peer['advertised_name'] ?? widget.peer['name'] ?? ''}'
            .trim()
            .toLowerCase();
    final tsCandidates = _configuredTailnetEndpoints(activeTransport);
    for (final node in tailnetNodes) {
      final ips = (node['ips'] as List? ?? const []).whereType<String>().where(
        (ip) => !ip.contains(':'),
      );
      if (ips.isEmpty) continue;
      final ep = '${ips.first}:8731';
      final nodeName = '${node['name'] ?? ''}'.trim().toLowerCase();
      final dnsName = '${node['dns_name'] ?? ''}'.trim().toLowerCase();
      if (peerLower.isNotEmpty &&
          (nodeName == peerLower || dnsName.split('.').first == peerLower)) {
        tsCandidates.add(ep);
      }
    }
    if (tsCandidates.isEmpty) return null;
    final resolved = await _firstSuccessfulProbe(
      tsCandidates.map(
        (ep) => [
          '--transport',
          'tailnet',
          '--endpoint',
          ep,
          '--approve-remote',
          'resolve',
          peerId,
        ],
      ),
    );
    return resolved == null
        ? null
        : _pathFromResolve('tailnet', resolved, remoteApproved: true);
  }

  void _retryTailnetPath({int attempt = 0, bool immediate = false}) {
    _tailnetRetry?.cancel();
    final revision = ++_tailnetProbeRevision;
    final peerId = widget.peer['id'] as String;
    if (!_tailnetReconnecting) {
      setState(() => _tailnetReconnecting = true);
    }
    final delay = immediate
        ? Duration.zero
        : Duration(seconds: 2 + attempt * 2);
    _tailnetRetry = Timer(delay, () async {
      await _readTailnetStatus(revision);
      if (!mounted || revision != _tailnetProbeRevision) return;
      final transport = connectionCfg?['transport'] as String? ?? 'lan';
      final path = await _probeTailnetPath(peerId, transport);
      if (!mounted || revision != _tailnetProbeRevision) return;
      if (path != null) {
        setState(() {
          reachablePaths = [
            ...reachablePaths.where((p) => p.transport != 'tailnet'),
            path,
          ];
        });
        await _selectAutomaticPath(_loadRevision);
        _savePeerCache();
      } else if (attempt < 3 && (_tailnetStarting || tailnetRunning)) {
        _retryTailnetPath(attempt: attempt + 1);
        return;
      }
      if (mounted && revision == _tailnetProbeRevision) {
        setState(() => _tailnetReconnecting = false);
        if (path == null) await _selectAutomaticPath(_loadRevision);
      }
    });
  }

  void _retryConnection() {
    if (connectionCfg?['transport'] == 'tailnet' && _canAutoConnectTailnet) {
      _retryTailnetPath(immediate: true);
      return;
    }
    setState(() => busy = true);
    unawaited(load());
  }

  Future<void> _fetchRoots(String peerId, _ReachablePath path) async {
    try {
      final loaded = await widget.core.run([
        ..._controlPrefixArgs(path),
        'roots',
        peerId,
      ]) as List;
      if (!mounted || !identical(route, path.resolved)) return;
      setState(() => roots = loaded);
      _savePeerCache();
    } catch (error) {
      DebugTrace.logCore('DeviceDetail', 'Folder list unavailable: $error');
    }
  }

  Map<String, dynamic> _mergePeerCaps(Map caps, {Object? features}) {
    final merged = Map<String, dynamic>.from(caps);
    merged['checked_at_utc'] ??= DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _peerCapsCached = false;
    if (features is List) {
      merged['features'] = List<dynamic>.from(features);
    } else if (!merged.containsKey('features') &&
        peerCaps?['features'] is List) {
      merged['features'] = List<dynamic>.from(peerCaps!['features'] as List);
    }
    return merged;
  }

  Future<void> _fetchPeerCapsBackground(
    String peerId,
    _ReachablePath path,
  ) async {
    try {
      final capArgs = <String>[
        if (path.interfaceName != null &&
            path.interfaceName!.isNotEmpty &&
            path.cidr != null &&
            path.cidr!.isNotEmpty) ...[
          '--interface',
          path.interfaceName!,
          '--lan-cidr',
          path.cidr!,
        ],
        '--transport',
        path.transport == 'direct-lan-v1' ? 'lan' : path.transport,
        if (path.endpoint.isNotEmpty) ...['--endpoint', path.endpoint],
        if (path.remoteApproved || path.transport == 'tailnet')
          '--approve-remote',
        'peer-caps',
        peerId,
      ];
      final capsRes = await _probeOne(capArgs);
      if (capsRes != null &&
          (capsRes['capabilities'] is Map || capsRes['features'] is List) &&
          mounted) {
        setState(() {
          final capsMap = capsRes['capabilities'] is Map
              ? capsRes['capabilities'] as Map
              : (peerCaps ?? const <String, dynamic>{});
          peerCaps = _mergePeerCaps(capsMap, features: capsRes['features']);
        });
        _savePeerCache();
      }
    } catch (_) {}
  }

  Future<void> _recoverPath(_ReachablePath preferred, int revision) async {
    final previousRoute = route;
    if (_recoveringPath ||
        !mounted ||
        revision != _loadRevision ||
        busy ||
        (preferred.transport == 'tailnet' && !_canAutoConnectTailnet)) {
      return;
    }
    _recoveringPath = true;
    final peerId = widget.peer['id'] as String;
    try {
      if (preferred.transport == 'lan' &&
          preferred.interfaceName != null &&
          preferred.cidr != null &&
          (widget.core.network?['interface'] != preferred.interfaceName ||
              widget.core.network?['cidr'] != preferred.cidr)) {
        final roaming =
            widget.core.network?['allow_wifi_roaming'] == true ||
            preferred.networkMap?['allow_wifi_roaming'] == true;
        await widget.core.approveNetwork({
          ...(preferred.networkMap ??
              {
                'interface': preferred.interfaceName,
                'cidr': preferred.cidr,
                if (preferred.kind != null) 'kind': preferred.kind,
              }),
          if (roaming) 'allow_wifi_roaming': true,
        });
      }
      if (!mounted ||
          revision != _loadRevision ||
          !identical(route, previousRoute) ||
          busy) {
        return;
      }
      final cur = Map<String, dynamic>.from(
        await widget.core.run(['connection', peerId]) as Map,
      );
      if (!mounted ||
          revision != _loadRevision ||
          !identical(route, previousRoute) ||
          busy) {
        return;
      }
      final tr = preferred.transport == 'direct-lan-v1'
          ? 'lan'
          : preferred.transport;
      final alreadySelected =
          tr == 'tailnet' &&
          cur['transport'] == tr &&
          (cur['endpoint'] ?? cur['tailnet_endpoint']) == preferred.endpoint;
      final saved = alreadySelected
          ? cur
          : await widget.core.run(
              ['connection', peerId, '-'],
              input: jsonEncode({
                ...cur,
                'transport': tr,
                'preferred_transport': _preferredTransport,
                'active_link': '',
                if (tr != 'lan') 'endpoint': preferred.endpoint,
                if (tr == 'lan') 'lan_endpoint': preferred.endpoint,
                if (tr == 'tailnet') 'tailnet_endpoint': preferred.endpoint,
                if (tr == 'adb') 'adb_endpoint': preferred.endpoint,
                if (tr == 'wireguard') 'wireguard_endpoint': preferred.endpoint,
              }),
            );
      if (!mounted ||
          revision != _loadRevision ||
          !identical(route, previousRoute) ||
          busy) {
        return;
      }
      setState(() {
        connectionCfg = Map<String, dynamic>.from(saved as Map);
        route = preferred.resolved;
        roots = [];
        offlineNote = null;
      });
      unawaited(_fetchRoots(peerId, preferred));
      DebugTrace.logFlow(
        'DeviceDetail',
        'Reconnected via ${preferred.transport} (${preferred.endpoint})',
      );
    } catch (e) {
      DebugTrace.logCore('DeviceDetail', 'Auto-promote fallback failed: $e');
    } finally {
      _recoveringPath = false;
    }
  }

  Future<void> load({bool background = false, bool checkStored = true}) async {
    final revision = ++_loadRevision;
    _tailnetRetry?.cancel();
    final tailnetRevision = ++_tailnetProbeRevision;
    _tailnetReconnecting = false;
    final peerId = widget.peer['id'] as String;
    if (!background) {
      offlineNote = null;
    }
    await Future.wait([
      () async {
        try {
          _linkOperation = Map<String, dynamic>.from(
            await widget.core.run(['link-operation', peerId]) as Map,
          );
        } catch (_) {}
      }(),
      () async {
        try {
          final method =
              await widget.core.run(['peer-ssh-method', peerId]) as Map;
          final hosts = await widget.core.run(['ssh-hosts']) as List;
          _sshMethod = method['method'] as String? ?? 'auto';
          _sshHosts = hosts
              .whereType<Map>()
              .map((h) => Map<String, dynamic>.from(h))
              .toList();
        } catch (_) {}
      }(),
      () async {
        try {
          _rules = await NetworkRules.load(widget.core);
        } catch (_) {}
      }(),
      () async {
        try {
          _sshAccess = Map<String, dynamic>.from(
            await widget.core.run(['peer-ssh-access', peerId]) as Map,
          );
        } catch (_) {}
      }(),
      () async {
        try {
          final ev = await widget.core.run(['acl', 'eval', peerId]);
          if (ev is Map) {
            _aclEval = Map<String, dynamic>.from(ev);
          }
        } catch (_) {}
      }(),
      () async {
        try {
          connectionCfg = Map<String, dynamic>.from(
            await widget.core.run(['connection', peerId]) as Map,
          );
        } catch (_) {
          connectionCfg = null;
        }
      }(),
      _readTailnetStatus(tailnetRevision),
      () async {
        try {
          final wg = await widget.core.run(['wireguard', 'status']) as Map;
          final st = '${wg['state'] ?? wg['status'] ?? ''}'.toLowerCase();
          wgRunning =
              st == 'running' ||
              st == 'active' ||
              st == 'up' ||
              wg['running'] == true ||
              wg['configured'] == true;
          wgPeers = wg['peers'] as List? ?? [];
        } catch (_) {
          wgRunning = false;
          wgPeers = [];
        }
      }(),
      () async {
        try {
          platformCaps = await widget.core.platformCapabilities();
        } catch (_) {
          platformCaps = {};
        }
      }(),
      () async {
        try {
          final activeDirect = await widget.core.activeDirectLink();
          _localLeaseStage = activeDirect['local_lease_stage'] as String?;
          _localLeaseDeadlineMs = (activeDirect['local_lease_deadline'] as num?)
              ?.toInt();
          final saved = activeDirect['saved'];
          _savedHostOpen = false;
          _savedDirect = saved is Map && saved['peer_id'] == peerId
              ? Map<String, dynamic>.from(saved)
              : null;
          if (activeDirect['active'] == true) {
            _resumedDirect = activeDirect;
            final kind = activeDirect['kind'];
            final savedJoinMatches =
                kind == 'wifi_join' &&
                _savedDirect?['joined'] == true &&
                _savedDirect?['ssid'] == activeDirect['ssid'];
            final joinedHotspot =
                kind == 'wifi_join' &&
                (savedJoinMatches
                    ? (_savedDirect?['kind'] == 'hotspot')
                    : '${activeDirect['ssid'] ?? ''}'.startsWith('DB-AP-'));
            activeDirectKind = '${activeDirect['kind'] ?? ''}'.isNotEmpty
                ? '${activeDirect['kind']}'
                : activeDirectKind;
            _directLinkMeta = {
              'interface': '${activeDirect['interface'] ?? ''}',
              'cidr': activeDirect['cidr'],
              'kind': savedJoinMatches
                  ? (_savedDirect?['kind'])
                  : (joinedHotspot ? 'hotspot' : kind),
              if (kind == 'hotspot' || joinedHotspot)
                'hotspot_host': (Platform.isAndroid != joinedHotspot)
                    ? 'phone'
                    : 'laptop',
              'band': '${activeDirect['band'] ?? ''}',
              'channel': (activeDirect['channel'] as num?)?.toInt() ?? 0,
              'frequency_mhz':
                  (activeDirect['frequency_mhz'] as num?)?.toInt() ?? 0,
              'bandwidth_mhz':
                  (activeDirect['bandwidth_mhz'] as num?)?.toInt() ?? 0,
              'wifi_standard': '${activeDirect['wifi_standard'] ?? ''}',
              'ssid': '${activeDirect['ssid'] ?? ''}',
            };
            if (_preDirectNetwork == null) {
              final nets = await widget.core.networks();
              for (final n in nets) {
                if (!_isDirectSubPath(
                  iface: '${n['interface'] ?? ''}',
                  kind: '${n['kind'] ?? ''}',
                )) {
                  _preDirectNetwork = Map<String, dynamic>.from(n);
                  break;
                }
              }
            }
          } else {
            _resumedDirect = null;
            _keptUnconnectedDirect = false;
            activeDirectKind = null;
          }
        } catch (_) {}
      }(),
    ]);
    if (!mounted || revision != _loadRevision) return;
    if (widget.peer['status'] == 'revoked') {
      route = null;
      roots = [];
      reachablePaths = [];
      _resumedDirect = null;
      _keptUnconnectedDirect = false;
      activeDirectKind = null;
      probingPaths = false;
      offlineNote = 'This device is revoked. Remove it or re-pair from an active device to reconnect.';
      if (mounted) {
        setState(() => busy = false);
      }
      _savePeerCache();
      return;
    }
    // Render loaded metadata & cached/resumed state immediately without blocking the UI.
    if (mounted) {
      setState(() {
        busy = false;
        probingPaths = !background && testingPathId == null;
      });
    }
    await Future.wait([
      if (checkStored)
        () async {
          try {
            final resolved = Map<String, dynamic>.from(
              await _resolveSelectedRoute(peerId),
            );
            if (!mounted || revision != _loadRevision) return;
            route = resolved;
            roots = [];
            offlineNote = null;
            final activeTr =
                '${connectionCfg?['transport'] ?? resolved['transport'] ?? 'lan'}';
            final normTr = activeTr == 'direct-lan-v1' ? 'lan' : activeTr;
            final activeIface =
                resolved['interface'] as String? ??
                widget.core.network?['interface'] as String?;
            final initialPath = _pathFromResolve(
              normTr,
              resolved,
              interfaceName: normTr == 'lan' ? activeIface : null,
              cidr: normTr == 'lan'
                  ? (widget.core.network?['cidr'] as String?)
                  : null,
              kind: normTr == 'lan'
                  ? (widget.core.network?['kind'] as String?)
                  : null,
              remoteApproved: normTr == 'tailnet',
              networkMap: normTr == 'lan' ? widget.core.network : null,
              labelOverride: normTr == 'adb' ? 'ADB over USB' : null,
            );
            if (reachablePaths.isEmpty && initialPath.endpoint.isNotEmpty) {
              reachablePaths = [initialPath];
            }
            unawaited(_fetchRoots(peerId, initialPath));
            if (peerCaps == null) {
              unawaited(_fetchPeerCapsBackground(peerId, initialPath));
            }
            if (mounted) {
              if (!_startingDirect &&
                  (testMessage?.contains('waiting for peer') == true)) {
                testMessage = null;
              }
              setState(() {});
            }
          } catch (e) {
            if (!mounted || revision != _loadRevision) return;
            route = null;
            roots = [];
            offlineNote = _friendlyError(e);
          }
        }(),
      () async {
        final activeIface =
            '${route?['interface'] ?? widget.core.network?['interface'] ?? ''}';
        try {
          _localLinkInfo = await widget.core.linkDetails(
            interfaceName: activeIface,
          );
        } catch (_) {
          _localLinkInfo = {};
        }
      }(),
    ]);
    if (!mounted || revision != _loadRevision) return;
    final probed = await _probeReachablePaths(
      onPartial: (partial) {
        if (!mounted || revision != _loadRevision || partial.isEmpty || busy) {
          return;
        }
        setState(() => reachablePaths = partial);
      },
    );
    if (!mounted || revision != _loadRevision) return;
    if (probed.isNotEmpty) {
      unawaited(_fetchPeerCapsBackground(peerId, probed.first));
    }
    if (mounted) {
      setState(() {
        reachablePaths = probed;
        probingPaths = false;
        busy = false;
      });
    }
    await _selectAutomaticPath(revision);
    if (!mounted || revision != _loadRevision) return;
    if (mounted &&
        (_tailnetStarting || tailnetRunning) &&
        !probed.any((path) => path.transport == 'tailnet')) {
      _retryTailnetPath();
    }
    if (mounted && _savedDirect?['joined'] == true && _resumedDirect == null) {
      unawaited(_checkSavedDirectHost(peerId));
    }
    _savePeerCache();
    DebugTrace.logFlow(
      'DeviceDetail',
      'Loaded ${widget.peer['name']} · ${probed.length} path(s), route=${route?['transport'] ?? 'offline'}',
    );
  }

  String _lanLabel(String? iface, String? kind, {String? hotspotHost}) {
    final i = iface ?? '';
    final k = kind ?? '';
    if (k == 'wifi_direct' || i.startsWith('p2p')) {
      return 'Wi-Fi Direct';
    }
    if (k == 'hotspot' || i.startsWith('ap') || i.startsWith('swlan')) {
      return hotspotHost == 'laptop' ? 'Laptop Hotspot' : 'Mobile Hotspot';
    }
    if (i.startsWith('rndis') || i.startsWith('usb')) return 'USB network';
    if (k == 'ethernet' || i.startsWith('eth') || i.startsWith('en')) {
      return 'Ethernet';
    }
    return 'Wi-Fi';
  }

  String _adbLabel() => 'ADB over USB';

  _ReachablePath _pathFromResolve(
    String transport,
    Map<String, dynamic> r, {
    String? interfaceName,
    String? cidr,
    String? kind,
    String? labelOverride,
    bool remoteApproved = false,
    Map<String, dynamic>? networkMap,
  }) {
    final verifiedCaps = r['capabilities'];
    if (verifiedCaps is Map) {
      peerCaps = _mergePeerCaps(verifiedCaps, features: r['features']);
    } else if (r['features'] is List) {
      peerCaps = _mergePeerCaps(
        peerCaps ?? const <String, dynamic>{},
        features: r['features'],
      );
    }
    final reportedIface = interfaceName ?? r['interface'] as String?;
    final iface = reportedIface?.isNotEmpty == true ? reportedIface : null;
    final endpoint = '${r['endpoint'] ?? ''}';
    final matchesDirectLink =
        transport == 'lan' &&
        iface == _directLinkMeta['interface'] &&
        _inSameSubnet(endpoint, _directLinkMeta['cidr'] as String?);
    final linkKind =
        (matchesDirectLink ? _directLinkMeta['kind'] as String? : null) ?? kind;
    final rttNs = r['rtt'] as num? ?? 0;
    final ms = rttNs > 0 ? rttNs / 1000000.0 : null;
    final label =
        labelOverride ??
        (transport == 'lan'
            ? _lanLabel(
                iface,
                linkKind,
                hotspotHost: matchesDirectLink
                    ? _directLinkMeta['hotspot_host'] as String?
                    : null,
              )
            : (transport == 'adb' ? _adbLabel() : _methodLabel(transport)));
    return _ReachablePath(
      transport: transport,
      label: label,
      endpoint: endpoint,
      interfaceName: iface,
      cidr: cidr,
      kind: linkKind,
      rttMs: ms,
      pathKind: r['path_kind'] as String?,
      relay: r['relay'] as String?,
      remoteApproved: remoteApproved,
      networkMap: networkMap,
      resolved: r,
    );
  }

  Future<Map<String, dynamic>?> _probeOne(List<String> args) async {
    try {
      final raw = await widget.core.run(args);
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
    } catch (_) {}
    return null;
  }

  Set<String> _knownLanEndpoints(String peerId) => {
    if (connectionCfg?['lan_endpoint'] case final String endpoint) endpoint,
    for (final candidate in widget.candidates)
      if (candidate['device_id'] == peerId) '${candidate['endpoint'] ?? ''}',
    for (final address in widget.peer['addresses'] as List? ?? const [])
      '${address['endpoint'] ?? ''}',
  };

  Future<Map> _resolveSelectedRoute(String peerId) async {
    final cidr = widget.core.network?['cidr'] as String?;
    final transport = connectionCfg?['transport'] as String? ?? 'lan';
    final endpoints = _knownLanEndpoints(peerId)
        .where((endpoint) => _inSameSubnet(endpoint, cidr));
    if (transport != 'lan' || endpoints.isEmpty) {
      return await widget.core.run(['resolve', peerId]) as Map;
    }
    final resolved = await _firstSuccessfulProbe([
      for (final endpoint in endpoints)
        ['--transport', 'lan', '--endpoint', endpoint, 'resolve', peerId],
      ['resolve', peerId],
    ]);
    if (resolved == null) {
      throw StateError('device not discovered on the selected LAN');
    }
    return resolved;
  }

  Future<Map<String, dynamic>?> _firstSuccessfulProbe(
    Iterable<List<String>> commands,
  ) {
    final result = Completer<Map<String, dynamic>?>();
    var remaining = commands.length;
    if (remaining == 0) result.complete(null);
    for (final args in commands) {
      unawaited(
        _probeOne(args).then((path) {
          remaining--;
          if (!result.isCompleted && (path != null || remaining == 0)) {
            result.complete(path);
          }
        }),
      );
    }
    return result.future;
  }

  Future<List<_ReachablePath>> _probeReachablePaths({
    void Function(List<_ReachablePath> current)? onPartial,
    bool lanOnly = false,
  }) async {
    final peerId = widget.peer['id'] as String;
    final activeTransport = connectionCfg?['transport'] as String? ?? 'lan';
    final addresses = widget.peer['addresses'] as List? ?? const [];
    final adbEp = connectionCfg?['adb_endpoint'] as String?;
    final sshEp = connectionCfg?['ssh_endpoint'] as String?;
    final wgEp = connectionCfg?['wireguard_endpoint'] as String?;
    final found = <_ReachablePath>[];
    final seen = <String>{};

    void addPath(_ReachablePath path) {
      if (!_rules.path(
            path.transport,
            kind: path.kind,
            interfaceName: path.interfaceName,
          ) ||
          path.endpoint.isEmpty ||
          !seen.add(path.id)) {
        return;
      }
      found.add(path);
    }

    List<Map<String, dynamic>> localNets = [];
    try {
      localNets = await widget.core.networks();
    } catch (_) {}

    Map<String, dynamic>? findLocalNet(String? iface) {
      if (iface == null || iface.isEmpty) {
        return null;
      }
      for (final n in localNets) {
        if ('${n['interface'] ?? ''}' == iface) {
          return n;
        }
      }
      return null;
    }

    final lanPaths = <_ReachablePath>[];
    final tailnetPaths = <_ReachablePath>[];
    final wgPaths = <_ReachablePath>[];
    final adbPaths = <_ReachablePath>[];
    final sshPaths = <_ReachablePath>[];

    late void Function() publishPaths;
    final knownLanEndpoints = _knownLanEndpoints(peerId);

    Future<void> probeLan() async {
      final approved = widget.core.network;
      final approvedInterface = approved?['interface'] as String?;
      final approvedNetwork = findLocalNet(approvedInterface) ?? approved;
      final nets = <Map<String, dynamic>>[
        ?approvedNetwork,
        ...localNets.where((net) => net['interface'] != approvedInterface),
      ];
      if (_connectedTransport == 'lan') {
        lanPaths.add(
          _pathFromResolve(
            'lan',
            route!,
            interfaceName: approvedInterface,
            cidr: approvedNetwork?['cidr'] as String?,
            kind: approvedNetwork?['kind'] as String?,
            networkMap: approvedNetwork,
          ),
        );
        publishPaths();
      }

      // Check other direct interfaces before the router link.
      final remainingNets = nets.where(
        (net) => !_isDirectSubPath(
          iface: net['interface'] as String?,
          kind: net['kind'] as String?,
        ),
      );
      final orderedNets = [
        ...nets.where(
          (net) => _isDirectSubPath(
            iface: net['interface'] as String?,
            kind: net['kind'] as String?,
          ),
        ),
        ...remainingNets,
      ];
      for (final net in orderedNets) {
        final iface = '${net['interface'] ?? ''}';
        final cidr = '${net['cidr'] ?? ''}';
        final kind = '${net['kind'] ?? ''}';
        final isDirect = _isDirectSubPath(iface: iface, kind: kind);
        if (iface.isEmpty ||
            cidr.isEmpty ||
            kind == 'cellular' ||
            !_rules.path('lan', kind: kind, interfaceName: iface) ||
            (iface.startsWith('rndis') &&
                !_inSameSubnet(
                  '${connectionCfg?['lan_endpoint'] ?? ''}',
                  cidr,
                )) ||
            lanPaths.any(
              (path) => path.interfaceName == iface && path.cidr == cidr,
            )) {
          continue;
        }
        final prefix = [
          '--interface',
          iface,
          '--lan-cidr',
          cidr,
          '--transport',
          'lan',
        ];
        final candidates = knownLanEndpoints
            .where((ep) => _inSameSubnet(ep, cidr))
            .toSet();
        var resolved = await _firstSuccessfulProbe([
          for (final ep in candidates)
            [...prefix, '--endpoint', ep, 'resolve', peerId],
          [...prefix, 'resolve', peerId],
        ]);
        if (resolved == null &&
            !isDirect &&
            _rules.path('lan', kind: kind, interfaceName: iface)) {
          // Foreground recovery: a restarted Agent may advertise a new port on
          // the same interface. Discovery is a hint; resolve still pins identity.
          try {
            final fresh =
                await widget.core.run([...prefix, 'discover']) as List;
            resolved = await _firstSuccessfulProbe([
              for (final hint in fresh.whereType<Map>())
                if (hint['device_id'] == peerId &&
                    _inSameSubnet('${hint['endpoint']}', cidr))
                  [
                    ...prefix,
                    '--endpoint',
                    '${hint['endpoint']}',
                    'resolve',
                    peerId,
                  ],
            ]);
          } catch (_) {}
        }
        if (resolved == null && isDirect && Platform.isAndroid) {
          try {
            final neighbors = await widget.core.directLinkNeighbors(iface);
            resolved = await _firstSuccessfulProbe([
              for (final ip in neighbors)
                if (!candidates.contains('$ip:8731'))
                  [...prefix, '--endpoint', '$ip:8731', 'resolve', peerId],
            ]);
          } catch (_) {}
        }
        if (resolved == null) continue;
        lanPaths.add(
          _pathFromResolve(
            'lan',
            resolved,
            interfaceName: iface,
            cidr: cidr,
            kind: kind,
            networkMap: net,
          ),
        );
        publishPaths();
      }
    }

    Future<void> probeTailnet() async {
      final path = await _probeTailnetPath(peerId, activeTransport);
      if (path != null) tailnetPaths.add(path);
    }

    Future<void> probeWireguard() async {
      if (_connectedTransport == 'wireguard') {
        wgPaths.add(_pathFromResolve('wireguard', route!));
        return;
      }
      if (!wgRunning) return;
      final wgCandidates = <String>{
        if (wgEp != null && wgEp.isNotEmpty) wgEp,
        ...(peerCaps?['wireguard_endpoints'] as List? ?? const [])
            .whereType<String>(),
      }.toList();
      for (final p in wgPeers.whereType<Map>()) {
        if (p['peer_id'] != peerId) continue;
        final ip = '${p['tunnel_ip'] ?? ''}'.split('/').first;
        if (InternetAddress.tryParse(ip) != null) {
          wgCandidates.add(
            '${ip.contains(':') ? '[$ip]' : ip}:${p['bridge_port'] ?? 8731}',
          );
        }
      }
      if (wgCandidates.isEmpty) return;
      final result = await _firstSuccessfulProbe(
        wgCandidates.map(
          (ep) => [
            '--transport',
            'wireguard',
            '--endpoint',
            ep,
            'resolve',
            peerId,
          ],
        ),
      );
      if (result != null) {
        wgPaths.add(_pathFromResolve('wireguard', result));
      }
    }

    Future<void> probeAdb() async {
      if (!_canUseUsbAdb) return;
      final probedAdbEps = <String>{};
      if (activeTransport == 'adb' && route != null) {
        final activeAdbEp = '${route!['endpoint'] ?? ''}'.trim();
        if (!activeAdbEp.endsWith(':18732')) {
          if (activeAdbEp.isNotEmpty) probedAdbEps.add(activeAdbEp);
          adbPaths.add(
            _pathFromResolve(
              'adb',
              route!,
              kind: 'usb',
              labelOverride: 'ADB over USB',
            ),
          );
        }
      }
      if (!Platform.isAndroid) {
        try {
          final rawAdb = await widget.core.run(['adb-devices']);
          if (rawAdb is List) {
            for (final d in rawAdb) {
              if (d is! Map || d['kind'] == 'wireless') continue;
              final ep = '${d['endpoint'] ?? ''}'.trim();
              if (ep.isNotEmpty) probedAdbEps.add(ep);
            }
          }
        } catch (_) {}
      }
      final candidateAdb =
          <String>{
                ...probedAdbEps,
                if (Platform.isAndroid) ...[
                  '127.0.0.1:18731',
                  for (final addr in addresses)
                    if ('${addr['endpoint'] ?? ''}'.startsWith('127.0.0.1:') &&
                        !'${addr['endpoint'] ?? ''}'.endsWith(':8022') &&
                        !'${addr['endpoint'] ?? ''}'.endsWith(':18732'))
                      '${addr['endpoint']}',
                ],
                if (adbEp != null &&
                    adbEp.isNotEmpty &&
                    !adbEp.endsWith(':8022') &&
                    !adbEp.endsWith(':18732'))
                  adbEp,
              }
              .where(
                (ep) =>
                    !(activeTransport == 'adb' &&
                        route != null &&
                        '${route!['endpoint'] ?? ''}'.trim() == ep),
              )
              .toList();
      if (candidateAdb.isEmpty) return;
      final results = await Future.wait(
        candidateAdb.map(
          (ep) => _probeOne([
            '--transport',
            'adb',
            '--endpoint',
            ep,
            'resolve',
            peerId,
          ]),
        ),
      );
      for (final r in results) {
        if (r != null) {
          adbPaths.add(
            _pathFromResolve(
              'adb',
              r,
              kind: 'usb',
              labelOverride: 'ADB over USB',
            ),
          );
        }
      }
    }

    Future<void> probeSsh() async {
      if (activeTransport == 'ssh' && route != null) {
        sshPaths.add(_pathFromResolve('ssh', route!));
      } else if (sshEp != null && sshEp.isNotEmpty) {
        final r = await _probeOne([
          '--transport',
          'ssh',
          '--endpoint',
          sshEp,
          'resolve',
          peerId,
        ]);
        if (r != null) {
          sshPaths.add(_pathFromResolve('ssh', r));
        }
      }
    }

    List<_ReachablePath> snapshotPaths() {
      final merged = <_ReachablePath>[];
      final s = <String>{};
      for (final p in [
        ...lanPaths,
        ...tailnetPaths,
        ...wgPaths,
        ...adbPaths,
        ...sshPaths,
      ]) {
        if (_rules.path(
              p.transport,
              kind: p.kind,
              interfaceName: p.interfaceName,
            ) &&
            p.endpoint.isNotEmpty &&
            s.add(p.id)) {
          merged.add(p);
        }
      }
      return merged;
    }

    publishPaths = () => onPartial?.call(snapshotPaths());

    Future<void> emitAfter(Future<void> work) async {
      await work;
      publishPaths();
    }

    await Future.wait([
      if (_rules.allows('direct')) emitAfter(probeLan()),
      if (!lanOnly) ...[
        if (_rules.allows('tailnet')) emitAfter(probeTailnet()),
        if (_rules.allows('wireguard')) emitAfter(probeWireguard()),
        if (_rules.allows('adb') && _rules.allows('usb')) emitAfter(probeAdb()),
        emitAfter(probeSsh()),
      ],
    ]);

    for (final p in snapshotPaths()) {
      addPath(p);
    }
    return found;
  }

  Future<void> selectConnection(
    String transport, {
    String? pathId,
    String? endpoint,
    bool? remoteApproved,
    bool silentProgress = false,
    bool fastDirectConnect = false,
    String? preferredLink,
  }) async {
    final peerId = widget.peer['id'] as String;
    _loadRevision++;
    setState(() {
      busy = true;
      probingPaths = false;
      offlineNote = null;

      testingPathId = pathId;
      testSuccess = null;

      measuredSpeedMiBs = pathId != null ? _pathSpeeds[pathId] : null;
      if (!silentProgress) {
        testMessage = null;
      }
    });
    final sw = Stopwatch()..start();
    var connected = false;
    try {
      final prefix = <String>[
        '--transport',
        transport,
        if (endpoint != null && endpoint.isNotEmpty) ...[
          '--endpoint',
          endpoint,
        ],
        if (transport == 'tailnet' || remoteApproved == true)
          '--approve-remote',
      ];
      final resolved = Map<String, dynamic>.from(
        await widget.core.run([...prefix, 'resolve', peerId]) as Map,
      );
      final iface =
          '${resolved['interface'] ?? widget.core.network?['interface'] ?? ''}';
      final lanNetwork = transport == 'lan' ? widget.core.network : null;
      final activePath = _pathFromResolve(
        transport,
        resolved,
        interfaceName: transport == 'lan' && iface.isNotEmpty ? iface : null,
        cidr: lanNetwork?['cidr'] as String?,
        kind: lanNetwork?['kind'] as String?,
        remoteApproved: remoteApproved == true || transport == 'tailnet',
        networkMap: lanNetwork,
        labelOverride: transport == 'adb' ? 'ADB over USB' : null,
      );
      final current = Map<String, dynamic>.from(
        await widget.core.run(['connection', peerId]) as Map,
      );
      final kind = _pathKind(activePath);
      final saved = await widget.core.run(
        ['connection', peerId, '-'],
        input: jsonEncode({
          ...current,
          'transport': transport,
          'preferred_transport': preferredLink == null
              ? kind
              : (current['preferred_transport'] ?? _preferredTransport),
          'preferred_link': ?preferredLink,
          'active_link': const {'hotspot', 'wifi_direct'}.contains(kind)
              ? kind
              : '',
          if (transport == 'lan' && kind != 'lan')
            'endpoint': activePath.endpoint,
          if (transport != 'lan') 'endpoint': activePath.endpoint,
          if (transport == 'lan' && kind == 'lan')
            'lan_endpoint': activePath.endpoint,
          if (transport == 'tailnet') 'tailnet_endpoint': activePath.endpoint,
          if (transport == 'adb') 'adb_endpoint': activePath.endpoint,
          if (transport == 'ssh') 'ssh_endpoint': activePath.endpoint,
          if (transport == 'wireguard')
            'wireguard_endpoint': activePath.endpoint,
        }),
      );
      connectionCfg = Map<String, dynamic>.from(saved as Map);
      route = resolved;
      roots = [];
      offlineNote = null;
      connected = true;
      final nextPaths = List<_ReachablePath>.from(reachablePaths)
        ..removeWhere(
          (p) =>
              p.id == activePath.id ||
              (activePath.transport == 'lan' &&
                  p.transport == 'lan' &&
                  activePath.interfaceName != null &&
                  p.interfaceName == activePath.interfaceName),
        )
        ..insert(0, activePath);
      reachablePaths = nextPaths;
      unawaited(_fetchRoots(peerId, activePath));
      unawaited(_fetchPeerCapsBackground(peerId, activePath));
      unawaited(() async {
        try {
          final info = await widget.core.linkDetails(interfaceName: iface);
          if (!mounted || !identical(route, resolved)) return;
          setState(() => _localLinkInfo = info);
          _savePeerCache();
        } catch (_) {}
      }());
    } catch (e) {
      offlineNote = _friendlyError(e);
    }
    sw.stop();
    if (connected) {
      DebugTrace.logFlow(
        'DeviceDetail',
        'Connected $transport (${route!['endpoint'] ?? ''}) in ${sw.elapsedMilliseconds} ms',
      );
      _savePeerCache();
    } else {
      DebugTrace.logError(
        'DeviceDetail',
        'Select connection $transport failed',
        error: offlineNote,
      );
    }
    if (!mounted) {
      return;
    }
    setState(() {
      busy = false;
      probingPaths = false;

      testingPathId = null;

      if (connected) {
        testSuccess = true;

        testMessage = null;
      } else {
        testSuccess = false;

        testMessage =
            'Connection failed · ${offlineNote ?? 'Device not reachable'}';
      }
    });
    if (fastDirectConnect && Platform.isAndroid) {
      _retryTailnetPath();
    }
    if (!fastDirectConnect && connected) {
      unawaited(() async {
        final refreshed = await _probeReachablePaths();
        if (mounted && refreshed.isNotEmpty) {
          setState(() => reachablePaths = refreshed);
          _savePeerCache();
        }
      }());
    }
  }

  bool _bothWifi6() =>
      platformCaps['wifi_6'] == true &&
      (peerCaps == null || peerCaps!['wifi_6'] == true);

  bool _bothWifi5G() =>
      platformCaps['wifi_5ghz'] == true &&
      (peerCaps == null || peerCaps!['wifi_5ghz'] == true);

  bool _bothWifi6G() =>
      platformCaps['wifi_6ghz'] == true && (peerCaps?['wifi_6ghz'] == true);

  static int freqToChannel(int freq) {
    if (freq == 2484) return 14;
    if (freq >= 2412 && freq <= 2472) return (freq - 2407) ~/ 5;
    if (freq >= 5150 && freq <= 5925) return (freq - 5000) ~/ 5;
    if (freq == 5935) return 2;
    if (freq >= 5955 && freq <= 7115) return (freq - 5950) ~/ 5;
    return 0;
  }

  static int channelToFreq(int ch) {
    if (ch == 14) return 2484;
    if (ch >= 1 && ch <= 13) return 2407 + ch * 5;
    if (ch >= 32 && ch <= 177) return 5000 + ch * 5;
    return 0;
  }

  List<int> _usable5GHzChannels() {
    final phoneRaw = (Platform.isAndroid
        ? platformCaps
        : peerCaps)?['usable_5ghz_channels'];
    final laptopRaw = (Platform.isAndroid
        ? peerCaps
        : platformCaps)?['usable_5ghz_channels'];
    final phoneSet = <int>{
      if (phoneRaw is List) ...phoneRaw.whereType<num>().map((e) => e.toInt()),
    };
    final laptopSet = <int>{
      if (laptopRaw is List)
        ...laptopRaw.whereType<num>().map((e) => e.toInt()),
    };
    Set<int> merged;
    if (phoneSet.isNotEmpty && laptopSet.isNotEmpty) {
      merged = phoneSet.intersection(laptopSet);
      if (merged.isEmpty) merged = phoneSet;
    } else if (phoneSet.isNotEmpty) {
      merged = phoneSet;
    } else if (laptopSet.isNotEmpty) {
      merged = laptopSet;
    } else if (_bothWifi5G()) {
      merged = {165, 161, 157, 153, 149};
    } else {
      merged = {};
    }
    final list = merged.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  int _autoHighestChannel() {
    final usable = _usable5GHzChannels();
    if (usable.isEmpty) return 0;
    // Ch 161 is the highest 80 MHz UNII-3 primary channel (165 is 20 MHz only).
    if (usable.contains(161)) return 161;
    return usable.first;
  }

  String _preferBandKey() {
    if (_selectedChannel != null) {
      return _selectedChannel! <= 14 ? '2ghz' : '5ghz';
    }
    if (_bothWifi6G()) {
      return '6ghz';
    }
    if (_bothWifi5G()) {
      return '5ghz';
    }
    return 'auto';
  }

  String _directBandSummary() {
    final ch = _selectedChannel;
    if (ch != null) {
      final f = channelToFreq(ch);
      final b = ch <= 14 ? '2.4 GHz' : '5 GHz';
      final bwTxt = _selectedBandwidthMhz > 0
          ? ' · $_selectedBandwidthMhz MHz'
          : '';
      return '$b · Ch $ch${f > 0 ? ' ($f MHz)' : ''}$bwTxt';
    }
    final autoCh = _autoHighestChannel();
    final chHint = autoCh > 0 ? ' · Auto Ch $autoCh' : '';
    if (_bothWifi6G()) {
      return '6 GHz · Wi-Fi 6E$chHint';
    }
    if (_bothWifi5G() && _bothWifi6()) {
      return '5 GHz · Wi-Fi 6 (802.11ax)$chHint';
    }
    if (_bothWifi5G()) {
      return '5 GHz$chHint';
    }
    return '2.4 GHz';
  }

  Future<void> _openChannelPicker() async {
    final usable = _usable5GHzChannels();
    final presets = <int>{...usable, 161, 149}.toList()
      ..sort((a, b) => b.compareTo(a));
    final laptopCaps = Platform.isAndroid ? peerCaps : platformCaps;
    final regCountry = '${laptopCaps?['reg_country'] ?? ''}'.trim();
    final regLimited = laptopCaps?['reg_5ghz_limited'] == true;
    final picked = await showDialog<({int? channel, int bandwidthMhz})>(
      context: context,
      builder: (_) => _ChannelPickerDialog(
        initialChannel: _selectedChannel,
        initialBandwidthMhz: _selectedBandwidthMhz,
        presets: presets,
        autoHighestChannel: _autoHighestChannel(),
        regCountry: regCountry,
        regLimited: regLimited,
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _selectedChannel = picked.channel;
        _selectedBandwidthMhz = picked.bandwidthMhz;
      });
    }
  }

  List<String> _controlPrefixArgs(_ReachablePath p, {bool bulk = false}) {
    final tr = p.transport == 'direct-lan-v1' ? 'lan' : p.transport;
    return [
      if (p.interfaceName != null &&
          p.interfaceName!.isNotEmpty &&
          p.cidr != null &&
          p.cidr!.isNotEmpty) ...[
        '--interface',
        p.interfaceName!,
        '--lan-cidr',
        p.cidr!,
      ],
      '--transport',
      tr,
      if (p.endpoint.isNotEmpty) ...['--endpoint', p.endpoint],
      if (bulk &&
          connectionCfg?['remote_approved'] == true &&
          (tr == 'tailnet' || tr == 'wireguard'))
        '--approve-remote',
    ];
  }

  List<_ReachablePath> _controlPathCandidates({bool allowAdb = true}) {
    final out = <_ReachablePath>[];
    final seen = <String>{};
    void add(_ReachablePath? p) {
      if (p == null) return;
      final norm = p.transport == 'direct-lan-v1' ? 'lan' : p.transport;
      if (!allowAdb && norm == 'adb') return;
      if (seen.add(p.id)) out.add(p);
    }

    add(_activeReachablePath());
    for (final tr in ['lan', 'adb', 'tailnet', 'wireguard']) {
      for (final p in reachablePaths) {
        final norm = p.transport == 'direct-lan-v1' ? 'lan' : p.transport;
        if (norm == tr) add(p);
      }
    }
    if (route != null) {
      final rawTr =
          '${route!['transport'] ?? connectionCfg?['transport'] ?? 'lan'}';
      final norm = rawTr == 'direct-lan-v1' ? 'lan' : rawTr;
      add(
        _pathFromResolve(
          norm,
          route!,
          interfaceName: norm == 'lan'
              ? (route!['interface'] as String? ??
                    widget.core.network?['interface'] as String?)
              : null,
          cidr: norm == 'lan'
              ? (widget.core.network?['cidr'] as String?)
              : null,
          kind: norm == 'lan'
              ? (widget.core.network?['kind'] as String?)
              : null,
          remoteApproved: norm == 'tailnet',
        ),
      );
    }
    return out;
  }

  _ReachablePath? _bestControlPath({bool allowAdb = true}) {
    final list = _controlPathCandidates(allowAdb: allowAdb);
    return list.isEmpty ? null : list.first;
  }

  Future<dynamic> _prepareLinkWithFallback(
    String peerId,
    Map<String, dynamic> body, {
    bool allowAdb = true,
  }) async {
    final candidates = _controlPathCandidates(allowAdb: allowAdb);
    if (candidates.isEmpty) {
      throw StateError(
        'An active control path (Wi-Fi, USB ADB, or Tailscale) is needed.',
      );
    }
    Object? lastErr;
    final leased =
        _startingDirect &&
        (peerCaps?['features'] as List? ?? const []).contains(
          'network-link-lease-v1',
        );
    if (leased) _leasedRemoteOperation = true;
    final payload = jsonEncode({
      ...body,
      if (leased && _linkOperation['id'] is String) ...{
        'operation_id': _linkOperation['id'],
        'lease_seconds': 120,
      },
    });
    for (final ctrl in candidates) {
      try {
        return await widget.core.run([
          ..._controlPrefixArgs(ctrl),
          'prepare-link',
          peerId,
          '-',
        ], input: payload);
      } catch (e) {
        lastErr = e;
      }
    }
    // If cached LAN IP went stale (e.g. peer DHCP lease renewed), refresh LAN discovery once.
    final net = widget.core.network;
    final iface = '${net?['interface'] ?? ''}'.trim();
    final cidr = '${net?['cidr'] ?? ''}'.trim();
    if (iface.isNotEmpty && cidr.isNotEmpty) {
      try {
        final disc = await widget.core.run([
          '--interface',
          iface,
          '--lan-cidr',
          cidr,
          'discover',
        ]);
        if (disc is List) {
          for (final item in disc) {
            if (item is Map && item['device_id'] == peerId) {
              final ep = '${item['endpoint'] ?? ''}'.trim();
              if (ep.isNotEmpty && !candidates.any((c) => c.endpoint == ep)) {
                return await widget.core.run([
                  '--interface',
                  iface,
                  '--lan-cidr',
                  cidr,
                  '--transport',
                  'lan',
                  '--endpoint',
                  ep,
                  'prepare-link',
                  peerId,
                  '-',
                ], input: payload);
              }
            }
          }
        }
      } catch (_) {}
    }
    throw lastErr!;
  }

  Future<void> _startAdbUsb(String? defaultHost) async {
    final peerId = widget.peer['id'] as String;
    setState(() {
      busy = true;
      offlineNote = null;

      testingPathId = 'start:adb_usb';
      testSuccess = null;

      testMessage = 'Configuring wired USB ADB reverse tunnel (tcp:18731)…';
    });
    try {
      if (!Platform.isAndroid) {
        final result =
            await widget.core.run(['adb-forward-peer', peerId]) as Map;
        await selectConnection(
          'adb',
          pathId: 'start:adb_usb',
          endpoint: result['endpoint'] as String,
          silentProgress: true,
        );
        return;
      } else {
        final usbSerial = '${platformCaps['usb_serial'] ?? ''}'.trim();
        final ctrl = _bestControlPath(allowAdb: false);
        var prepared = false;
        if (ctrl != null) {
          try {
            await widget.core.run(
              [..._controlPrefixArgs(ctrl), 'prepare-link', peerId, '-'],
              input: jsonEncode({
                'kind': 'adb_usb',
                if (usbSerial.isNotEmpty) 'serial': usbSerial,
              }),
            );
            prepared = true;
          } catch (_) {}
        }
        if (!prepared) {
          if (!mounted) {
            return;
          }
          setState(() => busy = false);
          final ranSsh = await _promptSshAdbReverse(defaultHost);
          if (!ranSsh || !mounted) {
            setState(() {
              testingPathId = null;
            });
            return;
          }
          setState(() => busy = true);
        }
      }
      final r = await _probeOne([
        '--transport',
        'adb',
        '--endpoint',
        '127.0.0.1:18731',
        'resolve',
        peerId,
      ]);
      if (r == null) {
        throw StateError(
          'USB ADB reverse ran, but 127.0.0.1:18731 did not respond. Verify host bridge-agent is running.',
        );
      }
      await selectConnection(
        'adb',
        pathId: 'start:adb_usb',
        endpoint: '${r['endpoint'] ?? '127.0.0.1:18731'}',
        silentProgress: true,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        busy = false;

        testingPathId = null;
        testSuccess = false;

        testMessage = 'USB ADB setup failed · ${_friendlyError(e)}';
      });
    }
  }

  Future<bool> _promptSshAdbReverse(String? defaultHost) async {
    final hostCtrl = TextEditingController(text: defaultHost ?? 'probook');
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    String? err;
    var ok = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Run adb reverse via SSH'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Builder(
                    builder: (_) {
                      final usbSerial = '${platformCaps['usb_serial'] ?? ''}'
                          .trim();
                      final serialFlag = usbSerial.isNotEmpty
                          ? '-s $usbSerial '
                          : '-s <serial> ';
                      return Text(
                        'No active Wi-Fi/Tailscale link reaches the laptop right now. Run "adb ${serialFlag}reverse tcp:18731 tcp:8731" over SSH (e.g. Tailscale host):',
                        style: const TextStyle(fontSize: 12),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: hostCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Laptop host / Tailscale name',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: userCtrl,
                    decoration: const InputDecoration(
                      labelText: 'SSH username',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password (optional for Tailscale/key)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: keyCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Private key PEM (optional)',
                    ),
                  ),
                  if (err != null) ...[
                    const SizedBox(height: 8),
                    SelectableText(err!, style: const TextStyle(fontSize: 12)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final host = hostCtrl.text.trim();
                final user = userCtrl.text.trim();
                if (host.isEmpty || user.isEmpty) {
                  setDlg(() => err = 'Host and SSH username required.');
                  return;
                }
                try {
                  final probe =
                      await widget.core.run(['ssh-probe', host, '22']) as Map;
                  final fp = '${probe['host_key_sha256'] ?? ''}';
                  final usbSerial = '${platformCaps['usb_serial'] ?? ''}'
                      .trim();
                  final sFlag = usbSerial.isNotEmpty ? '-s "$usbSerial" ' : '';
                  final sshCmd =
                      'ADB=\$(command -v adb || ls "\$HOME"/Android/[Ss]dk/platform-tools/adb 2>/dev/null | head -n1); '
                      '"\${ADB:-adb}" ${sFlag}reverse tcp:18731 tcp:8731 && '
                      '"\${ADB:-adb}" ${sFlag}forward tcp:0 tcp:8731';
                  await widget.core.run(
                    ['ssh-run', '-'],
                    input: jsonEncode({
                      'host': host,
                      'port': 22,
                      'user': user,
                      if (passCtrl.text.isNotEmpty) 'password': passCtrl.text,
                      if (keyCtrl.text.trim().isNotEmpty)
                        'private_key_pem': keyCtrl.text.trim(),
                      'expected_host_key': fp,
                      'command': sshCmd,
                    }),
                  );
                  ok = true;
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                  }
                } catch (e) {
                  setDlg(() => err = _friendlyError(e));
                }
              },
              child: const Text('Run adb reverse'),
            ),
          ],
        ),
      ),
    );
    hostCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
    keyCtrl.dispose();
    return ok;
  }

  Future<bool> _sendRestoreToPeer(String peerId) async {
    final candidates = <_ReachablePath>[
      if (route != null)
        _pathFromResolve(
          route!['transport'] as String? ?? 'lan',
          route!,
          interfaceName: route!['interface'] as String?,
          cidr: widget.core.network?['cidr'] as String?,
          kind: widget.core.network?['kind'] as String?,
          remoteApproved: true,
        ),
      ...reachablePaths.where((p) => p.transport == 'adb'),
      ..._preDirectPaths.where((p) => p.transport == 'adb'),
      ...reachablePaths.where(
        (p) => p.transport == 'lan' || p.transport == 'direct-lan-v1',
      ),
      ..._preDirectPaths.where(
        (p) => p.transport == 'lan' || p.transport == 'direct-lan-v1',
      ),
      ...reachablePaths.where(
        (p) => p.transport == 'tailnet' || p.transport == 'wireguard',
      ),
      ..._preDirectPaths.where(
        (p) => p.transport == 'tailnet' || p.transport == 'wireguard',
      ),
    ];
    for (final c in candidates) {
      try {
        await widget.core.run([
          ..._controlPrefixArgs(c),
          'restore-link',
          peerId,
        ]);
        return true;
      } catch (_) {}
    }
    final usbAdbReady =
        platformCaps['usb_adb'] == true ||
        platformCaps['usb_adb_connected'] == true;
    if (Platform.isAndroid && usbAdbReady) {
      try {
        await widget.core.run([
          '--transport',
          'adb',
          '--endpoint',
          '127.0.0.1:18731',
          'restore-link',
          peerId,
        ]);
        return true;
      } catch (_) {}
    }
    return false;
  }

  Future<void> _restorePreDirectState(
    String peerId, {
    bool forgetDirectLink = true,
  }) async {
    _directLinkMeta = {};
    activeDirectKind = null;
    _resumedDirect = null;
    _savedHostOpen = false;
    _keptUnconnectedDirect = false;
    try {
      await widget.core.stopDirectLink(forget: forgetDirectLink);
    } catch (_) {}
    if (Platform.isAndroid) {
      try {
        final nets = await widget.core.networks();
        final curIface = widget.core.network?['interface'] as String?;
        final curCidr = widget.core.network?['cidr'] as String?;
        Map<String, dynamic>? targetNet = _preDirectNetwork;
        if (targetNet == null ||
            !nets.any(
              (n) =>
                  '${n['interface'] ?? ''}' ==
                  '${targetNet?['interface'] ?? ''}',
            )) {
          targetNet = null;
          for (final n in nets) {
            if (!_isDirectSubPath(
              iface: '${n['interface'] ?? ''}',
              kind: '${n['kind'] ?? ''}',
            )) {
              targetNet = Map<String, dynamic>.from(n);
              break;
            }
          }
        }
        final targetIface = targetNet?['interface'] as String?;
        final targetCidr = targetNet?['cidr'] as String?;
        if (targetNet != null &&
            (curIface != targetIface ||
                (targetCidr != null &&
                    curCidr != null &&
                    curCidr != targetCidr))) {
          await widget.core.approveNetwork(targetNet);
        }
      } catch (_) {}
    }
    final prevEp = _preDirectLanEndpoint;
    final curCfg = connectionCfg;
    if (curCfg != null) {
      final curLanEp = '${curCfg['lan_endpoint'] ?? ''}'.trim();
      final isEphemeralEp =
          curLanEp.startsWith('10.95.') ||
          curLanEp.startsWith('192.168.49.') ||
          curLanEp.startsWith('10.42.');
      if ((prevEp != null && prevEp.isNotEmpty && curLanEp != prevEp) ||
          isEphemeralEp) {
        try {
          await widget.core.run(
            ['connection', peerId, '-'],
            input: jsonEncode({
              ...curCfg,
              'transport': 'lan',
              'active_link': '',
              'preferred_transport': 'auto',
              if (prevEp != null && prevEp.isNotEmpty)
                'lan_endpoint': prevEp
              else
                'lan_endpoint': '',
            }),
          );
        } catch (_) {}
      }
    }
  }

  Future<void> _capturePreDirectFallback() async {
    final curNet = widget.core.network;
    if (curNet != null &&
        !_isDirectSubPath(
          iface: '${curNet['interface'] ?? ''}',
          kind: '${curNet['kind'] ?? ''}',
        )) {
      _preDirectNetwork = Map<String, dynamic>.from(curNet);
    } else if (Platform.isAndroid && _preDirectNetwork == null) {
      try {
        final nets = await widget.core.networks();
        for (final n in nets) {
          if (!_isDirectSubPath(
            iface: '${n['interface'] ?? ''}',
            kind: '${n['kind'] ?? ''}',
          )) {
            _preDirectNetwork = Map<String, dynamic>.from(n);
            break;
          }
        }
      } catch (_) {}
    }
    _preDirectPaths = List<_ReachablePath>.from(reachablePaths);
    final savedLanEp = '${connectionCfg?['lan_endpoint'] ?? ''}'.trim();
    if (savedLanEp.isNotEmpty &&
        !savedLanEp.startsWith('10.95.') &&
        !savedLanEp.startsWith('192.168.49.')) {
      _preDirectLanEndpoint = savedLanEp;
    } else {
      for (final p in reachablePaths) {
        if ((p.transport == 'lan' || p.transport == 'direct-lan-v1') &&
            !_isDirectSubPath(iface: p.interfaceName, kind: p.kind) &&
            p.endpoint.isNotEmpty) {
          _preDirectLanEndpoint = p.endpoint;
          break;
        }
      }
    }
  }

  Future<void> _approveDirectInterface(
    String iface,
    String cidr,
    String kind,
  ) async {
    Map<String, dynamic> approveTarget = {
      'interface': iface,
      'cidr': cidr,
      'kind': kind,
    };
    try {
      final currentNets = await widget.core.networks();
      for (final n in currentNets) {
        if ('${n['interface'] ?? ''}' == iface &&
            '${n['cidr'] ?? ''}' == cidr) {
          approveTarget = Map<String, dynamic>.from(n);
          break;
        }
      }
    } catch (_) {}
    // Keep the Android network handle from ConnectivityManager, but record the
    // direct-link kind so headers, Stop and the active_link field stay correct
    // for a group the peer hosts on its own station interface.
    approveTarget['kind'] = kind;
    approveTarget['direct'] = true;
    await widget.core.approveNetwork(approveTarget);
  }

  Future<void> _waitForDirectPeerAndSelect({
    required String peerId,
    required String kind,
    required String label,
    required String iface,
    required String cidr,
    required String ssid,
    required String hostIp,
    required String pathId,
  }) async {
    String? peerEndpoint;
    final deadline = DateTime.now().add(const Duration(seconds: 38));
    var pollCount = 0;
    while (DateTime.now().isBefore(deadline) && peerEndpoint == null) {
      if (_cancellingDirect) {
        throw StateError('$label cancelled');
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_cancellingDirect) {
        throw StateError('$label cancelled');
      }
      final neighCandidates = <String>{};
      try {
        final neighs = await widget.core.directLinkNeighbors(iface);
        for (final ip in neighs) {
          if (ip != hostIp) {
            neighCandidates.add('$ip:8731');
          }
        }
      } catch (_) {}
      for (final ep in neighCandidates) {
        if (_cancellingDirect) {
          throw StateError('$label cancelled');
        }
        final r = await _probeOne([
          '--interface',
          iface,
          '--lan-cidr',
          cidr,
          '--transport',
          'lan',
          '--endpoint',
          ep,
          'resolve',
          peerId,
        ]);
        if (r != null) {
          peerEndpoint = '${r['endpoint'] ?? ep}';
          break;
        }
      }
      if (peerEndpoint != null) {
        break;
      }
      pollCount++;
      if (pollCount % 6 == 5) {
        try {
          final mdns = await widget.core.run([
            '--interface',
            iface,
            '--lan-cidr',
            cidr,
            'discover',
          ]);
          if (mdns is List) {
            for (final item in mdns) {
              if (item is Map && item['device_id'] == peerId) {
                final ep = '${item['endpoint'] ?? ''}'.trim();
                if (ep.isNotEmpty && !neighCandidates.contains(ep)) {
                  final r = await _probeOne([
                    '--interface',
                    iface,
                    '--lan-cidr',
                    cidr,
                    '--transport',
                    'lan',
                    '--endpoint',
                    ep,
                    'resolve',
                    peerId,
                  ]);
                  if (r != null) {
                    peerEndpoint = '${r['endpoint'] ?? ep}';
                    break;
                  }
                }
              }
            }
          }
        } catch (_) {}
      }
    }
    if (peerEndpoint == null) {
      throw StateError(
        'Peer did not respond on $iface${ssid.isNotEmpty ? ' ($ssid)' : ''} in time.',
      );
    }
    await _approveDirectInterface(iface, cidr, kind);
    await selectConnection(
      'lan',
      pathId: pathId,
      endpoint: peerEndpoint,
      silentProgress: true,
      fastDirectConnect: true,
    );
  }

  bool get _canJoinResumedDirectLink =>
      _bestControlPath(allowAdb: true) != null &&
      '${_resumedDirect?['ssid'] ?? ''}'.isNotEmpty &&
      '${_resumedDirect?['passphrase'] ?? ''}'.isNotEmpty;

  Future<void> _keepResumedDirectLink() async {
    final resumed = _resumedDirect;
    if (resumed == null || resumed['active'] != true) return;
    if (resumed['kind'] == 'wifi_join' &&
        _savedDirect?['joined'] == true &&
        _savedDirect?['ssid'] == resumed['ssid']) {
      await _connectSavedDirectLink(alreadyJoined: resumed);
      return;
    }
    final peerId = widget.peer['id'] as String;
    final kind = '${resumed['kind'] ?? activeDirectKind ?? 'wifi_direct'}';
    final label = kind == 'wifi_direct' ? 'Wi-Fi Direct' : 'Mobile Hotspot';
    final iface = '${resumed['interface'] ?? ''}';
    final cidr = '${resumed['cidr'] ?? ''}';
    final hostIp = '${resumed['ip'] ?? ''}';
    final ssid = '${resumed['ssid'] ?? ''}';
    final pass = '${resumed['passphrase'] ?? ''}';
    final band = '${resumed['band'] ?? _directBandSummary()}';

    await _capturePreDirectFallback();
    if (iface.isNotEmpty && cidr.isNotEmpty) {
      try {
        await _approveDirectInterface(iface, cidr, kind);
      } catch (_) {}
    }

    final ctrl = _bestControlPath(allowAdb: true);
    if (ctrl != null &&
        ssid.isNotEmpty &&
        pass.isNotEmpty &&
        iface.isNotEmpty &&
        cidr.isNotEmpty) {
      _startingDirect = true;
      _cancellingDirect = false;
      setState(() {
        busy = true;
        testingPathId = 'keep:direct';
        testSuccess = null;
        testMessage = 'Keeping $label ($ssid) and connecting peer…';
      });
      var armedPeer = false;
      try {
        await widget.core.run(
          [..._controlPrefixArgs(ctrl), 'prepare-link', peerId, '-'],
          input: jsonEncode({
            'kind': 'wifi_join',
            'mode': kind,
            'ssid': ssid,
            'passphrase': pass,
            'band': band,
          }),
        );
        armedPeer = true;
        if (_cancellingDirect) {
          throw StateError('$label cancelled');
        }
        await _waitForDirectPeerAndSelect(
          peerId: peerId,
          kind: kind,
          label: label,
          iface: iface,
          cidr: cidr,
          ssid: ssid,
          hostIp: hostIp,
          pathId: 'keep:direct',
        );
        DebugTrace.logFlow(
          'DirectLink',
          'Kept & connected $label ($ssid) on $iface',
        );
        if (mounted) {
          setState(() {
            _startingDirect = false;
            _cancellingDirect = false;
            _keptUnconnectedDirect = false;
            activeDirectKind = kind;
          });
        }
        return;
      } catch (e) {
        final wasCancelled = _cancellingDirect;
        DebugTrace.logError(
          'DirectLink',
          wasCancelled
              ? 'Keep & connect cancelled ($ssid)'
              : 'Keep & connect failed ($ssid)',
          error: e,
        );
        if (armedPeer) {
          await _sendRestoreToPeer(peerId);
        }
        if (!mounted) return;
        setState(() {
          _startingDirect = false;
          _cancellingDirect = false;
          busy = false;
          testingPathId = null;
          _keptUnconnectedDirect = !wasCancelled;
          activeDirectKind = kind;
          testSuccess = wasCancelled ? null : false;
          testMessage = wasCancelled
              ? 'Cancelled peer join · $label remains open'
              : 'Kept $label open · peer join failed (${_friendlyError(e)})';
        });
        return;
      }
    }

    // No control path or passphrase available right now: keep the open link selected locally.
    setState(() {
      busy = true;
      testingPathId = 'keep:direct';
      _keptUnconnectedDirect = true;
      activeDirectKind = kind;
      testSuccess = true;
      testMessage =
          'Kept $label selected on $iface${ssid.isNotEmpty ? ' ($ssid)' : ''} — connect peer to $ssid and tap Refresh.';
    });
    try {
      final cur = connectionCfg ?? <String, dynamic>{};
      await widget.core.run(
        ['connection', peerId, '-'],
        input: jsonEncode({
          ...cur,
          'transport': 'lan',
          'endpoint': '',
          'preferred_transport': activeDirectKind == 'hotspot'
              ? 'hotspot'
              : 'wifi_direct',
          'active_link': activeDirectKind == 'hotspot'
              ? 'hotspot'
              : 'wifi_direct',
        }),
      );
      connectionCfg = Map<String, dynamic>.from(
        await widget.core.run(['connection', peerId]) as Map,
      );
    } catch (_) {}
    if (mounted) {
      setState(() {
        busy = false;
        testingPathId = null;
      });
    }
  }

  Future<void> _connectSavedDirectLink({
    Map<String, dynamic>? alreadyJoined,
  }) async {
    final saved = _savedDirect;
    if (saved == null) return;
    final peerId = widget.peer['id'] as String;
    final kind = '${saved['kind']}';
    if (saved['joined'] != true) {
      if (_bestControlPath(allowAdb: true) == null) {
        await load();
      }
      if (!mounted) return;
      await _startDirectLink(kind, hostSide: 'phone');
      return;
    }
    final ssid = '${saved['ssid'] ?? ''}';
    final endpoint = '${saved['endpoint'] ?? ''}';
    if (ssid.isEmpty || endpoint.isEmpty) return;
    await _capturePreDirectFallback();
    if (!mounted) return;
    setState(() {
      busy = true;
      testingPathId = 'reconnect:direct';
      testMessage = 'Reconnecting to $ssid…';
      testSuccess = null;
    });
    try {
      final network =
          alreadyJoined ??
          await widget.core.prepareDirectLink(
            'wifi_join',
            ssid: ssid,
            passphrase: saved['passphrase'] as String?,
            band: saved['band'] as String? ?? 'auto',
            peerId: peerId,
            peerEndpoint: endpoint,
            peerKind: kind,
          );
      final iface = '${network['interface'] ?? ''}';
      final cidr = '${network['cidr'] ?? ''}';
      if (iface.isEmpty || !_inSameSubnet(endpoint, cidr)) {
        throw StateError('The saved endpoint is unavailable on $ssid.');
      }
      await _approveDirectInterface(iface, cidr, kind);
      final resolved = await _probeOne([
        '--interface',
        iface,
        '--lan-cidr',
        cidr,
        '--transport',
        'lan',
        '--endpoint',
        endpoint,
        'resolve',
        peerId,
      ]);
      if (resolved == null) {
        throw StateError('The paired device did not respond on $ssid.');
      }
      _directLinkMeta = {
        ...network,
        'kind': kind,
        if (kind == 'hotspot') 'hotspot_host': 'laptop',
      };
      activeDirectKind = kind;
      await selectConnection(
        'lan',
        endpoint: endpoint,
        fastDirectConnect: true,
      );
      if (route == null) {
        throw StateError('The paired device did not stay connected on $ssid.');
      }
    } catch (error) {
      await _restorePreDirectState(peerId, forgetDirectLink: false);
      await load();
      if (!mounted) return;
      setState(() {
        testingPathId = null;
        busy = false;
        testSuccess = false;
        testMessage = _friendlyError(error);
      });
    }
  }

  Future<void> _checkSavedDirectHost(String peerId) async {
    final saved = _savedDirect;
    final ssid = saved?['ssid'] as String?;
    final path = _bestControlPath(allowAdb: true);
    if (ssid == null || ssid.isEmpty || path == null) return;
    try {
      final result = await widget.core.run([
        ..._controlPrefixArgs(path),
        'prepare-link',
        peerId,
        '-',
      ], input: jsonEncode({'kind': 'link_status', 'ssid': ssid}));
      if (mounted && identical(saved, _savedDirect)) {
        setState(
          () => _savedHostOpen = result is Map && result['status'] == 'active',
        );
      }
    } catch (_) {}
  }

  ({String ssid, String passphrase}) _generateDirectCredentials(String kind) {
    final rnd = Random.secure();
    final hex4 = rnd.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    final preSsid = kind == 'wifi_direct' ? 'DIRECT-DB-$hex4' : 'DB-AP-$hex4';
    const passChars =
        'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final prePass = List.generate(
      16,
      (_) => passChars[rnd.nextInt(passChars.length)],
    ).join();
    return (ssid: preSsid, passphrase: prePass);
  }

  Future<Map<String, dynamic>> _prepareLocalLink(
    String kind, {
    String band = 'auto',
    String? ssid,
    String? passphrase,
    int? channel,
    int? frequencyMhz,
    int? bandwidthMhz,
    String? peerId,
    String? peerEndpoint,
    String? peerKind,
  }) {
    final core = widget.core;
    if (core is LocalCore) {
      return core.prepareDirectLink(
        kind,
        band: band,
        ssid: ssid,
        passphrase: passphrase,
        channel: channel,
        frequencyMhz: frequencyMhz,
        bandwidthMhz: bandwidthMhz,
        peerId: peerId,
        peerEndpoint: peerEndpoint,
        peerKind: peerKind,
        operationId: _linkOperation['id'] as String?,
        leaseSeconds: 120,
      );
    }
    return core.prepareDirectLink(
      kind,
      band: band,
      ssid: ssid,
      passphrase: passphrase,
      channel: channel,
      frequencyMhz: frequencyMhz,
      bandwidthMhz: bandwidthMhz,
      peerId: peerId,
      peerEndpoint: peerEndpoint,
      peerKind: peerKind,
    );
  }

  Future<void> _startDirectLink(
    String kind, {
    String hostSide = 'phone',
  }) async {
    final peerId = widget.peer['id'] as String;
    if (!_rules.allows(kind) || !_rules.allows('direct')) {
      setState(
        () => offlineNote =
            'Enable this link and Direct TCP in Network settings first.',
      );
      return;
    }
    final label = kind == 'wifi_direct' ? 'Wi-Fi Direct' : 'Wi-Fi Hotspot';
    final localHosts = (hostSide == 'phone') == Platform.isAndroid;
    final preferBand =
        (!localHosts &&
            hostSide == 'laptop' &&
            peerCaps?['hotspot_5ghz_ap'] != true)
        ? '2ghz'
        : _preferBandKey();
    final wantChannel =
        (!localHosts &&
            hostSide == 'laptop' &&
            peerCaps?['hotspot_5ghz_ap'] != true)
        ? 0
        : (_selectedChannel ?? _autoHighestChannel());
    final wantFreq = wantChannel > 0 ? channelToFreq(wantChannel) : 0;
    final wantBw = _selectedBandwidthMhz;
    await _capturePreDirectFallback();

    _leasedRemoteOperation = false;
    var journalOwned = false;
    var armedPeer = false;
    var startedLocal = false;
    _startingDirect = true;
    _cancellingDirect = false;
    final startId = 'start:$kind:$hostSide';
    DebugTrace.logFlow(
      'DirectLink',
      'Start $label (host=$hostSide, band=$preferBand, ch=${wantChannel > 0 ? wantChannel : 'auto'}, bw=$wantBw)',
    );
    setState(() {
      busy = true;
      offlineNote = null;

      testingPathId = startId;
      testSuccess = null;

      testMessage =
          'Starting $label (${hostSide == 'phone' ? 'Phone' : 'Laptop'} host · ${_directBandSummary()})…';
    });
    try {
      _linkOperation = Map<String, dynamic>.from(
        await widget.core.run([
          'link-operation',
          peerId,
          'begin',
          kind,
          hostSide,
        ]) as Map,
      );
      journalOwned = true;
      _localLeaseDeadlineMs = DateTime.now().millisecondsSinceEpoch + 120000;
      var manualHosting = false;
      if (localHosts && Platform.isAndroid) {
        final mode = NetworkSetupPolicy(await widget.core.appSettings())
            .hosting;
        final hasIndependentUsb =
            _bestControlPath(allowAdb: true)?.transport == 'adb';
        manualHosting =
            mode == NetworkSetupMode.standard &&
            !hasIndependentUsb &&
            !(kind == 'hotspot' &&
                platformCaps['hotspot_sta_concurrent'] == true);
      }
      if (manualHosting) {
        final local = await _prepareLocalLink(
          kind,
          band: preferBand,
          peerId: peerId,
        );
        startedLocal = true;
        final iface = '${local['interface'] ?? ''}',
            cidr = '${local['cidr'] ?? ''}';
        final ssid = '${local['ssid'] ?? ''}',
            pass = '${local['passphrase'] ?? ''}';
        if (iface.isEmpty || cidr.isEmpty || ssid.isEmpty) {
          throw StateError('Android did not provide the local link details.');
        }
        if (!mounted) throw StateError('Network setup closed.');
        setState(() => busy = false);
        final joined = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Join $label on ${widget.peer['name']}'),
            content: SelectableText(
              '''Standard Android chose this network. On the other device, join it in Wi-Fi settings.

Network: $ssid
Password: $pass

This setup has a two-minute restore deadline. No SSH key or password is needed for the paired Agent connection.''',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Peer has joined'),
              ),
            ],
          ),
        );
        if (joined != true) throw StateError('Manual link setup cancelled.');
        if (mounted) setState(() => busy = true);
        _directLinkMeta = {
          ...local,
          'kind': kind,
          if (kind == 'hotspot') 'hotspot_host': hostSide,
        };
        _resumedDirect = {...local, 'kind': kind, 'active': true};
        await _approveDirectInterface(iface, cidr, kind);
        await _waitForDirectPeerAndSelect(
          peerId: peerId,
          kind: kind,
          label: label,
          iface: iface,
          cidr: cidr,
          ssid: ssid,
          hostIp: '${local['ip'] ?? ''}',
          pathId: startId,
        );
        if (route == null) {
          throw StateError('The peer did not authenticate on the new link.');
        }
        if (widget.core case final LocalCore core) {
          await core.commitLocalLink('${_linkOperation['id']}');
        }
        await _journalLink('committed');
        if (mounted) {
          setState(() {
            _startingDirect = false;
            busy = false;
          });
        }
        return;
      }
      if (_bestControlPath(allowAdb: true) == null) {
        if (mounted) {
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('Set up $label manually'),
              content: Text(
                'There is no authenticated control path to coordinate the two devices. On the chosen host, enable $label in network settings. Join its network on the other device, then return and retry. DeviceBridge will verify the paired identity before using the new path.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
                if (Platform.isAndroid)
                  TextButton(
                    onPressed: () async {
                      await widget.core.openConnectionSetup(kind);
                    },
                    child: const Text('Open network settings'),
                  ),
              ],
            ),
          );
        }
        throw StateError('Finish manual setup on both devices, then retry.');
      }

      if (localHosts) {
        final creds = _generateDirectCredentials(kind);
        final preSsid = creds.ssid;
        final prePass = creds.passphrase;
        final startBeforePeer =
            Platform.isAndroid &&
            kind == 'hotspot' &&
            platformCaps['hotspot_sta_concurrent'] == true;
        Future<void> armPeer(String ssid, String pass, String band) async {
          await _prepareLinkWithFallback(peerId, {
            'kind': 'wifi_join',
            'mode': kind,
            'ssid': ssid,
            'passphrase': pass,
            'band': band,
          });
          armedPeer = true;
          if (_cancellingDirect) {
            throw StateError('$label cancelled');
          }
        }

        if (!startBeforePeer) {
          if (mounted) {
            setState(() {
              testMessage = 'Notifying peer to join $preSsid…';
            });
          }
          await armPeer(preSsid, prePass, _directBandSummary());
        }

        if (mounted) {
          setState(() {
            testMessage = 'Starting $label…';
          });
        }
        final localRes = Platform.isAndroid || widget.core is LocalCore
            ? await _prepareLocalLink(
                kind,
                band: preferBand,
                ssid: preSsid,
                passphrase: prePass,
                channel: wantChannel,
                frequencyMhz: wantFreq,
                bandwidthMhz: wantBw,
                peerId: peerId,
              )
            : Map<String, dynamic>.from(
                await widget.core.run(
                  ['link-host', '-'],
                  input: jsonEncode({
                    'kind': kind,
                    'band': preferBand,
                    'ssid': preSsid,
                    'passphrase': prePass,
                    if (wantChannel > 0) 'channel': wantChannel,
                    if (wantFreq > 0) 'frequency_mhz': wantFreq,
                    if (wantBw > 0) 'bandwidth_mhz': wantBw,
                  }),
                ) as Map,
              );
        startedLocal = true;
        final iface = '${localRes['interface'] ?? ''}';
        final cidr = '${localRes['cidr'] ?? ''}';
        final ssid = '${localRes['ssid'] ?? preSsid}';
        final pass = '${localRes['passphrase'] ?? prePass}';
        final phoneIp = '${localRes['ip'] ?? ''}';
        final actualBand = '${localRes['band'] ?? _directBandSummary()}';
        final actualStd = '${localRes['wifi_standard'] ?? ''}';
        final actualFreq = (localRes['frequency_mhz'] as num?)?.toInt() ?? 0;
        final actualCh =
            (localRes['channel'] as num?)?.toInt() ??
            (actualFreq > 0 ? freqToChannel(actualFreq) : 0);
        final actualBw = (localRes['bandwidth_mhz'] as num?)?.toInt() ?? 0;
        if (iface.isEmpty || cidr.isEmpty || ssid.isEmpty) {
          throw StateError('Failed to start $label interface');
        }
        if (startBeforePeer) {
          await armPeer(ssid, pass, actualBand);
        } else if (ssid != preSsid || pass != prePass) {
          throw StateError(
            'Android chose different hotspot credentials. An available control link is needed to share them.',
          );
        }
        _directLinkMeta = {
          'interface': iface,
          'cidr': cidr,
          'kind': kind,
          if (kind == 'hotspot') 'hotspot_host': hostSide,
          'band': actualBand,
          'channel': actualCh,
          'frequency_mhz': actualFreq,
          'bandwidth_mhz': actualBw,
          'wifi_standard': actualStd,
          'ssid': ssid,
        };
        _resumedDirect = {
          'active': true,
          'kind': kind,
          'interface': iface,
          'cidr': cidr,
          'ip': phoneIp,
          'ssid': ssid,
          'band': actualBand,
          'channel': actualCh,
          'frequency_mhz': actualFreq,
          'bandwidth_mhz': actualBw,
          'wifi_standard': actualStd,
        };
        if (mounted) {
          setState(() {
            activeDirectKind = kind;
            testMessage =
                'Hosting $ssid ($actualBand${actualStd.isNotEmpty ? ' · $actualStd' : ''}) — waiting for peer to join…';
          });
        }

        await _waitForDirectPeerAndSelect(
          peerId: peerId,
          kind: kind,
          label: label,
          iface: iface,
          cidr: cidr,
          ssid: ssid,
          hostIp: phoneIp,
          pathId: startId,
        );
      } else {
        final creds = _generateDirectCredentials(kind);
        final remoteResRaw = await _prepareLinkWithFallback(peerId, {
          'kind': kind,
          'band': preferBand,
          'ssid': creds.ssid,
          'passphrase': creds.passphrase,
          if (wantChannel > 0) 'channel': wantChannel,
          if (wantFreq > 0) 'frequency_mhz': wantFreq,
          if (wantBw > 0) 'bandwidth_mhz': wantBw,
        });
        armedPeer = true;
        final remoteRes = Map<String, dynamic>.from(remoteResRaw as Map);
        final ssid = '${remoteRes['ssid'] ?? ''}'.isNotEmpty
            ? '${remoteRes['ssid']}'
            : creds.ssid;
        final pass = '${remoteRes['passphrase'] ?? ''}'.isNotEmpty
            ? '${remoteRes['passphrase']}'
            : creds.passphrase;
        final peerIp = '${remoteRes['ip'] ?? ''}';
        var remoteEp =
            '${remoteRes['endpoint'] ?? (peerIp.isNotEmpty ? '$peerIp:8731' : '')}';
        final actualBand = '${remoteRes['band'] ?? _directBandSummary()}';
        final peerStarting = '${remoteRes['status'] ?? ''}' == 'starting';
        if (ssid.isEmpty || (peerIp.isEmpty && !peerStarting)) {
          throw StateError('Peer did not return $label credentials');
        }
        if (mounted) {
          setState(() {
            activeDirectKind = kind;
            testMessage = peerStarting
                ? 'Peer starting $ssid ($actualBand) · connecting…'
                : 'Joining ${hostSide == 'laptop' ? 'Laptop' : 'Phone'} $ssid ($actualBand) via Wi-Fi…';
          });
        }
        if (peerStarting) {
          await Future<void>.delayed(const Duration(milliseconds: 1200));
          if (_cancellingDirect) {
            throw StateError('$label cancelled');
          }
        }
        final joinRes = Platform.isAndroid || widget.core is LocalCore
            ? await _prepareLocalLink(
                'wifi_join',
                band: actualBand,
                ssid: ssid,
                passphrase: pass,
                peerId: peerId,
                peerEndpoint: remoteEp,
                peerKind: kind,
              )
            : Map<String, dynamic>.from(
                await widget.core.run(
                  ['wifi-join', '-'],
                  input: jsonEncode({
                    'kind': kind,
                    'ssid': ssid,
                    'passphrase': pass,
                    'band': actualBand,
                  }),
                ) as Map,
              );
        startedLocal = true;
        final iface = '${joinRes['interface'] ?? ''}';
        final cidr = '${joinRes['cidr'] ?? ''}';
        if (iface.isEmpty || cidr.isEmpty) {
          throw StateError('Joined $ssid but failed to read local IPv4 CIDR');
        }
        final rFreq = (remoteRes['frequency_mhz'] as num?)?.toInt() ?? 0;
        final rCh =
            (remoteRes['channel'] as num?)?.toInt() ??
            (rFreq > 0 ? freqToChannel(rFreq) : 0);
        final rBw = (remoteRes['bandwidth_mhz'] as num?)?.toInt() ?? 0;
        _directLinkMeta = {
          'interface': iface,
          'cidr': cidr,
          'kind': kind,
          if (kind == 'hotspot') 'hotspot_host': hostSide,
          'band': actualBand,
          'channel': rCh,
          'frequency_mhz': rFreq,
          'bandwidth_mhz': rBw,
          'wifi_standard': '${remoteRes['wifi_standard'] ?? ''}',
          'ssid': ssid,
        };
        await _approveDirectInterface(iface, cidr, kind);
        if (peerStarting) {
          String? reachedEp;
          final probeCandidates = <String>{
            if (remoteEp.isNotEmpty) remoteEp,
            if (cidr.contains('.'))
              '${cidr.split('/').first.split('.').take(3).join('.')}.1:8731',
          };
          for (var attempt = 0; attempt < 12 && reachedEp == null; attempt++) {
            if (_cancellingDirect) {
              throw StateError('$label cancelled');
            }
            try {
              for (final neighIp in await widget.core.directLinkNeighbors(
                iface,
              )) {
                probeCandidates.add('$neighIp:8731');
              }
            } catch (_) {}
            for (final ep in probeCandidates) {
              final r = await _probeOne([
                '--interface',
                iface,
                '--lan-cidr',
                cidr,
                '--transport',
                'lan',
                '--endpoint',
                ep,
                'resolve',
                peerId,
              ]);
              if (r != null) {
                reachedEp = '${r['endpoint'] ?? ep}';
                break;
              }
            }
            if (reachedEp == null) {
              await Future<void>.delayed(const Duration(milliseconds: 450));
            }
          }
          if (reachedEp != null) {
            remoteEp = reachedEp;
          }
        }
        await selectConnection(
          'lan',
          pathId: startId,
          endpoint: remoteEp,
          silentProgress: true,
          fastDirectConnect: true,
        );
      }
      if (route == null) {
        throw StateError('The new path did not authenticate the peer.');
      }
      if (_leasedRemoteOperation) {
        final active = _activeReachablePath();
        await widget.core.run([
          if (active != null) ..._controlPrefixArgs(active),
          'commit-link',
          peerId,
          '${_linkOperation['id']}',
        ]);
      }
      if (widget.core case final LocalCore core) {
        await core.commitLocalLink('${_linkOperation['id']}');
      }
      await _journalLink('committed');
    } catch (e) {
      if (journalOwned) {
        await _journalLink(
          startedLocal || armedPeer ? 'needs_recovery' : 'restored',
        );
      }
      final wasCancelled = _cancellingDirect;
      if (wasCancelled) {
        DebugTrace.logFlow('DirectLink', '$label cancelled');
      } else {
        DebugTrace.logError(
          'DirectLink',
          '$label setup failed (host=$hostSide)',
          error: e,
        );
      }
      if (armedPeer) {
        await _sendRestoreToPeer(peerId);
      }
      if (startedLocal ||
          (journalOwned && widget.core is LocalCore && Platform.isAndroid)) {
        await _restorePreDirectState(peerId);
      }
      if (armedPeer) {
        await Future<void>.delayed(const Duration(milliseconds: 900));
        await load();
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _startingDirect = false;
        _cancellingDirect = false;
        busy = false;

        testingPathId = null;
        testSuccess = wasCancelled ? null : false;

        testMessage = wasCancelled
            ? '$label cancelled · standard Wi-Fi restored'
            : '$label setup failed · ${_friendlyError(e)}';
      });
      return;
    }
    if (mounted) {
      setState(() {
        _startingDirect = false;
        _cancellingDirect = false;
      });
    } else {
      _startingDirect = false;
      _cancellingDirect = false;
    }
  }

  bool _isPathSelected(_ReachablePath path) {
    final activeTransport =
        _connectedTransport ?? connectionCfg?['transport'] as String? ?? 'lan';
    if (activeTransport != path.transport) {
      return false;
    }
    if (path.transport == 'lan' &&
        path.interfaceName != null &&
        (route?['interface'] ?? widget.core.network?['interface']) !=
            path.interfaceName) {
      return false;
    }
    final routeEp = '${route?['endpoint'] ?? ''}'.trim();
    if (routeEp.isNotEmpty) {
      return routeEp == path.endpoint;
    }
    final savedEndpoint =
        connectionCfg?['${path.transport}_endpoint'] ??
        (path.transport == 'lan' ? null : connectionCfg?['endpoint']);
    return savedEndpoint == null || savedEndpoint == path.endpoint;
  }

  _ReachablePath? _activeReachablePath() {
    for (final path in reachablePaths) {
      if (_isPathSelected(path)) {
        return path;
      }
    }
    return null;
  }

  Future<void> _runSpeedTest() async {
    final peerId = widget.peer['id'] as String;
    final activePath = _activeReachablePath();
    setState(() {
      busy = true;

      testingPathId = 'speed:active';
      testSuccess = null;
      testMessage = 'Speed test: transferring data for 5 seconds…';
    });
    try {
      final target =
          activePath ??
          (route == null ? _bestControlPath(allowAdb: true) : null);
      final args = target != null
          ? [
              ..._controlPrefixArgs(target, bulk: true),
              'speedtest',
              peerId,
              '5',
            ]
          : ['speedtest', peerId, '5'];
      final res = Map<String, dynamic>.from(await widget.core.run(args) as Map);
      final secs = (res['seconds'] as num?)?.toDouble() ?? 5.0;
      final mib = (res['mib'] as num?)?.toDouble() ?? 0.0;
      final speed =
          (res['mib_per_second'] as num?)?.toDouble() ??
          (secs > 0 ? mib / secs : 0.0);
      if (!mounted) {
        return;
      }
      setState(() {
        busy = false;
        probingPaths = false;
        testingPathId = null;
        if (activePath != null) {
          _pathSpeeds[activePath.id] = speed;
        }
        measuredSpeedMiBs = speed;
        testSuccess = true;
        testMessage =
            'Speed test · ${mib.toStringAsFixed(1)} MiB in ${secs.toStringAsFixed(1)} s · ${speed.toStringAsFixed(2)} MiB/s';
      });
      _savePeerCache();
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        testingPathId = null;
        busy = false;
        testSuccess = false;
        testMessage = 'Speed test failed · ${_friendlyError(e)}';
      });
    }
  }

  Future<void> _stopDirectLink() async {
    final peerId = widget.peer['id'] as String;
    setState(() {
      busy = true;
      testingPathId = 'stop:direct';
      testSuccess = null;
      testMessage = 'Restoring standard Wi-Fi connection…';
    });
    final peerAcked = await _sendRestoreToPeer(peerId);
    await _restorePreDirectState(peerId);
    if (peerAcked) await _journalLink('restored');
    if (peerAcked) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    } else {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    await load();
    for (
      var attempt = 0;
      attempt < 4 && peerAcked && route == null && mounted;
      attempt++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await load();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      testingPathId = null;
      testSuccess = route != null || !peerAcked;
      testMessage = route != null
          ? null
          : 'Closed direct link and restored local Wi-Fi settings.';
    });
    _savePeerCache();
    DebugTrace.logFlow(
      'DirectLink',
      'Stopped direct link (peerAcked=$peerAcked, route=${route?['transport']})',
    );
  }

  String _radioSummary({String? iface, String? kind}) {
    if ((iface ?? '').startsWith('eth') ||
        (iface ?? '').startsWith('en') ||
        (iface ?? '').startsWith('usb') ||
        (iface ?? '').startsWith('rndis')) {
      return '';
    }
    final peerLinkRaw = peerCaps?['link'];
    final peerLink = peerLinkRaw is Map
        ? Map<String, dynamic>.from(peerLinkRaw)
        : const <String, dynamic>{};
    final useDirectMeta =
        _directLinkMeta.isNotEmpty &&
        (_isDirectSubPath(iface: iface, kind: kind) ||
            '${_directLinkMeta['interface'] ?? ''}' == (iface ?? ''));
    final meta = useDirectMeta ? _directLinkMeta : const <String, dynamic>{};
    final matchesLocal =
        _localLinkInfo.isNotEmpty &&
        (iface == null ||
            iface.isEmpty ||
            '${_localLinkInfo['interface'] ?? ''}'.isEmpty ||
            '${_localLinkInfo['interface']}' == iface ||
            (_isDirectSubPath(iface: iface, kind: kind) &&
                _isDirectSubPath(
                  iface: '${_localLinkInfo['interface'] ?? ''}',
                )));
    final local = matchesLocal ? _localLinkInfo : const <String, dynamic>{};

    final std = [
      '${peerLink['wifi_standard'] ?? ''}',
      '${local['wifi_standard'] ?? ''}',
      '${meta['wifi_standard'] ?? ''}',
    ].firstWhere((s) => s.isNotEmpty, orElse: () => '');

    final freqRaw = [
      (local['frequency_mhz'] as num?)?.toInt() ?? 0,
      (meta['frequency_mhz'] as num?)?.toInt() ?? 0,
      (peerLink['frequency_mhz'] as num?)?.toInt() ?? 0,
    ].firstWhere((f) => f > 0, orElse: () => 0);
    final band = switch (freqRaw) {
      >= 5935 && <= 7115 => '6 GHz',
      >= 5000 && <= 5925 => '5 GHz',
      >= 2412 && <= 2484 => '2.4 GHz',
      _ => [
        '${local['band'] ?? ''}',
        '${meta['band'] ?? ''}',
        '${peerLink['band'] ?? ''}',
      ].firstWhere((s) => s.isNotEmpty, orElse: () => ''),
    };

    final chRaw = [
      freqToChannel(freqRaw),
      (local['channel'] as num?)?.toInt() ?? 0,
      (meta['channel'] as num?)?.toInt() ?? 0,
      (peerLink['channel'] as num?)?.toInt() ?? 0,
    ].firstWhere((c) => c > 0, orElse: () => 0);

    final bwRaw = [
      (meta['bandwidth_mhz'] as num?)?.toInt() ?? 0,
      (peerLink['bandwidth_mhz'] as num?)?.toInt() ?? 0,
      (local['bandwidth_mhz'] as num?)?.toInt() ?? 0,
    ].firstWhere((b) => b > 0, orElse: () => 0);

    final chanText = chRaw > 0
        ? 'Ch $chRaw${freqRaw > 0 ? ' ($freqRaw MHz)' : ''}'
        : (freqRaw > 0 ? '$freqRaw MHz' : '');

    final parts = <String>[
      if (std.isNotEmpty) std,
      if (band.isNotEmpty) band,
      if (chanText.isNotEmpty) chanText,
      if (bwRaw > 0) '$bwRaw MHz',
    ];
    return parts.join(' · ');
  }

  String _activeChannelSummary({String? iface, String? kind}) {
    final peerLinkRaw = peerCaps?['link'];
    final peerLink = peerLinkRaw is Map
        ? Map<String, dynamic>.from(peerLinkRaw)
        : const <String, dynamic>{};
    final useDirectMeta =
        _directLinkMeta.isNotEmpty &&
        (_isDirectSubPath(iface: iface, kind: kind) ||
            '${_directLinkMeta['interface'] ?? ''}' == (iface ?? ''));
    final meta = useDirectMeta ? _directLinkMeta : const <String, dynamic>{};
    final matchesLocal =
        _localLinkInfo.isNotEmpty &&
        (iface == null ||
            iface.isEmpty ||
            '${_localLinkInfo['interface'] ?? ''}'.isEmpty ||
            '${_localLinkInfo['interface']}' == iface ||
            (_isDirectSubPath(iface: iface, kind: kind) &&
                _isDirectSubPath(
                  iface: '${_localLinkInfo['interface'] ?? ''}',
                )));
    final local = matchesLocal ? _localLinkInfo : const <String, dynamic>{};
    final freqRaw = [
      (local['frequency_mhz'] as num?)?.toInt() ?? 0,
      (meta['frequency_mhz'] as num?)?.toInt() ?? 0,
      (peerLink['frequency_mhz'] as num?)?.toInt() ?? 0,
    ].firstWhere((f) => f > 0, orElse: () => 0);
    final chRaw = [
      (local['channel'] as num?)?.toInt() ?? 0,
      (meta['channel'] as num?)?.toInt() ?? 0,
      (peerLink['channel'] as num?)?.toInt() ?? 0,
      freqToChannel(freqRaw),
    ].firstWhere((c) => c > 0, orElse: () => 0);
    final bwRaw = [
      (meta['bandwidth_mhz'] as num?)?.toInt() ?? 0,
      (peerLink['bandwidth_mhz'] as num?)?.toInt() ?? 0,
      (local['bandwidth_mhz'] as num?)?.toInt() ?? 0,
    ].firstWhere((b) => b > 0, orElse: () => 0);
    if (chRaw <= 0 && freqRaw <= 0) return '';
    final chStr = chRaw > 0
        ? 'Ch $chRaw${freqRaw > 0 ? ' ($freqRaw MHz)' : ''}'
        : '$freqRaw MHz';
    return bwRaw > 0 ? '$chStr · $bwRaw MHz' : chStr;
  }

  String _pathSubtitle(_ReachablePath path, bool isConnected) {
    final statusSuffix = isConnected ? ' · Connected' : '';
    if (path.transport == 'tailnet') {
      final relaySuffix = (path.relay ?? '').isNotEmpty
          ? ' (${path.relay})'
          : '';
      final via = switch (path.pathKind) {
        'direct' => 'via Direct',
        'derp' => 'via DERP$relaySuffix',
        'peer-relay' => 'via Peer Relay$relaySuffix',
        _ => 'via ${path.pathKind ?? 'Tailscale'}',
      };
      return '$via · ${path.endpoint}$statusSuffix';
    }
    final ifaceSuffix = (path.interfaceName ?? '').isNotEmpty
        ? ' · ${path.interfaceName}'
        : '';
    final radio =
        (path.transport == 'lan' || path.transport == 'direct-lan-v1') &&
            (isConnected ||
                _isDirectSubPath(iface: path.interfaceName, kind: path.kind))
        ? _radioSummary(iface: path.interfaceName, kind: path.kind)
        : '';
    final line1 = '${path.endpoint}$ifaceSuffix$statusSuffix';
    return radio.isEmpty ? line1 : '$line1\n$radio';
  }

  String routeTitle(String? transport) => switch (transport) {
    'direct-lan-v1' || 'lan' => _selectedMethodLabel('lan'),
    'wireguard' || 'wireguard-v1' => 'WireGuard',
    'adb' => _activeReachablePath()?.label ?? _methodLabel('adb'),
    'ssh' => _methodLabel('ssh'),
    _ => 'Connected via Tailscale',
  };

  String _methodLabel(String transport) => switch (transport) {
    'direct-lan-v1' || 'lan' => 'Wi-Fi',
    'tailnet' || 'tsnet-v1' || 'tailscaled-v1' => 'Tailscale',
    'wireguard' || 'wireguard-v1' => 'WireGuard',
    'adb' => 'ADB over USB',
    'ssh' => 'SSH tunnel',
    _ => transport,
  };

  String _selectedMethodLabel(String transport) =>
      switch (_activeReachablePath()) {
        final path?
            when (transport == 'lan' || transport == 'direct-lan-v1') &&
                path.transport == 'lan' =>
          path.label,
        _ => _methodLabel(transport),
      };

  Future<void> _showRoutePreferences() async {
    final peerId = widget.peer['id'] as String;
    var allowRemoteBulk = connectionCfg?['remote_approved'] == true;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Connection preferences'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'When the preferred route drops, the app tries Wi-Fi or LAN, then Tailscale, then WireGuard. Manual links need Start.',
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: allowRemoteBulk,
                  title: const Text(
                    'Allow internet, relay and mobile data for transfers',
                  ),
                  onChanged: (value) =>
                      setDialogState(() => allowRemoteBulk = value == true),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || saved != true) return;
    try {
      final latest = await widget.core.run(['connection', peerId]) as Map;
      await widget.core.run([
        'connection',
        peerId,
        '-',
      ], input: jsonEncode({...latest, 'remote_approved': allowRemoteBulk}));
      if (mounted) await load(background: true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_friendlyError(error))));
      }
    }
  }

  bool _inSameSubnet(String? endpoint, String? cidr) {
    if (endpoint == null || endpoint.isEmpty || cidr == null || cidr.isEmpty) {
      return false;
    }
    final host = _hostFromEndpoint(endpoint);
    final slash = cidr.indexOf('/');
    if (host == null || slash <= 0) {
      return false;
    }
    final ip = InternetAddress.tryParse(host);
    final netIp = InternetAddress.tryParse(cidr.substring(0, slash));
    final prefixLen = int.tryParse(cidr.substring(slash + 1));
    if (ip == null ||
        netIp == null ||
        prefixLen == null ||
        ip.type != InternetAddressType.IPv4 ||
        netIp.type != InternetAddressType.IPv4 ||
        prefixLen < 0 ||
        prefixLen > 32) {
      return false;
    }
    int toU32(InternetAddress a) {
      final b = a.rawAddress;
      return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    }

    final mask = prefixLen == 0 ? 0 : (~0 << (32 - prefixLen)) & 0xFFFFFFFF;
    return (toU32(ip) & mask) == (toU32(netIp) & mask);
  }

  String? _hostFromEndpoint(Object? raw) {
    final ep = '${raw ?? ''}'.trim();
    if (ep.isEmpty) {
      return null;
    }
    final colon = ep.lastIndexOf(':');
    if (colon > 0 && !ep.contains(']')) {
      final host = ep.substring(0, colon);
      return host == '127.0.0.1' ? null : host;
    }
    return ep == '127.0.0.1' ? null : ep;
  }

  @override
  Widget build(BuildContext context) {
    final activeTransport = connectionCfg?['transport'] as String? ?? 'lan';
    final effectiveTransport = _connectedTransport ?? activeTransport;
    final addresses = widget.peer['addresses'] as List? ?? const [];
    final isRevoked = widget.peer['status'] == 'revoked';
    final directLinkOpen = _directLinkOpen;
    final localCidr = widget.core.network?['cidr'] as String?;
    String? discoveredLanEp;
    for (final v in widget.candidates) {
      if (v['device_id'] == widget.peer['id']) {
        final ep = '${v['endpoint'] ?? ''}'.trim();
        if (ep.isNotEmpty &&
            (localCidr == null || _inSameSubnet(ep, localCidr))) {
          discoveredLanEp = ep;
          break;
        }
      }
    }
    String? currentSubnetSavedEp;
    for (final addr in addresses) {
      final ep = '${addr['endpoint'] ?? ''}'.trim();
      if (!ep.startsWith('127.0.0.1:') && _inSameSubnet(ep, localCidr)) {
        currentSubnetSavedEp ??= ep;
      }
    }
    final activeEndpoint =
        (route?['endpoint'] as String?) ??
        (activeTransport != 'lan'
            ? (connectionCfg?['endpoint'] as String?)
            : null) ??
        discoveredLanEp ??
        currentSubnetSavedEp;
    String? defaultHost =
        _hostFromEndpoint(route?['endpoint']) ??
        _hostFromEndpoint(discoveredLanEp) ??
        _hostFromEndpoint(currentSubnetSavedEp);
    if (defaultHost == null) {
      for (final p in reachablePaths) {
        defaultHost = _hostFromEndpoint(p.endpoint);
        if (defaultHost != null) {
          break;
        }
      }
    }
    if (defaultHost == null) {
      for (final addr in addresses) {
        defaultHost = _hostFromEndpoint(addr['endpoint']);
        if (defaultHost != null) {
          break;
        }
      }
    }
    final activePath = _activeReachablePath();
    final recordedSpeed =
        (activePath != null && (_pathSpeeds[activePath.id] ?? 0) > 0)
        ? _pathSpeeds[activePath.id]!
        : ((measuredSpeedMiBs ?? 0) > 0
              ? measuredSpeedMiBs!
              : (((route?['mib_per_second'] as num?) ?? 0) > 0
                    ? (route!['mib_per_second'] as num)
                    : (((connectionCfg?['last_mib_per_second'] as num?) ?? 0) >
                              0
                          ? (connectionCfg!['last_mib_per_second'] as num)
                          : 0)));
    final localIsPhone = Platform.isAndroid;
    final phoneCaps = localIsPhone ? platformCaps : peerCaps;
    final laptopCaps = localIsPhone ? peerCaps : platformCaps;
    final phoneCanHotspotHost =
        _rules.allows('hotspot') &&
        phoneCaps?['hotspot_ap'] == true &&
        laptopCaps?['hotspot_sta'] == true;
    final laptopCanHotspotHost =
        _rules.allows('hotspot') &&
        laptopCaps?['hotspot_ap'] == true &&
        phoneCaps?['hotspot_sta'] == true;
    final phoneCanP2pHost =
        _rules.allows('wifi_direct') &&
        (phoneCaps?['wifi_direct_go'] ?? phoneCaps?['wifi_direct']) == true &&
        (laptopCaps?['wifi_direct'] == true ||
            laptopCaps?['hotspot_sta'] == true);
    final laptopCanP2pHost =
        _rules.allows('wifi_direct') &&
        laptopCaps?['wifi_direct_go'] == true &&
        (phoneCaps?['wifi_direct'] == true ||
            phoneCaps?['hotspot_sta'] == true);
    final scheme = Theme.of(context).colorScheme;
    final tabAccent = Theme.of(context).brightness == Brightness.dark
        ? scheme.primary
        : scheme.onSurface;
    final isDirectActive =
        route != null &&
        (_isDirectSubPath(
              iface: '${route!['interface'] ?? ''}',
              kind:
                  (widget.core.network?['kind'] as String?) ?? activeDirectKind,
            ) ||
            activeDirectKind != null ||
            (_resumedDirect != null && _resumedDirect!['active'] == true) ||
            ('${route?['endpoint'] ?? ''}'.contains('10.42.') ||
                '${route?['endpoint'] ?? ''}'.contains('192.168.49.') ||
                '${route?['endpoint'] ?? ''}'.contains('10.95.')));
    return Scaffold(
      appBar: AppBar(
        title: Text(_deviceName),
        actions: [
          if (widget.peer['status'] == 'paired')
            IconButton(
              key: const ValueKey('device-rename'),
              tooltip: 'Rename device',
              onPressed: _renameDevice,
              icon: const Icon(Icons.edit_outlined),
            ),
          if (!isRevoked)
            IconButton(
              key: const ValueKey('device-acl-button'),
              tooltip: 'Access & ACL',
              onPressed: busy ? null : _openDeviceAclSheet,
              icon: const Icon(Icons.security_outlined),
            ),
          IconButton(
            tooltip: 'Refresh device',
            onPressed: busy
                ? null
                : () {
                    setState(() {
                      busy = true;
                      offlineNote = null;
                    });
                    load();
                  },
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: tabAccent,
          labelColor: tabAccent,
          unselectedLabelColor: scheme.onSurfaceVariant,
          tabs: const [
            Tab(text: 'Overview'),
            Tab(key: ValueKey('device-connections-tab'), text: 'Connections'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildOverviewTab(
            context: context,
            isRevoked: isRevoked,
            effectiveTransport: effectiveTransport,
            activeEndpoint: activeEndpoint,
            defaultHost: defaultHost,
            isDirectActive: isDirectActive,
            recordedSpeed: recordedSpeed,
          ),
          _buildConnectionsTab(
            context: context,
            isRevoked: isRevoked,
            defaultHost: defaultHost,
            directLinkOpen: directLinkOpen,
            phoneCaps: phoneCaps,
            laptopCaps: laptopCaps,
            phoneCanHotspotHost: phoneCanHotspotHost,
            laptopCanHotspotHost: laptopCanHotspotHost,
            phoneCanP2pHost: phoneCanP2pHost,
            laptopCanP2pHost: laptopCanP2pHost,
          ),
        ],
      ),
    );
  }

  Future<void> _renameDevice() async {
    var draft = _deviceName;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename device'),
        content: TextFormField(
          key: const ValueKey('device-name-input'),
          initialValue: draft,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onChanged: (value) => draft = value,
          onFieldSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, draft.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (!mounted || result == null || result.isEmpty || result == _deviceName) {
      return;
    }
    try {
      await widget.core.run(['rename-peer', '${widget.peer['id']}', result]);
      if (mounted) setState(() => _renamedDevice = result);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _openDeviceFiles() async {
    final os = peerCaps?['os'] ?? widget.peer['os'];
    final root =
        os == 'android' ||
            roots.whereType<Map>().any((root) => root['id'] == 'termux_home')
        ? 'termux_home'
        : 'home';
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => FileManager(
          core: widget.core,
          remotePeer: _namedPeer,
          remoteRoot: root,
          candidates: widget.candidates,
        ),
      ),
    );
  }

  String _lastHandshake(BuildContext context) {
    final seconds = max(
      (route?['last_handshake_at'] as num?)?.toInt() ?? 0,
      (connectionCfg?['last_handshake_at'] as num?)?.toInt() ?? 0,
    );
    if (seconds <= 0) return 'Not recorded';
    final time = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatShortDate(time)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(time))}';
  }

  Widget _buildOverviewTab({
    required BuildContext context,
    required bool isRevoked,
    required String effectiveTransport,
    required String? activeEndpoint,
    required String? defaultHost,
    required bool isDirectActive,
    required num recordedSpeed,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final isLan =
        effectiveTransport == 'lan' || effectiveTransport == 'direct-lan-v1';
    final network = widget.core.network;
    final iface =
        '${route?['interface'] ?? (isLan ? (network?['interface']) : null) ?? ''}';
    final linkKind = isLan ? (network?['kind'] as String?) : null;
    final linkName = route == null
        ? '—'
        : isLan
        ? _lanLabel(iface, linkKind)
        : effectiveTransport == 'adb'
        ? 'USB'
        : '${route?['path_kind'] ?? 'System routing'}';
    final ordinarySsh = _sshMethod.startsWith('ssh:');
    final currentTransport = _activeReachablePath()?.transport;
    final canChooseLink =
        currentTransport == 'lan' &&
        reachablePaths.any((path) => path.transport == 'lan');
    final supportedSsh = (peerCaps?['features'] as List? ?? const []).contains(
      'agent-ssh-v1',
    );
    final hasSsh =
        supportedSsh && route != null ||
        _sshHosts.any((host) => host['agent_peer_id'] == widget.peer['id']);
    final chSummary =
        route != null &&
            (effectiveTransport == 'direct-lan-v1' ||
                effectiveTransport == 'lan')
        ? _activeChannelSummary(
            iface: iface.isEmpty
                ? '${widget.core.network?['interface'] ?? ''}'
                : iface,
            kind: widget.core.network?['kind'] as String?,
          )
        : '';
    final linkBits = <String>[
      if (activeEndpoint != null && activeEndpoint.isNotEmpty) activeEndpoint,
      if (iface.isNotEmpty) iface,
      if (chSummary.isNotEmpty) chSummary,
    ];

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (busy && testingPathId == null) const LinearProgressIndicator(),
        if (route != null || !busy || testingPathId != null)
          Card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: route != null
                        ? scheme.primary.withValues(alpha: 0.14)
                        : scheme.surfaceContainerHighest,
                    foregroundColor: route != null
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                    child: Icon(
                      isRevoked
                          ? Icons.block_outlined
                          : (route != null
                                ? Icons.computer
                                : Icons.portable_wifi_off_outlined),
                    ),
                  ),
                  title: const Text('Current connection'),
                  subtitle: Text(
                    route != null
                        ? 'Connected via ${_selectedMethodLabel(effectiveTransport)}'
                        : (_reconnectingSelectedTailnet
                              ? 'Reconnecting to Tailscale…'
                              : isRevoked
                              ? (offlineNote ?? 'Device revoked')
                              : (offlineNote ??
                                    'Device not currently reachable')),
                  ),
                  trailing: route == null && !isRevoked
                      ? TextButton(
                          onPressed: _reconnectingSelectedTailnet
                              ? null
                              : _retryConnection,
                          child: const Text('Retry'),
                        )
                      : (route != null
                            ? Icon(
                                Icons.verified_user_outlined,
                                color: scheme.primary,
                                size: 20,
                              )
                            : null),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!isRevoked && widget.peer['status'] == 'paired')
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const Text('Connection'),
                            _connectionChoice(supportedSsh),
                            ActionChip(
                              key: const ValueKey('overview-transport-choice'),
                              label: Text(
                                'Transport · ${ordinarySsh ? 'SSH account settings' : _transportLabel(route?['transport'] as String?)}',
                              ),
                              onPressed:
                                  busy || ordinarySsh || reachablePaths.isEmpty
                                  ? null
                                  : () => _pickVerifiedRoute(linkOnly: false),
                            ),
                            ActionChip(
                              key: const ValueKey('overview-link-choice'),
                              label: Text(
                                'Link · ${ordinarySsh ? 'SSH account settings' : linkName}',
                              ),
                              onPressed: busy || ordinarySsh || !canChooseLink
                                  ? null
                                  : () => _pickVerifiedRoute(linkOnly: true),
                            ),
                          ],
                        )
                      else ...[
                        Text(
                          'Transport: ${_transportLabel(route?['transport'] as String?)}',
                        ),
                        Text('Link: $linkName'),
                      ],
                      Text('Last handshake: ${_lastHandshake(context)}'),
                      if (widget.forDownload && route != null)
                        FilledButton(
                          onPressed: busy
                              ? null
                              : () => Navigator.pop(context, true),
                          child: const Text('Use selected connection'),
                        ),
                      if (!isRevoked &&
                          route == null &&
                          _resumedDirect?['active'] == true &&
                          !_keptUnconnectedDirect &&
                          !_canJoinResumedDirectLink)
                        TextButton(
                          onPressed: busy ? null : _keepResumedDirectLink,
                          child: const Text('Keep open link'),
                        ),
                      if (recordedSpeed > 0)
                        Text(
                          'Speed: ${recordedSpeed.toStringAsFixed(2)} MiB/s',
                        ),
                      if (!isRevoked)
                        TextButton.icon(
                          key: const ValueKey('overview-speed-test'),
                          onPressed: busy || route == null
                              ? null
                              : _runSpeedTest,
                          icon: const Icon(Icons.speed),
                          label: Text(
                            testingPathId == 'speed:active'
                                ? 'Testing…'
                                : 'Speed test',
                          ),
                        ),
                      if (testMessage?.startsWith('Speed test') == true ||
                          testMessage?.startsWith('Connection failed') == true)
                        Text(testMessage!),
                    ],
                  ),
                ),
                ListTile(
                  dense: true,
                  leading: Icon(
                    route != null ? Icons.hub_outlined : Icons.link_off,
                    size: 18,
                  ),
                  title: Text(
                    route != null
                        ? routeTitle(route!['transport'] as String?)
                        : (isRevoked
                              ? 'Device revoked'
                              : 'No active connection'),
                  ),
                  subtitle: Text(
                    isRevoked
                        ? 'Device is revoked — remove or re-pair to use connections.'
                        : (linkBits.isNotEmpty
                              ? linkBits.join(' · ')
                              : 'Open Connections to set up a manual link'),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (isDirectActive) ...[
                        OutlinedButton(
                          onPressed: busy ? null : _stopDirectLink,
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            visualDensity: VisualDensity.compact,
                          ),
                          child: testingPathId == 'stop:direct'
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Stop link'),
                        ),
                        const SizedBox(width: 8),
                      ],
                      const Text('Connections'),
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                  onTap: () => _tabController.animateTo(1),
                ),
              ],
            ),
          ),
        if (!isRevoked && widget.peer['status'] == 'paired')
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('device-open-terminal'),
                  onPressed: busy || !hasSsh
                      ? null
                      : () => _openSelectedSsh(
                          activeEndpoint,
                          effectiveTransport,
                        ),
                  icon: const Icon(Icons.terminal),
                  label: const Text('Terminal'),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey('device-open-files'),
                  onPressed: busy ? null : _openDeviceFiles,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Files'),
                ),
              ],
            ),
          ),
        if (roots.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Folders', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final feature in widget.registry.available(['remote-files-v1']))
            for (final root in roots)
              Card(
                child: ListTile(
                  leading: Icon(feature.icon),
                  title: Text('${root['name']}'),
                  subtitle: Text(feature.label),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: busy
                      ? null
                      : () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => FileBrowser(
                                core: widget.core,
                                peer: widget.peer,
                                registry: widget.registry,
                                candidates: widget.candidates,
                                root: root['id'] as String,
                                path: '.',
                              ),
                            ),
                          );
                          if (mounted) {
                            await load();
                          }
                        },
                ),
              ),
        ],
        const SizedBox(height: 12),
        if (const {
              'preparing',
              'verifying',
              'needs_recovery',
            }.contains(_linkOperation['stage']) ||
            const {'preparing', 'needs_recovery'}.contains(_localLeaseStage))
          _recoveryCard(),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: busy ? null : () => remove(defaultHost),
              child: const Text('Remove device'),
            ),
            if ((peerCaps?['os'] ?? widget.peer['os']) == null ||
                (peerCaps?['os'] ?? widget.peer['os']) == 'linux')
              TextButton(
                onPressed: busy ? null : _removeLocally,
                child: const Text('Remove without uninstalling daemon'),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _openDeviceAclSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final tags =
              (_aclEval['tags'] as List? ??
                      widget.peer['tags'] as List? ??
                      const [])
                  .map((e) => '$e')
                  .toList();
          final groups =
              (_aclEval['groups'] as List? ??
                      widget.peer['groups'] as List? ??
                      const [])
                  .map((e) => '$e')
                  .toList();
          final aclOn = _aclEval['enabled'] == true;
          final decisions = (_aclEval['decisions'] as List? ?? const [])
              .whereType<Map>()
              .toList();
          final allowedCount = decisions
              .where((d) => d['allowed'] == true)
              .length;
          final summary = !aclOn
              ? 'ACL enforcement is off (per-device grants apply).'
              : (decisions.isEmpty
                    ? 'ACL enforced'
                    : '$allowedCount of ${decisions.length} services allowed');
          final isTrusted = tags.contains('tag:trusted');
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Access & ACL · ${widget.peer['name']}',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(summary),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    key: const ValueKey('device-trusted-tag-chip'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Trusted device (tag:trusted)'),
                    subtitle: const Text(
                      'Grants full access when Tailscale-style ACL rules are enforced.',
                    ),
                    value: isTrusted,
                    onChanged: (select) async {
                      final next = List<String>.from(tags);
                      if (select && !next.contains('tag:trusted')) {
                        next.add('tag:trusted');
                      } else if (!select) {
                        next.remove('tag:trusted');
                      }
                      await widget.core.run([
                        'peer-tags',
                        '${widget.peer['id']}',
                        next.isEmpty ? 'none' : next.join(','),
                      ]);
                      if (mounted) {
                        await load(background: true);
                        if (ctx.mounted) setSheet(() {});
                      }
                    },
                  ),
                  if (tags.isNotEmpty || groups.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final t in tags) Chip(label: Text(t)),
                        for (final g in groups) Chip(label: Text(g)),
                      ],
                    ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    key: const ValueKey('device-manage-acl'),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AclScreen(core: widget.core),
                        ),
                      );
                      if (mounted) {
                        await load(background: true);
                      }
                    },
                    icon: const Icon(Icons.security_outlined),
                    label: const Text('Manage ACL rules & groups'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _directHostTile({
    required String kind,
    required IconData icon,
    required String title,
    required String? phoneLabel,
    required String? laptopLabel,
  }) {
    const padding = EdgeInsets.symmetric(horizontal: 10);
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      isThreeLine: true,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_directBandSummary()),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (phoneLabel != null)
                FilledButton.tonal(
                  style: FilledButton.styleFrom(padding: padding),
                  onPressed: busy
                      ? null
                      : () => _startDirectLink(kind, hostSide: 'phone'),
                  child: Text(phoneLabel),
                ),
              if (laptopLabel != null)
                OutlinedButton(
                  style: OutlinedButton.styleFrom(padding: padding),
                  onPressed: busy
                      ? null
                      : () => _startDirectLink(kind, hostSide: 'laptop'),
                  child: Text(laptopLabel),
                ),
            ],
          ),
        ],
      ),
      trailing: testingPathId?.startsWith('start:$kind:') == true
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
    );
  }

  Future<void> _activatePath(
    _ReachablePath path, {
    bool linkOnly = false,
  }) async {
    if (path.transport == 'lan' &&
        path.interfaceName != null &&
        path.cidr != null &&
        (widget.core.network?['interface'] != path.interfaceName ||
            widget.core.network?['cidr'] != path.cidr)) {
      await widget.core.approveNetwork(
        path.networkMap ??
            {
              'interface': path.interfaceName,
              'cidr': path.cidr,
              if (path.kind != null) 'kind': path.kind,
            },
      );
    }
    await selectConnection(
      path.transport,
      preferredLink: linkOnly ? _linkPreference(path) : null,
      pathId: path.id,
      endpoint: path.endpoint,
      remoteApproved: path.remoteApproved ? true : null,
    );
  }

  String _recoveryDeadlineNote() {
    final dl = _localLeaseDeadlineMs;
    if (dl == null || dl <= 0) return '';
    final rem = ((dl - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    return rem > 0
        ? ' Auto-restore deadline in ${rem}s.'
        : ' Auto-restore deadline elapsed.';
  }

  Widget _recoveryCard() => NetworkCard(
    icon: Icons.restore,
    title: 'Link setup needs recovery',
    detail:
        'A previous setup did not finish. Restore both devices before starting another. If the peer is unreachable, restore its network manually.${_recoveryDeadlineNote()}',
    actions: [
      TextButton(
        onPressed: busy ? null : _stopDirectLink,
        child: const Text('Restore connection'),
      ),
    ],
  );

  Future<void> _journalLink(String stage) async {
    final id = _linkOperation['id'];
    if (id is! String || id.isEmpty) return;
    try {
      final value = await widget.core.run([
        'link-operation',
        '${widget.peer['id']}',
        stage,
        id,
      ]) as Map;
      _linkOperation = Map<String, dynamic>.from(value);
    } catch (e) {
      DebugTrace.logError(
        'LinkOperation',
        'Could not save recovery state',
        error: e,
      );
    }
  }

  Future<void> _openSelectedSsh(String? endpoint, String transport) async {
    if ((_sshMethod == 'auto' || _sshMethod == 'agent') &&
        !(peerCaps?['features'] as List? ?? const []).contains(
          'agent-ssh-v1',
        )) {
      final associated = _sshHosts
          .where((h) => h['agent_peer_id'] == widget.peer['id'])
          .toList();
      if (_sshMethod == 'auto' && associated.length == 1) {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) =>
                SshHostScreen(core: widget.core, host: associated.single),
          ),
        );
      } else {
        await _openAlternativeSsh();
      }
      return;
    }

    if (_sshMethod.startsWith('ssh:')) {
      final host = _sshHosts.firstWhere((h) => 'ssh:${h['id']}' == _sshMethod);
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => SshHostScreen(core: widget.core, host: host),
        ),
      );
    } else {
      final workspace = TerminalWorkspaceScope.of(context);
      if (workspace != null) {
        final network =
            _activeReachablePath()?.networkMap ?? widget.core.network;
        workspace.openRemote({
          'peer': widget.peer['id'],
          'name': _deviceName,
          'endpoint': endpoint,
          'transport': transport,
          'interface': network?['interface'],
          'cidr': network?['cidr'],
        });
        return;
      }
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => GuestTerminalScreen(
            core: widget.core,
            sessionId: 'agent-${widget.peer['id']}',
            host: _deviceName,
            credentials: const {},
            agentMode: true,
            peerId: '${widget.peer['id']}',
            endpoint: endpoint,
            transport: transport,
          ),
        ),
      );
    }
  }

  Widget _connectionChoice(bool supported) => PopupMenuButton<String>(
    enabled: !busy,
    key: const ValueKey('overview-connection-choice'),
    tooltip: 'Choose connection',
    initialValue: _sshMethod,
    onSelected: (method) async {
      try {
        await widget.core.run([
          'peer-ssh-method',
          '${widget.peer['id']}',
          method,
        ]);
        if (mounted) setState(() => _sshMethod = method);
      } catch (e) {
        if (mounted) setState(() => offlineNote = '$e');
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(
        value: 'auto',
        child: Text('Automatic · paired Agent'),
      ),
      if (supported)
        const PopupMenuItem(
          value: 'agent',
          child: Text('Agent SSH · paired identity'),
        ),
      for (final host in _sshHosts.where(
        (h) => h['agent_peer_id'] == widget.peer['id'],
      ))
        PopupMenuItem(
          value: 'ssh:${host['id']}',
          child: Text(
            '${host['name']} · ${host['user']}@${host['host']}:${host['port']}',
          ),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        _sshMethod == 'auto'
            ? 'Automatic ▾'
            : _sshMethod == 'agent'
            ? 'Agent SSH ▾'
            : 'SSH account ▾',
      ),
    ),
  );

  Future<void> _pickVerifiedRoute({required bool linkOnly}) async {
    final active = _activeReachablePath();
    final transport = active?.transport ?? route?['transport'];
    final allowedPaths = reachablePaths.where(
      (path) =>
          !linkOnly ||
          path.transport == transport ||
          (transport == 'direct-lan-v1' && path.transport == 'lan'),
    );
    final byTransport = <String, _ReachablePath>{};
    for (final path in allowedPaths) {
      if (_isPathSelected(path)) {
        byTransport[path.transport] = path;
      } else {
        byTransport.putIfAbsent(path.transport, () => path);
      }
    }
    final options = linkOnly ? allowedPaths : byTransport.values;
    final selected = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(linkOnly ? 'Choose link' : 'Choose transport'),
              subtitle: Text(
                linkOnly ? 'Verified links for the selected transport.' : 'Choosing a transport also selects one of its verified links.',
              ),
            ),
            ListTile(
              title: Text(linkOnly ? 'Automatic link' : 'Automatic routing'),
              trailing:
                  (linkOnly ? _preferredLink : _preferredTransport) == 'auto'
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.pop(context, 'auto'),
            ),
            if (linkOnly && _preferredLink != 'auto')
              ListTile(
                title: Text(
                  'Preferred link · ${switch (_preferredLink) {
                    'wifi' => 'Wi-Fi',
                    'ethernet' => 'Ethernet',
                    'usb_net' => 'USB network',
                    'wifi_direct' => 'Wi-Fi Direct',
                    'hotspot' => 'Hotspot',
                    _ => _preferredLink,
                  }}',
                ),
              ),
            for (final path in options)
              ListTile(
                title: Text(
                  linkOnly ? path.label : _transportLabel(path.transport),
                ),
                subtitle: Text(_pathSubtitle(path, _isPathSelected(path))),
                trailing: _isPathSelected(path)
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, path),
              ),
          ],
        ),
      ),
    );
    if (!mounted || selected == null) return;
    try {
      if (selected == 'auto') {
        final id = widget.peer['id'] as String;
        final current = await widget.core.run(['connection', id]) as Map;
        await widget.core.run(
          ['connection', id, '-'],
          input: jsonEncode({
            ...current,
            if (linkOnly)
              'preferred_link': 'auto'
            else
              'preferred_transport': 'auto',
            if (!linkOnly) 'fallback_approved': true,
          }),
        );
        if (mounted) await load();
      } else if (selected is _ReachablePath) {
        await _activatePath(selected, linkOnly: linkOnly);
      }
    } catch (error) {
      if (mounted) setState(() => offlineNote = _friendlyError(error));
    }
  }

  String _transportLabel(String? transport) => switch (transport) {
    'lan' || 'direct-lan-v1' => 'Direct TCP',
    null => '—',
    _ => _methodLabel(transport),
  };

  Widget _agentSshCard() {
    return NetworkCard(
      icon: Icons.terminal,
      key: const ValueKey('peer-connection-settings'),
      title: 'Connection',
      headingAction: IconButton(
        tooltip: 'Connection preferences',
        onPressed: busy ? null : _showRoutePreferences,
        icon: const Icon(Icons.settings_outlined),
      ),
      extra: SwitchListTile.adaptive(
        key: const ValueKey('allow-peer-agent-ssh'),
        contentPadding: EdgeInsets.zero,
        title: Text('Allow ${widget.peer['name']} to SSH into this device'),
        subtitle: Text(
          _sshAccess['requested'] == true
              ? 'This device has requested shell access. Approve only if you trust it.'
              : 'Separate approval from file access. Runs as this device’s app/account.',
        ),
        value: _sshAccess['allowed'] == true,
        onChanged: busy
            ? null
            : (allow) async {
                try {
                  final access = await widget.core.run([
                    'peer-ssh-access',
                    '${widget.peer['id']}',
                    allow ? 'allow' : 'deny',
                  ]) as Map;
                  if (mounted) {
                    setState(
                      () => _sshAccess = Map<String, dynamic>.from(access),
                    );
                  }
                } catch (e) {
                  if (mounted) setState(() => offlineNote = '$e');
                }
              },
      ),
      actions: [
        TextButton.icon(
          onPressed: busy ? null : _openAlternativeSsh,
          icon: const Icon(Icons.add),
          label: const Text('Manage SSH accounts'),
        ),
      ],
    );
  }

  Future<void> _openAlternativeSsh() async {
    final raw = await widget.core.run(['ssh-hosts']);
    if (!mounted) return;
    final hosts = (raw as List).whereType<Map>().toList();
    final choice = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Choose an SSH account'),
              subtitle: Text(
                'Ordinary SSH uses the host’s verified identity and account. Agent SSH uses pairing automatically.',
              ),
            ),
            for (final h in hosts)
              ListTile(
                leading: const Icon(Icons.terminal),
                title: Text('${h['name']}'),
                subtitle: Text('${h['user']}@${h['host']}:${h['port']}'),
                onTap: () =>
                    Navigator.pop(context, Map<String, dynamic>.from(h)),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Add SSH device'),
              onTap: () => Navigator.pop(context, <String, dynamic>{}),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SshHostScreen(
          core: widget.core,
          host: choice.isEmpty ? null : choice,
        ),
      ),
    );
    if (mounted) await load(background: true);
  }

  Widget _buildConnectionsTab({
    required BuildContext context,
    required bool isRevoked,
    required String? defaultHost,
    required bool directLinkOpen,
    required Map<String, dynamic>? phoneCaps,
    required Map<String, dynamic>? laptopCaps,
    required bool phoneCanHotspotHost,
    required bool laptopCanHotspotHost,
    required bool phoneCanP2pHost,
    required bool laptopCanP2pHost,
  }) {
    if (isRevoked) {
      return const Center(child: Text('Device revoked'));
    }
    final linkPaths = reachablePaths.where(
      (path) => _manualPath(path) && path.transport == 'lan',
    );
    final adbStarted = reachablePaths.any((path) => path.transport == 'adb');
    final canStartDirect =
        phoneCanHotspotHost ||
        laptopCanHotspotHost ||
        phoneCanP2pHost ||
        laptopCanP2pHost;
    final showManual =
        canStartDirect ||
        (peerCaps == null && platformCaps['wifi'] != false) ||
        linkPaths.isNotEmpty ||
        _savedDirect != null ||
        _resumedDirect?['active'] == true;
    final sameOS =
        peerCaps?['os'] != null && peerCaps?['os'] == platformCaps['os'];
    final peerName = '${widget.peer['name']}';
    final phoneName = sameOS
        ? (Platform.isAndroid ? 'This device' : peerName)
        : 'Phone';
    final laptopName = sameOS
        ? (Platform.isAndroid ? peerName : 'This device')
        : 'Laptop';
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _agentSshCard(),
        if (const {
              'preparing',
              'verifying',
              'needs_recovery',
            }.contains(_linkOperation['stage']) ||
            const {'preparing', 'needs_recovery'}.contains(_localLeaseStage))
          _recoveryCard(),
        if (testMessage != null &&
            (_startingDirect ||
                (!testMessage!.startsWith('Speed test') &&
                    !testMessage!.startsWith('Connection failed'))))
          ListTile(
            leading: Icon(
              testSuccess == true
                  ? Icons.check_circle_outline
                  : testSuccess == false
                  ? Icons.error_outline
                  : Icons.sync,
            ),
            title: Text(testMessage!),
            trailing: _startingDirect && !_cancellingDirect
                ? TextButton(
                    onPressed: () => setState(() {
                      _cancellingDirect = true;
                      testMessage =
                          'Cancelling setup and restoring standard Wi-Fi…';
                    }),
                    child: const Text('Cancel'),
                  )
                : null,
          ),
        if (_canUseUsbAdb)
          Card(
            child: ListTile(
              key: const ValueKey('manual-usb-adb'),
              leading: const Icon(Icons.usb),
              title: const Text('ADB over USB'),
              subtitle: adbStarted
                  ? const Text('Started')
                  : const Text('ADB reverse tunnel'),
              trailing: adbStarted
                  ? null
                  : FilledButton.tonal(
                      onPressed: busy ? null : () => _startAdbUsb(defaultHost),
                      child: Text(
                        testingPathId == 'start:adb_usb'
                            ? 'Starting…'
                            : 'Start',
                      ),
                    ),
            ),
          ),
        if (showManual)
          NetworkCard(
            icon: Icons.wifi_tethering,
            key: const ValueKey('peer-direct-link-setup'),
            title: 'Direct link setup',
            extra: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  title: const Text('Wi-Fi Direct and hotspot'),
                  trailing:
                      canStartDirect || directLinkOpen || linkPaths.isNotEmpty
                      ? IconButton(
                          tooltip: 'Connection settings (channel & width)',
                          onPressed: busy ? null : _openChannelPicker,
                          icon: const Icon(Icons.tune),
                        )
                      : null,
                ),
                if (linkPaths.isNotEmpty)
                  ListTile(
                    title: Text(linkPaths.first.label),
                    trailing: TextButton(
                      onPressed: busy ? null : _stopDirectLink,
                      child: const Text('Stop'),
                    ),
                  ),
                if (_savedDirect
                    case {
                      'kind': final String kind,
                      'joined': final bool joined,
                    }
                    when !isRevoked &&
                        !directLinkOpen &&
                        (kind == 'hotspot' || kind == 'wifi_direct'))
                  ListTile(
                    leading: Icon(
                      kind == 'wifi_direct'
                          ? Icons.wifi_find
                          : Icons.wifi_tethering,
                    ),
                    title: Text(
                      kind == 'wifi_direct'
                          ? 'Saved Wi-Fi Direct'
                          : (joined
                                ? 'Saved Laptop Hotspot'
                                : 'Saved Mobile Hotspot'),
                    ),
                    subtitle: Text('${_savedDirect?['ssid'] ?? ''}'),
                    trailing: OutlinedButton(
                      onPressed: busy ? null : _connectSavedDirectLink,
                      child: Text(joined ? 'Reconnect' : 'Restart'),
                    ),
                  ),
                () {
                  final hasReachableP2p = reachablePaths.any(
                    (p) =>
                        p.kind == 'wifi_direct' ||
                        (p.interfaceName ?? '').startsWith('p2p'),
                  );
                  final hasReachableHotspot = reachablePaths.any(
                    (p) =>
                        p.kind == 'hotspot' ||
                        (p.interfaceName ?? '').startsWith('ap') ||
                        (p.interfaceName ?? '').startsWith('swlan'),
                  );
                  final r = _resumedDirect;
                  final rKind = '${r?['kind'] ?? ''}';
                  final showResumed =
                      !isRevoked &&
                      r != null &&
                      r['active'] == true &&
                      ((rKind == 'wifi_direct' && !hasReachableP2p) ||
                          (rKind == 'hotspot' && !hasReachableHotspot) ||
                          (rKind == 'wifi_join' &&
                              !hasReachableHotspot &&
                              !hasReachableP2p));
                  if (!showResumed) {
                    return const SizedBox.shrink();
                  }
                  final rLabel = rKind == 'wifi_direct'
                      ? 'Wi-Fi Direct (Open)'
                      : (rKind == 'hotspot'
                            ? 'Mobile Hotspot (Open)'
                            : 'Direct Wi-Fi (Open)');
                  final rIface = '${r['interface'] ?? ''}';
                  final rIp = '${r['ip'] ?? ''}';
                  final rSsid = '${r['ssid'] ?? ''}';
                  final rBand = '${r['band'] ?? ''}';
                  final rFreq = (r['frequency_mhz'] as num?)?.toInt() ?? 0;
                  final rCh =
                      (r['channel'] as num?)?.toInt() ??
                      (rFreq > 0 ? freqToChannel(rFreq) : 0);
                  final radioBits = <String>[
                    if (rBand.isNotEmpty) rBand,
                    if (rCh > 0)
                      'Ch $rCh${rFreq > 0 ? ' ($rFreq MHz)' : ''}'
                    else if (rFreq > 0)
                      '$rFreq MHz',
                  ].join(' · ');
                  final metaBits = <String>[
                    if (rIface.isNotEmpty)
                      '$rIface${rIp.isNotEmpty ? ' ($rIp)' : ''}',
                    if (rSsid.isNotEmpty) rSsid,
                    if (radioBits.isNotEmpty) radioBits,
                  ].join(' · ');
                  return ListTile(
                    leading: Icon(
                      _keptUnconnectedDirect
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: Text(rLabel),
                    isThreeLine: true,
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${metaBits.isNotEmpty ? '$metaBits\n' : ''}${_keptUnconnectedDirect ? 'Kept as selected connection · peer not connected yet' : 'Open from previous session · laptop not connected yet'}',
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (_canJoinResumedDirectLink)
                              FilledButton.tonal(
                                onPressed: busy ? null : _keepResumedDirectLink,
                                child: const Text('Connect peer'),
                              ),
                            OutlinedButton(
                              onPressed: busy ? null : _stopDirectLink,
                              child: const Text('Stop'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    trailing:
                        (testingPathId == 'keep:direct' ||
                            testingPathId == 'stop:direct')
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                  );
                }(),
                if (peerCaps == null || _peerCapsCached)
                  ListTile(
                    leading: const Icon(Icons.help_outline),
                    title: const Text('Peer wireless support'),
                    subtitle: Text(
                      probingPaths ? 'Checking wireless capabilities…' : 'Tap Check support when the peer is reachable to inspect Hotspot and Wi-Fi Direct options.',
                    ),
                    trailing: TextButton(
                      key: const ValueKey('direct-check-support'),
                      onPressed: busy ? null : () => load(),
                      child: const Text('Check support'),
                    ),
                  ),
                if (!isRevoked &&
                    !reachablePaths.any(
                      (p) =>
                          p.kind == 'wifi_direct' ||
                          (p.interfaceName ?? '').startsWith('p2p'),
                    ) &&
                    !(_resumedDirect?['active'] == true &&
                        _resumedDirect?['kind'] == 'wifi_direct') &&
                    (phoneCanP2pHost || laptopCanP2pHost))
                  _directHostTile(
                    kind: 'wifi_direct',
                    icon: Icons.wifi_find,
                    title: 'Wi-Fi Direct',
                    phoneLabel: phoneCanP2pHost
                        ? (phoneCaps?['wifi_5ghz'] == true
                              ? '$phoneName (5 GHz)'
                              : phoneName)
                        : null,
                    laptopLabel: laptopCanP2pHost ? laptopName : null,
                  ),
                if (!isRevoked &&
                    !reachablePaths.any(
                      (p) =>
                          p.kind == 'hotspot' ||
                          (p.interfaceName ?? '').startsWith('ap') ||
                          (p.interfaceName ?? '').startsWith('swlan'),
                    ) &&
                    !(_resumedDirect?['active'] == true &&
                        _resumedDirect?['kind'] == 'hotspot') &&
                    (phoneCanHotspotHost || laptopCanHotspotHost))
                  _directHostTile(
                    kind: 'hotspot',
                    icon: Icons.wifi_tethering,
                    title: 'Wi-Fi Hotspot',
                    phoneLabel: phoneCanHotspotHost
                        ? (phoneCaps?['wifi_5ghz'] == true
                              ? '$phoneName (5 GHz)'
                              : phoneName)
                        : null,
                    laptopLabel: laptopCanHotspotHost
                        ? (laptopCaps?['hotspot_5ghz_ap'] == true
                              ? '$laptopName (5 GHz)'
                              : '$laptopName (2.4 GHz)')
                        : null,
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> remove(String? defaultHost) async {
    final os = peerCaps?['os'] ?? widget.peer['os'];
    if (os == null || os == 'linux') {
      final removed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SshBootstrapDialog(
          core: widget.core,
          initialHost: defaultHost,
          uninstallPeerId: widget.peer['id'] as String,
          deviceName: widget.peer['name'] as String?,
        ),
      );
      if (removed == true && mounted) Navigator.pop(context);
      return;
    }
    await _removeLocally();
  }

  Future<void> _removeLocally() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this device?'),
        content: const Text(
          'Grants, cached addresses and saved connection settings for this device will be deleted from this device without touching any remote daemon.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (approved == true) {
      try {
        await widget.core.run(['remove', widget.peer['id'] as String]);
        if (mounted) {
          Navigator.pop(context);
        }
      } catch (e) {
        if (mounted) {
          setState(() => offlineNote = _friendlyError(e));
        }
      }
    }
  }
}

class FileBrowser extends StatefulWidget {
  const FileBrowser({
    super.key,
    required this.core,
    required this.peer,
    required this.registry,
    required this.root,
    required this.path,
    this.candidates = const [],
  });
  final CoreBridge core;
  final Map<String, dynamic> peer;
  final FeatureRegistry registry;
  final List<dynamic> candidates;
  final String root, path;
  @override
  State<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser> with WidgetsBindingObserver {
  List<dynamic> entries = [];
  bool busy = true;
  String? error;
  String next = '';
  String? received;
  double? receivedMiB;
  String? receivedMode;
  String? receivedTransport;
  String? routeNotice;
  bool waitingForRoute = false;
  String? meteredApprovalId;
  bool approvingMetered = false;
  bool choosingDownloadRoute = false;
  bool pulling = false;
  Map<String, dynamic>? liveProgress;
  StreamSubscription<Map<String, dynamic>>? progressSub;

  late String sourcePath;
  bool showHidden = false;
  String activeSide = 'source';
  List<Map> syncedFolders = [];
  List<Map> syncedPairs = [];
  String preferredMethod = 'auto'; // 'auto' | 'tar'
  Map<String, dynamic>? connectionConfig;
  Map<String, dynamic>? resolvedRoute;
  Map<String, dynamic>? interruptedPull;
  bool hoverTargetPane = false;
  String? hoverTargetEntryId;

  // Target pane state: 'downloads' (desktop) | 'local' | 'termux_home' (Android)
  String targetMode = 'downloads';
  bool get usingTargetSaf => false;
  bool get targetPermissionMissing =>
      Platform.isAndroid && targetMode == 'local' && !allFilesAccess;
  late String targetPosixPath;
  String? termuxHomePath;
  String? targetSafUri;
  String? targetSafName;
  final List<String> safStack = [];
  List<Map<String, dynamic>> targetEntries = [];
  String? targetError;
  bool targetBusy = false;
  bool allFilesAccess = !Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    sourcePath = widget.path;
    if (Platform.isAndroid) {
      targetMode = 'local';
    }
    targetPosixPath = Platform.isAndroid
        ? '/storage/emulated/0'
        : widget.core.downloads;
    progressSub = widget.core.transferProgress.listen((p) {
      if (!mounted || !pulling) {
        return;
      }
      setState(() {
        if (p['transfer_state'] == 'waiting') {
          meteredApprovalId = null;
          waitingForRoute = true;
          routeNotice = 'Waiting for connection…';
        } else if (p['transfer_state'] == 'metered') {
          meteredApprovalId = p['approval_id'] as String?;
          waitingForRoute = true;
          routeNotice = 'Paused. Tailscale would use mobile or metered data.';
        } else if (p['transfer_state'] == 'resuming') {
          meteredApprovalId = null;
          waitingForRoute = false;
          routeNotice =
              'Resuming over ${connectionDisplayName('${p['transport'] ?? ''}')}';
        } else if (p['route_switched'] == true) {
          routeNotice =
              'Route disrupted · resumed over ${connectionDisplayName('${p['to'] ?? ''}')} (${p['endpoint']})';
        } else if (p.containsKey('verified_bytes')) {
          liveProgress = p;
        }
      });
    });
    loadBrowserSettings();
    loadSource();
    loadActiveRoute();
    loadTargetCapabilities();
    readSyncFolders();
  }

  Future<void> readSyncFolders() async {
    try {
      final profile = await widget.core.run(['syncthing', 'status']) as Map;
      if (mounted) {
        setState(
          () => syncedFolders = (profile['registered'] as List? ?? [])
              .whereType<Map>()
              .toList(),
        );
      }
      final pairs = await widget.core.run(['sync-pairs']);
      if (mounted && pairs is List) {
        setState(() => syncedPairs = pairs.whereType<Map>().toList());
      }
    } catch (_) {
      /* File browsing remains independent of sync setup. */
    }
  }

  Future<void> syncSourceFolder(String path, String name) async {
    final destination = await pickSyncFolder(
      context,
      widget.core,
      excludeDevice: '${widget.peer['id']}',
    );
    if (!mounted || destination == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => FolderPairSync(
          core: widget.core,
          source: SyncLocation(
            device: '${widget.peer['id']}',
            name: '${widget.peer['name']}',
            root: widget.root,
            path: path,
          ),
          target: destination,
          fullPull: (location) =>
              openFullFolderPull(context, widget.core, location),
        ),
      ),
    );
    await readSyncFolders();
  }

  Future<void> syncTargetFolder(String path, String name) async {
    final destination = await pickSyncFolder(
      context,
      widget.core,
      excludeDevice: 'local',
    );
    if (!mounted || destination == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => FolderPairSync(
          core: widget.core,
          source: SyncLocation(
            device: 'local',
            name: 'This device',
            root: 'local',
            path: '',
            localPath: path,
          ),
          target: destination,
          fullPull: (location) =>
              openFullFolderPull(context, widget.core, location),
        ),
      ),
    );
    await readSyncFolders();
  }

  Future<void> loadBrowserSettings() async {
    final settings = await widget.core.appSettings();
    if (mounted) setState(() => showHidden = settings['show_hidden'] == true);
  }

  Future<void> loadActiveRoute() async {
    try {
      final cfg = await widget.core.run([
        'connection',
        widget.peer['id'] as String,
      ]);
      if (cfg is Map) {
        connectionConfig = Map<String, dynamic>.from(cfg);
      }
    } catch (_) {
      /* keep best-effort connection metadata */
    }
    try {
      final res = await widget.core.run([
        'resolve',
        widget.peer['id'] as String,
      ]);
      if (res is Map) {
        resolvedRoute = Map<String, dynamic>.from(res);
      }
    } catch (_) {
      /* offline or pending route */
    }
    if (mounted) {
      setState(() {});
    }
  }

  String connectionDisplayName(String transport) {
    switch (transport) {
      case 'adb':
        return 'ADB over USB';
      case 'ssh':
        return 'SSH Tunnel';
      case 'tailnet':
      case 'tsnet-v1':
      case 'tailscaled-v1':
        final pk = resolvedRoute?['path_kind'] as String? ?? '';
        return pk.isEmpty ? 'Tailscale' : 'Tailscale ($pk)';
      case 'wireguard':
      case 'wireguard-v1':
        final pk = resolvedRoute?['path_kind'] as String? ?? '';
        return pk.isEmpty ? 'WireGuard' : 'WireGuard ($pk)';
      case 'direct-lan-v1':
      case 'lan':
        final kind = widget.core.network?['kind'] as String? ?? '';
        if (kind == 'wifi_direct') {
          return 'Wi-Fi Direct';
        }
        if (kind == 'hotspot') {
          return 'Hotspot';
        }
        return 'Wi-Fi LAN';
      default:
        return transport.isEmpty ? 'Wi-Fi LAN' : transport;
    }
  }

  String activeConnectionSummary() {
    final t =
        (resolvedRoute?['transport'] as String?) ??
        (connectionConfig?['transport'] as String?) ??
        'lan';
    final name = connectionDisplayName(t);
    final ep =
        (resolvedRoute?['endpoint'] as String?) ??
        (connectionConfig?['endpoint'] as String?) ??
        '';
    return ep.isEmpty ? name : '$name · $ep';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    progressSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      loadTargetCapabilities();
    }
  }

  Future<void> loadTargetCapabilities() async {
    try {
      final caps = await widget.core.platformCapabilities();
      allFilesAccess = caps['all_files_access'] == true;
      termuxHomePath = caps['termux_home_path'] as String?;
      if (Platform.isAndroid &&
          (termuxHomePath == null || termuxHomePath!.isEmpty)) {
        try {
          final rootsList = await widget.core.localFiles('roots', {}) as List;
          for (final r in rootsList.whereType<Map>()) {
            if (r['id'] == 'termux_home' && r['native_path'] is String) {
              termuxHomePath = r['native_path'] as String;
              break;
            }
          }
        } catch (_) {}
      }
      if (targetMode == 'local' && Platform.isAndroid && allFilesAccess) {
        if (!targetPosixPath.startsWith('/storage/')) {
          targetPosixPath = '/storage/emulated/0';
        }
      } else if (targetMode == 'termux_home' &&
          Platform.isAndroid &&
          termuxHomePath != null) {
        if (!targetPosixPath.startsWith(termuxHomePath!)) {
          targetPosixPath = termuxHomePath!;
        }
      }
    } catch (_) {
      /* optional platform metadata */
    }
    await loadTarget();
  }

  Future<void> switchTargetMode(String mode) async {
    setState(() {
      targetMode = mode;
      targetError = null;
      safStack.clear();
    });
    if (mode == 'downloads') {
      targetPosixPath = widget.core.downloads;
      await loadTarget();
      return;
    }
    if (!Platform.isAndroid) {
      targetPosixPath = widget.core.homeDir;
      await loadTarget();
      return;
    }
    final caps = await widget.core.platformCapabilities();
    allFilesAccess = caps['all_files_access'] == true;
    termuxHomePath ??= caps['termux_home_path'] as String?;
    if (mode == 'local') {
      targetPosixPath = '/storage/emulated/0';
      targetSafUri = null;
      if (!allFilesAccess) {
        await widget.core.openConnectionSetup('all_files_access');
        await loadTargetCapabilities();
        return;
      }
    } else if (mode == 'termux_home') {
      targetSafUri = null;
      if (termuxHomePath == null || termuxHomePath!.isEmpty) {
        await loadTargetCapabilities();
        return;
      }
      targetPosixPath = termuxHomePath!;
    }
    await loadTarget();
  }

  Future<void> pickTargetFolder() async {
    try {
      final picked = await widget.core.pickTargetTree();
      if (picked != null && mounted) {
        setState(() {
          targetSafUri = picked['uri'] as String?;
          targetSafName = picked['name'] as String?;
          safStack.clear();
        });
      }
      await loadTarget();
    } on PlatformException catch (e) {
      if (mounted) setState(() => targetError = e.message ?? e.code);
    }
  }

  Future<void> loadTarget() async {
    if (!mounted) {
      return;
    }
    setState(() {
      targetBusy = true;
      targetError = null;
    });
    try {
      if (targetPermissionMissing) {
        targetEntries = [];
      } else if (!usingTargetSaf) {
        final dir = Directory(targetPosixPath);
        if (!dir.existsSync()) {
          targetEntries = [];
        } else {
          final list = <Map<String, dynamic>>[];
          for (final entity in dir.listSync(followLinks: false)) {
            final name = entity.uri.pathSegments
                .where((s) => s.isNotEmpty)
                .last;
            final stat = entity.statSync();
            list.add({
              'name': name,
              'path': entity.path,
              'kind': stat.type == FileSystemEntityType.directory
                  ? 'directory'
                  : 'file',
              'size': stat.size,
            });
          }
          list.sort((a, b) {
            if (a['kind'] != b['kind']) {
              return a['kind'] == 'directory' ? -1 : 1;
            }
            return (a['name'] as String).toLowerCase().compareTo(
              (b['name'] as String).toLowerCase(),
            );
          });
          targetEntries = list;
        }
      } else if (targetSafUri != null) {
        final docId = safStack.isEmpty ? null : safStack.last;
        final res = await widget.core.listTargetTree(
          targetSafUri!,
          documentId: docId,
        );
        targetEntries = (res['entries'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } else {
        targetEntries = [];
      }
    } catch (e) {
      targetError = e.toString();
    }
    if (mounted) {
      setState(() => targetBusy = false);
    }
  }

  Future<void> loadSource({bool more = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final page = await widget.core.run([
        'list',
        widget.peer['id'] as String,
        widget.root,
        sourcePath,
        more ? next : '',
      ]) as Map;
      if (!more) {
        entries = [];
      }
      entries.addAll(page['entries'] as List);
      next = page['next'] as String? ?? '';
    } catch (e) {
      error = e.toString();
    }
    if (mounted) {
      setState(() => busy = false);
    }
  }

  Future<void> createNewTargetFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const FolderNameDialog(),
    );
    if (name == null || name.isEmpty || name.contains('/')) {
      return;
    }
    try {
      if (!usingTargetSaf) {
        await Directory('$targetPosixPath/$name').create(recursive: true);
      } else if (targetSafUri != null) {
        await widget.core.createTargetFolder(
          targetSafUri!,
          name,
          documentId: safStack.isEmpty ? null : safStack.last,
        );
      }
      await loadTarget();
    } catch (e) {
      if (mounted) {
        setState(() => targetError = e.toString());
      }
    }
  }

  Future<void> pull(
    String path, {
    String? targetDirOverride,
    String? targetDocOverride,
    String? targetSubLabel,
    String? destinationOverride,
    bool skipConfirm = false,
    List<String> exclusions = const [],
  }) async {
    final name = path == '.' ? widget.root : path.split('/').last;
    final usingSaf = usingTargetSaf;
    if (targetPermissionMissing) {
      setState(() => error = 'Grant phone storage access before copying here.');
      return;
    }
    if (usingSaf && targetSafUri == null) {
      setState(() => error = 'Choose a SAF folder in the Target pane first.');
      return;
    }
    final destPosixDir = targetDirOverride ?? targetPosixPath;
    final destSafDoc =
        targetDocOverride ?? (safStack.isEmpty ? null : safStack.last);
    final baseSafLabel = 'SAF: ${targetSafName ?? 'selected folder'}';
    final targetLabel = usingSaf
        ? (targetSubLabel == null
              ? baseSafLabel
              : '$baseSafLabel/$targetSubLabel')
        : destPosixDir;
    var selectedExclusions = List<String>.from(exclusions);
    final isDirectory =
        path == sourcePath ||
        entries.any((e) => e['path'] == path && e['kind'] == 'directory');
    if (!skipConfirm) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('Pull $name?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Download a verified copy into:\n$targetLabel\n\nExisting files will not be overwritten. This does not enable synchronization.',
                ),
                if (isDirectory)
                  TextButton.icon(
                    icon: const Icon(Icons.filter_alt_outlined),
                    label: Text(
                      selectedExclusions.isEmpty
                          ? 'Exclude files or subfolders…'
                          : '${selectedExclusions.length} exclusions',
                    ),
                    onPressed: () async {
                      final result = await showDialog<List<String>>(
                        context: context,
                        builder: (_) => FolderExclusions(
                          initial: selectedExclusions,
                          load: (relative) async {
                            final location = relative.isEmpty
                                ? path
                                : path == '.'
                                ? relative
                                : '$path/$relative';
                            final page = await widget.core.run([
                              'list',
                              widget.peer['id'] as String,
                              widget.root,
                              location,
                              '',
                            ]) as Map;
                            return (page['entries'] as List)
                                .map((e) => Map<String, dynamic>.from(e as Map))
                                .toList();
                          },
                        ),
                      );
                      if (result != null && context.mounted) {
                        setDialogState(() => selectedExclusions = result);
                      }
                    },
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Pull'),
              ),
            ],
          ),
        ),
      );
      if (approved != true || !mounted) {
        return;
      }
    }
    setState(() {
      busy = true;
      pulling = true;
      error = null;
      interruptedPull = null;
      routeNotice = null;
      waitingForRoute = false;
      meteredApprovalId = null;
      liveProgress = null;
      receivedMiB = null;
      receivedMode = null;
      receivedTransport = null;
    });
    final cmd = preferredMethod == 'tar' ? 'pull-tar' : 'pull';
    final phoneStorageTarget = Platform.isAndroid && targetMode == 'local';
    final destination =
        destinationOverride ??
        ((usingSaf || phoneStorageTarget)
            ? '${widget.core.downloads}/$name-${DateTime.now().millisecondsSinceEpoch}'
            : '$destPosixDir/$name');
    var downloaded = false;
    try {
      final receipt = await widget.core.run([
        cmd,
        widget.peer['id'] as String,
        widget.root,
        path,
        destination,
        ...selectedExclusions,
      ]) as Map;
      downloaded = true;
      if (phoneStorageTarget) {
        await widget.core.localFiles('import', {
          'source_path': destination,
          'name': name,
          'target': {
            'kind': 'internal',
            'path': destPosixDir
                .replaceFirst('/storage/emulated/0', '')
                .replaceFirst(RegExp(r'^/'), ''),
          },
        });
        received = '$destPosixDir/$name';
      } else if (usingSaf && targetSafUri != null) {
        await widget.core.exportToTargetTree(
          destination,
          targetSafUri!,
          documentId: destSafDoc,
        );
        received = '${targetSubLabel ?? targetSafName ?? targetMode}/$name';
      } else {
        received = destination;
      }
      receivedMiB = (receipt['mib_per_second'] as num?)?.toDouble();
      receivedMode = receipt['mode'] as String?;
      receivedTransport =
          (receipt['transport'] as String?) ??
          (connectionConfig?['transport'] as String?) ??
          'lan';
      await loadActiveRoute();
      if (receivedTransport == 'adb' || receivedTransport == 'ssh') {
        resolvedRoute = {
          ...?resolvedRoute,
          'transport': receivedTransport,
          'endpoint':
              connectionConfig?[receivedTransport == 'adb'
                  ? 'adb_endpoint'
                  : 'ssh_endpoint'] ??
              '',
        };
      }
      await loadTarget();
    } catch (e) {
      error = choosingDownloadRoute ? null : e.toString();
      if (!downloaded) {
        interruptedPull = {
          'path': path,
          'name': name,
          'targetDir': destPosixDir,
          'targetDoc': destSafDoc,
          'targetLabel': targetLabel,
          'destination': destination,
          'targetMode': targetMode,
          'targetSafUri': targetSafUri,
          'excludes': selectedExclusions,
        };
      }
    }
    if (mounted) {
      setState(() {
        busy = false;
        pulling = false;
        liveProgress = null;
        waitingForRoute = false;
        meteredApprovalId = null;
      });
      if (choosingDownloadRoute) {
        choosingDownloadRoute = false;
        if (interruptedPull != null) {
          await continueInterrupted(chooseConnection: true);
        }
      }
    }
  }

  Future<void> approveMeteredDownload() async {
    final approval = meteredApprovalId;
    if (approval == null || approvingMetered || choosingDownloadRoute) return;
    setState(() => approvingMetered = true);
    try {
      await widget.core.allowMeteredPull(approval);
      if (mounted && meteredApprovalId == approval) {
        setState(() {
          meteredApprovalId = null;
          routeNotice = 'Connecting over Tailscale…';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => approvingMetered = false);
    }
  }

  Future<void> chooseDownloadConnection() async {
    if (!pulling || choosingDownloadRoute || approvingMetered) return;
    setState(() => choosingDownloadRoute = true);
    try {
      await widget.core.cancel();
    } catch (e) {
      if (mounted) {
        setState(() {
          choosingDownloadRoute = false;
          error = e.toString();
        });
      }
    }
  }

  Future<bool?> _openConnections({bool forDownload = false}) =>
      Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => DeviceDetail(
            core: widget.core,
            peer: widget.peer,
            registry: widget.registry,
            candidates: widget.candidates,
            forDownload: forDownload,
          ),
        ),
      );

  Future<void> continueInterrupted({bool chooseConnection = false}) async {
    final pending = interruptedPull;
    if (pending == null || busy) return;
    if (pending['targetMode'] != targetMode ||
        pending['targetSafUri'] != targetSafUri) {
      setState(
        () => error =
            'Select the original storage location to resume this download.',
      );
      return;
    }
    if (chooseConnection) {
      final confirmed = await _openConnections(forDownload: true);
      if (!mounted) return;
      await loadActiveRoute();
      if (confirmed != true || !mounted) return;
    }
    await pull(
      pending['path'] as String,
      targetDirOverride: pending['targetDir'] as String?,
      targetDocOverride: pending['targetDoc'] as String?,
      destinationOverride: pending['destination'] as String,
      skipConfirm: true,
      exclusions: List<String>.from(pending['excludes'] as List? ?? []),
    );
  }

  String metadata(Map<dynamic, dynamic> entry) {
    final bytes = (entry['size'] as num? ?? 0).toInt();
    final size = bytes < 1024
        ? '$bytes B'
        : bytes < 1024 * 1024
        ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
        : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    return size;
  }

  bool _visibleName(String name) {
    if (name.endsWith('.devicebridge-part')) {
      return showHidden;
    }
    if (!showHidden && name.startsWith('.')) {
      return false;
    }
    return true;
  }

  Widget _sourceRowTile(Map<dynamic, dynamic> e) {
    final map = Map<String, dynamic>.from(e);
    final isDir = map['kind'] == 'directory';
    final name = '${map['name']}';
    final rowContent = ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: isDir
          ? SyncedFolderIcon(
              activity: folderActivity(
                '${widget.peer['id']}',
                widget.root,
                '${e['path']}',
              ),
            )
          : const Icon(Icons.insert_drive_file_outlined, size: 18),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        isDir ? 'folder · hold to drag' : '${metadata(map)} · hold to drag',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      onTap: () {
        setState(() => activeSide = 'source');
        if (!busy && isDir) {
          sourcePath = map['path'] as String;
          loadSource();
        }
      },
      trailing: (isDir || map['kind'] == 'file')
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: ValueKey('pull-item-$name'),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  onPressed: busy ? null : () => pull(map['path'] as String),
                  icon: const Icon(Icons.download_outlined, size: 18),
                  tooltip: 'Pull to target',
                ),
                if (isDir)
                  PopupMenuButton<String>(
                    tooltip: 'Folder actions',
                    enabled: !busy,
                    onSelected: (_) =>
                        syncSourceFolder(map['path'] as String, name),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'sync', child: Text('Sync folder…')),
                    ],
                  ),
              ],
            )
          : null,
    );
    return LongPressDraggable<Map<String, dynamic>>(
      data: map,
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: Theme.of(context).colorScheme.primaryContainer,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isDir ? Icons.folder : Icons.insert_drive_file,
                size: 18,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              Text(
                name,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.45, child: rowContent),
      child: rowContent,
    );
  }

  String? folderActivity(
    String device,
    String root,
    String path, {
    bool native = false,
  }) {
    for (final pair in syncedPairs) {
      if (pair['state'] == 'draft') continue;
      for (final key in ['source', 'target']) {
        final location = pair[key] as Map;
        if (location['device'] == device &&
            (native
                ? location['local_path'] == path
                : location['root'] == root && location['path'] == path)) {
          return '${pair['state'] ?? 'paused'}';
        }
      }
    }
    if (native) {
      return syncedFolders
              .where((entry) => entry['source'] == path)
              .firstOrNull?['activity']
          as String?;
    }
    return null;
  }

  Widget sourcePane() {
    final visibleEntries = entries
        .where((e) => _visibleName('${e['name']}'))
        .toList();
    final isActive = activeSide == 'source';
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => setState(() => activeSide = 'source'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: isActive
                ? cs.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
            child: Row(
              children: [
                const Icon(Icons.devices, size: 16),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Source · ${widget.peer['name']} · ${widget.root}/$sourcePath',
                    style: Theme.of(context).textTheme.labelMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (sourcePath != '.')
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    tooltip: 'Source parent folder',
                    icon: const Icon(Icons.arrow_upward, size: 16),
                    onPressed: busy
                        ? null
                        : () {
                            final parts = sourcePath.split('/');
                            parts.removeLast();
                            sourcePath = parts.isEmpty ? '.' : parts.join('/');
                            loadSource();
                          },
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              children: [
                if (visibleEntries.isEmpty && !busy)
                  const ListTile(
                    dense: true,
                    title: Text('Folder empty', style: TextStyle(fontSize: 12)),
                  ),
                for (final e in visibleEntries) _sourceRowTile(e as Map),
                if (next.isNotEmpty)
                  TextButton(
                    onPressed: busy ? null : () => loadSource(more: true),
                    child: const Text('Load more'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _targetRowTile(Map<String, dynamic> e) {
    final isDir = e['kind'] == 'directory';
    final rowId =
        (e['document_id'] as String?) ??
        (e['path'] as String?) ??
        '${e['name']}';
    final isHovered = hoverTargetEntryId == rowId;
    final tile = Container(
      decoration: isHovered
          ? BoxDecoration(
              color: Theme.of(context).colorScheme.primary
                  .withValues(alpha: 0.18),
              border: Border.all(color: Theme.of(context).colorScheme.primary),
            )
          : null,
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        leading: isDir
            ? SyncedFolderIcon(
                activity: folderActivity(
                  'local',
                  'local',
                  '${e['path']}',
                  native: true,
                ),
              )
            : const Icon(Icons.insert_drive_file_outlined, size: 18),
        title: Text(
          '${e['name']}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
        subtitle: Text(
          e['kind'] == 'file' ? metadata(e) : 'folder',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11),
        ),
        trailing: isDir && !usingTargetSaf
            ? PopupMenuButton<String>(
                tooltip: 'Local folder actions',
                enabled: !targetBusy && !targetPermissionMissing,
                onSelected: (_) =>
                    syncTargetFolder('${e['path']}', '${e['name']}'),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'sync', child: Text('Sync folder…')),
                ],
              )
            : null,
        onTap: () {
          setState(() => activeSide = 'target');
          if (!isDir) {
            return;
          }
          if (usingTargetSaf) {
            safStack.add(e['document_id'] as String);
          } else {
            targetPosixPath = e['path'] as String;
          }
          loadTarget();
        },
      ),
    );
    if (!isDir) {
      return tile;
    }
    return DragTarget<Map<String, dynamic>>(
      onWillAcceptWithDetails: (_) {
        setState(() => hoverTargetEntryId = rowId);
        return !busy;
      },
      onLeave: (_) {
        if (hoverTargetEntryId == rowId) {
          setState(() => hoverTargetEntryId = null);
        }
      },
      onAcceptWithDetails: (details) {
        setState(() {
          hoverTargetEntryId = null;
          hoverTargetPane = false;
        });
        final remotePath = details.data['path'] as String?;
        if (remotePath == null || busy) {
          return;
        }
        if (usingTargetSaf) {
          pull(
            remotePath,
            targetDocOverride: e['document_id'] as String?,
            targetSubLabel: '${e['name']}',
          );
        } else {
          pull(remotePath, targetDirOverride: e['path'] as String?);
        }
      },
      builder: (_, _, _) => tile,
    );
  }

  Widget targetPane() {
    final visibleTargets = targetEntries
        .where((e) => _visibleName('${e['name']}'))
        .toList();
    final canGoUp =
        (targetMode == 'downloads' &&
            targetPosixPath != widget.core.downloads) ||
        (targetMode == 'termux_home' &&
            termuxHomePath != null &&
            targetPosixPath != termuxHomePath) ||
        (targetMode == 'local' &&
            targetPosixPath != widget.core.homeDir &&
            targetPosixPath != '/' &&
            (!Platform.isAndroid || targetPosixPath != '/storage/emulated/0'));
    final isActive = activeSide == 'target';
    final cs = Theme.of(context).colorScheme;

    return DragTarget<Map<String, dynamic>>(
      onWillAcceptWithDetails: (_) {
        setState(() => hoverTargetPane = true);
        return !busy;
      },
      onLeave: (_) => setState(() => hoverTargetPane = false),
      onAcceptWithDetails: (details) {
        setState(() => hoverTargetPane = false);
        final remotePath = details.data['path'] as String?;
        if (remotePath != null && !busy) {
          pull(remotePath);
        }
      },
      builder: (context, candidateData, rejectedData) => Container(
        decoration: hoverTargetPane || candidateData.isNotEmpty
            ? BoxDecoration(
                border: Border.all(color: cs.primary, width: 2),
                color: cs.primary.withValues(alpha: 0.06),
              )
            : null,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => setState(() => activeSide = 'target'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                color: isActive
                    ? cs.primary.withValues(alpha: 0.12)
                    : Colors.transparent,
                padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
                child: Row(
                  children: [
                    const Icon(Icons.save_alt, size: 16),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Target · ${targetMode == 'downloads'
                            ? 'Downloads'
                            : targetMode == 'termux_home'
                            ? 'Termux Home'
                            : Platform.isAndroid
                            ? 'Phone storage'
                            : 'Local'}',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (canGoUp)
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        tooltip: 'Target parent folder',
                        icon: const Icon(Icons.arrow_upward, size: 16),
                        onPressed: targetBusy
                            ? null
                            : () {
                                if (usingTargetSaf) {
                                  safStack.removeLast();
                                } else {
                                  targetPosixPath = Directory(targetPosixPath)
                                      .parent
                                      .path;
                                }
                                loadTarget();
                              },
                      ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      tooltip: 'New folder',
                      icon: const Icon(
                        Icons.create_new_folder_outlined,
                        size: 16,
                      ),
                      onPressed: targetBusy || targetPermissionMissing
                          ? null
                          : createNewTargetFolder,
                    ),
                    if (!usingTargetSaf)
                      IconButton(
                        tooltip: 'Sync target folder',
                        onPressed: targetBusy || targetPermissionMissing
                            ? null
                            : () => syncTargetFolder(
                                targetPosixPath,
                                Directory(targetPosixPath).uri.pathSegments
                                        .where((s) => s.isNotEmpty)
                                        .lastOrNull ??
                                    'Local folder',
                              ),
                        icon: const Icon(Icons.sync, size: 16),
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                  ],
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  children: [
                    if (!Platform.isAndroid) ...[
                      ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        label: const Text(
                          'Downloads',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: targetMode == 'downloads',
                        onSelected: (_) => switchTargetMode('downloads'),
                      ),
                      const SizedBox(width: 6),
                    ],
                    ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        Platform.isAndroid ? 'Phone storage' : 'Home',
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: targetMode == 'local',
                      onSelected: (_) => switchTargetMode('local'),
                    ),
                    if (Platform.isAndroid) ...[
                      const SizedBox(width: 6),
                      ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        label: const Text(
                          'Termux Home',
                          style: TextStyle(fontSize: 11),
                        ),
                        selected: targetMode == 'termux_home',
                        onSelected: (_) => switchTargetMode('termux_home'),
                      ),
                    ],
                  ],
                ),
              ),
              if (Platform.isAndroid && !allFilesAccess)
                TextButton.icon(
                  onPressed: () =>
                      widget.core.openConnectionSetup('all_files_access'),
                  icon: const Icon(Icons.sd_storage_outlined, size: 16),
                  label: const Text(
                    'Phone storage access',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              if (targetPermissionMissing)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Allow phone storage access to browse and save here.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              if (targetBusy) const LinearProgressIndicator(),
              if (candidateData.isNotEmpty)
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Drop to pull into ${targetMode == 'downloads'
                        ? 'Downloads'
                        : targetMode == 'termux_home'
                        ? 'Termux Home'
                        : 'Phone storage'}',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              if (targetError != null)
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    targetError!,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              if (usingTargetSaf && targetSafUri == null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: OutlinedButton.icon(
                    onPressed: pickTargetFolder,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text(
                      'Choose target folder',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                )
              else
                Expanded(
                  child: ListView(
                    children: [
                      if (visibleTargets.isEmpty && !targetBusy)
                        const ListTile(
                          dense: true,
                          title: Text(
                            'Target folder empty · drag Source item here',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      for (final e in visibleTargets) _targetRowTile(e),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final liveMethodRaw = (liveProgress?['method'] as String?) ?? '';
    final liveMethodLabel = liveMethodRaw.isNotEmpty
        ? liveMethodRaw.toUpperCase()
        : (preferredMethod == 'tar' ? 'TAR' : 'AUTO');
    final liveViaRaw = (liveProgress?['transport'] as String?) ?? '';
    final liveViaLabel = liveViaRaw.isNotEmpty
        ? connectionDisplayName(liveViaRaw)
        : connectionDisplayName(
            (resolvedRoute?['transport'] as String?) ??
                (connectionConfig?['transport'] as String?) ??
                'lan',
          );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          sourcePath == '.' ? widget.root : sourcePath.split('/').last,
        ),
        actions: [
          if (Platform.isAndroid)
            IconButton(
              tooltip: 'Choose devices and storage',
              icon: const Icon(Icons.view_week_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => FileManager(
                    core: widget.core,
                    remotePeer: widget.peer,
                    remoteRoot: widget.root,
                    candidates: widget.candidates,
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: showHidden ? 'Hide hidden files' : 'Show hidden files',
            icon: Icon(
              showHidden ? Icons.visibility : Icons.visibility_off_outlined,
            ),
            onPressed: () async {
              setState(() => showHidden = !showHidden);
              await widget.core.appSettings(
                update: {'show_hidden': showHidden},
              );
            },
          ),
          IconButton(
            onPressed: busy ? null : () => pull(sourcePath),
            icon: const Icon(Icons.download),
            tooltip: 'Pull this folder',
          ),
          IconButton(
            tooltip: 'Sync this folder',
            onPressed: busy
                ? null
                : () => syncSourceFolder(
                    sourcePath,
                    sourcePath
                            .split('/')
                            .where((s) => s.isNotEmpty && s != '.')
                            .lastOrNull ??
                        widget.root,
                  ),
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.settings_ethernet, size: 15),
                  label: Text(
                    activeConnectionSummary(),
                    style: const TextStyle(fontSize: 12),
                  ),
                  onPressed: busy
                      ? null
                      : () async {
                          await _openConnections();
                          if (mounted) await loadActiveRoute();
                        },
                ),
                ChoiceChip(
                  visualDensity: VisualDensity.compact,
                  label: const Text(
                    'Auto (TAR/Direct)',
                    style: TextStyle(fontSize: 11),
                  ),
                  selected: preferredMethod == 'auto',
                  onSelected: busy
                      ? null
                      : (_) => setState(() => preferredMethod = 'auto'),
                ),
                ChoiceChip(
                  visualDensity: VisualDensity.compact,
                  label: const Text(
                    'Force TAR',
                    style: TextStyle(fontSize: 11),
                  ),
                  selected: preferredMethod == 'tar',
                  onSelected: busy
                      ? null
                      : (_) => setState(() => preferredMethod = 'tar'),
                ),
              ],
            ),
          ),
          if (busy)
            LinearProgressIndicator(
              value:
                  liveProgress != null &&
                      ((liveProgress!['total_bytes'] as num? ?? 0) > 0)
                  ? ((liveProgress!['verified_bytes'] as num? ?? 0) /
                            (liveProgress!['total_bytes'] as num))
                        .clamp(0.0, 1.0)
                  : null,
            ),
          if (busy && routeNotice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
              child: Text(
                routeNotice!,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (pulling && waitingForRoute)
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                if (meteredApprovalId != null)
                  FilledButton(
                    onPressed: approvingMetered || choosingDownloadRoute
                        ? null
                        : approveMeteredDownload,
                    child: const Text('Use data for this download'),
                  ),
                OutlinedButton(
                  onPressed: approvingMetered || choosingDownloadRoute
                      ? null
                      : chooseDownloadConnection,
                  child: const Text('Choose another connection'),
                ),
              ],
            ),
          if (busy && liveProgress != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                '${(((liveProgress!['verified_bytes'] as num? ?? 0)) / (1024 * 1024)).toStringAsFixed(1)} / ${(((liveProgress!['total_bytes'] as num? ?? 0)) / (1024 * 1024)).toStringAsFixed(1)} MiB${waitingForRoute ? '' : ' · ${((liveProgress!['mib_per_second'] as num? ?? 0)).toStringAsFixed(2)} MiB/s · Method: $liveMethodLabel · Via: $liveViaLabel · ${liveProgress!['file'] ?? ''}'}',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (busy)
            TextButton(
              onPressed: widget.core.cancel,
              child: const Text('Cancel operation'),
            ),
          if (interruptedPull != null)
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Resume downloading "${interruptedPull!['name']}"',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        OutlinedButton.icon(
                          onPressed: busy ? null : () => continueInterrupted(),
                          icon: const Icon(Icons.refresh, size: 15),
                          label: const Text('Resume'),
                        ),
                        OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () =>
                                    continueInterrupted(chooseConnection: true),
                          icon: const Icon(Icons.alt_route, size: 15),
                          label: const Text('Choose a connection'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: SelectableText(
                error!,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (received != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                children: [
                  Text(
                    'Verified download${receivedMode == 'tar'
                        ? ' (streaming tar)'
                        : receivedMode == 'stream'
                        ? ' (TCP stream)'
                        : ' (direct)'}\n${received!.split('/').last}\nVia ${connectionDisplayName(receivedTransport ?? 'lan')}${receivedMiB != null && receivedMiB! > 0 ? ' · ${receivedMiB!.toStringAsFixed(2)} MiB/s' : ''}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (targetMode == 'downloads')
                    TextButton(
                      onPressed: () async {
                        try {
                          final saved = await widget.core.saveDownload(
                            received!,
                          );
                          if (saved != null && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Copy saved to your selected destination',
                                ),
                              ),
                            );
                          }
                        } catch (e) {
                          if (mounted) {
                            setState(() => error = e.toString());
                          }
                        }
                      },
                      child: const Text('Save a copy…'),
                    ),
                ],
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: Row(
              children: [
                Expanded(child: sourcePane()),
                const VerticalDivider(width: 2, thickness: 1.5),
                Expanded(child: targetPane()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChannelPickerDialog extends StatefulWidget {
  const _ChannelPickerDialog({
    required this.initialChannel,
    required this.initialBandwidthMhz,
    required this.presets,
    required this.autoHighestChannel,
    required this.regCountry,
    required this.regLimited,
  });

  final int? initialChannel;
  final int initialBandwidthMhz;
  final List<int> presets;
  final int autoHighestChannel;
  final String regCountry;
  final bool regLimited;

  @override
  State<_ChannelPickerDialog> createState() => _ChannelPickerDialogState();
}

class _ChannelPickerDialogState extends State<_ChannelPickerDialog> {
  late int? draftCh = widget.initialChannel;
  late int draftBw = widget.initialBandwidthMhz;
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initialChannel != null ? '${widget.initialChannel}' : '',
  );
  String? inputErr;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _applyCustomText(String raw) {
    final t = raw.trim();
    if (t.isEmpty) {
      setState(() {
        draftCh = null;
        inputErr = null;
      });
      return;
    }
    final numVal = int.tryParse(t);
    if (numVal == null) {
      setState(() => inputErr = 'Enter a channel (1–177) or MHz (2412–7115)');
      return;
    }
    int? resolvedCh;
    if (numVal >= 2400 && numVal <= 7125) {
      final c = _DeviceDetailState.freqToChannel(numVal);
      if (c > 0 && _DeviceDetailState.channelToFreq(c) == numVal) {
        resolvedCh = c;
      }
    } else if (_DeviceDetailState.channelToFreq(numVal) > 0) {
      resolvedCh = numVal;
    }
    if (resolvedCh == null) {
      setState(() => inputErr = 'Unsupported Wi-Fi channel/frequency');
      return;
    }
    setState(() {
      draftCh = resolvedCh;
      inputErr = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final autoLabel = widget.autoHighestChannel > 0
        ? 'Auto (Highest · Ch ${widget.autoHighestChannel})'
        : 'Auto (Highest)';
    return AlertDialog(
      title: const Text('Direct link channel & width'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Channel selection',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  label: Text(autoLabel),
                  selected: draftCh == null,
                  onSelected: (_) => setState(() {
                    draftCh = null;
                    _ctrl.clear();
                    inputErr = null;
                  }),
                ),
                for (final ch in widget.presets)
                  ChoiceChip(
                    label: Text(
                      ch == 165
                          ? 'Ch 165 (${_DeviceDetailState.channelToFreq(ch)} MHz · 20MHz)'
                          : 'Ch $ch (${_DeviceDetailState.channelToFreq(ch)} MHz)',
                    ),
                    selected: draftCh == ch,
                    onSelected: (_) => setState(() {
                      draftCh = ch;
                      _ctrl.text = '$ch';
                      inputErr = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ctrl,
              keyboardType: TextInputType.number,
              onChanged: _applyCustomText,
              decoration: InputDecoration(
                labelText: 'Custom channel or MHz (blank = Auto Highest)',
                hintText: 'e.g. 161 or 5805',
                errorText: inputErr,
                helperText: draftCh != null
                    ? 'Selected: Ch $draftCh (${_DeviceDetailState.channelToFreq(draftCh!)} MHz)'
                    : 'Defaults to highest 80 MHz-capable 5 GHz channel',
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Channel width (Root / Shizuku)',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final bw in const [0, 160, 80, 40])
                  ChoiceChip(
                    label: Text(bw == 0 ? 'Auto (160→80 MHz)' : '$bw MHz'),
                    selected: draftBw == bw,
                    onSelected: (_) => setState(() => draftBw = bw),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'UNII-3 (Ch 149–161) tops out at 80 MHz (~867–1201 Mbps PHY). '
              '160 MHz requires UNII-1/2 (Ch 36–128) + hardware 160 MHz support.'
              '${widget.regLimited ? '\nLinux regdom${widget.regCountry.isNotEmpty ? ' ${widget.regCountry}' : ''}: Ch 36–144 disabled (run "sudo iw reg set US" on laptop to unlock).' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: inputErr != null
              ? null
              : () => Navigator.pop(context, (
                  channel: draftCh,
                  bandwidthMhz: draftBw,
                )),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
