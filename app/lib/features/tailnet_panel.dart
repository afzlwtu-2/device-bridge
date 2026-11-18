import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';

class TailnetPanel extends StatefulWidget {
  const TailnetPanel({super.key, required this.core});
  final CoreBridge core;
  @override
  State<TailnetPanel> createState() => _TailnetPanelState();
}

class _TailnetPanelState extends State<TailnetPanel>
    with WidgetsBindingObserver {
  Map<dynamic, dynamic>? status;
  String? error;
  bool busy = true;
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
          return 'App-only Tailscale is off. Approve a Wi-Fi or Hotspot network in Connections, then tap Enable app-only Tailscale.';
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
    try {
      status = await widget.core.run(['tailnet', 'status']) as Map;
      error = null;
    } catch (e) {
      error = _formatError(e);
    }
    if (mounted) {
      setState(() => busy = false);
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
    return Scaffold(
      appBar: AppBar(title: const Text('Tailscale connectivity')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (busy) const LinearProgressIndicator(),
          Text(
            system ? 'Existing system Tailscale' : 'App-only Tailscale',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            system
                ? 'DeviceBridge uses the existing laptop agent. Its settings and credentials are managed by Tailscale.'
                : 'This creates a separate DeviceBridge node. It does not enable Android’s system-wide VPN. It runs while this app is open or transferring on approved Wi-Fi.',
          ),
          const SizedBox(height: 20),
          if (status != null) ...[
            Text('Status: ${status!['state']}'),
            for (final ip in status!['ips'] as List? ?? [])
              SelectableText('Tailscale IP: $ip'),
            const SizedBox(height: 12),
            if ((status!['peers'] as List? ?? []).isNotEmpty) ...[
              Text(
                'Tailscale peers (tap Probe to check Direct vs DERP)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              for (final peer in (status!['peers'] as List? ?? []))
                for (final ip in (peer['ips'] as List? ?? []))
                  if (!(ip as String).contains(':'))
                    Card(
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          peer['online'] == true
                              ? Icons.computer
                              : Icons.cloud_off,
                        ),
                        title: Text('${peer['name']} · $ip'),
                        subtitle: Text(
                          probeResults.containsKey(ip)
                              ? 'Path: ${probeResults[ip]!['kind']}'
                                '${(probeResults[ip]!['endpoint'] as String? ?? '').isNotEmpty ? ' (${probeResults[ip]!['endpoint']})' : ''}'
                                '${(probeResults[ip]!['relay'] as String? ?? '').isNotEmpty ? ' · relay ${probeResults[ip]!['relay']}' : ''}'
                                ' · ${(((probeResults[ip]!['rtt_seconds'] as num? ?? 0)) * 1000).toStringAsFixed(1)} ms'
                              : (peer['online'] == true ? 'Online' : 'Offline'),
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
                                    ]) as Map;
                                    final p = res['path'] as Map?;
                                    if (p != null && mounted) {
                                      probeResults[ip] =
                                          Map<String, dynamic>.from(p);
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
                    ),
            ],
          ],
          if (error != null) Text(error!),
          const SizedBox(height: 16),
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
                          await widget.core.enableTailnet(false);
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
