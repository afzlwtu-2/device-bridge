import 'package:material_ui/material_ui.dart';

abstract interface class DeviceFeature {
  String get id;
  String get label;
  IconData get icon;
  List<String> get requiredCapabilities;
  List<String> get requiredGrants;
  int get protocolVersion;
}

class RemoteFilesFeature implements DeviceFeature {
  @override
  String get id => 'remote-files-v1';
  @override
  String get label => 'Browse files';
  @override
  IconData get icon => Icons.folder_outlined;
  @override
  List<String> get requiredCapabilities => ['filesystem.read'];
  @override
  List<String> get requiredGrants => ['browse(root)'];
  @override
  int get protocolVersion => 1;
}

class FeatureRegistry {
  final Map<String, DeviceFeature> _features = {};
  void register(DeviceFeature feature) {
    if (feature.protocolVersion != 1 || _features.containsKey(feature.id)) {
      throw StateError('Unsupported or duplicate feature');
    }
    _features[feature.id] = feature;
  }

  Iterable<DeviceFeature> available(Iterable<String> supported) =>
      supported.map((id) => _features[id]).whereType<DeviceFeature>();
}
