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
    final lines = <String>[];
    final advertised = candidates
        .where((v) => v['device_id'] == peer['id'])
        .toList();
    for (final v in advertised) {
      final seen = DateTime.tryParse(v['observed'] as String? ?? '');
      final fresh =
          seen != null && DateTime.now().difference(seen).inSeconds < 30;
      lines.add(
        'LAN ${v['endpoint']} · ${fresh ? 'discovered' : 'last advertised'}',
      );
    }
    for (final v in (peer['addresses'] as List? ?? [])) {
      if (advertised.any((a) => a['endpoint'] == v['endpoint'])) {
        continue;
      }
      lines.add('LAN ${v['endpoint']} · last authenticated address');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${peer['status']} · reachability checked on demand'),
        if (lines.isEmpty)
          const Text('IP not discovered · Find devices to refresh'),
        ...lines.map((line) => Text(line)),
      ],
    );
  }
}
