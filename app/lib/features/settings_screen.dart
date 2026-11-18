import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

/// App-wide access and lifecycle preferences. Feature settings stay in features.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.core});
  final CoreBridge core;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  Map<String, dynamic> values = {};
  bool loading = true, saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !saving) {
      load();
    }
  }

  Future<void> load() async {
    try {
      final result = await widget.core.appSettings();
      if (mounted) {
        setState(() {
          values = result;
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
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    }
    if (mounted) {
      setState(() => saving = false);
    }
  }

  Future<void> save(String key, bool value) => action(() async {
    final result = await widget.core.appSettings(update: {key: value});
    if (mounted) {
      setState(() => values = result);
    }
  });
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
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final android = values['android'] == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            tooltip: 'Refresh settings',
            onPressed: saving ? null : load,
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
                  margin: const EdgeInsets.only(bottom: 28),
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
                              'Optional access and app-wide preferences.',
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
                if (android) ...[
                  section(
                    'Root',
                    'Permission only when you enable it',
                    Icons.admin_panel_settings_outlined,
                    [
                      toggle(
                        'root_enabled',
                        'Root access',
                        '${values['root_status'] ?? 'Not requested'}. Enable to request permission and verify access.',
                      ),
                      if (values['root_enabled'] == true)
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
                    'Use an existing Shizuku service',
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
                  section(
                    'App behavior',
                    'Applies across DeviceBridge',
                    Icons.phone_android_outlined,
                    [
                      toggle(
                        'keep_awake',
                        'Keep screen awake',
                        'Only while DeviceBridge is in the foreground.',
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      'Privileged file browsing is not enabled in this build. System partitions and boot settings are never changed.',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ] else if (!loading)
                  const ListTile(
                    leading: Icon(Icons.computer_outlined),
                    title: Text('No additional permissions needed'),
                    subtitle: Text(
                      'Root and Shizuku access controls are available on Android.',
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
