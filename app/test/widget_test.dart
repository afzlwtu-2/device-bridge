import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:devicebridge/main.dart';
import 'package:devicebridge/core/bridge.dart';
import 'package:devicebridge/features/phone_files.dart';
import 'package:devicebridge/features/folder_exclusions.dart';

class FakeCore implements CoreBridge {
  @override
  Future<dynamic> localFiles(
    String operation,
    Map<String, dynamic> arguments,
  ) async => operation == 'roots'
      ? [
          {'id': 'internal', 'name': 'Internal storage', 'available': true},
          {'id': 'saf', 'name': 'SAF', 'available': false},
          {'id': 'termux', 'name': 'Termux Home', 'available': false},
        ]
      : {'entries': []};
  final _progressController =
      StreamController<Map<String, dynamic>>.broadcast();
  @override
  Future<void> enableTailnet(bool enabled) async {}
  @override
  Future<void> openLogin(String url) async {}
  @override
  Future<void> openConnectionSetup(String kind) async {}
  @override
  Future<Map<String, dynamic>> platformCapabilities() async => {
    'wifi_direct': true,
    'adb_enabled': true,
    'termux_installed': true,
  };
  @override
  Future<Map<String, dynamic>?> pickTargetTree({bool termux = false}) async => {
    'uri': 'content://mock/tree',
    'name': termux ? 'TermuxHome' : 'PickedFolder',
    'kind': termux ? 'termux' : 'saf',
  };
  @override
  Future<Map<String, dynamic>> listTargetTree(
    String uri, {
    String? documentId,
  }) async => {'entries': []};
  @override
  Future<String?> createTargetFolder(
    String uri,
    String name, {
    String? documentId,
  }) async => null;
  @override
  Future<void> exportToTargetTree(
    String localPath,
    String uri, {
    String? documentId,
  }) async {}
  @override
  Future<void> shutdown() async {
    await _progressController.close();
  }

  @override
  Stream<Map<String, dynamic>> get networkEvents => const Stream.empty();
  @override
  Stream<Map<String, dynamic>> get transferProgress =>
      _progressController.stream;
  void emitProgress(Map<String, dynamic> p) => _progressController.add(p);
  final settings = <String, dynamic>{
    'android': true,
    'keep_awake': true,
    'show_hidden': false,
    'root_enabled': false,
    'root_status': 'Not requested',
    'shizuku_enabled': false,
    'shizuku_running': false,
    'shizuku_status': 'Service not running',
  };
  @override
  Future<Map<String, dynamic>> appSettings({
    Map<String, dynamic>? update,
  }) async {
    if (update != null) settings.addAll(update);
    return Map.of(settings);
  }

  final calls = <List<String>>[];
  @override
  String get downloads => '/private/downloads';
  @override
  String get homeDir => '/private/home';
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
      'wireguard' => {
        'backend': 'userspace',
        'public_key': 'mockWGPubKey==',
        'local_tunnel_ip': '10.77.0.2/24',
        'listen_port': 51820,
        'peers': [],
      },
      'ssh-probe' => {
        'host': arguments[1],
        'port': 22,
        'host_key_sha256': 'SHA256:mockhostkey',
        'key_type': 'ssh-ed25519',
      },
      'tailnet' => {'mode': 'app', 'state': 'Stopped', 'ips': []},
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
          {
            'name': '.secret-dotfile',
            'path': '.secret-dotfile',
            'kind': 'file',
            'size': 8,
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
      'remove' => {'status': 'removed'},
      _ => throw StateError('Unexpected command $arguments'),
    };
  }
}

void main() {
  testWidgets(
    'Global settings contains access controls without module preferences',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = FakeCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Your device. Your rules.'), findsOneWidget);
      expect(find.text('Show hidden files by default'), findsNothing);
      expect(find.text('Recover on unmetered Wi-Fi'), findsNothing);
      expect(find.text('Laptop'), findsNothing);
      await tester.scrollUntilVisible(find.text('Root access'), 250);
      expect(find.text('Shizuku access'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Keep screen awake'), 250);
      await tester.tap(find.text('Keep screen awake'));
      await tester.pumpAndSettle();
      expect(core.settings['keep_awake'], isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Matte background stays visible during device route push and pop',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: DeviceBridgeApp(core: FakeCore()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Matte paper'));
      await tester.pumpAndSettle();
      Future<void> checkPaper() async {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final pixels = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          // Margin outside route cards, halfway down the screen.
          final offset = (400 * image.width + 2) * 4;
          expect(pixels.getUint8(offset), lessThan(200));
          expect(pixels.getUint8(offset + 1), lessThan(200));
          image.dispose();
        });
      }

      await tester.ensureVisible(find.text('Laptop'));
      await tester.tap(find.text('Laptop'));
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await checkPaper();
      }
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pump();
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        await checkPaper();
      }
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'Same phone can occupy both file-manager panes with three storage providers',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: PhoneFiles(core: FakeCore())));
      await tester.pumpAndSettle();
      expect(find.text('This phone'), findsNWidgets(2));
      await tester.tap(find.text('Internal storage').first);
      await tester.pumpAndSettle();
      expect(find.text('SAF · grant access'), findsWidgets);
      expect(find.text('Termux Home · grant access'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Exclusions select a subtree without scanning its contents', (
    tester,
  ) async {
    var scans = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<List<String>>(
              context: context,
              builder: (_) => FolderExclusions(
                load: (path) async {
                  scans++;
                  return [
                    {'name': 'cache', 'kind': 'directory', 'size': 0},
                    {'name': 'keep.txt', 'kind': 'file', 'size': 7},
                  ];
                },
              ),
            ),
            child: const Text('Choose exclusions'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose exclusions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('cache'));
    await tester.pumpAndSettle();
    expect(scans, 1);
    expect(find.text('1 excluded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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

  testWidgets(
    'Four primary areas, dual-pane browser, hidden files toggle and pull',
    (tester) async {
      final core = FakeCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Tailscale connectivity'), findsNothing);
      expect(find.byTooltip('Connections'), findsOneWidget);
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
      expect(find.text('Remove device'), findsOneWidget);
      await tester.tap(find.text('Approved'));
      await tester.pumpAndSettle();
      expect(find.text('hello.txt'), findsOneWidget);
      expect(find.text('.secret-dotfile'), findsNothing);
      expect(find.text('Termux Storage'), findsOneWidget);
      await tester.tap(find.byTooltip('Show hidden files'));
      await tester.pumpAndSettle();
      expect(find.text('.secret-dotfile'), findsOneWidget);
      await tester.tap(find.byTooltip('Hide hidden files'));
      await tester.pumpAndSettle();
      expect(find.text('.secret-dotfile'), findsNothing);

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
      expect(core.calls.where((c) => c.first == 'pull').last, [
        'pull',
        'laptop',
        'approved',
        'hello.txt',
        '/private/downloads/hello.txt',
      ]);
      expect(
        find.textContaining('Verified download (streaming tar)'),
        findsOneWidget,
      );
      expect(find.textContaining('42.50 MiB/s'), findsOneWidget);
    },
  );

  testWidgets('Connections hub shows all transports under Wi-Fi icon', (
    tester,
  ) async {
    final core = FakeCore();
    await tester.pumpWidget(DeviceBridgeApp(core: core));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Connections'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi LAN'), findsOneWidget);
    expect(find.text('Hotspot & Wi-Fi Direct'), findsOneWidget);
    expect(find.text('Recover on unmetered Wi-Fi'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Tailscale (tsnet / system)'),
      200,
    );
    expect(find.text('Tailscale (tsnet / system)'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('USB / Wireless ADB'), 200);
    expect(find.text('USB / Wireless ADB'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('SSH & Termux Bridge'), 200);
    expect(find.text('SSH & Termux Bridge'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('WireGuard (Userspace / Kernel)'),
      200,
    );
    expect(find.text('WireGuard (Userspace / Kernel)'), findsOneWidget);
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

  testWidgets(
    'MT Manager side-by-side panes, method switch, and interrupted connection resume',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final core = _InterruptibleCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approved'));
      await tester.pumpAndSettle();

      // Side-by-side Source and Target panes share vertical row even in 390dp portrait
      final srcBox = tester.getRect(find.textContaining('Source · Laptop'));
      final dstBox = tester.getRect(find.textContaining('Target · Downloads'));
      expect((srcBox.top - dstBox.top).abs() < 20, isTrue);
      expect(srcBox.left < dstBox.left, isTrue);
      expect(find.textContaining('Wi-Fi LAN'), findsWidgets);

      // Force TAR selection works
      await tester.tap(find.text('Force TAR'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.download_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Pull'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Connection interrupted pulling "hello.txt"'),
        findsOneWidget,
      );
      expect(find.text('Continue on USB / Wireless ADB'), findsOneWidget);

      // Continue interrupted transfer over USB / Wireless ADB
      core.failPull = false;
      await tester.tap(find.text('Continue on USB / Wireless ADB'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Verified download (direct)'), findsOneWidget);
      expect(find.textContaining('Via USB / Wireless ADB'), findsOneWidget);
    },
  );
}

class _InterruptibleCore extends FakeCore {
  bool failPull = true;
  String activeTransport = 'lan';

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    calls.add(arguments);
    if (arguments.first == 'connection' &&
        arguments.length > 2 &&
        arguments[2] == '-') {
      activeTransport = 'adb';
      return {'transport': 'adb', 'adb_endpoint': '127.0.0.1:8731'};
    }
    if (arguments.first == 'connection') {
      return {
        'transport': activeTransport,
        if (activeTransport == 'adb') 'adb_endpoint': '127.0.0.1:8731',
      };
    }
    if (arguments.first == 'resolve') {
      return {
        'transport': activeTransport == 'adb' ? 'adb' : 'direct-lan-v1',
        'endpoint': activeTransport == 'adb'
            ? '127.0.0.1:8731'
            : '192.168.50.3:8731',
        'interface': 'test0',
        'rtt': 1000000,
        'mib_per_second': 18.2,
      };
    }
    if (arguments.first == 'pull' || arguments.first == 'pull-tar') {
      if (failPull) {
        throw StateError('connection reset by peer');
      }
      return {
        'destination': '/private/downloads/hello.txt',
        'mode': 'chunked',
        'transport': activeTransport,
        'mib_per_second': 18.2,
      };
    }
    return super.run(arguments, input: input);
  }
}
