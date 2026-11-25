import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'folder_exclusions.dart';
import 'folder_name_dialog.dart';
import 'registry.dart';
import 'remote_files.dart';
import 'sync_screen.dart';
import 'folder_pair_sync.dart';

class FileManager extends StatefulWidget {
  const FileManager({
    super.key,
    required this.core,
    this.remotePeer,
    this.remoteRoot,
    this.candidates = const [],
    this.embedded = false,
  });
  final CoreBridge core;
  final Map<String, dynamic>? remotePeer;
  final String? remoteRoot;
  final List<dynamic> candidates;
  final bool embedded;
  @override
  State<FileManager> createState() => _FileManagerState();
}

class _Pane {
  String device = 'local', root = 'internal', path = '';
  List<Map<String, dynamic>> roots = [], entries = [];
  String? error;
  bool busy = false;
}

class _FileManagerState extends State<FileManager> with WidgetsBindingObserver {
  final panes = [_Pane(), _Pane()];
  List<Map<String, dynamic>> localRoots = [];
  List<dynamic> peers = [];
  bool transferring = false, showHidden = false;
  String? notice;
  String? hoverFolderKey;
  int? hoverPaneIndex;
  List<Map> syncFolders = [];
  List<Map> syncPairs = [];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.remotePeer != null) {
      panes[0].device = '${widget.remotePeer!['id']}';
      panes[0].root = widget.remoteRoot ?? '';
      panes[0].path = '.';
    }
    initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !transferring) {
      initialize();
    }
  }

  Future<void> initialize() async {
    try {
      final settings = await widget.core.appSettings();
      showHidden = settings['show_hidden'] == true;
      try {
        localRoots = (await widget.core.localFiles('roots', {}) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } catch (_) {
        localRoots = <Map<String, dynamic>>[];
      }
      peers = await widget.core.run(['peers']) as List;
      await readSyncFolders();
      for (final pane in panes) {
        await load(pane, roots: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => notice = '$e');
      }
    }
  }

  Future<void> readSyncFolders() async {
    try {
      final status = await widget.core.run(['syncthing', 'status']) as Map;
      syncFolders = (status['registered'] as List? ?? [])
          .whereType<Map>()
          .toList();
      final pairs = await widget.core.run(['sync-pairs']);
      syncPairs = pairs is List ? pairs.whereType<Map>().toList() : [];
    } catch (_) {
      // The sync manager reports engine errors; file browsing stays available.
      syncFolders = [];
    }
    if (mounted) setState(() {});
  }

  String? syncActivity(_Pane pane, String path) {
    for (final pair in syncPairs) {
      if (pair['state'] == 'draft') continue;
      for (final key in ['source', 'target']) {
        final location = pair[key] as Map;
        if (location['device'] == pane.device &&
            location['root'] == pane.root &&
            (location['path'] == path ||
                ((location['path'] == '' || location['path'] == '.') &&
                    (path == '' || path == '.')))) {
          return '${pair['state'] ?? 'paused'}';
        }
      }
    }
    if (pane.device != 'local') return null;
    final root = pane.roots.where((r) => r['id'] == pane.root).firstOrNull;
    final base = root?['native_path'] as String?;
    if (base == null) return null;
    final native = path.isEmpty || path == '.' ? base : '$base/$path';
    return syncFolders
            .where((entry) => entry['source'] == native)
            .firstOrNull?['activity']
        as String?;
  }

  bool isRecycleBin(_Pane pane) =>
      pane.device == 'local' && pane.root == 'recycle_bin';

  Map? _peerForPane(String id) =>
      peers.whereType<Map>().where((peer) => peer['id'] == id).firstOrNull ??
      (widget.remotePeer?['id'] == id ? widget.remotePeer : null);

  Future<void> _openPaneConnections(_Pane pane) async {
    final id = pane.device;
    final peer = _peerForPane(id);
    if (peer == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DeviceDetail(
          core: widget.core,
          peer: Map<String, dynamic>.from(peer),
          registry: FeatureRegistry()..register(RemoteFilesFeature()),
          candidates: widget.candidates,
        ),
      ),
    );
    if (mounted && pane.device == id) await load(pane, roots: true);
  }

  bool supportsFolderSync(_Pane pane) {
    if (pane.root.isEmpty || isRecycleBin(pane)) return false;
    if (pane.device != 'local') return true;
    return pane.roots.any(
      (root) =>
          root['id'] == pane.root &&
          root['available'] == true &&
          root['native_path'] != null,
    );
  }

  Future<void> syncFolder(_Pane pane, String path, String name) async {
    if (!supportsFolderSync(pane)) return;
    try {
      String? localPath;
      if (pane.device == 'local') {
        final location = await widget.core.localFiles('sync-location', {
          'kind': pane.root,
          'path': path,
        }) as Map;
        localPath = location['path'] as String;
      }
      if (!mounted) return;
      final source = SyncLocation(
        device: pane.device,
        name: deviceName(pane),
        root: pane.root,
        path: path,
        localPath: localPath,
      );
      final other = panes[1 - panes.indexOf(pane)];
      SyncLocation? target;
      if (other.device != pane.device &&
          supportsFolderSync(other) &&
          other.path.isNotEmpty &&
          other.path != '.') {
        String? targetPath;
        if (other.device == 'local') {
          targetPath =
              (await widget.core.localFiles('sync-location', {
                    'kind': other.root,
                    'path': other.path,
                  }) as Map)['path']
                  as String;
        }
        target = SyncLocation(
          device: other.device,
          name: deviceName(other),
          root: other.root,
          path: other.path,
          localPath: targetPath,
        );
      } else {
        if (!mounted) return;
        target = await pickSyncFolder(
          context,
          widget.core,
          excludeDevice: pane.device,
        );
      }
      if (!mounted || target == null) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => FolderPairSync(
            core: widget.core,
            source: source,
            target: target!,
            fullPull: (location) =>
                openFullFolderPull(context, widget.core, location),
          ),
        ),
      );
      await readSyncFolders();
    } catch (e) {
      if (mounted) {
        setState(() {
          notice = e is PlatformException ? e.message ?? e.code : '$e';
        });
      }
    }
  }

  Future<void> manageSync() async {
    await openFolderSync(context, widget.core);
    await readSyncFolders();
  }

  Future<List<Map<String, dynamic>>> listAt(_Pane pane, String path) async {
    final entries = <Map<String, dynamic>>[];
    String next = '';
    do {
      final response = pane.device == 'local'
          ? await widget.core.localFiles('list', {
              'kind': pane.root,
              'path': path,
              'next': next,
            }) as Map
          : await widget.core.run([
              'list',
              pane.device,
              pane.root,
              path.isEmpty ? '.' : path,
              next,
            ]) as Map;
      entries.addAll(
        (response['entries'] as List).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
      next = response['next'] as String? ?? '';
      if (entries.length >= 20000) {
        break;
      }
    } while (next.isNotEmpty);
    return entries;
  }

  Future<void> load(_Pane pane, {bool roots = false}) async {
    if (mounted) {
      setState(() {
        pane.busy = true;
        pane.error = null;
      });
    }
    try {
      if (roots) {
        pane.roots = pane.device == 'local'
            ? localRoots
            : (await widget.core.run(['roots', pane.device]) as List)
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();
        if (!pane.roots.any((r) => r['id'] == pane.root)) {
          if (pane.device != 'local' &&
              pane.root == widget.remoteRoot &&
              const {'home', 'termux_home'}.contains(pane.root)) {
            notice = 'Home is unavailable with the current file access.';
          }
          pane.root = pane.roots.isEmpty ? '' : '${pane.roots.first['id']}';
          pane.path = '';
        }
      }
      pane.entries = pane.root.isEmpty ? [] : await listAt(pane, pane.path);
    } catch (e) {
      pane.error = '$e';
      pane.entries = [];
    }
    if (mounted) {
      setState(() => pane.busy = false);
    }
  }

  Future<void> chooseRoot(_Pane pane, String root) async {
    pane.root = root;
    pane.path = '';
    notice = null;
    if (pane.device == 'local') {
      final info = localRoots.firstWhere((r) => r['id'] == root);
      if (info['available'] != true) {
        try {
          if (root == 'internal') {
            await widget.core.openConnectionSetup('all_files_access');
          } else {
            await widget.core.pickTargetTree();
          }
          localRoots = (await widget.core.localFiles('roots', {}) as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        } catch (e) {
          if (mounted) {
            setState(
              () =>
                  notice = e is PlatformException ? e.message ?? e.code : '$e',
            );
          }
        }
      }
    }
    await load(pane, roots: true);
  }

  String deviceName(_Pane pane) => pane.device == 'local'
      ? (Platform.isAndroid ? 'This phone' : 'This device')
      : '${_peerForPane(pane.device)?['name'] ?? 'Paired device'}';
  String join(String parent, String child) => child.isEmpty
      ? parent
      : parent.isEmpty || parent == '.'
      ? child
      : '$parent/$child';
  Future<void> preview(_Pane pane, Map<String, dynamic> entry) async {
    Future<Map<String, dynamic>> fetch() async => Map<String, dynamic>.from(
      pane.device == 'local'
          ? await widget.core.localFiles('preview', {
              'kind': pane.root,
              'path': entry['path'],
            }) as Map
          : await widget.core.run([
              'preview',
              pane.device,
              pane.root,
              '${entry['path']}',
            ]) as Map,
    );
    try {
      var data = await fetch();
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('${entry['name']}'),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: SelectableText(
                  '${data['text']}${data['truncated'] == true ? '\n… Preview limited to 64 KiB' : ''}',
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  final result = await fetch();
                  if (context.mounted) {
                    setDialogState(
                      () => data = Map<String, dynamic>.from(result),
                    );
                  }
                },
                child: const Text('Refresh live'),
              ),
              if (pane.device == 'local')
                TextButton(
                  onPressed: () => widget.core.localFiles('open', {
                    'kind': pane.root,
                    'path': entry['path'],
                  }),
                  child: const Text('Open with…'),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => notice = '$e');
      }
    }
  }

  bool termuxWritable(_Pane pane) =>
      pane.device != 'local' &&
      pane.roots.any(
        (root) => root['id'] == pane.root && root['writable'] == true,
      );

  bool canCopy(_Pane source, _Pane target) =>
      !isRecycleBin(source) &&
      !isRecycleBin(target) &&
      (target.device == 'local' ||
          (source.device == 'local' && termuxWritable(target)));

  bool canMove(_Pane source, _Pane target) {
    if (isRecycleBin(source) || isRecycleBin(target)) {
      return false;
    }
    if (source.device == 'local' && target.device == 'local') {
      return Platform.isAndroid || Platform.isLinux;
    }
    return (source.device == 'local' && termuxWritable(target)) ||
        (target.device == 'local' && termuxWritable(source));
  }

  Future<Map> uploadToTermux(
    _Pane source,
    _Pane target,
    String path,
    String targetPath,
    bool move,
    List<String> excludes,
  ) async {
    final ref = {'kind': source.root, 'path': path, 'excludes': excludes};
    final location = await widget.core.localFiles('upload-source', ref) as Map;
    final stage = location['stage'] as String?;
    var uploaded = false;
    try {
      final receipt = await widget.core.run([
        'file-push',
        target.device,
        target.root,
        targetPath.isEmpty ? '.' : targetPath,
        location['path'] as String,
        move && stage == null ? 'move' : 'copy',
        ...excludes,
      ]) as Map;
      uploaded = true;
      if (stage != null) {
        final remaining = await widget.core.localFiles('finish-upload', {
          ...ref,
          'stage': stage,
          'move': move,
        });
        receipt['source_remaining'] = remaining;
      }
      return receipt;
    } finally {
      if (!uploaded && stage != null) {
        await widget.core.localFiles('finish-upload', {
          ...ref,
          'stage': stage,
          'move': false,
        });
      }
    }
  }

  Future<void> transfer(
    int from,
    Map<String, dynamic> entry, {
    int? targetPaneIndex,
    String? targetDirOverride,
    bool move = false,
    bool askMode = false,
  }) async {
    final source = panes[from];
    final target = panes[targetPaneIndex ?? (1 - from)];
    final destPath = targetDirOverride ?? target.path;
    final allowCopy = canCopy(source, target);
    final allowMove = canMove(source, target);
    if (askMode) {
      if (!allowCopy && !allowMove) return;
    } else if (move ? !allowMove : !allowCopy) {
      return;
    }
    var excluded = <String>[];
    final destDisplay = destPath.isEmpty ? '/' : destPath;
    final bool? chosenMove;
    if (askMode) {
      chosenMove = await showDialog<bool?>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(
              allowCopy && allowMove
                  ? 'Copy or move ${entry['name']}?'
                  : '${allowMove ? 'Move' : 'Copy'} ${entry['name']}?',
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${deviceName(source)} · ${source.root}\n→ ${deviceName(target)} · ${target.root}/$destDisplay\n\nVerified with XXH64. Existing files are never overwritten; Move removes source files only after verification.',
                ),
                if (entry['kind'] == 'directory')
                  TextButton.icon(
                    onPressed: () async {
                      final result = await showDialog<List<String>>(
                        context: context,
                        builder: (_) => FolderExclusions(
                          initial: excluded,
                          load: (relative) => listAt(
                            source,
                            join('${entry['path']}', relative),
                          ),
                        ),
                      );
                      if (result != null && context.mounted) {
                        setDialogState(() => excluded = result);
                      }
                    },
                    icon: const Icon(Icons.filter_alt_outlined),
                    label: Text(
                      excluded.isEmpty
                          ? 'Exclude files or subfolders…'
                          : '${excluded.length} exclusions',
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: const Text('Cancel'),
              ),
              if (allowCopy)
                OutlinedButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Copy'),
                ),
              if (allowMove)
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Move'),
                ),
            ],
          ),
        ),
      );
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('${move ? 'Move' : 'Copy'} ${entry['name']}?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${deviceName(source)} · ${source.root}\n→ ${deviceName(target)} · ${target.root}/$destDisplay\n\n${move ? 'Source files are removed only after the completed copy passes XXH64 verification. Excluded items remain on the source.' : 'The completed copy is verified with XXH64. Existing files are never overwritten.'}',
                ),
                if (entry['kind'] == 'directory')
                  TextButton.icon(
                    onPressed: () async {
                      final result = await showDialog<List<String>>(
                        context: context,
                        builder: (_) => FolderExclusions(
                          initial: excluded,
                          load: (relative) => listAt(
                            source,
                            join('${entry['path']}', relative),
                          ),
                        ),
                      );
                      if (result != null && context.mounted) {
                        setDialogState(() => excluded = result);
                      }
                    },
                    icon: const Icon(Icons.filter_alt_outlined),
                    label: Text(
                      excluded.isEmpty
                          ? 'Exclude files or subfolders…'
                          : '${excluded.length} exclusions',
                    ),
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
                child: Text(move ? 'Move' : 'Copy'),
              ),
            ],
          ),
        ),
      );
      chosenMove = confirmed == true ? move : null;
    }
    if (chosenMove == null || !mounted) {
      return;
    }
    final doMove = chosenMove;
    setState(() {
      transferring = true;
      notice = null;
    });
    try {
      if (target.device != 'local') {
        final result = await uploadToTermux(
          source,
          target,
          entry['path'] as String,
          destPath,
          doMove,
          excluded,
        );
        notice =
            '${doMove ? 'Move' : 'Copy'} verified · XXH64 · ${result['files']} files${doMove && result['source_remaining'] == true ? ' · some items remain at source' : ''}';
      } else if (source.device == 'local') {
        final result = await widget.core.localFiles('transfer', {
          'source': {'kind': source.root, 'path': entry['path']},
          'target': {'kind': target.root, 'path': destPath},
          'move': doMove,
          'excludes': excluded,
        }) as Map;
        notice =
            '${doMove ? 'Move' : 'Copy'} verified · XXH64 · ${result['files']} files${result['source_remaining'] == true && doMove ? ' · excluded items remain at source' : ''}';
      } else {
        final staging = Platform.isAndroid
            ? '${widget.core.downloads}/${entry['name']}-${DateTime.now().microsecondsSinceEpoch}'
            : '${(await widget.core.localFiles('sync-location', {'kind': target.root, 'path': destPath}) as Map)['path']}/${entry['name']}';
        final receipt = await widget.core.run([
          'pull',
          source.device,
          source.root,
          '${entry['path']}',
          staging,
          ...excluded,
        ]) as Map;
        if (Platform.isAndroid) {
          await widget.core.localFiles('import', {
            'source_path': staging,
            'target': {'kind': target.root, 'path': destPath},
            'name': entry['name'],
            if (termuxWritable(source)) 'evict_staging': true,
          });
        }
        if (doMove) {
          final digest = receipt['source_xxh64'];
          if (digest is! String) {
            throw StateError(
              'Copy verified. A source receipt is required to move files.',
            );
          }
          final result = await widget.core.run([
            'file-remove',
            source.device,
            source.root,
            '${entry['path']}',
            digest,
            ...excluded,
          ]) as Map;
          notice =
              'Move verified · XXH64${result['source_remaining'] == true ? ' · some items remain at source' : ''}';
        } else {
          notice = 'Copy verified · XXH64';
        }
      }
      await load(source);
      if (!identical(source, target)) {
        await load(target);
      }
    } catch (e) {
      notice = e is PlatformException ? e.message ?? e.code : '$e';
    }
    if (mounted) {
      setState(() => transferring = false);
    }
  }

  Future<void> trashEntry(
    _Pane pane,
    Map<String, dynamic> entry, {
    bool confirm = false,
  }) async {
    if (pane.device != 'local' || isRecycleBin(pane)) return;
    if (confirm) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Move ${entry['name']} to Recycle Bin?'),
          content: const Text(
            'You can restore this item later or delete it permanently from the Recycle Bin.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Move to Recycle Bin'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() {
      transferring = true;
      notice = null;
    });
    try {
      await widget.core.localFiles('trash', {
        'kind': pane.root,
        'path': entry['path'],
      });
      notice = 'Moved ${entry['name']} to Recycle Bin';
      await load(pane);
      for (final p in panes) {
        if (!identical(p, pane) && p.device == 'local') {
          await load(p);
        }
      }
    } catch (e) {
      notice = e is PlatformException ? e.message ?? e.code : '$e';
    }
    if (mounted) {
      setState(() => transferring = false);
    }
  }

  Future<void> restoreEntry(_Pane pane, Map<String, dynamic> entry) async {
    if (!isRecycleBin(pane)) return;
    setState(() {
      transferring = true;
      notice = null;
    });
    try {
      await widget.core.localFiles('restore', {'path': entry['path']});
      notice = 'Restored ${entry['name']}';
      await load(pane);
      for (final p in panes) {
        if (!identical(p, pane) && p.device == 'local') {
          await load(p);
        }
      }
    } catch (e) {
      notice = e is PlatformException ? e.message ?? e.code : '$e';
    }
    if (mounted) {
      setState(() => transferring = false);
    }
  }

  Future<void> deleteEntry(_Pane pane, Map<String, dynamic> entry) async {
    if (pane.device != 'local') return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${entry['name']} permanently?'),
        content: Text(
          'This permanently deletes ${entry['name']} and cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      transferring = true;
      notice = null;
    });
    try {
      await widget.core.localFiles('delete', {
        'kind': pane.root,
        'path': entry['path'],
      });
      notice = 'Deleted ${entry['name']}';
      await load(pane);
      for (final p in panes) {
        if (!identical(p, pane) && p.device == 'local') {
          await load(p);
        }
      }
    } catch (e) {
      notice = e is PlatformException ? e.message ?? e.code : '$e';
    }
    if (mounted) {
      setState(() => transferring = false);
    }
  }

  Future<void> emptyRecycleBin(_Pane pane) async {
    if (!isRecycleBin(pane) || pane.entries.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Empty Recycle Bin?'),
        content: Text(
          'Permanently delete all ${pane.entries.length} item(s) in the Recycle Bin? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Empty'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      transferring = true;
      notice = null;
    });
    try {
      await widget.core.localFiles('empty-trash', {});
      notice = 'Recycle Bin emptied';
      await load(pane);
    } catch (e) {
      notice = e is PlatformException ? e.message ?? e.code : '$e';
    }
    if (mounted) {
      setState(() => transferring = false);
    }
  }

  Future<void> newFolder(_Pane pane) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const FolderNameDialog(),
    );
    if (name == null) {
      return;
    }
    try {
      await widget.core.localFiles('mkdir', {
        'kind': pane.root,
        'path': pane.path,
        'name': name,
      });
      await load(pane);
    } catch (e) {
      if (mounted) {
        setState(() => notice = '$e');
      }
    }
  }

  Widget _entryTile(
    int index,
    _Pane pane,
    _Pane other,
    bool canSync,
    Map<String, dynamic> entry,
  ) {
    final isDir = entry['kind'] == 'directory';
    final inTrash = isRecycleBin(pane);
    final folderKey = '$index:${entry['path']}';
    final isFolderHovered = hoverFolderKey == folderKey;
    final cs = Theme.of(context).colorScheme;
    final rawTile = ListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 8),
      minLeadingWidth: 18,
      horizontalTitleGap: 7,
      minTileHeight: 44,
      leading: isDir
          ? (inTrash
                ? const Icon(Icons.folder_outlined, size: 18)
                : SyncedFolderIcon(
                    activity: syncActivity(pane, '${entry['path']}'),
                  ))
          : const Icon(Icons.insert_drive_file_outlined, size: 18),
      title: Text(
        '${entry['name']}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      subtitle: isDir && !inTrash
          ? null
          : Text(
              inTrash
                  ? '${entry['original_label'] ?? 'Deleted'}'
                  : '${entry['size']} B',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      onTap: transferring
          ? null
          : () {
              if (inTrash) {
                showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('${entry['name']}'),
                    content: Text(
                      'Original location: ${entry['original_label'] ?? 'Unknown'}',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          deleteEntry(pane, entry);
                        },
                        child: const Text('Delete permanently'),
                      ),
                      FilledButton(
                        onPressed: () {
                          Navigator.pop(context);
                          restoreEntry(pane, entry);
                        },
                        child: const Text('Restore'),
                      ),
                    ],
                  ),
                );
              } else if (isDir) {
                pane.path = '${entry['path']}';
                load(pane);
              } else {
                preview(pane, entry);
              }
            },
      trailing: PopupMenuButton<String>(
        tooltip: 'File actions',
        enabled: !transferring,
        onSelected: (value) {
          switch (value) {
            case 'sync':
              syncFolder(pane, '${entry['path']}', '${entry['name']}');
            case 'open':
              preview(pane, entry);
            case 'copy':
              transfer(index, entry, move: false);
            case 'move':
              transfer(index, entry, move: true);
            case 'trash':
              trashEntry(pane, entry);
            case 'restore':
              restoreEntry(pane, entry);
            case 'delete':
              deleteEntry(pane, entry);
          }
        },
        itemBuilder: (_) => inTrash
            ? const [
                PopupMenuItem(value: 'restore', child: Text('Restore')),
                PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete permanently'),
                ),
              ]
            : [
                if (isDir && canSync)
                  const PopupMenuItem(
                    value: 'sync',
                    child: Text('Sync folder…'),
                  ),
                if (canCopy(pane, other))
                  const PopupMenuItem(
                    value: 'copy',
                    child: Text('Copy to other pane'),
                  ),
                if (canMove(pane, other))
                  const PopupMenuItem(
                    value: 'move',
                    child: Text('Move to other pane'),
                  ),
                if (entry['kind'] == 'file')
                  const PopupMenuItem(
                    value: 'open',
                    child: Text('Open / live preview'),
                  ),
                if (pane.device == 'local') ...[
                  const PopupMenuItem(
                    value: 'trash',
                    child: Text('Move to Recycle Bin'),
                  ),
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete permanently'),
                  ),
                ],
              ],
      ),
    );
    final tile = isFolderHovered
        ? Material(
            color: cs.primary.withValues(alpha: 0.16),
            shape: RoundedRectangleBorder(
              side: BorderSide(color: cs.primary, width: 1.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: rawTile,
          )
        : rawTile;
    if (inTrash) {
      return tile;
    }
    Widget targetTile = tile;
    if (isDir) {
      targetTile = DragTarget<Map<String, dynamic>>(
        onWillAcceptWithDetails: (details) {
          if (transferring) return false;
          final srcIdx = details.data['pane'] as int?;
          final rawEntry = details.data['entry'];
          if (srcIdx == null || rawEntry is! Map) return false;
          final srcPane = panes[srcIdx];
          if (isRecycleBin(srcPane)) return false;
          final srcPath = '${rawEntry['path'] ?? ''}';
          if (srcIdx == index) {
            if (pane.device != 'local' || srcPath == '${entry['path']}') {
              return false;
            }
          } else {
            if (!canCopy(srcPane, pane) && !canMove(srcPane, pane)) {
              return false;
            }
            if (srcPane.device == 'local' &&
                pane.device == 'local' &&
                srcPane.root == pane.root &&
                srcPath == '${entry['path']}') {
              return false;
            }
          }
          if (hoverFolderKey != folderKey) {
            setState(() => hoverFolderKey = folderKey);
          }
          return true;
        },
        onLeave: (_) {
          if (hoverFolderKey == folderKey) {
            setState(() => hoverFolderKey = null);
          }
        },
        onAcceptWithDetails: (details) {
          setState(() {
            hoverFolderKey = null;
            hoverPaneIndex = null;
          });
          final srcIdx = details.data['pane'] as int;
          final srcEntry = Map<String, dynamic>.from(
            details.data['entry'] as Map,
          );
          transfer(
            srcIdx,
            srcEntry,
            targetPaneIndex: index,
            targetDirOverride: '${entry['path']}',
            askMode: true,
          );
        },
        builder: (_, _, _) => tile,
      );
    }
    return LongPressDraggable<Map<String, dynamic>>(
      data: {'pane': index, 'entry': entry},
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: cs.primaryContainer,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isDir ? Icons.folder : Icons.insert_drive_file,
                size: 18,
                color: cs.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              Text(
                '${entry['name']}',
                style: TextStyle(
                  color: cs.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: targetTile),
      child: targetTile,
    );
  }

  Widget pane(int index) {
    final pane = panes[index];
    final other = panes[1 - index];
    final canSync = supportsFolderSync(pane);
    final inTrash = isRecycleBin(pane);
    final entries = pane.entries
        .where(
          (entry) =>
              inTrash || showHidden || !'${entry['name']}'.startsWith('.'),
        )
        .toList();
    final cs = Theme.of(context).colorScheme;
    return DragTarget<Map<String, dynamic>>(
      onWillAcceptWithDetails: (details) {
        if (transferring) return false;
        final srcIdx = details.data['pane'] as int?;
        if (srcIdx == null || srcIdx == index) return false;
        final srcPane = panes[srcIdx];
        if (isRecycleBin(srcPane)) return false;
        final ok = inTrash
            ? srcPane.device == 'local'
            : (canCopy(srcPane, pane) || canMove(srcPane, pane));
        if (ok && hoverPaneIndex != index) {
          setState(() => hoverPaneIndex = index);
        }
        return ok;
      },
      onLeave: (_) {
        if (hoverPaneIndex == index) {
          setState(() => hoverPaneIndex = null);
        }
      },
      onAcceptWithDetails: (details) {
        setState(() {
          hoverPaneIndex = null;
          hoverFolderKey = null;
        });
        final srcIdx = details.data['pane'] as int;
        final srcEntry = Map<String, dynamic>.from(
          details.data['entry'] as Map,
        );
        if (inTrash) {
          trashEntry(panes[srcIdx], srcEntry, confirm: true);
        } else {
          transfer(srcIdx, srcEntry, targetPaneIndex: index, askMode: true);
        }
      },
      builder: (context, candidates, rejected) => Container(
        decoration: (hoverPaneIndex == index || candidates.isNotEmpty)
            ? BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.35),
                border: Border.all(color: cs.primary, width: 1.5),
              )
            : null,
        child: Column(
          children: [
            _paneLocation(index, pane),
            _paneToolbar(index, pane, inTrash: inTrash, canSync: canSync),
            if (pane.busy) const LinearProgressIndicator(),
            if (pane.error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(pane.error!, style: const TextStyle(fontSize: 11)),
              ),
            Expanded(
              child: entries.isEmpty && !pane.busy && pane.error == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          inTrash ? 'Recycle Bin is empty' : 'Folder is empty',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, entryIndex) => _entryTile(
                        index,
                        pane,
                        other,
                        canSync,
                        entries[entryIndex],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _locationPicker({
    required Key key,
    required String label,
    required IconData icon,
    required String? value,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
    String? hint,
  }) => Semantics(
    label: label,
    child: SizedBox(
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: key,
                isExpanded: true,
                isDense: true,
                value: value,
                hint: hint == null
                    ? null
                    : Text(hint, overflow: TextOverflow.ellipsis),
                iconSize: 18,
                borderRadius: BorderRadius.circular(12),
                style: Theme.of(context).textTheme.bodyMedium,
                items: items,
                onChanged: transferring ? null : onChanged,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _paneLocation(int index, _Pane pane) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
    child: Column(
      children: [
        _locationPicker(
          key: ValueKey('file-pane-$index-device'),
          label: index == 0 ? 'Left device' : 'Right device',
          icon: Icons.devices_outlined,
          value: pane.device,
          items: [
            DropdownMenuItem(
              value: 'local',
              child: Text(Platform.isAndroid ? 'This phone' : 'This device'),
            ),
            if (pane.device != 'local' &&
                !peers.any(
                  (p) => p['id'] == pane.device && p['status'] == 'paired',
                ))
              DropdownMenuItem(
                value: pane.device,
                enabled: false,
                child: Text(deviceName(pane), overflow: TextOverflow.ellipsis),
              ),
            for (final peer in peers.where((p) => p['status'] == 'paired'))
              DropdownMenuItem(
                value: '${peer['id']}',
                child: Text('${peer['name']}', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (value) {
            if (value == null) return;
            pane.device = value;
            pane.path = '';
            load(pane, roots: true);
          },
        ),
        _locationPicker(
          key: ValueKey('file-pane-$index-storage'),
          label: index == 0 ? 'Left storage' : 'Right storage',
          icon: Icons.storage_outlined,
          value: pane.roots.any((root) => root['id'] == pane.root)
              ? pane.root
              : null,
          hint: 'Select storage',
          items: [
            for (final root in pane.roots)
              DropdownMenuItem(
                value: '${root['id']}',
                child: Text(
                  '${root['name'] ?? root['id']}${root['available'] == false ? ' · grant access' : ''}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) chooseRoot(pane, value);
          },
        ),
      ],
    ),
  );

  Widget _paneToolbar(
    int index,
    _Pane pane, {
    required bool inTrash,
    required bool canSync,
  }) {
    final path = pane.path.isEmpty || pane.path == '.' ? '/' : pane.path;
    final buttonStyle = IconButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size(36, 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Row(
      children: [
        if (!inTrash && path != '/')
          IconButton(
            tooltip: 'Parent folder',
            style: buttonStyle,
            onPressed: transferring
                ? null
                : () {
                    final separator = pane.path.lastIndexOf('/');
                    pane.path = separator < 0
                        ? ''
                        : pane.path.substring(0, separator);
                    load(pane);
                  },
            icon: const Icon(Icons.arrow_upward, size: 18),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Tooltip(
              message: path,
              child: Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Refresh pane',
          style: buttonStyle,
          onPressed: transferring ? null : () => load(pane, roots: true),
          icon: const Icon(Icons.refresh, size: 18),
        ),
        if (pane.device != 'local')
          IconButton(
            key: ValueKey('file-pane-$index-connection'),
            tooltip: 'Connection method',
            style: buttonStyle,
            onPressed: transferring ? null : () => _openPaneConnections(pane),
            icon: const Icon(Icons.settings_ethernet, size: 18),
          ),
        if (pane.device == 'local' || canSync)
          SizedBox(
            width: 36,
            height: 36,
            child: PopupMenuButton<String>(
              key: ValueKey('file-pane-$index-actions'),
              tooltip: 'Folder actions',
              enabled: !transferring && (!inTrash || pane.entries.isNotEmpty),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.more_vert, size: 18),
              itemBuilder: (_) => [
                if (inTrash)
                  const PopupMenuItem(
                    value: 'empty',
                    child: Text('Empty Recycle Bin'),
                  )
                else ...[
                  if (pane.device == 'local')
                    const PopupMenuItem(
                      value: 'new',
                      child: Text('New folder'),
                    ),
                  if (canSync)
                    const PopupMenuItem(
                      value: 'sync',
                      child: Text('Sync this folder'),
                    ),
                ],
              ],
              onSelected: (action) {
                switch (action) {
                  case 'new':
                    newFolder(pane);
                  case 'empty':
                    emptyRecycleBin(pane);
                  case 'sync':
                    syncFolder(
                      pane,
                      pane.path,
                      pane.path
                              .split('/')
                              .where((part) => part.isNotEmpty && part != '.')
                              .lastOrNull ??
                          pane.root,
                    );
                }
              },
            ),
          ),
      ],
    );
  }

  Widget _content() => SafeArea(
    child: Column(
      children: [
        if (transferring) const LinearProgressIndicator(),
        if (notice != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(notice!)),
        Expanded(
          child: Row(
            children: [
              Expanded(child: pane(0)),
              const VerticalDivider(width: 1),
              Expanded(child: pane(1)),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        title: const Text('File manager'),
        actions: [
          IconButton(
            key: const ValueKey('open-synced-folders'),
            tooltip: 'Synced folders',
            onPressed: transferring ? null : manageSync,
            icon: const Icon(Icons.sync),
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
        ],
      ),
      body: _content(),
    );
  }
}
