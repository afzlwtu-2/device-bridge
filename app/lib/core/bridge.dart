import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

abstract interface class CoreBridge {
  Future<void> initialize();
  Future<dynamic> run(List<String> arguments, {String? input});
  Future<List<Map<String, dynamic>>> networks();
  Future<void> approveNetwork(Map<String, dynamic> network);
  Future<void> cancel();
  Future<String?> saveDownload(String path);
  String get downloads;
  String get homeDir;
  Map<String, dynamic>? get network;
  Stream<Map<String, dynamic>> get networkEvents;
  Stream<Map<String, dynamic>> get transferProgress;
  Future<void> enableTailnet(bool enabled);
  Future<void> openLogin(String url);
  Future<void> openConnectionSetup(String kind);
  Future<Map<String, dynamic>> platformCapabilities();
  Future<Map<String, dynamic>?> pickTargetTree({bool termux = false});
  Future<Map<String, dynamic>> listTargetTree(String uri, {String? documentId});
  Future<String?> createTargetFolder(
    String uri,
    String name, {
    String? documentId,
  });
  Future<void> exportToTargetTree(
    String localPath,
    String uri, {
    String? documentId,
  });
  Future<void> shutdown();
}

/// Flutter never handles private keys or implements the network protocol.
class LocalCore implements CoreBridge {
  static const channel = MethodChannel('dev.devicebridge/core');
  late String _state;
  late String _binary;
  Process? _active;
  Process? _tailnetProcess;
  Map<String, dynamic>? _network;
  static const networkChannel = EventChannel('dev.devicebridge/network');
  static const transferChannel = EventChannel('dev.devicebridge/transfer');
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _progress = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _nativeEvents;
  StreamSubscription<dynamic>? _nativeProgress;
  @override
  Stream<Map<String, dynamic>> get networkEvents => _events.stream;
  @override
  Stream<Map<String, dynamic>> get transferProgress => _progress.stream;

  @override
  Future<void> enableTailnet(bool enabled) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('tailnetEnable', {'enabled': enabled});
      return;
    }
    if (!enabled) {
      _tailnetProcess?.kill(ProcessSignal.sigterm);
      _tailnetProcess = null;
      return;
    }
    try {
      final status = await run(['tailnet', 'status']) as Map;
      if (status['mode'] == 'system' && status['state'] == 'Running') {
        return;
      }
    } catch (_) {
      /* no daemon available; opt-in fallback below */
    }
    if (_tailnetProcess != null) {
      return;
    }
    final binary =
        '${File(Platform.resolvedExecutable).parent.path}/bridge-tailnet';
    _tailnetProcess = await Process.start(binary, [
      '--state',
      '$_state/tailnet',
      '--name',
      'devicebridge-desktop',
    ], runInShell: false);
    _tailnetProcess!.stdout.drain<void>();
    _tailnetProcess!.stderr.drain<void>();
  }

  @override
  Future<void> openLogin(String url) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' || uri.host != 'login.tailscale.com') {
      throw StateError('Invalid Tailscale login page');
    }
    if (Platform.isAndroid) {
      await channel.invokeMethod('openLogin', {'url': url});
    } else {
      await Process.start('xdg-open', [url], runInShell: false);
    }
  }

  @override
  Future<void> openConnectionSetup(String kind) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('connectionSetup', {'kind': kind});
    } else {
      throw UnsupportedError(
        'Use your desktop network settings to configure $kind, then refresh Connections.',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> platformCapabilities() async {
    if (Platform.isAndroid) {
      return Map<String, dynamic>.from(
        await channel.invokeMethod('platformCapabilities') as Map,
      );
    }
    final adb = await Process.run('which', ['adb'], runInShell: false);
    final ssh = await Process.run('which', ['ssh'], runInShell: false);
    return {
      'wifi_direct': false,
      'adb_enabled': adb.exitCode == 0,
      'ssh_available': ssh.exitCode == 0,
      'termux_installed': false,
    };
  }

  @override
  Future<Map<String, dynamic>?> pickTargetTree({bool termux = false}) async {
    if (!Platform.isAndroid) {
      return {'uri': homeDir, 'name': 'Home', 'kind': 'posix'};
    }
    final res = await channel.invokeMethod<Map>('pickTargetTree', {
      'termux': termux,
    });
    return res == null ? null : Map<String, dynamic>.from(res);
  }

  @override
  Future<Map<String, dynamic>> listTargetTree(
    String uri, {
    String? documentId,
  }) async {
    final res = await channel.invokeMethod<Map>('listTargetTree', {
      'uri': uri,
      'document_id': documentId,
    });
    return Map<String, dynamic>.from(res!);
  }

  @override
  Future<String?> createTargetFolder(
    String uri,
    String name, {
    String? documentId,
  }) async {
    return channel.invokeMethod<String>('createTargetFolder', {
      'uri': uri,
      'name': name,
      'document_id': documentId,
    });
  }

  @override
  Future<void> exportToTargetTree(
    String localPath,
    String uri, {
    String? documentId,
  }) async {
    await channel.invokeMethod('exportToTargetTree', {
      'path': localPath,
      'uri': uri,
      'document_id': documentId,
    });
  }

  @override
  Future<void> shutdown() async {
    _tailnetProcess?.kill(ProcessSignal.sigterm);
    await _nativeEvents?.cancel();
    await _nativeProgress?.cancel();
  }

  @override
  Map<String, dynamic>? get network => _network;
  @override
  String get downloads => '$_state/downloads';
  @override
  String get homeDir => Platform.environment['HOME'] ?? downloads;

  @override
  Future<void> initialize() async {
    if (Platform.isAndroid) {
      final config = Map<String, dynamic>.from(
        await channel.invokeMethod('configuration') as Map,
      );
      _state = config['state'] as String;
      _binary = config['binary'] as String;
    } else {
      final parent = File(Platform.resolvedExecutable).parent.path;
      _binary =
          Platform.environment['DEVICEBRIDGE_CORE'] ?? '$parent/bridge-cli';
      _state =
          Platform.environment['DEVICEBRIDGE_STATE'] ??
          '${Platform.environment['HOME']}/.local/share/devicebridge';
    }
    await run([
      'init',
      Platform.isAndroid ? 'Android phone' : Platform.localHostname,
    ]);
    await Directory(downloads).create(recursive: true);
    // The export alone grants no access. Incoming pairing approval separately
    // lets the owner select this narrowly scoped app download directory.
    await run(['export', 'downloads', downloads]);
    final settings = File('$_state/network.json');
    if (await settings.exists()) {
      _network = Map<String, dynamic>.from(
        jsonDecode(await settings.readAsString()) as Map,
      );
    }
    if (Platform.isAndroid) {
      _nativeEvents ??= networkChannel.receiveBroadcastStream().listen((value) {
        final event = Map<String, dynamic>.from(value as Map);
        final updated = event['network'];
        if (updated is Map) {
          _network = Map<String, dynamic>.from(updated);
        } else if (event['state'] == 'offline' ||
            event['state'] == 'approval_required') {
          _network = null;
        }
        _events.add(event);
      });
      await channel.invokeMethod('activateLan', {'network': _network});
      _nativeProgress ??= transferChannel.receiveBroadcastStream().listen((
        value,
      ) {
        _progress.add(Map<String, dynamic>.from(value as Map));
      });
    }
  }

  @override
  Future<void> approveNetwork(Map<String, dynamic> network) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('approveLan', {'network': network});
    }
    _network = Map<String, dynamic>.from(network);
    await File(
      '$_state/network.json',
    ).writeAsString(jsonEncode(_network), flush: true);
  }

  @override
  Future<List<Map<String, dynamic>>> networks() async {
    final dynamic values = Platform.isAndroid
        ? await channel.invokeMethod('networks')
        : await run(['networks']);
    return (values as List)
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
  }

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    final args = ['--state', _state];
    if (_network != null) {
      args.addAll([
        '--interface',
        _network!['interface'] as String,
        '--lan-cidr',
        _network!['cidr'] as String,
      ]);
    }
    const deviceOperations = {
      'resolve',
      'roots',
      'list',
      'stat',
      'pull',
      'pull-tar',
    };
    if (deviceOperations.contains(arguments.first) && arguments.length > 1) {
      final connection = await run(['connection', arguments[1]]) as Map;
      final transport = connection['transport'] as String? ?? 'lan';
      if (transport == 'tailnet') {
        args.addAll([
          '--transport',
          'tailnet',
          '--endpoint',
          connection['endpoint'] as String,
          '--approve-remote',
        ]);
      } else if (transport == 'adb' || transport == 'ssh') {
        args.addAll([
          '--transport',
          transport,
          '--endpoint',
          connection['endpoint'] as String,
        ]);
      }
      if (connection['fallback_approved'] == true) {
        args.add('--allow-route-fallback');
      }
    }
    args.addAll(arguments);
    if (Platform.isAndroid) {
      final result = await channel.invokeMethod<String>('execute', {
        'arguments': args,
        'input': input ?? '',
        'transfer': arguments.first == 'pull' || arguments.first == 'pull-tar',
      });
      return jsonDecode(result!);
    }
    if (_active != null) {
      throw StateError('Another operation is active');
    }
    final process = await Process.start(_binary, args, runInShell: false);
    _active = process;
    try {
      if (input != null) {
        process.stdin.write(input);
      }
      await process.stdin.close();
      final stdout = process.stdout.transform(utf8.decoder).join();
      final errLines = <String>[];
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('{')) {
              try {
                final obj = Map<String, dynamic>.from(jsonDecode(line) as Map);
                if (obj.containsKey('verified_bytes') ||
                    obj['route_switched'] == true) {
                  _progress.add(obj);
                  return;
                }
              } catch (_) {
                /* keep raw line */
              }
            }
            errLines.add(line);
          })
          .asFuture<void>();
      final code = await process.exitCode;
      final out = await stdout;
      await stderrDone;
      final err = errLines.join('\n');
      if (code != 0) {
        String message = err;
        try {
          message =
              (jsonDecode(err.trim().split('\n').last) as Map)['message']
                  as String;
        } catch (_) {
          /* non-JSON core error */
        }
        throw StateError(message);
      }
      return jsonDecode(out);
    } finally {
      _active = null;
    }
  }

  @override
  Future<void> cancel() async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('cancel');
    } else {
      _active?.kill(ProcessSignal.sigterm);
    }
  }

  @override
  Future<String?> saveDownload(String path) async {
    if (!Platform.isAndroid) {
      return path;
    }
    return channel.invokeMethod<String>('saveDownload', {'path': path});
  }
}
