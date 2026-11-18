import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'registry.dart';
import 'connection_picker.dart';
import 'device_commands.dart';
import 'phone_files.dart';
import 'folder_exclusions.dart';
import 'folder_name_dialog.dart';

class DeviceDetail extends StatefulWidget {
  const DeviceDetail({
    super.key,
    required this.core,
    required this.peer,
    required this.registry,
  });
  final CoreBridge core;
  final Map<String, dynamic> peer;
  final FeatureRegistry registry;
  @override
  State<DeviceDetail> createState() => _DeviceDetailState();
}

class _DeviceDetailState extends State<DeviceDetail> {
  bool busy = true;
  String? offlineNote;
  String? testingTransport, testedTransport, testMessage;
  bool? testSuccess;
  double? testPingMs;
  List<dynamic> roots = [];
  List<dynamic> tailnetNodes = [];
  List<dynamic> wgPeers = [];
  bool tailnetRunning = false;
  Map<String, dynamic>? route;
  Map<String, dynamic>? connectionCfg;
  @override
  void initState() {
    super.initState();
    load();
  }

  String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('device not discovered on the approved LAN')) {
      return 'Not currently discovered on the approved LAN.';
    }
    final match = RegExp(r'"message":"([^"]+)"').firstMatch(s);
    if (match != null) {
      return match.group(1)!;
    }
    return s;
  }

  Future<void> load() async {
    offlineNote = null;
    try {
      connectionCfg = Map<String, dynamic>.from(
        await widget.core.run(['connection', widget.peer['id'] as String])
            as Map,
      );
    } catch (_) {
      connectionCfg = null;
    }
    try {
      final st = await widget.core.run(['tailnet', 'status']) as Map;
      tailnetRunning = st['state'] == 'Running';
      tailnetNodes = st['peers'] as List? ?? [];
    } catch (_) {
      tailnetRunning = false;
      tailnetNodes = [];
    }
    try {
      final wg = await widget.core.run(['wireguard', 'status']) as Map;
      wgPeers = wg['peers'] as List? ?? [];
    } catch (_) {
      wgPeers = [];
    }
    if (widget.peer['status'] == 'revoked') {
      route = null;
      roots = [];
      offlineNote =
          'This device is revoked. Remove it or re-pair from an active device to reconnect.';
      if (mounted) {
        setState(() => busy = false);
      }
      return;
    }
    try {
      route = Map<String, dynamic>.from(
        await widget.core.run(['resolve', widget.peer['id'] as String]) as Map,
      );
      roots =
          await widget.core.run(['roots', widget.peer['id'] as String]) as List;
    } catch (e) {
      route = null;
      roots = [];
      offlineNote = _friendlyError(e);
    }
    if (mounted) {
      setState(() => busy = false);
    }
  }

  Future<void> selectConnection(
    String transport, {
    String? endpoint,
    bool? remoteApproved,
  }) async {
    setState(() {
      busy = true;
      offlineNote = null;
      testingTransport = transport;
      testSuccess = null;
      testPingMs = null;
      testMessage = 'Testing ${_methodLabel(transport)}…';
    });
    final sw = Stopwatch()..start();
    try {
      final current = connectionCfg ?? <String, dynamic>{};
      await widget.core.run(
        ['connection', widget.peer['id'] as String, '-'],
        input: jsonEncode({
          ...current,
          'transport': transport,
          'endpoint': ?endpoint,
          'remote_approved': ?remoteApproved,
        }),
      );
    } catch (e) {
      offlineNote = _friendlyError(e);
    }
    await load();
    sw.stop();
    if (!mounted) {
      return;
    }
    setState(() {
      testingTransport = null;
      testedTransport = transport;
      if (route != null) {
        final rttNs = route!['rtt'] as num? ?? 0;
        final ms = rttNs > 0
            ? rttNs / 1000000.0
            : sw.elapsedMicroseconds / 1000.0;
        testSuccess = true;
        testPingMs = ms;
        testMessage =
            'Connection successful · Ping ${ms.toStringAsFixed(1)} ms · ${route!['endpoint']}';
      } else {
        testSuccess = false;
        testPingMs = null;
        testMessage =
            'Connection failed · ${offlineNote ?? 'Device not reachable'}';
      }
    });
  }

  Widget? _connectionTrailing(String id) {
    if (testingTransport == id) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (testedTransport == id && testSuccess == true && testPingMs != null) {
      return Text(
        '${testPingMs!.toStringAsFixed(1)} ms',
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (testedTransport == id && testSuccess == false) {
      return Text(
        'Failed',
        style: TextStyle(
          color: Theme.of(context).colorScheme.error,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    return null;
  }

  String routeTitle(String? transport) => switch (transport) {
    'direct-lan-v1' => 'Authenticated direct LAN',
    'wireguard' || 'wireguard-v1' =>
      'WireGuard · ${route!['path_kind'] ?? 'direct-lan/tunnel'}',
    'adb' => 'Authenticated ADB loopback tunnel',
    'ssh' => 'Authenticated SSH loopback tunnel',
    _ => 'Tailscale · ${route!['path_kind'] ?? 'unknown'}',
  };

  String _methodLabel(String transport) => switch (transport) {
    'direct-lan-v1' || 'lan' => 'Direct Wi-Fi LAN',
    'tailnet' => 'Tailscale',
    'wireguard' || 'wireguard-v1' => 'WireGuard',
    'adb' => 'USB / Wireless ADB',
    'ssh' => 'SSH tunnel',
    _ => transport,
  };

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
    final effectiveTransport =
        (route?['transport'] as String?) ?? activeTransport;
    final addresses = widget.peer['addresses'] as List? ?? const [];
    final isRevoked = widget.peer['status'] == 'revoked';
    final adbEp = connectionCfg?['adb_endpoint'] as String?;
    final sshEp = connectionCfg?['ssh_endpoint'] as String?;
    final wgEp = connectionCfg?['wireguard_endpoint'] as String?;
    final fallbacks = (connectionCfg?['fallback_transports'] as List? ?? const [])
        .whereType<String>()
        .toList();
    final peerLower = '${widget.peer['name'] ?? ''}'.trim().toLowerCase();
    String? tailnetEp;
    if (tailnetRunning) {
      String? fallbackTailnetEp;
      for (final node in tailnetNodes) {
        if (node['online'] != true) {
          continue;
        }
        final ips = (node['ips'] as List? ?? const [])
            .whereType<String>()
            .where((ip) => !ip.contains(':'));
        if (ips.isEmpty) {
          continue;
        }
        final ep = '${ips.first}:8731';
        final nodeName = '${node['name'] ?? ''}'.trim().toLowerCase();
        if (peerLower.isNotEmpty &&
            nodeName.isNotEmpty &&
            (nodeName == peerLower ||
                nodeName.contains(peerLower) ||
                peerLower.contains(nodeName))) {
          tailnetEp = ep;
          break;
        }
        fallbackTailnetEp ??= ep;
      }
      if (tailnetEp == null &&
          tailnetNodes.where((n) => n['online'] == true).length == 1) {
        tailnetEp = fallbackTailnetEp;
      }
    }
    if (tailnetEp == null &&
        activeTransport == 'tailnet' &&
        '${connectionCfg?['endpoint'] ?? ''}'.isNotEmpty) {
      tailnetEp = connectionCfg!['endpoint'] as String;
    }
    String? wgPeerEp;
    for (final p in wgPeers) {
      final ep = '${p['endpoint'] ?? p['tunnel_ip'] ?? ''}'.trim();
      if (ep.isNotEmpty) {
        wgPeerEp = ep.contains(':') ? ep : '$ep:8731';
        break;
      }
    }
    String? lanSavedEp;
    String? loopbackEp;
    for (final addr in addresses) {
      final ep = '${addr['endpoint'] ?? ''}'.trim();
      if (ep.startsWith('127.0.0.1:')) {
        loopbackEp ??= ep;
      } else if (ep.isNotEmpty) {
        lanSavedEp ??= ep;
      }
    }
    final localIface = '${widget.core.network?['interface'] ?? ''}';
    final localKind = '${widget.core.network?['kind'] ?? ''}';
    final lanTitle = (localKind == 'wifi_direct' || localIface.startsWith('p2p'))
        ? 'Wi-Fi Direct'
        : ((localKind == 'hotspot' ||
                  localIface.startsWith('ap') ||
                  localIface.startsWith('swlan') ||
                  localIface.startsWith('rndis'))
              ? 'Mobile Hotspot'
              : 'Direct Wi-Fi LAN');
    final lanTargetIp =
        (route?['transport'] == 'direct-lan-v1'
            ? route!['endpoint'] as String?
            : null) ??
        lanSavedEp ??
        'Discovered on ${localIface.isNotEmpty ? localIface : 'LAN'}';
    final canLan =
        widget.core.network != null ||
        lanSavedEp != null ||
        activeTransport == 'lan';
    final canTailscale = tailnetEp != null || activeTransport == 'tailnet';
    final effectiveWgEp = (wgEp != null && wgEp.isNotEmpty) ? wgEp : wgPeerEp;
    final canWireguard =
        effectiveWgEp != null || activeTransport == 'wireguard';
    final effectiveAdbEp = (adbEp != null && adbEp.isNotEmpty)
        ? adbEp
        : loopbackEp;
    final canAdb = effectiveAdbEp != null || activeTransport == 'adb';
    final canSsh =
        (sshEp != null && sshEp.isNotEmpty) || activeTransport == 'ssh';
    final activeEndpoint =
        (route?['endpoint'] as String?) ??
        (connectionCfg?['endpoint'] as String?) ??
        (addresses.isNotEmpty ? '${addresses.first['endpoint']}' : null);
    String? defaultHost = _hostFromEndpoint(route?['endpoint']);
    if (defaultHost == null) {
      for (final addr in addresses) {
        defaultHost = _hostFromEndpoint(addr['endpoint']);
        if (defaultHost != null) {
          break;
        }
      }
    }
    defaultHost ??= _hostFromEndpoint(tailnetEp);
    final recordedSpeed =
        (route?['mib_per_second'] as num?) ??
        (connectionCfg?['last_mib_per_second'] as num?) ??
        0;
    final caps = widget.registry.available(['remote-files-v1']).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.peer['name']}'),
        actions: [
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
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (route != null || !busy)
            Card(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      leading: Icon(
                        route != null
                            ? Icons.verified_user_outlined
                            : (isRevoked
                                  ? Icons.block_outlined
                                  : Icons.wifi_off_outlined),
                      ),
                      title: Text(
                        route != null
                            ? routeTitle(route!['transport'] as String?)
                            : (isRevoked
                                  ? 'Device revoked'
                                  : 'Device not currently reachable'),
                      ),
                      subtitle: Text(
                        route != null
                            ? '${route!['endpoint']}${route!['interface'] != null && '${route!['interface']}'.isNotEmpty ? ' · ${route!['interface']}' : ''}\nHandshake ${((route!['rtt'] as num) / 1000000).toStringAsFixed(1)} ms · Speed ${recordedSpeed > 0 ? '${recordedSpeed.toStringAsFixed(2)} MiB/s' : '—'}'
                            : (offlineNote ??
                                  'Not currently reachable on the selected connection.'),
                      ),
                      trailing: route == null && !isRevoked
                          ? TextButton(
                              onPressed: () {
                                setState(() => busy = true);
                                load();
                              },
                              child: const Text('Retry'),
                            )
                          : null,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Connection details',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            'Method: ${_methodLabel(effectiveTransport)} · TLS 1.3 mTLS',
                          ),
                          if (activeEndpoint != null &&
                              activeEndpoint.isNotEmpty)
                            SelectableText('Endpoint: $activeEndpoint'),
                          if (route?['interface'] != null &&
                              '${route!['interface']}'.isNotEmpty)
                            SelectableText(
                              'Interface: ${route!['interface']}',
                            ),
                          if (route?['path_kind'] != null)
                            SelectableText('Path: ${route!['path_kind']}'),
                          if (recordedSpeed > 0 && route == null)
                            SelectableText(
                              'Last speed: ${recordedSpeed.toStringAsFixed(2)} MiB/s',
                            ),
                          if (fallbacks.isNotEmpty)
                            SelectableText(
                              'Fallbacks: ${fallbacks.map(_methodLabel).join(', ')}',
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
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
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Available connections',
                            style: Theme.of(context).textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  final changed = await showDialog<bool>(
                                    context: context,
                                    builder: (_) => ConnectionPicker(
                                      core: widget.core,
                                      peer: widget.peer['id'] as String,
                                    ),
                                  );
                                  if (changed == true) {
                                    setState(() => busy = true);
                                    await load();
                                  }
                                },
                          child: const Text('Custom…'),
                        ),
                      ],
                    ),
                  ),
                  if (testingTransport != null)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: LinearProgressIndicator(),
                    ),
                  if (testMessage != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(
                        children: [
                          Icon(
                            testSuccess == true
                                ? Icons.check_circle_outline
                                : (testSuccess == false
                                      ? Icons.error_outline
                                      : Icons.sync),
                            size: 18,
                            color: testSuccess == true
                                ? Theme.of(context).colorScheme.primary
                                : (testSuccess == false
                                      ? Theme.of(context).colorScheme.error
                                      : null),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: SelectableText(
                              testMessage!,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (canLan)
                    ListTile(
                      leading: Icon(
                        activeTransport == 'lan'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(lanTitle),
                      subtitle: Text(lanTargetIp),
                      trailing: _connectionTrailing('lan'),
                      onTap: busy ? null : () => selectConnection('lan'),
                    ),
                  if (canTailscale)
                    ListTile(
                      leading: Icon(
                        activeTransport == 'tailnet'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: const Text('Tailscale'),
                      subtitle: Text(
                        tailnetEp ?? 'Tailscale peer unavailable',
                      ),
                      trailing: _connectionTrailing('tailnet'),
                      onTap: busy || tailnetEp == null
                          ? null
                          : () => selectConnection(
                              'tailnet',
                              endpoint: tailnetEp,
                              remoteApproved: true,
                            ),
                    ),
                  if (canWireguard)
                    ListTile(
                      leading: Icon(
                        activeTransport == 'wireguard'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: const Text('WireGuard'),
                      subtitle: Text(effectiveWgEp ?? 'Configured tunnel'),
                      trailing: _connectionTrailing('wireguard'),
                      onTap: busy || effectiveWgEp == null
                          ? null
                          : () => selectConnection(
                              'wireguard',
                              endpoint: effectiveWgEp,
                            ),
                    ),
                  if (canAdb)
                    ListTile(
                      leading: Icon(
                        activeTransport == 'adb'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: const Text('USB / Wireless ADB'),
                      subtitle: Text(effectiveAdbEp ?? 'ADB loopback tunnel'),
                      trailing: _connectionTrailing('adb'),
                      onTap: busy || effectiveAdbEp == null
                          ? null
                          : () => selectConnection(
                              'adb',
                              endpoint: effectiveAdbEp,
                            ),
                    ),
                  if (canSsh)
                    ListTile(
                      leading: Icon(
                        activeTransport == 'ssh'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: const Text('SSH tunnel'),
                      subtitle: Text(sshEp ?? 'Configured SSH tunnel'),
                      trailing: _connectionTrailing('ssh'),
                      onTap: busy || sshEp == null
                          ? null
                          : () => selectConnection(
                              'ssh',
                              endpoint: sshEp,
                            ),
                    ),
                  if (!canLan &&
                      !canTailscale &&
                      !canWireguard &&
                      !canAdb &&
                      !canSsh)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Text(
                        'No active connection path detected. Use Custom… to configure a tunnel.',
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          DeviceCommandsSection(
            core: widget.core,
            peer: widget.peer,
            defaultHost: defaultHost,
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Saved addresses',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final addr in addresses)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: SelectableText('LAN ${addr['endpoint']}'),
                    ),
                  if (addresses.isEmpty)
                    const Text('No saved addresses yet.'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Device details',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SelectableText('Name: ${widget.peer['name']}'),
                  const SizedBox(height: 4),
                  SelectableText('Status: ${widget.peer['status']}'),
                  const SizedBox(height: 4),
                  SelectableText(
                    'Capabilities: ${caps.isEmpty ? 'remote-files-v1' : caps.map((c) => '${c.label} (${c.id})').join(', ')}',
                  ),
                  const SizedBox(height: 6),
                  SelectableText('Fingerprint\n${widget.peer['id']}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              if (widget.peer['status'] != 'revoked')
                OutlinedButton(
                  onPressed: busy ? null : revoke,
                  child: const Text('Revoke device'),
                ),
              OutlinedButton(
                onPressed: busy ? null : remove,
                child: const Text('Remove device'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> remove() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this device?'),
        content: const Text(
          'Grants, cached addresses and saved connection settings for this device will be deleted.',
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

  Future<void> revoke() async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Revoke this device?'),
        content: const Text('Future connections and reads will be denied.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (approved == true) {
      try {
        await widget.core.run(['revoke', widget.peer['id'] as String]);
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
    required this.root,
    required this.path,
  });
  final CoreBridge core;
  final Map<String, dynamic> peer;
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
  Map<String, dynamic>? liveProgress;
  StreamSubscription<Map<String, dynamic>>? progressSub;

  late String sourcePath;
  bool showHidden = false;
  String activeSide = 'source';
  String preferredMethod = 'auto'; // 'auto' | 'tar'
  Map<String, dynamic>? connectionConfig;
  Map<String, dynamic>? resolvedRoute;
  Map<String, dynamic>? interruptedPull;
  bool hoverTargetPane = false;
  String? hoverTargetEntryId;

  // Target pane state: 'downloads' | 'local' | 'termux'
  String targetMode = 'downloads';
  bool get usingTargetSaf => Platform.isAndroid && targetMode == 'termux';
  bool get targetPermissionMissing =>
      Platform.isAndroid && targetMode == 'local' && !allFilesAccess;
  late String targetPosixPath;
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
      if (!mounted) {
        return;
      }
      setState(() {
        if (p['route_switched'] == true) {
          routeNotice =
              'Route disrupted · resumed over ${connectionDisplayName('${p['to'] ?? ''}')} (${p['endpoint']})';
        } else {
          liveProgress = p;
        }
      });
    });
    loadBrowserSettings();
    loadSource();
    loadActiveRoute();
    loadTargetCapabilities();
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
        return 'USB / Wireless ADB';
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
      if (targetMode == 'local' && Platform.isAndroid && allFilesAccess) {
        if (!targetPosixPath.startsWith('/storage/')) {
          targetPosixPath = '/storage/emulated/0';
        }
      } else if (targetMode == 'termux' && Platform.isAndroid) {
        targetSafUri = caps['termux_tree_uri'] as String?;
        targetSafName = caps['termux_tree_name'] as String?;
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
    if (mode == 'local') {
      targetPosixPath = '/storage/emulated/0';
      targetSafUri = null;
      if (!allFilesAccess) {
        await widget.core.openConnectionSetup('all_files_access');
        await loadTargetCapabilities();
        return;
      }
    } else if (mode == 'termux') {
      targetSafUri = caps['termux_tree_uri'] as String?;
      targetSafName = caps['termux_tree_name'] as String?;
      if (targetSafUri == null) {
        final picked = await widget.core.pickTargetTree(termux: true);
        if (picked != null) {
          targetSafUri = picked['uri'] as String?;
          targetSafName = picked['name'] as String?;
        }
      }
    }
    await loadTarget();
  }

  Future<void> pickTargetFolder({required bool termux}) async {
    final picked = await widget.core.pickTargetTree(termux: termux);
    if (picked != null && mounted) {
      setState(() {
        targetSafUri = picked['uri'] as String?;
        targetSafName = picked['name'] as String?;
        safStack.clear();
      });
      await loadTarget();
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
      setState(
        () => error =
            'Select a target ${targetMode == 'termux' ? 'Termux' : 'SAF'} folder in the Target pane first.',
      );
      return;
    }
    final destPosixDir = targetDirOverride ?? targetPosixPath;
    final destSafDoc =
        targetDocOverride ?? (safStack.isEmpty ? null : safStack.last);
    final baseSafLabel =
        '${targetMode == 'termux' ? 'Termux' : 'SAF'}: ${targetSafName ?? 'selected folder'}';
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
      error = null;
      interruptedPull = null;
      routeNotice = null;
      liveProgress = null;
      receivedMiB = null;
      receivedMode = null;
      receivedTransport = null;
    });
    final cmd = preferredMethod == 'tar' ? 'pull-tar' : 'pull';
    try {
      final phoneStorageTarget = Platform.isAndroid && targetMode == 'local';
      final destination = (usingSaf || phoneStorageTarget)
          ? '${widget.core.downloads}/$name-${DateTime.now().millisecondsSinceEpoch}'
          : '$destPosixDir/$name';
      final receipt = await widget.core.run([
        cmd,
        widget.peer['id'] as String,
        widget.root,
        path,
        destination,
        ...selectedExclusions,
      ]) as Map;
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
      error = e.toString();
      interruptedPull = {
        'path': path,
        'name': name,
        'targetDir': destPosixDir,
        'targetDoc': destSafDoc,
        'targetLabel': targetLabel,
        'excludes': selectedExclusions,
      };
    }
    if (mounted) {
      setState(() {
        busy = false;
        liveProgress = null;
      });
    }
  }

  Future<void> continueInterruptedOn(String transport) async {
    final pending = interruptedPull;
    if (pending == null || busy) {
      return;
    }
    final peerId = widget.peer['id'] as String;
    final currentCfg = Map<String, dynamic>.from(connectionConfig ?? {});
    String endpoint = '';
    bool remoteApproved = currentCfg['remote_approved'] == true;
    if (transport == 'adb') {
      endpoint = (currentCfg['adb_endpoint'] as String? ?? '').isNotEmpty
          ? currentCfg['adb_endpoint'] as String
          : '127.0.0.1:8731';
    } else if (transport == 'ssh') {
      endpoint = (currentCfg['ssh_endpoint'] as String? ?? '').isNotEmpty
          ? currentCfg['ssh_endpoint'] as String
          : '127.0.0.1:8731';
    } else if (transport == 'tailnet') {
      endpoint = currentCfg['endpoint'] as String? ?? '';
      remoteApproved = true;
    } else if (transport == 'wireguard') {
      endpoint = currentCfg['wireguard_endpoint'] as String? ?? '';
      if (endpoint.isEmpty && currentCfg['transport'] == 'wireguard') {
        endpoint = currentCfg['endpoint'] as String? ?? '';
      }
      remoteApproved = true;
    }
    if ((transport == 'adb' ||
            transport == 'ssh' ||
            transport == 'tailnet' ||
            transport == 'wireguard') &&
        endpoint.isEmpty) {
      final changed = await showDialog<bool>(
        context: context,
        builder: (_) => ConnectionPicker(core: widget.core, peer: peerId),
      );
      if (changed != true) {
        return;
      }
      await loadActiveRoute();
    } else {
      final updated = <String, dynamic>{
        ...currentCfg,
        'peer_id': peerId,
        'transport': transport,
        'endpoint': transport == 'lan' ? '' : endpoint,
        'remote_approved': remoteApproved,
        'fallback_approved': currentCfg['fallback_approved'] == true,
        'fallback_transports': currentCfg['fallback_transports'] ?? <String>[],
        if (transport == 'adb') 'adb_endpoint': endpoint,
        if (transport == 'ssh') 'ssh_endpoint': endpoint,
      };
      try {
        await widget.core.run([
          'connection',
          peerId,
          '-',
        ], input: jsonEncode(updated));
        await loadActiveRoute();
      } catch (e) {
        if (mounted) {
          setState(() => error = e.toString());
        }
        return;
      }
    }
    if (!mounted) {
      return;
    }
    await pull(
      pending['path'] as String,
      targetDirOverride: pending['targetDir'] as String?,
      targetDocOverride: pending['targetDoc'] as String?,
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
      leading: Icon(
        isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
        size: 18,
      ),
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
          ? IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: busy ? null : () => pull(map['path'] as String),
              icon: const Icon(Icons.download_outlined, size: 18),
              tooltip: 'Pull to target',
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
        leading: Icon(
          isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
          size: 18,
        ),
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
        (targetMode == 'local' &&
            targetPosixPath != widget.core.homeDir &&
            targetPosixPath != '/' &&
            (!Platform.isAndroid ||
                targetPosixPath != '/storage/emulated/0')) ||
        (usingTargetSaf && safStack.isNotEmpty);
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
                            : targetMode == 'termux'
                            ? 'Termux'
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
                  ],
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Row(
                  children: [
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
                    ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        Platform.isAndroid ? 'Phone storage' : 'Home',
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: targetMode == 'local',
                      onSelected: (_) => switchTargetMode('local'),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      label: const Text(
                        'Termux Storage',
                        style: TextStyle(fontSize: 11),
                      ),
                      selected: targetMode == 'termux',
                      onSelected: (_) => switchTargetMode('termux'),
                    ),
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
                    'Drop to pull into ${targetMode == 'downloads' ? 'Downloads' : targetSafName ?? targetMode}',
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
                    onPressed: () =>
                        pickTargetFolder(termux: targetMode == 'termux'),
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: Text(
                      targetMode == 'termux'
                          ? 'Grant Termux folder via SAF'
                          : 'Choose target folder',
                      style: const TextStyle(fontSize: 12),
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
                  builder: (_) => PhoneFiles(
                    core: widget.core,
                    remotePeer: widget.peer,
                    remoteRoot: widget.root,
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
                          final changed = await showDialog<bool>(
                            context: context,
                            builder: (_) => ConnectionPicker(
                              core: widget.core,
                              peer: widget.peer['id'] as String,
                            ),
                          );
                          if (changed == true) {
                            await loadActiveRoute();
                          }
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
          if (busy && liveProgress != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                '${(((liveProgress!['verified_bytes'] as num? ?? 0)) / (1024 * 1024)).toStringAsFixed(1)} / ${(((liveProgress!['total_bytes'] as num? ?? 0)) / (1024 * 1024)).toStringAsFixed(1)} MiB · ${((liveProgress!['mib_per_second'] as num? ?? 0)).toStringAsFixed(2)} MiB/s · Method: $liveMethodLabel · Via: $liveViaLabel · ${liveProgress!['file'] ?? ''}',
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
                      'Connection interrupted pulling "${interruptedPull!['name']}" — continue on another connection:',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final opt in [
                          ('lan', 'Wi-Fi / Direct LAN'),
                          ('wireguard', 'WireGuard'),
                          ('adb', 'USB / Wireless ADB'),
                          ('ssh', 'SSH Tunnel'),
                          ('tailnet', 'Tailscale'),
                        ])
                          OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => continueInterruptedOn(opt.$1),
                            icon: const Icon(Icons.alt_route, size: 15),
                            label: Text('Continue on ${opt.$2}'),
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
