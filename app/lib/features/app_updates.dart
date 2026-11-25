import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';

class AppUpdates {
  static bool _checking = false;

  static Future<String?> version() =>
      LocalCore.channel.invokeMethod<String>('appVersion');

  static Future<String?> check(
    BuildContext context, {
    bool manual = false,
  }) async {
    if (_checking) return 'An update check is already in progress.';
    _checking = true;
    try {
      final release = await LocalCore.channel.invokeMapMethod<String, dynamic>(
        'checkAppUpdate',
        {'manual': manual},
      );
      if (!context.mounted) return null;
      if (release == null) return manual ? 'DeviceBridge is up to date.' : null;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _UpdateDialog(
          version: release['version'] as String,
          bytes: release['bytes'] as int,
        ),
      );
      return null;
    } on PlatformException catch (error) {
      if (manual) throw error.message ?? 'Could not check for updates.';
      return null;
    } finally {
      _checking = false;
    }
  }
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.version, required this.bytes});

  final String version;
  final int bytes;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _installing = false;
  String? _message;

  Future<void> _download() async {
    setState(() => _installing = true);
    try {
      final installed = await LocalCore.channel.invokeMethod<bool>(
        'downloadAppUpdate',
        {'version': widget.version},
      );
      if (mounted) {
        setState(() {
          _installing = false;
          _message = installed == true
              ? 'Update installed.'
              : 'Installation ended. You can try again from Settings.';
        });
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _message = error.message ?? 'Could not install the update.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = (widget.bytes / (1024 * 1024)).toStringAsFixed(1);
    return PopScope(
      canPop: !_installing,
      child: AlertDialog(
        title: Text('DeviceBridge ${widget.version} is available'),
        content: _installing
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Downloading, verifying, and opening the installation…'),
                  SizedBox(height: 12),
                  LinearProgressIndicator(),
                ],
              )
            : Text(_message ?? 'Download and install the $size MiB update?'),
        actions: [
          if (!_installing)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_message == null ? 'Later' : 'Close'),
            ),
          if (!_installing && _message == null)
            FilledButton(
              onPressed: _download,
              child: const Text('Download and install'),
            ),
        ],
      ),
    );
  }
}
