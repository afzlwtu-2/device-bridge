import 'dart:convert';

import '../core/bridge.dart';

/// Availability is policy; it never means that a service or route is ready.
class NetworkRules {
  const NetworkRules([this.policy = const {}]);
  final Map<String, dynamic> policy;
  bool allows(String id) => policy['network_$id'] != false;
  bool transport(String id) => allows(switch (id) {
    'lan' || 'direct-lan-v1' => 'direct',
    'tailnet' || 'tailscale' => 'tailnet',
    'adb' => 'adb',
    'wireguard' => 'wireguard',
    _ => id,
  });
  bool link(String kind) => allows(switch (kind) {
    'usb_net' || 'usbNetwork' => 'usb',
    'wifiDirect' => 'wifi_direct',
    'ethernet' => 'direct',
    _ => kind,
  });
  bool path(String transportId, {String? kind, String? interfaceName}) {
    if (!transport(transportId)) return false;
    final iface = interfaceName ?? '';
    final observedKind =
        kind ??
        (iface.startsWith('p2p') || iface.startsWith('dbp2p')
            ? 'wifi_direct'
            : iface.startsWith('ap') || iface.startsWith('swlan')
            ? 'hotspot'
            : iface.startsWith('wl')
            ? 'wifi'
            : iface.startsWith('rndis') || iface.startsWith('usb')
            ? 'usb'
            : iface.startsWith('rmnet') || iface.startsWith('wwan')
            ? 'cellular'
            : null);
    return observedKind == null || link(observedKind);
  }

  static Future<NetworkRules> load(CoreBridge core) async {
    final raw = await core.run(['network-policy']);
    if (raw is! Map) return const NetworkRules();
    return NetworkRules(Map<String, dynamic>.from(raw));
  }

  static Future<void> save(CoreBridge core, String id, bool value) async {
    await core.run([
      'network-policy',
      '-',
    ], input: jsonEncode({'network_$id': value}));
  }
}
