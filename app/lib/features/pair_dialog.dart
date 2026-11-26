import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

Map<String, dynamic>? decodePairInvitation(String text) {
  if (utf8.encode(text).length > 4096) return null;
  try {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['name'] is! String ||
        (value['name'] as String).trim().isEmpty ||
        value['id'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['id'] as String) ||
        value['token'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value['token'] as String) ||
        value['expires'] is! String ||
        DateTime.tryParse(value['expires'] as String) == null) {
      return null;
    }
    return value;
  } on FormatException {
    return null;
  }
}

class SharePairInvitationDialog extends StatelessWidget {
  const SharePairInvitationDialog({
    super.key,
    required this.invitation,
    required this.fingerprint,
  });

  final String invitation;
  final String fingerprint;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Invite another device'),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'On the other device, open Add Device → Scan or enter invitation and scan this QR or paste the code. The invitation expires in five minutes.',
            ),
            const SizedBox(height: 12),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 252),
                child: QrImageView(
                  key: const ValueKey('pair-invitation-qr'),
                  data: invitation,
                  backgroundColor: Colors.white,
                  semanticsLabel: 'DeviceBridge pairing QR code',
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('This device’s fingerprint'),
            SelectableText(fingerprint, textAlign: TextAlign.center),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Clipboard.setData(ClipboardData(text: invitation)),
        child: const Text('Copy code'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  );
}

class PairInvitationResult {
  const PairInvitationResult(this.invite, {this.tailnetEndpoint});
  final String invite;
  final String? tailnetEndpoint;
}

/// The controller belongs to the route. Disposing it when showDialog's result
/// completes is too early: the outgoing route still animates and reads it.
class PairInvitationDialog extends StatefulWidget {
  const PairInvitationDialog({
    super.key,
    this.tailnetPeers = const [],
    this.peerName,
  });
  final List<Map<String, dynamic>> tailnetPeers;
  final String? peerName;
  @override
  State<PairInvitationDialog> createState() => _PairInvitationDialogState();
}

class _PairInvitationDialogState extends State<PairInvitationDialog> {
  final controller = TextEditingController();
  String? selectedTailnetEndpoint;

  void _review(String invitation) {
    FocusScope.of(context).unfocus();
    Navigator.pop(
      context,
      PairInvitationResult(
        invitation,
        tailnetEndpoint: selectedTailnetEndpoint,
      ),
    );
  }

  Future<void> _scan() async {
    FocusScope.of(context).unfocus();
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const _ScanPairInvitation()),
    );
    if (mounted && value != null) _review(value);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peerItems = <DropdownMenuItem<String?>>[
      const DropdownMenuItem(
        value: null,
        child: Text('Direct local network (Wi-Fi / Hotspot LAN)'),
      ),
      for (final node in widget.tailnetPeers)
        for (final ip in (node['ips'] as List? ?? const []))
          if (!(ip as String).contains(':'))
            DropdownMenuItem(
              value: '$ip:8731',
              child: Text(
                'Tailscale · ${node['name']} · $ip${node['online'] == true ? '' : ' (offline)'}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
    ];
    return AlertDialog(
      title: const Text('Pair with a device'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.peerName == null
                    ? 'Create an invitation on your other device, then scan its QR or paste its code.'
                    : 'Create an invitation on ${widget.peerName}, then scan its QR or paste its code.',
              ),
              if (peerItems.length > 1) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: selectedTailnetEndpoint,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Connect via',
                    border: OutlineInputBorder(),
                  ),
                  items: peerItems,
                  onChanged: (v) => setState(() => selectedTailnetEndpoint = v),
                ),
              ],
              const SizedBox(height: 16),
              if (Platform.isAndroid) ...[
                OutlinedButton.icon(
                  onPressed: _scan,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('Scan QR code'),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: controller,
                maxLines: 5,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Invitation code',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => _review(controller.text),
          child: const Text('Review'),
        ),
      ],
    );
  }
}

class _ScanPairInvitation extends StatefulWidget {
  const _ScanPairInvitation();

  @override
  State<_ScanPairInvitation> createState() => _ScanPairInvitationState();
}

class _ScanPairInvitationState extends State<_ScanPairInvitation> {
  bool _completed = false;
  bool _invalidCode = false;

  void _detect(BarcodeCapture capture) {
    if (!mounted || _completed) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (barcode.format != BarcodeFormat.qrCode || value == null) continue;
      if (decodePairInvitation(value) == null) {
        if (!_invalidCode) setState(() => _invalidCode = true);
        continue;
      }
      _completed = true;
      Navigator.pop(context, value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan pairing QR')),
    body: Column(
      children: [
        Expanded(
          child: MobileScanner(
            onDetect: _detect,
            errorBuilder: (context, error) => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Camera unavailable. Allow camera access or go back and paste the invitation code.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _invalidCode
                  ? 'That QR is not a DeviceBridge invitation.'
                  : 'Point the camera at the invitation on your other device.',
            ),
          ),
        ),
      ],
    ),
  );
}
