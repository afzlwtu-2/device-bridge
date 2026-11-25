// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:devicebridge/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

Future<void> waitFor(
  WidgetTester tester,
  Finder finder,
  String step, {
  int seconds = 25,
}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 80));
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  if (finder.evaluate().isEmpty) {
    print(
      'VISIBLE $step: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data ?? text.textSpan?.toPlainText()).toList()}',
    );
  }
  expect(finder, findsWidgets, reason: step);
}

Future<void> tap(WidgetTester tester, Finder target, String step) async {
  await waitFor(tester, target, step);
  if (Scrollable.maybeOf(tester.element(target.first)) != null) {
    await tester
        .ensureVisible(target.first)
        .timeout(const Duration(seconds: 3));
  }
  // onlyPumps advances route animations solely through explicit pumps; settle
  // any entrance transition so the target is hit-testable.
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(target.first).timeout(const Duration(seconds: 8));
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> choose(WidgetTester tester, String current, String next) async {
  await tap(tester, find.text(current), 'open $current dropdown');
  await tester.pump(const Duration(milliseconds: 200));
  await tap(tester, find.text(next).last, 'choose $next');
}

/// The Linux core serializes non-parallel CLI operations; the shell's peer
/// refresh can transiently reject a Sync action with "Another operation is
/// active". Report that outcome separately so callers retry only that case.
Future<String> outcome(WidgetTester tester, Finder success, int seconds) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 80));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (success.evaluate().isNotEmpty) return 'success';
    if (find
        .textContaining('Another operation is active')
        .evaluate()
        .isNotEmpty) {
      return 'conflict';
    }
  }
  return success.evaluate().isNotEmpty ? 'success' : 'timeout';
}

List<String> treeFiles(String root) {
  final base = Directory(root);
  final result = <String>[];
  for (final entity in base.listSync(recursive: true)) {
    if (entity is File) {
      final rel = entity.path.substring(root.length + 1);
      if (rel.split('/').contains('.stfolder') ||
          rel.split('/').contains('.stversions')) {
        continue;
      }
      result.add(rel);
    }
  }
  result.sort();
  return result;
}

void main() {
  final integration = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // An idle Wayland window stops receiving compositor frame callbacks, which
  // stalls benchmarkLive's wait-only pumps. onlyPumps drives a frame for every
  // explicit pump, so the harness never depends on the compositor's vsync.
  integration.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final env = Platform.environment;
  final work = env['DEVICEBRIDGE_ACCEPTANCE']!;
  final state = env['DEVICEBRIDGE_STATE']!;
  final cli = env['DEVICEBRIDGE_CORE']!;
  final remotePath = env['DESK_GATE_REMOTE_PATH']!;

  tearDownAll(() async {
    final passed = integration.failureMethodsDetails.isEmpty;
    File('$work/gui-result.txt')
        .writeAsStringSync(passed ? 'PASS\n' : 'FAIL\n');
    exit(passed ? 0 : 1);
  });

  testWidgets('Linux desktop sync-modes acceptance', (tester) async {
    app.main();
    await waitFor(
      tester,
      find.text('Local storage & readiness'),
      'Home rendered',
    );
    print('CHECK Home rendered');
    await tap(tester, find.byKey(const ValueKey('home-open-file-manager')), 'open Files');
    await tap(tester, find.byTooltip('Synced folders'), 'Synced folders');

    var prepared = 'timeout';
    for (var i = 0; i < 8 && prepared != 'success'; i++) {
      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Prepare profile'),
        'prepare the managed profile',
      );
      prepared = await outcome(tester, find.text('Syncthing device ID'), 25);
      if (prepared == 'conflict') {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    expect(prepared, 'success', reason: 'profile prepared');
    print('CHECK profile prepared');

    final peerStId = File('$work/peer/syncthing-v1/device-id')
        .readAsStringSync()
        .trim();
    var registered = 'timeout';
    for (var i = 0; i < 6 && registered != 'success'; i++) {
      await tap(
        tester,
        find.widgetWithText(OutlinedButton, 'Register folder'),
        'open register dialog',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Shared group ID'),
        'deskgate',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Peer Syncthing device ID'),
        peerStId,
      );
      await choose(
        tester,
        'Non-git files (filtered projection)',
        'Full folder (incl. hidden & .git)',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Local folder to sync (required)'),
        '$work/source',
      );
      await choose(tester, 'Receive only', 'Send only');
      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Register'),
        'register full-mode folder',
      );
      registered = await outcome(tester, find.text('deskgate'), 15);
      if (registered == 'conflict') {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    expect(registered, 'success', reason: 'registered');
    await waitFor(
      tester,
      find.textContaining('Full folder · incl. hidden & .git'),
      'full mode label',
    );
    print('CHECK full-mode folder registered');

    // One-off Full pull through the real UI and the real mTLS pull path.
    // The fixture agent disables discovery; refresh the authenticated endpoint
    // cache for the loopback LAN exactly as a recent reachability probe would.
    final refresh = await Process.run(cli, [
      '--state',
      state,
      '--interface',
      'lo',
      '--lan-cidr',
      '127.0.0.1/8',
      '--endpoint',
      env['DESK_GATE_ENDPOINT']!,
      'resolve',
      env['DESK_GATE_PEER_ID']!,
    ]);
    expect(refresh.exitCode, 0, reason: '${refresh.stderr}');
    var pulled = 'timeout';
    for (var i = 0; i < 6 && pulled != 'success'; i++) {
      await tap(tester, find.byType(PopupMenuButton<String>), 'folder menu');
      await tap(tester, find.text('Full pull from peer…'), 'full pull action');
      await waitFor(
        tester,
        find.widgetWithText(TextFormField, 'Remote folder path'),
        'full pull dialog',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Remote folder path'),
        remotePath,
      );
      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Pull everything'),
        'start full pull',
      );
      pulled = await outcome(
        tester,
        find.textContaining('Full pull verified'),
        60,
      );
      if (pulled == 'conflict') {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    expect(pulled, 'success', reason: 'full pull verified');
    final downloads = Directory('$state/downloads');
    final pulledDir = downloads.listSync().whereType<Directory>().firstWhere((
      d,
    ) {
      final name = d.path.split('/').last;
      return name.startsWith('source-') && !name.endsWith('.devicebridge-part');
    });
    expect(
      File('${pulledDir.path}/tracked.txt').readAsStringSync(),
      'committed + uncommitted edit\n',
    );
    expect(File('${pulledDir.path}/.git/HEAD').existsSync(), isTrue);
    expect(
      File('${pulledDir.path}/.hidden').readAsStringSync(),
      'hidden working file\n',
    );
    expect(treeFiles(pulledDir.path), treeFiles('$work/source'));
    print('CHECK full pull byte-identical incl. .git');

    // One-time approved full-mode session through the UI, with the peer side
    // driven by the same CLI the Termux workflow uses.
    final clientStId = File('$state/syncthing-v1/device-id')
        .readAsStringSync()
        .trim();
    final register = await Process.run(cli, [
      '--state',
      '$work/peer',
      'syncthing',
      'register',
      'deskgate',
      clientStId,
      'receiveonly',
      '--mode',
      'full',
      '--source',
      '$work/mirror',
    ]);
    expect(register.exitCode, 0, reason: '${register.stderr}');
    final manifestResult = await Process.run(cli, [
      '--state',
      state,
      'syncthing',
      'manifest',
      'deskgate',
    ]);
    expect(manifestResult.exitCode, 0, reason: '${manifestResult.stderr}');
    final manifest =
        jsonDecode(manifestResult.stdout as String)['manifest_xxh64'] as String;
    final peerSession = await Process.start(cli, [
      '--state',
      '$work/peer',
      '--interface',
      'lo',
      '--lan-cidr',
      '127.0.0.1/8',
      '--approve-sync',
      'syncthing',
      'run',
      'deskgate',
      '127.0.0.1:22011',
      '127.0.0.1:22010',
      manifest,
      '120s',
    ]);
    var synced = 'timeout';
    for (var i = 0; i < 6 && synced != 'success'; i++) {
      await tap(tester, find.text('deskgate'), 'open session dialog');
      await waitFor(
        tester,
        find.widgetWithText(TextFormField, 'Local port'),
        'session dialog',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Local port'),
        '22010',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Peer IPv4 address and port'),
        '127.0.0.1:22011',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Source manifest XXH64'),
        manifest,
      );
      await tap(
        tester,
        find.widgetWithText(FilledButton, 'Approve and start'),
        'approve the session',
      );
      synced = await outcome(
        tester,
        find.textContaining('Folder verified. Sync paused.'),
        100,
      );
      if (synced == 'conflict') {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }
    }
    expect(synced, 'success', reason: 'session verified and paused');
    expect(await peerSession.exitCode, 0);
    expect(treeFiles('$work/mirror'), treeFiles('$work/source'));
    expect(
      File('$work/mirror/tracked.txt').readAsStringSync(),
      'committed + uncommitted edit\n',
    );
    expect(File('$work/mirror/.git/HEAD').existsSync(), isTrue);
    print('CHECK full-mode session mirrored the worktree');

    if (env['DESK_GATE_NATIVE_FILES'] == '1') {
      final browse = Directory('$state/downloads/native-files-source');
      browse.createSync();
      File('${browse.path}/fixture.txt')
          .writeAsStringSync('Native desktop Files');
      await tap(tester, find.byTooltip('Back'), 'back to Files');
      await tap(
        tester,
        find.byKey(const ValueKey('file-pane-0-storage')),
        'local storage root',
      );
      await tap(
        tester,
        find.text('DeviceBridge Downloads').last,
        'choose local downloads',
      );
      await tap(tester, find.text('native-files-source'), 'open local folder');
      await waitFor(tester, find.text('fixture.txt'), 'browse Linux file');
      await tap(tester, find.byKey(const ValueKey('file-pane-0-actions')), 'folder actions');
      await tap(tester, find.text('Sync this folder'), 'local folder sync');
      await choose(tester, 'home', 'native-mirror');
      await tap(
        tester,
        find.text('Use this folder'),
        'select paired destination',
      );
      await waitFor(
        tester,
        find.textContaining(browse.path),
        'native Linux path',
      );
      final browseRefresh = await Process.run(cli, [
        '--state',
        state,
        '--interface',
        'lo',
        '--lan-cidr',
        '127.0.0.1/8',
        '--endpoint',
        env['DESK_GATE_ENDPOINT']!,
        'resolve',
        env['DESK_GATE_PEER_ID']!,
      ]);
      expect(browseRefresh.exitCode, 0, reason: '${browseRefresh.stderr}');
      await tap(
        tester,
        find.text('Register these folders'),
        'register from Files',
      );
      await waitFor(
        tester,
        find.textContaining('Folders registered.'),
        'saved from Files',
      );
      await tap(tester, find.byTooltip('Back'), 'return to native Files');
      await tap(tester, find.byTooltip('Parent folder'), 'open Downloads');
      await waitFor(
        tester,
        find.byTooltip('Synced folder · paused'),
        'local registration badge',
      );
      print('CHECK local Linux Files browse, register and badge');
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
