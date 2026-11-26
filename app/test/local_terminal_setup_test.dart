import 'dart:async';
import 'dart:convert';

import 'package:devicebridge/core/bridge.dart';
import 'package:devicebridge/features/local_terminal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _TestTerminalCore extends LocalCore {
  final StreamController<String> frames = StreamController<String>();

  @override
  Future<Map<String, dynamic>> appSettings({
    Map<String, dynamic>? update,
  }) async => const {};

  @override
  Future<GuestTerminalLink> openLocalTerminal(
    Map<String, dynamic> request,
  ) async {
    return GuestTerminalLink(frames.stream, (_) async {}, () async {
      if (!frames.isClosed) await frames.close();
    });
  }
}

void main() {
  testWidgets(
    'LocalTerminalScreen shows live setup progress banner and clears it when shell is ready',
    (tester) async {
      final core = _TestTerminalCore();
      addTearDown(() async {
        if (!core.frames.isClosed) await core.frames.close();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LocalTerminalScreen(core: core)),
        ),
      );
      await tester.pumpAndSettle();

      core.frames.add(
        jsonEncode({
          'state': 'setup',
          'phase': 'download',
          'message': 'Downloading bootstrap-aarch64.zip (12.0 / 24.0 MiB)',
          'bytes': 12 * 1024 * 1024,
          'total': 24 * 1024 * 1024,
        }),
      );
      await tester.pump();
      await tester.pump();

      final banner = find.byKey(const ValueKey('termux-setup-progress'));
      expect(banner, findsOneWidget);
      expect(
        find.text('Downloading bootstrap-aarch64.zip (12.0 / 24.0 MiB)'),
        findsOneWidget,
      );
      expect(find.text('12.0 MiB / 24.0 MiB · 50%'), findsOneWidget);
      final bar = find.descendant(
        of: banner,
        matching: find.byType(LinearProgressIndicator),
      );
      expect(
        tester.widget<LinearProgressIndicator>(bar).value,
        closeTo(0.5, 0.01),
      );

      core.frames.add(jsonEncode({'state': 'ready'}));
      await tester.pump();

      expect(find.byKey(const ValueKey('termux-setup-progress')), findsNothing);
    },
  );
}
