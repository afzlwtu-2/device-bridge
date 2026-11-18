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
  Map<String, dynamic>? get network;
}

/// Flutter never handles private keys or implements the network protocol.
class LocalCore implements CoreBridge {
  static const channel = MethodChannel('dev.devicebridge/core');
  late String _state;
  late String _binary;
  Process? _active;
  Map<String, dynamic>? _network;
  @override
  Map<String, dynamic>? get network => _network;
  @override
  String get downloads => '$_state/downloads';

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
    final settings = File('$_state/network.json');
    if (await settings.exists()) {
      _network = Map<String, dynamic>.from(
        jsonDecode(await settings.readAsString()) as Map,
      );
    }
  }

  @override
  Future<void> approveNetwork(Map<String, dynamic> network) async {
    _network = Map<String, dynamic>.from(network);
    await File('$_state/network.json')
        .writeAsString(jsonEncode(_network), flush: true);
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
    args.addAll(arguments);
    if (Platform.isAndroid) {
      final result = await channel.invokeMethod<String>('execute', {
        'arguments': args,
        'input': input ?? '',
        'transfer': arguments.first == 'pull',
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
      final stderr = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode;
      final out = await stdout;
      final err = await stderr;
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
