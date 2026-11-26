import 'dart:async';

import 'package:devicebridge/core/bridge.dart';
import 'package:devicebridge/features/settings_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _SettingsCore extends LocalCore {
  @override
  Future<Map<String, dynamic>> appSettings({
    Map<String, dynamic>? update,
  }) async => {'android': true, 'go_runtime': <String, dynamic>{}};
}

void main() {
  testWidgets('Termux backup shows real progress only in its card', (
    tester,
  ) async {
    const events = MethodChannel('dev.devicebridge/termux_backup');
    const codec = StandardMethodCodec();
    final messenger = tester.binding.defaultBinaryMessenger;
    final done = Completer<Map<String, dynamic>>();
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(LocalCore.channel, (call) async {
      if (call.method == 'appVersion') return '1.0.2 (1000002)';
      if (call.method == 'createTermuxBackup') return done.future;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(events, null);
      messenger.setMockMethodCallHandler(LocalCore.channel, null);
    });

    Future<void> progress(Map<String, Object?>? event) async {
      await messenger.handlePlatformMessage(
        events.name,
        codec.encodeSuccessEnvelope(event),
        null,
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(core: _SettingsCore())),
    );
    await tester.pumpAndSettle();
    final create = find.byKey(const ValueKey('termux-backup-create'));
    await tester.scrollUntilVisible(create, 400);
    await tester.ensureVisible(create);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();

    final status = find.byKey(const ValueKey('termux-backup-status'));
    final card = find.ancestor(of: create, matching: find.byType(Card));
    expect(find.descendant(of: card, matching: status), findsOneWidget);

    await progress({'phase': 'write', 'bytes': 1024 * 1024});
    expect(
      find.descendant(of: status, matching: find.text('Writing archive')),
      findsOneWidget,
    );
    expect(find.text('1.0 MiB written'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await progress({'phase': 'verify', 'bytes': 1024, 'total': 4096});
    final bar = find.descendant(
      of: status,
      matching: find.byType(LinearProgressIndicator),
    );
    expect(tester.widget<LinearProgressIndicator>(bar).value, .25);
    expect(find.text('1.0 KiB of 4.0 KiB · 25%'), findsOneWidget);

    await progress(null);
    done.complete({'skipped': 0});
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: status,
        matching: find.text('Termux backup saved and verified.'),
      ),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets(
    'Termux backup folder/exclude picker omits .cache and preserves .env* and custom excludes',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      Map<String, dynamic>? capturedSpec;
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.devicebridge/termux_backup'),
        (_) async => null,
      );
      messenger.setMockMethodCallHandler(LocalCore.channel, (call) async {
        if (call.method == 'appVersion') return '1.0.4 (1000004)';
        if (call.method == 'listTermuxBackupEntries') {
          return {
            'entries': [
              {
                'path': '.cache',
                'name': '.cache',
                'is_dir': true,
                'size_bytes': 0,
                'excluded_by_default': true,
                'always_included': false,
              },
              {
                'path': '.env',
                'name': '.env',
                'is_dir': false,
                'size_bytes': 32,
                'excluded_by_default': false,
                'always_included': true,
              },
              {
                'path': 'projects',
                'name': 'projects',
                'is_dir': true,
                'size_bytes': 1024,
                'excluded_by_default': false,
                'always_included': false,
              },
            ],
            'default_excludes': ['.cache', 'node_modules', '.node_modules'],
          };
        }
        if (call.method == 'createTermuxBackup') {
          final args = call.arguments as Map?;
          capturedSpec = args == null
              ? null
              : Map<String, dynamic>.from(args['spec'] as Map);
          return {'skipped': 0, 'excluded': 2};
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('dev.devicebridge/termux_backup'),
          null,
        );
        messenger.setMockMethodCallHandler(LocalCore.channel, null);
      });

      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(core: _SettingsCore())),
      );
      await tester.pumpAndSettle();
      final create = find.byKey(const ValueKey('termux-backup-create'));
      await tester.scrollUntilVisible(create, 400);
      await tester.ensureVisible(create);
      await tester.pumpAndSettle();
      await tester.tap(create);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('termux-backup-dialog')),
        findsOneWidget,
      );
      final excludeInput = find.byKey(
        const ValueKey('termux-backup-exclude-input'),
      );
      await tester.ensureVisible(excludeInput);
      await tester.enterText(excludeInput, '.next');
      final addExclude = find.byKey(
        const ValueKey('termux-backup-exclude-add'),
      );
      await tester.ensureVisible(addExclude);
      await tester.pumpAndSettle();
      await tester.tap(addExclude);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('termux-backup-confirm')));
      await tester.pumpAndSettle();

      expect(capturedSpec, isNotNull);
      expect(capturedSpec!['include_paths'], containsAll(['.env', 'projects']));
      expect(capturedSpec!['include_paths'], isNot(contains('.cache')));
      expect(
        capturedSpec!['exclude_patterns'],
        containsAll(['.cache', 'node_modules', '.node_modules', '.next']),
      );
      expect(
        find.textContaining('2 generated/cache items excluded'),
        findsOneWidget,
      );
    },
  );
}
