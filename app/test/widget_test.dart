import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:devicebridge/main.dart';
import 'package:devicebridge/core/bridge.dart';

class FakeCore implements CoreBridge {
  final _progressController = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Future<void> enableTailnet(bool enabled) async {}
  @override
  Future<void> openLogin(String url) async {}
  @override
  Future<void> openConnectionSetup(String kind) async {}
  @override
  Future<void> shutdown() async {
    await _progressController.close();
  }
  @override
  Stream<Map<String, dynamic>> get networkEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get transferProgress => _progressController.stream;
  void emitProgress(Map<String, dynamic> p) => _progressController.add(p);
  final calls = <List<String>>[];
  @override
  String get downloads => '/private/downloads';
  @override
  Map<String, dynamic>? get network => {
    'interface': 'test0',
    'cidr': '192.168.50.2/24',
  };
  @override
  Future<void> initialize() async {}
  @override
  Future<void> approveNetwork(Map<String, dynamic> network) async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<String?> saveDownload(String path) async => path;
  @override
  Future<List<Map<String, dynamic>>> networks() async => [];
  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    calls.add(arguments);
    return switch (arguments.first) {
      'connection' => {'transport': 'lan'},
      'theme' => {'theme': arguments.length > 1 ? arguments[1] : 'system'},
      'export' => {'status': 'export_registered'},
      'identity' => {'id': 'phone', 'name': 'Phone'},
      'peers' => [
        {'id': 'laptop', 'name': 'Laptop', 'status': 'paired'},
      ],
      'resolve' => {
        'transport': 'direct-lan-v1',
        'endpoint': '192.168.50.3:8731',
        'interface': 'test0',
        'rtt': 1000000,
        'mib_per_second': 42.5,
      },
      'roots' => [
        {'id': 'approved', 'name': 'Approved'},
      ],
      'list' => {
        'entries': [
          {
            'name': 'hello.txt',
            'path': 'hello.txt',
            'kind': 'file',
            'size': 5,
            'modified': '2026-11-18',
          },
        ],
      },
      'pull' => {
        'destination': '/private/downloads/hello.txt',
        'mode': 'tar',
        'mib_per_second': 42.5,
      },
      'discover' => [],
      'pair' => {'status': 'pending'},
      _ => throw StateError('Unexpected command $arguments'),
    };
  }
}

void main() {
  testWidgets('Invitation route closes safely before fingerprint approval', (
    tester,
  ) async {
    final core = FakeCore();
    await tester.pumpWidget(DeviceBridgeApp(core: core));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pair device'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      '{"version":1,"id":"laptop","name":"Laptop","token":"test"}',
    );
    await tester.tap(find.text('Review'));
    // The core is intentionally busy while the fingerprint modal awaits input;
    // its progress indicator animates. Advance the route transition explicitly.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.text('Fingerprint matches'), findsOneWidget);
    await tester.tap(find.text('Fingerprint matches'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(core.calls.any((c) => c.first == 'pair'), isTrue);
  });
  testWidgets('Four primary areas and remote files inside a paired device', (
    tester,
  ) async {
    final core = FakeCore();
    await tester.pumpWidget(DeviceBridgeApp(core: core));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination), findsNWidgets(4));
    for (final label in ['Home', 'Devices', 'Share', 'Sync']) {
      expect(find.text(label), findsWidgets);
    }
    expect(find.text('Files'), findsNothing);
    expect(find.text('Terminal'), findsNothing);
    expect(core.calls.any((c) => c.first == 'list'), isFalse);
    await tester.ensureVisible(find.text('Laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();
    expect(find.text('Authenticated direct LAN'), findsOneWidget);
    await tester.tap(find.text('Approved'));
    await tester.pumpAndSettle();
    expect(find.text('hello.txt'), findsOneWidget);
    expect(core.calls.any((c) => c.first == 'pull'), isFalse);
    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Existing files will not be overwritten'),
      findsOneWidget,
    );
    expect(core.calls.any((c) => c.first == 'pull'), isFalse);
    await tester.tap(find.widgetWithText(FilledButton, 'Pull'));
    await tester.pumpAndSettle();
    expect(core.calls.last, [
      'pull',
      'laptop',
      'approved',
      'hello.txt',
      '/private/downloads/hello.txt',
    ]);
    expect(find.textContaining('Verified download (streaming tar)'), findsOneWidget);
    expect(find.textContaining('42.50 MiB/s'), findsOneWidget);
  });

  testWidgets('Matte paper and AMOLED themes render cleanly', (tester) async {
    final core = FakeCore();
    await tester.pumpWidget(DeviceBridgeApp(core: core));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Matte paper'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Find devices'), findsOneWidget);

    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AMOLED black · Neon green'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AMOLED black · Neon red'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
