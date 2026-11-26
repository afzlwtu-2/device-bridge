import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'core/bridge.dart';
import 'core/debug_trace.dart';
import 'features/registry.dart';
import 'features/remote_files.dart';
import 'features/device_addresses.dart';
import 'features/incoming_pair.dart';
import 'features/pair_dialog.dart';
import 'features/connections_hub.dart';
import 'features/home_dashboard.dart';
import 'features/appearance.dart';
import 'features/amoled_editor.dart';
import 'features/matte_editor.dart';
import 'features/settings_screen.dart';
import 'features/app_updates.dart';
import 'features/acl_screen.dart';
import 'features/phone_files.dart';
import 'features/permission_wizard.dart';
import 'features/quick_share.dart';
import 'features/ssh_bootstrap.dart';
import 'features/ssh_hosts.dart';
import 'features/local_terminal.dart';

void main() {
  if (kDebugMode) {
    enableFlutterDriverExtension();
  }
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final prevFlutterErr = FlutterError.onError;
  FlutterError.onError = (details) {
    DebugTrace.logError(
      'FlutterError',
      details.exceptionAsString(),
      error: details.stack,
    );
    if (prevFlutterErr != null) {
      prevFlutterErr(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  PlatformDispatcher.instance.onError = (err, stack) {
    DebugTrace.logError('Uncaught', '$err', error: stack);
    return false;
  };
  binding.deferFirstFrame();
  runApp(
    DeviceBridgeApp(
      core: LocalCore(),
      onAppearanceReady: binding.allowFirstFrame,
    ),
  );
}

class DeviceBridgeApp extends StatefulWidget {
  const DeviceBridgeApp({
    super.key,
    required this.core,
    this.onAppearanceReady,
  });
  final CoreBridge core;
  final VoidCallback? onAppearanceReady;
  @override
  State<DeviceBridgeApp> createState() => _DeviceBridgeAppState();
}

class _DeviceBridgeAppState extends State<DeviceBridgeApp> {
  String appearance = 'system';
  List<MatteArtItem> matteItems = defaultMatteItems();
  AmoledStyleConfig amoledConfig = AmoledStyleConfig.defaults();
  bool _appearanceReady = false;
  final _homeKey = GlobalKey<_BridgeHomeState>();

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(_loadAppearance());
  }

  Future<void> _loadAppearance() async {
    final core = widget.core;
    try {
      if (core is LocalCore) await core.prepare();
      try {
        final saved = await core.run(['theme']) as Map;
        appearance = saved['theme'] as String? ?? 'system';
      } catch (e) {
        DebugTrace.logCore('Appearance', 'Saved theme unavailable: $e');
      }
      final values = await (core is LocalCore
          ? core.startupSettings()
          : core.appSettings());
      if (values.containsKey('debug_mode')) {
        DebugTrace.setEnabled(values['debug_mode'] != false);
      }
      final rawMatte = values['matte_items'] as String?;
      if (rawMatte != null && rawMatte.isNotEmpty) {
        matteItems = decodeMatteItems(rawMatte);
      }
      amoledConfig = decodeAmoledConfig(
        values['amoled_config'] as String?,
        appearance: appearance,
      );
    } catch (e) {
      DebugTrace.logError(
        'Appearance',
        'Startup settings unavailable',
        error: e,
      );
    } finally {
      if (mounted) setState(() => _appearanceReady = true);
      widget.onAppearanceReady?.call();
    }
  }

  ThemeData get dark {
    if (isAmoledTheme(appearance)) {
      return amoledTheme(appearance, config: amoledConfig);
    }
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff41c6b5),
      brightness: Brightness.dark,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xff101615),
      useMaterial3: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_appearanceReady) return const SizedBox.shrink();
    return MaterialApp(
      title: 'DeviceBridge',
      debugShowCheckedModeBanner: false,
      navigatorObservers: [DebugNavigatorObserver()],
      themeAnimationDuration: Duration.zero,
      theme: appearance == 'matte'
          ? mattePaperTheme()
          : ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xff176b62),
              ),
              scaffoldBackgroundColor: const Color(0xfff4f7f6),
              useMaterial3: true,
            ),
      darkTheme: dark,
      builder: (context, child) => AppearanceSurface(
        appearance: appearance,
        matteItems: matteItems,
        amoledConfig: amoledConfig,
        child: TerminalWorkspaceScope(
          openRemote: (target) => _homeKey.currentState?._openRemoteTerminal(target),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
      themeMode: appearance == 'system'
          ? ThemeMode.system
          : appearance == 'light' || appearance == 'matte'
          ? ThemeMode.light
          : ThemeMode.dark,
      home: BridgeHome(
        key: _homeKey,
        core: widget.core,
        appearance: appearance,
        matteItems: matteItems,
        amoledConfig: amoledConfig,
        onAppearance: (value) {
          if (mounted) {
            setState(() => appearance = value);
          }
        },
        onMatteItems: (items) {
          if (mounted) {
            setState(() => matteItems = items);
          }
        },
        onAmoledConfig: (cfg) {
          if (mounted) {
            setState(() => amoledConfig = cfg);
          }
        },
      ),
    );
  }
}

class BridgeHome extends StatefulWidget {
  const BridgeHome({
    super.key,
    required this.core,
    required this.appearance,
    required this.matteItems,
    required this.amoledConfig,
    required this.onAppearance,
    required this.onMatteItems,
    required this.onAmoledConfig,
  });
  final CoreBridge core;
  final String appearance;
  final List<MatteArtItem> matteItems;
  final AmoledStyleConfig amoledConfig;
  final ValueChanged<String> onAppearance;
  final ValueChanged<List<MatteArtItem>> onMatteItems;
  final ValueChanged<AmoledStyleConfig> onAmoledConfig;
  @override
  State<BridgeHome> createState() => _BridgeHomeState();
}

class _HomeSnapshot {
  Map<String, dynamic>? identity;
  Map<String, dynamic>? capabilities;
  List<dynamic> peers = [];
  List<dynamic> candidates = [];
}

class _BridgeHomeState extends State<BridgeHome> {
  static final Expando<_HomeSnapshot> _homeCache = Expando<_HomeSnapshot>(
    'homeCache',
  );
  int tab = 0;
  int _devicesTab = 0;
  bool _terminalOpen = false;
  bool _terminalVisited = false;
  String? _terminalPeerName;
  TerminalKeyboardConfig _terminalConfig = const TerminalKeyboardConfig();
  TerminalSystemStats _terminalStats = const TerminalSystemStats();
  final GlobalKey<LocalTerminalScreenState> _terminalKey =
      GlobalKey<LocalTerminalScreenState>();
  bool busy = false;
  bool _openingThemeEditor = false;
  String? error;
  List<dynamic> peers = [], candidates = [];
  Map<String, dynamic>? identity, capabilities;
  StreamSubscription<Map<String, dynamic>>? networkEvents;
  StreamSubscription<void>? _sharedDraftEvents;
  Map<String, dynamic>? _sharedDraft;
  String? listenerState;
  Timer? networkRefresh;
  Timer? invitationRefresh;
  Timer? incomingPairingExpiry;
  bool checkingInvitations = false;
  Timer? pairingCompletion;
  bool checkingPairingCompletion = false;
  Map<String, dynamic>? _permissionsStatus;
  bool _permissionWizardChecked = false;
  final pairingDeadlines = <String, DateTime>{};
  final registry = FeatureRegistry()..register(RemoteFilesFeature());
  @override
  void initState() {
    super.initState();
    final cached = _homeCache[widget.core];
    if (cached != null) {
      identity = cached.identity;
      capabilities = cached.capabilities;
      peers = cached.peers;
      candidates = cached.candidates;
      _pruneIncomingPairingRequests();
    }
    unawaited(initialize());
    if (widget.core case final LocalCore local) {
      if (Platform.isAndroid) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(AppUpdates.check(context));
        });
      }
      _sharedDraftEvents = local.sharedDraftEvents.listen(
        (_) async {
          final draft = await local.takeSharedDraft();
          if (!mounted || draft == null) return;
          if (ModalRoute.of(context)?.isCurrent == false) {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Quick Share')),
                  body: QuickShare(
                    core: local,
                    peers: peers,
                    sharedDraft: draft,
                  ),
                ),
              ),
            );
            return;
          }
          setState(() {
            _sharedDraft = draft;
            tab = 2;
          });
        },
        onError: (Object error) {
          DebugTrace.logCore('Share', 'Unable to read shared draft: $error');
        },
      );
    }
  }

  void _saveHomeCache() {
    final snap =
        _homeCache[widget.core] ?? (_homeCache[widget.core] = _HomeSnapshot());
    snap.identity = identity;
    snap.capabilities = capabilities;
    snap.peers = peers;
    snap.candidates = candidates;
  }

  Future<void> initialize() async {
    networkEvents = widget.core.networkEvents.listen((event) {
      if (!mounted) {
        return;
      }
      if (event['tailnet_network_changed'] == true ||
          event['usb_state_changed'] == true) {
        return;
      }
      candidates = [];
      setState(() => listenerState = event['state'] as String?);
      networkRefresh?.cancel();
      if (event['state'] == 'active') {
        networkRefresh = Timer(const Duration(milliseconds: 250), () {
          if (mounted) {
            unawaited(_refreshLanCandidates());
          }
        });
      }
    });
    try {
      await widget.core.initialize();
      await Future.wait([
        () async {
          identity = Map<String, dynamic>.from(
            await widget.core.run(['identity']) as Map,
          );
          if (mounted) {
            setState(() {});
          }
        }(),
        () async {
          try {
            capabilities = await widget.core.platformCapabilities();
          } catch (e) {
            DebugTrace.logCore('Home', 'platformCapabilities failed: $e');
          }
        }(),
        refreshPeers(),
      ]);
      _saveHomeCache();
      DebugTrace.logFlow(
        'Home',
        'Initialized (${peers.length} peers, id=${_shortFingerprint(identity?['id'] as String?)})',
      );
      if (mounted) {
        setState(() {});
      }
      if (tab == 1) {
        unawaited(_refreshLanCandidates());
      }
      if (Platform.isAndroid && widget.core is LocalCore) {
        unawaited(_refreshPermissions(autoGrant: true, promptWizard: true));
      }
    } catch (e) {
      DebugTrace.logError('Home', 'Initialize failed', error: e);
      if (mounted) {
        setState(() => error = e.toString());
      }
    }
  }

  @override
  void dispose() {
    networkEvents?.cancel();
    unawaited(_sharedDraftEvents?.cancel());
    networkRefresh?.cancel();
    invitationRefresh?.cancel();
    incomingPairingExpiry?.cancel();
    pairingCompletion?.cancel();
    widget.core.shutdown();
    super.dispose();
  }

  List<Map<String, dynamic>> sshHosts = [];

  Future<void> refreshPeers() async {
    try {
      final raw = await widget.core.run(['ssh-hosts']);
      if (raw is List) {
        sshHosts = raw
            .whereType<Map>()
            .map((h) => Map<String, dynamic>.from(h))
            .toList();
      }
    } catch (_) {
      /* Older cores keep existing paired devices usable. */
    }
    peers = await widget.core.run(['peers']) as List;
    if (!mounted) return;
    _pruneIncomingPairingRequests();
    final outbound = {
      for (final peer in peers)
        if (peer['status'] == 'outbound') peer['id'] as String,
    };
    pairingDeadlines.removeWhere((id, _) => !outbound.contains(id));
    for (final id in outbound) {
      pairingDeadlines.putIfAbsent(
        id,
        () => DateTime.now().add(const Duration(minutes: 5)),
      );
    }
    _schedulePairingCompletion();
  }

  void _pruneIncomingPairingRequests() {
    incomingPairingExpiry?.cancel();
    final now = DateTime.now();
    DateTime? nextExpiry;
    final livePeers = <dynamic>[];
    for (final peer in peers) {
      final expires = peer['expires'];
      if (peer['status'] == 'pending' && expires is int) {
        final expiry = DateTime.fromMillisecondsSinceEpoch(expires * 1000);
        if (!expiry.isAfter(now)) continue;
        if (nextExpiry == null || expiry.isBefore(nextExpiry)) {
          nextExpiry = expiry;
        }
      }
      livePeers.add(peer);
    }
    peers = livePeers;
    if (nextExpiry != null) {
      incomingPairingExpiry = Timer(nextExpiry.difference(now), () {
        if (mounted) setState(_pruneIncomingPairingRequests);
      });
    }
  }

  void _schedulePairingCompletion() {
    if (!mounted ||
        checkingPairingCompletion ||
        pairingCompletion?.isActive == true) {
      return;
    }
    final now = DateTime.now();
    if (!pairingDeadlines.values.any(now.isBefore)) return;
    pairingCompletion = Timer(const Duration(seconds: 3), () async {
      if (!mounted) return;
      if (!busy &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        checkingPairingCompletion = true;
        try {
          final now = DateTime.now();
          final pending = pairingDeadlines.entries
              .where((entry) => now.isBefore(entry.value))
              .map((entry) => entry.key)
              .toList();
          for (final id in pending) {
            if (!mounted || busy) break;
            try {
              await _finishInvitation(id);
            } catch (_) {
              // Approval may still be pending or the other device offline.
            }
          }
          if (mounted) setState(() {});
        } finally {
          checkingPairingCompletion = false;
        }
      }
      _schedulePairingCompletion();
    });
  }

  bool _isWaitingForApproval(String id) =>
      pairingDeadlines[id]?.isAfter(DateTime.now()) == true;

  Future<void> task(Future<void> Function() action) async {
    if (mounted) {
      setState(() {
        busy = true;
        error = null;
      });
    }
    try {
      await action();
    } catch (e) {
      DebugTrace.logError('Home', 'Action failed', error: e);
      if (mounted) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _refreshLanCandidates() async {
    final network = widget.core.network;
    if (network == null) return;
    try {
      final found = (await widget.core.run(['discover']) as List)
          .where((v) => v['device_id'] != identity?['id'])
          .toList();
      final current = widget.core.network;
      if (mounted &&
          current?['cidr'] == network['cidr'] &&
          current?['interface'] == network['interface'] &&
          current?['network_handle'] == network['network_handle']) {
        setState(() => candidates = found);
      }
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _loadTailnetSshTargets() async {
    try {
      final raw = await widget.core.run([
        'discover-ssh',
        '-',
      ], input: jsonEncode({'tailnet_only': true, 'include_paired_tailnet': true}));
      return (raw as List? ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .where((t) => t['source'] == 'tailnet' && t['ssh_enabled'] == true)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _createInvitation() async {
    Map<String, dynamic>? response;
    await task(() async {
      response = Map<String, dynamic>.from(
        await widget.core.run(['invite']) as Map,
      );
    });
    final invitation = response;
    if (invitation == null || !mounted) return;
    final expires = DateTime.parse(invitation['expires'] as String);
    final pending = {
      for (final peer in peers)
        if (peer['status'] == 'pending') peer['id']: peer['expires'],
    };
    invitationRefresh?.cancel();
    invitationRefresh = Timer.periodic(const Duration(seconds: 2), (
      timer,
    ) async {
      if (!mounted || !DateTime.now().isBefore(expires)) {
        timer.cancel();
        return;
      }
      if (tab != 1 ||
          busy ||
          checkingInvitations ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      checkingInvitations = true;
      try {
        await refreshPeers();
        if (peers.any(
          (peer) =>
              peer['status'] == 'pending' &&
              (!pending.containsKey(peer['id']) ||
                  pending[peer['id']] != peer['expires']),
        )) {
          timer.cancel();
        }
        if (mounted) setState(() {});
      } catch (_) {
        // The user can refresh the list from Devices.
      } finally {
        checkingInvitations = false;
      }
    });
    await showDialog<void>(
      context: context,
      builder: (_) => SharePairInvitationDialog(
        invitation: jsonEncode(invitation),
        fingerprint: invitation['id'] as String,
      ),
    );
    if (mounted) await task(refreshPeers);
  }

  Future<void> _pairWithInvitation({String? peerId, String? peerName}) async {
    var tailnetPeers = <Map<String, dynamic>>[];
    try {
      final status = await widget.core.run(['tailnet', 'status']) as Map;
      tailnetPeers = (status['peers'] as List? ?? const [])
          .whereType<Map>()
          .map((peer) => Map<String, dynamic>.from(peer))
          .where((peer) => peer['online'] == true)
          .toList();
    } catch (_) {}
    if (!mounted) return;
    final invitation = await showDialog<PairInvitationResult>(
      context: context,
      builder: (_) =>
          PairInvitationDialog(tailnetPeers: tailnetPeers, peerName: peerName),
    );
    if (invitation == null || !mounted) return;
    final code = invitation.invite.trim();
    final route = invitation.tailnetEndpoint;
    final value = decodePairInvitation(code);
    if (value == null) {
      setState(() => error = 'Enter a valid DeviceBridge invitation code.');
      return;
    }
    if (!DateTime.now().isBefore(DateTime.parse(value['expires'] as String))) {
      setState(
        () => error =
            'This invitation expired. Create a fresh one on the other device.',
      );
      return;
    }
    final id = value['id'] as String;
    if (peerId != null && peerId != id) {
      setState(() => error = 'This invitation belongs to a different device.');
      return;
    }
    if (id == identity?['id']) {
      setState(() => error = 'Use this invitation on the other device.');
      return;
    }
    final authorized = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Pair with ${value['name']}?'),
        content: SelectableText(
          [
            'Verify this fingerprint on the inviting device.',
            id,
            if (identity?['id'] case final String localId)
              'Your fingerprint for their approval\n$localId',
            if (route != null) 'Send this pairing request over Tailscale.',
            'The inviting device must also approve your request.',
          ].join('\n\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Fingerprint matches'),
          ),
        ],
      ),
    );
    if (authorized != true || !mounted) return;
    await task(() async {
      await widget.core.run([
        if (route != null) ...[
          '--transport',
          'tailnet',
          '--endpoint',
          route,
          '--approve-remote',
        ],
        'pair',
        '-',
      ], input: code);
      pairingDeadlines.remove(id);
      await refreshPeers();
    });
  }

  Future<void> _finishInvitation(String id) async {
    final connection = await widget.core.run(['connection', id]) as Map;
    final endpoint = connection['tailnet_endpoint'] as String? ?? '';
    await widget.core.run([
      if (endpoint.isNotEmpty) ...[
        '--transport',
        'tailnet',
        '--endpoint',
        endpoint,
        '--approve-remote',
      ],
      'finish',
      id,
    ]);
    await refreshPeers();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_terminalOpen,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _terminalOpen) {
        setState(() => _terminalOpen = false);
      }
    },
    child: Scaffold(
      appBar: AppBar(
        leading: _terminalOpen
            ? IconButton(
                tooltip: 'Back',
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _terminalOpen = false),
              )
            : null,
        title: _terminalOpen
            ? InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _terminalKey.currentState?.openTerminalSettings(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.terminal_outlined),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          _terminalPeerName ?? 'Termux',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : Row(
                children: [
                  const Icon(Icons.hub_outlined),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      ['DeviceBridge', 'Devices', 'Share'][tab.clamp(0, 2)],
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
        actions: _terminalOpen
            ? [
                if ((_terminalConfig.showCpuUsage &&
                        _terminalStats.cpuAvailable) ||
                    (_terminalConfig.showRamUsage &&
                        _terminalStats.ramAvailable) ||
                    (_terminalConfig.showGpuUsage &&
                        _terminalStats.gpuAvailable))
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () =>
                          _terminalKey.currentState?.openTerminalSettings(),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_terminalConfig.showCpuUsage &&
                              _terminalStats.cpuAvailable)
                            _buildStatBadge(
                              context,
                              'CPU',
                              '${_terminalStats.cpuPercent}%',
                              Theme.of(context).colorScheme.primary,
                              icon: Icons.memory,
                            ),
                          if (_terminalConfig.showRamUsage &&
                              _terminalStats.ramAvailable) ...[
                            if (_terminalConfig.showCpuUsage &&
                                _terminalStats.cpuAvailable)
                              const SizedBox(width: 5),
                            _buildStatBadge(
                              context,
                              'RAM',
                              '${_terminalStats.ramPercent}%',
                              Theme.of(context).colorScheme.secondary,
                            ),
                          ],
                          if (_terminalConfig.showGpuUsage &&
                              _terminalStats.gpuAvailable) ...[
                            if ((_terminalConfig.showCpuUsage &&
                                    _terminalStats.cpuAvailable) ||
                                (_terminalConfig.showRamUsage &&
                                    _terminalStats.ramAvailable))
                              const SizedBox(width: 5),
                            _buildStatBadge(
                              context,
                              'GPU',
                              '${_terminalStats.gpuPercent}%',
                              Theme.of(context).colorScheme.tertiary,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ]
            : [
                IconButton(
                  key: const ValueKey('top-settings-button'),
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsScreen(core: widget.core),
                      ),
                    );
                    if (mounted && Platform.isAndroid && widget.core is LocalCore) {
                      unawaited(_refreshPermissions(autoGrant: false));
                    }
                  },
                ),
                PopupMenuButton<String>(
                  tooltip: 'Appearance',
                  icon: const Icon(Icons.brightness_6_outlined),
                  onSelected: (value) async {
                    if (_openingThemeEditor) {
                      return;
                    }
                    widget.onAppearance(value);
                    unawaited(() async {
                      try {
                        await widget.core.run(['theme', value]);
                      } catch (_) {}
                    }());
                    if (value == 'matte') {
                      _openingThemeEditor = true;
                      try {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => MatteThemeEditor(
                              initialItems: widget.matteItems,
                              onSave: (items) async {
                                widget.onMatteItems(items);
                                unawaited(() async {
                                  try {
                                    await widget.core.appSettings(
                                      update: {
                                        'matte_items': encodeMatteItems(items),
                                      },
                                    );
                                  } catch (_) {}
                                }());
                              },
                            ),
                          ),
                        );
                      } finally {
                        _openingThemeEditor = false;
                      }
                      return;
                    }
                    if (value == 'amoled') {
                      _openingThemeEditor = true;
                      try {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => AmoledThemeEditor(
                              initialConfig: widget.amoledConfig,
                              onSave: (cfg) async {
                                widget.onAmoledConfig(cfg);
                                unawaited(() async {
                                  try {
                                    await widget.core.appSettings(
                                      update: {
                                        'amoled_config': encodeAmoledConfig(
                                          cfg,
                                        ),
                                      },
                                    );
                                  } catch (_) {}
                                }());
                              },
                            ),
                          ),
                        );
                      } finally {
                        _openingThemeEditor = false;
                      }
                      return;
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'system', child: Text('System theme')),
                    PopupMenuItem(value: 'light', child: Text('Light')),
                    PopupMenuItem(value: 'dark', child: Text('Dark')),
                    PopupMenuItem(value: 'amoled', child: Text('AMOLED')),
                    PopupMenuItem(value: 'matte', child: Text('Matte')),
                  ],
                ),
                IconButton(
                  key: const ValueKey('top-networks-button'),
                  onPressed: busy ? null : _openConnections,
                  icon: const Icon(Icons.wifi),
                  tooltip: 'Networks',
                ),
              ],
      ),
      body: SafeArea(
        top: true,
        bottom: _terminalOpen,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              children: [
                if (busy) const LinearProgressIndicator(),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: MaterialBanner(
                      content: SelectableText(error!),
                      actions: [
                        TextButton(
                          onPressed: () => setState(() => error = null),
                          child: const Text('Dismiss'),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!_terminalOpen)
                        switch (tab) {
                          0 => home(),
                          1 => devices(),
                          _ => QuickShare(
                            core: widget.core,
                            peers: peers,
                            sharedDraft: _sharedDraft,
                            onDraftAccepted: (draft) {
                              if (mounted && identical(_sharedDraft, draft)) {
                                setState(() => _sharedDraft = null);
                              }
                            },
                          ),
                        },
                      if (_terminalVisited || _terminalOpen)
                        Offstage(
                          offstage: !_terminalOpen,
                          child: TickerMode(
                            enabled: _terminalOpen,
                            child: LocalTerminalScreen(
                              key: _terminalKey,
                              core: widget.core,
                              appearance: widget.appearance,
                              amoledConfig: widget.amoledConfig,
                              isActive: _terminalOpen,
                              onSessionChanged: (name) {
                                if (mounted && name != _terminalPeerName) {
                                  setState(() => _terminalPeerName = name);
                                }
                              },
                              onConfigChanged: (cfg) {
                                if (mounted) {
                                  setState(() => _terminalConfig = cfg);
                                }
                              },
                              onStatsChanged: (stats) {
                                if (mounted) {
                                  setState(() => _terminalStats = stats);
                                }
                              },
                              onOpenAppSettings: () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        SettingsScreen(core: widget.core),
                                  ),
                                );
                                await _terminalKey.currentState
                                    ?.refreshStatsNow();
                              },
                              onTerminalExited: () {
                                if (!mounted) return;
                                setState(() {
                                  _terminalOpen = false;
                                  _terminalVisited = false;
                                });
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _terminalOpen
          ? null
          : NavigationBar(
              selectedIndex: tab.clamp(0, 2),
              onDestinationSelected: (v) {
                const names = ['Home', 'Devices', 'Share'];
                DebugTrace.logScreen(
                  'Tab',
                  names[v.clamp(0, names.length - 1)],
                );
                setState(() => tab = v);
                if (v == 1) unawaited(_refreshLanCandidates());
              },
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.home_outlined),
                  selectedIcon: amoledNavIcon(
                    context,
                    Icons.home,
                    widget.appearance,
                    config: widget.amoledConfig,
                  ),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: const Icon(Icons.devices_outlined),
                  selectedIcon: amoledNavIcon(
                    context,
                    Icons.devices,
                    widget.appearance,
                    config: widget.amoledConfig,
                  ),
                  label: 'Devices',
                ),
                NavigationDestination(
                  icon: const Icon(Icons.send_outlined),
                  selectedIcon: amoledNavIcon(
                    context,
                    Icons.send,
                    widget.appearance,
                    config: widget.amoledConfig,
                  ),
                  label: 'Share',
                ),
              ],
            ),
    ),
  );
  Widget _buildStatBadge(
    BuildContext context,
    String labelText,
    String valueText,
    Color accent, {
    IconData? icon,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.14),
          scheme.surface.withValues(alpha: 0.90),
        ),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.42), width: 0.9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: accent),
            const SizedBox(width: 3),
          ] else ...[
            Text(
              labelText,
              style: TextStyle(
                fontFamily: 'MesloLGS NF',
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: accent,
                height: 1.0,
              ),
            ),
            const SizedBox(width: 3),
          ],
          Text(
            valueText,
            style: TextStyle(
              fontFamily: 'MesloLGS NF',
              fontSize: 11.0,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _refreshPermissions({
    bool autoGrant = true,
    bool promptWizard = false,
  }) async {
    try {
      final status = await widget.core.permissionsStatus(autoGrant: autoGrant);
      if (!mounted) return;
      setState(() => _permissionsStatus = status);
      if (promptWizard && !_permissionWizardChecked) {
        _permissionWizardChecked = true;
        if (status['wizard_completed'] != true &&
            status['all_essential_granted'] != true) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_openPermissionWizard(initialStatus: status));
          });
        }
      }
    } catch (e) {
      DebugTrace.logCore('Permissions', 'Unable to read permissions: $e');
    }
  }

  Future<void> _openPermissionWizard({
    Map<String, dynamic>? initialStatus,
  }) async {
    final updated = await showPermissionWizard(
      context,
      widget.core,
      initialStatus: initialStatus ?? _permissionsStatus,
    );
    if (!mounted) return;
    if (updated != null) {
      setState(() => _permissionsStatus = updated);
    }
    unawaited(_refreshPermissions(autoGrant: false));
    try {
      final caps = await widget.core.platformCapabilities();
      if (mounted) {
        setState(() => capabilities = caps);
        _saveHomeCache();
      }
    } catch (_) {}
  }

  Future<void> _openConnections() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ConnectionsHub(
          core: widget.core,
          listenerState: listenerState,
        ),
      ),
    );
  }

  void _openRemoteTerminal(Map<String, dynamic> target) {
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() {
      _terminalOpen = true;
      _terminalVisited = true;
      _terminalPeerName = target['name'] as String?;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_terminalKey.currentState?.openRemote(target));
    });
  }

  Future<void> _openPeerDetails(Map<String, dynamic> peer) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DeviceDetail(
          core: widget.core,
          peer: peer,
          registry: registry,
          candidates: candidates,
        ),
      ),
    );
    if (mounted) await task(refreshPeers);
  }

  String _shortFingerprint(String? id) {
    if (id == null || id.isEmpty) {
      return '—';
    }
    if (id.length <= 20) {
      return id;
    }
    return '${id.substring(0, 12)}…${id.substring(id.length - 6)}';
  }

  Widget home() => HomeDashboard(
    core: widget.core,
    identity: identity,
    peers: peers,
    listenerState: listenerState,
    onOpenTerminal: () => setState(() {
      _terminalVisited = true;
      _terminalOpen = true;
    }),
    onOpenFiles: () => Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FileManager(core: widget.core, candidates: candidates),
      ),
    ),
    onOpenNetworks: _openConnections,
    onGoToTab: (index) {
      setState(() => tab = index);
      if (index == 1) unawaited(_refreshLanCandidates());
    },
    permissionsStatus: _permissionsStatus,
    onOpenPermissions: () => unawaited(_openPermissionWizard()),
  );

  Future<void> _openSshHost([
    Map<String, dynamic>? host,
    String? initialHost,
    int initialPort = 22,
    String? initialTransport,
    bool initialRemoteApproved = false,
  ]) async {
    final beforeIds = sshHosts.map((h) => '${h['id'] ?? ''}').toSet();
    final upgraded = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => SshHostScreen(
          core: widget.core,
          host: host,
          initialHost: initialHost,
          initialPort: initialPort,
          initialTransport: initialTransport,
          initialRemoteApproved: initialRemoteApproved,
        ),
      ),
    );
    await refreshPeers();
    if (!mounted) return;
    setState(() {
      if (upgraded == true) {
        _devicesTab = 0;
      } else {
        final afterIds = sshHosts.map((h) => '${h['id'] ?? ''}').toSet();
        if (afterIds.difference(beforeIds).isNotEmpty) {
          _devicesTab = 1;
        }
      }
    });
  }

  Future<void> _openSshBootstrap([Map<String, dynamic>? savedHost]) async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => SshBootstrapDialog(
        core: widget.core,
        initialHost: savedHost == null ? null : '${savedHost['host'] ?? ''}',
        initialPort: savedHost == null
            ? null
            : (savedHost['port'] as num?)?.toInt() ?? 22,
        initialUser: savedHost == null ? null : '${savedHost['user'] ?? ''}',
        initialExpectedHostKey: savedHost == null
            ? null
            : '${savedHost['expected_host_key'] ?? ''}',
        initialTransport: savedHost == null
            ? null
            : '${savedHost['transport'] ?? ''}',
        initialRemoteApproved: savedHost?['remote_approved'] == true,
        associateSshHostId: savedHost == null
            ? null
            : '${savedHost['id'] ?? ''}',
      ),
    );
    if (added == true) {
      await refreshPeers();
      if (mounted) {
        setState(() => _devicesTab = 0);
      }
    }
  }

  Future<void> _openTailscaleSshPicker() async {
    var loading = true;
    var targets = <Map<String, dynamic>>[];
    var startedLoad = false;
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          if (!startedLoad) {
            startedLoad = true;
            unawaited(
              _loadTailnetSshTargets().then((found) {
                if (!ctx.mounted) return;
                setDialogState(() {
                  loading = false;
                  targets = found;
                });
              }),
            );
          }
          return AlertDialog(
            key: const ValueKey('tailscale-ssh-picker-dialog'),
            title: const Text('Add from Tailscale SSH'),
            content: SizedBox(
              width: 440,
              child: loading
                  ? const SizedBox(
                      height: 80,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : targets.isEmpty
                  ? const Text(
                      'No online Tailscale devices with SSH found. Sign in to Tailscale in Networks first.',
                    )
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Select a Tailscale SSH device to add to your SSH devices list:',
                          ),
                          const SizedBox(height: 8),
                          for (final target in targets) ...[
                            Builder(
                              builder: (_) {
                                final name = '${target['name'] ?? ''}'.trim();
                                final host = '${target['host'] ?? ''}'.trim();
                                final connectHost =
                                    '${target['connect_host'] ?? ''}'.trim();
                                final port =
                                    (target['port'] as num?)?.toInt() ?? 22;
                                final pingMs =
                                    (target['ping_ms'] as num?)?.toDouble();
                                final banner = '${target['banner'] ?? ''}'
                                    .trim();
                                final alreadyPaired =
                                    target['already_paired'] == true;
                                final isTailscaleSsh =
                                    target['tailscale_ssh'] == true ||
                                    banner.contains('Tailscale');
                                final displayTitle = name.isNotEmpty
                                    ? name
                                    : (host.isNotEmpty ? host : connectHost);
                                final openTarget = host.isNotEmpty
                                    ? host
                                    : connectHost;
                                final details = <String>[
                                  if (connectHost.isNotEmpty &&
                                      connectHost != displayTitle)
                                    connectHost,
                                  isTailscaleSsh
                                      ? 'Tailscale SSH :$port'
                                      : 'SSH :$port',
                                  if (pingMs != null && pingMs > 0)
                                    '${pingMs.toStringAsFixed(1)} ms',
                                  if (alreadyPaired) 'Already paired',
                                ];
                                return ListTile(
                                  key: ValueKey(
                                    'tailscale-ssh-device-$openTarget',
                                  ),
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.hub_outlined),
                                  title: Text(displayTitle),
                                  subtitle: Text(details.join(' · ')),
                                  trailing: const Chip(
                                    label: Text('Add to SSH'),
                                  ),
                                  onTap: () => Navigator.pop(ctx, target),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setDialogState(() => loading = true);
                  unawaited(
                    _loadTailnetSshTargets().then((found) {
                      if (!ctx.mounted) return;
                      setDialogState(() {
                        loading = false;
                        targets = found;
                      });
                    }),
                  );
                },
                child: const Text('Refresh'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
    if (picked == null || !mounted) return;
    final host = '${picked['host'] ?? ''}'.trim();
    final connectHost = '${picked['connect_host'] ?? ''}'.trim();
    final openTarget = host.isNotEmpty ? host : connectHost;
    final port = (picked['port'] as num?)?.toInt() ?? 22;
    await _openSshHost(
      null,
      openTarget.isNotEmpty ? openTarget : null,
      port > 0 ? port : 22,
      'tailnet',
      true,
    );
  }

  Future<void> _addDevice() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        key: const ValueKey('add-device-sheet'),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                child: Text(
                  'Pair DeviceBridge device',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              ListTile(
                key: const ValueKey('add-device-scan-invite'),
                visualDensity: VisualDensity.compact,
                leading: const Icon(Icons.qr_code_scanner),
                title: const Text('Scan or enter invitation'),
                subtitle: const Text(
                  'Pair using another device’s QR code or invitation JSON',
                ),
                onTap: () => Navigator.pop(context, 'join'),
              ),
              ListTile(
                key: const ValueKey('add-device-show-invite'),
                visualDensity: VisualDensity.compact,
                leading: const Icon(Icons.qr_code),
                title: const Text('Show my invitation'),
                subtitle: const Text('Let another device pair with this device'),
                onTap: () => Navigator.pop(context, 'invite'),
              ),
              const Divider(height: 1),
              ListTile(
                key: const ValueKey('add-device-ssh-only'),
                visualDensity: VisualDensity.compact,
                leading: const Icon(Icons.terminal),
                title: const Text('Add SSH Device only (no agent)'),
                subtitle: const Text('Over available transports'),
                onTap: () => Navigator.pop(context, 'ssh_only'),
              ),
              ListTile(
                key: const ValueKey('add-device-tailscale-ssh'),
                visualDensity: VisualDensity.compact,
                leading: const Icon(Icons.hub_outlined),
                title: const Text('Add from Tailscale SSH'),
                subtitle: const Text(
                  'Pick an online Tailscale SSH peer to add to SSH devices',
                ),
                onTap: () => Navigator.pop(context, 'tailscale_ssh'),
              ),
              ListTile(
                key: const ValueKey('add-device-ssh-agent'),
                visualDensity: VisualDensity.compact,
                leading: const Icon(Icons.dns_outlined),
                title: const Text('Add agent via SSH'),
                subtitle: const Text(
                  'Install bridge-agent with root access via systemd over available transports',
                ),
                onTap: () => Navigator.pop(context, 'ssh_agent'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'join':
        await _pairWithInvitation();
      case 'invite':
        await _createInvitation();
      case 'ssh_only':
        await _openSshHost();
      case 'tailscale_ssh':
        await _openTailscaleSshPicker();
      case 'ssh_agent':
        await _openSshBootstrap();
    }
  }

  Widget devices() {
    final activePeers = peers.where((p) => p['status'] != 'revoked').toList();
    final revokedPeers = peers.where((p) => p['status'] == 'revoked').toList();
    final pairedIds = {
      for (final peer in activePeers)
        if (peer['status'] == 'paired') peer['id'],
    };
    final standaloneSshHosts = sshHosts
        .where((h) => !pairedIds.contains(h['agent_peer_id']))
        .toList();
    final knownIds = {identity?['id'], for (final peer in peers) peer['id']};
    final nearby = <String, Map<String, dynamic>>{};
    for (final candidate in candidates.whereType<Map<String, dynamic>>()) {
      final id = candidate['device_id'];
      if (id is String && !knownIds.contains(id)) {
        nearby.putIfAbsent(id, () => candidate);
      }
    }
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              key: const ValueKey('devices-add-device-button'),
              onPressed: busy ? null : _addDevice,
              icon: const Icon(Icons.add),
              label: const Text('Add Device'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('devices-acl-button'),
              onPressed: busy
                  ? null
                  : () async {
                      await Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AclScreen(core: widget.core),
                        ),
                      );
                      if (mounted) await task(refreshPeers);
                    },
              icon: const Icon(Icons.security_outlined),
              label: const Text('ACL & Groups'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SegmentedButton<int>(
          key: const ValueKey('devices-section-tabs'),
          segments: [
            const ButtonSegment<int>(
              value: 0,
              icon: Icon(Icons.devices_outlined),
              label: Text('Direct'),
            ),
            ButtonSegment<int>(
              value: 1,
              icon: const Icon(Icons.terminal),
              label: Text(
                standaloneSshHosts.isEmpty
                    ? 'SSH'
                    : 'SSH (${standaloneSshHosts.length})',
              ),
            ),
          ],
          selected: {_devicesTab},
          onSelectionChanged: (sel) =>
              setState(() => _devicesTab = sel.first),
        ),
        const SizedBox(height: 20),
        if (_devicesTab == 0) ...[
          if (activePeers.isNotEmpty)
            Text(
              'DeviceBridge devices',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ...activePeers.map(_peerCard),
          if (activePeers.isEmpty && nearby.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No active devices yet. Tap Add Device to pair via invitation or deploy an agent over SSH.',
              ),
            ),
          if (nearby.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              'Nearby DeviceBridge devices',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final entry in nearby.entries)
              ListTile(
                key: ValueKey('nearby-device-${entry.key}'),
                leading: const Icon(Icons.wifi),
                title: Text(
                  entry.value['device_name'] as String? ??
                      'DeviceBridge device',
                ),
                subtitle: Text('${entry.value['endpoint']} · Unpaired'),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy
                    ? null
                    : () => _pairWithInvitation(
                        peerId: entry.key,
                        peerName: entry.value['device_name'] as String?,
                      ),
              ),
          ],
          if (revokedPeers.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              'Revoked devices (${revokedPeers.length})',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            ...revokedPeers.map(_peerCard),
          ],
        ] else ...[
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('devices-browse-tailscale-ssh'),
                onPressed: busy ? null : _openTailscaleSshPicker,
                icon: const Icon(Icons.hub_outlined),
                label: const Text('Add from Tailscale SSH'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (standaloneSshHosts.isNotEmpty) ...[
            Text('SSH devices', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final host in standaloneSshHosts)
              Card(
                key: ValueKey('ssh-device-card-${host['id'] ?? host['host']}'),
                child: ListTile(
                  leading: const Icon(Icons.terminal),
                  title: Text('${host['name']}'),
                  subtitle: Text(
                    '${host['user']}@${host['host']}:${host['port']}'
                    '${(host['transport'] ?? '').toString().isNotEmpty ? ' · ${host['transport']}' : ''}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        key: ValueKey(
                          'ssh-device-upgrade-${host['id'] ?? host['host']}',
                        ),
                        onPressed: busy ? null : () => _openSshBootstrap(host),
                        icon: const Icon(Icons.upgrade, size: 18),
                        label: const Text('Upgrade'),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () => _openSshHost(host),
                ),
              ),
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No SSH devices saved yet. Tap Add Device or Add from Tailscale SSH to add an SSH host.',
              ),
            ),
        ],
      ],
    );
  }

  Widget _peerCard(dynamic p) => Card(
    child: ListTile(
      leading: Icon(
        p['status'] == 'revoked' ? Icons.block_outlined : Icons.computer,
      ),
      title: Text('${p['name']}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DeviceAddresses(
            peer: Map<String, dynamic>.from(p),
            candidates: candidates,
          ),
          if ((p['tags'] as List?)?.isNotEmpty == true ||
              (p['groups'] as List?)?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                [
                  ...(p['tags'] as List? ?? const []),
                  ...(p['groups'] as List? ?? const []),
                ].join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
      trailing: switch (p['status']) {
        'pending' => const Text('Approve request'),
        'outbound' => Text(
          _isWaitingForApproval(p['id'] as String)
              ? 'Waiting for approval'
              : 'Check approval',
        ),
        _ => const Icon(Icons.chevron_right),
      },
      onTap:
          busy ||
              (p['status'] == 'outbound' &&
                  _isWaitingForApproval(p['id'] as String))
          ? null
          : () async {
              if (p['status'] == 'pending') {
                final allow = await showDialog<bool>(
                  context: context,
                  builder: (_) =>
                      IncomingPairDialog(peer: Map<String, dynamic>.from(p)),
                );
                if (allow != null) {
                  await task(() async {
                    await widget.core.run([
                      'approve',
                      p['id'] as String,
                      allow ? 'all' : '',
                      '8760h',
                      '1099511627776',
                    ]);
                    await refreshPeers();
                  });
                }
              } else if (p['status'] == 'outbound') {
                await task(() => _finishInvitation(p['id'] as String));
              } else if (p['status'] == 'paired' || p['status'] == 'revoked') {
                await _openPeerDetails(Map<String, dynamic>.from(p));
              }
            },
    ),
  );
}
