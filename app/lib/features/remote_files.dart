import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'registry.dart';
import 'connection_picker.dart';

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
  String? error;
  List<dynamic> roots = [];
  Map<String, dynamic>? route;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      route = Map<String, dynamic>.from(
        await widget.core.run(['resolve', widget.peer['id'] as String]) as Map,
      );
      roots =
          await widget.core.run(['roots', widget.peer['id'] as String]) as List;
    } catch (e) {
      error = e.toString();
    }
    if (mounted) {
      setState(() => busy = false);
    }
  }

  String routeTitle(String? transport) => switch (transport) {
    'direct-lan-v1' => 'Authenticated direct LAN',
    'wireguard' || 'wireguard-v1' =>
      'WireGuard · ${route!['path_kind'] ?? 'direct-lan/tunnel'}',
    'adb' => 'Authenticated ADB loopback tunnel',
    'ssh' => 'Authenticated SSH loopback tunnel',
    _ => 'Tailscale · ${route!['path_kind'] ?? 'unknown'}',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${widget.peer['name']}'),
      actions: [
        IconButton(
          tooltip: 'Choose connection',
          onPressed: () async {
            final changed = await showDialog<bool>(
              context: context,
              builder: (_) => ConnectionPicker(
                core: widget.core,
                peer: widget.peer['id'] as String,
              ),
            );
            if (changed == true) {
              setState(() {
                busy = true;
                error = null;
              });
              await load();
            }
          },
          icon: const Icon(Icons.settings_ethernet),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (busy) const LinearProgressIndicator(),
        if (error != null) SelectableText(error!),
        if (route != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(routeTitle(route!['transport'] as String?)),
              subtitle: Text(
                '${route!['endpoint']} · ${route!['interface'] ?? ''}\nHandshake ${((route!['rtt'] as num) / 1000000).toStringAsFixed(1)} ms\nTransfer speed: ${((route!['mib_per_second'] as num? ?? 0) > 0) ? '${(route!['mib_per_second'] as num).toStringAsFixed(2)} MiB/s' : '— MiB/s (measure during a transfer)'}',
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text('Approved folders', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        if (!busy && roots.isEmpty && error == null)
          const Text('This device has not granted access to any folders.'),
        for (final feature in widget.registry.available(
          roots.isEmpty ? [] : ['remote-files-v1'],
        ))
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
        const SizedBox(height: 24),
        SelectableText('Device fingerprint\n${widget.peer['id']}'),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
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
          setState(() => error = e.toString());
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
          setState(() => error = e.toString());
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

class _FileBrowserState extends State<FileBrowser> {
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
  late String targetPosixPath;
  String? targetSafUri;
  String? targetSafName;
  final List<String> safStack = [];
  List<Map<String, dynamic>> targetEntries = [];
  String? targetError;
  bool targetBusy = false;

  @override
  void initState() {
    super.initState();
    sourcePath = widget.path;
    targetPosixPath = widget.core.downloads;
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
    loadSource();
    loadActiveRoute();
    loadTargetCapabilities();
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
    progressSub?.cancel();
    super.dispose();
  }

  Future<void> loadTargetCapabilities() async {
    try {
      final caps = await widget.core.platformCapabilities();
      if (targetMode == 'local' && Platform.isAndroid) {
        targetSafUri = caps['saf_tree_uri'] as String?;
        targetSafName = caps['saf_tree_name'] as String?;
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
    if (mode == 'local') {
      targetSafUri = caps['saf_tree_uri'] as String?;
      targetSafName = caps['saf_tree_name'] as String?;
      if (targetSafUri == null) {
        final picked = await widget.core.pickTargetTree(termux: false);
        if (picked != null) {
          targetSafUri = picked['uri'] as String?;
          targetSafName = picked['name'] as String?;
        }
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
      if (targetMode == 'downloads' || !Platform.isAndroid) {
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
      final page =
          await widget.core.run([
                'list',
                widget.peer['id'] as String,
                widget.root,
                sourcePath,
                more ? next : '',
              ])
              as Map;
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
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New target folder'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || name.contains('/')) {
      return;
    }
    try {
      if (targetMode == 'downloads' || !Platform.isAndroid) {
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
  }) async {
    final name = path == '.' ? widget.root : path.split('/').last;
    final usingSaf = Platform.isAndroid && targetMode != 'downloads';
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
        ? (targetSubLabel == null ? baseSafLabel : '$baseSafLabel/$targetSubLabel')
        : destPosixDir;
    if (!skipConfirm) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Pull $name?'),
          content: Text(
            'Download a verified copy into:\n$targetLabel\n\nExisting files will not be overwritten. This does not enable synchronization.',
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
      final destination = usingSaf
          ? '${widget.core.downloads}/$name-${DateTime.now().millisecondsSinceEpoch}'
          : '$destPosixDir/$name';
      final receipt =
          await widget.core.run([
                cmd,
                widget.peer['id'] as String,
                widget.root,
                path,
                destination,
              ])
              as Map;
      if (usingSaf && targetSafUri != null) {
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
      await loadTarget();
    } catch (e) {
      error = e.toString();
      interruptedPull = {
        'path': path,
        'name': name,
        'targetDir': destPosixDir,
        'targetDoc': destSafDoc,
        'targetLabel': targetLabel,
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
      endpoint =
          (currentCfg['adb_endpoint'] as String? ?? '').isNotEmpty
          ? currentCfg['adb_endpoint'] as String
          : '127.0.0.1:8731';
    } else if (transport == 'ssh') {
      endpoint =
          (currentCfg['ssh_endpoint'] as String? ?? '').isNotEmpty
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
        'peer_id': peerId,
        'transport': transport,
        'endpoint': transport == 'lan' ? '' : endpoint,
        'remote_approved': remoteApproved,
        'fallback_approved': true,
        'fallback_transports': ['lan', 'adb', 'ssh', if (remoteApproved) 'tailnet'],
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
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
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
    final rowId = (e['document_id'] as String?) ?? (e['path'] as String?) ?? '${e['name']}';
    final isHovered = hoverTargetEntryId == rowId;
    final tile = Container(
      decoration: isHovered
          ? BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
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
          if (Platform.isAndroid && targetMode != 'downloads') {
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
        if (Platform.isAndroid && targetMode != 'downloads') {
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
        (targetMode == 'downloads' && targetPosixPath != widget.core.downloads) ||
        (targetMode == 'local' &&
            !Platform.isAndroid &&
            targetPosixPath != widget.core.homeDir &&
            targetPosixPath != '/') ||
        (Platform.isAndroid && targetMode != 'downloads' && safStack.isNotEmpty);
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
                        'Target · ${targetMode == 'downloads' ? 'Downloads' : targetMode == 'termux' ? 'Termux' : 'Local'}',
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
                                if (Platform.isAndroid &&
                                    targetMode != 'downloads') {
                                  safStack.removeLast();
                                } else {
                                  targetPosixPath = Directory(
                                    targetPosixPath,
                                  ).parent.path;
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
                      onPressed: targetBusy ? null : createNewTargetFolder,
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
                      label: const Text('Downloads', style: TextStyle(fontSize: 11)),
                      selected: targetMode == 'downloads',
                      onSelected: (_) => switchTargetMode('downloads'),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(
                        Platform.isAndroid ? 'SAF Folder' : 'Home',
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
              if (targetBusy) const LinearProgressIndicator(),
              if (candidateData.isNotEmpty)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                  child: Text(targetError!, style: const TextStyle(fontSize: 12)),
                ),
              if (Platform.isAndroid &&
                  targetMode != 'downloads' &&
                  targetSafUri == null)
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
          IconButton(
            tooltip: showHidden ? 'Hide hidden files' : 'Show hidden files',
            icon: Icon(
              showHidden ? Icons.visibility : Icons.visibility_off_outlined,
            ),
            onPressed: () => setState(() => showHidden = !showHidden),
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
                  label: const Text('Force TAR', style: TextStyle(fontSize: 11)),
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
              child: SelectableText(error!, style: const TextStyle(fontSize: 12)),
            ),
          if (received != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                children: [
                  Text(
                    'Verified download${receivedMode == 'tar' ? ' (streaming tar)' : receivedMode == 'stream' ? ' (TCP stream)' : ' (direct)'}\n${received!.split('/').last}\nVia ${connectionDisplayName(receivedTransport ?? 'lan')}${receivedMiB != null && receivedMiB! > 0 ? ' · ${receivedMiB!.toStringAsFixed(2)} MiB/s' : ''}',
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
