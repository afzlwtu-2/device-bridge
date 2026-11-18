import 'dart:async';
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
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => FileBrowser(
                            core: widget.core,
                            peer: widget.peer,
                            root: root['id'] as String,
                            path: '.',
                          ),
                        ),
                      ),
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
  String? routeNotice;
  Map<String, dynamic>? liveProgress;
  StreamSubscription<Map<String, dynamic>>? progressSub;

  late String sourcePath;
  bool showHidden = false;

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
              'Route disrupted · resumed over ${p['to']} (${p['endpoint']})';
        } else {
          liveProgress = p;
        }
      });
    });
    loadSource();
    loadTargetCapabilities();
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

  Future<void> pull(String path) async {
    final name = path == '.' ? widget.root : path.split('/').last;
    final usingSaf = Platform.isAndroid && targetMode != 'downloads';
    if (usingSaf && targetSafUri == null) {
      setState(
        () => error =
            'Select a target ${targetMode == 'termux' ? 'Termux' : 'SAF'} folder in the Target pane first.',
      );
      return;
    }
    final targetLabel = usingSaf
        ? '${targetMode == 'termux' ? 'Termux' : 'SAF'}: ${targetSafName ?? 'selected folder'}'
        : targetPosixPath;
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
    setState(() {
      busy = true;
      error = null;
      routeNotice = null;
      liveProgress = null;
      receivedMiB = null;
      receivedMode = null;
    });
    try {
      final destination = usingSaf
          ? '${widget.core.downloads}/$name-${DateTime.now().millisecondsSinceEpoch}'
          : '$targetPosixPath/$name';
      final receipt =
          await widget.core.run([
                'pull',
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
          documentId: safStack.isEmpty ? null : safStack.last,
        );
        received = '${targetSafName ?? targetMode}/$name';
      } else {
        received = destination;
      }
      receivedMiB = (receipt['mib_per_second'] as num?)?.toDouble();
      receivedMode = receipt['mode'] as String?;
      await loadTarget();
    } catch (e) {
      error = e.toString();
    }
    if (mounted) {
      setState(() {
        busy = false;
        liveProgress = null;
      });
    }
  }

  String metadata(Map<dynamic, dynamic> entry) {
    final bytes = (entry['size'] as num? ?? 0).toInt();
    final size = bytes < 1024
        ? '$bytes B'
        : bytes < 1024 * 1024
        ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
        : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    final modified = DateTime.tryParse(entry['modified'] as String? ?? '')
        ?.toLocal();
    if (modified == null) {
      return size;
    }
    final locale = MaterialLocalizations.of(context);
    return '$size · ${locale.formatShortDate(modified)} ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(modified))}';
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

  Widget sourcePane() {
    final visibleEntries = entries
        .where((e) => _visibleName('${e['name']}'))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              const Icon(Icons.devices, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Source · ${widget.peer['name']} · ${widget.root}/$sourcePath',
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (sourcePath != '.')
                IconButton(
                  tooltip: 'Source parent folder',
                  icon: const Icon(Icons.arrow_upward, size: 18),
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
        Expanded(
          child: ListView(
            children: [
              for (final e in visibleEntries)
                ListTile(
                  dense: true,
                  leading: Icon(
                    e['kind'] == 'directory'
                        ? Icons.folder_outlined
                        : Icons.insert_drive_file_outlined,
                  ),
                  title: Text('${e['name']}'),
                  subtitle: Text(
                    e['kind'] == 'file' ? metadata(e as Map) : '${e['kind']}',
                  ),
                  onTap: busy || e['kind'] != 'directory'
                      ? null
                      : () {
                          sourcePath = e['path'] as String;
                          loadSource();
                        },
                  trailing: e['kind'] == 'file' || e['kind'] == 'directory'
                      ? IconButton(
                          onPressed: busy
                              ? null
                              : () => pull(e['path'] as String),
                          icon: const Icon(Icons.download_outlined),
                          tooltip: 'Pull to target',
                        )
                      : null,
                ),
              if (next.isNotEmpty)
                TextButton(
                  onPressed: busy ? null : () => loadSource(more: true),
                  child: const Text('Load more'),
                ),
            ],
          ),
        ),
      ],
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              const Icon(Icons.save_alt, size: 18),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Target · This device (${targetMode == 'downloads' ? 'App downloads' : targetMode == 'termux' ? 'Termux' : 'Local'})',
                  style: Theme.of(context).textTheme.titleSmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (canGoUp)
                IconButton(
                  tooltip: 'Target parent folder',
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: targetBusy
                      ? null
                      : () {
                          if (Platform.isAndroid && targetMode != 'downloads') {
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
                tooltip: 'New folder',
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                onPressed: targetBusy ? null : createNewTargetFolder,
              ),
            ],
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('Downloads'),
                selected: targetMode == 'downloads',
                onSelected: (_) => switchTargetMode('downloads'),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text(Platform.isAndroid ? 'SAF Folder' : 'Home'),
                selected: targetMode == 'local',
                onSelected: (_) => switchTargetMode('local'),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Termux Storage'),
                selected: targetMode == 'termux',
                onSelected: (_) => switchTargetMode('termux'),
              ),
            ],
          ),
        ),
        if (targetBusy) const LinearProgressIndicator(),
        if (targetError != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(targetError!),
          ),
        if (Platform.isAndroid &&
            targetMode != 'downloads' &&
            targetSafUri == null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: OutlinedButton.icon(
              onPressed: () => pickTargetFolder(termux: targetMode == 'termux'),
              icon: const Icon(Icons.folder_open),
              label: Text(
                targetMode == 'termux'
                    ? 'Grant Termux folder via SAF'
                    : 'Choose target folder',
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
                    title: Text('Target folder is empty'),
                  ),
                for (final e in visibleTargets)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      e['kind'] == 'directory'
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                    ),
                    title: Text('${e['name']}'),
                    subtitle: Text(
                      e['kind'] == 'file' ? metadata(e) : 'folder',
                    ),
                    onTap: e['kind'] != 'directory'
                        ? null
                        : () {
                            if (Platform.isAndroid &&
                                targetMode != 'downloads') {
                              safStack.add(e['document_id'] as String);
                            } else {
                              targetPosixPath = e['path'] as String;
                            }
                            loadTarget();
                          },
                  ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(routeNotice!, textAlign: TextAlign.center),
          ),
        if (busy && liveProgress != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              '${(((liveProgress!['verified_bytes'] as num? ?? 0)) / (1024 * 1024)).toStringAsFixed(1)} / ${(((liveProgress!['total_bytes'] as num? ?? 0)) / (1024 * 1024)).toStringAsFixed(1)} MiB · ${((liveProgress!['mib_per_second'] as num? ?? 0)).toStringAsFixed(2)} MiB/s · ${liveProgress!['file'] ?? ''}',
              textAlign: TextAlign.center,
            ),
          ),
        if (busy)
          TextButton(
            onPressed: widget.core.cancel,
            child: const Text('Cancel operation'),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(error!),
          ),
        if (received != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  'Verified download${receivedMode == 'tar' ? ' (streaming tar)' : ''}\n${received!.split('/').last}\nSaved in DeviceBridge${receivedMiB != null && receivedMiB! > 0 ? ' · ${receivedMiB!.toStringAsFixed(2)} MiB/s' : ''}',
                  textAlign: TextAlign.center,
                ),
                if (targetMode == 'downloads')
                  TextButton(
                    onPressed: () async {
                      try {
                        final saved = await widget.core.saveDownload(received!);
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
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= 720
                ? Row(
                    children: [
                      Expanded(child: sourcePane()),
                      const VerticalDivider(width: 1),
                      Expanded(child: targetPane()),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(child: sourcePane()),
                      const Divider(height: 1),
                      Expanded(child: targetPane()),
                    ],
                  ),
          ),
        ),
      ],
    ),
  );
}
