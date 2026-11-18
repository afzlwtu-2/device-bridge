import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

/// Connects via SSH (user-supplied credentials, held in memory only for setup),
/// inspects host key fingerprint, starts/schedules precompiled bridge-agent in systemd,
/// opens firewall TCP/8731 (UFW), and auto-pairs with the device.
class SshBootstrapDialog extends StatefulWidget {
  const SshBootstrapDialog({super.key, required this.core});
  final CoreBridge core;
  @override
  State<SshBootstrapDialog> createState() => _SshBootstrapDialogState();
}

class _SshBootstrapDialogState extends State<SshBootstrapDialog> {
  final hostCtrl = TextEditingController();
  final portCtrl = TextEditingController(text: '22');
  final userCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final keyCtrl = TextEditingController();
  final sudoCtrl = TextEditingController();

  bool installSystemd = true;
  bool openFirewall = true;
  bool autoPair = true;
  bool busy = false;
  String? hostFingerprint;
  String? hostKeyType;
  String? error;
  Map<String, dynamic>? result;

  @override
  void dispose() {
    hostCtrl.dispose();
    portCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
    keyCtrl.dispose();
    sudoCtrl.dispose();
    super.dispose();
  }

  Future<void> probeHostKey() async {
    final host = hostCtrl.text.trim();
    final port = portCtrl.text.trim().isEmpty ? '22' : portCtrl.text.trim();
    if (host.isEmpty) {
      setState(() => error = 'Enter target host / Tailscale / LAN IP');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      hostFingerprint = null;
    });
    try {
      final res = await widget.core.run(['ssh-probe', host, port]) as Map;
      if (mounted) {
        setState(() {
          hostFingerprint = res['host_key_sha256'] as String?;
          hostKeyType = res['key_type'] as String?;
        });
      }
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

  Future<void> runBootstrap() async {
    if (hostFingerprint == null || hostFingerprint!.isEmpty) {
      await probeHostKey();
      return;
    }
    final host = hostCtrl.text.trim();
    final user = userCtrl.text.trim();
    final port = int.tryParse(portCtrl.text.trim()) ?? 22;
    if (host.isEmpty || user.isEmpty) {
      setState(() => error = 'Host and username are required');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      String localArtifacts = '';
      if (!Platform.isAndroid) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        if (File('$exeDir/bridge-agent').existsSync()) {
          localArtifacts = exeDir;
        }
      }
      final payload = {
        'host': host,
        'port': port,
        'user': user,
        if (passCtrl.text.isNotEmpty) 'password': passCtrl.text,
        if (keyCtrl.text.trim().isNotEmpty)
          'private_key_pem': keyCtrl.text.trim(),
        'expected_host_key': hostFingerprint,
        if (sudoCtrl.text.isNotEmpty) 'sudo_password': sudoCtrl.text,
        'open_firewall': openFirewall,
        'install_systemd': installSystemd,
        'auto_pair': autoPair,
        'bridge_port': 8731,
        if (localArtifacts.isNotEmpty) 'local_artifacts': localArtifacts,
      };
      final res = await widget.core.run(
        ['ssh-bootstrap', '-'],
        input: jsonEncode(payload),
      );
      if (mounted) {
        setState(() => result = Map<String, dynamic>.from(res as Map));
      }
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

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Setup & auto-pair via SSH'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (busy) const LinearProgressIndicator(),
            const Text(
              'Connects over SSH to start/schedule precompiled bridge-agent in systemd (--user), open TCP 8731 firewall port, and auto-pair with full storage access. Credentials are never saved to disk.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: hostCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Host / LAN / Tailscale IP',
                      hintText: '10.100.102.69',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: portCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: userCtrl,
              decoration: const InputDecoration(
                labelText: 'SSH username',
                hintText: 'afzl',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: passCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'SSH password (optional if using key)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: keyCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Private key PEM (optional)',
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: installSystemd,
              onChanged: (v) => setState(() => installSystemd = v ?? true),
              title: const Text('Schedule bridge-agent via systemd (--user)'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: openFirewall,
              onChanged: (v) => setState(() => openFirewall = v ?? true),
              title: const Text('Open TCP 8731 on UFW firewall'),
            ),
            if (openFirewall)
              TextField(
                controller: sudoCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Sudo password for UFW (if required)',
                ),
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: autoPair,
              onChanged: (v) => setState(() => autoPair = v ?? true),
              title: const Text('Auto-pair with full storage access'),
            ),
            if (hostFingerprint != null) ...[
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    'SSH Host Key ($hostKeyType):\n$hostFingerprint\nTap Run Setup to trust & configure.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
            if (result != null) ...[
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    'Target: ${result!['remote_hostname']}\n'
                    'Systemd: ${result!['systemd_status']}\n'
                    'Firewall: ${result!['firewall_status']}\n'
                    'Paired: ${result!['paired_route'] ?? '—'} (${result!['paired_endpoint'] ?? '—'})',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              SelectableText(error!, style: const TextStyle(fontSize: 12)),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, result != null),
        child: Text(result != null ? 'Done' : 'Cancel'),
      ),
      if (hostFingerprint == null)
        FilledButton(
          onPressed: busy ? null : probeHostKey,
          child: const Text('Verify Host Key'),
        )
      else if (result == null)
        FilledButton(
          onPressed: busy ? null : runBootstrap,
          child: const Text('Run Setup'),
        ),
    ],
  );
}
