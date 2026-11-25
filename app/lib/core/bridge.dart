import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'debug_trace.dart';

abstract interface class CoreBridge {
  Future<void> initialize();
  Future<dynamic> localFiles(String operation, Map<String, dynamic> arguments);
  Future<Map<String, dynamic>> appSettings({Map<String, dynamic>? update});
  Future<dynamic> run(List<String> arguments, {String? input});
  Future<List<Map<String, dynamic>>> networks();
  Future<void> approveNetwork(Map<String, dynamic> network);
  Future<void> cancel();
  Future<void> allowMeteredPull(String approvalId);
  Future<String?> saveDownload(String path);
  Future<Map<String, dynamic>?> pickShareFile({bool directory = false});
  Future<Map<String, dynamic>> sendShareFile(
    String peer,
    Map<String, dynamic> file,
  );
  Future<String?> saveSharedFile(String name);
  String get downloads;
  String get homeDir;
  Map<String, dynamic>? get network;
  Stream<Map<String, dynamic>> get networkEvents;
  Stream<Map<String, dynamic>> get transferProgress;
  Future<void> enableTailnet(bool enabled);
  Future<void> enableWireguard(bool enabled);
  Future<String?> pickConfText();
  Future<List<Map<String, String>>> listSshKeys();
  Future<String?> readSshKey(Map<String, String> keyRef);
  Future<String?> pickSshKeyText();
  Future<void> openLogin(String url);
  Future<void> openConnectionSetup(String kind);
  Future<Map<String, dynamic>> platformCapabilities();
  Future<Map<String, dynamic>> prepareDirectLink(
    String kind, {
    String band = 'auto',
    String? ssid,
    String? passphrase,
    int? channel,
    int? frequencyMhz,
    int? bandwidthMhz,
    String? peerId,
    String? peerEndpoint,
    String? peerKind,
  });
  Future<Map<String, dynamic>> stopDirectLink({bool forget = true});
  Future<Map<String, dynamic>> activeDirectLink();
  Future<List<String>> directLinkNeighbors(String interfaceName);
  Future<Map<String, dynamic>> linkDetails({String interfaceName = ''});
  Future<Map<String, dynamic>?> pickTargetTree();
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
  Future<Map<String, dynamic>> goBinariesStatus();
  Future<Map<String, dynamic>> syncGoBinariesFromAssets();
  Future<Map<String, dynamic>?> pickGoBinaryFile(String role);
  Future<Map<String, dynamic>> revertGoBinaries({String? role});

  /// A display snapshot, including tailnet_status and wireguard_status when available.
  Future<Map<String, dynamic>> runtimeStatus({
    bool includeResources = false,
  }) async => {};
  Future<void> restartAgent() async {}
  Future<GuestTerminalLink> openAgentTerminal(
    Map<String, dynamic> request,
  ) async => throw UnsupportedError('Agent terminal unavailable');
  Future<void> shutdown();
}

class GuestTerminalLink {
  const GuestTerminalLink(this.frames, this.send, this.close);

  final Stream<String> frames;
  final Future<void> Function(Map<String, dynamic> frame) send;
  final Future<void> Function() close;
}

/// The Go core implements the network protocols and verifies remote identity.
class LocalCore implements CoreBridge {
  static const channel = MethodChannel('dev.devicebridge/core');
  static const _guestTerminalChannel = EventChannel(
    'dev.devicebridge/guest_terminal',
  );
  static const _localTerminalChannel = EventChannel(
    'dev.devicebridge/local_terminal',
  );
  late final Stream<String> _localTerminalFrames = _localTerminalChannel
      .receiveBroadcastStream()
      .cast<String>();
  String _state = '';
  String _binary = '';
  String? _androidDeviceName;
  bool _phoneStorageExported = false;
  Process? _active;

  Future<List<String>> detachedLocalTerminals() async {
    if (!Platform.isAndroid) return const [];
    return await channel.invokeListMethod<String>('detachedLocalTerminals') ??
        const [];
  }

  Future<GuestTerminalLink> openLocalTerminal(
    Map<String, dynamic> request,
  ) async {
    final controller = StreamController<String>();
    final sessionId =
        (request['session_id'] as String?) ??
        'session-${DateTime.now().microsecondsSinceEpoch}';
    if (Platform.isAndroid) {
      final subscription = _localTerminalFrames.listen((raw) {
        try {
          final parsed = jsonDecode(raw) as Map;
          final sid = parsed['session_id'] as String?;
          if (sid == null || sid == sessionId) {
            controller.add(raw);
          }
        } catch (_) {
          controller.add(raw);
        }
      }, onError: controller.addError);
      try {
        await channel.invokeMethod<void>('localTerminalStart', {
          'session_id': sessionId,
          'frame': jsonEncode(request),
        });
      } catch (_) {
        await subscription.cancel();
        unawaited(controller.close());
        rethrow;
      }
      return GuestTerminalLink(
        controller.stream,
        (frame) => channel.invokeMethod<void>('localTerminalWrite', {
          'session_id': sessionId,
          'frame': jsonEncode(frame),
        }),
        () async {
          await channel.invokeMethod<void>('localTerminalStop', {
            'session_id': sessionId,
          });
          await subscription.cancel();
          unawaited(controller.close());
        },
      );
    }
    final child = await Process.start(_binary, [
      '--state',
      _state,
      'local-terminal',
      '-',
    ]);
    final err = child.stderr.transform(utf8.decoder).join();
    final output = child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(controller.add, onError: controller.addError)
        .asFuture<void>();
    unawaited(
      () async {
        final code = await child.exitCode;
        await output;
        final diagnostic = await err;
        if (!controller.isClosed) {
          controller.add(
            jsonEncode({
              'state': 'closed',
              if (code != 0) 'error': diagnostic.trim(),
            }),
          );
          unawaited(controller.close());
        }
      }().catchError((Object error) {
        if (!controller.isClosed) controller.addError(error);
      }),
    );
    child.stdin.writeln(jsonEncode(request));
    await child.stdin.flush();
    var pending = Future<void>.value();
    return GuestTerminalLink(
      controller.stream,
      (frame) {
        pending = pending.then((_) async {
          child.stdin.writeln(jsonEncode(frame));
          await child.stdin.flush();
        });
        return pending;
      },
      () async {
        child.kill(ProcessSignal.sigterm);
        await child.stdin.close();
      },
    );
  }

  Future<GuestTerminalLink> openGuestTerminal(Map<String, dynamic> request) =>
      _openChannelTerminal('guest-terminal', request);

  @override
  Future<GuestTerminalLink> openAgentTerminal(Map<String, dynamic> request) {
    final extraArgs = <String>[
      if (const {
        'hotspot',
        'wifi_direct',
        'wifi_join',
      }.contains(_network?['kind']))
        '--manual-lan-context',
      if (_network != null) ...[
        '--interface',
        _network!['interface'] as String,
        '--lan-cidr',
        _network!['cidr'] as String,
      ],
    ];
    return _openChannelTerminal(
      'agent-terminal',
      request,
      extraArgs: extraArgs,
    );
  }

  Future<GuestTerminalLink> _openChannelTerminal(
    String subcommand,
    Map<String, dynamic> request, {
    List<String> extraArgs = const [],
  }) async {
    final controller = StreamController<String>();
    if (Platform.isAndroid) {
      final source = _guestTerminalChannel
          .receiveBroadcastStream()
          .cast<String>();
      final subscription = source.listen(
        controller.add,
        onError: controller.addError,
      );
      try {
        await channel.invokeMethod<void>('guestTerminalStart', {
          'subcommand': subcommand,
          'args': extraArgs,
          'frame': jsonEncode(request),
        });
      } catch (_) {
        await subscription.cancel();
        unawaited(controller.close());
        rethrow;
      }
      return GuestTerminalLink(
        controller.stream,
        (frame) => channel.invokeMethod<void>('guestTerminalWrite', {
          'frame': jsonEncode(frame),
        }),
        () async {
          await channel.invokeMethod<void>('guestTerminalStop');
          await subscription.cancel();
          unawaited(controller.close());
        },
      );
    }
    final child = await Process.start(_binary, [
      '--state',
      _state,
      ...extraArgs,
      subcommand,
      '-',
    ]);
    final err = child.stderr.transform(utf8.decoder).join();
    final output = child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(controller.add, onError: controller.addError)
        .asFuture<void>();
    unawaited(
      () async {
        final code = await child.exitCode;
        await output;
        final diagnostic = await err;
        if (!controller.isClosed) {
          controller.add(
            jsonEncode({
              'state': 'closed',
              if (code != 0) 'error': diagnostic.trim(),
            }),
          );
          unawaited(controller.close());
        }
      }().catchError((Object error) {
        if (!controller.isClosed) controller.addError(error);
      }),
    );
    child.stdin.writeln(jsonEncode(request));
    await child.stdin.flush();
    var pending = Future<void>.value();
    return GuestTerminalLink(
      controller.stream,
      (frame) {
        pending = pending.then((_) async {
          child.stdin.writeln(jsonEncode(frame));
          await child.stdin.flush();
        });
        return pending;
      },
      () async {
        child.kill(ProcessSignal.sigterm);
        await child.stdin.close();
      },
    );
  }

  Process? _tailnetProcess;
  Process? _wgProcess;
  Map<String, dynamic>? _network;
  static const networkChannel = EventChannel('dev.devicebridge/network');
  static const transferChannel = EventChannel('dev.devicebridge/transfer');
  static const _sharedDraftChannel = EventChannel(
    'dev.devicebridge/shared_draft',
  );
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _progress = StreamController<Map<String, dynamic>>.broadcast();
  StreamSubscription<dynamic>? _nativeEvents;
  StreamSubscription<dynamic>? _nativeProgress;
  @override
  Stream<Map<String, dynamic>> get networkEvents => _events.stream;
  @override
  Stream<Map<String, dynamic>> get transferProgress => _progress.stream;

  Stream<void> get sharedDraftEvents => Platform.isAndroid
      ? _sharedDraftChannel.receiveBroadcastStream().map<void>((_) {})
      : const Stream.empty();

  Future<Map<String, dynamic>?> takeSharedDraft() async {
    if (!Platform.isAndroid) return null;
    final draft = await channel.invokeMethod<Map>('takeSharedDraft');
    return draft == null ? null : Map<String, dynamic>.from(draft);
  }

  @override
  Future<Map<String, dynamic>?> pickShareFile({bool directory = false}) async {
    if (Platform.isAndroid) {
      final file = await channel.invokeMethod<Map>('pickShareFile', {
        'directory': directory,
      });
      return file == null ? null : Map<String, dynamic>.from(file);
    }
    final kind = directory ? 'folder' : 'file';
    final selected = await Process.run('zenity', [
      '--file-selection',
      if (directory) '--directory',
      '--title=Choose a $kind to send',
    ]);
    if (selected.exitCode == 1) return null;
    if (selected.exitCode != 0) {
      throw StateError('Could not open the system file picker.');
    }
    final path = (selected.stdout as String).replaceFirst(RegExp(r'\n$'), '');
    if (path.isEmpty) return null;
    if (directory) {
      final folder = Directory(path);
      return {
        'path': path,
        'name':
            folder.uri.pathSegments
                .where((part) => part.isNotEmpty)
                .lastOrNull ??
            path,
        'directory': true,
      };
    }
    final file = File(path);
    return {
      'path': path,
      'name': file.uri.pathSegments.last,
      'size': await file.length(),
    };
  }

  @override
  Future<Map<String, dynamic>> sendShareFile(
    String peer,
    Map<String, dynamic> file,
  ) async {
    final directory = file['directory'] == true;
    String? staged;
    try {
      if (Platform.isAndroid) {
        staged = await channel.invokeMethod<String>('stageShareFile', {
          'uri': file['uri'],
          'directory': directory,
        });
        if (staged == null) throw StateError('Cannot open the selected file.');
      }
      final path = staged ?? file['path'] as String;
      return Map<String, dynamic>.from(
        await run([directory ? 'send-folder' : 'send-file', peer, path]) as Map,
      );
    } finally {
      if (staged != null) {
        try {
          await File(staged).parent.delete(recursive: true);
        } on FileSystemException {
          // Android can reclaim the app-private cache.
        }
      }
    }
  }

  @override
  Future<String?> saveSharedFile(String name) async {
    if (Platform.isAndroid) {
      return channel.invokeMethod<String>('saveSharedFile', {'name': name});
    }
    final inbox = '$_state/shared-files';
    final result = await Process.run('xdg-open', [inbox]);
    if (result.exitCode != 0) {
      throw StateError('The file manager could not open the inbox.');
    }
    return null;
  }

  @override
  Future<dynamic> localFiles(
    String operation,
    Map<String, dynamic> arguments,
  ) async {
    if (Platform.isLinux) {
      final result = await run([
        'local-files',
        operation,
      ], input: jsonEncode(arguments));
      if (operation == 'open') {
        await Process.start('xdg-open', [
          (result as Map)['path'] as String,
        ], mode: ProcessStartMode.detached);
        return true;
      }
      return result;
    }
    try {
      return await channel.invokeMethod('localFiles', {
        'operation': operation,
        'arguments': arguments,
      });
    } on PlatformException catch (e) {
      DebugTrace.logError('LocalFiles', '$operation failed', error: e.message);
      rethrow;
    }
  }

  @override
  Future<Map<String, dynamic>> appSettings({
    Map<String, dynamic>? update,
  }) async {
    if (Platform.isAndroid) {
      final res = Map<String, dynamic>.from(
        await channel.invokeMethod(
          update == null ? 'appSettings' : 'updateAppSettings',
          update,
        ) as Map,
      );
      if (res.containsKey('debug_mode')) {
        DebugTrace.setEnabled(res['debug_mode'] != false);
      }
      return res;
    }
    final file = File('$_state/settings.json');
    final values = <String, dynamic>{
      'android': false,
      'show_hidden': false,
      'verbose_logging': true,
      'debug_mode': true,
      'matte_items': '',
      'amoled_config': '',
    };
    if (await file.exists()) {
      values.addAll(
        jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      );
    }
    if (update != null) {
      for (final entry in update.entries) {
        final ok = switch (entry.key) {
          'show_hidden' => entry.value is bool,
          'verbose_logging' => entry.value is bool,
          'debug_mode' => entry.value is bool,
          'matte_items' =>
            entry.value is String && (entry.value as String).length <= 32768,
          'amoled_config' =>
            entry.value is String && (entry.value as String).length <= 8192,
          _ => false,
        };
        if (!ok) {
          throw ArgumentError('Unsupported desktop setting');
        }
      }
      values.addAll(update);
      final staged = File('${file.path}.tmp');
      await staged.writeAsString(jsonEncode(values), flush: true);
      await staged.rename(file.path);
    }
    DebugTrace.setEnabled(values['debug_mode'] != false);
    return values;
  }

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
  Future<void> enableWireguard(bool enabled) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('wireguardEnable', {'enabled': enabled});
      return;
    }
    if (!enabled) {
      _wgProcess?.kill(ProcessSignal.sigterm);
      _wgProcess = null;
      return;
    }
    if (_wgProcess != null) {
      return;
    }
    final binary = '${File(Platform.resolvedExecutable).parent.path}/bridge-wg';
    if (!File(binary).existsSync()) {
      return;
    }
    _wgProcess = await Process.start(binary, [
      '--state',
      _state,
      '--backend',
      'auto',
    ], runInShell: false);
    _wgProcess!.stdout.drain<void>();
    _wgProcess!.stderr.drain<void>();
  }

  @override
  Future<String?> pickConfText() async {
    if (Platform.isAndroid) {
      return channel.invokeMethod<String>('pickConfText');
    }
    return null;
  }

  @override
  Future<List<Map<String, String>>> listSshKeys() async {
    if (Platform.isAndroid) return [];
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return [];
    }
    final sshDir = Directory('$home/.ssh');
    if (!await sshDir.exists()) {
      return [];
    }
    const skip = {
      'known_hosts',
      'known_hosts.old',
      'config',
      'authorized_keys',
      'authorized_keys2',
    };
    final out = <Map<String, String>>[];
    await for (final entity in sshDir.list()) {
      if (entity is! File) {
        continue;
      }
      final name = entity.uri.pathSegments.last;
      if (name.endsWith('.pub') || skip.contains(name)) {
        continue;
      }
      out.add({'name': name, 'path': entity.path});
    }
    out.sort((a, b) {
      final aId = (a['name'] ?? '').startsWith('id_') ? 0 : 1;
      final bId = (b['name'] ?? '').startsWith('id_') ? 0 : 1;
      if (aId != bId) {
        return aId.compareTo(bId);
      }
      return (a['name'] ?? '').compareTo(b['name'] ?? '');
    });
    return out;
  }

  @override
  Future<String?> readSshKey(Map<String, String> keyRef) async {
    if (Platform.isAndroid) return null;
    final p = keyRef['path'];
    if (p == null || p.isEmpty) {
      return null;
    }
    return File(p).readAsString();
  }

  @override
  Future<String?> pickSshKeyText() async {
    if (Platform.isAndroid) {
      return channel.invokeMethod<String>('pickSshKeyText');
    }
    return null;
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
        'Use your desktop network settings to configure $kind, then refresh Networks.',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> platformCapabilities() async {
    if (Platform.isAndroid) {
      final caps = Map<String, dynamic>.from(
        await channel.invokeMethod('platformCapabilities') as Map,
      );
      if (caps['all_files_access'] == true && !_phoneStorageExported) {
        await run(['export', 'phone_storage', '/storage/emulated/0']);
        _phoneStorageExported = true;
        await channel.invokeMethod('refreshExports');
      }
      return caps;
    }
    final ssh = await Process.run('which', ['ssh'], runInShell: false);
    Map<String, dynamic> linkCaps = {};
    try {
      linkCaps = Map<String, dynamic>.from(await run(['link-caps']) as Map);
    } catch (_) {}
    final adbEnabled = linkCaps['usb_adb'] == true;
    return {
      'os': linkCaps['os'] ?? 'linux',
      'wifi_5ghz': linkCaps['wifi_5ghz'] == true,
      'wifi_6': linkCaps['wifi_6'] == true,
      'wifi_6ghz': linkCaps['wifi_6ghz'] == true,
      'wifi_direct': linkCaps['wifi_direct'] == true,
      'hotspot_ap': linkCaps['hotspot_ap'] == true,
      'hotspot_5ghz_ap': linkCaps['hotspot_5ghz_ap'] == true,
      'hotspot_sta': linkCaps['hotspot_sta'] == true,
      if (linkCaps['usable_5ghz_channels'] != null)
        'usable_5ghz_channels': linkCaps['usable_5ghz_channels'],
      if (linkCaps['reg_country'] != null)
        'reg_country': linkCaps['reg_country'],
      'reg_5ghz_limited': linkCaps['reg_5ghz_limited'] == true,
      'can_set_regdom': linkCaps['can_set_regdom'] == true,
      'usb_adb': adbEnabled,
      'usb_adb_connected': adbEnabled,
      'adb_enabled': adbEnabled,
      'ssh_available': ssh.exitCode == 0,
      'termux_installed': false,
      'checked_at_utc':
          linkCaps['checked_at_utc'] ??
          (DateTime.now().millisecondsSinceEpoch ~/ 1000),
    };
  }

  @override
  Future<Map<String, dynamic>> prepareDirectLink(
    String kind, {
    String band = 'auto',
    String? ssid,
    String? passphrase,
    int? channel,
    int? frequencyMhz,
    int? bandwidthMhz,
    String? peerId,
    String? peerEndpoint,
    String? peerKind,
    String? operationId,
    int leaseSeconds = 120,
  }) async {
    if (Platform.isAndroid) {
      final raw = await LocalCore.channel.invokeMethod<Map>(
        'prepareDirectLink',
        {
          'kind': kind,
          'operation_id': ?operationId,
          'lease_seconds': leaseSeconds,
          'band': band,
          if (ssid != null && ssid.isNotEmpty) 'ssid': ssid,
          if (passphrase != null && passphrase.isNotEmpty)
            'passphrase': passphrase,
          if (channel != null && channel > 0) 'channel': channel,
          if (frequencyMhz != null && frequencyMhz > 0)
            'frequency_mhz': frequencyMhz,
          if (bandwidthMhz != null && bandwidthMhz > 0)
            'bandwidth_mhz': bandwidthMhz,
          'peer_id': ?peerId,
          'peer_endpoint': ?peerEndpoint,
          'peer_kind': ?peerKind,
        },
      );
      return raw == null ? {} : Map<String, dynamic>.from(raw);
    }
    return Map<String, dynamic>.from(
      await run(
        [kind == 'wifi_join' ? 'wifi-join' : 'link-host', '-'],
        input: jsonEncode({
          'kind': kind,
          'band': band,
          'operation_id': ?operationId,
          'lease_seconds': leaseSeconds,
          'ssid': ssid ?? '',
          'passphrase': passphrase ?? '',
          'channel': ?channel,
          'frequency_mhz': ?frequencyMhz,
          'bandwidth_mhz': ?bandwidthMhz,
        }),
      ) as Map,
    );
  }

  Future<void> commitLocalLink(String id) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('commitDirectLink', {'operation_id': id});
    } else {
      await run(['link-local-commit', id]);
    }
  }

  @override
  Future<Map<String, dynamic>> stopDirectLink({bool forget = true}) async {
    if (Platform.isAndroid) {
      final raw = await channel.invokeMethod<Map>('stopDirectLink', {
        'forget': forget,
      });
      return raw == null ? {} : Map<String, dynamic>.from(raw);
    }
    return Map<String, dynamic>.from(await run(['wifi-restore']) as Map);
  }

  @override
  Future<Map<String, dynamic>> activeDirectLink() async {
    try {
      if (Platform.isAndroid) {
        final raw = await channel.invokeMethod<Map>('activeDirectLink');
        return raw == null ? {'active': false} : Map<String, dynamic>.from(raw);
      }
      final raw = await run(['link-active']);
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
    } catch (_) {}
    return {'active': false};
  }

  @override
  Future<List<String>> directLinkNeighbors(String interfaceName) async {
    if (Platform.isAndroid) {
      final raw = await channel.invokeMethod<List>('directLinkNeighbors', {
        'interface': interfaceName,
      });
      return (raw ?? const [])
          .map((e) => '$e')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return [];
  }

  @override
  Future<Map<String, dynamic>> linkDetails({String interfaceName = ''}) async {
    if (Platform.isAndroid) {
      final raw = await channel.invokeMethod<Map>('linkDetails', {
        'interface': interfaceName,
      });
      return raw == null ? {} : Map<String, dynamic>.from(raw);
    }
    try {
      final raw = await run([
        'link-details',
        if (interfaceName.isNotEmpty) interfaceName,
      ]);
      if (raw is Map) {
        return Map<String, dynamic>.from(raw);
      }
    } catch (_) {}
    return {};
  }

  @override
  Future<Map<String, dynamic>?> pickTargetTree() async {
    if (!Platform.isAndroid) {
      return {'uri': homeDir, 'name': 'Home', 'kind': 'posix'};
    }
    final res = await channel.invokeMethod<Map>('pickTargetTree');
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
    _wgProcess?.kill(ProcessSignal.sigterm);
    await _nativeEvents?.cancel();
    await _nativeProgress?.cancel();
  }

  @override
  Map<String, dynamic>? get network => _network;
  @override
  String get downloads =>
      _state.isEmpty ? 'Initializing local storage…' : '$_state/downloads';
  @override
  String get homeDir => Platform.environment['HOME'] ?? downloads;

  Future<void> prepare() async {
    if (_state.isNotEmpty) return;
    if (Platform.isAndroid) {
      final config = Map<String, dynamic>.from(
        await channel.invokeMethod('configuration') as Map,
      );
      _state = config['state'] as String;
      _binary = config['binary'] as String;
      _androidDeviceName = config['device_name'] as String?;
    } else {
      final parent = File(Platform.resolvedExecutable).parent.path;
      _binary =
          Platform.environment['DEVICEBRIDGE_CORE'] ?? '$parent/bridge-cli';
      _state =
          Platform.environment['DEVICEBRIDGE_STATE'] ??
          '${Platform.environment['HOME']}/.local/share/devicebridge';
    }
  }

  Future<Map<String, dynamic>> startupSettings() async {
    if (Platform.isAndroid) {
      return Map<String, dynamic>.from(
        await channel.invokeMethod('startupSettings') as Map,
      );
    }
    return appSettings();
  }

  @override
  Future<void> initialize() async {
    await prepare();
    await run([
      'init',
      Platform.isAndroid
          ? (_androidDeviceName?.trim().isNotEmpty == true
                ? _androidDeviceName!.trim()
                : 'Android phone')
          : Platform.localHostname,
    ]);
    unawaited(DebugTrace.configureStateDir(_state));
    await Directory(downloads).create(recursive: true);
    if (!Platform.isAndroid) {
      await Future.wait([
        run(['export', 'downloads', downloads]),
        run(['export', 'home', homeDir]),
        run(['export', 'filesystem', '/']),
      ]);
    } else {
      await Future.wait([
        run(['export', 'downloads', downloads]),
        () async {
          try {
            final caps = await platformCapabilities();
            if (caps['termux_home_path'] case final String termuxHome) {
              await run(['export', 'termux_home', termuxHome]);
            }
            if (caps['all_files_access'] == true &&
                Directory('/storage/emulated/0').existsSync()) {
              await run(['export', 'phone_storage', '/storage/emulated/0']);
            }
          } catch (_) {
            /* all-files access optional until granted by owner */
          }
        }(),
      ]);
      try {
        await run(['ensure-termux-ssh']);
      } catch (error) {
        DebugTrace.logCore('Termux', 'SSH environment refresh failed: $error');
      }
    }
    final settings = File('$_state/network.json');
    if (await settings.exists()) {
      _network = Map<String, dynamic>.from(
        jsonDecode(await settings.readAsString()) as Map,
      );
    }
    if (!Platform.isAndroid && _network != null) {
      try {
        final live = await networks();
        final iface = _network!['interface'];
        final match = live.firstWhere(
          (n) => n['interface'] == iface,
          orElse: () => const {},
        );
        if (match.isNotEmpty && match['cidr'] != _network!['cidr']) {
          _network = Map<String, dynamic>.from(match);
          await settings.writeAsString(jsonEncode(_network), flush: true);
        }
      } catch (_) {}
    }
    if (Platform.isAndroid) {
      _nativeEvents ??= networkChannel.receiveBroadcastStream().listen((value) {
        final event = Map<String, dynamic>.from(value as Map);
        final updated = event['network'];
        if (updated is Map) {
          _network = mergeNetworkEvent(
            _network,
            Map<String, dynamic>.from(updated),
          );
          event['network'] = _network;
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
      // Hot-sync Go core assets in the background so first launch does not stall Home UI.
      unawaited(syncGoBinariesFromAssets(automatic: true));
    }
  }

  /// ConnectivityManager reports a joined peer-hosted group as plain Wi-Fi;
  /// keep the approved direct-link stamp while the same network stays selected
  /// so labels and active_link survive native events.
  static Map<String, dynamic> mergeNetworkEvent(
    Map<String, dynamic>? prev,
    Map<String, dynamic> updated,
  ) {
    final next = Map<String, dynamic>.from(updated);
    if (prev != null &&
        prev['direct'] == true &&
        prev['interface'] == next['interface'] &&
        prev['cidr'] == next['cidr']) {
      next['kind'] = prev['kind'];
      next['direct'] = true;
    }
    return next;
  }

  @override
  Future<void> approveNetwork(Map<String, dynamic> network) async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('approveLan', {'network': network});
    }
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

  String _cliOp(List<String> args) {
    var i = 0;
    while (i < args.length) {
      final a = args[i];
      if (const {
        '--approve-remote',
        '--approve-sync',
        '--allow-route-fallback',
        '--manual-lan-context',
        '--wireguard-tunnel-only',
      }.contains(a)) {
        i += 1;
      } else if (a.startsWith('--')) {
        i += 2;
      } else {
        return a;
      }
    }
    return args.isEmpty ? 'cli' : args.first;
  }

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    final op = _cliOp(arguments);
    final localSyncControl =
        op == 'sync-local' &&
        input != null &&
        const {
          'status',
          'stop',
        }.contains((jsonDecode(input) as Map)['operation']);
    final parallelProbe =
        const {'sync-control', 'local-files'}.contains(op) ||
        localSyncControl ||
        (input == null &&
            (const {
                  'network-policy',
                  'acl',
                  'peer-tags',
                  'acl-group',
                  'peer-ssh-access',
                  'peer-ssh-method',
                  'ssh-hosts',
                  'link-operation',
                  'discover',
                  'peers',
                  'finish',
                  'resolve',
                  'roots',
                  'peer-caps',
                  'networks',
                  'adb-devices',
                  'share-inbox',
                  'share-files',
                  'action-inbox',
                  'agent-actions',
                  'guest-close',
                  'guest-terminal-revoke',
                }.contains(op) ||
                op == 'sync-pairs' ||
                op == 'sync-owner-stop' ||
                (op == 'syncthing' && arguments.last == 'status') ||
                (op == 'connection' && arguments.length == 2) ||
                ((op == 'share-text-access' ||
                        op == 'share-file-access' ||
                        op == 'sync-control-access' ||
                        op == 'sync-remote-access') &&
                    arguments.length == 2) ||
                ((op == 'tailnet' || op == 'wireguard') &&
                    arguments.last == 'status')));
    final args = ['--state', _state];
    if (const {
      'hotspot',
      'wifi_direct',
      'wifi_join',
    }.contains(_network?['kind'])) {
      args.add('--manual-lan-context');
    }
    final explicitTransportIndex = arguments.indexOf('--transport');
    if (explicitTransportIndex >= 0 &&
        explicitTransportIndex + 1 < arguments.length &&
        arguments[explicitTransportIndex + 1] == 'wireguard') {
      args.add('--wireguard-tunnel-only');
    }
    final hasExplicitLan =
        arguments.contains('--interface') || arguments.contains('--lan-cidr');
    final localStatus =
        op == 'networks' ||
        op == 'share-inbox' ||
        ((op == 'tailnet' || op == 'wireguard') && arguments.last == 'status');
    if (_network != null && !hasExplicitLan && !localStatus) {
      args.addAll([
        '--interface',
        _network!['interface'] as String,
        '--lan-cidr',
        _network!['cidr'] as String,
      ]);
    }
    const deviceOperations = {
      'finish',
      'resolve',
      'peer-caps',
      'prepare-link',
      'restore-link',
      'speedtest',
      'send-text',
      'send-file',
      'send-folder',
      'file-push',
      'file-remove',
      'agent-actions',
      'action',
      'sync-control',
      'roots',
      'list',
      'stat',
      'preview',
      'pull',
      'pull-tar',
    };
    if (deviceOperations.contains(arguments.first) && arguments.length > 1) {
      final connection = await run(['connection', arguments[1]]) as Map;
      final transport = connection['transport'] as String? ?? 'lan';
      if (transport == 'tailnet') {
        final ep = (connection['endpoint'] as String? ?? '').isNotEmpty
            ? connection['endpoint'] as String
            : (connection['tailnet_endpoint'] as String? ?? '');
        args.addAll([
          '--transport',
          'tailnet',
          if (ep.isNotEmpty) ...['--endpoint', ep],
          if (connection['remote_approved'] == true) '--approve-remote',
        ]);
      } else if (transport == 'wireguard') {
        final ep = (connection['endpoint'] as String? ?? '').isNotEmpty
            ? connection['endpoint'] as String
            : (connection['wireguard_endpoint'] as String? ?? '');
        args.addAll(['--wireguard-tunnel-only', '--transport', 'wireguard']);
        if (ep.isNotEmpty) {
          args.addAll(['--endpoint', ep]);
        }
        if (connection['remote_approved'] == true) {
          args.add('--approve-remote');
        }
      } else if (transport == 'adb' || transport == 'ssh') {
        final ep = (connection['endpoint'] as String? ?? '').isNotEmpty
            ? connection['endpoint'] as String
            : (transport == 'adb'
                  ? connection['adb_endpoint'] as String? ?? ''
                  : connection['ssh_endpoint'] as String? ?? '');
        args.addAll(['--transport', transport]);
        if (ep.isNotEmpty) {
          args.addAll(['--endpoint', ep]);
        }
      } else if (transport == 'lan' &&
          const {
            'hotspot',
            'wifi_direct',
          }.contains(connection['active_link'])) {
        final endpoint = '${connection['endpoint'] ?? ''}';
        if (endpoint.isNotEmpty) args.addAll(['--endpoint', endpoint]);
      }
      if (connection['fallback_approved'] == true) {
        args.add('--allow-route-fallback');
      }
    }
    args.addAll(arguments);
    final transfer =
        const {
          'pull',
          'pull-tar',
          'send-file',
          'send-folder',
          'guest-pull',
          'file-push',
          'file-remove',
        }.contains(op) ||
        arguments.contains('--approve-sync');
    if (Platform.isAndroid) {
      try {
        final result = await channel.invokeMethod<String>('execute', {
          'arguments': args,
          'input': input ?? '',
          'transfer': transfer,
          'resumablePull': op == 'pull' || op == 'pull-tar',
          'parallelProbe': parallelProbe,
        });
        return jsonDecode(result!);
      } catch (e) {
        if (op == 'finish' &&
            e.toString().contains('remote approval still pending')) {
          rethrow;
        } else if (op == 'resolve' || op == 'discover') {
          DebugTrace.logCore(op, 'CLI probe failed', detail: '$args -> $e');
        } else {
          DebugTrace.logError('LocalCore', '$op failed', error: '$args -> $e');
        }
        rethrow;
      }
    }
    if (!parallelProbe && _active != null) {
      throw StateError('Another operation is active');
    }
    final syncEngine = File(
      '${File(Platform.resolvedExecutable).parent.path}/bridge-sync',
    );
    final process = await Process.start(
      _binary,
      args,
      runInShell: false,
      environment:
          syncEngine.existsSync() &&
              !Platform.environment.containsKey('DEVICEBRIDGE_SYNCTHING_BINARY')
          ? {'DEVICEBRIDGE_SYNCTHING_BINARY': syncEngine.path}
          : null,
    );
    if (!parallelProbe) _active = process;
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
                    obj.containsKey('sent_bytes') ||
                    obj['route_switched'] == true ||
                    obj.containsKey('transfer_state') ||
                    obj['ssh_output'] == true) {
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
        if (op == 'resolve' || op == 'discover') {
          DebugTrace.logCore(op, 'CLI probe failed: $message', detail: '$args');
        } else {
          DebugTrace.logError(
            'LocalCore',
            '$op failed: $message',
            error: '$args',
          );
        }
        throw StateError(message);
      }
      return jsonDecode(out);
    } finally {
      if (!parallelProbe) _active = null;
      if (transfer && !_progress.isClosed) {
        _progress.add({'transfer_state': 'finished'});
      }
    }
  }

  @override
  Future<void> allowMeteredPull(String approvalId) =>
      channel.invokeMethod<void>('allowMeteredPull', {'id': approvalId});

  @override
  Future<void> cancel() async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('cancel');
    } else {
      _active?.kill(ProcessSignal.sigterm);
    }
  }

  @override
  Future<Map<String, dynamic>> goBinariesStatus() async {
    if (Platform.isAndroid) {
      final raw = await channel.invokeMethod<Map>('goBinariesStatus');
      return raw == null ? {} : Map<String, dynamic>.from(raw);
    }
    String version = 'unknown';
    String goVer = '';
    String arch = Platform.operatingSystem;
    try {
      final res = await Process.run(_binary, ['version'], runInShell: false);
      if (res.exitCode == 0) {
        final obj = jsonDecode('${res.stdout}') as Map<String, dynamic>;
        version = '${obj['version'] ?? 'unknown'}';
        goVer = '${obj['go'] ?? ''}';
        arch = '${obj['os'] ?? ''}/${obj['arch'] ?? ''}';
      }
    } catch (_) {}
    return {
      'version': version,
      'go': goVer,
      'arch': arch,
      'hot_count': 0,
      'libraries': [
        {
          'role': 'cli',
          'path': _binary,
          'source': 'bundled',
          'version': version,
          'go': goVer,
          'arch': arch,
          'available': File(_binary).existsSync(),
          'size_bytes': File(_binary).existsSync()
              ? File(_binary).lengthSync()
              : 0,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> syncGoBinariesFromAssets({
    bool automatic = false,
  }) async {
    if (!Platform.isAndroid) {
      return goBinariesStatus();
    }
    const mapping = <String, String>{
      'cli': 'assets/bin/android-arm64-libbridge_cli.gzbin',
      'agent': 'assets/bin/android-arm64-libbridge_agent.gzbin',
      'tailnet': 'assets/bin/android-arm64-libbridge_tailnet.gzbin',
      'wg': 'assets/bin/android-arm64-libbridge_wg.gzbin',
      'sync': 'assets/bin/android-arm64-libbridge_sync.gzbin',
    };
    List<String> pending;
    try {
      pending = automatic
          ? await channel.invokeListMethod<String>('pendingGoAssetRoles') ??
                const []
          : mapping.keys.toList();
    } catch (_) {
      return {};
    }
    final results = <String, dynamic>{};
    for (final entry in mapping.entries) {
      if (!pending.contains(entry.key)) continue;
      try {
        final bd = await rootBundle.load(entry.value);
        final bytes = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
        final res = await channel.invokeMethod<Map>('hotSwapGoAsset', {
          'role': entry.key,
          'bytes': bytes,
          'automatic': automatic,
        });
        results[entry.key] = res == null ? {} : Map<String, dynamic>.from(res);
      } catch (error) {
        if (!automatic) {
          results[entry.key] = {'error': '${entry.key}: $error'};
        }
      }
    }
    return {
      if (!automatic) ...await goBinariesStatus(),
      'sync_results': results,
    };
  }

  @override
  Future<Map<String, dynamic>?> pickGoBinaryFile(String role) async {
    if (!Platform.isAndroid) {
      return null;
    }
    final res = await channel.invokeMethod<Map>('pickGoBinaryFile', {
      'role': role,
    });
    return res == null ? null : Map<String, dynamic>.from(res);
  }

  @override
  Future<Map<String, dynamic>> revertGoBinaries({String? role}) async {
    if (!Platform.isAndroid) {
      return goBinariesStatus();
    }
    final res = await channel.invokeMethod<Map>('revertGoBinaries', {
      'role': ?role,
    });
    return res == null ? {} : Map<String, dynamic>.from(res);
  }

  @override
  Future<String?> saveDownload(String path) async {
    if (!Platform.isAndroid) {
      return path;
    }
    return channel.invokeMethod<String>('saveDownload', {'path': path});
  }

  @override
  Future<void> restartAgent() async {
    if (Platform.isAndroid) {
      await channel.invokeMethod('restartAgent');
    }
  }

  Future<Map<String, dynamic>> trafficConnections() async {
    if (!Platform.isAndroid) return {};
    try {
      return Map<String, dynamic>.from(
        await channel.invokeMethod<Map>('trafficConnections') ?? {},
      );
    } catch (_) {
      return {};
    }
  }

  @override
  Future<Map<String, dynamic>> runtimeStatus({
    bool includeResources = false,
  }) async {
    Map<String, dynamic> base = {};
    if (Platform.isAndroid) {
      try {
        final raw = await channel.invokeMethod<Map>('runtimeStatus', {
          'include_resources': includeResources,
        });
        if (raw != null) base = Map<String, dynamic>.from(raw);
      } catch (_) {}
    } else {
      base = await _linuxRuntimeStatus();
    }
    Map<String, dynamic>? ts;
    Map<String, dynamic>? wg;
    await Future.wait([
      () async {
        try {
          final raw = await run(['tailnet', 'status']);
          if (raw is Map) ts = Map<String, dynamic>.from(raw);
        } catch (_) {}
      }(),
      () async {
        try {
          final raw = await run(['wireguard', 'status']);
          if (raw is Map) wg = Map<String, dynamic>.from(raw);
        } catch (_) {}
      }(),
    ]);
    final proxy = ts?['proxy_stats'];
    if (Platform.isAndroid && proxy is Map) {
      final ports = (proxy['client_ports'] as List? ?? const [])
          .whereType<int>()
          .toList(growable: false);
      final endpoint = '${ts?['socks5_addr'] ?? ''}';
      final port = int.tryParse(endpoint.split(':').last);
      if (ports.isNotEmpty && port != null) {
        try {
          final apps = await channel.invokeListMethod<dynamic>(
            'proxyClientApps',
            {'port': port, 'client_ports': ports},
          );
          if (apps != null) base['proxy_client_apps'] = apps;
        } catch (_) {}
      }
    }
    return {...base, 'tailnet_status': ?ts, 'wireguard_status': ?wg};
  }

  Future<Map<String, dynamic>> _linuxRuntimeStatus() async {
    var rxBytes = 0;
    var txBytes = 0;
    final phys = <Map<String, dynamic>>[];
    try {
      final nets = await networks();
      for (final n in nets) {
        final iface = '${n['interface'] ?? ''}';
        final kind = switch (iface) {
          _ when iface.startsWith('p2p') || iface.startsWith('dbp2p') =>
            'wifi_direct',
          _ when iface.startsWith('ap') || iface.startsWith('swlan') =>
            'hotspot',
          _ when iface.startsWith('usb') || iface.startsWith('rndis') =>
            'usb_net',
          _ when iface.startsWith('en') || iface.startsWith('eth') =>
            'ethernet',
          _ when iface.startsWith('wwan') => 'cellular',
          _ when iface.startsWith('wl') => 'wifi',
          _ => null,
        };
        if (kind == null) continue;
        phys.add({
          'kind': kind,
          'interface': iface,
          'cidr': n['cidr'] ?? '',
          'unmetered': kind != 'cellular',
          'connected': true,
        });
      }
    } catch (_) {}
    try {
      final devFile = File('/proc/net/dev');
      if (await devFile.exists()) {
        for (final line in (await devFile.readAsLines()).skip(2)) {
          final idx = line.indexOf(':');
          if (idx <= 0) continue;
          final iface = line.substring(0, idx).trim();
          if (iface == 'lo') continue;
          final cols = line
              .substring(idx + 1)
              .trim()
              .split(RegExp(r'\s+'))
              .map((s) => int.tryParse(s) ?? 0)
              .toList();
          if (cols.length >= 9) {
            rxBytes += cols[0];
            txBytes += cols[8];
          }
        }
      }
    } catch (_) {}

    Map<String, dynamic> agent = {'running': false, 'state': 'idle'};
    try {
      final statusFile = File('$_state/agent-status.json');
      if (await statusFile.exists()) {
        final parsed = jsonDecode(await statusFile.readAsString()) as Map;
        final pid = (parsed['pid'] as num?)?.toInt() ?? 0;
        final alive =
            parsed['running'] == true &&
            pid > 0 &&
            Directory('/proc/$pid').existsSync();
        agent = {
          'running': alive,
          'file_running': alive,
          'state': alive ? 'active' : 'stopped',
          'pid': pid,
          'endpoint': parsed['endpoint'] ?? '',
          'interface': parsed['interface'] ?? '',
          'cidr': parsed['cidr'] ?? '',
          'discovery': parsed['discovery'] == true,
          'agent_ssh_enabled': parsed['agent_ssh_enabled'] == true,
          'active_ssh': alive ? (parsed['active_ssh'] ?? 0) : 0,
          'active_conns': alive ? (parsed['active_conns'] ?? 0) : 0,
          'active_requests': alive ? (parsed['active_requests'] ?? 0) : 0,
          'total_requests': parsed['total_requests'] ?? 0,
          'bytes_sent': parsed['bytes_sent'] ?? 0,
          'bytes_received': parsed['bytes_received'] ?? 0,
        };
      }
    } catch (_) {}

    var sshListening = false;
    var sshConns = 0;
    try {
      for (final p in ['/proc/net/tcp', '/proc/net/tcp6']) {
        final f = File(p);
        if (!await f.exists()) continue;
        for (final line in (await f.readAsLines()).skip(1)) {
          final cols = line.trim().split(RegExp(r'\s+'));
          if (cols.length < 4) continue;
          final local = cols[1].toUpperCase();
          final st = cols[3];
          if (local.endsWith(':0016')) {
            if (st == '0A') sshListening = true;
            if (st == '01') sshConns++;
          }
        }
      }
    } catch (_) {}

    Map<String, dynamic> directLink = {'active': false};
    try {
      directLink = await activeDirectLink();
    } catch (_) {}
    final caps = await platformCapabilities();

    return {
      'os': 'linux',
      'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
      'traffic': {
        'uid_rx_bytes': rxBytes,
        'uid_tx_bytes': txBytes,
        'total_rx_bytes': rxBytes,
        'total_tx_bytes': txBytes,
      },
      'usb': {
        'cable_plugged': caps['usb_adb'] == true,
        'adb_enabled': caps['adb_enabled'] == true,
        'usb_adb_connected': caps['usb_adb_connected'] == true,
      },
      'physical_networks': phys,
      'direct_link': directLink,
      'agent': agent,
      'ssh': {
        'tailscale_ssh_enabled': false,
        'openssh_enabled': sshListening,
        'openssh_running': sshListening,
        'openssh_port': 22,
        'openssh_conns': sshConns,
      },
      'capabilities': caps,
    };
  }
}
