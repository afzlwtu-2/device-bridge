import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'connection_picker.dart';
import 'folder_exclusions.dart';
import 'folder_name_dialog.dart';
import 'termux_tools.dart';

class PhoneFiles extends StatefulWidget {
  const PhoneFiles({
    super.key,
    required this.core,
    this.remotePeer,
    this.remoteRoot,
    this.embedded = false,
  });
  final CoreBridge core;
  final Map<String, dynamic>? remotePeer;
  final String? remoteRoot;
  final bool embedded;
  @override
  State<PhoneFiles> createState() => _PhoneFilesState();
}

class _Pane {
  String device = 'local', root = 'internal', path = '';
  List<Map<String, dynamic>> roots = [], entries = [];
  String? error;
  bool busy = false;
}

class _PhoneFilesState extends State<PhoneFiles> with WidgetsBindingObserver {
  final panes = [_Pane(), _Pane()];
  List<Map<String, dynamic>> localRoots = [];
  List<dynamic> peers = [];
  bool transferring = false, showHidden = false;
  String? notice;
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
      for (final pane in panes) {
        await load(pane, roots: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => notice = '$e');
      }
    }
  }

  Future<List<Map<String, dynamic>>> listAt(_Pane pane, String path) async {
    if (pane.device == 'local') {
      final response = await widget.core.localFiles('list', {
        'kind': pane.root,
        'path': path,
      }) as Map;
      return (response['entries'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    final entries = <Map<String, dynamic>>[];
    String next = '';
    do {
      final response = await widget.core.run([
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
    if (pane.device == 'local') {
      final info = localRoots.firstWhere((r) => r['id'] == root);
      if (info['available'] != true) {
        try {
          if (root == 'internal') {
            await widget.core.openConnectionSetup('all_files_access');
          } else {
            await widget.core.pickTargetTree(termux: root == 'termux');
          }
          localRoots = (await widget.core.localFiles('roots', {}) as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        } catch (e) {
          if (mounted) {
            setState(() => notice = '$e');
          }
        }
      }
    }
    await load(pane, roots: true);
  }

  String deviceName(_Pane pane) => pane.device == 'local'
      ? 'This phone'
      : '${peers.firstWhere((p) => p['id'] == pane.device, orElse: () => {'name': 'Paired device'})['name']}';
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

  Future<void> transfer(
    int from,
    Map<String, dynamic> entry, {
    bool move = false,
  }) async {
    final source = panes[from], target = panes[1 - from];
    if (target.device != 'local') {
      setState(
        () => notice = 'This destination has not granted file creation. Choose this phone as the target.',
      );
      return;
    }
    if (move && source.device != 'local') {
      setState(
        () =>
            notice = 'Remote source deletion requires a separate device grant.',
      );
      return;
    }
    var excluded = <String>[];
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
                '${deviceName(source)} · ${source.root}\n→ ${deviceName(target)} · ${target.root}/${target.path}\n\n${move ? 'Source files are removed only after the completed copy passes XXH64 verification. Excluded items remain on the source.' : 'The completed copy is verified with XXH64. Existing files are never overwritten.'}',
              ),
              if (entry['kind'] == 'directory')
                TextButton.icon(
                  onPressed: () async {
                    final result = await showDialog<List<String>>(
                      context: context,
                      builder: (_) => FolderExclusions(
                        initial: excluded,
                        load: (relative) =>
                            listAt(source, join('${entry['path']}', relative)),
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
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      transferring = true;
      notice = null;
    });
    try {
      if (source.device == 'local') {
        final result = await widget.core.localFiles('transfer', {
          'source': {'kind': source.root, 'path': entry['path']},
          'target': {'kind': target.root, 'path': target.path},
          'move': move,
          'excludes': excluded,
        }) as Map;
        notice =
            '${move ? 'Move' : 'Copy'} verified · XXH64 · ${result['files']} files${result['source_remaining'] == true && move ? ' · excluded items remain at source' : ''}';
      } else {
        final staging =
            '${widget.core.downloads}/${entry['name']}-${DateTime.now().microsecondsSinceEpoch}';
        await widget.core.run([
          'pull',
          source.device,
          source.root,
          '${entry['path']}',
          staging,
          ...excluded,
        ]);
        // Use the verified download exporter for the selected local provider.
        await widget.core.localFiles('import', {
          'source_path': staging,
          'target': {'kind': target.root, 'path': target.path},
          'name': entry['name'],
        });
        notice = 'Copy verified · XXH64';
      }
      await load(source);
      await load(target);
    } catch (e) {
      notice = '$e';
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

  Widget pane(int index) {
    final pane = panes[index];
    final cs = Theme.of(context).colorScheme;
    return DragTarget<Map<String, dynamic>>(
      onWillAcceptWithDetails: (details) =>
          !transferring && details.data['pane'] != index,
      onAcceptWithDetails: (details) => transfer(
        details.data['pane'] as int,
        Map<String, dynamic>.from(details.data['entry'] as Map),
      ),
      builder: (context, candidates, rejected) => Container(
        decoration: BoxDecoration(
          color: candidates.isNotEmpty ? cs.primaryContainer : null,
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: pane.device,
                    dropdownColor: Theme.of(context).canvasColor,
                    borderRadius: BorderRadius.circular(16),
                    decoration: InputDecoration(
                      labelText: index == 0 ? 'Left device' : 'Right device',
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: 'local',
                        child: Text('This phone'),
                      ),
                      for (final peer in peers.where(
                        (p) => p['status'] == 'paired',
                      ))
                        DropdownMenuItem(
                          value: '${peer['id']}',
                          child: Text(
                            '${peer['name']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: transferring
                        ? null
                        : (v) {
                            pane.device = v!;
                            pane.path = '';
                            load(pane, roots: true);
                          },
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    key: ValueKey('${pane.device}:${pane.root}'),
                    isExpanded: true,
                    dropdownColor: Theme.of(context).canvasColor,
                    borderRadius: BorderRadius.circular(16),
                    initialValue: pane.roots.any((r) => r['id'] == pane.root)
                        ? pane.root
                        : null,
                    decoration: const InputDecoration(
                      labelText: 'Storage',
                      isDense: true,
                    ),
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
                    onChanged: transferring
                        ? null
                        : (v) => chooseRoot(pane, v!),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Parent folder',
                  onPressed:
                      pane.path.isEmpty || pane.path == '.' || transferring
                      ? null
                      : () {
                          pane.path = pane.path.contains('/')
                              ? pane.path.substring(
                                  0,
                                  pane.path.lastIndexOf('/'),
                                )
                              : '';
                          load(pane);
                        },
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                Expanded(
                  child: Text(
                    pane.path.isEmpty || pane.path == '.' ? '/' : pane.path,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                if (pane.device == 'local')
                  IconButton(
                    tooltip: 'New folder',
                    onPressed: transferring ? null : () => newFolder(pane),
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 18,
                    ),
                  )
                else
                  IconButton(
                    tooltip: 'Connection method',
                    onPressed: transferring
                        ? null
                        : () async {
                            final changed = await showDialog<bool>(
                              context: context,
                              builder: (_) => ConnectionPicker(
                                core: widget.core,
                                peer: pane.device,
                              ),
                            );
                            if (changed == true && mounted) {
                              await load(pane, roots: true);
                            }
                          },
                    icon: const Icon(Icons.settings_ethernet, size: 18),
                  ),
                IconButton(
                  tooltip: 'Refresh pane',
                  onPressed: () => load(pane, roots: true),
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
            if (pane.busy) const LinearProgressIndicator(),
            if (pane.error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(pane.error!, style: const TextStyle(fontSize: 11)),
              ),
            Expanded(
              child: ListView(
                children: [
                  for (final entry in pane.entries.where(
                    (e) => showHidden || !'${e['name']}'.startsWith('.'),
                  ))
                    LongPressDraggable<Map<String, dynamic>>(
                      data: {'pane': index, 'entry': entry},
                      feedback: Material(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text('${entry['name']}'),
                        ),
                      ),
                      childWhenDragging: Opacity(
                        opacity: .4,
                        child: Text('${entry['name']}'),
                      ),
                      child: ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.only(left: 8),
                        leading: Icon(
                          entry['kind'] == 'directory'
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                          size: 18,
                        ),
                        title: Text(
                          '${entry['name']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                        subtitle: Text(
                          entry['kind'] == 'directory'
                              ? 'Folder'
                              : '${entry['size']} B',
                          style: const TextStyle(fontSize: 10),
                        ),
                        onTap: transferring
                            ? null
                            : () {
                                if (entry['kind'] == 'directory') {
                                  pane.path = '${entry['path']}';
                                  load(pane);
                                } else {
                                  preview(pane, entry);
                                }
                              },
                        trailing: PopupMenuButton<String>(
                          tooltip: 'File actions',
                          enabled: !transferring,
                          onSelected: (value) => value == 'open'
                              ? preview(pane, entry)
                              : transfer(index, entry, move: value == 'move'),
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'copy',
                              child: Text('Copy to other pane'),
                            ),
                            if (pane.device == 'local')
                              const PopupMenuItem(
                                value: 'move',
                                child: Text('Move to other pane'),
                              ),
                            if (entry['kind'] == 'file')
                              const PopupMenuItem(
                                value: 'open',
                                child: Text('Open / live preview'),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content() => SafeArea(
    child: Column(
      children: [
        if (widget.embedded)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 0),
            child: Row(
              children: [
                if (Platform.isAndroid)
                  TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => TermuxTools(core: widget.core),
                      ),
                    ),
                    icon: const Icon(Icons.terminal, size: 18),
                    label: const Text('Termux tools'),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: showHidden
                      ? 'Hide hidden files'
                      : 'Show hidden files',
                  icon: Icon(
                    showHidden
                        ? Icons.visibility
                        : Icons.visibility_off_outlined,
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
          ),
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
    if (widget.embedded) {
      return _content();
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('File manager'),
        actions: [
          IconButton(
            tooltip: 'Termux tools',
            icon: const Icon(Icons.terminal),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => TermuxTools(core: widget.core),
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
        ],
      ),
      body: _content(),
    );
  }
}
