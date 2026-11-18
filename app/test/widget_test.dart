import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:devicebridge/main.dart';
import 'package:devicebridge/core/bridge.dart';

class FakeCore implements CoreBridge {
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
      'identity' => {'id': 'phone', 'name': 'Phone'},
      'peers' => [
        {'id': 'laptop', 'name': 'Laptop', 'status': 'paired'},
      ],
      'resolve' => {
        'endpoint': '192.168.50.3:8731',
        'interface': 'test0',
        'rtt': 1000000,
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
      'pull' => {'destination': '/private/downloads/hello.txt'},
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
    expect(find.textContaining('Verified download'), findsOneWidget);
  });
}
