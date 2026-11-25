import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

/// Connects via SSH (user-supplied credentials, held in memory only for setup),
/// inspects host key fingerprint, starts/schedules precompiled bridge-agent in systemd,
/// opens firewall TCP/8731 (UFW), and auto-pairs with the device.
class SshBootstrapDialog extends StatefulWidget {
  const SshBootstrapDialog({
    super.key,
    required this.core,
    this.initialHost,
    this.initialPort,
    this.autoProbe = false,
    this.termuxCompanion = false,
    this.tailscaleSsh = false,
    this.uninstallPeerId,
    this.deviceName,
  });

  final CoreBridge core;
  final String? initialHost;
  final int? initialPort;
  final bool autoProbe;
  final bool termuxCompanion;
  final bool tailscaleSsh;
  final String? uninstallPeerId, deviceName;

  @override
  State<SshBootstrapDialog> createState() => _SshBootstrapDialogState();
}

class _SshBootstrapDialogState extends State<SshBootstrapDialog> {
  late final TextEditingController hostCtrl;
  late final TextEditingController portCtrl;
  final userCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  final keyCtrl = TextEditingController();
  final sudoCtrl = TextEditingController();
  final keyPassphraseCtrl = TextEditingController();

  bool installSystemd = true;
  bool installSystemService = true;
  bool openFirewall = true;
  bool autoPair = true;
  bool updateBinaries = true;
  bool allowSyncControl = false;
  bool allowTermuxFiles = false;
  bool allowSyncRemote = false;
  bool busy = false;
  String? hostFingerprint;
  String? hostKeyType;
  String? resolvedHost;
  bool viaTailnet = false;
  String? error;
  Map<String, dynamic>? result;
  bool get uninstall => widget.uninstallPeerId != null;

  String _friendlyError(Object e) {
    final s = e.toString();
    final match = RegExp(r'"message":"([^"]+)"').firstMatch(s);
    if (match != null) {
      return match.group(1)!;
    }
    return s;
  }

  @override
  void initState() {
    super.initState();
    if (widget.termuxCompanion) {
      installSystemd = false;
      openFirewall = false;
    }
    hostCtrl = TextEditingController(text: widget.initialHost ?? '');
    portCtrl = TextEditingController(text: '${widget.initialPort ?? 22}');
    hostCtrl.addListener(_invalidateProbe);
    portCtrl.addListener(_invalidateProbe);
    if (uninstall) {
      _loadSavedHostSsh(hostCtrl.text.trim(), peerId: widget.uninstallPeerId);
    } else {
      _loadSavedHostSsh(hostCtrl.text.trim());
    }
    if (widget.autoProbe && (widget.initialHost ?? '').trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          probeHostKey();
        }
      });
    }
  }

  Future<void> _loadSavedHostSsh(String host, {String? peerId}) async {
    if (host.isEmpty && peerId == null) return;
    try {
      final raw = await widget.core.run(
        peerId == null ? ['host-ssh', host] : ['peer-ssh', peerId],
      );
      if (!mounted || raw is! Map || raw.isEmpty) return;
      final m = Map<String, dynamic>.from(raw);
      final isTail = m['via_tailnet'] == true;
      setState(() {
        final savedHost = '${m['host'] ?? ''}'.trim();
        if (peerId != null && savedHost.isNotEmpty) hostCtrl.text = savedHost;
        final u = '${m['user'] ?? ''}'.trim();
        if (userCtrl.text.trim().isEmpty && u.isNotEmpty) {
          userCtrl.text = u;
        }
        final p = (m['port'] as num?)?.toInt() ?? 0;
        if (p > 0) portCtrl.text = '$p';
        if (!isTail) {
          final pem = '${m['private_key_pem'] ?? ''}'.trim();
          if (keyCtrl.text.trim().isEmpty && pem.isNotEmpty) {
            keyCtrl.text = pem;
          }
        }
        final fk = '${m['expected_host_key'] ?? ''}'.trim();
        if ((hostFingerprint ?? '').isEmpty && fk.isNotEmpty) {
          hostFingerprint = fk;
        }
        if (isTail) viaTailnet = true;
      });
    } catch (_) {}
  }

  Future<void> _saveHostAndPeerSsh({
    required String host,
    required int port,
    required String user,
    required String hostKey,
    required bool isTailnet,
    required String pem,
    String? peerId,
  }) async {
    final payload = jsonEncode({
      'host': host,
      'port': port,
      'user': user,
      'expected_host_key': hostKey,
      'via_tailnet': isTailnet,
      if (!isTailnet && pem.isNotEmpty) 'private_key_pem': pem,
    });
    try {
      await widget.core.run(['host-ssh', host, '-'], input: payload);
    } catch (_) {}
    if (peerId != null && peerId.isNotEmpty) {
      try {
        await widget.core.run(['peer-ssh', peerId, '-'], input: payload);
      } catch (_) {}
    }
  }

  void _invalidateProbe() {
    if (hostFingerprint != null || resolvedHost != null || viaTailnet) {
      setState(() {
        hostFingerprint = null;
        hostKeyType = null;
        resolvedHost = null;
        viaTailnet = false;
      });
    }
  }

  @override
  void dispose() {
    hostCtrl.removeListener(_invalidateProbe);
    portCtrl.removeListener(_invalidateProbe);
    hostCtrl.dispose();
    portCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
    keyCtrl.dispose();
    sudoCtrl.dispose();
    keyPassphraseCtrl.dispose();
    super.dispose();
  }

  Future<void> probeHostKey() async {
    final host = hostCtrl.text.trim();
    final port = portCtrl.text.trim().isEmpty ? '22' : portCtrl.text.trim();
    if (host.isEmpty) {
      setState(() => error = 'Enter target host / Tailscale hostname / LAN IP');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      hostFingerprint = null;
      resolvedHost = null;
      viaTailnet = false;
    });
    try {
      final res = await widget.core.run(['ssh-probe', host, port]) as Map;
      if (mounted) {
        setState(() {
          hostFingerprint = res['host_key_sha256'] as String?;
          hostKeyType = res['key_type'] as String?;
          resolvedHost = res['resolved_host'] as String?;
          viaTailnet = res['via_tailnet'] == true;
        });
        if (!uninstall) await _loadSavedHostSsh(host);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = _friendlyError(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<String> _prepareBundledArtifacts() async {
    final baseDir = Directory('${File(widget.core.downloads).parent.path}/bundled-bin');
    const targets = {
      'linux-x86_64': ['bridge-agent', 'bridge-cli', 'bridge-sync'],
      'android-aarch64': ['bridge-agent', 'bridge-cli', 'bridge-sync'],
    };
    final nativeArm64Paths = <String, String>{};
    if (Platform.isAndroid) {
      try {
        final status = await widget.core.goBinariesStatus();
        final topArch = '${status['arch'] ?? ''}';
        final libs = status['libraries'];
        if (libs is List) {
          for (final raw in libs) {
            if (raw is! Map) continue;
            final role = '${raw['role'] ?? ''}';
            final path = '${raw['path'] ?? ''}';
            final arch = '${raw['arch'] ?? topArch}';
            if (raw['available'] == true &&
                arch == 'android/arm64' &&
                path.isNotEmpty) {
              nativeArm64Paths['bridge-$role'] = path;
            }
          }
        }
      } catch (_) {}
    }
    var anyReady = false;
    for (final entry in targets.entries) {
      final plat = entry.key;
      if (widget.termuxCompanion && plat != 'android-aarch64') continue;
      for (final bin in entry.value) {
        final outFile = File('${baseDir.path}/$plat/$bin');
        try {
          outFile.parent.createSync(recursive: true);
          final nativePath = plat == 'android-aarch64'
              ? nativeArm64Paths[bin]
              : null;
          if (nativePath != null && File(nativePath).existsSync()) {
            final tmp = File('${outFile.path}.tmp');
            await File(nativePath).copy(tmp.path);
            await tmp.rename(outFile.path);
            anyReady = true;
            continue;
          }
          // Fall back to compressed assets if native libraries do not match target ABI.
          final asset = plat == 'android-aarch64'
              ? 'android-arm64-lib${bin.replaceAll('-', '_')}.gzbin'
              : '$plat-$bin.gzbin';
          final data = await rootBundle.load('assets/bin/$asset');
          final gzBytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          final decoded = gzip.decode(gzBytes);
          final tmp = File('${outFile.path}.tmp');
          await tmp.writeAsBytes(decoded, flush: true);
          await tmp.rename(outFile.path);
          anyReady = true;
        } catch (_) {
          if (outFile.existsSync() && outFile.lengthSync() > 0) anyReady = true;
        }
      }
    }
    if (anyReady) {
      return baseDir.path;
    }
    if (!Platform.isAndroid) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      if (File('$exeDir/bridge-agent').existsSync()) {
        return exeDir;
      }
    }
    return '';
  }

  Future<void> removeLocallyOnly() async {
    final peerId = widget.uninstallPeerId;
    if (peerId == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.core.run(['remove', peerId]);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => error = _friendlyError(e));
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
      if (widget.uninstallPeerId case final String peerId) {
        await widget.core.run(
          ['ssh-uninstall', peerId, '-'],
          input: jsonEncode({
            'host': host,
            'port': port,
            'user': user,
            'expected_host_key': hostFingerprint,
            if (passCtrl.text.isNotEmpty) 'password': passCtrl.text,
            if (keyCtrl.text.trim().isNotEmpty) 'private_key_pem': keyCtrl.text.trim(),
            if (keyPassphraseCtrl.text.isNotEmpty) 'key_passphrase': keyPassphraseCtrl.text,
            if (sudoCtrl.text.isNotEmpty) 'sudo_password': sudoCtrl.text,
          }),
        );
        if (mounted) Navigator.pop(context, true);
        return;
      }
      final localArtifacts = await _prepareBundledArtifacts();
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
        'install_system_service': installSystemd && installSystemService,
        'auto_pair': autoPair,
        if (widget.termuxCompanion) 'termux_companion': true,
        if (widget.termuxCompanion) 'allow_termux_files': autoPair && allowTermuxFiles,
        'update_binaries': updateBinaries,
        'allow_sync_control': autoPair && allowSyncControl,
        'allow_sync_remote': autoPair && allowSyncControl && allowSyncRemote,
        'bridge_port': 8731,
        if (localArtifacts.isNotEmpty) 'local_artifacts': localArtifacts,
      };
      final res = await widget.core.run(
        ['ssh-bootstrap', '-'],
        input: jsonEncode(payload),
      );
      final parsed = Map<String, dynamic>.from(res as Map);
      await _saveHostAndPeerSsh(
        host: host,
        port: port,
        user: user,
        hostKey: hostFingerprint ?? '',
        isTailnet: viaTailnet || parsed['via_tailnet'] == true,
        pem: keyCtrl.text.trim(),
        peerId: parsed['paired_peer_id'] as String?,
      );
      if (mounted) {
        setState(() => result = parsed);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = _friendlyError(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _importFromSshDir() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final keys = await widget.core.listSshKeys();
      if (!mounted) return;
      if (keys.isEmpty) {
        setState(
          () => error = 'No private keys found in ~/.ssh. Use Browse key file to select a key.',
        );
        return;
      }
      setState(() => busy = false);
      final chosen = await showDialog<Map<String, String>>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Select private key (.ssh)'),
          children: [
            for (final k in keys)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, k),
                child: Text(k['name'] ?? k['path'] ?? 'key'),
              ),
          ],
        ),
      );
      if (chosen == null) return;
      final pem = await widget.core.readSshKey(chosen);
      if (!mounted) return;
      if (pem == null || pem.trim().isEmpty) {
        setState(() => error = 'Selected key file is empty or unreadable.');
        return;
      }
      setState(() {
        keyCtrl.text = pem.trim();
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() => error = _friendlyError(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  Future<void> _browseKeyFile() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final pem = await widget.core.pickSshKeyText();
      if (!mounted) return;
      if (pem != null && pem.trim().isNotEmpty) {
        setState(() {
          keyCtrl.text = pem.trim();
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = _friendlyError(e));
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTailnet = viaTailnet || widget.tailscaleSsh;
    final dialog = AlertDialog(
    title: Text(
      uninstall
          ? 'Remove ${widget.deviceName ?? 'laptop'}?'
          : widget.termuxCompanion
          ? 'Set up Termux folder sync'
          : 'Setup & auto-pair via SSH',
    ),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (busy) const LinearProgressIndicator(),
            if (uninstall)
              const Text(
                'Remove this pairing from this device only (for offline, wiped, or uninstalled devices), or verify SSH below to also stop and uninstall the DeviceBridge daemon, binaries, and configuration on the remote device.',
              )
            else if (widget.termuxCompanion)
              const Text(
                'Installs and starts the companion and its bundled Syncthing engine over SSH. The companion runs as the Termux app user. Pair this phone to browse and sync Termux Home.',
                style: TextStyle(fontSize: 12),
              )
            else const Text(
              'Connects over SSH to install bridge-agent as a root systemd service (zero Polkit/sudo prompts for Wi-Fi Direct, Hotspot & 5 GHz regdom), open TCP 8731, and auto-pair with full storage access. Passwords remain memory-only.',
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
                      labelText: 'Host / Tailscale hostname / IP',
                      hintText: 'probook or 10.100.102.69',
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
              decoration: InputDecoration(
                labelText: isTailnet
                    ? 'SSH password (optional for Tailscale SSH)'
                    : 'SSH password (optional if using key)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: keyCtrl,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: isTailnet
                    ? 'Private key PEM (optional for Tailscale SSH)'
                    : 'Private key PEM (optional)',
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!Platform.isAndroid)
                  OutlinedButton.icon(
                    onPressed: busy ? null : _importFromSshDir,
                    icon: const Icon(Icons.vpn_key_outlined, size: 18),
                    label: const Text('Import from .ssh'),
                  ),
                OutlinedButton.icon(
                  onPressed: busy ? null : _browseKeyFile,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Browse key file'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (!uninstall && !widget.termuxCompanion) ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: installSystemd,
              onChanged: (v) => setState(() => installSystemd = v ?? true),
              title: const Text('Schedule bridge-agent via systemd'),
            ),
            if (installSystemd)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: installSystemService,
                onChanged: (v) =>
                    setState(() => installSystemService = v ?? true),
                title: const Text(
                  'Root system service (recommended, no Polkit prompts)',
                ),
                subtitle: const Text(
                  'Runs as root with full 5 GHz regdom & Wi-Fi Direct/Hotspot join permissions; falls back to user service if sudo unavailable',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: openFirewall,
              onChanged: (v) => setState(() => openFirewall = v ?? true),
              title: const Text('Open TCP 8731 on UFW firewall'),
            ),
            ],
            if (uninstall)
              TextField(
                controller: keyPassphraseCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'SSH key passphrase (if required)'),
              ),
            if (uninstall || openFirewall || (installSystemd && installSystemService))
              TextField(
                controller: sudoCtrl,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Sudo password for root service / UFW (if required)',
                ),
              ),
            if (!uninstall) CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: autoPair,
              onChanged: (v) => setState(() => autoPair = v ?? true),
              title: Text(widget.termuxCompanion ? 'Pair and grant Termux Home access' : 'Auto-pair with full storage access'),
            ),
            if (!uninstall) CheckboxListTile(
              contentPadding: EdgeInsets.zero, value: updateBinaries,
              onChanged: (v) => setState(() => updateBinaries = v ?? true),
              title: const Text('Install or update DeviceBridge binaries'),
              subtitle: const Text('Includes the folder sync engine on supported machines, in DeviceBridge-owned storage.'),
            ),
            if (widget.termuxCompanion && autoPair)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: allowTermuxFiles,
                onChanged: (value) => setState(() => allowTermuxFiles = value ?? false),
                title: const Text('Allow copying and moving Termux files'),
                subtitle: const Text('This phone can create files and remove verified move sources within the granted Home.'),
              ),
            if (!uninstall && autoPair) CheckboxListTile(
              contentPadding: EdgeInsets.zero, value: allowSyncControl,
              onChanged: (v) => setState(() => allowSyncControl = v ?? false),
              title: const Text('Allow this device to manage folder sync'),
              subtitle: const Text('Includes updating selected destination folders within granted storage. Transfers go directly between the selected endpoints.'),
            ),
            if (!uninstall && autoPair && allowSyncControl) CheckboxListTile(
              contentPadding: EdgeInsets.zero, value: allowSyncRemote,
              onChanged: (v) => setState(() => allowSyncRemote = v ?? false),
              title: const Text('Allow approved remote sync routes'),
              subtitle: const Text('Permit explicit Tailscale or routed sessions, including approved internet or relay data.'),
            ),
            if (hostFingerprint != null) ...[
              const SizedBox(height: 8),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    'SSH Host Key${hostKeyType == null ? '' : ' ($hostKeyType)'}'
                    '${viaTailnet ? ' · via Tailscale${resolvedHost == null ? '' : ' ($resolvedHost)'}' : ''}:\n'
                    '$hostFingerprint',
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
                    'Service: ${result!['systemd_status']}\n'
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
        onPressed: busy ? null : () => Navigator.pop(context, result != null),
        child: Text(result != null ? 'Done' : 'Cancel'),
      ),
      if (uninstall && result == null)
        OutlinedButton(
          onPressed: busy ? null : removeLocallyOnly,
          child: const Text('Remove locally only'),
        ),
      if (hostFingerprint == null)
        FilledButton(
          onPressed: busy ? null : probeHostKey,
          child: const Text('Verify Host Key'),
        )
      else if (result == null)
        FilledButton(
          onPressed: busy ? null : runBootstrap,
          child: Text(uninstall ? 'Remove and uninstall' : 'Run Setup'),
        ),
    ],
    );
    return PopScope(canPop: !busy, child: dialog);
  }
}
