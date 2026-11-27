import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../core/bridge.dart';
import '../core/debug_trace.dart';
import 'acl_screen.dart';
import 'app_updates.dart';
import 'debug_log_screen.dart';
import 'permission_wizard.dart';
import 'termux_backup_dialog.dart';
import 'wiki_screen.dart';

/// App-wide access, execution-mode submenus, verbose logging, and Go library management.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.core});
  final CoreBridge core;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  static const _backupEvents = EventChannel('dev.devicebridge/termux_backup');
  Map<String, dynamic> values = {};
  Map<String, dynamic> goRuntime = {};
  Map<String, dynamic> permissions = {};
  bool loading = true, saving = false;
  String? error;
  String? notice;
  String? appVersion;
  StreamSubscription<dynamic>? _backupSubscription;
  Map<String, dynamic>? _backupProgress;
  bool _backupRequest = false;
  String? _backupNotice;
  bool _backupFailed = false;
  bool get _backupBusy => _backupRequest || _backupProgress != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    unawaited(_backupSubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !saving && !_backupBusy) {
      load();
    }
  }

  Future<void> load() async {
    try {
      final result = await widget.core.appSettings();
      String? version;
      Map<String, dynamic> permStatus = {};
      if (result['android'] == true && widget.core is LocalCore) {
        if (mounted) {
          _backupSubscription ??= _backupEvents.receiveBroadcastStream().listen(
            (event) {
              if (mounted) {
                setState(() {
                  _backupProgress = event is Map
                      ? Map<String, dynamic>.from(event)
                      : null;
                });
              }
            },
          );
        }
        try {
          version = await AppUpdates.version();
        } on PlatformException {
          // Settings remains usable if the platform version is unavailable.
        }
        try {
          permStatus = await widget.core.permissionsStatus(autoGrant: false);
        } on PlatformException {
          // Settings remains usable if permission inspection fails.
        }
      }
      Map<String, dynamic> rt = {};
      if (result['go_runtime'] is Map) {
        rt = Map<String, dynamic>.from(result['go_runtime'] as Map);
      } else {
        try {
          rt = await widget.core.goBinariesStatus();
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          values = result;
          goRuntime = rt;
          permissions = permStatus;
          appVersion = version;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> action(Future<void> Function() operation) async {
    if (saving) {
      return;
    }
    setState(() {
      saving = true;
      error = null;
      notice = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is PlatformException ? e.message ?? e.code : '$e',
        );
      }
    }
    if (mounted) {
      setState(() => saving = false);
    }
  }

  Future<void> save(String key, bool value) => action(() async {
    if (key == 'debug_mode') {
      DebugTrace.setEnabled(value);
      DebugTrace.logFlow('Settings', 'debug_mode -> $value');
    }
    final result = await widget.core.appSettings(update: {key: value});
    Map<String, dynamic>? updatedPerms;
    String? nextNotice;
    if (value &&
        (key == 'root_enabled' || key == 'shizuku_enabled') &&
        result['android'] == true) {
      try {
        updatedPerms = await widget.core.permissionsStatus(autoGrant: false);
        nextNotice = updatedPerms['all_granted'] == true
            ? '${key == 'root_enabled' ? 'Root access' : 'Shizuku'} enabled and all permissions granted.'
            : '${key == 'root_enabled' ? 'Root access' : 'Shizuku'} enabled.';
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        values = result;
        if (updatedPerms != null) permissions = updatedPerms;
        if (nextNotice != null) notice = nextNotice;
        if (result.containsKey('debug_mode')) {
          DebugTrace.setEnabled(result['debug_mode'] != false);
        }
        if (result['go_runtime'] is Map) {
          goRuntime = Map<String, dynamic>.from(result['go_runtime'] as Map);
        }
      });
    }
  });

  Future<void> installTerminalTools() async {
    setState(() {
      saving = true;
      _backupNotice = 'Installing Terminal tools…';
      _backupFailed = false;
    });
    try {
      await widget.core.openConnectionSetup('terminal-tools');
      if (mounted) setState(() => _backupNotice = 'Terminal tools installed.');
    } catch (error) {
      if (mounted) {
        setState(() {
          _backupFailed = true;
          _backupNotice = error is PlatformException
              ? error.message ?? error.code
              : '$error';
        });
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> termuxBackup({required bool restore}) async {
    if (saving || _backupBusy) return;
    Map<String, dynamic>? backupSpec;
    if (restore) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Restore Termux Home?'),
          content: const Text(
            'Close Termux tabs and stop shell jobs first. The backup becomes '
            'your active Home. Your current Home is saved in a separate folder. '
            'You can reinstall the saved packages afterward.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Choose backup'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    } else {
      try {
        final listing = await LocalCore.channel
            .invokeMapMethod<String, dynamic>('listTermuxBackupEntries');
        if (!mounted) return;
        if (listing != null) {
          final selection = await showTermuxBackupDialog(
            context,
            initialListing: listing,
            loadFolder: (subpath) =>
                LocalCore.channel.invokeMapMethod<String, dynamic>(
                  'listTermuxBackupEntries',
                  {'path': ?subpath},
                ),
          );
          if (selection == null || !mounted) return;
          backupSpec = selection.toSpec();
        }
      } on PlatformException catch (error) {
        if (!mounted) return;
        setState(() {
          _backupNotice = error.message ?? error.code;
          _backupFailed = true;
        });
        return;
      }
    }
    setState(() {
      _backupRequest = true;
      _backupNotice = null;
      _backupFailed = false;
    });
    try {
      final result = await LocalCore.channel.invokeMapMethod<String, dynamic>(
        restore ? 'restoreTermuxBackup' : 'createTermuxBackup',
        !restore && backupSpec != null ? {'spec': backupSpec} : null,
      );
      if (!mounted || result == null) return;
      final previous = result['previous_home'] as String? ?? '';
      final skipped = result['skipped'] as int? ?? 0;
      final excluded = result['excluded'] as int? ?? 0;
      setState(() {
        _backupNotice = restore
            ? 'Termux Home restored. ${result['package_count']} package names '
                  'saved.${previous.isEmpty ? '' : ' Previous Home is at ../$previous.'}'
            : skipped == 0
            ? (excluded == 0
                  ? 'Termux backup saved and verified.'
                  : 'Termux backup saved and verified ($excluded generated/cache items excluded).')
            : 'Termux backup saved and verified. Skipped $skipped '
                  'unreadable or disappearing entries.';
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _backupNotice = error.message ?? error.code;
          _backupFailed = true;
        });
      }
    } finally {
      if (mounted) setState(() => _backupRequest = false);
    }
  }

  Future<void> copyTermuxPackages() async {
    try {
      final packages = await LocalCore.channel.invokeMethod<String>(
        'savedTermuxPackages',
      );
      if (packages != null && packages.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: 'pkg install $packages'));
      }
      if (mounted) {
        setState(() {
          _backupFailed = false;
          _backupNotice = packages == null || packages.isEmpty
              ? 'There are no saved package names. Restore a backup first.'
              : 'Package install command copied. Paste it in Termux when ready.';
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _backupFailed = true;
          _backupNotice = error.message ?? error.code;
        });
      }
    }
  }

  Widget _termuxBackupStatus() {
    final phase = _backupProgress?['phase'];
    final bytes = _backupProgress?['bytes'] as int? ?? 0;
    final total = _backupProgress?['total'] as int?;
    final fraction = total == null || total <= 0
        ? null
        : (bytes / total).clamp(0.0, 1.0);
    final label = switch (phase) {
      'choose_backup' => 'Choose a backup file',
      'choose_destination' => 'Choose where to save the backup',
      'write' => 'Writing archive',
      'verify' => 'Verifying saved archive',
      'restore' => 'Reading backup',
      'finish_restore' => 'Applying restore',
      _ => 'Waiting for Android',
    };
    final counts = switch (phase) {
      'write' => '${_backupBytes(bytes)} written',
      'verify' || 'restore' when fraction != null =>
        '${_backupBytes(bytes)} of ${_backupBytes(total!)} · ${(fraction * 100).floor()}%',
      'verify' || 'restore' => '${_backupBytes(bytes)} read',
      _ => null,
    };
    return Padding(
      key: const ValueKey('termux-backup-status'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_backupBusy) ...[
            Text(label, style: Theme.of(context).textTheme.titleSmall),
            if (counts != null) Text(counts),
            if (fraction != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: fraction),
            ],
          ] else
            Semantics(
              liveRegion: true,
              child: Text(
                _backupNotice!,
                style: _backupFailed
                    ? TextStyle(color: Theme.of(context).colorScheme.error)
                    : null,
              ),
            ),
        ],
      ),
    );
  }

  String _backupBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }

  Future<void> _openSubmenu({
    required String title,
    required String subtitle,
    required String banner,
    required bool parentActive,
    required List<(String key, String title, String subtitle)> items,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _PrivilegeFeaturesPage(
          core: widget.core,
          title: title,
          subtitle: subtitle,
          banner: banner,
          parentActive: parentActive,
          initialValues: Map<String, dynamic>.from(values),
          items: items,
        ),
      ),
    );
    if (mounted) {
      await load();
    }
  }

  Widget section(
    String title,
    String caption,
    IconData icon,
    List<Widget> children,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: cs.onPrimaryContainer, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      caption,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: cs.outlineVariant.withValues(alpha: .6)),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  Widget toggle(String key, String title, String subtitle) =>
      SwitchListTile.adaptive(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        title: Text(title),
        subtitle: Text(subtitle),
        value: values[key] == true,
        onChanged: saving ? null : (value) => save(key, value),
      );

  String _modeLabel(String mode) => switch (mode) {
    'root' => 'Root mode (UID 0 verified)',
    'shizuku' => 'Shizuku mode (shell)',
    _ => 'Standard mode (no Root / Shizuku)',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final android = values['android'] == true;
    final execMode = '${values['execution_mode'] ?? 'standard'}';
    final rootOn = values['root_enabled'] == true;
    final shizukuOn = values['shizuku_enabled'] == true;
    final goVersion = '${goRuntime['version'] ?? 'unknown'}';
    final goToolchain = '${goRuntime['go'] ?? ''}';
    final goHotCount = (goRuntime['hot_count'] as num?)?.toInt() ?? 0;
    final goLibs = (goRuntime['libraries'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            tooltip: 'Refresh settings',
            onPressed: saving || _backupBusy ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  margin: const EdgeInsets.only(bottom: 24),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    gradient: LinearGradient(
                      colors: [
                        cs.primaryContainer,
                        cs.tertiaryContainer.withValues(alpha: .65),
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.tune_rounded,
                        size: 36,
                        color: cs.onPrimaryContainer,
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Your device. Your rules.',
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    color: cs.onPrimaryContainer,
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              android
                                  ? '${_modeLabel(execMode)} · Go core v$goVersion'
                                  : 'Desktop mode · Go core v$goVersion',
                              style: TextStyle(color: cs.onPrimaryContainer),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (loading || saving) const LinearProgressIndicator(),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: MaterialBanner(
                      content: Text(error!),
                      actions: [
                        TextButton(
                          onPressed: () => setState(() => error = null),
                          child: const Text('Dismiss'),
                        ),
                      ],
                    ),
                  ),
                if (notice != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
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
                if (android) ...[
                  ListTile(
                    key: const ValueKey('settings-permissions-wizard'),
                    leading: const Icon(Icons.verified_user_outlined),
                    title: const Text('Permissions & setup wizard'),
                    subtitle: Text(() {
                      final items =
                          (permissions['permissions'] as List? ?? const [])
                              .whereType<Map>()
                              .toList();
                      if (items.isEmpty) {
                        return 'Review storage, Wi-Fi, notifications, and privilege auto-grant';
                      }
                      final granted = items
                          .where((p) => p['granted'] == true)
                          .length;
                      return '$granted/${items.length} granted · ${_modeLabel(execMode)}';
                    }()),
                    trailing: const Icon(Icons.chevron_right),
                    enabled: !saving,
                    onTap: () async {
                      final updated = await showPermissionWizard(
                        context,
                        widget.core,
                        initialStatus: permissions.isEmpty ? null : permissions,
                      );
                      if (mounted && updated != null) {
                        await load();
                      }
                    },
                  ),
                  ListTile(
                    key: const ValueKey('check-app-update'),
                    leading: const Icon(Icons.system_update_outlined),
                    title: const Text('Check for updates'),
                    subtitle: Text(
                      appVersion == null
                          ? 'GitHub Releases'
                          : 'DeviceBridge $appVersion',
                    ),
                    enabled: !saving,
                    onTap: () => action(() async {
                      final message = await AppUpdates.check(
                        context,
                        manual: true,
                      );
                      if (mounted) setState(() => notice = message);
                    }),
                  ),
                  section(
                    'Root',
                    'Verified live on launch; disabled automatically if root is removed',
                    Icons.admin_panel_settings_outlined,
                    [
                      toggle(
                        'root_enabled',
                        'Root access',
                        '${values['root_status'] ?? 'Not requested'}. Enable to request permission and verify access.',
                      ),
                      const Divider(height: 1),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 6,
                        ),
                        leading: const Icon(Icons.account_tree_outlined),
                        title: const Text('Root features'),
                        subtitle: Text(
                          rootOn
                              ? 'Configure network helpers and background Termux sessions'
                              : 'Inspect Root-specific options (requires Root access above)',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: saving
                            ? null
                            : () => _openSubmenu(
                                title: 'Root features',
                                subtitle:
                                    'Used only when Root access is verified',
                                banner: rootOn
                                    ? 'Root access is active (UID 0).'
                                    : 'Root access is currently off. Enable Root access above before using these.',
                                parentActive: rootOn,
                                items: const [
                                  (
                                    'root_feature_direct_link',
                                    'Root direct-link control',
                                    'Use root cmd wifi & wifip2p for 5 GHz / 6 GHz Hotspot and Wi-Fi Direct.',
                                  ),
                                  (
                                    'root_feature_neighbors',
                                    'Root neighbor & ARP lookup',
                                    'Query AP/P2P peer IPs directly from ip neigh when unprivileged netlink is restricted.',
                                  ),
                                  (
                                    'root_feature_shell_diag',
                                    'Root link diagnostics',
                                    'Include privileged interface diagnostics in verbose logs.',
                                  ),
                                  (
                                    'root_feature_keep_terminal',
                                    'Keep Termux running',
                                    'Keep new sessions running after closing DeviceBridge, without a notification. Turn off to end background sessions.',
                                  ),
                                ],
                              ),
                      ),
                      if (rootOn)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: saving
                                  ? null
                                  : () => save('root_enabled', true),
                              icon: const Icon(Icons.fact_check_outlined),
                              label: const Text('Recheck root permission'),
                            ),
                          ),
                        ),
                    ],
                  ),
                  section(
                    'Shizuku',
                    'Use an existing Shizuku service without root',
                    Icons.shield_outlined,
                    [
                      toggle(
                        'shizuku_enabled',
                        'Shizuku access',
                        '${values['shizuku_status'] ?? 'Service not running'}. Enable to request permission for DeviceBridge.',
                      ),
                      const Divider(height: 1),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 6,
                        ),
                        leading: const Icon(Icons.tune),
                        title: const Text('Shizuku features'),
                        subtitle: Text(
                          shizukuOn
                              ? 'Configure ADB-shell network helpers. Termux uses the app lifecycle.'
                              : 'Inspect Shizuku helpers (works alongside non-root fallback)',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: saving
                            ? null
                            : () => _openSubmenu(
                                title: 'Shizuku features',
                                subtitle:
                                    'Runs via Shizuku service without root',
                                banner: shizukuOn
                                    ? 'Shizuku service is connected and permitted.'
                                    : 'Shizuku is off or unpermitted. Enable Shizuku access above, or Standard non-root APIs will be used.',
                                parentActive: shizukuOn,
                                items: const [
                                  (
                                    'shizuku_feature_direct_link',
                                    'Shizuku direct-link control',
                                    'Start & stop Hotspot and Wi-Fi Direct using Shizuku shell commands.',
                                  ),
                                  (
                                    'shizuku_feature_wifi_join',
                                    'Shizuku automated Wi-Fi join',
                                    'Join and forget peer Hotspot/Direct Wi-Fi networks automatically.',
                                  ),
                                ],
                              ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 6,
                        ),
                        leading: const Icon(Icons.open_in_new),
                        title: const Text('Open Shizuku'),
                        subtitle: const Text(
                          'Service and permission management',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: saving
                            ? null
                            : () => action(
                                () =>
                                    widget.core.openConnectionSetup('shizuku'),
                              ),
                      ),
                    ],
                  ),
                ],
                section(
                  'App behavior',
                  'Applies across DeviceBridge',
                  Icons.phone_android_outlined,
                  [
                    if (android) ...[
                      toggle(
                        'keep_awake',
                        'Keep screen awake',
                        'Only while DeviceBridge is in the foreground.',
                      ),
                      const Divider(height: 1),
                    ],
                    toggle(
                      'verbose_logging',
                      'Verbose debug logging',
                      'Emit detailed Go core and direct-link diagnostics in debug logs.',
                    ),
                    const Divider(height: 1),
                    toggle(
                      'debug_mode',
                      'Debug & flow tracker',
                      'Keep runtime failures, screen transitions, and transport/direct-link flows in the persistent tracker.',
                    ),
                    if (android) ...[
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.monitor_heart_outlined),
                        title: const Text('Battery & CPU diagnostics'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (_) =>
                              _ResourceDiagnosticsDialog(core: widget.core),
                        ),
                      ),
                    ],
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      leading: const Icon(Icons.bug_report_outlined),
                      title: const Text('Debug & flow log'),
                      subtitle: Text(
                        '${DebugTrace.instance.entries.length} events · ${DebugTrace.instance.errorCount} errors recorded',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            settings: const RouteSettings(
                              name: 'DebugLogScreen',
                            ),
                            builder: (_) => const DebugLogScreen(),
                          ),
                        );
                        if (mounted) {
                          setState(() {});
                        }
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      key: const ValueKey('settings-acl-tile'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      leading: const Icon(Icons.security_outlined),
                      title: const Text('ACL rules & device groups'),
                      subtitle: const Text(
                        'Control what trusted and non-trusted devices can access',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => AclScreen(core: widget.core),
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      leading: const Icon(Icons.menu_book_outlined),
                      title: const Text('DeviceBridge Wiki'),
                      subtitle: const Text(
                        'Permissions, battery & efficiency rankings, Termux targetSdk & binaries',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => WikiScreen(core: widget.core),
                        ),
                      ),
                    ),
                  ],
                ),
                if (android)
                  section(
                    'Termux backup',
                    'Back up hidden files and .env files. Generated caches, dependencies, '
                        'and build outputs are excluded by default.',
                    Icons.inventory_2_outlined,
                    [
                      if (_backupBusy || _backupNotice != null)
                        _termuxBackupStatus(),
                      ListTile(
                        key: const ValueKey('termux-backup-create'),
                        title: const Text('Back up Termux Home'),
                        enabled: !saving && !_backupBusy,
                        onTap: () => termuxBackup(restore: false),
                      ),
                      ListTile(
                        key: const ValueKey('termux-backup-restore'),
                        title: const Text('Restore Termux backup'),
                        enabled: !saving && !_backupBusy,
                        onTap: () => termuxBackup(restore: true),
                      ),
                      ListTile(
                        title: const Text('Install optional Terminal tools'),
                        subtitle: const Text(
                          'Fish, tmux, OpenSSH, Starship, Fastfetch, and zoxide',
                        ),
                        enabled: !saving && !_backupBusy,
                        onTap: installTerminalTools,
                      ),
                      ListTile(
                        title: const Text('Copy package install command'),
                        enabled: !saving && !_backupBusy,
                        onTap: copyTermuxPackages,
                      ),
                    ],
                  ),
                section(
                  'Go core libraries',
                  'Loaded Go version & hot-swap control',
                  Icons.memory_outlined,
                  [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      leading: const Icon(Icons.verified_outlined),
                      title: Text('Go core v$goVersion'),
                      subtitle: Text(
                        [
                          if (goToolchain.isNotEmpty) goToolchain,
                          if ('${goRuntime['arch'] ?? ''}'.isNotEmpty)
                            '${goRuntime['arch']}',
                          goHotCount > 0
                              ? '$goHotCount hot-swapped'
                              : 'All bundled libraries active',
                        ].join(' · '),
                      ),
                    ),
                    for (final lib in goLibs) ...[
                      const Divider(height: 1),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 6,
                        ),
                        title: Text(() {
                          final ver = '${lib['version'] ?? 'unknown'}'.trim();
                          final verLabel =
                              ver.isEmpty ||
                                  ver.startsWith('v') ||
                                  !RegExp(r'^[0-9]').hasMatch(ver)
                              ? ver
                              : 'v$ver';
                          return '${lib['role']} · $verLabel (${lib['source'] ?? 'bundled'})';
                        }()),
                        subtitle: Text(
                          [
                            if ('${lib['xxh64'] ?? ''}'.isNotEmpty)
                              'xxh64:${'${lib['xxh64']}'.substring(0, ('${lib['xxh64']}'.length > 12 ? 12 : '${lib['xxh64']}'.length))}',
                            if ('${lib['size_bytes'] ?? ''}'.isNotEmpty &&
                                (lib['size_bytes'] as num? ?? 0) > 0)
                              '${((lib['size_bytes'] as num) / (1024 * 1024)).toStringAsFixed(1)} MiB',
                            if ('${lib['last_error'] ?? ''}'.isNotEmpty)
                              'Note: ${lib['last_error']}',
                          ].join(' · '),
                        ),
                        trailing:
                            android &&
                                (lib['role'] == 'cli' ||
                                    lib['role'] == 'agent' ||
                                    lib['role'] == 'sync')
                            ? TextButton(
                                onPressed: saving
                                    ? null
                                    : () => action(() async {
                                        final res = await widget.core
                                            .pickGoBinaryFile('${lib['role']}');
                                        await load();
                                        if (res != null && mounted) {
                                          setState(() {
                                            notice = res['activated'] == true
                                                ? 'Replaced ${lib['role']} library cleanly (previous binary removed).'
                                                : res['unchanged'] == true
                                                ? '${lib['role']} already matches the selected binary.'
                                                : '${res['error'] ?? 'Could not activate picked binary'}';
                                          });
                                        }
                                      }),
                                child: const Text('Replace…'),
                              )
                            : null,
                      ),
                    ],
                    if (android) ...[
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: saving
                                  ? null
                                  : () => action(() async {
                                      final res = await widget.core
                                          .syncGoBinariesFromAssets();
                                      await load();
                                      if (mounted) {
                                        final sr =
                                            res['sync_results'] as Map? ??
                                            const {};
                                        final errs = sr.values
                                            .whereType<Map>()
                                            .map((m) => m['error'])
                                            .whereType<String>()
                                            .where((s) => s.isNotEmpty)
                                            .toList();
                                        setState(() {
                                          notice = errs.isNotEmpty
                                              ? errs.first
                                              : 'Checked Flutter assets and refreshed Go libraries.';
                                        });
                                      }
                                    }),
                              icon: const Icon(Icons.sync),
                              label: const Text('Reload from Flutter assets'),
                            ),
                            if (goHotCount > 0)
                              OutlinedButton.icon(
                                onPressed: saving
                                    ? null
                                    : () => action(() async {
                                        await widget.core.revertGoBinaries();
                                        await load();
                                        if (mounted) {
                                          setState(() {
                                            notice = 'Reverted to APK-bundled Go binaries.';
                                          });
                                        }
                                      }),
                                icon: const Icon(Icons.restore),
                                label: const Text('Revert to bundled'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
                if (android)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      'Standard mode works without Root or Shizuku using Android Wi-Fi & Nearby permissions. System partitions and boot settings are never changed.',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResourceDiagnosticsDialog extends StatefulWidget {
  const _ResourceDiagnosticsDialog({required this.core});

  final CoreBridge core;

  @override
  State<_ResourceDiagnosticsDialog> createState() =>
      _ResourceDiagnosticsDialogState();
}

class _ResourceDiagnosticsDialogState
    extends State<_ResourceDiagnosticsDialog> {
  late Future<Map<String, dynamic>> _sample = _read();

  Future<Map<String, dynamic>> _read() =>
      widget.core.runtimeStatus(includeResources: true);

  String _cpu(Object? value) =>
      value is num ? '${value.toStringAsFixed(1)}%' : 'Unavailable';

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Battery & CPU diagnostics'),
    content: SizedBox(
      width: 400,
      child: FutureBuilder<Map<String, dynamic>>(
        future: _sample,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Text('Sampling device usage…');
          }
          final data = snapshot.data?['resources'];
          if (data is! Map || data.isEmpty) {
            return const Text('Device usage data is unavailable.');
          }
          final diagnostics = data['battery_stats'] as Map? ?? const {};
          final current = data['device_current_ma'];
          final charge = diagnostics['estimated_mah'];
          final alarms = diagnostics['wakeup_alarms'];
          final locks = diagnostics['partial_wake_lock_ms'];
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (current is num)
                  ListTile(
                    title: const Text('Battery current'),
                    trailing: Text('${current.toStringAsFixed(0)} mA'),
                  ),
                ListTile(
                  title: const Text('DeviceBridge CPU'),
                  trailing: Text(_cpu(data['app_cpu_percent'])),
                ),
                ListTile(
                  title: const Text('Go binaries & shell tools'),
                  trailing: Text(_cpu(data['child_cpu_percent'])),
                ),
                for (final process
                    in (data['processes'] as List? ?? const [])
                        .whereType<Map>())
                  ListTile(
                    title: Text('${process['name']}'),
                    trailing: Text(_cpu(process['cpu_percent'])),
                  ),
                if (diagnostics.isNotEmpty)
                  ListTile(
                    title: const Text('Android battery attribution'),
                    subtitle: Text(
                      [
                        if (charge is num)
                          '${charge.toStringAsFixed(2)} mAh estimated',
                        if (alarms is num) '${alarms.toInt()} wakeup alarms',
                        if (locks is num)
                          '${(locks / 1000).toStringAsFixed(1)} s partial wake lock',
                      ].join(' · '),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => setState(() => _sample = _read()),
        child: const Text('Refresh'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

class _PrivilegeFeaturesPage extends StatefulWidget {
  const _PrivilegeFeaturesPage({
    required this.core,
    required this.title,
    required this.subtitle,
    required this.banner,
    required this.parentActive,
    required this.initialValues,
    required this.items,
  });

  final CoreBridge core;
  final String title;
  final String subtitle;
  final String banner;
  final bool parentActive;
  final Map<String, dynamic> initialValues;
  final List<(String key, String title, String subtitle)> items;

  @override
  State<_PrivilegeFeaturesPage> createState() => _PrivilegeFeaturesPageState();
}

class _PrivilegeFeaturesPageState extends State<_PrivilegeFeaturesPage> {
  late Map<String, dynamic> values = Map<String, dynamic>.from(
    widget.initialValues,
  );
  bool saving = false;
  String? error;

  Future<void> _setKey(String key, bool val) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final updated = await widget.core.appSettings(update: {key: val});
      if (mounted) {
        setState(() => values = updated);
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    }
    if (mounted) {
      setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: widget.parentActive
                  ? cs.primaryContainer
                  : cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.subtitle,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(widget.banner),
              ],
            ),
          ),
          if (saving) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(error!, style: TextStyle(color: cs.error)),
            ),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < widget.items.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  SwitchListTile.adaptive(
                    title: Text(widget.items[i].$2),
                    subtitle: Text(widget.items[i].$3),
                    value:
                        widget.parentActive &&
                        values[widget.items[i].$1] == true,
                    onChanged: (!widget.parentActive || saving)
                        ? null
                        : (v) => _setKey(widget.items[i].$1, v),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
