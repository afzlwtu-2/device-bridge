import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'core/bridge.dart';
import 'features/registry.dart';
import 'features/remote_files.dart';
import 'features/pair_dialog.dart';

void main() => runApp(DeviceBridgeApp(core: LocalCore()));

class DeviceBridgeApp extends StatelessWidget {
  const DeviceBridgeApp({super.key, required this.core});
  final CoreBridge core;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'DeviceBridge',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176b62)),
      scaffoldBackgroundColor: const Color(0xfff4f7f6),
      useMaterial3: true,
    ),
    home: BridgeHome(core: core),
  );
}

class BridgeHome extends StatefulWidget {
  const BridgeHome({super.key, required this.core});
  final CoreBridge core;
  @override
  State<BridgeHome> createState() => _BridgeHomeState();
}

class _BridgeHomeState extends State<BridgeHome> {
  int tab = 0;
  bool busy = true;
  String? error;
  List<dynamic> peers = [], candidates = [];
  Map<String, dynamic>? identity;
  final registry = FeatureRegistry()..register(RemoteFilesFeature());
  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() => task(() async {
    await widget.core.initialize();
    identity = Map<String, dynamic>.from(
      await widget.core.run(['identity']) as Map,
    );
    await refreshPeers();
  });
  Future<void> refreshPeers() async {
    peers = await widget.core.run(['peers']) as List;
  }

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
      if (mounted) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> selectNetwork() => task(() async {
    final networks = await widget.core.networks();
    if (!mounted) {
      return;
    }
    final selected = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Approve a local network'),
        children: [
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Choose an unmetered LAN you trust. Transfers stay on this network, with no relay or cellular fallback.',
            ),
          ),
          if (networks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('No supported local Wi-Fi network is available.'),
            ),
          ...networks.map(
            (n) => SimpleDialogOption(
              onPressed: () => Navigator.pop(context, n),
              child: ListTile(
                leading: const Icon(Icons.wifi),
                title: Text('${n['interface']} · ${n['cidr']}'),
                subtitle: Text('${n['metered']}'),
              ),
            ),
          ),
        ],
      ),
    );
    if (selected != null) {
      await widget.core.approveNetwork(selected);
    }
  });
  Future<void> discover() async {
    if (widget.core.network == null) {
      await selectNetwork();
    }
    if (widget.core.network == null) {
      return;
    }
    await task(() async {
      candidates = await widget.core.run(['discover']) as List;
      await refreshPeers();
    });
  }

  Future<void> pair() async {
    if (widget.core.network == null) {
      await selectNetwork();
    }
    if (widget.core.network == null || !mounted) {
      return;
    }
    final invite = await showDialog<String>(
      context: context,
      builder: (_) => const PairInvitationDialog(),
    );
    if (invite == null || !mounted) {
      return;
    }
    await task(() async {
      final value = jsonDecode(invite) as Map;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Pair with ${value['name']}?'),
          content: SelectableText(
            'Verify this fingerprint on your other device:\n\n${value['id']}\n\nThe other device must separately approve your access.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Fingerprint matches'),
            ),
          ],
        ),
      );
      if (approved == true) {
        await widget.core.run(['pair', '-'], input: invite);
        await refreshPeers();
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Row(
        children: [
          const Icon(Icons.hub_outlined),
          const SizedBox(width: 12),
          Text(['DeviceBridge', 'Devices', 'Share', 'Sync'][tab]),
        ],
      ),
      actions: [
        IconButton(
          onPressed: busy ? null : selectNetwork,
          icon: const Icon(Icons.wifi),
          tooltip: 'Approved network',
        ),
      ],
    ),
    body: SafeArea(
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
                child: switch (tab) {
                  0 => home(),
                  1 => devices(),
                  2 => unavailable(
                    'Quick sharing',
                    'One-off sending and clipboard sharing arrive after browse and pull are verified.',
                    Icons.send_outlined,
                  ),
                  _ => unavailable(
                    'Registered folder sync',
                    'Synchronization is disabled. No folders are registered or changed.',
                    Icons.sync_disabled,
                  ),
                },
              ),
            ],
          ),
        ),
      ),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (v) => setState(() => tab = v),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.devices_outlined),
          label: 'Devices',
        ),
        NavigationDestination(icon: Icon(Icons.send_outlined), label: 'Share'),
        NavigationDestination(icon: Icon(Icons.sync_outlined), label: 'Sync'),
      ],
    ),
  );
  Widget home() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Text(
        'Your devices. One connection.',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 10),
      const Text(
        'Browse approved folders and bring files home over your local network.',
      ),
      const SizedBox(height: 24),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                identity?['name'] as String? ?? 'Starting the core…',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                widget.core.network == null
                    ? 'Choose a local network to begin'
                    : 'Approved LAN · ${widget.core.network!['interface']} · ${widget.core.network!['cidr']}',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: busy ? null : discover,
                    icon: const Icon(Icons.radar),
                    label: const Text('Find devices'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : pair,
                    icon: const Icon(Icons.link),
                    label: const Text('Pair device'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 24),
      Text(
        '${peers.where((p) => p['status'] == 'paired').length} paired devices',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      ...peerCards(),
      const SizedBox(height: 24),
      const Text(
        'Pulls are one-time downloads. They never register a folder for synchronization.',
      ),
    ],
  );
  Widget devices() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FilledButton.icon(
            onPressed: busy ? null : discover,
            icon: const Icon(Icons.radar),
            label: const Text('Discover on LAN'),
          ),
          OutlinedButton(
            onPressed: busy ? null : pair,
            child: const Text('Pair device'),
          ),
        ],
      ),
      const SizedBox(height: 20),
      ...peerCards(),
      if (peers.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text(
            'No paired devices yet. Pair using an invitation from your other device.',
          ),
        ),
      if (candidates.isNotEmpty) ...[
        const SizedBox(height: 24),
        const Text('LAN advertisements · identity verified when connecting'),
        ...candidates.map(
          (v) => ListTile(
            leading: const Icon(Icons.wifi),
            title: Text('${v['endpoint']}'),
            subtitle: Text('${v['device_id']}'),
          ),
        ),
      ],
    ],
  );
  List<Widget> peerCards() => peers
      .map(
        (p) => Card(
          child: ListTile(
            leading: const Icon(Icons.computer),
            title: Text('${p['name']}'),
            subtitle: Text('${p['status']} · reachability checked on demand'),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy
                ? null
                : () async {
                    if (p['status'] == 'outbound') {
                      await task(() async {
                        await widget.core.run(['finish', p['id'] as String]);
                        await refreshPeers();
                      });
                    } else if (p['status'] == 'paired') {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => DeviceDetail(
                            core: widget.core,
                            peer: Map<String, dynamic>.from(p as Map),
                            registry: registry,
                          ),
                        ),
                      );
                      await task(refreshPeers);
                    }
                  },
          ),
        ),
      )
      .toList();
  Widget unavailable(String title, String detail, IconData icon) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(detail, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
