import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'settings_screen.dart';
import 'network_rules.dart';

enum NetworkSetupMode {
  standard('Standard'),
  shizuku('Shizuku'),
  root('Root');

  const NetworkSetupMode(this.label);
  final String label;
}

const _rootDirectLink = 'root_feature_direct_link';
const _shizukuDirectLink = 'shizuku_feature_direct_link';
const _shizukuWifiJoin = 'shizuku_feature_wifi_join';

class NetworkSetupPolicy {
  const NetworkSetupPolicy(this.settings);

  final Map<String, dynamic> settings;

  bool get rootReady =>
      settings['root_enabled'] == true && settings['root_verified'] == true;
  bool get shizukuReady => settings['shizuku_enabled'] == true;

  NetworkSetupMode get hosting => _preferredMode(_shizukuDirectLink);
  NetworkSetupMode get joining => _preferredMode(_shizukuWifiJoin);

  NetworkSetupMode _preferredMode(String shizukuFeature) {
    if (rootReady && settings[_rootDirectLink] == true) {
      return NetworkSetupMode.root;
    }
    if (shizukuReady && settings[shizukuFeature] == true) {
      return NetworkSetupMode.shizuku;
    }
    return NetworkSetupMode.standard;
  }
}

class NetworkSetupSettings extends StatefulWidget {
  const NetworkSetupSettings({super.key, required this.core});

  final CoreBridge core;

  @override
  State<NetworkSetupSettings> createState() => _NetworkSetupSettingsState();
}

class _NetworkSetupSettingsState extends State<NetworkSetupSettings>
    with WidgetsBindingObserver {
  Map<String, dynamic> _settings = {};
  NetworkRules _rules = const NetworkRules();
  Map<String, dynamic> _caps = {};
  bool _activeLink = false;
  bool _busy = false;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ModalRoute.of(context)?.isCurrent == true) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh({String? key, bool? enabled}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _rules = await NetworkRules.load(widget.core);
      _caps = await widget.core.platformCapabilities();
      final (settings, session) = await (
        widget.core.appSettings(),
        widget.core.activeDirectLink(),
      ).wait;
      if (!mounted) return;

      var updated = settings;
      final active = session['active'] == true;
      final policy = NetworkSetupPolicy(settings);
      if (key != null && enabled != null) {
        final granted = key == _rootDirectLink
            ? policy.rootReady
            : policy.shizukuReady;
        if (active) {
          _error = 'Stop or disconnect the current direct link first.';
        } else if (!granted) {
          _error =
              'Check access in Global Settings before enabling automation.';
        } else {
          updated = await widget.core.appSettings(update: {key: enabled});
        }
      }
      if (!mounted) return;
      setState(() {
        _settings = updated;
        _activeLink = active;
        _ready = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _ready = false;
        _error = 'Could not check or save network settings. $error';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openGlobalSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => SettingsScreen(core: widget.core)),
    );
    if (mounted) await _refresh();
  }

  Widget _toggle({
    required String key,
    required String title,
    required String detail,
    required bool granted,
  }) => SwitchListTile.adaptive(
    key: ValueKey('network-$key'),
    title: Text(title),
    subtitle: Text(detail),
    value: _ready && granted && _settings[key] == true,
    onChanged: _busy || !_ready || _activeLink || !granted
        ? null
        : (enabled) => _refresh(key: key, enabled: enabled),
  );

  @override
  Widget build(BuildContext context) {
    final policy = NetworkSetupPolicy(_settings);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Network settings'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _refresh,
            tooltip: 'Refresh network settings',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_busy) const LinearProgressIndicator(),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (_activeLink)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Stop or disconnect the active direct link before changing setup mode.',
                ),
              ),
            if (_ready && _settings['android'] == true)
              Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      title: const Text('Host a hotspot or Wi-Fi Direct group'),
                      subtitle: Text(
                        policy.hosting.label,
                        key: const ValueKey('network-hosting-mode'),
                      ),
                    ),
                    ListTile(
                      title: const Text('Join a peer’s Wi-Fi network'),
                      subtitle: Text(
                        policy.joining.label,
                        key: const ValueKey('network-joining-mode'),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        'DeviceBridge tries the selected mode first. Standard uses Android’s setup prompts where needed.',
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            if (_ready)
              Card(
                child: ExpansionTile(
                  title: const Text('Connection availability'),
                  subtitle: const Text('Choose usable providers; radio power stays in system settings.'),
                  children: [
                    for (final item in [
                      ('direct', 'Direct TCP'),
                      ('tailnet', 'Tailscale'),
                      ('wireguard', 'WireGuard'),
                      ('adb', 'ADB tunnels'),
                      if (_caps['wifi'] == true || _caps['hotspot_sta'] == true)
                        ('wifi', 'Wi-Fi'),
                      if (_caps['hotspot_ap'] == true) ('hotspot', 'Hotspot'),
                      if (_caps['wifi_direct'] == true)
                        ('wifi_direct', 'Wi-Fi Direct'),
                      if (_caps['usb_adb'] == true) ('usb', 'USB'),
                      if (_caps['cellular'] == true)
                        ('cellular', 'Mobile data'),
                    ])
                      SwitchListTile.adaptive(
                        key: ValueKey('availability-${item.$1}'),
                        title: Text(item.$2),
                        value: _rules.allows(item.$1),
                        onChanged: _busy || _activeLink
                            ? null
                            : (value) async {
                                setState(() => _busy = true);
                                try {
                                  await NetworkRules.save(
                                    widget.core,
                                    item.$1,
                                    value,
                                  );
                                } catch (e) {
                                  if (mounted) setState(() => _error = '$e');
                                } finally {
                                  if (mounted) {
                                    setState(() => _busy = false);
                                    await _refresh();
                                  }
                                }
                              },
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            if (_settings['android'] == true)
              Card(
                child: _toggle(
                  key: _rootDirectLink,
                  title: 'Root direct-link setup',
                  detail: policy.rootReady
                      ? 'Automate hosting and joining with Root.'
                      : 'Enable and verify Root access in Global Settings.',
                  granted: policy.rootReady,
                ),
              ),
            if (_settings['android'] == true)
              Card(
                child: Column(
                  children: [
                    _toggle(
                      key: _shizukuDirectLink,
                      title: 'Shizuku direct-link hosting',
                      detail: policy.shizukuReady
                          ? 'Automate Hotspot and Wi-Fi Direct hosting.'
                          : 'Start Shizuku and grant access in Global Settings.',
                      granted: policy.shizukuReady,
                    ),
                    _toggle(
                      key: _shizukuWifiJoin,
                      title: 'Shizuku Wi-Fi join',
                      detail: 'Join and forget the peer’s temporary network.',
                      granted: policy.shizukuReady,
                    ),
                  ],
                ),
              ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('network-global-settings'),
                onPressed: _busy ? null : _openGlobalSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Global Settings'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
