import 'dart:convert';
import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'core/bridge.dart';
import 'features/registry.dart';
import 'features/remote_files.dart';
import 'features/pair_dialog.dart';
import 'features/ssh_bootstrap.dart';
import 'features/device_addresses.dart';
import 'features/incoming_pair.dart';
import 'features/connections_hub.dart';
import 'features/appearance.dart';
import 'features/settings_screen.dart';
import 'features/phone_files.dart';

import 'dart:io';

void main() => runApp(DeviceBridgeApp(core: LocalCore()));

class DeviceBridgeApp extends StatefulWidget {
  const DeviceBridgeApp({super.key, required this.core});
  final CoreBridge core;
  @override
  State<DeviceBridgeApp> createState() => _DeviceBridgeAppState();
}

class _DeviceBridgeAppState extends State<DeviceBridgeApp> {
  String appearance = 'system';
  ThemeData get dark {
    if (isAmoledTheme(appearance)) {
      return amoledTheme(appearance);
    }
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff41c6b5),
      brightness: Brightness.dark,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xff101615),
      useMaterial3: true,
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'DeviceBridge',
    debugShowCheckedModeBanner: false,
    theme: appearance == 'matte'
        ? mattePaperTheme()
        : ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff176b62),
            ),
            scaffoldBackgroundColor: const Color(0xfff4f7f6),
            useMaterial3: true,
          ),
    darkTheme: dark,
    builder: (context, child) => AppearanceSurface(
      appearance: appearance,
      child: child ?? const SizedBox.shrink(),
    ),
    themeMode: appearance == 'system'
        ? ThemeMode.system
        : appearance == 'light' || appearance == 'matte'
        ? ThemeMode.light
        : ThemeMode.dark,
    home: BridgeHome(
      core: widget.core,
      appearance: appearance,
      onAppearance: (value) {
        if (mounted) {
          setState(() => appearance = value);
        }
      },
    ),
  );
}

class BridgeHome extends StatefulWidget {
  const BridgeHome({
    super.key,
    required this.core,
    required this.appearance,
    required this.onAppearance,
  });
  final CoreBridge core;
  final String appearance;
  final ValueChanged<String> onAppearance;
  @override
  State<BridgeHome> createState() => _BridgeHomeState();
}

class _BridgeHomeState extends State<BridgeHome> {
  int tab = 0;
  bool busy = true;
  String? error;
  List<dynamic> peers = [], candidates = [];
  Map<String, dynamic>? identity;
  StreamSubscription<Map<String, dynamic>>? networkEvents;
  String? listenerState;
  Timer? networkRefresh;
  final registry = FeatureRegistry()..register(RemoteFilesFeature());
  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() => task(() async {
    networkEvents = widget.core.networkEvents.listen((event) {
      if (!mounted) {
        return;
      }
      candidates = [];
      setState(() => listenerState = event['state'] as String?);
      networkRefresh?.cancel();
      if (event['state'] == 'active') {
        networkRefresh = Timer(const Duration(milliseconds: 250), () {
          if (mounted && !busy) {
            discover();
          }
        });
      }
    });
    await widget.core.initialize();
    final appearance = await widget.core.run(['theme']) as Map;
    widget.onAppearance(appearance['theme'] as String? ?? 'system');
    identity = Map<String, dynamic>.from(
      await widget.core.run(['identity']) as Map,
    );
    await refreshPeers();
  });
  @override
  void dispose() {
    networkEvents?.cancel();
    networkRefresh?.cancel();
    widget.core.shutdown();
    super.dispose();
  }

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
      if (!mounted) {
        return;
      }
      final roaming = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Recover on other Wi-Fi networks?'),
          content: const Text(
            'Allow automatic reconnection on unmetered Wi-Fi after network changes. Metered Wi-Fi and cellular will still require separate approval.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Only this network'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Allow unmetered Wi-Fi'),
            ),
          ],
        ),
      );
      selected['allow_wifi_roaming'] = roaming == true;
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
      candidates = (await widget.core.run(['discover']) as List)
          .where((v) => v['device_id'] != identity?['id'])
          .toList();
      await refreshPeers();
    });
  }

  Future<void> invite() async {
    if (widget.core.network == null) {
      await selectNetwork();
    }
    if (widget.core.network == null || !mounted) {
      return;
    }
    await task(() async {
      final value = await widget.core.run(['invite']);
      if (!mounted) {
        return;
      }
      final code = jsonEncode(value);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Invite another device'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'This code expires in five minutes. Send it only to the device you intend to pair. Approve its request here afterward.',
                  ),
                  const SizedBox(height: 16),
                  SelectableText(code),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              child: const Text('Copy code'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> pair() async {
    var tailnetPeers = <Map<String, dynamic>>[];
    try {
      final st = await widget.core.run(['tailnet', 'status']) as Map;
      tailnetPeers = (st['peers'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      /* app-only tailnet may be off */
    }
    if (widget.core.network == null && tailnetPeers.isEmpty) {
      await selectNetwork();
    }
    if ((widget.core.network == null && tailnetPeers.isEmpty) || !mounted) {
      return;
    }
    final result = await showDialog<PairInvitationResult>(
      context: context,
      builder: (_) => PairInvitationDialog(tailnetPeers: tailnetPeers),
    );
    if (result == null || !mounted) {
      return;
    }
    final invite = result.invite;
    final tailnetEndpoint = result.tailnetEndpoint;
    await task(() async {
      final value = jsonDecode(invite) as Map;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Pair with ${value['name']}?'),
          content: SelectableText(
            'Verify this fingerprint on your other device:\n\n${value['id']}\n${tailnetEndpoint != null ? '\nRoute: Tailscale ($tailnetEndpoint)\n' : ''}\nThe other device must separately approve your access.',
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
        if (tailnetEndpoint != null && tailnetEndpoint.isNotEmpty) {
          await widget.core.run([
            '--transport',
            'tailnet',
            '--endpoint',
            tailnetEndpoint,
            '--approve-remote',
            'pair',
            '-',
          ], input: invite);
          await widget.core.run(
            ['connection', value['id'] as String, '-'],
            input: jsonEncode({
              'peer_id': value['id'],
              'transport': 'tailnet',
              'endpoint': tailnetEndpoint,
              'remote_approved': true,
            }),
          );
        } else {
          await widget.core.run(['pair', '-'], input: invite);
        }
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
          Flexible(
            child: Text(
              ['DeviceBridge', 'Devices', 'Share', 'Sync'][tab],
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => SettingsScreen(core: widget.core),
            ),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Appearance',
          icon: const Icon(Icons.brightness_6_outlined),
          onSelected: (value) async {
            await widget.core.run(['theme', value]);
            widget.onAppearance(value);
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'system', child: Text('System theme')),
            PopupMenuItem(value: 'light', child: Text('Light')),
            PopupMenuItem(value: 'dark', child: Text('Dark')),
            PopupMenuItem(
              value: 'amoled-green',
              child: Text('AMOLED black · Neon green'),
            ),
            PopupMenuItem(
              value: 'amoled-red',
              child: Text('AMOLED black · Neon red'),
            ),
            PopupMenuItem(value: 'matte', child: Text('Matte paper')),
          ],
        ),
        IconButton(
          onPressed: busy
              ? null
              : () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ConnectionsHub(
                      core: widget.core,
                      listenerState: listenerState,
                      onSelectNetwork: selectNetwork,
                    ),
                  ),
                ),
          icon: const Icon(Icons.wifi),
          tooltip: 'Connections',
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
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: amoledNavIcon(context, Icons.home, widget.appearance),
          label: 'Home',
        ),
        NavigationDestination(
          icon: const Icon(Icons.devices_outlined),
          selectedIcon: amoledNavIcon(
            context,
            Icons.devices,
            widget.appearance,
          ),
          label: 'Devices',
        ),
        NavigationDestination(
          icon: const Icon(Icons.send_outlined),
          selectedIcon: amoledNavIcon(context, Icons.send, widget.appearance),
          label: 'Share',
        ),
        NavigationDestination(
          icon: const Icon(Icons.sync_outlined),
          selectedIcon: amoledNavIcon(context, Icons.sync, widget.appearance),
          label: 'Sync',
        ),
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
              if (listenerState != null)
                Text(switch (listenerState) {
                  'active' => 'Discoverable on this LAN while the app is open',
                  'approval_required' => 'New network · approval required',
                  'offline' => 'Wi-Fi disconnected · transfers paused',
                  'receiver_error' =>
                    'LAN listener unavailable · choose network to retry',
                  _ => 'Recovering LAN connection…',
                }),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  if (Platform.isAndroid)
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => PhoneFiles(core: widget.core),
                              ),
                            ),
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('File manager'),
                    ),
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
                  OutlinedButton.icon(
                    onPressed: busy ? null : invite,
                    icon: const Icon(Icons.qr_code),
                    label: const Text('Create invitation'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (_) =>
                                  SshBootstrapDialog(core: widget.core),
                            );
                            if (ok == true) {
                              await refreshPeers();
                            }
                          },
                    icon: const Icon(Icons.terminal),
                    label: const Text('Setup via SSH'),
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
            subtitle: DeviceAddresses(
              peer: Map<String, dynamic>.from(p),
              candidates: candidates,
            ),
            isThreeLine: true,
            trailing: const Icon(Icons.chevron_right),
            onTap: busy
                ? null
                : () async {
                    if (p['status'] == 'pending') {
                      final allow = await showDialog<bool>(
                        context: context,
                        builder: (_) => IncomingPairDialog(
                          peer: Map<String, dynamic>.from(p),
                        ),
                      );
                      if (allow != null) {
                        await task(() async {
                          await widget.core.run([
                            'approve',
                            p['id'] as String,
                            allow ? 'all' : '',
                            '8760h',
                            '1099511627776',
                          ]);
                          await refreshPeers();
                        });
                      }
                    } else if (p['status'] == 'outbound') {
                      await task(() async {
                        await widget.core.run(['finish', p['id'] as String]);
                        await refreshPeers();
                      });
                    } else if (p['status'] == 'revoked') {
                      final remove = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text('Remove ${p['name']}?'),
                          content: const Text(
                            'This device is revoked. Remove it from your device list?',
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
                      if (remove == true) {
                        await task(() async {
                          await widget.core.run(['remove', p['id'] as String]);
                          await refreshPeers();
                        });
                      }
                    } else if (p['status'] == 'paired') {
                      await Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => DeviceDetail(
                            core: widget.core,
                            peer: Map<String, dynamic>.from(p),
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
