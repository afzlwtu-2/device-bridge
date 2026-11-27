import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'network_card.dart';
import 'network_rules.dart';
import 'network_setup_settings.dart';
import 'tailnet_panel.dart';
import 'traffic_light.dart';

enum _LinkKind {
  wifi('Wi-Fi', Icons.wifi),
  ethernet('Ethernet', Icons.settings_ethernet),
  hotspot('Hotspot', Icons.wifi_tethering),
  wifiDirect('Wi-Fi Direct', Icons.wifi_find),
  usbNetwork('USB network', Icons.usb),
  cellular('Mobile data', Icons.signal_cellular_alt);

  const _LinkKind(this.label, this.icon);
  final String label;
  final IconData icon;

  static _LinkKind? of(Map<String, dynamic> network) {
    final iface = '${network['interface'] ?? ''}';
    return switch (network['kind']) {
      'hotspot' => hotspot,
      'wifi_direct' => wifiDirect,
      'usb_net' when iface.startsWith('eth') || iface.startsWith('en') =>
        ethernet,
      'usb_net' => usbNetwork,
      'ethernet' => ethernet,
      'cellular' => cellular,
      'wifi' || null => switch (iface) {
        _ when iface.startsWith('p2p') || iface.startsWith('dbp2p') =>
          wifiDirect,
        _ when iface.startsWith('ap') || iface.startsWith('swlan') => hotspot,
        _ when iface.startsWith('usb') || iface.startsWith('rndis') =>
          usbNetwork,
        _ when iface.startsWith('wwan') || iface.startsWith('rmnet') =>
          cellular,
        _ when iface.startsWith('eth') || iface.startsWith('en') => ethernet,
        _ when network['kind'] == 'wifi' || iface.startsWith('wl') => wifi,
        _ => null,
      },
      _ => null,
    };
  }

  String? get directKind => switch (this) {
    hotspot => 'hotspot',
    wifiDirect => 'wifi_direct',
    _ => null,
  };
}

bool _sameLink(Map<String, dynamic>? a, Map<String, dynamic>? b) {
  if (a == null || b == null) return false;
  final handle = '${a['network_handle'] ?? ''}';
  final otherHandle = '${b['network_handle'] ?? ''}';
  return a['interface'] == b['interface'] &&
      a['cidr'] == b['cidr'] &&
      (handle.isEmpty || otherHandle.isEmpty || handle == otherHandle);
}

String _address(Map<String, dynamic> network) => [
  network['interface'],
  network['cidr'],
].whereType<String>().where((part) => part.isNotEmpty).join(' · ');

class ConnectionsHub extends StatefulWidget {
  const ConnectionsHub({
    super.key,
    required this.core,
    required this.listenerState,
  });

  final CoreBridge core;
  final String? listenerState;

  @override
  State<ConnectionsHub> createState() => _ConnectionsHubState();
}

class _ConnectionsHubState extends State<ConnectionsHub>
    with WidgetsBindingObserver {
  NetworkLayer _view = NetworkLayer.services;
  final _usbLink = GlobalKey();

  bool _loading = true;
  bool _working = false;
  int _loadGeneration = 0;
  String? _error;
  List<Map<String, dynamic>> _availableNetworks = [];
  Map<String, dynamic> _caps = {};
  Map<String, dynamic> _runtime = {};
  Map<String, dynamic> _settings = {};
  NetworkRules _rules = const NetworkRules();
  Map? _tailnet;
  Map? _wireguard;
  StreamSubscription<Map<String, dynamic>>? _netSub;

  bool get _busy => _loading || _working;
  bool get _android =>
      Platform.isAndroid ||
      _runtime['os'] == 'android' ||
      _caps['os'] == 'android';
  bool get _tailnetRunning => _tailnet?['state'] == 'Running';
  bool get _wireguardRunning =>
      _wireguard?['configured'] == true &&
      (_wireguard?['running'] == true ||
          _wireguard?['state'] == 'Running' ||
          _map('wireguard')['process_running'] == true);
  Map<String, dynamic> get _directSession => _map('direct_link');
  String? _sessionLinkKind(Map<String, dynamic> session) {
    if (session['active'] != true) return null;
    final kind = session['kind'] as String?;
    if (kind == 'wifi_join') {
      return (session['saved'] as Map?)?['kind'] as String?;
    }
    return kind;
  }

  Map<String, dynamic> get _usb => _map('usb');
  bool get _wiredAdb =>
      _usb['usb_adb_connected'] == true || _caps['usb_adb_connected'] == true;
  bool get _usbCable => _wiredAdb || _usb['cable_plugged'] == true;
  bool get _usbReverse => _wiredAdb && _usb['usb_adb_reverse_active'] == true;
  String get _usbSerial {
    final serial = '${_usb['serial'] ?? _caps['usb_serial'] ?? ''}'.trim();
    return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(serial) ? serial : '';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _netSub = widget.core.networkEvents.listen(
      (_) => unawaited(_load(silent: true)),
    );
    unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_load(silent: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_netSub?.cancel());
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    if (!silent) setState(() => _loading = true);
    final results = await Future.wait([
      widget.core.networks().catchError((_) => <Map<String, dynamic>>[]),
      widget.core.platformCapabilities().catchError((_) => <String, dynamic>{}),
      widget.core.runtimeStatus().catchError((_) => <String, dynamic>{}),
      widget.core.appSettings().catchError((_) => <String, dynamic>{}),
      NetworkRules.load(widget.core).catchError((_) => const NetworkRules()),
    ]);
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _availableNetworks = results[0] as List<Map<String, dynamic>>;
      _caps = results[1] as Map<String, dynamic>;
      _runtime = results[2] as Map<String, dynamic>;
      _settings = results[3] as Map<String, dynamic>;
      _rules = results[4] as NetworkRules;
      _tailnet = _runtime['tailnet_status'] as Map?;
      _wireguard = _runtime['wireguard_status'] as Map?;
      _loading = false;
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _working = true);
    try {
      await _navigate(action);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _navigate(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      await _load(silent: true);
    }
  }

  Map<String, dynamic> _map(String key) {
    final value = _runtime[key];
    return value is Map ? Map<String, dynamic>.from(value) : {};
  }

  void _show(NetworkLayer view, {GlobalKey? anchor}) {
    setState(() => _view = view);
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = anchor.currentContext;
      if (mounted && _view == view && target != null) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 180),
        );
      }
    });
  }

  Map<String, dynamic> _withDirectKind(Map<String, dynamic> network) {
    final session = _directSession;
    final sessionKind = _sessionLinkKind(session);
    final selected = widget.core.network;
    if (const {'hotspot', 'wifi_direct'}.contains(sessionKind) &&
        _sameLink(session, network)) {
      return {...network, 'kind': sessionKind};
    }
    if (_sameLink(selected, network) &&
        selected?['direct'] == true &&
        const {'hotspot', 'wifi_direct'}.contains(selected?['kind'])) {
      return {...network, 'kind': selected!['kind']};
    }
    return network;
  }

  List<Map<String, dynamic>> _directLinks(List<Map<String, dynamic>> networks) {
    final links = <Map<String, dynamic>>[];
    for (final raw in networks) {
      final link = _withDirectKind(raw);
      final kind = _LinkKind.of(link);
      if (kind == null ||
          !_rules.link(kind.directKind ?? kind.name) ||
          kind == _LinkKind.cellular ||
          link['connected'] == false ||
          (link['interface'] as String? ?? '').isEmpty ||
          (link['cidr'] as String? ?? '').isEmpty) {
        continue;
      }
      if (!links.any((other) => _sameLink(other, link))) links.add(link);
    }
    return links;
  }

  List<Map<String, dynamic>> _linksOfKind(_LinkKind kind) {
    final live = (_runtime['physical_networks'] as List? ?? const [])
        .whereType<Map>()
        .map((v) => Map<String, dynamic>.from(v));
    final result = <Map<String, dynamic>>[];
    for (final raw in [...live, ..._availableNetworks]) {
      final link = _withDirectKind(raw);
      if (_LinkKind.of(link) == kind &&
          link['connected'] != false &&
          !result.any((other) => _sameLink(other, link))) {
        result.add(link);
      }
    }
    return result;
  }

  Future<void> _bindLink(Map<String, dynamic> target, {bool roam = false}) =>
      _perform(() async {
        final available = _directLinks(await widget.core.networks());
        final current = available
            .where((link) => _sameLink(target, link))
            .firstOrNull;
        if (current == null) {
          throw StateError(
            'That link changed. Choose a currently connected link.',
          );
        }
        final kind = _LinkKind.of(current)!;
        await widget.core.approveNetwork({
          ...current,
          if (kind.directKind case final direct?) ...{
            'kind': direct,
            'direct': true,
          },
          'allow_wifi_roaming': kind == _LinkKind.wifi && roam,
        });
      });

  Future<void> _chooseDirectLink(_LinkKind kind) async {
    final links = _directLinks(_availableNetworks)
        .where((link) => _LinkKind.of(link) == kind);
    final active = widget.core.network;
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(ctx).height * .65,
        ),
        child: SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(
                'Use ${kind.label} for Direct TCP',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                _android
                    ? 'Changing the local listener link can interrupt direct connections.'
                    : 'This sets the local link for the app’s outbound direct connections.',
              ),
              const SizedBox(height: 8),
              for (final link in links)
                ListTile(
                  key: ValueKey("l4-direct-underlay-${link['interface']}"),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  leading: Icon(_LinkKind.of(link)!.icon),
                  title: Text(_LinkKind.of(link)!.label),
                  subtitle: Text(
                    [
                      _address(link),
                      if (link['unmetered'] == false) 'Metered',
                    ].join(' · '),
                  ),
                  selected: _sameLink(active, link),
                  trailing: _sameLink(active, link)
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.pop(ctx, link),
                ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || picked == null || _sameLink(widget.core.network, picked)) {
      return;
    }
    await _bindLink(picked);
  }

  bool _canStart(_LinkKind kind) =>
      _rules.allows(kind.directKind!) &&
      _android &&
      _caps[kind == _LinkKind.hotspot ? 'hotspot_ap' : 'wifi_direct'] == true;

  Future<void> _stopDirect(String expectedKind) => _perform(() async {
    final session = await widget.core.activeDirectLink();
    if (session['active'] != true || session['kind'] != expectedKind) {
      throw StateError(
        'The direct link changed. Refresh its status and try again.',
      );
    }
    await widget.core.stopDirectLink(forget: true);
  });

  Future<void> _openSetup(String kind) =>
      _perform(() => widget.core.openConnectionSetup(kind));

  Future<void> _manageTailnet() => _navigate(
    () => Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => TailnetPanel(core: widget.core)),
    ),
  );

  Future<void> _importWireguard() => _navigate(() async {
    await showDialog<bool>(
      context: context,
      builder: (_) => _WireguardImportDialog(core: widget.core),
    );
  });

  Future<void> _removeWireguard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove WireGuard configuration?'),
        content: const Text(
          'You will need the .conf file to set up this tunnel again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _perform(() async {
      await widget.core.enableWireguard(false);
      await widget.core.run(['wireguard', 'remove-conf']);
    });
  }

  Future<({bool triggered, String? hostName, String? detail})>
  _triggerHostAdbReverseViaPeers(String usbSerial) async {
    final raw = await widget.core
        .run(['peers'])
        .timeout(const Duration(seconds: 2));
    if (raw is! List) return (triggered: false, hostName: null, detail: null);
    final payload = jsonEncode({'kind': 'adb_usb', 'serial': usbSerial});
    final transportPrefixes = <List<String>>[
      if (_directLinks(_availableNetworks)
          .any((link) => _sameLink(link, widget.core.network)))
        const <String>[],
      if (_tailnetRunning) const ['--transport', 'tailnet'],
      if (_wireguardRunning) const ['--transport', 'wireguard'],
    ];
    for (final peer in raw.whereType<Map>()) {
      final kind = '${peer['os'] ?? ''}'.toLowerCase();
      final id = '${peer['id'] ?? ''}';
      if (peer['status'] != 'paired' || kind != 'linux' || id.isEmpty) continue;
      for (final prefix in transportPrefixes) {
        try {
          final res = await widget.core
              .run([...prefix, 'prepare-link', id, '-'], input: payload)
              .timeout(const Duration(seconds: 6));
          if (res is! Map || res['ok'] != true) continue;
          return (
            triggered: true,
            hostName: '${peer['name'] ?? id}',
            detail: null,
          );
        } catch (_) {
          // The host may be offline or may have a different Android device attached.
        }
      }
    }
    return (
      triggered: false,
      hostName: null,
      detail: 'No reachable paired Linux host accepted this USB serial. Run the command on the attached computer.',
    );
  }

  Future<void> _openUsbAdbDialog() => _navigate(() async {
    String? result;
    bool checking = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          final serial = _usbSerial;
          final command =
              'adb -s ${serial.isEmpty ? '<serial>' : serial} reverse tcp:18731 tcp:8731';
          return AlertDialog(
            key: const ValueKey('usb-adb-dialog'),
            title: const Text('USB ADB reverse'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_usbAdbStatus()),
                  const SizedBox(height: 12),
                  const Text(
                    'On the attached computer, check the phone with adb devices -l, then run:',
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: SelectableText(
                      command,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    trailing: IconButton(
                      tooltip: 'Copy adb reverse command',
                      icon: const Icon(Icons.copy),
                      onPressed: serial.isEmpty
                          ? null
                          : () =>
                                Clipboard.setData(ClipboardData(text: command)),
                    ),
                  ),
                  if (serial.isEmpty)
                    const Text(
                      'Replace <serial> with the serial shown by adb devices -l.',
                    ),
                  if (result != null) Text(result!),
                  if (checking) const LinearProgressIndicator(),
                ],
              ),
            ),
            actions: [
              if (_usb['adb_enabled'] != true && _caps['adb_enabled'] != true)
                TextButton(
                  onPressed: checking
                      ? null
                      : () async {
                          try {
                            await widget.core.openConnectionSetup('adb');
                          } catch (error) {
                            if (ctx.mounted) update(() => result = '$error');
                          }
                        },
                  child: const Text('Developer options'),
                ),
              TextButton(
                onPressed: checking ? null : () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
              if (!_usbReverse && _wiredAdb && serial.isNotEmpty)
                FilledButton(
                  key: const ValueKey('usb-adb-activate'),
                  onPressed: checking
                      ? null
                      : () async {
                          update(() {
                            result = null;
                            checking = true;
                          });
                          try {
                            await _load(silent: true);
                            if (!ctx.mounted) return;
                            if (!_wiredAdb ||
                                _usbSerial != serial ||
                                _usbReverse) {
                              return;
                            }
                            final host = await _triggerHostAdbReverseViaPeers(
                              serial,
                            );
                            await _load(silent: true);
                            if (!ctx.mounted) return;
                            result = host.triggered
                                ? 'Command accepted by ${host.hostName}. Check the paired device route to verify the agent.'
                                : host.detail;
                          } catch (error) {
                            result = '$error';
                          } finally {
                            if (ctx.mounted) update(() => checking = false);
                          }
                        },
                  child: const Text('Activate on paired host'),
                )
              else
                TextButton(
                  onPressed: checking
                      ? null
                      : () async {
                          await _load(silent: true);
                          if (ctx.mounted) update(() {});
                        },
                  child: const Text('Check status'),
                ),
            ],
          );
        },
      ),
    );
  });

  String _usbAdbStatus() {
    if (_usbReverse) return 'Reverse listener detected on 127.0.0.1:18731';
    if (_wiredAdb) {
      return _android
          ? 'Wired ADB detected. The attached computer can start the reverse tunnel.'
          : 'Wired Android device detected. Choose its paired route.';
    }
    if (!_usbCable) {
      return 'Connect Android and the computer with a USB data cable.';
    }
    if (_usb['adb_enabled'] != true && _caps['adb_enabled'] != true) {
      return 'Enable USB debugging in Android Developer options.';
    }
    return 'Check the USB data cable and approve the debugging prompt on Android.';
  }

  String _linkStatus(_LinkKind kind, List<Map<String, dynamic>> links) {
    if (links.isEmpty) {
      return kind == _LinkKind.cellular ? 'Inactive' : 'Disconnected';
    }
    return links
        .map(
          (link) => [
            _address(link),
            if (kind == _LinkKind.cellular || link['unmetered'] == false)
              'Metered',
          ].where((part) => part.isNotEmpty).join(' · '),
        )
        .join('\n');
  }

  List<Widget> _services() {
    final agent = _map('agent');
    final ssh = _map('ssh');
    final running = agent['running'] == true || agent['file_running'] == true;
    final agentSsh = _rules.allows('agent_ssh');
    final tailnetSsh = _settings['tsnet_ssh_enabled'] == true;
    final openssh = _settings['tsnet_openssh_enabled'] == true;
    final terminalReady = !_android || ssh['terminal_ready'] != false;
    final openSshReady = ssh['openssh_ready'] != false;
    final openSshAddress = ssh['openssh_address'] as String?;
    final openSshError = ssh['openssh_error'] as String?;
    Widget toggle(
      String id,
      String title,
      String detail,
      bool enabled,
      Future<void> Function(bool) apply,
    ) => SwitchListTile.adaptive(
      key: ValueKey('ssh-backend-$id'),
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(detail),
      value: enabled,
      onChanged: _busy
          ? null
          : (value) => _perform(() async {
              if (!value) {
                setState(() => _working = false);
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('Disable $title?'),
                    content: Text(
                      id == 'service'
                          ? 'Agent files, sharing and Agent SSH will disconnect. Tailscale SSH and OpenSSH have separate controls.'
                          : 'New incoming sessions will be blocked. Existing sessions using this backend may disconnect. Other SSH methods and file access remain available.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Disable'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
                if (!mounted) return;
                setState(() => _working = true);
              }
              await apply(value);
            }),
    );
    return [
      NetworkCard(
        icon: Icons.memory_outlined,
        title: 'DeviceBridge agent',
        status: _settings['agent_enabled'] == false
            ? (running ? 'Stopping' : 'Off')
            : running
            ? 'Running'
            : 'Standby',
        level: running ? TrafficLightLevel.green : TrafficLightLevel.off,
        detail:
            'Files, sharing and paired-device features. ${agent['active_conns'] ?? 0} active connections.',
        extra: _android
            ? toggle(
                'service',
                'Agent service',
                'Receive Agent connections on this device. SSH backends have separate controls below.',
                _settings['agent_enabled'] != false,
                (value) async {
                  await widget.core.appSettings(
                    update: {'agent_enabled': value},
                  );
                },
              )
            : null,
        actions: [
          if (_android)
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _perform(widget.core.restartAgent),
              child: const Text('Restart agent'),
            ),
        ],
      ),
      NetworkCard(
        key: const ValueKey('network-ssh-service'),
        icon: Icons.terminal,
        title: 'SSH',
        detail: 'Incoming access to this device. Open SSH from a device’s details to connect out.',
        extra: Column(
          children: [
            toggle(
              'agent',
              'Agent SSH',
              agentSsh
                  ? !terminalReady
                        ? 'Terminal setup required'
                        : '${running ? 'Available through Agent' : 'Waiting for Agent'} · ${agent['active_ssh'] ?? ssh['agent_ssh_conns'] ?? 0} sessions'
                  : 'Off · Agent files and sharing stay available',
              agentSsh,
              (value) => NetworkRules.save(widget.core, 'agent_ssh', value),
            ),
            if (_android)
              toggle(
                'tailnet',
                'Tailscale SSH',
                tailnetSsh
                    ? !terminalReady
                          ? 'Terminal setup required'
                          : '${_tailnetRunning ? 'Tailnet port 22' : 'Sign in to Tailscale first'} · ${_tailnet?['active_ssh_conns'] ?? 0} sessions'
                    : 'Off · Tailscale transport stays available',
                tailnetSsh,
                (value) async {
                  await widget.core.appSettings(
                    update: {'tsnet_ssh_enabled': value},
                  );
                },
              ),
            if (!terminalReady)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _perform(
                        () => widget.core.openConnectionSetup('terminal-setup'),
                      ),
                child: const Text('Set up Terminal for incoming SSH'),
              ),
            if (_android)
              toggle(
                'openssh',
                'Termux OpenSSH',
                openssh
                    ? openSshError ??
                          (openSshAddress == null
                              ? 'Waiting for the selected LAN link'
                              : 'Listening on $openSshAddress:8022 · Key auth only')
                    : 'Off · Key-based SSH on the selected LAN link',
                openssh,
                (value) async {
                  if (value && !openSshReady) {
                    await widget.core.openConnectionSetup('terminal-openssh');
                  }
                  await widget.core.appSettings(
                    update: {'tsnet_openssh_enabled': value},
                  );
                },
              ),
            if (!_android)
              const ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('System OpenSSH'),
                subtitle: Text(
                  'Manage the existing SSH service in system settings.',
                ),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _transports() {
    final agent = _map('agent');
    final linkDetails = _map('link_details');
    final selected = widget.core.network;
    final live = _directLinks(_availableNetworks)
        .where((link) => _sameLink(link, selected))
        .firstOrNull;
    final liveKind = live == null ? null : _LinkKind.of(live);
    final receiverNetwork = agent['network'];
    final listenerUp =
        _android &&
        receiverNetwork is Map &&
        _sameLink(live, Map<String, dynamic>.from(receiverNetwork)) &&
        (agent['state'] ?? widget.listenerState) == 'active';
    final tsState = switch (_tailnet?['state']) {
      'Running' => 'Running',
      'NeedsLogin' => 'Sign-in needed',
      'NeedsMachineAuth' => 'Approval needed',
      'Starting' => 'Starting',
      'Stopped' => 'Stopped',
      _ => 'Unavailable',
    };
    final hostname = '${_tailnet?['hostname'] ?? ''}';
    final tsIp = (_tailnet?['ips'] as List?)?.firstOrNull;
    final wgConfigured = _wireguard?['configured'] == true;
    final wgRunning = _wireguardRunning;
    final wgIp = '${_wireguard?['local_tunnel_ip'] ?? ''}';
    final wgBackend = '${_wireguard?['backend'] ?? ''}';
    final wgAllowed = (_wireguard?['scoped_allowed_ips'] as List? ?? const [])
        .join(', ');
    return [
      if (_rules.allows('direct'))
        NetworkCard(
          key: const ValueKey('networks-direct-tls'),
          icon: Icons.lan_outlined,
          title: 'Direct TCP',
          status: listenerUp
              ? 'Listening'
              : live != null
              ? 'Link selected'
              : 'Needs link',
          level: listenerUp ? TrafficLightLevel.green : TrafficLightLevel.amber,
          detail: live == null
              ? selected == null
                    ? 'TCP with mutual TLS. Bind a local interface under Links.'
                    : 'The local interface is unavailable. Check Links.'
              : [
                  '${liveKind!.label} · ${_address(live)}',
                  if (live['unmetered'] == false) 'Metered',
                  if ('${linkDetails['wifi_standard'] ?? ''}'.isNotEmpty)
                    '${linkDetails['wifi_standard']}',
                  if ('${linkDetails['band'] ?? ''}'.isNotEmpty)
                    '${linkDetails['band']}',
                  if ((linkDetails['channel'] as num? ?? 0) > 0)
                    'Ch ${linkDetails['channel']}',
                ].join(' · '),
        ),
      if (_rules.allows('tailnet') || _tailnetRunning)
        NetworkCard(
          key: const ValueKey('connections-tailscale'),
          icon: Icons.vpn_lock_outlined,
          title: 'Tailscale',
          status: tsState,
          level: _tailnetRunning
              ? TrafficLightLevel.green
              : TrafficLightLevel.off,
          detail: [
            if (hostname.isNotEmpty || tsIp != null)
              [if (hostname.isNotEmpty) hostname, ?tsIp].join(' · '),
            if (_android)
              'Uses Android’s default internet link when available. Check Direct or Relay under the paired device.'
            else
              'Uses system routing. Check Direct or Relay under the paired device.',
          ].join('\n'),
          actions: [
            FilledButton.tonal(
              onPressed: _busy ? null : _manageTailnet,
              child: const Text('Manage Tailscale'),
            ),
          ],
        ),
      if (_rules.allows('wireguard') || wgConfigured)
        NetworkCard(
          icon: Icons.vpn_key_outlined,
          title: 'WireGuard',
          status: wgRunning
              ? 'Running'
              : wgConfigured
              ? 'Configured'
              : 'Setup needed',
          level: wgRunning
              ? TrafficLightLevel.green
              : wgConfigured
              ? TrafficLightLevel.amber
              : TrafficLightLevel.off,
          detail: wgConfigured
              ? [
                  if (wgBackend.isNotEmpty) wgBackend,
                  if (wgIp.isNotEmpty) wgIp,
                  if (wgAllowed.isNotEmpty) 'Tunnel routes: $wgAllowed',
                  if (_wireguard?['default_route_stripped'] == true)
                    'Default routes stripped from this app-scoped tunnel.',
                  _android
                      ? 'Uses the shared LAN selection. Android may keep Wi-Fi for the tunnel while hosting a direct link.'
                      : 'The system routes traffic to the WireGuard endpoint.',
                ].join('\n')
              : 'Import a configuration for DeviceBridge tunnel routes.',
          actions: [
            FilledButton.tonal(
              onPressed: _busy ? null : _importWireguard,
              child: Text(wgConfigured ? 'Replace .conf' : 'Import .conf'),
            ),
            if (wgConfigured) ...[
              TextButton(
                onPressed: _busy ? null : _removeWireguard,
                child: const Text('Remove'),
              ),
            ],
          ],
        ),
      if (_rules.allows('adb') && _usbCable)
        NetworkCard(
          icon: Icons.developer_mode,
          title: 'USB ADB reverse',
          status: _usbReverse
              ? 'Listener detected'
              : _wiredAdb
              ? 'Wired ADB'
              : 'Needs USB',
          level: _usbReverse
              ? TrafficLightLevel.green
              : TrafficLightLevel.amber,
          detail: _usbAdbStatus(),
          actions: [
            if (_android)
              FilledButton.tonal(
                key: const ValueKey('usb-adb-start'),
                onPressed: _busy ? null : _openUsbAdbDialog,
                child: Text(_usbReverse ? 'Tunnel details' : 'USB setup'),
              ),
            TextButton.icon(
              onPressed: () => _show(NetworkLayer.links, anchor: _usbLink),
              icon: const Icon(Icons.arrow_downward),
              label: const Text('USB cable'),
            ),
          ],
        ),
    ];
  }

  Widget? _bindAction(_LinkKind kind) {
    final available = _directLinks(_availableNetworks).any(
      (link) =>
          _LinkKind.of(link) == kind && !_sameLink(link, widget.core.network),
    );
    if (!available ||
        !_rules.link(kind.directKind ?? kind.name) ||
        !_rules.allows('direct')) {
      return null;
    }
    return TextButton(
      key: ValueKey('bind-local-link-${kind.name}'),
      onPressed: _busy ? null : () => _chooseDirectLink(kind),
      child: const Text('Use for Direct TCP'),
    );
  }

  String _formatCheckedAge(dynamic ts) {
    final sec = (ts as num?)?.toInt() ?? 0;
    if (sec <= 0) return '';
    final delta = ((DateTime.now().millisecondsSinceEpoch ~/ 1000) - sec).clamp(
      0,
      86400 * 365,
    );
    if (delta < 60) return 'Checked just now';
    if (delta < 3600) return 'Checked ${delta ~/ 60}m ago';
    return 'Checked ${delta ~/ 3600}h ago';
  }

  List<Widget> _links() {
    final wifi = _linksOfKind(_LinkKind.wifi);
    final selected = widget.core.network;
    final selectedWifi = wifi
        .where((link) => _sameLink(link, selected))
        .firstOrNull;
    final ethernet = _linksOfKind(_LinkKind.ethernet);
    final usbNetwork = _linksOfKind(_LinkKind.usbNetwork);
    final cellular = _linksOfKind(_LinkKind.cellular);
    final session = _directSession;
    final capFreshness = _formatCheckedAge(_caps['checked_at_utc']);
    return [
      if (_caps.isEmpty && !_loading)
        NetworkCard(
          icon: Icons.help_outline,
          title: 'Local link support unknown',
          detail: 'Hardware capabilities have not been checked yet.',
          actions: [
            TextButton(
              onPressed: _busy ? null : _load,
              child: const Text('Check support'),
            ),
          ],
        ),
      if (capFreshness.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            capFreshness,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      if (wifi.isNotEmpty ||
          _caps['wifi'] == true ||
          _caps['hotspot_sta'] == true)
        NetworkCard(
          icon: _LinkKind.wifi.icon,
          title: _LinkKind.wifi.label,
          detail:
              _linkStatus(_LinkKind.wifi, wifi) +
              (_android ? '' : '\nChange Wi-Fi in desktop network settings.'),
          extra: selectedWifi == null
              ? null
              : SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Recover on unmetered Wi-Fi'),
                  value: selected?['allow_wifi_roaming'] == true,
                  onChanged: _busy
                      ? null
                      : (value) => _bindLink(selectedWifi, roam: value),
                ),
          actions: [
            if (_android)
              FilledButton.tonal(
                onPressed: _busy ? null : () => _openSetup('wifi'),
                child: const Text('Wi-Fi settings'),
              ),
            ?_bindAction(_LinkKind.wifi),
          ],
        ),
      if (ethernet.isNotEmpty)
        NetworkCard(
          icon: _LinkKind.ethernet.icon,
          title: _LinkKind.ethernet.label,
          detail: _linkStatus(_LinkKind.ethernet, ethernet),
          actions: [?_bindAction(_LinkKind.ethernet)],
        ),
      if (session['active'] == true &&
          session['kind'] == 'wifi_join' &&
          !const {'hotspot', 'wifi_direct'}.contains(_sessionLinkKind(session)))
        NetworkCard(
          icon: Icons.wifi,
          title: 'Joined direct link',
          detail: _address(session),
          actions: [
            TextButton(
              onPressed: _busy ? null : () => _stopDirect('wifi_join'),
              child: const Text('Disconnect'),
            ),
          ],
        ),
      for (final kind in [_LinkKind.hotspot, _LinkKind.wifiDirect])
        if (_canStart(kind) ||
            _linksOfKind(kind).isNotEmpty ||
            _sessionLinkKind(session) == kind.directKind)
          NetworkCard(
            icon: kind.icon,
            title: kind.label,
            detail: [
              _linkStatus(kind, _linksOfKind(kind)),
              'Set up a link with a peer in its Connections screen.',
            ].join('\n'),
            actions: [
              ?_bindAction(kind),
              if (_sessionLinkKind(session) == kind.directKind)
                TextButton(
                  key: ValueKey('direct-stop-${kind.directKind}'),
                  onPressed: _busy
                      ? null
                      : () => _stopDirect(
                          session['kind'] as String? ?? kind.directKind!,
                        ),
                  child: Text('Stop ${kind.label}'),
                ),
            ],
          ),
      if (_usbCable || usbNetwork.isNotEmpty)
        KeyedSubtree(
          key: _usbLink,
          child: NetworkCard(
            icon: Icons.usb,
            title: 'USB cable',
            detail: [
              if (usbNetwork.isNotEmpty)
                'USB networking · ${_linkStatus(_LinkKind.usbNetwork, usbNetwork)}',
              if (_wiredAdb)
                'Wired ADB detected'
              else if (_usbCable)
                'Cable detected · Check data and debugging'
              else if (usbNetwork.isEmpty)
                'Disconnected',
            ].join('\n'),
            actions: [
              ?_bindAction(_LinkKind.usbNetwork),
              if (_android)
                TextButton(
                  key: const ValueKey('usb-cable-setup'),
                  onPressed: _busy ? null : _openUsbAdbDialog,
                  child: const Text('USB ADB setup'),
                ),
            ],
          ),
        ),
      if (cellular.isNotEmpty || _caps['cellular'] == true)
        NetworkCard(
          icon: _LinkKind.cellular.icon,
          title: _LinkKind.cellular.label,
          detail: [
            _linkStatus(_LinkKind.cellular, cellular),
            if (_android) 'Managed in Android network settings.',
          ].join('\n'),
          actions: [
            if (_android)
              TextButton(
                onPressed: _busy ? null : () => _openSetup('cellular'),
                child: const Text('Mobile network settings'),
              ),
          ],
        ),
    ];
  }

  Future<void> _openNetworkSettings() => _navigate(
    () => Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => NetworkSetupSettings(core: widget.core),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Networks'),
        actions: [
          IconButton(
            key: const ValueKey('network-settings-button'),
            onPressed: _busy ? null : _openNetworkSettings,
            tooltip: 'Network settings',
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh networks',
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: SegmentedButton<NetworkLayer>(
                showSelectedIcon: false,
                segments: [
                  for (final view in NetworkLayer.values)
                    ButtonSegment(
                      value: view,
                      label: Text(
                        view.label,
                        key: ValueKey('networks-${view.name}'),
                      ),
                    ),
                ],
                selected: {_view},
                onSelectionChanged: (selection) => _show(selection.single),
              ),
            ),
            SizedBox(
              height: 3,
              child: _busy ? const LinearProgressIndicator() : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 5, 12, 4),
              child: Text(
                _view.description,
                style: Theme.of(context).textTheme.labelLarge,
                textAlign: TextAlign.center,
              ),
            ),
            if (_error case final error?)
              MaterialBanner(
                content: SelectableText(error),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _error = null),
                    child: const Text('Dismiss'),
                  ),
                ],
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: SingleChildScrollView(
                  key: ValueKey('networks-content-${_view.name}'),
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: Column(
                        key: const ValueKey('networks-hub'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ...switch (_view) {
                            NetworkLayer.services => _services(),
                            NetworkLayer.transports => _transports(),
                            NetworkLayer.links => _links(),
                          },
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WireguardImportDialog extends StatefulWidget {
  const _WireguardImportDialog({required this.core});
  final CoreBridge core;

  @override
  State<_WireguardImportDialog> createState() => _WireguardImportDialogState();
}

class _WireguardImportDialogState extends State<_WireguardImportDialog> {
  final confCtrl = TextEditingController();
  final pathCtrl = TextEditingController();
  String? dialogErr;
  bool importing = false;

  @override
  void dispose() {
    confCtrl.dispose();
    pathCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Import WireGuard .conf'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Imports your server .conf purely for internal DeviceBridge tunnel connections. Default routes (0.0.0.0/0, ::/0) and DNS overrides are stripped so general mobile traffic never routes through WireGuard.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: importing
                      ? null
                      : () async {
                          try {
                            final picked = await widget.core.pickConfText();
                            if (picked != null && picked.trim().isNotEmpty) {
                              setState(() {
                                confCtrl.text = picked;
                                dialogErr = null;
                              });
                            }
                          } catch (e) {
                            setState(() => dialogErr = '$e');
                          }
                        },
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Choose .conf file'),
                ),
              ],
            ),
            if (!Platform.isAndroid) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: pathCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Or .conf file path',
                        hintText: '/path/to/wg0.conf',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: importing
                        ? null
                        : () async {
                            final p = pathCtrl.text.trim();
                            if (p.isEmpty) return;
                            try {
                              final text = await File(p).readAsString();
                              setState(() {
                                confCtrl.text = text;
                                dialogErr = null;
                              });
                            } catch (e) {
                              setState(() => dialogErr = '$e');
                            }
                          },
                    child: const Text('Load'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: confCtrl,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'WireGuard .conf contents',
                hintText: '[Interface]\nPrivateKey = ...\nAddress = 10.x.x.x/24\n\n[Peer]\nPublicKey = ...\nEndpoint = dubai.example:51820\nAllowedIPs = 10.x.x.0/24',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            if (dialogErr != null) ...[
              const SizedBox(height: 8),
              Text(
                dialogErr!,
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
        onPressed: importing ? null : () => Navigator.pop(context, false),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: importing
            ? null
            : () async {
                final raw = confCtrl.text.trim();
                if (raw.isEmpty) {
                  setState(
                    () => dialogErr = 'Choose or paste a WireGuard .conf file.',
                  );
                  return;
                }
                setState(() {
                  importing = true;
                  dialogErr = null;
                });
                try {
                  await widget.core.run([
                    'wireguard',
                    'import-conf',
                    '-',
                  ], input: raw);
                  await widget.core.enableWireguard(true);
                  if (mounted) {
                    Navigator.pop(this.context, true);
                  }
                } catch (e) {
                  setState(() {
                    importing = false;
                    dialogErr = '$e';
                  });
                }
              },
        child: Text(importing ? 'Importing…' : 'Import'),
      ),
    ],
  );
}
