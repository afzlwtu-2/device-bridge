import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'folder_name_dialog.dart';
import 'registry.dart';
import 'remote_files.dart';

class SyncLocation {
  const SyncLocation({
    required this.device,
    required this.name,
    required this.root,
    required this.path,
    this.localPath,
  });
  final String device, name, root, path;
  final String? localPath;
  bool get local => device == 'local';
  String get label =>
      '$name · ${localPath ?? '$root/${path.isEmpty ? '.' : path}'}';
  Map<String, dynamic> toJson() => {
    'device': device,
    'name': name,
    'root': root,
    'path': path,
    if (localPath != null) 'local_path': localPath,
  };
  factory SyncLocation.fromJson(Map value) => SyncLocation(
    device: '${value['device']}',
    name: '${value['name']}',
    root: '${value['root']}',
    path: '${value['path']}',
    localPath: value['local_path'] as String?,
  );
  Map<String, dynamic> scope() => {
    'root': root,
    'path': path,
    if (local) 'local_path': localPath,
  };
}

String _randomId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

String _friendlySyncError(Object error) => error is PlatformException
    ? error.message ?? 'The sync operation could not complete.'
    : error is StateError
    ? error.message
    : '$error';

Future<SyncLocation?> pickSyncFolder(
  BuildContext context,
  CoreBridge core, {
  required String excludeDevice,
}) => showDialog<SyncLocation>(
  context: context,
  builder: (_) => _SyncFolderPicker(core: core, excludeDevice: excludeDevice),
);

class _SyncFolderPicker extends StatefulWidget {
  const _SyncFolderPicker({required this.core, required this.excludeDevice});
  final CoreBridge core;
  final String excludeDevice;
  @override
  State<_SyncFolderPicker> createState() => _SyncFolderPickerState();
}

class _SyncFolderPickerState extends State<_SyncFolderPicker> {
  List<Map> devices = [], roots = [], entries = [];
  String? device, root, error;
  String path = '';
  String next = '';
  bool busy = true;
  @override
  void initState() {
    super.initState();
    unawaited(initialize());
  }

  Future<void> initialize() async {
    try {
      final peers = await widget.core.run(['peers']) as List;
      devices = [
        if (widget.excludeDevice != 'local')
          {'id': 'local', 'name': 'This device'},
        ...peers.whereType<Map>().where(
          (p) => p['status'] == 'paired' && p['id'] != widget.excludeDevice,
        ),
      ];
      device = devices.firstOrNull?['id'] as String?;
      await load(newDevice: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  Future<void> load({bool newDevice = false, bool append = false}) async {
    if (mounted) {
      setState(() {
        busy = true;
        error = null;
      });
    }
    try {
      if (device == null) {
        throw StateError('Pair another device before creating a folder sync.');
      }
      if (newDevice) {
        path = '';
        final rawRoots = device == 'local'
            ? await widget.core.localFiles('roots', {})
            : await widget.core.run(['roots', device!]);
        roots = (rawRoots as List).whereType<Map>().toList();
        if (device == 'local') {
          roots = roots
              .where((r) => r['available'] == true && r['native_path'] != null)
              .toList();
        }
        final preferred = roots
            .where((entry) => entry['id'] == 'home')
            .firstOrNull;
        root = (preferred ?? roots.firstOrNull)?['id'] as String?;
      }
      if (!append) {
        entries = [];
        next = '';
      }
      if (root != null) {
        final response = device == 'local'
            ? await widget.core.localFiles('list', {
                'kind': root,
                'path': path,
                'next': append ? next : '',
              }) as Map
            : await widget.core.run([
                'list',
                device!,
                root!,
                path.isEmpty ? '.' : path,
                append ? next : '',
              ]) as Map;
        entries.addAll(
          (response['entries'] as List)
              .whereType<Map>()
              .where((e) => e['kind'] == 'directory')
              .toList(),
        );
        next = '${response['next'] ?? ''}';
      }
    } catch (e) {
      error = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> newFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const FolderNameDialog(),
    );
    if (name == null || !mounted) return;
    setState(() => busy = true);
    try {
      if (device == 'local') {
        await widget.core.localFiles('mkdir', {
          'kind': root,
          'path': path,
          'name': name,
        });
      } else {
        await widget.core.run(
          ['sync-control', device!, '-'],
          input: jsonEncode({
            'operation': 'mkdir',
            'root': root,
            'path': path,
            'name': name,
          }),
        );
      }
      path = path.isEmpty || path == '.' ? name : '$path/$name';
      await load();
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  Future<void> select() async {
    try {
      String? native;
      if (device == 'local') {
        native =
            (await widget.core.localFiles('sync-location', {
                  'kind': root,
                  'path': path,
                }) as Map)['path']
                as String;
      }
      if (!mounted) return;
      Navigator.pop(
        context,
        SyncLocation(
          device: device!,
          name: '${devices.firstWhere((d) => d['id'] == device)['name']}',
          root: root ?? 'local',
          path: path,
          localPath: native,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Choose the destination folder'),
    content: SizedBox(
      width: 520,
      height: 420,
      child: Column(
        children: [
          if (devices.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: device,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Device'),
              items: [
                for (final entry in devices)
                  DropdownMenuItem(
                    value: '${entry['id']}',
                    child: Text('${entry['name']}'),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      device = value;
                      load(newDevice: true);
                    },
            ),
          if (roots.isNotEmpty)
            DropdownButtonFormField<String>(
              key: ValueKey('$device:$root'),
              initialValue: root,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Storage'),
              items: [
                for (final entry in roots)
                  DropdownMenuItem(
                    value: '${entry['id']}',
                    child: Text('${entry['name'] ?? entry['id']}'),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) {
                      root = value;
                      path = '';
                      load();
                    },
            ),
          Row(
            children: [
              IconButton(
                tooltip: 'Destination parent folder',
                onPressed: busy || path.isEmpty || path == '.'
                    ? null
                    : () {
                        path = path.contains('/')
                            ? path.substring(0, path.lastIndexOf('/'))
                            : '';
                        load();
                      },
                icon: const Icon(Icons.arrow_upward),
              ),
              Expanded(
                child: Text(
                  path.isEmpty ? '/' : path,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'New destination folder',
                onPressed: busy || root == null ? null : newFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null) Text(error!),
          Expanded(
            child: ListView(
              children: [
                for (final entry in entries)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text('${entry['name']}'),
                    onTap: busy
                        ? null
                        : () {
                            path = '${entry['path']}';
                            load();
                          },
                  ),
                if (next.isNotEmpty)
                  TextButton(
                    onPressed: busy ? null : () => load(append: true),
                    child: const Text('More folders'),
                  ),
              ],
            ),
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
        onPressed: busy || device == null || root == null ? null : select,
        child: const Text('Use this folder'),
      ),
    ],
  );
}

class FolderPairSync extends StatefulWidget {
  const FolderPairSync({
    super.key,
    required this.core,
    required this.source,
    required this.target,
    this.saved,
    this.fullPull,
  });
  final CoreBridge core;
  final SyncLocation source, target;
  final Map<String, dynamic>? saved;
  final Future<void> Function(SyncLocation)? fullPull;
  @override
  State<FolderPairSync> createState() => _FolderPairSyncState();
}

class _FolderPairSyncState extends State<FolderPairSync> {
  late Map<String, dynamic> pair;
  bool busy = false, running = false, remoteApproved = false, firewall = true;
  bool configured = false, stopping = false;
  Future<void>? _stopTask;
  String? message, failure;
  final Map<String, Map> completedLocal = {};
  final Map<String, Future<Map>> localTasks = {};
  final TextEditingController excludes = TextEditingController();
  List<SyncLocation> get endpoints => [widget.source, widget.target];

  @override
  void initState() {
    super.initState();
    configured = widget.saved?['configured'] == true;
    pair = widget.saved == null
        ? {
            'group': 'sync-${_randomId().substring(0, 16)}',
            'source': widget.source.toJson(),
            'target': widget.target.toJson(),
            'mode': 'full',
            'state': 'paused',
            'configured': false,
          }
        : Map.of(widget.saved!);
    excludes.text = (pair['excludes'] as List? ?? []).join('\n');
    unawaited(loadConnection());
    if (pair['state'] == 'running') {
      busy = true;
      running = true;
      unawaited(resume());
    }
  }

  @override
  void dispose() {
    excludes.dispose();
    super.dispose();
  }

  List<String> excludesList() => excludes.text
      .split(RegExp(r'[\n,]'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  SyncLocation get connectionDevice =>
      widget.target.local ? widget.source : widget.target;
  Map<String, dynamic>? connectionCfg;

  Future<void> loadConnection() async {
    try {
      final cfg = Map<String, dynamic>.from(
        await widget.core.run(['connection', connectionDevice.device]) as Map,
      );
      if (mounted) setState(() => connectionCfg = cfg);
    } catch (_) {
      /* Connection display is best-effort; Approve re-reads it. */
    }
  }

  // Returning from the paired device's Connections view refreshes the route.
  // Sync starts only from Approve and sync now.
  Future<void> changeConnection() async {
    final peers = (await widget.core.run(['peers']) as List).whereType<Map>();
    final peer = peers.firstWhere(
      (entry) => entry['id'] == connectionDevice.device,
      orElse: () => <String, dynamic>{
        'id': connectionDevice.device,
        'name': connectionDevice.name,
      },
    );
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DeviceDetail(
          core: widget.core,
          peer: Map<String, dynamic>.from(peer),
          registry: FeatureRegistry()..register(RemoteFilesFeature()),
        ),
      ),
    );
    await loadConnection();
  }

  String get connectionLabel {
    final cfg = connectionCfg;
    if (cfg == null) return 'Loading…';
    final link = '${cfg['active_link'] ?? ''}';
    final transport = link.isNotEmpty
        ? link
        : '${cfg['preferred_transport'] ?? cfg['transport'] ?? 'lan'}';
    return switch (transport) {
      'tailnet' => 'Tailscale',
      'wireguard' => 'WireGuard',
      'wifi_direct' => 'Wi-Fi Direct',
      'hotspot' => 'Hotspot',
      'adb' => 'ADB over USB',
      'ssh' => 'SSH tunnel',
      _ => 'Wi-Fi / LAN',
    };
  }

  Future<Map> control(
    SyncLocation location,
    String operation, {
    Map<String, dynamic> extra = const {},
    bool approved = false,
  }) async {
    final request = {
      ...location.scope(),
      'operation': operation,
      'group': pair['group'],
      ...extra,
    };
    return await widget.core.run([
      if (approved && location.local) '--approve-sync',
      location.local ? 'sync-local' : 'sync-control',
      if (!location.local) location.device,
      '-',
    ], input: jsonEncode(request)) as Map;
  }

  Future<void> save() async {
    await widget.core.run(['sync-pairs', 'save', '-'], input: jsonEncode(pair));
  }

  Future<List<Map>> configure() async {
    if (widget.source.device == widget.target.device) {
      throw StateError(
        'Choose folders on two different devices in the file manager.',
      );
    }
    final exclusions = excludesList();
    final info = <Map>[];
    for (final endpoint in endpoints) {
      info.add(await control(endpoint, 'prepare'));
    }
    pair['excludes'] = exclusions;
    pair['state'] = configured ? 'configuring' : 'draft';
    await save();
    for (var i = 0; i < 2; i++) {
      final extra = <String, dynamic>{
        'peer_id': info[1 - i]['device_id'],
        'role': i == 0 ? 'sendonly' : 'receiveonly',
        'mode': pair['mode'],
        if (pair['mode'] == 'non-git') 'filter': 'working',
        'excludes': pair['excludes'],
      };
      // A lost response can leave a registration on the endpoint.
      pair[i == 0 ? 'source_registered' : 'target_registered'] = true;
      await save();
      await control(
        endpoints[i],
        configured ? 'mode' : 'register',
        extra: extra,
      );
    }
    configured = true;
    pair['configured'] = true;
    pair['state'] = 'paused';
    await save();
    return info;
  }

  Future<void> register() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await configure();
      if (mounted) {
        setState(
          () => message =
              'Folders registered. Sync is paused until you approve a session.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => message = _friendlySyncError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  int ipv4(String value) =>
      value.split('.').fold(0, (n, part) => (n << 8) | int.parse(part));
  bool contains(String cidr, String address) {
    final parts = cidr.split('/');
    final bits = int.parse(parts[1]);
    final mask = bits == 0 ? 0 : (0xffffffff << (32 - bits)) & 0xffffffff;
    return (ipv4(parts[0]) & mask) == (ipv4(address) & mask);
  }

  List<Map<String, dynamic>> routes(List<Map> info) {
    final choices = <Map<String, dynamic>>[];
    for (final a in (info[0]['networks'] as List).whereType<Map>()) {
      for (final b in (info[1]['networks'] as List).whereType<Map>()) {
        final left = '${a['cidr']}'.split('/').first,
            right = '${b['cidr']}'.split('/').first;
        if (a['kind'] == 'loopback' || b['kind'] == 'loopback') continue;
        final lan =
            a['kind'] == 'lan' &&
            b['kind'] == 'lan' &&
            contains('${a['cidr']}', right) &&
            contains('${b['cidr']}', left);
        final tailnet = a['kind'] == 'tailscale' && b['kind'] == 'tailscale';
        choices.add({
          'left': a,
          'right': b,
          'route': lan
              ? 'lan'
              : tailnet
              ? 'tailscale'
              : 'routed',
          'priority': lan
              ? 0
              : tailnet
              ? 1
              : 2,
        });
      }
    }
    choices.sort(
      (a, b) => (a['priority'] as int).compareTo(b['priority'] as int),
    );
    return choices;
  }

  Future<List<String>> endpointPorts() async {
    final ports = <String>[];
    for (final endpoint in endpoints) {
      if (endpoint.local) {
        ports.add('8731');
        continue;
      }
      final resolved =
          await widget.core.run(['resolve', endpoint.device]) as Map;
      ports.add('${resolved['endpoint']}'.split(':').last);
    }
    return ports;
  }

  Future<bool> probeChoice(
    Map<String, dynamic> choice,
    List<String> ports,
  ) async {
    final networks = [choice['left'] as Map, choice['right'] as Map];
    for (var i = 0; i < 2; i++) {
      if (endpoints[1 - i].local) {
        continue; // The local endpoint can probe outward.
      }
      try {
        final here = networks[i], there = networks[1 - i];
        final response = await control(
          endpoints[i],
          'probe',
          extra: {
            'interface': here['interface'],
            'cidr': here['cidr'],
            'listen': '${'${here['cidr']}'.split('/').first}:22001',
            'peer_endpoint':
                '${'${there['cidr']}'.split('/').first}:${ports[1 - i]}',
            'peer_device_id': endpoints[1 - i].device,
            'route': choice['route'],
            'remote_approved': choice['route'] != 'lan' && remoteApproved,
          },
        );
        if (response['reachable'] == true) return true;
      } catch (_) {
        /* Try another endpoint-to-endpoint route; never relay. */
      }
    }
    return false;
  }

  // The connection itself is viewed/changed through the central DeviceDetail
  // Connections view (see changeConnection). Here we only map the currently
  // selected connection onto the two folders' endpoint-to-endpoint networks.
  Future<Map<String, dynamic>> selectRoute(List<Map> info) async {
    final remote = widget.target.local ? widget.source : widget.target;
    final cfg = Map<String, dynamic>.from(
      await widget.core.run(['connection', remote.device]) as Map,
    );
    final link = '${cfg['active_link'] ?? ''}';
    final transport = link.isNotEmpty
        ? link
        : '${cfg['preferred_transport'] ?? cfg['transport'] ?? 'lan'}';
    final endpoint = switch (transport) {
      'tailnet' => '${cfg['tailnet_endpoint'] ?? ''}',
      'wireguard' => '${cfg['wireguard_endpoint'] ?? ''}',
      'adb' => '${cfg['adb_endpoint'] ?? ''}',
      'ssh' => '${cfg['ssh_endpoint'] ?? ''}',
      _ =>
        '${(cfg['endpoint'] ?? '').toString().isNotEmpty ? cfg['endpoint'] : cfg['lan_endpoint'] ?? ''}',
    };
    final wantIp = endpoint.split(':').first;
    Map<String, dynamic>? pick;
    for (final choice in routes(info)) {
      final side =
          (remote.device == widget.source.device
                  ? choice['left']
                  : choice['right'])
              as Map;
      final route = '${choice['route']}';
      if (transport == 'tailnet' && route == 'tailscale') {
        pick = choice;
        break;
      }
      if (transport == 'wireguard' && route == 'routed') {
        pick = choice;
        break;
      }
      if (const {'lan', 'wifi_direct', 'hotspot'}.contains(transport) &&
          route == 'lan' &&
          wantIp.isNotEmpty &&
          contains('${side['cidr']}', wantIp)) {
        pick = choice;
        break;
      }
    }
    if (pick == null) {
      throw StateError(
        'No sync route matches the connection you chose ($transport). Open Connections and pick a reachable one.',
      );
    }
    if (pick['route'] != 'lan' && !remoteApproved) {
      throw StateError('Enable Allow remote route for this sync session.');
    }
    final ports = await endpointPorts();
    if (!await probeChoice(pick, ports)) {
      throw StateError(
        'The chosen connection is not reachable between the two folders. Pick another in Connections.',
      );
    }
    return pick;
  }

  Future<void> start() async {
    setState(() {
      busy = true;
      running = true;
      stopping = false;
      failure = null;
      message = 'Preparing the two endpoints…';
    });
    completedLocal.clear();
    localTasks.clear();
    pair.remove('source_job');
    pair.remove('target_job');
    try {
      final info = await configure();
      if (stopping) throw StateError('Sync was stopped.');
      if (!mounted) return;
      final route = await selectRoute(info);
      final digest = await control(widget.source, 'manifest');
      if (stopping) throw StateError('Sync was stopped.');
      if (!mounted) return;
      final networks = [route['left'] as Map, route['right'] as Map];
      final addresses = List.generate(
        2,
        (i) => '${'${networks[i]['cidr']}'.split('/').first}:${22001 + i}',
      );
      final jobs = [_randomId(), _randomId()];
      pair.addAll({
        'source_job': jobs[0],
        'target_job': jobs[1],
        'state': 'running',
      });
      await save();
      for (var i = 0; i < 2; i++) {
        if (stopping) throw StateError('Sync was stopped.');
        final request = <String, dynamic>{
          'job_id': jobs[i],
          'interface': networks[i]['interface'],
          'cidr': networks[i]['cidr'],
          'listen': addresses[i],
          'peer_endpoint': addresses[1 - i],
          'manifest_xxh64': digest['manifest_xxh64'],
          'bytes': digest['bytes'] ?? 0,
          'seconds': 300,
          'route': route['route'],
          'remote_approved': route['route'] != 'lan' && remoteApproved,
          'open_firewall': firewall,
        };
        if (endpoints[i].local) {
          final task = control(
            endpoints[i],
            'start',
            extra: request,
            approved: true,
          );
          localTasks[jobs[i]] = task;
          unawaited(
            task.then(
              (job) {
                completedLocal[jobs[i]] = job;
              },
              onError: (Object e) {
                completedLocal[jobs[i]] = {
                  'state': 'interrupted',
                  'error': '$e',
                };
              },
            ),
          );
        } else {
          await control(endpoints[i], 'start', extra: request);
          if (stopping) {
            await control(endpoints[i], 'stop', extra: {'job_id': jobs[i]});
          }
        }
      }
      if (stopping) throw StateError('Sync was stopped.');
      if (mounted) {
        setState(
          () => message =
              'Transferring directly between ${widget.source.name} and ${widget.target.name} over ${route['route'] == 'lan' ? 'LAN' : route['route']}. This screen only sends control requests.',
        );
      }
      await waitForJobs(jobs);
    } catch (e) {
      failure = stopping
          ? 'Sync stopped. The folders remain registered for another approved session.'
          : _friendlySyncError(e);
      await stop();
      pair['state'] = 'interrupted';
      try {
        await save();
      } catch (_) {
        /* Local transfer may still be closing. */
      }
      if (mounted) setState(() => message = failure);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          running = false;
        });
      }
    }
  }

  Future<void> waitForJobs(List<String> jobs) async {
    final deadline = DateTime.now().add(const Duration(seconds: 920));
    while (mounted && DateTime.now().isBefore(deadline)) {
      final states = <Map>[];
      for (var i = 0; i < 2; i++) {
        states.add(
          endpoints[i].local && localTasks.containsKey(jobs[i])
              ? completedLocal[jobs[i]] ?? {'state': 'running'}
              : await control(
                  endpoints[i],
                  'status',
                  extra: {'job_id': jobs[i]},
                ),
        );
      }
      if (!mounted) return;
      final failed = states.where((job) => job['state'] == 'interrupted');
      if (failed.isNotEmpty) {
        throw StateError(
          '${failed.first['error'] ?? 'Sync stopped before verification.'}',
        );
      }
      if (states.every((job) => job['state'] == 'verified')) {
        pair['state'] = 'verified';
        await save();
        if (mounted) {
          setState(
            () => message = 'Both folders verified. Sync paused. Data travelled between the two endpoints.',
          );
        }
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    throw StateError(
      'Sync exceeded its approved session. Review the endpoint status.',
    );
  }

  Future<void> resume() async {
    try {
      await waitForJobs(['${pair['source_job']}', '${pair['target_job']}']);
    } catch (e) {
      if (!mounted) return;
      pair['state'] = 'interrupted';
      try {
        await save();
      } catch (_) {
        /* An endpoint may still be closing. */
      }
      if (mounted) setState(() => message = _friendlySyncError(e));
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          running = false;
        });
      }
    }
  }

  Future<void> stop() =>
      _stopTask ??= _stopJobs().whenComplete(() => _stopTask = null);

  Future<void> _stopJobs() async {
    stopping = true;
    if (mounted) setState(() => message = 'Stopping both endpoints…');
    for (var i = 0; i < 2; i++) {
      final id = pair[i == 0 ? 'source_job' : 'target_job'];
      if (id == null) continue;
      try {
        await control(endpoints[i], 'stop', extra: {'job_id': id});
      } catch (_) {
        /* Endpoint expiry/revocation also stops the bounded job. */
      }
    }
    for (final task in localTasks.values) {
      try {
        await task.timeout(const Duration(seconds: 10));
      } catch (_) {
        /* Keep bounded endpoint errors visible through job status. */
      }
    }
  }

  Future<void> forget() async {
    setState(() => busy = true);
    try {
      for (var i = 0; i < endpoints.length; i++) {
        if (configured ||
            pair[i == 0 ? 'source_registered' : 'target_registered'] == true) {
          await control(endpoints[i], 'forget');
          pair[i == 0 ? 'source_registered' : 'target_registered'] = false;
          configured = false;
          pair['configured'] = false;
          pair['state'] = 'draft';
          await save();
        }
      }
      await widget.core.run(['sync-pairs', 'forget', '${pair['group']}']);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          message = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Folder sync'),
      actions: [
        if (widget.fullPull != null)
          PopupMenuButton<int>(
            tooltip: 'Full pull to this device',
            enabled: !busy,
            onSelected: (index) => widget.fullPull!(endpoints[index]),
            itemBuilder: (_) => [
              for (var i = 0; i < endpoints.length; i++)
                if (!endpoints[i].local)
                  PopupMenuItem(
                    value: i,
                    child: Text(
                      'Full pull from ${endpoints[i].name} to this device',
                    ),
                  ),
            ],
          ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Source', style: Theme.of(context).textTheme.titleMedium),
        SelectableText(widget.source.label),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Icon(Icons.arrow_downward),
        ),
        Text('Destination', style: Theme.of(context).textTheme.titleMedium),
        SelectableText(widget.target.label),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.settings_ethernet),
          title: const Text('Connection'),
          subtitle: Text('${connectionDevice.name} · $connectionLabel'),
          trailing: const Icon(Icons.chevron_right),
          onTap: busy ? null : changeConnection,
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: '${pair['mode']}',
          decoration: const InputDecoration(labelText: 'Sync mode'),
          items: const [
            DropdownMenuItem(
              value: 'full',
              child: Text('Full folder, hidden and Git files'),
            ),
            DropdownMenuItem(
              value: 'non-git',
              child: Text('All working files except .git'),
            ),
          ],
          onChanged: busy
              ? null
              : (value) => setState(() => pair['mode'] = value),
        ),
        const SizedBox(height: 12),
        Text(
          pair['mode'] == 'full'
              ? 'Includes hidden files, Git history, secrets and caches. Review the selected folders. Existing destination files may be updated by the approved mirror.'
              : 'Copies working files without Git metadata. Git and unrelated local files stay in place; changed baseline files have recovery copies. Concurrent edits block import.',
        ),
        const SizedBox(height: 12),
        TextField(
          controller: excludes,
          enabled: !busy,
          minLines: 1,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Exclude folders (optional)',
            hintText: 'One relative path per line, e.g. build/ or .dart_tool',
            helperText: 'Whole subtrees left out of the verified sync and the transfer. Symlinks and special files in the remaining folders are still blocked.',
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: remoteApproved,
          onChanged: busy
              ? null
              : (value) => setState(() => remoteApproved = value ?? false),
          title: const Text('Allow remote route'),
          subtitle: const Text(
            'Permit the selected Tailscale or routed connection for this session. Both endpoints must allow remote sync.',
          ),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: firewall,
          onChanged: busy
              ? null
              : (value) => setState(() => firewall = value ?? true),
          title: const Text('Allow temporary scoped firewall access'),
          subtitle: const Text(
            'Only the peer address and dedicated sync port, removed when the session stops.',
          ),
        ),
        const Text(
          'Transfers run between the selected devices. This device only coordinates when neither folder is local. No automatic background sync or phone relay.',
        ),
        const SizedBox(height: 16),
        if (busy) const LinearProgressIndicator(),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SelectableText(message!),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: busy ? null : register,
              child: Text(
                configured ? 'Save sync mode' : 'Register these folders',
              ),
            ),
            FilledButton.icon(
              onPressed: busy ? null : start,
              icon: const Icon(Icons.sync),
              label: const Text('Approve and sync now'),
            ),
            if (running)
              OutlinedButton(
                onPressed: stopping ? null : stop,
                child: const Text('Stop both endpoints'),
              ),
            if (configured ||
                widget.saved != null ||
                pair['source_registered'] == true ||
                pair['target_registered'] == true)
              TextButton(
                onPressed: busy ? null : forget,
                child: const Text('Remove folder sync'),
              ),
          ],
        ),
      ],
    ),
  );
}
