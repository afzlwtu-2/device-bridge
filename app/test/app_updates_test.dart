import 'package:devicebridge/core/bridge.dart';
import 'package:devicebridge/features/app_updates.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('GitHub APK download requires confirmation and reports failure', (
    tester,
  ) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    final requestedVersions = <String>[];
    messenger.setMockMethodCallHandler(LocalCore.channel, (call) async {
      switch (call.method) {
        case 'checkAppUpdate':
          return {'version': '1.10.0', 'bytes': 70 * 1024 * 1024};
        case 'downloadAppUpdate':
          requestedVersions.add(call.arguments['version'] as String);
          throw PlatformException(
            code: 'update_install_failed',
            message: 'The downloaded APK failed XXH64 verification.',
          );
        default:
          return null;
      }
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(LocalCore.channel, null),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => AppUpdates.check(context),
              child: const Text('Check'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    expect(find.text('DeviceBridge 1.10.0 is available'), findsOneWidget);
    expect(requestedVersions, isEmpty);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(requestedVersions, isEmpty);

    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download and install'));
    await tester.pumpAndSettle();
    expect(requestedVersions, ['1.10.0']);
    expect(
      find.text('The downloaded APK failed XXH64 verification.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });
}
