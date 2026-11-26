import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

/// Launches the interactive Android permission setup wizard and returns the updated status.
Future<Map<String, dynamic>?> showPermissionWizard(
  BuildContext context,
  CoreBridge core, {
  Map<String, dynamic>? initialStatus,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => PermissionWizardDialog(
    core: core,
    initialStatus: initialStatus,
  ),
);

/// Reviews Android runtime/special permissions and supports Standard, Shizuku, and Root auto-grant.
class PermissionWizardDialog extends StatefulWidget {
  const PermissionWizardDialog({
    super.key,
    required this.core,
    this.initialStatus,
  });

  final CoreBridge core;
  final Map<String, dynamic>? initialStatus;

  @override
  State<PermissionWizardDialog> createState() => _PermissionWizardDialogState();
}

class _PermissionWizardDialogState extends State<PermissionWizardDialog>
    with WidgetsBindingObserver {
  Map<String, dynamic> _status = const {};
  bool _loading = true;
  bool _busy = false;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialStatus != null) {
      _status = Map<String, dynamic>.from(widget.initialStatus!);
      _loading = false;
    }
    unawaited(_refresh(autoGrant: false));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) {
      unawaited(_refresh(autoGrant: false));
    }
  }

  Future<void> _refresh({bool autoGrant = false}) async {
    try {
      final next = await widget.core.permissionsStatus(autoGrant: autoGrant);
      if (mounted) {
        setState(() {
          _status = next;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _message = e is PlatformException ? e.message ?? e.code : '$e';
          _isError = true;
        });
      }
    }
  }

  Future<void> _runAction(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _isError = false;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(() {
          _message = e is PlatformException ? e.message ?? e.code : '$e';
          _isError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enablePrivilege(String settingKey, String label) =>
      _runAction(() async {
        await widget.core.appSettings(update: {settingKey: true});
        final next = await widget.core.autoGrantPermissions();
        if (mounted) {
          setState(() {
            _status = next;
            _message = next['all_granted'] == true
                ? '$label verified and all permissions granted automatically.'
                : '$label verified.';
            _isError = false;
          });
        }
      });

  Future<void> _autoGrant() => _runAction(() async {
    final next = await widget.core.autoGrantPermissions();
    if (mounted) {
      setState(() {
        _status = next;
        _message = next['all_granted'] == true
            ? 'All available permissions were granted automatically.'
            : 'Updated available permissions. Review any remaining system toggles.';
        _isError = false;
      });
    }
  });

  Future<void> _requestOne(String id) => _runAction(() async {
    final next = await widget.core.requestAppPermission(id);
    if (mounted) {
      setState(() {
        _status = next;
      });
    }
  });

  Future<void> _finish() async {
    try {
      await widget.core.appSettings(
        update: {'permissions_wizard_done': true},
      );
    } catch (_) {}
    if (mounted) {
      Navigator.of(context).pop(_status);
    }
  }

  IconData _iconFor(String id) => switch (id) {
    'storage' => Icons.folder_open_outlined,
    'wifi_nearby' => Icons.wifi_tethering_outlined,
    'notifications' => Icons.notifications_outlined,
    'camera' => Icons.qr_code_scanner_outlined,
    'install_packages' => Icons.system_update_outlined,
    'termux_run' => Icons.terminal_outlined,
    _ => Icons.verified_user_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mode = '${_status['execution_mode'] ?? 'standard'}';
    final rootOn = _status['root_enabled'] == true;
    final shizukuRunning = _status['shizuku_running'] == true;
    final shizukuOn = _status['shizuku_enabled'] == true;
    final allGranted = _status['all_granted'] == true;
    final hasMissingRuntime = _status['has_missing_runtime'] == true;
    final perms = (_status['permissions'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    final modeSummary = switch (mode) {
      'root' => 'Root mode active · permissions can be auto-granted',
      'shizuku' => 'Shizuku mode active · permissions can be auto-granted',
      _ => 'Standard mode · grant permissions using Android prompts & settings',
    };

    return AlertDialog(
      key: const ValueKey('permission-wizard-dialog'),
      title: const Row(
        children: [
          Icon(Icons.verified_user_outlined),
          SizedBox(width: 10),
          Expanded(child: Text('Permissions setup')),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      modeSummary,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (shizukuRunning && !shizukuOn && !rootOn)
                          FilledButton.tonalIcon(
                            key: const ValueKey('permission-wizard-shizuku'),
                            onPressed: _busy
                                ? null
                                : () => _enablePrivilege(
                                    'shizuku_enabled',
                                    'Shizuku',
                                  ),
                            icon: const Icon(Icons.shield_outlined, size: 18),
                            label: const Text('Allow Shizuku & grant all'),
                          ),
                        if (!rootOn)
                          OutlinedButton.icon(
                            key: const ValueKey('permission-wizard-root'),
                            onPressed: _busy
                                ? null
                                : () => _enablePrivilege(
                                    'root_enabled',
                                    'Root access',
                                  ),
                            icon: const Icon(
                              Icons.admin_panel_settings_outlined,
                              size: 18,
                            ),
                            label: const Text('Use Root & grant all'),
                          ),
                        if ((rootOn || shizukuOn) && !allGranted)
                          FilledButton.icon(
                            key: const ValueKey('permission-wizard-autogrant'),
                            onPressed: _busy ? null : _autoGrant,
                            icon: const Icon(Icons.auto_fix_high, size: 18),
                            label: const Text('Auto-grant all'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_loading || _busy) ...[
                const SizedBox(height: 10),
                const LinearProgressIndicator(),
              ],
              if (_message != null) ...[
                const SizedBox(height: 10),
                Text(
                  _message!,
                  style: TextStyle(
                    color: _isError ? cs.error : cs.primary,
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              for (final item in perms) ...[
                _PermissionTile(
                  icon: _iconFor('${item['id']}'),
                  id: '${item['id']}',
                  title: '${item['title'] ?? item['id']}',
                  description: '${item['description'] ?? ''}',
                  granted: item['granted'] == true,
                  required: item['required'] == true,
                  kind: '${item['kind'] ?? 'runtime'}',
                  busy: _busy,
                  onGrant: () => _requestOne('${item['id']}'),
                ),
                const SizedBox(height: 6),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (hasMissingRuntime)
          TextButton(
            key: const ValueKey('permission-wizard-runtime-batch'),
            onPressed: _busy ? null : () => _requestOne('runtime_batch'),
            child: const Text('Grant runtime prompts'),
          ),
        TextButton(
          onPressed: _busy ? null : _finish,
          child: Text(allGranted ? 'Close' : 'Skip for now'),
        ),
        FilledButton(
          key: const ValueKey('permission-wizard-done'),
          onPressed: _busy ? null : _finish,
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _PermissionTile extends StatelessWidget {
  const _PermissionTile({
    required this.icon,
    required this.id,
    required this.title,
    required this.description,
    required this.granted,
    required this.required,
    required this.kind,
    required this.busy,
    required this.onGrant,
  });

  final IconData icon;
  final String id;
  final String title;
  final String description;
  final bool granted;
  final bool required;
  final String kind;
  final bool busy;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final statusText = granted
        ? 'Granted'
        : (required ? 'Required' : 'Optional');
    final statusColor = granted
        ? Colors.green
        : (required ? cs.error : cs.onSurfaceVariant);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: granted
              ? Colors.green.withValues(alpha: 0.45)
              : cs.outlineVariant,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              granted ? Icons.check_circle : icon,
              size: 20,
              color: granted ? Colors.green : cs.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      statusText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: statusColor,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (!granted) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: ValueKey('permission-grant-$id'),
              onPressed: busy ? null : onGrant,
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(kind == 'special' ? 'Settings' : 'Grant'),
            ),
          ],
        ],
      ),
    );
  }
}
