import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:devicebridge/features/folder_pair_sync.dart';
import 'package:devicebridge/features/phone_files.dart';
import 'package:devicebridge/features/remote_files.dart';

import 'widget_test.dart' show FakeCore;

class PairCore extends FakeCore {
  final metadata = <Map<String, dynamic>>[];
  final saved = <Map<String, dynamic>>[];
  bool failTargetRegistration = false;
  bool preferTailscale = false;
  @override
  Future<dynamic> run(List<String> args, {String? input}) async {
    if (args.first == 'sync-control') {
      calls.add(args);
      final request = Map<String, dynamic>.from(jsonDecode(input!) as Map);
      metadata.add({'device': args[1], ...request});
      switch (request['operation']) {
        case 'register':
          if (args[1] == 'target' && failTargetRegistration) {
            throw StateError('Target registration response was interrupted');
          }
          return {'state': 'paused'};
        case 'prepare':
          return {
            'installed': true,
            'prepared': true,
            'device_id': args[1] == 'source'
                ? 'SOURCE-ENGINE'
                : 'TARGET-ENGINE',
            'networks': [
              {
                'interface': 'wlan0',
                'cidr': args[1] == 'source'
                    ? '192.168.1.10/24'
                    : '192.168.1.11/24',
                'kind': 'lan',
              },
              if (preferTailscale)
                {
                  'interface': 'tailscale0',
                  'cidr': args[1] == 'source'
                      ? '100.64.0.10/32'
                      : '100.64.0.11/32',
                  'kind': 'tailscale',
                },
            ],
          };
        case 'probe':
          return {'reachable': true};
        case 'manifest':
          return {'manifest_xxh64': '0123456789abcdef'};
        case 'status':
          return {'state': 'verified'};
        default:
          return {'state': 'running'};
      }
    }
    if (args.first == 'sync-pairs') {
      calls.add(args);
      if (input != null) {
        saved.add(Map<String, dynamic>.from(jsonDecode(input) as Map));
      }
      return saved;
    }
    if (args.first == 'resolve' || args.contains('resolve')) {
      calls.add(args);
      final isSource = args.contains('source');
      return {
        'endpoint': isSource ? '192.168.1.10:8731' : '192.168.1.11:8731',
        'rtt': 200000000,
        'interface': 'wlan0',
        'transport': 'lan',
      };
    }
    if (args.first == 'connection') {
      if (preferTailscale) {
        return {'transport': 'tailnet', 'tailnet_endpoint': '100.64.0.11:8731'};
      }
      return {
        'transport': 'lan',
        'lan_endpoint': args[1] == 'source'
            ? '192.168.1.10:8731'
            : '192.168.1.11:8731',
      };
    }
    if (args.first == 'peers') {
      return [
        {
          'id': 'source',
          'name': 'Laptop A',
          'status': 'paired',
          'addresses': [],
        },
        {'id': 'target', 'name': 'VM B', 'status': 'paired', 'addresses': []},
      ];
    }
    return super.run(args, input: input);
  }
}

class BadgeCore extends FakeCore {
  @override
  Future<dynamic> localFiles(
    String operation,
    Map<String, dynamic> arguments,
  ) async => operation == 'roots'
      ? [
          {
            'id': 'internal',
            'name': 'Phone storage',
            'available': true,
            'native_path': '/storage/emulated/0',
          },
          {
            'id': 'termux_home',
            'name': 'Termux Home',
            'available': true,
            'native_path': '/data/user/0/dev.devicebridge.devicebridge/files/terminal/files/home',
          },
          {'id': 'recycle_bin', 'name': 'Recycle Bin', 'available': true},
        ]
      : {
          'entries': [
            {'name': 'projects', 'path': 'projects', 'kind': 'directory'},
            {'name': 'note.txt', 'path': 'note.txt', 'kind': 'file', 'size': 3},
          ],
        };
  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    if (arguments.first == 'syncthing') {
      return {
        'installed': true,
        'prepared': true,
        'registered': [
          {'source': '/storage/emulated/0/projects', 'activity': 'paused'},
        ],
      };
    }
    return super.run(arguments, input: input);
  }
}

void main() {
  testWidgets('Selected Tailscale sync waits for explicit session consent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = PairCore()..preferTailscale = true;
    await tester.pumpWidget(
      MaterialApp(
        home: FolderPairSync(
          core: core,
          source: const SyncLocation(
            device: 'source',
            name: 'Laptop A',
            root: 'home',
            path: 'project',
          ),
          target: const SyncLocation(
            device: 'target',
            name: 'VM B',
            root: 'data',
            path: 'copy',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final approve = find.text('Approve and sync now');
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect(find.textContaining('Enable Allow remote route'), findsOneWidget);
    expect(
      core.metadata.where(
        (r) => const {'probe', 'start'}.contains(r['operation']),
      ),
      isEmpty,
    );

    final remote = find.widgetWithText(CheckboxListTile, 'Allow remote route');
    await tester.ensureVisible(remote);
    await tester.tap(remote);
    await tester.ensureVisible(approve);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    final starts = core.metadata.where((r) => r['operation'] == 'start');
    expect(starts, hasLength(2));
    for (final start in starts) {
      expect(start['route'], 'tailscale');
      expect(start['remote_approved'], isTrue);
    }
  });

  testWidgets(
    'Phone controller starts two remote endpoints without a file relay',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = PairCore();
      await tester.pumpWidget(
        MaterialApp(
          home: FolderPairSync(
            core: core,
            source: const SyncLocation(
              device: 'source',
              name: 'Laptop A',
              root: 'home',
              path: 'project',
            ),
            target: const SyncLocation(
              device: 'target',
              name: 'VM B',
              root: 'data',
              path: 'copy',
            ),
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Approve and sync now'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Approve and sync now'));
      await tester.pumpAndSettle();
      expect(find.text('Choose the sync connection'), findsNothing);
      expect(find.textContaining('Both folders verified'), findsOneWidget);
      final starts = core.metadata
          .where((request) => request['operation'] == 'start')
          .toList();
      expect(starts, hasLength(2));
      expect(starts[0]['listen'], '192.168.1.10:22001');
      expect(starts[0]['peer_endpoint'], '192.168.1.11:22002');
      expect(starts[1]['listen'], '192.168.1.11:22002');
      expect(starts[1]['peer_endpoint'], '192.168.1.10:22001');
      expect(
        core.calls.any(
          (call) => const {
            'pull',
            'pull-tar',
            'send-file',
            'send-folder',
            'sync-local',
          }.contains(call.first),
        ),
        isFalse,
      );
      expect(core.saved.last['state'], 'verified');
    },
  );

  testWidgets('A draft can retry registration after reopening', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = PairCore()..failTargetRegistration = true;
    Future<void> open([Map<String, dynamic>? saved]) async {
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: FolderPairSync(
            core: core,
            source: const SyncLocation(
              device: 'source',
              name: 'Laptop A',
              root: 'home',
              path: 'project',
            ),
            target: const SyncLocation(
              device: 'target',
              name: 'VM B',
              root: 'data',
              path: 'copy',
            ),
            saved: saved,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> register() async {
      final label = find.text('Register these folders');
      await tester.scrollUntilVisible(
        label,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(label);
      await tester.pumpAndSettle();
    }

    await open();
    await register();
    final draft = core.saved.last;
    expect(draft['state'], 'draft');
    expect(draft['configured'], false);
    expect(draft['source_registered'], true);
    expect(draft['target_registered'], true);

    core.failTargetRegistration = false;
    await open(draft);
    await register();
    expect(core.saved.last['group'], draft['group']);
    expect(core.saved.last['state'], 'paused');
    expect(core.saved.last['configured'], true);
  });

  testWidgets(
    'Recycle Bin root keeps non-sync actions usable without native sync',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: FileManager(core: BadgeCore())),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Phone storage').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recycle Bin').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('file-pane-0-actions')));
      await tester.pumpAndSettle();
      expect(find.text('Empty Recycle Bin'), findsOneWidget);
      expect(find.text('Sync this folder'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('file-pane-1-actions')));
      await tester.pumpAndSettle();
      expect(find.text('Sync this folder'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('File actions').first);
      await tester.pumpAndSettle();
      expect(find.text('Sync folder…'), findsNothing);
      expect(find.text('Restore'), findsOneWidget);
      expect(find.text('Delete permanently'), findsOneWidget);
    },
  );

  testWidgets(
    'Synced folders keep a badge and only folders offer sync actions',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = BadgeCore();
      Future<void> reopen() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FileManager(key: UniqueKey(), core: core, embedded: true),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await reopen();
      expect(find.byTooltip('Synced folder · paused'), findsNWidgets(2));
      await tester.tap(find.byTooltip('File actions').first);
      await tester.pumpAndSettle();
      expect(find.text('Sync folder…'), findsOneWidget);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('File actions').at(1));
      await tester.pumpAndSettle();
      expect(find.text('Sync folder…'), findsNothing);
      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      await reopen();
      expect(find.byTooltip('Synced folder · paused'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Exclusions are sent to both endpoint registrations', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = PairCore();
    await tester.pumpWidget(
      MaterialApp(
        home: FolderPairSync(
          core: core,
          source: const SyncLocation(
            device: 'source',
            name: 'Laptop A',
            root: 'home',
            path: 'project',
          ),
          target: const SyncLocation(
            device: 'target',
            name: 'VM B',
            root: 'data',
            path: 'copy',
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byType(TextField),
      'build\n.dart_tool, ephemeral/.plugin_symlinks',
    );
    await tester.scrollUntilVisible(
      find.text('Register these folders'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Register these folders'));
    await tester.pumpAndSettle();
    final registers = core.metadata
        .where((request) => request['operation'] == 'register')
        .toList();
    expect(registers, hasLength(2));
    for (final request in registers) {
      expect(request['excludes'], [
        'build',
        '.dart_tool',
        'ephemeral/.plugin_symlinks',
      ]);
    }
    expect(core.saved.last['excludes'], [
      'build',
      '.dart_tool',
      'ephemeral/.plugin_symlinks',
    ]);
  });

  testWidgets(
    'Connection row opens Device Overview; back leaves sync untouched',
    (tester) async {
      final core = PairCore();
      await tester.pumpWidget(
        MaterialApp(
          home: FolderPairSync(
            core: core,
            source: const SyncLocation(
              device: 'source',
              name: 'Laptop A',
              root: 'home',
              path: 'project',
            ),
            target: const SyncLocation(
              device: 'target',
              name: 'VM B',
              root: 'data',
              path: 'copy',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Connection'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Connection'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // Reuses Device Overview for route selection.
      expect(find.byType(DeviceDetail), findsOneWidget);
      expect(find.text('Current connection'), findsOneWidget);
      expect(find.text('Choose the sync connection'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        core.metadata.where((request) => request['operation'] == 'start'),
        isEmpty,
      );
    },
  );

  testWidgets('A Wi-Fi Direct connection is honored for the sync', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = DirectPairCore();
    await tester.pumpWidget(
      MaterialApp(
        home: FolderPairSync(
          core: core,
          source: const SyncLocation(
            device: 'source',
            name: 'Laptop A',
            root: 'home',
            path: 'project',
          ),
          target: const SyncLocation(
            device: 'target',
            name: 'VM B',
            root: 'data',
            path: 'copy',
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Approve and sync now'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Approve and sync now'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Both folders verified'), findsOneWidget);
    final starts = core.metadata
        .where((request) => request['operation'] == 'start')
        .toList();
    expect(starts[0]['listen'], '192.168.49.10:22001');
    expect(starts[0]['peer_endpoint'], '192.168.49.11:22002');
  });
}

class DirectPairCore extends PairCore {
  @override
  Future<dynamic> run(List<String> args, {String? input}) async {
    if (args.first == 'connection') {
      return {
        'transport': 'lan',
        'active_link': 'wifi_direct',
        'endpoint': args[1] == 'source'
            ? '192.168.49.10:8731'
            : '192.168.49.11:8731',
      };
    }
    if (args.first == 'sync-control') {
      final request = Map<String, dynamic>.from(jsonDecode(input!) as Map);
      if (request['operation'] == 'prepare') {
        calls.add(args);
        metadata.add({'device': args[1], ...request});
        return {
          'installed': true,
          'prepared': true,
          'device_id': args[1] == 'source' ? 'SOURCE-ENGINE' : 'TARGET-ENGINE',
          'networks': [
            {
              'interface': 'p2p-wlan0-0',
              'cidr': args[1] == 'source'
                  ? '192.168.49.10/24'
                  : '192.168.49.11/24',
              'kind': 'lan',
            },
          ],
        };
      }
    }
    return super.run(args, input: input);
  }
}
