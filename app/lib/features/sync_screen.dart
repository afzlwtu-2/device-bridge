import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'folder_pair_sync.dart';

class SyncFolderSelection {
  const SyncFolderSelection({required this.name, this.localPath, this.peer, this.root, this.path});
  final String name;
  final String? localPath, peer, root, path;
}

Future<void> openFolderSync(BuildContext context, CoreBridge core, {SyncFolderSelection? folder, bool startFullPull = false}) =>
    Navigator.push<void>(context, MaterialPageRoute(builder: (_) => Scaffold(
      appBar: AppBar(title: Text(startFullPull ? 'Full pull' : folder == null ? 'Synced folders' : 'Sync ${folder.name}')),
      body: SyncScreen(core: core, folder: folder, startFullPull: startFullPull),
    )));

Future<void> openFullFolderPull(BuildContext context,CoreBridge core,SyncLocation location) => openFolderSync(context,core,
  folder:SyncFolderSelection(name:location.name,peer:location.device,root:location.root,path:location.path),startFullPull:true);

/// Registration is persisted in the managed profile, never inferred from
/// marker files. Paused folders remain visibly registered after reopening Files.
class SyncedFolderIcon extends StatelessWidget {
  const SyncedFolderIcon({super.key, this.activity, this.size = 18});
  final String? activity;
  final double size;
  @override
  Widget build(BuildContext context) => activity == null
      ? Icon(Icons.folder_outlined, size: size)
      : Tooltip(
          message: 'Synced folder · $activity',
          child: SizedBox(width: size + 8, height: size + 6, child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(Icons.folder_outlined, size: size),
              Positioned(right: 0, bottom: 0, child: Icon(Icons.sync, size: 12,
                color: activity == 'interrupted' ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.primary)),
            ],
          )),
        );
}

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.core, this.folder, this.startFullPull = false});

  final CoreBridge core;
  final SyncFolderSelection? folder;
  final bool startFullPull;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  Map<String, dynamic>? _profile;
  String? _message;
  String? _pullProgress;
  bool _busy = false;
  bool _running = false;
  List<Map> _pairs = [];
  List<Map> _controllers = [];

  @override
  void initState() {
    super.initState();
    if(widget.startFullPull){WidgetsBinding.instance.addPostFrameCallback((_){if(mounted)unawaited(_fullPull());});}
    else {unawaited(_readStatus());}
  }

  static String _mode(Map entry) => '${entry['mode'] ?? 'non-git'}';

  static String _filter(Map entry) => '${entry['filter'] ?? 'untracked'}';

  static bool _isFull(Map entry) => _mode(entry) == 'full';

  static bool _isWorking(Map entry) =>
      !_isFull(entry) && _filter(entry) == 'working';

  static bool _isUntracked(Map entry) => !_isFull(entry) && !_isWorking(entry);

  static String _modeLabel(Map entry) {
    if (_isFull(entry)) return 'Full folder · incl. hidden & .git';
    if (_isWorking(entry)) return 'Non-git · all working files except .git';
    return 'Non-git · untracked & ignored only';
  }

  Future<void> _readStatus({bool prepare = false}) async {
    setState(() => _busy = true);
    try {
      final result = await widget.core.run([
        'syncthing',
        prepare ? 'prepare' : 'status',
      ]) as Map;
      if (mounted) { setState(() {
        _profile = Map<String, dynamic>.from(result);
        _running = (result['registered'] as List? ?? []).whereType<Map>().any((entry) => entry['activity'] == 'running');
      }); }
      final pairs = await widget.core.run(['sync-pairs']);
      if (mounted) setState(() => _pairs = pairs is List ? pairs.whereType<Map>().toList() : []);
      final peers = await widget.core.run(['peers']) as List;
      final controllers = <Map>[];
      for (final peer in peers.whereType<Map>().where((peer) => peer['status'] == 'paired')) {
        final access = await widget.core.run(['sync-control-access', '${peer['id']}']) as Map;
        final remote = await widget.core.run(['sync-remote-access', '${peer['id']}']) as Map;
        controllers.add({...peer, 'allowed': access['allowed'] == true, 'remote': remote['allowed'] == true});
      }
      if (mounted) setState(() => _controllers = controllers);
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _controllerAccess(Map peer, bool value, {bool remote = false}) async {
    setState(() => _busy = true);
    try {await widget.core.run([remote ? 'sync-remote-access' : 'sync-control-access', '${peer['id']}', value ? 'allow' : 'deny']);}
    catch (e) {if (mounted) setState(() => _message = '$e');}
    if (mounted) await _readStatus();
  }

  Future<void> _perform(
    List<String> arguments, {
    bool approved = false,
    bool project = false,
  }) async {
    setState(() {
      _busy = true;
      _running = approved;
      _message = null;
    });
    try {
      final result = await widget.core.run([
        if (approved) '--approve-sync',
        project ? 'project' : 'syncthing',
        ...arguments,
      ]) as Map;
      if (!mounted) return;
      if (arguments.first == 'manifest') {
        await Clipboard.setData(
          ClipboardData(text: '${result['manifest_xxh64']}'),
        );
        if (mounted) setState(() => _message = 'Manifest XXH64 copied.');
      } else if (approved) {
        setState(() => _message = 'Folder verified. Sync paused.');
      } else if (arguments.first == 'mode') {
        setState(() => _message = 'Sync mode updated.');
      } else if (arguments.first == 'build') {
        setState(
          () => _message =
              'Working projection built · XXH64 ${result['manifest_xxh64']}.',
        );
      } else if (project && arguments.first == 'status') {
        setState(() {
          _message = switch (result) {
            {'handoff_pending': true} =>
              'Handoff pending. Local writes are paused.',
            {'writable': true} => 'This device owns the project.',
            _ => 'This device is read-only for the project.',
          };
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      if (mounted) {
        setState(() => _running = false);
        await _readStatus();
      }
    }
  }

  /// Shared mode/filter/source fields for the register and change-mode
  /// dialogs. Full mode syncs the real folder; non-git keeps a projection.
  List<Widget> _modeFields({
    required String mode,
    required String filter,
    required String source,
    required void Function(String) onMode,
    required void Function(String) onFilter,
    required void Function(String) onSource,
    required String? Function(String?) sourceValidator,
  }) {
    return [
      DropdownButtonFormField<String>(
        initialValue: mode,
        decoration: const InputDecoration(labelText: 'Sync mode'),
        items: const [
          DropdownMenuItem(
            value: 'non-git',
            child: Text('Non-git files (filtered projection)'),
          ),
          DropdownMenuItem(
            value: 'full',
            child: Text('Full folder (incl. hidden & .git)'),
          ),
        ],
        onChanged: (value) => onMode(value ?? 'non-git'),
      ),
      if (mode == 'non-git')
        DropdownButtonFormField<String>(
          initialValue: filter,
          decoration: const InputDecoration(labelText: 'Non-git filter'),
          items: const [
            DropdownMenuItem(
              value: 'untracked',
              child: Text('Untracked & ignored only'),
            ),
            DropdownMenuItem(
              value: 'working',
              child: Text('All working files except .git'),
            ),
          ],
          onChanged: (value) => onFilter(value ?? 'untracked'),
        ),
      TextFormField(
        initialValue: source,
        decoration: InputDecoration(
          labelText: mode == 'full'
              ? 'Local folder to sync (required)'
              : 'Local source folder (optional)',
        ),
        onChanged: onSource,
        validator: sourceValidator,
      ),
      if (mode == 'full' || filter == 'working')
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'This mode can include secrets, caches and uncommitted work. '
            'Review the folder before approving a session.',
          ),
        ),
    ];
  }

  Future<void> _register() async {
    var group = '';
    var peer = '';
    var role = widget.folder?.localPath != null ? 'sendonly' : 'receiveonly';
    var mode = widget.folder != null ? 'full' : 'non-git';
    var filter = 'untracked';
    var source = widget.folder?.localPath ?? '';
    final form = GlobalKey<FormState>();
    final args = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Register a folder'),
          content: Form(
            key: form,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Shared group ID',
                    ),
                    onChanged: (value) => group = value.trim(),
                    validator: (_) =>
                        RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(group)
                        ? null
                        : 'Use lowercase letters, numbers, and hyphens.',
                  ),
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Peer Syncthing device ID',
                    ),
                    onChanged: (value) => peer = value.trim().toUpperCase(),
                    validator: (_) =>
                        RegExp(r'^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$').hasMatch(peer)
                        ? null
                        : 'Enter the ID from the peer’s Sync screen.',
                  ),
                  const SizedBox(height: 12),
                  ..._modeFields(
                    mode: mode,
                    filter: filter,
                    source: source,
                    onMode: (value) => setDialogState(() => mode = value),
                    onFilter: (value) => setDialogState(() => filter = value),
                    onSource: (value) => source = value.trim(),
                    sourceValidator: (_) => mode == 'full' && source.isEmpty
                        ? 'Full folder sync needs the folder path.'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: role,
                    decoration: const InputDecoration(labelText: 'This device'),
                    items: const [
                      DropdownMenuItem(
                        value: 'receiveonly',
                        child: Text('Receive only'),
                      ),
                      DropdownMenuItem(
                        value: 'sendonly',
                        child: Text('Send only'),
                      ),
                    ],
                    onChanged: (value) => role = value ?? 'receiveonly',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(context, [
                    'register',
                    group,
                    peer,
                    role,
                    '--mode',
                    mode,
                    if (mode == 'non-git') ...['--filter', filter],
                    if (source.isNotEmpty) ...['--source', source],
                  ]);
                }
              },
              child: const Text('Register'),
            ),
          ],
        ),
      ),
    );
    if (mounted && args != null) await _perform(args);
  }

  Future<void> _changeMode(Map entry) async {
    var mode = _mode(entry);
    var filter = _filter(entry);
    var source = '${entry['source'] ?? ''}';
    final form = GlobalKey<FormState>();
    final args = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Sync mode for ${entry['group']}'),
          content: Form(
            key: form,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ..._modeFields(
                    mode: mode,
                    filter: filter,
                    source: source,
                    onMode: (value) => setDialogState(() => mode = value),
                    onFilter: (value) => setDialogState(() => filter = value),
                    onSource: (value) => source = value.trim(),
                    sourceValidator: (_) => mode == 'full' && source.isEmpty
                        ? 'Full folder sync needs the folder path.'
                        : null,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(context, [
                    'mode',
                    '${entry['group']}',
                    '--mode',
                    mode,
                    if (mode == 'non-git') ...['--filter', filter],
                    if (source.isNotEmpty) ...['--source', source],
                  ]);
                }
              },
              child: const Text('Save mode'),
            ),
          ],
        ),
      ),
    );
    if (mounted && args != null) await _perform(args);
  }

  Future<void> _buildWorking(Map entry) async {
    var worktree = '${entry['source'] ?? ''}';
    var snapshot = false;
    final form = GlobalKey<FormState>();
    final args = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Build working projection for ${entry['group']}'),
        content: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Copies every working file except .git at any depth, '
                  'including uncommitted and hidden files, into the managed '
                  'projection. You can retain the previous projection as a '
                  'snapshot before replacing it.',
                ),
                TextFormField(
                  initialValue: worktree,
                  decoration: const InputDecoration(
                    labelText: 'Working folder path',
                  ),
                  onChanged: (value) => worktree = value.trim(),
                  validator: (_) => worktree.isEmpty
                      ? 'Enter the working folder path.'
                      : null,
                ),
                StatefulBuilder(builder: (context, setChoice) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero, value: snapshot,
                  title: const Text('Keep the previous projection as a snapshot'),
                  onChanged: (value) => setChoice(() => snapshot = value ?? false),
                )),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, [
                  'build',
                  '${entry['group']}',
                  worktree,
                  if (snapshot) '--snapshot',
                ]);
              }
            },
            child: const Text('Build'),
          ),
        ],
      ),
    );
    if (mounted && args != null) await _perform(args);
  }

  /// One-off verified pull of the peer's whole folder, independent of the
  /// registered sync mode and without touching sync revisions.
  Future<void> _fullPull([Map? entry]) async {
    final bound = widget.folder?.peer ?? entry?['devicebridge_peer'] as String?;
    var peer = bound ?? '';
    var peerLabel = bound ?? '';
    var peers = <Map<String, dynamic>>[];
    try {
      final all = (await widget.core.run(['peers']) as List)
          .whereType<Map>()
          .map((p) => Map<String, dynamic>.from(p))
          .where((p) => p['status'] == 'paired')
          .toList();
      if (bound != null) {
        peerLabel =
            '${all.firstWhere((p) => p['id'] == bound, orElse: () => {'name': bound})['name']}';
      } else {
        peers = all;
        if (peers.isEmpty) {
          if (mounted) {
            setState(
              () => _message = 'Pair a DeviceBridge peer before a full pull.',
            );
          }
          return;
        }
        peer = '${peers.first['id']}';
        peerLabel = '${peers.first['name']}';
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
      return;
    }
    if (!mounted) return;
    var root = widget.folder?.root ?? 'home';
    var path = widget.folder?.path ?? '';
    if(widget.folder!=null&&path.isEmpty)path='.';
    var includeGit = true;
    final form = GlobalKey<FormState>();
    final choice = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Full pull from peer'),
          content: Form(
            key: form,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'One-time verified copy of everything on $peerLabel, '
                    'including uncommitted and hidden files. This does not '
                    'change sync registrations or revisions.',
                  ),
                  if (bound == null)
                    DropdownButtonFormField<String>(
                      initialValue: peer,
                      decoration: const InputDecoration(labelText: 'Peer'),
                      items: [
                        for (final p in peers)
                          DropdownMenuItem(
                            value: '${p['id']}',
                            child: Text('${p['name']}'),
                          ),
                      ],
                      onChanged: (value) => setDialogState(() {
                        peer = value ?? peer;
                        peerLabel =
                            '${peers.firstWhere((p) => p['id'] == peer, orElse: () => {'name': peer})['name']}';
                      }),
                    ),
                  TextFormField(
                    initialValue: root,
                    decoration: const InputDecoration(
                      labelText: 'Remote root (e.g. home)',
                    ),
                    onChanged: (value) => root = value.trim(),
                    validator: (_) =>
                        root.isEmpty ? 'Enter the remote root.' : null,
                  ),
                  TextFormField(
                    initialValue: path,
                    decoration: const InputDecoration(
                      labelText: 'Remote folder path',
                    ),
                    onChanged: (value) => path = value.trim(),
                    validator: (_) => path.isEmpty
                        ? 'Enter the folder to pull in full.'
                        : null,
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: includeGit,
                    title: const Text('Include .git history'),
                    subtitle: const Text(
                      'Uncheck to skip the root .git directory; nested '
                      'submodule .git folders can be excluded manually.',
                    ),
                    onChanged: (value) =>
                        setDialogState(() => includeGit = value ?? true),
                  ),
                  Text(
                    'Saves a new verified copy under '
                    '${widget.core.downloads}.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(context, {
                    'peer': peer,
                    'root': root,
                    'path': path,
                    'include_git': includeGit,
                  });
                }
              },
              child: const Text('Pull everything'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    await _runFullPull(
      '${choice['peer']}',
      '${choice['root']}',
      '${choice['path']}',
      choice['include_git'] == true,
    );
  }

  Future<void> _runFullPull(
    String peer,
    String root,
    String path,
    bool includeGit,
  ) async {
    final segments = path.split('/').where((s) => s.isNotEmpty && s!='.').toList();
    final name = segments.isEmpty ? 'folder' : segments.last;
    final destination =
        '${widget.core.downloads}/$name-${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      _busy = true;
      _message = null;
      _pullProgress = 'Starting full pull…';
    });
    final subscription = widget.core.transferProgress.listen((progress) {
      final verified = (progress['verified_bytes'] as num?)?.toDouble() ?? 0;
      final total = (progress['total_bytes'] as num?)?.toDouble() ?? 0;
      if (mounted) {
        setState(
          () => _pullProgress =
              'Full pull ${(verified / (1 << 20)).toStringAsFixed(1)} / '
              '${(total / (1 << 20)).toStringAsFixed(1)} MiB',
        );
      }
    });
    try {
      final receipt = await widget.core.run([
        'pull-tar',
        peer,
        root,
        path,
        destination,
        if (!includeGit) '.git',
      ]) as Map;
      final speed = (receipt['mib_per_second'] as num?)?.toDouble();
      if (mounted) {
        setState(
          () => _message =
              'Full pull verified${speed != null ? ' · ${speed.toStringAsFixed(2)} MiB/s' : ''}'
              ' → $destination',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _message = error.toString());
    } finally {
      unawaited(subscription.cancel());
      if (mounted) {
        setState(() {
          _busy = false;
          _pullProgress = null;
        });
      }
    }
  }

  Future<void> _run(Map entry) async {
    final localIP = '${widget.core.network?['cidr'] ?? ''}'.split('/').first;
    if (localIP.isEmpty) {
      setState(() => _message = 'Select a local network in Connections first.');
      return;
    }
    final group = '${entry['group']}';
    final project = entry['devicebridge_peer'] != null && _isUntracked(entry);
    var localPort = '22001';
    var peer = '';
    var digest = '';
    var worktree = '';
    final form = GlobalKey<FormState>();
    final args = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Sync $group'),
        content: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Local address $localIP. This one-time session uses direct '
                  'LAN for up to five minutes.',
                ),
                if (_isFull(entry))
                  const Text(
                    'Full folder mode: the manifest covers hidden files and '
                    '.git on both devices.',
                  )
                else if (_isWorking(entry))
                  const Text(
                    'Working filter: build the projection first; its manifest '
                    'excludes .git.',
                  ),
                TextFormField(
                  initialValue: localPort,
                  decoration: const InputDecoration(labelText: 'Local port'),
                  keyboardType: TextInputType.number,
                  onChanged: (value) => localPort = value.trim(),
                  validator: (_) {
                    final port = int.tryParse(localPort) ?? 0;
                    return port > 0 && port < 65536
                        ? null
                        : 'Enter a port from 1 to 65535.';
                  },
                ),
                TextFormField(
                  decoration: const InputDecoration(
                    labelText: 'Peer IPv4 address and port',
                  ),
                  onChanged: (value) => peer = value.trim(),
                  validator: (_) =>
                      RegExp(r'^(\d+\.){3}\d+:\d+$').hasMatch(peer)
                      ? null
                      : 'Enter the LAN endpoint, such as 192.168.1.10:22001.',
                ),
                if (project)
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Local Git worktree path',
                    ),
                    onChanged: (value) => worktree = value.trim(),
                    validator: (_) => worktree.isEmpty
                        ? 'Enter the project root path.'
                        : null,
                  )
                else
                  TextFormField(
                    decoration: const InputDecoration(
                      labelText: 'Source manifest XXH64',
                    ),
                    onChanged: (value) => digest = value.trim(),
                    validator: (_) =>
                        RegExp(r'^[0-9a-fA-F]{16}$').hasMatch(digest)
                        ? null
                        : 'Copy the manifest from the sending device.',
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(context, [
                  'run',
                  group,
                  if (project) worktree,
                  '$localIP:$localPort',
                  peer,
                  if (!project) digest,
                ]);
              }
            },
            child: const Text('Approve and start'),
          ),
        ],
      ),
    );
    if (mounted && args != null) {
      await _perform(args, approved: true, project: project);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final installed = profile?['installed'] == true;
    final prepared = profile?['prepared'] == true;
    final allRegistered = (profile?['registered'] as List? ?? []).whereType<Map>();
    final registered = allRegistered.where((entry) => widget.folder?.localPath == null || entry['source'] == widget.folder!.localPath).toList();
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.folder == null ? 'Registered folders' : widget.folder!.name,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            IconButton(
              tooltip: 'Refresh sync status',
              onPressed: _busy ? null : _readStatus,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        for (final pair in _pairs) Card(child: ListTile(
          leading: SyncedFolderIcon(activity: '${pair['state'] ?? 'paused'}', size: 24),
          title: Text('${(pair['source'] as Map)['name']} → ${(pair['target'] as Map)['name']}'),
          subtitle: Text('${(pair['source'] as Map)['path']} → ${(pair['target'] as Map)['path']}\n${pair['mode'] == 'full' ? 'Full folder' : 'Working files without .git'} · ${pair['state']}'),
          onTap: _busy ? null : () async {
            await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => FolderPairSync(core: widget.core,
              source: SyncLocation.fromJson(pair['source'] as Map), target: SyncLocation.fromJson(pair['target'] as Map), saved: Map<String, dynamic>.from(pair),fullPull:(location)=>openFullFolderPull(context,widget.core,location))));
            if (mounted) await _readStatus();
          },
        )),
        if (_controllers.isNotEmpty) ExpansionTile(
          title: const Text('Allow other devices to manage sync here'),
          children: [for (final peer in _controllers) ...[
            SwitchListTile(title: Text('${peer['name']}'), subtitle: const Text('Can configure and update sync folders within granted storage.'), value: peer['allowed'] == true, onChanged: _busy ? null : (value) => _controllerAccess(peer, value)),
            if (peer['allowed'] == true) SwitchListTile(title: Text('Remote sync routes · ${peer['name']}'), subtitle: const Text('Allow approved Tailscale or routed data sessions.'), value: peer['remote'] == true, onChanged: _busy ? null : (value) => _controllerAccess(peer, value, remote: true)),
          ]],
        ),
        if (widget.folder case final folder?) ...[
          SelectableText(folder.localPath ?? '${folder.root ?? ''}/${folder.path ?? ''}'),
          const SizedBox(height: 8),
          Text(widget.startFullPull ? 'Download a new verified copy to this device without changing sync settings.' : 'Choose full folder sync, including hidden and Git files, or a non-git filter. Sessions run only when you approve them.'),
          if (folder.peer != null && !widget.startFullPull)
            const Text('Register matching folders on both devices. Choose a local receiving folder when setting up this side.'),
        ],
        if (_pullProgress case final progress?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(progress),
          ),
        if (_running)
          TextButton.icon(
            onPressed: () async { await widget.core.run(['sync-owner-stop']); await widget.core.cancel(); if(mounted)await _readStatus(); },
            icon: const Icon(Icons.stop_outlined),
            label: const Text('Stop sync'),
          ),
        if (_message case final message?)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(message),
          ),
        if (widget.folder?.localPath == null) Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _fullPull(),
            icon: const Icon(Icons.download_outlined),
            label: const Text('Full pull…'),
          ),
        ),
        if (widget.folder?.localPath == null) const Text(
          'Copy a paired device’s folder once. No Syncthing setup is required.',
        ),
        if (profile != null && !installed)
          Text(
            Platform.isAndroid
                ? 'The app sync engine is unavailable. Update DeviceBridge to a build with the sync engine. Termux and root are not required for phone-storage sync.'
                : 'Install Syncthing separately to prepare a DeviceBridge profile.',
          ),
        if (installed && !prepared) ...[
          const Text('DeviceBridge uses a dedicated local Syncthing profile.'),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _busy ? null : () => _readStatus(prepare: true),
              child: const Text('Prepare profile'),
            ),
          ),
        ],
        if (prepared) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Syncthing device ID'),
            subtitle: SelectableText('${profile?['device_id']}'),
            trailing: IconButton(
              tooltip: 'Copy Syncthing device ID',
              icon: const Icon(Icons.copy_outlined),
              onPressed: () => Clipboard.setData(
                ClipboardData(text: '${profile?['device_id']}'),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _register,
              icon: const Icon(Icons.add),
              label: const Text('Register folder'),
            ),
          ),
          if (registered.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No synced folders yet. Open a folder’s Sync action in Files to register it, or register a folder here. Set up the matching folder on the other device too.'),
            ),
          for (final entry in registered)
            Card(
              child: ListTile(
                leading: Icon(
                  _isFull(entry)
                      ? Icons.folder_copy_outlined
                      : Icons.folder_outlined,
                ),
                title: Text('${entry['group']}'),
                subtitle: Text(
                  '${_modeLabel(entry)} · '
                  '${entry['role'] == 'sendonly' ? 'Send only' : 'Receive only'} · '
                  '${entry['activity'] ?? 'paused'}\n'
                  '${_isFull(entry) ? entry['source'] : entry['path']}',
                ),
                onTap: _busy ? null : () => _run(entry),
                trailing: PopupMenuButton<String>(
                  enabled: !_busy,
                  onSelected: (action) async {
                    if (action == 'pull') {
                      await _fullPull(entry);
                    } else if (action == 'mode') {
                      await _changeMode(entry);
                    } else if (action == 'build') {
                      await _buildWorking(entry);
                    } else if (action == 'project') {
                      await _perform([
                        'status',
                        '${entry['group']}',
                      ], project: true);
                    } else if (action == 'manifest') {
                      await _perform(['manifest', '${entry['group']}']);
                    } else if (action == 'copy') {
                      await Clipboard.setData(
                        ClipboardData(
                          text:
                              '${_isFull(entry) ? entry['source'] : entry['path']}',
                        ),
                      );
                    } else if (action == 'forget') {
                      await _perform(['forget', '${entry['group']}']);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'pull',
                      child: Text('Full pull from peer…'),
                    ),
                    const PopupMenuItem(
                      value: 'mode',
                      child: Text('Change sync mode…'),
                    ),
                    if (_isWorking(entry))
                      const PopupMenuItem(
                        value: 'build',
                        child: Text('Build working projection…'),
                      ),
                    if (entry['devicebridge_peer'] != null &&
                        _isUntracked(entry))
                      const PopupMenuItem(
                        value: 'project',
                        child: Text('Project ownership'),
                      ),
                    if (entry['role'] == 'sendonly' &&
                        (entry['devicebridge_peer'] == null ||
                            _isFull(entry) ||
                            _isWorking(entry)))
                      const PopupMenuItem(
                        value: 'manifest',
                        child: Text('Copy manifest XXH64'),
                      ),
                    const PopupMenuItem(
                      value: 'copy',
                      child: Text('Copy folder path'),
                    ),
                    if (entry['devicebridge_peer'] == null)
                      const PopupMenuItem(
                        value: 'forget',
                        child: Text('Unregister folder'),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ],
    );
  }
}
