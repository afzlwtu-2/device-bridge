import 'package:material_ui/material_ui.dart';

/// Advertisements never authenticate a device. Keep current hints separate from
/// last authenticated observations, and avoid claiming reachability from either.
class DeviceAddresses extends StatelessWidget {
  const DeviceAddresses({
    super.key,
    required this.peer,
    required this.candidates,
  });
  final Map<String, dynamic> peer;
  final List<dynamic> candidates;
  @override
  Widget build(BuildContext context) {
    final advertised = candidates
        .where((v) => v['device_id'] == peer['id'])
        .toList();
    String? current;
    for (final v in advertised) {
      final seen = DateTime.tryParse(v['observed'] as String? ?? '');
      final fresh =
          seen != null && DateTime.now().difference(seen).inSeconds < 30;
      if (fresh) {
        current = 'LAN ${v['endpoint']}';
        break;
      }
      current ??= 'LAN ${v['endpoint']}';
    }
    return Text(
      current == null
          ? '${peer['status']} · tap for details'
          : '${peer['status']} · $current',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
