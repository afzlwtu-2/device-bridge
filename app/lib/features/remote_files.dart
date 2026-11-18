import 'dart:async';

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
              title: Text(
                route!['transport'] == 'direct-lan-v1'
                    ? 'Authenticated direct LAN'
                    : 'Tailscale · ${route!['path_kind'] ?? 'unknown'}',
              ),
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
  Map<String, dynamic>? liveProgress;
  StreamSubscription<Map<String, dynamic>>? progressSub;
  @override
  void initState() {
    super.initState();
    progressSub = widget.core.transferProgress.listen((p) {
      if (mounted) {
        setState(() => liveProgress = p);
      }
    });
    load();
  }

  @override
  void dispose() {
    progressSub?.cancel();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final page = await widget.core.run([
        'list',
        widget.peer['id'] as String,
        widget.root,
        widget.path,
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

  Future<void> pull(String path) async {
    final name = path == '.' ? widget.root : path.split('/').last;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Pull $name?'),
        content: const Text(
          'Download a verified copy over the approved LAN. Existing files will not be overwritten. This does not enable synchronization.',
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
      liveProgress = null;
      receivedMiB = null;
      receivedMode = null;
    });
    try {
      final destination = '${widget.core.downloads}/$name';
      final receipt = await widget.core.run([
        'pull',
        widget.peer['id'] as String,
        widget.root,
        path,
        destination,
      ]) as Map;
      received = destination;
      receivedMiB = (receipt['mib_per_second'] as num?)?.toDouble();
      receivedMode = receipt['mode'] as String?;
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
    final bytes = (entry['size'] as num).toInt();
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.path == '.' ? widget.root : widget.path.split('/').last,
      ),
      actions: [
        IconButton(
          onPressed: busy ? null : () => pull(widget.path),
          icon: const Icon(Icons.download),
          tooltip: 'Pull this folder',
        ),
      ],
    ),
    body: Column(
      children: [
        if (busy)
          LinearProgressIndicator(
            value: liveProgress != null &&
                    ((liveProgress!['total_bytes'] as num? ?? 0) > 0)
                ? ((liveProgress!['verified_bytes'] as num? ?? 0) /
                          (liveProgress!['total_bytes'] as num))
                      .clamp(0.0, 1.0)
                : null,
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
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  'Verified download${receivedMode == 'tar' ? ' (streaming tar)' : ''}\n${received!.split('/').last}\nSaved in DeviceBridge${receivedMiB != null && receivedMiB! > 0 ? ' · ${receivedMiB!.toStringAsFixed(2)} MiB/s' : ''}',
                  textAlign: TextAlign.center,
                ),
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
          child: ListView(
            children: [
              for (final e in entries)
                ListTile(
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
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => FileBrowser(
                              core: widget.core,
                              peer: widget.peer,
                              root: widget.root,
                              path: e['path'] as String,
                            ),
                          ),
                        ),
                  trailing: e['kind'] == 'file' || e['kind'] == 'directory'
                      ? IconButton(
                          onPressed: busy
                              ? null
                              : () => pull(e['path'] as String),
                          icon: const Icon(Icons.download_outlined),
                          tooltip: 'Pull',
                        )
                      : null,
                ),
              if (next.isNotEmpty)
                TextButton(
                  onPressed: busy ? null : () => load(more: true),
                  child: const Text('Load more'),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
