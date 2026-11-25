import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

/// Network settings and status panel for Tailscale (app-private tsnet or system tailscaled).
class TailnetPanel extends StatefulWidget {
  const TailnetPanel({super.key, required this.core});
  final CoreBridge core;
  @override
  State<TailnetPanel> createState() => _TailnetPanelState();
}

class _TailnetPanelState extends State<TailnetPanel>
    with WidgetsBindingObserver {
  Map<dynamic, dynamic>? status;
  Map<String, dynamic> settingsValues = {};
  String? error;
  String? notice;
  bool busy = true;
  bool saving = false;
  Timer? retry;
  int retries = 0;
  double? liveMiB;
  final Map<String, Map<String, dynamic>> probeResults = {};
  StreamSubscription<Map<String, dynamic>>? progressSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    progressSub = widget.core.transferProgress.listen((p) {
      if (mounted) {
        setState(() => liveMiB = (p['mib_per_second'] as num?)?.toDouble());
      }
    });
    load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      retries = 0;
      load(pollUntilRunning: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    progressSub?.cancel();
    retry?.cancel();
    super.dispose();
  }

  String _formatError(Object err) {
    if (err is PlatformException) {
      final raw = err.message ?? err.toString();
      final match = RegExp(r'"message"\s*:\s*"([^"]+)"').firstMatch(raw);
      if (match != null) {
        final msg = match.group(1)!;
        if (msg.contains('not running')) {
          return 'App-only Tailscale is off. Select a Wi-Fi or Hotspot network in Networks, then tap Enable app-only Tailscale.';
        }
        return msg;
      }
      return raw;
    }
    return err.toString();
  }

  Future<void> load({bool pollUntilRunning = false, bool silent = false}) async {
    if (mounted && !silent) {
      setState(() => busy = true);
    }
    Map<dynamic, dynamic>? nextStatus;
    String? nextError;
    try {
      final res = await widget.core.run(['tailnet', 'status']);
      if (res is Map) {
        nextStatus = res;
      } else {
        nextStatus = null;
      }
    } catch (e) {
      nextStatus = null;
      nextError = _formatError(e);
    }
    Map<String, dynamic> nextSettings = settingsValues;
    try {
      nextSettings = await widget.core.appSettings();
    } catch (_) {}
    if (mounted) {
      setState(() {
        status = nextStatus;
        error = nextError;
        settingsValues = nextSettings;
        busy = false;
      });
      if (pollUntilRunning &&
          status?['state'] != 'Running' &&
          retries++ < 30) {
        retry?.cancel();
        retry = Timer(const Duration(seconds: 1), () {
          if (mounted) {
            load(pollUntilRunning: true, silent: true);
          }
        });
      }
    }
  }

  Future<void> _saveTsnetSettings(Map<String, dynamic> update) async {
    if (saving) {
      return;
    }
    setState(() {
      saving = true;
      notice = null;
    });
    try {
      final updated = await widget.core.appSettings(update: update);
      Map<dynamic, dynamic>? refreshedStatus = status;
      try {
        final res = await widget.core.run(['tailnet', 'status']);
        if (res is Map) {
          refreshedStatus = res;
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          settingsValues = updated;
          status = refreshedStatus;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = _formatError(e));
      }
    } finally {
      if (mounted) {
        setState(() => saving = false);
      }
    }
  }

  Future<void> _editSocksPort(int currentPort) async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => _TsnetTextPromptDialog(
        title: 'SOCKS5 listen port',
        labelText: 'Port (1024–65535)',
        hintText: '1055',
        confirmLabel: 'Save',
        initialValue: '$currentPort',
        keyboardType: TextInputType.number,
        validate: (v) {
          final parsed = int.tryParse(v.trim());
          return parsed != null && parsed >= 1024 && parsed <= 65535;
        },
      ),
    );
    final port = raw == null ? null : int.tryParse(raw.trim());
    if (port != null) {
      await _saveTsnetSettings({'tsnet_socks5_port': port});
    }
  }

  Future<void> _pickExitNode(
    String currentId,
    List<Map<String, dynamic>> exitNodes,
  ) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select SOCKS5 / tsnet exit node'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                    currentId.isEmpty
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: const Text('None (Direct)'),
                  subtitle: const Text(
                    'Route only tailnet peers through tsnet',
                  ),
                  onTap: () => Navigator.of(ctx).pop(''),
                ),
                if (exitNodes.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Connect and log in to Tailscale to load advertised exit-node peers.',
                    ),
                  ),
                for (final node in exitNodes)
                  ListTile(
                    leading: Icon(
                      currentId == '${node['id'] ?? ''}'
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: Text(
                      '${(node['name'] ?? '').toString().isNotEmpty ? node['name'] : (node['id'] ?? 'Exit node')}',
                    ),
                    subtitle: Text(
                      [
                        if (node['online'] == true) 'Online' else 'Offline',
                        if (node['ips'] is List &&
                            (node['ips'] as List).isNotEmpty)
                          '${(node['ips'] as List).first}',
                      ].join(' · '),
                    ),
                    onTap: () =>
                        Navigator.of(ctx).pop('${node['id'] ?? ''}'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
    if (picked != null) {
      await _saveTsnetSettings({'tsnet_exit_node_id': picked});
    }
  }

  Future<void> enable() async {
    setState(() => busy = true);
    retries = 0;
    try {
      await widget.core.enableTailnet(true);
      await load(pollUntilRunning: true, silent: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = _formatError(e);
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final system = status?['mode'] == 'system';
    final login = status?['login_url'] as String?;
    final tsState = '${status?['state'] ?? (status == null ? 'Disconnected' : 'Unknown')}';
    final tsLoggedIn = tsState == 'Running';
    final socks5Enabled = settingsValues['tsnet_socks5_enabled'] == true;
    final socks5Port =
        (settingsValues['tsnet_socks5_port'] as num?)?.toInt() ?? 1055;
    final liveSocksAddr = '${status?['socks5_addr'] ?? ''}';
    final socks5Addr =
        liveSocksAddr.isNotEmpty ? liveSocksAddr : '127.0.0.1:$socks5Port';
    final exitNodeId = '${settingsValues['tsnet_exit_node_id'] ?? ''}';
    final tsPeers = (status?['peers'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
    final exitNodes =
        tsPeers.where((p) => p['exit_node_option'] == true).toList();
    String exitNodeLabel = 'None (Direct)';
    if (exitNodeId.isNotEmpty) {
      final matched = exitNodes.where((p) => '${p['id'] ?? ''}' == exitNodeId);
      if (matched.isNotEmpty) {
        final name = '${matched.first['name'] ?? ''}'.trim();
        exitNodeLabel = name.isNotEmpty ? name : exitNodeId;
      } else {
        exitNodeLabel = exitNodeId;
      }
    }
    final tailscaleSSHEnabled = settingsValues['tsnet_ssh_enabled'] != false;
    final openSSHEnabled = settingsValues['tsnet_openssh_enabled'] == true;
    final ips = (status?['ips'] as List? ?? const []);
    final hostname = (status?['hostname'] as String?)?.trim() ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('Tailscale connectivity')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (busy || saving) const LinearProgressIndicator(),
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: MaterialBanner(
                content: Text(notice!),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => notice = null),
                    child: const Text('OK'),
                  ),
                ],
              ),
            ),
          Text(
            system ? 'Existing system Tailscale' : 'App-only Tailscale',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            system
                ? 'DeviceBridge uses the existing laptop agent. Its settings and credentials are managed by Tailscale.'
                : 'DeviceBridge runs its own Tailscale node. The local SOCKS5 proxy lets configured apps use that node and keeps it active in the background.',
          ),
          const SizedBox(height: 20),
          if (status != null) ...[
            if (hostname.isNotEmpty) SelectableText('Hostname: $hostname'),
            Text('Status: $tsState'),
            for (final ip in ips) SelectableText('Tailscale IP: $ip'),
            const SizedBox(height: 12),
          ],
          if (error != null) Text(error!),
          const SizedBox(height: 12),
          if (!system)
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  onPressed: busy ? null : enable,
                  child: const Text('Enable app-only Tailscale'),
                ),
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () async {
                          try {
                            await widget.core.enableTailnet(false);
                          } catch (_) {}
                          await load();
                        },
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          TextButton.icon(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh status'),
          ),
          if (login != null && login.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Log in to authorize this DeviceBridge node. No passwords or permanent auth keys are stored in the interface.',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => widget.core.openLogin(login),
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Log in to Tailscale'),
            ),
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: login)),
              child: const Text('Copy login link'),
            ),
          ],
          if (!system) ...[
            const SizedBox(height: 20),
            Text(
              'Tailscale (tsnet) settings',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.vpn_lock_outlined),
                    title: Text('tsnet node · $tsState'),
                    subtitle: Text(
                      [
                        if (!tsLoggedIn)
                          'Tailscale is not logged in / disconnected — saved settings apply automatically once logged in'
                        else if (socks5Enabled)
                          'SOCKS5 listening on socks5h://$socks5Addr (proxy-capable apps & CLI isolate without interrupting other traffic)'
                        else
                          'Enable SOCKS5 to let proxy-capable apps and Termux commands use tsnet without interrupting other traffic',
                        if (exitNodeId.isNotEmpty) 'Exit node: $exitNodeLabel',
                      ].join(' · '),
                    ),
                    trailing: socks5Enabled
                        ? IconButton(
                            tooltip: 'Copy SOCKS5 URL',
                            onPressed: () async {
                              final url = 'socks5h://$socks5Addr';
                              await Clipboard.setData(
                                ClipboardData(text: url),
                              );
                              if (mounted) {
                                setState(() => notice = 'Copied $url');
                              }
                            },
                            icon: const Icon(Icons.copy_outlined),
                          )
                        : null,
                  ),
                  const Divider(height: 1),
                  SwitchListTile.adaptive(
                    title: const Text('Local SOCKS5 proxy'),
                    subtitle: Text(
                      '127.0.0.1:$socks5Port · runs in the background with a Stop proxy notification',
                    ),
                    value: socks5Enabled,
                    onChanged: saving
                        ? null
                        : (value) =>
                            _saveTsnetSettings({'tsnet_socks5_enabled': value}),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.settings_ethernet),
                    title: const Text('SOCKS5 listen port'),
                    subtitle: Text('127.0.0.1:$socks5Port (1024–65535)'),
                    trailing: const Icon(Icons.edit_outlined),
                    onTap: saving ? null : () => _editSocksPort(socks5Port),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.alt_route_outlined),
                    title: const Text('SOCKS5 & tsnet exit node'),
                    subtitle: Text(
                      tsLoggedIn
                          ? '$exitNodeLabel · ${exitNodes.length} exit-node peer(s) advertised'
                          : '$exitNodeLabel · connect & log in to load exit-node peers',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: saving
                        ? null
                        : () => _pickExitNode(exitNodeId, exitNodes),
                  ),
                  const Divider(height: 1),
                  SwitchListTile.adaptive(
                    title: const Text('Tailscale SSH (:22)'),
                    subtitle: Text(
                      tailscaleSSHEnabled
                          ? 'Enabled (--ssh) · Access controlled directly by Tailscale Admin Console ACLs'
                          : 'Disabled · Enable to run Tailscale SSH (--ssh) on port 22',
                    ),
                    value: tailscaleSSHEnabled,
                    onChanged: saving
                        ? null
                        : (value) => _saveTsnetSettings({
                            'tsnet_ssh_enabled': value,
                          }),
                  ),
                  const Divider(height: 1),
                  SwitchListTile.adaptive(
                    title: const Text('OpenSSH server (port 8022)'),
                    subtitle: const Text(
                      'Off by default. Listens on non-loopback, non-Tailscale interfaces with key auth only.',
                    ),
                    value: openSSHEnabled,
                    onChanged: saving
                        ? null
                        : (value) => _saveTsnetSettings({
                            'tsnet_openssh_enabled': value,
                          }),
                  ),
                ],
              ),
            ),
          ],
          if (status != null && tsPeers.isNotEmpty) ...[
            const SizedBox(height: 20),
            Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                initiallyExpanded: false,
                leading: const Icon(Icons.devices_other_outlined),
                title: Text('Tailscale peers (${tsPeers.length})'),
                subtitle: const Text(
                  'Tap to expand and probe Direct vs DERP paths',
                ),
                children: [
                  for (final peer in tsPeers)
                    for (final ip in (peer['ips'] as List? ?? const []))
                      if (!'$ip'.contains(':'))
                        ListTile(
                          dense: true,
                          leading: Icon(
                            peer['online'] == true
                                ? Icons.computer
                                : Icons.cloud_off,
                          ),
                          title: Text('${peer['name'] ?? 'Peer'} · $ip'),
                          subtitle: Text(
                            probeResults.containsKey('$ip')
                                ? 'Path: ${probeResults['$ip']!['kind']}'
                                      '${(probeResults['$ip']!['endpoint'] as String? ?? '').isNotEmpty ? ' (${probeResults['$ip']!['endpoint']})' : ''}'
                                      '${(probeResults['$ip']!['relay'] as String? ?? '').isNotEmpty ? ' · relay ${probeResults['$ip']!['relay']}' : ''}'
                                      ' · ${(((probeResults['$ip']!['rtt_seconds'] as num? ?? 0)) * 1000).toStringAsFixed(1)} ms'
                                : (peer['online'] == true
                                      ? 'Online'
                                      : 'Offline'),
                          ),
                          trailing: OutlinedButton(
                            onPressed: system || busy
                                ? null
                                : () async {
                                    setState(() => busy = true);
                                    try {
                                      final res = await widget.core.run([
                                        'tailnet',
                                        'probe',
                                        '$ip:8731',
                                      ]);
                                      if (res is Map) {
                                        final p = res['path'] as Map?;
                                        if (p != null && mounted) {
                                          probeResults['$ip'] =
                                              Map<String, dynamic>.from(p);
                                        }
                                      }
                                      error = null;
                                    } catch (e) {
                                      error = _formatError(e);
                                    }
                                    if (mounted) {
                                      setState(() => busy = false);
                                    }
                                  },
                            child: const Text('Probe'),
                          ),
                        ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          const Text(
            'Connection paths are measured per peer. Direct, DERP relay, peer relay and unknown are shown separately. A path can change after a measurement. Remote bulk data requires explicit per-device approval; LAN never silently falls back to Tailscale.',
          ),
          const SizedBox(height: 12),
          Text(
            liveMiB != null && liveMiB! > 0
                ? 'Transfer rate: ${liveMiB!.toStringAsFixed(2)} MiB/s'
                : 'Transfer rate: — MiB/s (no active transfer)',
          ),
        ],
      ),
    );
  }
}

class _TsnetTextPromptDialog extends StatefulWidget {
  const _TsnetTextPromptDialog({
    required this.title,
    required this.labelText,
    required this.hintText,
    required this.confirmLabel,
    required this.validate,
    this.initialValue = '',
    this.keyboardType,
  });

  final String title;
  final String labelText;
  final String hintText;
  final String confirmLabel;
  final String initialValue;
  final TextInputType? keyboardType;
  final bool Function(String) validate;

  @override
  State<_TsnetTextPromptDialog> createState() => _TsnetTextPromptDialogState();
}

class _TsnetTextPromptDialogState extends State<_TsnetTextPromptDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      keyboardType: widget.keyboardType,
      autofocus: true,
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: widget.hintText,
        border: const OutlineInputBorder(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (!widget.validate(_controller.text)) {
            return;
          }
          Navigator.of(context).pop(_controller.text);
        },
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}
