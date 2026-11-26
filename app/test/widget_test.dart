import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:xterm3/xterm.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:devicebridge/main.dart';
import 'package:devicebridge/core/bridge.dart';
import 'package:devicebridge/core/debug_trace.dart';
import 'package:devicebridge/features/ssh_bootstrap.dart';
import 'package:devicebridge/features/appearance.dart';
import 'package:devicebridge/features/amoled_editor.dart';
import 'package:devicebridge/features/phone_files.dart';
import 'package:devicebridge/features/permission_wizard.dart';
import 'package:devicebridge/features/quick_share.dart';
import 'package:devicebridge/features/ssh_key_picker.dart';
import 'package:devicebridge/features/registry.dart';
import 'package:devicebridge/features/remote_files.dart';
import 'package:devicebridge/features/folder_exclusions.dart';
import 'package:devicebridge/features/settings_screen.dart';
import 'package:devicebridge/features/sync_screen.dart';
import 'package:devicebridge/features/tailnet_panel.dart';
import 'package:devicebridge/features/traffic_details.dart';
import 'package:devicebridge/features/local_terminal.dart';

class FakeCore implements CoreBridge {
  @override
  Future<Map<String, dynamic>?> pickShareFile({bool directory = false}) async =>
      {'path': '/fixture/sample.bin', 'name': 'sample.bin', 'size': 3};
  @override
  Future<Map<String, dynamic>> sendShareFile(
    String peer,
    Map<String, dynamic> file,
  ) async {
    calls.add(['send-file', peer, file['name'] as String]);
    return {
      'name': file['name'],
      'size': file['size'],
      'xxh64': '44bc2cf5ad770999',
    };
  }

  @override
  Future<String?> saveSharedFile(String name) async => null;
  @override
  Future<dynamic> localFiles(
    String operation,
    Map<String, dynamic> arguments,
  ) async => operation == 'roots'
      ? [
          {'id': 'internal', 'name': 'Internal storage', 'available': true},
          {'id': 'termux_home', 'name': 'Termux Home', 'available': true},
          {'id': 'recycle_bin', 'name': 'Recycle Bin', 'available': true},
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
  Future<Map<String, dynamic>> permissionsStatus({bool autoGrant = true}) async =>
      const {
        'execution_mode': 'standard',
        'wizard_completed': true,
        'all_essential_granted': true,
        'all_granted': true,
        'has_missing_runtime': false,
        'permissions': <Map<String, dynamic>>[],
      };
  @override
  Future<Map<String, dynamic>> requestAppPermission(String id) async =>
      permissionsStatus(autoGrant: false);
  @override
  Future<Map<String, dynamic>> autoGrantPermissions() async =>
      permissionsStatus(autoGrant: false);
  @override
  Future<Map<String, dynamic>> platformCapabilities() async => {
    'cellular': true,
    'wifi': true,
    'wifi_5ghz': true,
    'wifi_6': true,
    'wifi_6ghz': false,
    'wifi_direct': true,
    'hotspot_ap': true,
    'hotspot_sta': true,
    'adb_enabled': true,
    'usb_adb': true,
    'usb_adb_connected': true,
    'termux_installed': true,
    'tailnet_enabled': tailnetEnabled,
  };
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
  }) async {
    final chosenFreq = (frequencyMhz != null && frequencyMhz > 0)
        ? frequencyMhz
        : (channel != null && channel > 0
              ? (channel <= 13 ? 2407 + channel * 5 : 5000 + channel * 5)
              : 5805);
    final chosenCh = (channel != null && channel > 0)
        ? channel
        : (chosenFreq >= 5000 ? (chosenFreq - 5000) ~/ 5 : 6);
    return {
      'ok': true,
      'kind': kind,
      'transport': 'lan',
      'interface': kind == 'wifi_direct' ? 'p2p-p2p0-0' : 'ap0',
      'ip': kind == 'wifi_direct' ? '192.168.49.1' : '10.95.40.224',
      'cidr': kind == 'wifi_direct' ? '192.168.49.1/24' : '10.95.40.224/24',
      'endpoint': kind == 'wifi_direct'
          ? '192.168.49.1:8731'
          : '10.95.40.224:8731',
      'ssid': (ssid != null && ssid.isNotEmpty)
          ? ssid
          : (kind == 'wifi_direct' ? 'DIRECT-DB-5G' : 'DB-AP-5G'),
      'passphrase': (passphrase != null && passphrase.isNotEmpty)
          ? passphrase
          : 'devicebridge123',
      'band': '5 GHz',
      'channel': chosenCh,
      'frequency_mhz': chosenFreq,
      'bandwidth_mhz': (bandwidthMhz != null && bandwidthMhz > 0)
          ? bandwidthMhz
          : 80,
      'wifi_standard': 'Wi-Fi 6 (802.11ax)',
    };
  }

  @override
  Future<Map<String, dynamic>> stopDirectLink({bool forget = true}) async => {
    'ok': true,
    'status': 'restored',
  };
  @override
  Future<Map<String, dynamic>> activeDirectLink() async => {'active': false};
  @override
  Future<List<String>> directLinkNeighbors(String interfaceName) async => [];
  @override
  Future<Map<String, dynamic>> linkDetails({String interfaceName = ''}) async =>
      {};
  @override
  Future<Map<String, dynamic>?> pickTargetTree() async => {
    'uri': 'content://mock/tree',
    'name': 'PickedFolder',
    'kind': 'saf',
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

  Map<String, dynamic> goStatus = {
    'version': '1.4.0',
    'go': 'go1.24.0',
    'arch': 'android/arm64',
    'hot_count': 0,
    'libraries': [
      {
        'role': 'cli',
        'version': '1.4.0',
        'source': 'bundled',
        'xxh64': 'abcdef0123456789',
        'size_bytes': 11534336,
        'available': true,
      },
      {
        'role': 'agent',
        'version': '1.4.0',
        'source': 'bundled',
        'xxh64': '1122334455667788',
        'size_bytes': 11000000,
        'available': true,
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> goBinariesStatus() async => Map.of(goStatus);
  @override
  Future<Map<String, dynamic>> syncGoBinariesFromAssets() async => {
    ...goStatus,
    'sync_results': {},
  };
  @override
  Future<Map<String, dynamic>?> pickGoBinaryFile(String role) async {
    goStatus['hot_count'] = 1;
    goStatus['libraries'] = [
      {
        'role': role,
        'version': '1.4.0',
        'source': 'picked-file',
        'xxh64': '9999888877776666',
        'size_bytes': 11534336,
        'available': true,
      },
    ];
    return {'role': role, 'activated': true, 'previous_removed': false};
  }

  @override
  Future<Map<String, dynamic>> revertGoBinaries({String? role}) async {
    goStatus['hot_count'] = 0;
    return Map.of(goStatus);
  }

  @override
  Future<void> restartAgent() async {}
  @override
  Future<Map<String, dynamic>> runtimeStatus({
    bool includeResources = false,
  }) async => {
    'os': 'android',
    'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
    'traffic': {
      'uid_rx_bytes': 2097152,
      'uid_tx_bytes': 1048576,
      'total_rx_bytes': 4194304,
      'total_tx_bytes': 2097152,
    },
    'usb': {
      'cable_plugged': true,
      'adb_enabled': true,
      'usb_adb_connected': true,
      'battery_level': 84,
      'battery_charging': true,
    },
    'physical_networks': [
      if (network != null)
        {
          'kind': 'wifi',
          'interface': network!['interface'] ?? 'test0',
          'cidr': network!['cidr'] ?? '192.168.50.2/24',
          'unmetered': true,
          'connected': true,
        },
      if (wifiDirectReachable)
        {
          'kind': 'wifi_direct',
          'interface': 'p2p-wlan0-0',
          'cidr': '192.168.49.1/24',
          'unmetered': true,
          'connected': true,
        },
    ],
    'direct_link': {'active': false},
    'agent': {
      'running': true,
      'state': 'active',
      'endpoint': '192.168.50.2:8731',
      'discovery': true,
      'active_conns': 1,
      'active_requests': 0,
      'total_requests': 12,
      'bytes_sent': 65536,
      'bytes_received': 16384,
    },
    'ssh': {
      'tailscale_ssh_enabled': settings['tsnet_ssh_enabled'] != false,
      'openssh_enabled': settings['tsnet_openssh_enabled'] == true,
      'openssh_running': settings['tsnet_openssh_enabled'] == true,
      'openssh_port': 8022,
      'openssh_conns': 0,
    },
    'tailnet': {'enabled': tailnetEnabled, 'process_running': tailnetReachable},
    'wireguard': {'enabled': false, 'process_running': false},
    'tailnet_status': await run(['tailnet', 'status']),
    'wireguard_status': await run(['wireguard', 'status']),
    'capabilities': {'all_files_access': true, 'termux_installed': true},
  };

  @override
  Future<GuestTerminalLink> openAgentTerminal(
    Map<String, dynamic> request,
  ) async {
    calls.add(['agent-terminal', jsonEncode(request)]);
    return GuestTerminalLink(
      Stream<String>.fromIterable([
        jsonEncode({'state': 'ready'}),
      ]),
      (_) async {},
      () async {},
    );
  }

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
    'verbose_logging': true,
    'debug_mode': true,
    'execution_mode': 'standard',
    'root_enabled': false,
    'root_verified': false,
    'root_status': 'Not requested',
    'root_feature_direct_link': true,
    'root_feature_neighbors': true,
    'root_feature_shell_diag': false,
    'shizuku_enabled': false,
    'shizuku_running': false,
    'shizuku_status': 'Service not running',
    'shizuku_feature_direct_link': true,
    'shizuku_feature_wifi_join': true,
    'tsnet_socks5_enabled': false,
    'tsnet_socks5_port': 1055,
    'tsnet_exit_node_id': '',
    'tsnet_ssh_enabled': true,
    'tsnet_openssh_enabled': false,
  };
  @override
  Future<Map<String, dynamic>> appSettings({
    Map<String, dynamic>? update,
  }) async {
    if (update != null) settings.addAll(update);
    final rootOn = settings['root_enabled'] == true;
    final shizukuOn = settings['shizuku_enabled'] == true;
    return {
      ...settings,
      'root_feature_direct_link':
          rootOn && settings['root_feature_direct_link'] == true,
      'root_feature_neighbors':
          rootOn && settings['root_feature_neighbors'] == true,
      'root_feature_shell_diag':
          rootOn && settings['root_feature_shell_diag'] == true,
      'shizuku_feature_direct_link':
          shizukuOn && settings['shizuku_feature_direct_link'] == true,
      'shizuku_feature_wifi_join':
          shizukuOn && settings['shizuku_feature_wifi_join'] == true,
      'go_runtime': goStatus,
    };
  }

  final calls = <List<String>>[];
  List<dynamic> peerActions = [];
  bool tailnetReachable = false;
  String tailnetHostname = 'termux';
  bool tailnetEnabled = false;
  int tailnetStartupFailures = 0;
  int tailnetStartingResponses = 0;
  bool wifiDirectReachable = false;
  final Map<String, Map<String, dynamic>> savedPeerSsh = {};
  final Map<String, Map<String, dynamic>> savedHostSsh = {};

  String _cliCmd(List<String> args) {
    var i = 0;
    while (i < args.length) {
      final a = args[i];
      if (a == '--approve-remote' || a == '--allow-route-fallback') {
        i += 1;
      } else if (a.startsWith('--')) {
        i += 2;
      } else {
        return a;
      }
    }
    return args.isEmpty ? '' : args.first;
  }

  String? _flagVal(List<String> args, String flag) {
    final idx = args.indexOf(flag);
    if (idx >= 0 && idx + 1 < args.length) {
      return args[idx + 1];
    }
    return null;
  }

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
  Future<void> enableWireguard(bool enabled) async {}
  @override
  Future<String?> pickConfText() async => null;
  @override
  Future<List<Map<String, String>>> listSshKeys() async => [
    {'name': 'id_ed25519', 'path': '/mock/.ssh/id_ed25519'},
  ];
  @override
  Future<String?> readSshKey(Map<String, String> keyRef) async =>
      '-----BEGIN OPENSSH PRIVATE KEY-----\nmock-key\n-----END OPENSSH PRIVATE KEY-----';
  @override
  Future<String?> pickSshKeyText() async =>
      '-----BEGIN OPENSSH PRIVATE KEY-----\nbrowsed-key\n-----END OPENSSH PRIVATE KEY-----';
  @override
  Future<void> approveNetwork(Map<String, dynamic> network) async {}
  @override
  Future<void> cancel() async {}

  @override
  Future<void> allowMeteredPull(String approvalId) async {}
  @override
  Future<String?> saveDownload(String path) async => path;
  @override
  Future<List<Map<String, dynamic>>> networks() async => [
    if (wifiDirectReachable)
      {
        'interface': 'p2p-wlan0-0',
        'cidr': '192.168.49.1/24',
        'kind': 'wifi_direct',
      },
  ];
  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    calls.add(arguments);
    final cmd = _cliCmd(arguments);
    if (cmd == 'tailnet' && tailnetStartupFailures > 0) {
      tailnetStartupFailures--;
      throw StateError('app-only Tailscale is not running');
    }
    if (cmd == 'tailnet' && tailnetStartingResponses > 0) {
      tailnetStartingResponses--;
      return {'state': 'Starting'};
    }
    final tr = _flagVal(arguments, '--transport');
    final iface = _flagVal(arguments, '--interface');
    if (cmd == 'resolve') {
      if (tr == 'tailnet') {
        if (!tailnetReachable) {
          throw StateError('tailnet peer unreachable');
        }
        return {
          'transport': 'tailnet',
          'endpoint': _flagVal(arguments, '--endpoint') ?? '100.64.0.9:8731',
          'path_kind': 'direct',
          'rtt': 8500000,
          'mib_per_second': 14.0,
        };
      }
      if (tr == 'wireguard' || tr == 'adb' || tr == 'ssh') {
        throw StateError('$tr unreachable');
      }
      if (iface == 'p2p-wlan0-0') {
        return {
          'transport': 'direct-lan-v1',
          'endpoint': '192.168.49.15:8731',
          'interface': 'p2p-wlan0-0',
          'rtt': 2200000,
          'mib_per_second': 35.0,
        };
      }
      return {
        'transport': 'direct-lan-v1',
        'endpoint': '192.168.50.3:8731',
        'interface': 'test0',
        'rtt': 1000000,
        'mib_per_second': 42.5,
      };
    }
    return switch (cmd) {
      'link-operation' => <String, dynamic>{
        'id': 'fixture-operation',
        'stage': arguments.length > 2 ? arguments[2] : 'restored',
      },
      'network-policy' => <String, dynamic>{'network_agent_ssh': true},
      'ssh-hosts' => <Map<String, dynamic>>[],
      'peer-ssh-method' => {'method': 'auto'},
      'rename-peer' => {'name': arguments.last},
      'peer-ssh-access' => {'allowed': arguments.last == 'allow'},
      'share-inbox' || 'share-files' => const <Map<String, dynamic>>[],
      'share-text-access' ||
      'share-file-access' => {'allowed': arguments.last == 'allow'},
      'connection' => {'transport': 'lan'},
      'wireguard' => () {
        if (arguments.length > 1 && arguments[1] == 'import-conf') {
          return {
            'configured': true,
            'imported': true,
            'default_route_stripped': (input ?? '').contains('0.0.0.0/0'),
            'scoped_allowed_ips': ['10.66.66.0/24'],
            'backend': 'userspace',
            'public_key': 'importedPubKey==',
            'local_tunnel_ip': '10.66.66.5/24',
            'listen_port': 51820,
            'peers': [
              {
                'name': 'dubai.example.com',
                'server_endpoint': 'dubai.example.com:51820',
              },
            ],
          };
        }
        return {
          'configured': false,
          'backend': 'userspace',
          'public_key': '',
          'local_tunnel_ip': '',
          'peers': [],
        };
      }(),
      'ssh-probe' => {
        'host': arguments[1],
        'port': int.tryParse(arguments.length > 2 ? arguments[2] : '22') ?? 22,
        'host_key_sha256': 'SHA256:mockhostkey',
        'key_type': 'ssh-ed25519',
        'via_tailnet': arguments[1] == 'probook',
        'resolved_host': arguments[1] == 'probook'
            ? '100.100.78.84'
            : arguments[1],
      },
      'ssh-bootstrap' => () {
        final req = jsonDecode(input ?? '{}') as Map;
        return {
          'remote_hostname': req['host'],
          'systemd_status': 'active',
          'firewall_status': 'allowed',
          'paired_route': 'tailnet',
          'paired_endpoint': '${req['host']}:8731',
        };
      }(),
      'ssh-run' || 'agent-ssh-run' => () {
        final req = jsonDecode(input ?? '{}') as Map;
        return {
          'host': req['host'] ?? req['endpoint'] ?? req['peer_id'] ?? '',
          'port': req['port'] ?? 22,
          'host_key_sha256': 'SHA256:mockhostkey',
          'exit_code': 0,
          'stdout': 'ran:${req['command']}',
          'stderr': '',
        };
      }(),
      'peer-actions' => () {
        if (arguments.length == 3 && arguments[2] == '-') {
          peerActions = List<dynamic>.from(jsonDecode(input ?? '[]') as List);
        }
        return peerActions;
      }(),
      'peer-ssh' => () {
        if (arguments.length == 3 && arguments[2] == '-') {
          final m = Map<String, dynamic>.from(jsonDecode(input ?? '{}') as Map);
          if (m['via_tailnet'] == true) {
            m.remove('private_key_pem');
          }
          savedPeerSsh[arguments[1]] = m;
        }
        return savedPeerSsh[arguments[1]] ?? <String, dynamic>{};
      }(),
      'host-ssh' => () {
        if (arguments.length == 3 && arguments[2] == '-') {
          final m = Map<String, dynamic>.from(jsonDecode(input ?? '{}') as Map);
          if (m['via_tailnet'] == true) {
            m.remove('private_key_pem');
          }
          savedHostSsh[arguments[1]] = m;
        }
        return savedHostSsh[arguments[1]] ?? <String, dynamic>{};
      }(),
      'tailnet' =>
        tailnetReachable
            ? {
                'mode': 'app',
                'state': 'Running',
                'hostname': tailnetHostname,
                'ips': ['100.64.0.2'],
                'socks5_enabled': settings['tsnet_socks5_enabled'] == true,
                'socks5_addr': settings['tsnet_socks5_enabled'] == true
                    ? '127.0.0.1:${settings['tsnet_socks5_port'] ?? 1055}'
                    : '',
                'exit_node_id': settings['tsnet_exit_node_id'] ?? '',
                'tailscale_ssh_enabled': settings['tsnet_ssh_enabled'] != false,
                'openssh_enabled': settings['tsnet_openssh_enabled'] == true,
                'peers': [
                  {
                    'id': 'node-laptop-1',
                    'name': 'Laptop',
                    'online': true,
                    'ips': ['100.64.0.9'],
                    'exit_node_option': true,
                    'tags': ['tag:trusted'],
                  },
                ],
              }
            : {'mode': 'app', 'state': 'Stopped', 'ips': []},
      'theme' => {'theme': arguments.length > 1 ? arguments[1] : 'system'},
      'export' => {'status': 'export_registered'},
      'identity' => {'id': 'phone', 'name': 'Phone'},
      'peers' => [
        {
          'id': 'laptop',
          'name': 'Laptop',
          'status': 'paired',
          if (savedPeerSsh['laptop']?['host'] case final String host)
            'ssh_target':
                '${savedPeerSsh['laptop']?['user']}@$host:${savedPeerSsh['laptop']?['port']}',
          'addresses': [
            {'endpoint': '10.0.0.5:8731'},
          ],
        },
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
      'discover-ssh' => [
        {
          'source': 'lan',
          'source_label': 'Wi-Fi LAN',
          'name': 'arch-box',
          'host': '192.168.50.10',
          'connect_host': '192.168.50.10',
          'port': 22,
          'ping_ms': 2.1,
          'banner': 'SSH-2.0-OpenSSH_9.9',
          'ssh_enabled': true,
        },
        {
          'source': 'hotspot',
          'source_label': 'Hotspot',
          'host': '192.168.43.88',
          'connect_host': '192.168.43.88',
          'port': 8022,
          'ping_ms': 3.4,
          'banner': 'SSH-2.0-OpenSSH_9.8',
          'ssh_enabled': true,
        },
        {
          'source': 'tailnet',
          'source_label': 'Tailscale (tsnet)',
          'name': 'probook',
          'host': 'probook',
          'connect_host': '100.100.78.84',
          'port': 22,
          'ping_ms': 18.5,
          'banner': 'SSH-2.0-Tailscale',
          'ssh_enabled': true,
          'tailscale_ssh': true,
        },
      ],
      'pair' => {'status': 'pending'},
      'remove' => {'status': 'removed'},
      'syncthing' => {'installed': false, 'prepared': false, 'registered': []},
      'sync-pairs' => [],
      'sync-control-access' || 'sync-remote-access' => {'allowed': false},
      _ => throw StateError('Unexpected command $arguments'),
    };
  }
}

void main() {
  registerNetworkRefactorTests();
  _syncModeTests();
  testWidgets('A shared file stays in the composer until Send file', (
    tester,
  ) async {
    final core = FakeCore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuickShare(
            core: core,
            peers: const [
              {'id': 'laptop', 'name': 'Laptop', 'status': 'paired'},
            ],
            sharedDraft: const {
              'file': {
                'uri': 'content://fixture/sample',
                'name': 'sample.bin',
                'size': 3,
              },
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('sample.bin'), findsOneWidget);
    expect(core.calls.where((c) => c.first == 'send-file'), isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'Send file'));
    await tester.pumpAndSettle();
    expect(core.calls.where((c) => c.first == 'send-file').single, [
      'send-file',
      'laptop',
      'sample.bin',
    ]);
    expect(find.textContaining('File delivered and verified'), findsOneWidget);
  });

  testWidgets('The first app screen uses the saved theme', (tester) async {
    final core = _PendingThemeCore();
    await tester.pumpWidget(DeviceBridgeApp(core: core));
    expect(find.byType(MaterialApp), findsNothing);
    core.theme.complete({'theme': 'matte'});
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AppearanceSurface>(find.byType(AppearanceSurface).first)
          .appearance,
      'matte',
    );
  });

  testWidgets('Linux Remove asks for confirmation and invokes SSH uninstall', (
    tester,
  ) async {
    final core = _UninstallCore();
    await tester.pumpWidget(DeviceBridgeApp(core: core));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Devices').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();
    final list = find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Remove device'),
      200,
      scrollable: list,
    );
    expect(find.text('Revoke device'), findsNothing);
    await tester.tap(find.text('Remove device'));
    await tester.pumpAndSettle();
    expect(core.uninstall, isNull);
    await tester.tap(find.text('Remove and uninstall'));
    await tester.pumpAndSettle();
    expect(core.uninstall?['expected_host_key'], 'SHA256:saved-host-key');
    expect(core.calls.where((args) => args.first == 'remove'), isEmpty);
  });

  testWidgets(
    'Offline or uninstalled peer can be removed locally without SSH uninstall',
    (tester) async {
      final core = FakeCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();
      final list = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Remove without uninstalling daemon'),
        200,
        scrollable: list,
      );
      expect(find.text('Remove device'), findsOneWidget);
      expect(find.text('Remove without uninstalling daemon'), findsOneWidget);

      // Path A: inside Remove device dialog -> Remove locally only
      await tester.tap(find.text('Remove device'));
      await tester.pumpAndSettle();
      expect(find.text('Remove locally only'), findsOneWidget);
      await tester.tap(find.text('Remove locally only'));
      await tester.pumpAndSettle();
      expect(
        core.calls.any(
          (args) =>
              args.length == 2 && args[0] == 'remove' && args[1] == 'laptop',
        ),
        isTrue,
      );

      // Path B: direct Remove without uninstalling daemon button
      core.calls.clear();
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();
      final list2 = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Remove without uninstalling daemon'),
        200,
        scrollable: list2,
      );
      await tester.tap(find.text('Remove without uninstalling daemon'));
      await tester.pumpAndSettle();
      expect(find.text('Remove this device?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(
        core.calls.any(
          (args) =>
              args.length == 2 && args[0] == 'remove' && args[1] == 'laptop',
        ),
        isTrue,
      );
    },
  );

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
      await tester.scrollUntilVisible(find.text('Shizuku access'), 250);
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
      await tester.tap(find.text('Matte'));
      await tester.pumpAndSettle();
      expect(find.text('Matte editor'), findsOneWidget);
      await tester.tap(find.text('Done'));
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

      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
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
    'Local storage offers Termux Home and Recycle Bin without SAF or App Downloads',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: FileManager(core: FakeCore())));
      await tester.pumpAndSettle();
      expect(find.text('This device'), findsNWidgets(2));
      await tester.tap(find.text('Internal storage').first);
      await tester.pumpAndSettle();
      expect(find.text('Termux Home'), findsWidgets);
      expect(find.text('Recycle Bin'), findsWidgets);
      expect(find.textContaining('SAF'), findsNothing);
      expect(find.text('App Downloads'), findsNothing);
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

  testWidgets(
    'Add Device opens pairing, SSH-only, and SSH agent deployment over available transports with .ssh import and Tailscale setup',
    (tester) async {
      final core = FakeCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      expect(find.text('Discover'), findsNothing);
      expect(find.text('Discover on LAN'), findsNothing);
      expect(find.text('Pair device'), findsNothing);
      expect(find.text('Create invitation'), findsNothing);
      expect(find.text('Add SSH device'), findsNothing);
      expect(find.byKey(const ValueKey('devices-add-device-button')), findsOneWidget);
      expect(find.text('Add Device'), findsOneWidget);
      expect(find.text('Direct'), findsOneWidget);
      expect(find.text('SSH'), findsOneWidget);
      // Tailscale SSH peers must not spam Direct or saved SSH devices automatically.
      expect(find.text('Tailscale SSH devices'), findsNothing);
      expect(find.byKey(const ValueKey('tailscale-ssh-device-probook')), findsNothing);
      expect(find.text('probook'), findsNothing);
      expect(find.text('arch-box'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('devices-add-device-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('add-device-sheet')), findsOneWidget);
      expect(find.text('Scan or enter invitation'), findsOneWidget);
      expect(find.text('Show my invitation'), findsOneWidget);
      expect(find.text('Add SSH Device only (no agent)'), findsOneWidget);
      expect(find.text('Add agent via SSH'), findsOneWidget);

      await tester.ensureVisible(find.text('Add agent via SSH'));
      await tester.tap(find.text('Add agent via SSH'));
      await tester.pumpAndSettle();
      expect(find.text('Setup & auto-pair via SSH'), findsOneWidget);
      expect(find.byKey(const ValueKey('ssh-transport-dropdown')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ssh-transport-dropdown')));
      await tester.pumpAndSettle();
      expect(find.text('Direct TCP').last, findsOneWidget);
      expect(find.text('Tailscale — sign-in required').last, findsOneWidget);
      expect(find.text('WireGuard — configuration required').last, findsOneWidget);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        MaterialApp(
          home: SshBootstrapDialog(
            core: core,
            initialHost: 'probook',
            initialPort: 22,
            autoProbe: true,
            tailscaleSsh: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Setup & auto-pair via SSH'), findsOneWidget);
      expect(
        find.text('SSH password (optional for Tailscale SSH)'),
        findsOneWidget,
      );
      expect(
        core.calls.any(
          (c) =>
              c.length >= 3 &&
              c[0] == 'ssh-probe' &&
              c[1] == 'probook' &&
              c[2] == '22',
        ),
        isTrue,
      );

      // Import private key directly from .ssh picker.
      await tester.ensureVisible(find.text('Import from .ssh'));
      await tester.tap(find.text('Import from .ssh'));
      await tester.pumpAndSettle();
      expect(find.text('Select private key (.ssh)'), findsOneWidget);
      await tester.tap(find.text('id_ed25519'));
      await tester.pumpAndSettle();
      expect(find.textContaining('mock-key'), findsOneWidget);

      // Clear imported key and verify Tailscale SSH Run Setup succeeds without password/key.
      final keyField = find.widgetWithText(
        TextField,
        'Private key PEM (optional for Tailscale SSH)',
      );
      await tester.ensureVisible(keyField);
      await tester.enterText(keyField, '');
      final userField = find.widgetWithText(TextField, 'SSH username');
      await tester.ensureVisible(userField);
      await tester.enterText(userField, 'afzl');
      await tester.tap(find.text('Run Setup'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Paired: tailnet (probook:8731)'),
        findsOneWidget,
      );

      // Open SSH tab, browse Tailscale SSH on demand, and open Add SSH device preselected with Tailscale.
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('SSH'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('devices-browse-tailscale-ssh')), findsOneWidget);
      expect(find.text('probook'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('devices-browse-tailscale-ssh')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tailscale-ssh-picker-dialog')), findsOneWidget);
      expect(find.byKey(const ValueKey('tailscale-ssh-device-probook')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tailscale-ssh-device-probook')));
      await tester.pumpAndSettle();
      expect(find.text('Add SSH device'), findsOneWidget);
      expect(find.text('probook'), findsOneWidget);
      expect(find.text('Tailscale — sign-in required'), findsOneWidget);
    },
  );

  testWidgets('Four primary areas with folder sync managed in Files', (
    tester,
  ) async {
    final core = FakeCore();
    await tester.pumpWidget(DeviceBridgeApp(core: core));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Tailscale connectivity'), findsNothing);
    expect(find.byTooltip('Networks'), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(3));
    expect(find.text('Sync'), findsNothing);
    for (final label in ['Home', 'Files', 'Devices', 'Share']) {
      expect(find.text(label), findsWidgets);
    }
    expect(find.widgetWithText(FilledButton, 'Termux'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('home-open-file-manager')),
      findsOneWidget,
    );
    expect(find.text('Find devices'), findsNothing);
    expect(find.text('Pair device'), findsNothing);
    expect(find.text('Create invitation'), findsNothing);
    expect(find.text('Select LAN'), findsNothing);
    expect(find.text('Transports'), findsNothing);
    expect(find.text('Local storage & readiness'), findsNothing);
    expect(find.textContaining('paired ·'), findsNothing);
    expect(find.textContaining('Approved LAN'), findsNothing);
    final traffic = find.byKey(const ValueKey('home-traffic-monitor'));
    final ssh = find.byKey(const ValueKey('home-signal-ssh'));
    expect(traffic, findsOneWidget);
    expect(ssh, findsOneWidget);
    expect(tester.getTopLeft(traffic).dy, lessThan(tester.getTopLeft(ssh).dy));
    expect(find.text('OpenSSH · :8022'), findsOneWidget);
    expect(find.text('Tailscale SSH · :22'), findsOneWidget);
    expect(find.text('SSH status & connections'), findsNothing);
    expect(find.text('Agent & app connections'), findsNothing);
    expect(find.byKey(const ValueKey('home-signal-network')), findsNothing);
    expect(find.byKey(const ValueKey('home-signal-traffic')), findsNothing);
    expect(find.text('Laptop'), findsNothing);
    expect(find.textContaining('10.0.0.5:8731'), findsNothing);
    expect(core.calls.any((c) => c.first == 'list'), isFalse);

    await tester.tap(find.byKey(const ValueKey('home-open-file-manager')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'File manager'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byKey(const ValueKey('file-pane-0-device')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-dashboard')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('open-live-traffic')));
    await tester.pumpAndSettle();
    expect(find.text('DeviceBridge app & agents'), findsOneWidget);
    final trafficScroll = find
        .descendant(
          of: find.byType(TrafficDetails),
          matching: find.byType(Scrollable),
        )
        .first;
    for (final section in [
      'SSH traffic',
      'tsnet peer traffic',
      'SOCKS5 traffic',
      'Other DeviceBridge binaries',
      'Termux binaries',
    ]) {
      await tester.scrollUntilVisible(
        find.text(section),
        200,
        scrollable: trafficScroll,
      );
      expect(find.text(section), findsOneWidget);
    }
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Devices').last);
    await tester.pumpAndSettle();
    expect(find.text('Discover'), findsNothing);
    expect(find.text('Setup via SSH'), findsNothing);
    expect(find.text('Pair device'), findsNothing);
    expect(find.text('Create invitation'), findsNothing);
    expect(find.text('Add SSH device'), findsNothing);
    expect(find.text('Add Device'), findsOneWidget);
    await tester.ensureVisible(find.text('Laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();
    expect(find.text('Wi-Fi'), findsOneWidget);
    final overviewScroll = find
        .descendant(
          of: find.byType(ListView).first,
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Remove device'),
      200,
      scrollable: overviewScroll,
    );
    expect(find.text('Remove device'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, 'Connections'));
    await tester.pumpAndSettle();
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Saved addresses'), findsNothing);
    await tester.tap(find.widgetWithText(Tab, 'Overview'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Approved'),
      -200,
      scrollable: overviewScroll,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('Approved')),
      alignment: .35,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approved'));
    await tester.pumpAndSettle();
    expect(find.text('hello.txt'), findsOneWidget);
    expect(find.text('.secret-dotfile'), findsNothing);
    expect(find.text('Termux Storage'), findsNothing);
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
  });

  testWidgets(
    'Invitation pairing sends the code only after fingerprint approval',
    (tester) async {
      final core = FakeCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scan or enter invitation'));
      await tester.pumpAndSettle();
      final deviceId = List.filled(64, 'a').join();
      await tester.enterText(
        find.widgetWithText(TextField, 'Invitation code'),
        jsonEncode({
          'version': 1,
          'id': deviceId,
          'name': 'Other phone',
          'token': List.filled(43, 'a').join(),
          'expires': DateTime.now()
              .add(const Duration(minutes: 5))
              .toUtc()
              .toIso8601String(),
        }),
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('Pair with Other phone?'), findsOneWidget);
      expect(core.calls.any((args) => args.contains('pair')), isFalse);
      await tester.tap(find.text('Fingerprint matches'));
      await tester.pumpAndSettle();
      expect(core.calls.where((args) => args.contains('pair')).single, [
        'pair',
        '-',
      ]);
    },
  );

  testWidgets(
    'Devices lists nearby DeviceBridge peers automatically and invites show QR and JSON copy',
    (tester) async {
      final core = _NearbyPairingCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      expect(find.text('Discover'), findsNothing);
      expect(find.text('Nearby DeviceBridge devices'), findsOneWidget);
      expect(find.text('Nearby phone'), findsOneWidget);
      expect(find.text('192.168.50.5:42231 · Unpaired'), findsOneWidget);
      await tester.tap(find.text('Nearby phone'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Create an invitation on Nearby phone'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show my invitation'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pair-invitation-qr')), findsOneWidget);
      expect(find.byType(QrImageView), findsOneWidget);
      expect(find.text('Copy code'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'The requesting device finishes pairing automatically after approval',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final core = _AutomaticPairingCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      expect(find.text('Waiting for approval'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      expect(core.finishAttempts, 1);
      expect(core.completed, isFalse);
      core.approved = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(core.completed, isTrue);
      expect(find.text('Waiting for approval'), findsNothing);
      expect(find.text('Finish pairing'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'SOCKS5 details stay on Home and battery diagnostics open from Settings',
    (tester) async {
      await tester.pumpWidget(DeviceBridgeApp(core: _UsageMonitorCore()));
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byKey(const ValueKey('home-dashboard')),
            matching: find.byType(Scrollable),
          )
          .first;
      expect(find.text('Battery & CPU diagnostics'), findsNothing);
      expect(find.byKey(const ValueKey('home-battery-usage')), findsNothing);
      final proxy = find.text('Local SOCKS5 proxy');
      await tester.scrollUntilVisible(proxy, 120, scrollable: scrollable);
      await tester.tap(proxy);
      await tester.pumpAndSettle();
      final destination = find.text('example.net');
      await tester.scrollUntilVisible(destination, 120, scrollable: scrollable);
      expect(destination, findsOneWidget);
      expect(find.text('org.example.client'), findsOneWidget);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      final diagnostics = find.text('Battery & CPU diagnostics');
      await tester.scrollUntilVisible(
        diagnostics,
        180,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(diagnostics);
      await tester.pumpAndSettle();
      await tester.tap(diagnostics);
      await tester.pumpAndSettle();
      expect(find.text('Go binaries & shell tools'), findsOneWidget);
      expect(find.textContaining('3 wakeup alarms'), findsOneWidget);
    },
  );

  testWidgets(
    'Revoked device in Devices opens DeviceDetail without intercepting dialog',
    (tester) async {
      final core = _RevokedPeerCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      expect(find.text('arch-laptop'), findsNothing);
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('No active devices yet.'), findsOneWidget);
      expect(find.text('Revoked devices (1)'), findsOneWidget);
      await tester.tap(find.text('arch-laptop'));
      await tester.pumpAndSettle();
      expect(find.text('Remove arch-laptop?'), findsNothing);
      expect(find.textContaining('This device is revoked'), findsOneWidget);
      expect(find.text('Revoke device'), findsNothing);
      expect(
        find.text('Device is revoked — remove or re-pair to use connections.'),
        findsOneWidget,
      );
      expect(find.text('Wi-Fi'), findsNothing);
      final detailScroll = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Remove device'),
        200,
        scrollable: detailScroll,
      );
      expect(find.text('Remove device'), findsOneWidget);
    },
  );

  testWidgets(
    'Device Overview chooses verified routes and Connections only configures setup',
    (tester) async {
      final core = FakeCore()
        ..tailnetReachable = true
        ..wifiDirectReachable = true;
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();

      expect(find.text('Device details'), findsNothing);
      expect(find.text('Toggles & target commands'), findsNothing);
      expect(
        find.byKey(const ValueKey('device-open-terminal')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('device-open-files')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('overview-transport-choice')));
      await tester.pumpAndSettle();
      expect(find.text('Direct TCP'), findsOneWidget);
      expect(find.text('Tailscale'), findsOneWidget);
      expect(find.text('WireGuard'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Connections'));
      await tester.pumpAndSettle();
      expect(find.text('Connection details'), findsNothing);
      expect(find.text('Available connections'), findsNothing);
      expect(find.text('Connection'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('overview-transport-choice')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Networks shows local status and Devices and Files open peer connections',
    (tester) async {
      final core = FakeCore()..tailnetReachable = true;
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Networks'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(AppBar, 'Networks'), findsOneWidget);
      expect(find.text('Agent and SSH services'), findsOneWidget);
      expect(find.text('Tailscale SSH'), findsOneWidget);
      expect(find.text('DeviceBridge agent'), findsOneWidget);
      final sshTransport = find.byKey(const ValueKey('networks-transports'));
      await tester.ensureVisible(sshTransport);
      await tester.tap(sshTransport);
      await tester.pumpAndSettle();
      expect(find.text('Direct TCP and tunnels'), findsOneWidget);
      expect(find.text('Direct TCP'), findsOneWidget);
      expect(find.textContaining('termux · 100.64.0.2'), findsOneWidget);
      expect(find.text('Import .conf'), findsOneWidget);

      expect(find.text('Internet links'), findsNothing);
      expect(find.text('Choose link'), findsNothing);
      expect(find.text('Change link'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('networks-links')));
      await tester.pumpAndSettle();
      expect(
        find.text('Radios, cables and network interfaces'),
        findsOneWidget,
      );
      expect(find.text('USB cable'), findsOneWidget);
      expect(find.text('Mobile data'), findsOneWidget);
      expect(
        core.calls.where((call) => call.contains('select-route')),
        isEmpty,
      );

      await tester.tap(find.byKey(const ValueKey('networks-services')));
      await tester.pumpAndSettle();
      expect(find.text('Choose device'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop').first);
      await tester.pumpAndSettle();
      expect(find.text('Current connection'), findsOneWidget);
      expect(find.textContaining('Last handshake:'), findsOneWidget);
      expect(find.byKey(const ValueKey('overview-speed-test')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('device-rename')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('device-name-input')),
        'Travel laptop',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Travel laptop'), findsOneWidget);
      expect(
        core.calls,
        contains(equals(['rename-peer', 'laptop', 'Travel laptop'])),
      );
      await tester.tap(find.byKey(const ValueKey('device-open-files')));
      await tester.pumpAndSettle();
      final files = tester.widget<FileManager>(find.byType(FileManager));
      expect(files.remotePeer?['id'], 'laptop');
      expect(files.remoteRoot, 'home');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('device-connections-tab')));
      await tester.pumpAndSettle();
      expect(find.text('Connection'), findsOneWidget);
      final detail = tester.widget<DeviceDetail>(find.byType(DeviceDetail));
      expect(detail.peer['id'], 'laptop');

      await tester.pumpWidget(
        MaterialApp(
          home: FileManager(
            core: core,
            remotePeer: detail.peer,
            candidates: detail.candidates,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Connection method'));
      await tester.pumpAndSettle();
      final fromFiles = tester.widget<DeviceDetail>(find.byType(DeviceDetail));
      expect(fromFiles.openConnections, isFalse);
      expect(fromFiles.peer['id'], detail.peer['id']);
      expect(fromFiles.candidates, detail.candidates);
      expect(find.text('Connections'), findsWidgets);
      expect(find.text('Current connection'), findsOneWidget);
    },
  );

  testWidgets(
    'Networks keeps peer setup contextual, binds existing links and targets the wired ADB serial',
    (tester) async {
      final core = _DirectHubCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Networks'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('networks-links')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('direct-config-wifi_direct')),
        findsNothing,
      );
      expect(find.text('Choose device to connect'), findsNothing);
      // Model a link established by peer-specific setup. Global Networks only binds it.
      await core.prepareDirectLink('wifi_direct');
      await tester.tap(find.byTooltip('Refresh networks'));
      await tester.pumpAndSettle();
      expect(core.approvedInterfaces, isEmpty);

      final bindDirect = find.byKey(
        const ValueKey('bind-local-link-wifiDirect'),
      );
      await tester.ensureVisible(bindDirect);
      await tester.tap(bindDirect);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('l4-direct-underlay-rmnet_data0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('l4-direct-underlay-tailscale0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('l4-direct-underlay-rndis0')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('l4-direct-underlay-p2p-wlan0-0')),
      );
      await tester.pumpAndSettle();
      expect(core.approvedInterfaces, ['p2p-wlan0-0']);
      expect(core.network?['direct'], isTrue);
      expect(core.network?['allow_wifi_roaming'], isFalse);

      await tester.tap(find.byKey(const ValueKey('networks-transports')));
      await tester.pumpAndSettle();
      final usbSetup = find.byKey(const ValueKey('usb-adb-start'));
      await tester.ensureVisible(usbSetup);
      await tester.tap(usbSetup);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('usb-adb-dialog')), findsOneWidget);
      expect(
        find.text('adb -s JBKJF6JFAAIZUGP7 reverse tcp:18731 tcp:8731'),
        findsOneWidget,
      );
      expect(core.adbPrepareRequests, isEmpty);
      await tester.tap(find.byKey(const ValueKey('usb-adb-activate')));
      await tester.pumpAndSettle();
      expect(core.adbPrepareRequests.single['serial'], 'JBKJF6JFAAIZUGP7');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('networks-links')));
      await tester.pumpAndSettle();
      final stop = find.byKey(const ValueKey('direct-stop-wifi_direct'));
      await tester.ensureVisible(stop);
      await tester.tap(stop);
      await tester.pumpAndSettle();
      expect(core.stopCalls, 1);
      expect(find.byKey(const ValueKey('direct-config-hotspot')), findsNothing);
    },
  );

  testWidgets(
    'Networks rejects a stale link and keeps charging USB and unsupported radio actions gated',
    (tester) async {
      final core = _DirectHubCore()
        ..wiredAdb = false
        ..supportsWifiDirect = false;
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Networks'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('networks-links')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bind-local-link-wifi')));
      await tester.pumpAndSettle();
      final candidate = find.byKey(const ValueKey('l4-direct-underlay-wlan1'));
      expect(candidate, findsOneWidget);
      core.altWifiHandle = '43';
      await tester.tap(candidate);
      await tester.pumpAndSettle();
      expect(find.textContaining('That link changed'), findsOneWidget);
      expect(core.approvedInterfaces, isEmpty);

      await tester.tap(find.byKey(const ValueKey('networks-links')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('direct-config-wifi_direct')),
        findsNothing,
      );
      final usbSetup = find.byKey(const ValueKey('usb-cable-setup'));
      await tester.ensureVisible(usbSetup);
      await tester.tap(usbSetup);
      await tester.pumpAndSettle();
      expect(
        find.text('Enable USB debugging in Android Developer options.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('usb-adb-activate')), findsNothing);
      expect(core.adbPrepareRequests, isEmpty);
    },
  );

  testWidgets(
    'Network settings follows live grants and chooses automation per operation',
    (tester) async {
      final core = _DirectHubCore()..settings['root_enabled'] = true;
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Networks'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('network-settings-button')));
      await tester.pumpAndSettle();

      Finder feature(String key) => find.byKey(ValueKey('network-$key'));
      String? mode(String operation) => tester
          .widget<Text>(find.byKey(ValueKey('network-$operation-mode')))
          .data;
      Future<void> change(String key) async {
        await tester.ensureVisible(feature(key));
        await tester.pumpAndSettle();
        await tester.tap(feature(key));
        await tester.pumpAndSettle();
      }

      const root = 'root_feature_direct_link';
      const shizukuHost = 'shizuku_feature_direct_link';
      const shizukuJoin = 'shizuku_feature_wifi_join';
      expect(tester.widget<SwitchListTile>(feature(root)).onChanged, isNull);
      expect(
        tester.widget<SwitchListTile>(feature(shizukuHost)).onChanged,
        isNull,
      );
      expect(mode('hosting'), 'Standard');
      expect(mode('joining'), 'Standard');

      core.settings['root_verified'] = true;
      core.settings['shizuku_enabled'] = true;
      await tester.tap(find.byTooltip('Refresh network settings'));
      await tester.pumpAndSettle();
      expect(mode('hosting'), 'Root');
      expect(mode('joining'), 'Root');

      await change(root);
      expect(mode('hosting'), 'Shizuku');
      expect(mode('joining'), 'Shizuku');
      await change(shizukuHost);
      expect(mode('hosting'), 'Standard');
      expect(mode('joining'), 'Shizuku');

      core.activeSession = {'active': true, 'kind': 'wifi_join'};
      await change(shizukuJoin);
      expect(mode('joining'), 'Shizuku');
      expect(
        tester.widget<SwitchListTile>(feature(shizukuJoin)).onChanged,
        isNull,
      );
      expect(core.settings[shizukuJoin], isTrue);

      core.activeSession = {'active': false};
      await tester.tap(find.byTooltip('Refresh network settings'));
      await tester.pumpAndSettle();
      await change(shizukuJoin);
      expect(mode('joining'), 'Standard');
      expect(core.settings['root_enabled'], isTrue);
      expect(core.settings['shizuku_enabled'], isTrue);
      expect(core.startedKinds, isEmpty);
    },
  );

  testWidgets(
    'Home monitor pauses when covered or backgrounded and resumes promptly',
    (tester) async {
      final core = _HomeMonitorCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      final first = core.statusReads;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(core.statusReads, greaterThan(first));

      await tester.tap(find.byTooltip('Networks'));
      await tester.pumpAndSettle();
      final covered = core.statusReads;
      await tester.pump(const Duration(seconds: 9));
      await tester.pumpAndSettle();
      expect(core.statusReads, covered);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(core.statusReads, greaterThan(covered));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      try {
        final paused = core.statusReads;
        await tester.pump(const Duration(seconds: 9));
        expect(core.statusReads, paused);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      await tester.pumpAndSettle();
      expect(core.statusReads, greaterThan(covered + 1));
    },
  );

  testWidgets('Home shows live traffic, SSH ports and actionable alerts', (
    tester,
  ) async {
    final core = _HomeMonitorCore();
    await tester.pumpWidget(DeviceBridgeApp(core: core));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('home-signal-ssh')), findsOneWidget);
    expect(find.text('On · 1 active'), findsOneWidget);
    expect(find.text('On · 2 active'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('2 pending device pairing request(s)'),
      120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('home-dashboard')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('2 pending device pairing request(s)'), findsOneWidget);
    expect(find.text('Mobile data active (metered)'), findsNothing);
    expect(find.text('SSH status & connections'), findsNothing);
    expect(find.text('Agent & app connections'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('home-traffic-monitor')),
      -120,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('home-dashboard')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('RX rate'), findsOneWidget);
    expect(find.text('TX rate'), findsOneWidget);

    await tester.tap(find.text('Devices').last);
    await tester.pumpAndSettle();
    expect(find.text('Pending Phone'), findsOneWidget);
    expect(find.text('Pending Tablet'), findsOneWidget);
    expect(find.text('Expired Phone'), findsNothing);
  });

  testWidgets('Home keeps saved SSH targets out of the listener summary', (
    tester,
  ) async {
    final core = _TailnetFailoverCore(approved: true);
    addTearDown(core.events.close);
    core.savedPeerSsh['laptop'] = {
      'host': 'laptop.local',
      'port': 2222,
      'user': 'owner',
    };
    await tester.pumpWidget(DeviceBridgeApp(core: core));
    await tester.pumpAndSettle();
    expect(find.text('owner@laptop.local:2222'), findsNothing);
    expect(find.text('OpenSSH · :8022'), findsOneWidget);
    expect(find.byTooltip('SSH settings'), findsOneWidget);
  });

  testWidgets('Matte paper and AMOLED themes render cleanly', (tester) async {
    final core = FakeCore();
    await tester.pumpWidget(DeviceBridgeApp(core: core));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    expect(find.text('AMOLED'), findsOneWidget);
    expect(find.text('Matte'), findsOneWidget);
    expect(find.text('AMOLED black · Neon green'), findsNothing);
    expect(find.text('Edit Matte theme…'), findsNothing);

    await tester.tap(find.text('AMOLED'));
    await tester.pumpAndSettle();
    expect(find.text('AMOLED editor'), findsOneWidget);
    await tester.tap(find.text('Cyber cyan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activate'));
    await tester.pumpAndSettle();
    expect(
      (core.settings['amoled_config'] as String?)?.contains('edge_color'),
      isTrue,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Matte'));
    await tester.pumpAndSettle();
    expect(find.text('Matte editor'), findsOneWidget);
    expect(find.text('Use defaults'), findsOneWidget);
    await tester.tap(find.byTooltip('Add bird'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use defaults'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Foreground'));
    await tester.tap(find.byTooltip('Add bird'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(
      (core.settings['matte_items'] as String?)?.contains('"foreground":true'),
      isTrue,
    );
    expect(find.byKey(const ValueKey('home-dashboard')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'File manager side-by-side panes, method switch, and interrupted connection resume',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final core = _InterruptibleCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
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
      await tester.pump();
      core.emitProgress({'verified_bytes': 1048576, 'total_bytes': 2097152});
      core.emitProgress({'transfer_state': 'waiting'});
      await tester.pump();
      expect(find.text('Waiting for connection…'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0.5,
      );
      core.emitProgress({
        'transfer_state': 'metered',
        'transport': 'tailnet',
        'approval_id': 'active-download',
      });
      await tester.pump();
      expect(find.textContaining('mobile or metered data'), findsOneWidget);
      expect(find.text('Choose another connection'), findsOneWidget);
      expect(core.approvals, isEmpty);
      await tester.tap(find.text('Use data for this download'));
      await tester.pump();
      expect(core.approvals, ['active-download']);
      expect(find.text('Use data for this download'), findsNothing);
      core.emitProgress({'transfer_state': 'resuming', 'transport': 'lan'});
      await tester.pump();
      expect(find.textContaining('Resuming over Wi-Fi'), findsOneWidget);
      core.emitProgress({'transfer_state': 'waiting'});
      await tester.pump();
      await tester.tap(find.text('Choose another connection'));
      await tester.pumpAndSettle();
      expect(find.text('Connections'), findsWidgets);
      expect(find.text('Current connection'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('overview-transport-choice')),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Resume downloading "hello.txt"'), findsOneWidget);
      expect(find.text('Choose a connection'), findsOneWidget);

      // Resume through a verified route without offering unsupported manual routes.
      core.failPull = false;
      await tester.tap(find.text('Choose a connection'));
      await tester.pumpAndSettle();
      expect(find.text('ADB over USB'), findsNothing);
      await tester.ensureVisible(find.text('Use selected connection'));
      await tester.tap(find.text('Use selected connection'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Verified download (direct)'), findsOneWidget);
      expect(find.textContaining('Via Wi-Fi LAN'), findsOneWidget);
      final pulls = core.calls
          .where((call) => call.first == 'pull-tar')
          .toList();
      expect(pulls, hasLength(2));
      expect(pulls.first[4], pulls.last[4]);
    },
  );
  registerMultiPathAndSshTests();
  mainAdditionalTests();
}

class _AutomaticPairingCore extends FakeCore {
  bool approved = false;
  bool completed = false;
  int finishAttempts = 0;

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    if (arguments.first == 'peers') {
      return [
        {
          'id': 'request-1',
          'name': 'Inviting phone',
          'status': completed ? 'paired' : 'outbound',
        },
      ];
    }
    if (arguments.first == 'finish') {
      finishAttempts++;
      if (!approved) throw StateError('remote approval still pending');
      completed = true;
      return {'status': 'paired'};
    }
    return super.run(arguments, input: input);
  }
}

class _NearbyPairingCore extends FakeCore {
  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    if (arguments.first == 'discover') {
      return [
        {
          'device_id': List.filled(64, 'b').join(),
          'device_name': 'Nearby phone',
          'endpoint': '192.168.50.5:42231',
        },
      ];
    }
    if (arguments.first == 'invite') {
      return {
        'version': 1,
        'id': List.filled(64, 'a').join(),
        'name': 'This phone',
        'token': List.filled(43, 'd').join(),
        'expires': DateTime.now()
            .add(const Duration(minutes: 5))
            .toUtc()
            .toIso8601String(),
        'lan_endpoint': '192.168.50.9:43210',
      };
    }
    return super.run(arguments, input: input);
  }
}

class _InterruptibleCore extends FakeCore {
  bool failPull = true;
  String activeTransport = 'lan';
  final initialPull = Completer<void>();
  final approvals = <String>[];

  @override
  Future<void> allowMeteredPull(String approvalId) async {
    approvals.add(approvalId);
  }

  @override
  Future<void> cancel() async {
    if (!initialPull.isCompleted) initialPull.complete();
  }

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    calls.add(arguments);
    if (arguments.first == 'connection' &&
        arguments.length > 2 &&
        arguments[2] == '-') {
      final selected = jsonDecode(input!) as Map<String, dynamic>;
      activeTransport = selected['transport'] as String;
      return selected;
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
        await initialPull.future;
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

class _DisconnectedUsbCore extends FakeCore {
  @override
  Future<Map<String, dynamic>> platformCapabilities() async => {
    ...await super.platformCapabilities(),
    'usb_adb': false,
    'usb_adb_connected': false,
  };
}

class _RoamedWifiCore extends FakeCore {
  bool approvedNewSubnet = false;
  @override
  Map<String, dynamic>? get network => approvedNewSubnet
      ? {
          'interface': 'wlan0',
          'cidr': '10.100.102.55/24',
          'kind': 'wifi',
          'unmetered': true,
        }
      : {
          'interface': 'wlan0',
          'cidr': '192.168.50.2/24',
          'kind': 'wifi',
          'unmetered': true,
        };

  @override
  Future<List<Map<String, dynamic>>> networks() async => [
    {
      'interface': 'wlan0',
      'cidr': '10.100.102.55/24',
      'kind': 'wifi',
      'unmetered': true,
    },
  ];

  @override
  Future<void> approveNetwork(Map<String, dynamic> network) async {
    if (network['cidr'] == '10.100.102.55/24') {
      approvedNewSubnet = true;
    }
  }

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    calls.add(arguments);
    if (_cliCmd(arguments) == 'resolve') {
      final tr = _flagVal(arguments, '--transport');
      if (tr != null && tr != 'lan') {
        throw StateError('$tr unreachable');
      }
      final cidrIdx = arguments.indexOf('--lan-cidr');
      final lanCidr = cidrIdx >= 0 && cidrIdx + 1 < arguments.length
          ? arguments[cidrIdx + 1]
          : (network?['cidr'] ?? '');
      if (lanCidr != '10.100.102.55/24') {
        throw StateError('Device unreachable on stale Wi-Fi $lanCidr');
      }
      return {
        'transport': 'lan',
        'endpoint': '10.100.102.12:8731',
        'discovery_name': 'new-wifi',
        'rtt': 1400000,
      };
    }
    return super.run(arguments, input: input);
  }
}

void mainAdditionalTests() {
  testWidgets(
    'Settings shows Root features, Shizuku features submenus and Go core version/hot-swap',
    (tester) async {
      final core = FakeCore();
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(core: core)));
      await tester.pumpAndSettle();

      expect(find.textContaining('Go core v1.4.0'), findsWidgets);
      await tester.scrollUntilVisible(find.text('Root features'), 200);
      await tester.tap(find.text('Root features'));
      await tester.pumpAndSettle();
      expect(find.text('Root direct-link control'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(find.text('Shizuku features'), 200);
      await tester.tap(find.text('Shizuku features'));
      await tester.pumpAndSettle();
      expect(find.text('Shizuku automated Wi-Fi join'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Reload from Flutter assets'),
        200,
      );
      expect(find.text('Reload from Flutter assets'), findsOneWidget);
    },
  );

  testWidgets(
    'ADB over USB is hidden when USB is disconnected even on offline peer',
    (tester) async {
      final core = _DisconnectedUsbCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();

      expect(find.text('ADB over USB'), findsNothing);
    },
  );

  testWidgets(
    'DeviceDetail recovers on new Wi-Fi subnet and displays Wi-Fi instead of Direct Wi-Fi LAN',
    (tester) async {
      final core = _RoamedWifiCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();

      expect(core.approvedNewSubnet, isTrue);
      expect(find.text('Connected via Wi-Fi'), findsOneWidget);
      expect(find.textContaining('10.100.102.12:8731'), findsWidgets);
    },
  );

  testWidgets(
    'Overview speed test updates without re-probing and shows the direct link channel',
    (tester) async {
      final core = _WifiDirectRadioInfoCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Ch 149 (5745 MHz)'), findsWidgets);

      final resolvesBefore = core.calls
          .where((c) => c.contains('resolve'))
          .length;
      await tester.ensureVisible(
        find.byKey(const ValueKey('overview-speed-test')),
      );
      await tester.tap(find.byKey(const ValueKey('overview-speed-test')));
      await tester.pumpAndSettle();
      final resolvesAfter = core.calls
          .where((c) => c.contains('resolve'))
          .length;

      expect(find.textContaining('Speed test · 110.0 MiB'), findsOneWidget);
      expect(resolvesAfter, resolvesBefore);
    },
  );

  testWidgets(
    'DeviceBridge Wiki shows privilege strategies, battery efficiency badges, file access, channel guide, and Termux targetSdk guide',
    (tester) async {
      final core = FakeCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();

      // Redundant Wiki icon was removed from top AppBar; Wiki remains on Home & Settings.
      expect(find.byTooltip('Wiki & architecture'), findsNothing);
      await tester.tap(find.text('Wiki'));
      await tester.pumpAndSettle();

      expect(find.text('DeviceBridge Wiki'), findsOneWidget);
      expect(
        find.text('Privilege Modes & Required Permissions'),
        findsOneWidget,
      );
      final wikiScroll = find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text(
          'What Root adds over Shizuku & Standard (Efficiency, Battery & Extra Features)',
        ),
        200,
        scrollable: wikiScroll,
      );
      expect(
        find.text(
          'What Root adds over Shizuku & Standard (Efficiency, Battery & Extra Features)',
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('What Shizuku adds over Standard mode'),
        200,
        scrollable: wikiScroll,
      );
      expect(find.text('What Shizuku adds over Standard mode'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Same speed & battery without Root or Shizuku'),
        200,
        scrollable: wikiScroll,
      );
      expect(
        find.text('Same speed & battery without Root or Shizuku'),
        findsOneWidget,
      );

      // Topic chips live at the top of the wiki list; jump there directly so
      // navigation is independent of section content height and hit testing.
      tester.state<ScrollableState>(wikiScroll).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Connections & Battery'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(
          'Direct Link Channels, Width (80 vs 160 MHz) & Regulatory Domains',
        ),
        200,
        scrollable: wikiScroll,
      );
      expect(
        find.text(
          'Direct Link Channels, Width (80 vs 160 MHz) & Regulatory Domains',
        ),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('ADB over USB (Wired)'),
        -200,
        scrollable: wikiScroll,
      );
      expect(find.text('ADB over USB (Wired)'), findsOneWidget);
      expect(find.text('Most Battery Friendly'), findsOneWidget);
      expect(find.text('Privilege Modes & Required Permissions'), findsNothing);
      tester.state<ScrollableState>(wikiScroll).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('File Access'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('All Files Access (MANAGE_EXTERNAL_STORAGE)'),
        200,
        scrollable: wikiScroll,
      );
      expect(
        find.text('All Files Access (MANAGE_EXTERNAL_STORAGE)'),
        findsOneWidget,
      );
      expect(find.text('Most Efficient Shared Storage'), findsOneWidget);

      tester.state<ScrollableState>(wikiScroll).position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Binaries & Termux'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Termux: targetSdk 28'),
        200,
        scrollable: wikiScroll,
      );
      expect(find.text('Termux: targetSdk 28'), findsOneWidget);
      expect(find.text('DeviceBridge: targetSdk 28'), findsOneWidget);
    },
  );

  testWidgets(
    'LocalCore downloads is safe before initialize and AMOLED<->Matte transitions do not throw',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      expect(LocalCore().downloads, contains('Initializing'));

      final core = FakeCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AMOLED'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Activate'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Matte'));
      // Pump mid-transition frames between Dark AMOLED and Light Matte themes.
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Matte editor'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  test('LocalCore.mergeNetworkEvent keeps the direct stamp only while the same joined network is selected', () {
    const joined = {
      'interface': 'wlan0',
      'cidr': '192.168.49.64/24',
      'network_handle': '570341380109',
      'kind': 'wifi_direct',
      'direct': true,
    };
    const rawEvent = {
      'interface': 'wlan0',
      'cidr': '192.168.49.64/24',
      'network_handle': '570341380109',
      'kind': 'wifi',
    };
    final kept = LocalCore.mergeNetworkEvent(joined, rawEvent);
    expect(kept['kind'], 'wifi_direct');
    expect(kept['direct'], true);
    expect(kept['network_handle'], '570341380109');

    const router = {
      'interface': 'wlan0',
      'cidr': '192.168.1.10/24',
      'network_handle': '100',
      'kind': 'wifi',
    };
    final restored = LocalCore.mergeNetworkEvent(joined, router);
    expect(restored['kind'], 'wifi');
    expect(restored['direct'], isNull);
    expect(LocalCore.mergeNetworkEvent(null, rawEvent)['kind'], 'wifi');
    const plain = {
      'interface': 'wlan0',
      'cidr': '192.168.49.64/24',
      'kind': 'wifi',
    };
    expect(LocalCore.mergeNetworkEvent(plain, rawEvent)['kind'], 'wifi');
  });

  testWidgets(
    'Direct link displays its running channel and manual settings and allows selecting Ch 161 / 80 MHz',
    (tester) async {
      final core = _WifiDirectRadioInfoCore();
      await tester.pumpWidget(
        MaterialApp(
          home: DeviceDetail(
            core: core,
            peer: const {
              'id': 'laptop',
              'name': 'Laptop',
              'status': 'paired',
              'capabilities': {
                'os': 'linux',
                'wifi_5ghz': true,
                'wifi_6': true,
                'wifi_direct': true,
                'hotspot_ap': true,
                'hotspot_5ghz_ap': true,
                'hotspot_sta': true,
                'usable_5ghz_channels': [165, 161, 157, 153, 149],
                'reg_country': 'PK',
                'reg_5ghz_limited': true,
              },
              'addresses': [
                {'endpoint': '192.168.49.161:8731'},
              ],
            },
            registry: FeatureRegistry()..register(RemoteFilesFeature()),
            candidates: const [],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Ch 149 (5745 MHz)'), findsWidgets);
      await tester.tap(find.widgetWithText(Tab, 'Connections'));
      await tester.pumpAndSettle();

      // Channel & width picker opens from the manual connections gear and notes Linux regdom.
      await tester.scrollUntilVisible(
        find.byTooltip('Connection settings (channel & width)'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Connection settings (channel & width)'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('sudo iw reg set US'),
        findsAtLeastNWidgets(1),
      );
      await tester.ensureVisible(find.text('Ch 161 (5805 MHz)'));
      await tester.tap(find.text('Ch 161 (5805 MHz)'));
      await tester.ensureVisible(find.text('80 MHz'));
      await tester.tap(find.text('80 MHz'));
      await tester.ensureVisible(find.text('Apply'));
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('Direct link channel & width'), findsNothing);
      expect(
        find.textContaining('Ch 161 (5805 MHz) · 80 MHz'),
        findsAtLeastNWidgets(1),
      );
    },
  );

  testWidgets(
    'AMOLED white selectedTabColor & buttonColor render solid white background and black inner icon/text without green edge bleed',
    (tester) async {
      const cfg = AmoledStyleConfig(
        edgeColor:
            0xff00b848, // green edge must NOT bleed into white button/tab
        peakColor: 0xff1cff68,
        lineWidth: 2.0,
        centerGlow: 0.35,
        selectedTabColor: 0xffffffff,
        buttonColor: 0xffffffff,
        popupBorderColor: 0xffffffff,
        selectedTextColor:
            0xffffffff, // even if user selected white text, contrasts to black!
      );
      final theme = amoledTheme('amoled', config: cfg);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  amoledNavIcon(context, Icons.home, 'amoled', config: cfg),
                  FilledButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.bolt),
                    label: const Text('Primary action'),
                  ),
                  FilterChip(
                    label: const Text('Auto-root'),
                    selected: true,
                    onSelected: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Selected FilterChip ('Auto-root') uses black text/checkmark and white button border (not green).
      final chipRichText = tester.widget<RichText>(
        find.descendant(
          of: find.widgetWithText(FilterChip, 'Auto-root'),
          matching: find.byType(RichText),
        ),
      );
      expect(chipRichText.text.style?.color, Colors.black);
      expect(theme.chipTheme.checkmarkColor, Colors.black);
      final chipBorder = theme.chipTheme.side is WidgetStateBorderSide
          ? (theme.chipTheme.side! as WidgetStateBorderSide).resolve({
              WidgetState.selected,
            })
          : theme.chipTheme.side;
      expect(chipBorder?.color, Colors.white);

      // Nav pill uses solid white decoration (not gradient mixed with green edge) & black icon.
      final navPill = tester.widget<Container>(find.byType(Container).first);
      final navDec = navPill.decoration! as BoxDecoration;
      expect(navDec.color, Colors.white);
      expect(navDec.gradient, isNull);
      final navIcon = tester.widget<Icon>(find.byIcon(Icons.home));
      expect(navIcon.color, Colors.black);

      // FilledButton uses solid white fill (not green edge gradient) and black text/icon.
      final btnDecs = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where((d) => d.decoration is BoxDecoration)
          .map((d) => d.decoration as BoxDecoration)
          .where((bd) => bd.borderRadius == BorderRadius.circular(24))
          .toList();
      expect(btnDecs, isNotEmpty);
      expect(btnDecs.first.color, Colors.white);
      expect(btnDecs.first.gradient, isNull);
      final fg = theme.filledButtonTheme.style!.foregroundColor!.resolve({});
      expect(fg, Colors.black);

      // Also check Monochrome white preset inside AmoledThemeEditor.
      await tester.pumpWidget(
        MaterialApp(
          home: AmoledThemeEditor(
            initialConfig: AmoledStyleConfig.defaults(),
            onSave: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Monochrome white'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Selecting AMOLED twice (edit + cancel/back) keeps Home visible and interactive cleanly',
    (tester) async {
      final core = FakeCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();

      // First AMOLED selection -> edit preset -> Activate
      await tester.tap(find.byTooltip('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AMOLED'));
      await tester.pumpAndSettle();
      expect(find.text('AMOLED editor'), findsOneWidget);
      await tester.tap(find.text('Monochrome white'));
      await tester.tap(find.text('Activate'));
      await tester.pumpAndSettle();

      expect(find.text('DeviceBridge'), findsOneWidget);
      expect(find.byTooltip('Appearance'), findsOneWidget);

      // Second AMOLED selection -> back without editing
      await tester.tap(find.byTooltip('Appearance'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AMOLED'));
      await tester.pumpAndSettle();
      expect(find.text('AMOLED editor'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.text('DeviceBridge'), findsOneWidget);
      expect(find.byKey(const ValueKey('home-dashboard')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Orphaned Wi-Fi Direct can be stopped from Connections', (
    tester,
  ) async {
    final core = _OrphanedWifiDirectFakeCore()..tailnetReachable = true;
    final reg = FeatureRegistry()..register(RemoteFilesFeature());
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceDetail(
          core: core,
          peer: const {
            'id': 'peer-1',
            'name': 'probook-450-g9',
            'status': 'approved',
          },
          registry: reg,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Tab, 'Connections'));
    await tester.pumpAndSettle();

    expect(find.text('Wi-Fi Direct (Open)'), findsOneWidget);
    expect(find.text('Wi-Fi Direct'), findsNothing);
    expect(find.text('Keep open link'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Stop'), findsOneWidget);
    // Stopping tears down the orphaned Wi-Fi Direct link and restores the Create option.
    await tester.scrollUntilVisible(
      find.widgetWithText(OutlinedButton, 'Stop'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
    await tester.pumpAndSettle();
    expect(core.stopCalls, 1);
    expect(find.text('Wi-Fi Direct (Open)'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Wi-Fi Direct'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Wi-Fi Direct'), findsOneWidget);
  });

  testWidgets(
    'Global Debug & flow tracker toggle persists and Debug & flow log captures errors, flows, and screen routes',
    (tester) async {
      await DebugTrace.clear();
      DebugTrace.setEnabled(true);
      final core = FakeCore();
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [DebugNavigatorObserver()],
          home: SettingsScreen(core: core),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll down to App behavior -> Debug & flow tracker
      await tester.scrollUntilVisible(
        find.text('DeviceBridge Wiki'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Debug & flow log'));
      await tester.pumpAndSettle();
      expect(find.text('Debug & flow tracker'), findsOneWidget);

      DebugTrace.logError(
        'DirectLink',
        'Simulated join error',
        error: 'nmcli test',
      );
      DebugTrace.logFlow('DeviceDetail', 'Simulated wifi_direct step');

      await tester.tap(find.text('Debug & flow log'));
      await tester.pumpAndSettle();

      expect(find.text('Debug & Flow Tracker'), findsOneWidget);
      expect(find.textContaining('Simulated join error'), findsOneWidget);
      expect(find.textContaining('Simulated wifi_direct step'), findsOneWidget);

      // Go back and toggle debug_mode off -> persisted in core.settings & stops recording new events.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, 200));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.widgetWithText(SwitchListTile, 'Debug & flow tracker'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Debug & flow tracker'));
      await tester.pumpAndSettle();
      expect(core.settings['debug_mode'], isFalse);
      final countBefore = DebugTrace.instance.entries.length;
      DebugTrace.logError('DirectLink', 'Should not record while off');
      expect(DebugTrace.instance.entries.length, countBefore);
      DebugTrace.setEnabled(true);
    },
  );

  testWidgets(
    'Remote host hotspot pre-sends credentials and connects cleanly on starting response',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _LaptopStartingHotspotCore();
      await tester.pumpWidget(
        MaterialApp(
          home: DeviceDetail(
            core: core,
            peer: const {
              'id': 'laptop',
              'name': 'Laptop',
              'status': 'paired',
              'capabilities': {
                'os': 'android',
                'wifi_5ghz': true,
                'wifi_6': true,
                'hotspot_ap': true,
                'hotspot_5ghz_ap': true,
                'hotspot_sta': true,
              },
            },
            registry: FeatureRegistry()..register(RemoteFilesFeature()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Connections'));
      await tester.pumpAndSettle();

      final connScroll = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Wi-Fi Hotspot'),
        200,
        scrollable: connScroll,
      );
      final hsTile = find.ancestor(
        of: find.text('Wi-Fi Hotspot'),
        matching: find.byType(ListTile),
      );
      final phoneBtn = find.descendant(
        of: hsTile,
        matching: find.text('Phone (5 GHz)'),
      );
      await tester.ensureVisible(phoneBtn);
      await tester.pumpAndSettle();
      await tester.tap(phoneBtn);
      await tester.pump(const Duration(milliseconds: 1400));
      await tester.pumpAndSettle();

      expect(core.sentSsid, startsWith('DB-AP-'));
      expect(core.sentPassphrase.length, 16);
      expect(core.joinedSsid, core.sentSsid);
      await tester.drag(connScroll, const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'Stop'), findsOneWidget);

      // Overview tab also provides a direct 'Stop link' action
      await tester.tap(find.widgetWithText(Tab, 'Overview'));
      await tester.pumpAndSettle();
      expect(find.textContaining('10.42.0.1:8731'), findsWidgets);
      expect(find.textContaining('10.100.102.39:8731'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Stop link'), findsOneWidget);

      // Tapping Stop link sends restore to peer and restores standard Wi-Fi
      await tester.tap(find.widgetWithText(OutlinedButton, 'Stop link'));
      await tester.pump(const Duration(milliseconds: 1400));
      await tester.pumpAndSettle();
      expect(core.restoreCalled, isTrue);
      expect(find.text('Connected via Wi-Fi'), findsOneWidget);
    },
  );

  testWidgets('A resumed laptop hotspot has a host-specific connection label', (
    tester,
  ) async {
    final core = _LaptopStartingHotspotCore(resumedLaptopHotspot: true);
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceDetail(
          core: core,
          peer: const {'id': 'phone', 'name': 'Phone', 'status': 'paired'},
          registry: FeatureRegistry()..register(RemoteFilesFeature()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Connected via Laptop Hotspot'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, 'Connections'));
    await tester.pumpAndSettle();
    expect(find.text('Laptop Hotspot'), findsWidgets);
    expect(find.text('Connection details'), findsNothing);
  });

  testWidgets(
    'Reconnect joins the saved laptop hotspot and verifies its peer',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _LaptopStartingHotspotCore(savedLaptopHotspot: true)
        ..tailnetEnabled = true;
      await tester.pumpWidget(
        MaterialApp(
          home: DeviceDetail(
            core: core,
            peer: const {'id': 'laptop', 'name': 'Laptop', 'status': 'paired'},
            registry: FeatureRegistry()..register(RemoteFilesFeature()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Connections'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Reconnect'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reconnect'));
      await tester.pumpAndSettle();
      expect(core.joinedSsid, 'DB-AP-saved');
      await tester.tap(find.widgetWithText(Tab, 'Overview'));
      await tester.pumpAndSettle();
      expect(find.text('Connected via Laptop Hotspot'), findsOneWidget);
      expect(find.text('Saved Laptop Hotspot'), findsNothing);
    },
  );

  testWidgets('Tailscale appears after the sidecar finishes starting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = FakeCore()
      ..tailnetEnabled = true
      ..tailnetReachable = true
      ..tailnetStartupFailures = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceDetail(
          core: core,
          peer: const {'id': 'laptop', 'name': 'Laptop', 'status': 'paired'},
          registry: FeatureRegistry()..register(RemoteFilesFeature()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('overview-transport-choice')));
    await tester.pumpAndSettle();
    expect(find.text('Tailscale'), findsOneWidget);
    expect(find.textContaining('via Direct'), findsOneWidget);
  });

  testWidgets('Configured Tailscale stays visible when Wi-Fi returns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = _TailnetFailoverCore(approved: false);
    addTearDown(core.events.close);
    await tester.pumpWidget(
      MaterialApp(
        home: DeviceDetail(
          core: core,
          peer: const {'id': 'laptop', 'name': 'Laptop', 'status': 'paired'},
          registry: FeatureRegistry()..register(RemoteFilesFeature()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    core.tailnetReachable = false;
    core.events.add({'tailnet_network_changed': true});
    core.events.add({'state': 'active', 'network': core.network});
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('overview-transport-choice')));
    await tester.pumpAndSettle();
    expect(find.text('Tailscale'), findsNothing);
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await tester.pumpAndSettle();
    core.tailnetReachable = true;
    core.events.add({'tailnet_network_changed': true});
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('overview-transport-choice')));
    await tester.pumpAndSettle();
    expect(find.text('Tailscale'), findsOneWidget);
    expect(core.connection['remote_approved'], isFalse);
  });

  testWidgets(
    'Returning peer promotes Tailscale to direct without a local network event',
    (tester) async {
      final core = _TailnetFailoverCore(approved: false)..peerOnLan = false;
      addTearDown(core.events.close);
      core.connection['preferred_link'] = 'wifi';
      await tester.pumpWidget(
        MaterialApp(
          home: DeviceDetail(
            core: core,
            peer: const {'id': 'laptop', 'name': 'Laptop', 'status': 'paired'},
            registry: FeatureRegistry(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(core.connection['transport'], 'tailnet');
      core.peerOnLan = true;
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(core.connection['transport'], 'lan');
      expect(core.connection['preferred_link'], 'wifi');
      expect(core.connection['remote_approved'], isFalse);
    },
  );

  for (final approved in [true, false]) {
    testWidgets(
      'Verified Tailscale fallback preserves remote bulk consent ($approved)',
      (tester) async {
        tester.view.physicalSize = const Size(900, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final core = _TailnetFailoverCore(approved: approved);
        addTearDown(core.events.close);
        await tester.pumpWidget(
          MaterialApp(
            home: DeviceDetail(
              core: core,
              peer: const {
                'id': 'laptop',
                'name': 'Laptop',
                'status': 'paired',
              },
              registry: FeatureRegistry()..register(RemoteFilesFeature()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        core.wifi = false;
        core.tailnetStartupFailures = 1;
        core.events.add({'state': 'offline', 'network': null});
        core.events.add({'tailnet_network_changed': true});
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();

        expect(find.text('Transport · Tailscale'), findsOneWidget);
        expect(core.connection['transport'], 'tailnet');
        expect(core.connection['preferred_transport'], 'lan');
        expect(core.connection['remote_approved'], approved);
        core.wifi = true;
        core.tailnetStartingResponses = 1;
        core.events.add({'state': 'active', 'network': core.network});
        core.events.add({'tailnet_network_changed': true});
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(core.connection['transport'], 'lan');
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
        expect(core.connection['transport'], 'lan');

        await tester.tap(
          find.byKey(const ValueKey('overview-transport-choice')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.text('Tailscale'),
          ),
        );
        await tester.pumpAndSettle();
        core.events.add({'state': 'active', 'network': core.network});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        expect(core.connection['preferred_transport'], 'tailnet');
        expect(core.connection['transport'], 'tailnet');
      },
    );
  }

  for (final remoteOS in ['linux', 'android']) {
    testWidgets('Unshared transports stay hidden for an $remoteOS peer', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _UnsharedRoutesCore(remoteOS);
      await tester.pumpWidget(
        MaterialApp(
          home: DeviceDetail(
            core: core,
            peer: const {'id': 'laptop', 'name': 'Laptop', 'status': 'paired'},
            registry: FeatureRegistry()..register(RemoteFilesFeature()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Connections'));
      await tester.pumpAndSettle();
      expect(find.text('Tailscale'), findsNothing);
      expect(find.text('WireGuard'), findsNothing);
      expect(find.text('ADB over USB'), findsNothing);
      expect(find.text('Direct link setup'), findsNothing);
      expect(
        core.calls.where(
          (args) =>
              args.first == 'adb-forward-peer' || args.first == 'prepare-link',
        ),
        isEmpty,
      );
    });
  }
}

class _UnsharedRoutesCore extends FakeCore {
  _UnsharedRoutesCore(this.remoteOS) {
    tailnetEnabled = true;
  }

  final String remoteOS;

  @override
  Future<Map<String, dynamic>> platformCapabilities() async => {
    'os': 'android',
    'usb_adb_connected': true,
    'tailnet_enabled': true,
    'wifi_direct_go': true,
    'hotspot_ap': true,
  };

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    switch (_cliCmd(arguments)) {
      case 'tailnet':
        return {'state': 'NeedsLogin'};
      case 'wireguard':
        return {'configured': true, 'peers': []};
      case 'peer-caps':
        return {
          'capabilities': {'os': remoteOS, 'usb_adb': remoteOS == 'android'},
        };
      default:
        return super.run(arguments, input: input);
    }
  }
}

class _PendingThemeCore extends FakeCore {
  final theme = Completer<Map<String, dynamic>>();

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) {
    if (arguments.length == 1 && arguments.single == 'theme') {
      return theme.future;
    }
    return super.run(arguments, input: input);
  }
}

class _UninstallCore extends FakeCore {
  Map<String, dynamic>? uninstall;

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    switch (arguments.first) {
      case 'peer-ssh':
        return {
          'host': 'laptop',
          'user': 'owner',
          'port': 22,
          'expected_host_key': 'SHA256:saved-host-key',
        };
      case 'ssh-uninstall':
        expect(arguments, ['ssh-uninstall', 'laptop', '-']);
        uninstall = jsonDecode(input!) as Map<String, dynamic>;
        return {'status': 'uninstalled'};
      default:
        return super.run(arguments, input: input);
    }
  }
}

class _TailnetFailoverCore extends FakeCore {
  _TailnetFailoverCore({required bool approved})
    : connection = {
        'transport': 'lan',
        'remote_approved': approved,
        'fallback_approved': true,
        'fallback_transports': ['tailnet'],
        'tailnet_endpoint': '100.64.0.9:8731',
      } {
    tailnetEnabled = true;
    tailnetReachable = true;
  }

  final Map<String, dynamic> connection;
  final events = StreamController<Map<String, dynamic>>.broadcast();
  bool wifi = true;
  bool peerOnLan = true;

  @override
  Stream<Map<String, dynamic>> get networkEvents => events.stream;

  @override
  Map<String, dynamic>? get network => wifi ? super.network : null;

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    switch (_cliCmd(arguments)) {
      case 'connection':
        if (input != null) {
          connection.addAll(jsonDecode(input) as Map<String, dynamic>);
        }
        return Map<String, dynamic>.of(connection);
      case 'resolve' when _flagVal(arguments, '--transport') == 'tailnet':
        if (!tailnetReachable) throw StateError('Tailscale peer unreachable');
        return {
          'transport': 'tsnet-v1',
          'interface': '',
          'endpoint': '100.64.0.9:8731',
          'path_kind': 'derp',
          'relay': 'sin',
          'rtt': 42000000,
        };
      case 'resolve' when !wifi || !peerOnLan:
        throw StateError('Wi-Fi unavailable');
      default:
        return super.run(arguments, input: input);
    }
  }
}

class _LaptopStartingHotspotCore extends _StartableLinksCore {
  _LaptopStartingHotspotCore({
    this.resumedLaptopHotspot = false,
    this.savedLaptopHotspot = false,
  }) {
    activeTransport = 'lan';
    if (resumedLaptopHotspot) {
      _customNet['cidr'] = '10.42.0.10/24';
    }
  }

  final bool resumedLaptopHotspot;
  final bool savedLaptopHotspot;
  bool restoreCalled = false;
  String sentSsid = '';
  String sentPassphrase = '';
  String joinedSsid = '';
  Map<String, dynamic> _customNet = {
    'interface': 'wlan0',
    'cidr': '10.100.102.33/24',
    'kind': 'wifi',
  };

  @override
  Map<String, dynamic>? get network => _customNet;

  @override
  Future<void> approveNetwork(Map<String, dynamic> network) async {
    _customNet = Map<String, dynamic>.from(network);
    await super.approveNetwork(network);
  }

  @override
  Future<List<Map<String, dynamic>>> networks() async => [_customNet];

  @override
  Future<Map<String, dynamic>> activeDirectLink() async => {
    if (resumedLaptopHotspot) ..._customNet,
    'active': resumedLaptopHotspot,
    if (resumedLaptopHotspot) 'kind': 'hotspot',
    if (savedLaptopHotspot)
      'saved': {
        'kind': 'hotspot',
        'joined': true,
        'peer_id': 'laptop',
        'ssid': 'DB-AP-saved',
        'endpoint': '10.42.0.1:8731',
      },
  };

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
  }) async {
    assert(kind == 'wifi_join' && peerId == 'laptop');
    joinedSsid = ssid ?? '';
    _customNet['cidr'] = '10.42.0.10/24';
    return Map<String, dynamic>.from(_customNet);
  }

  @override
  Future<Map<String, dynamic>> platformCapabilities() async => {
    ...await super.platformCapabilities(),
    'os': 'linux',
    'hotspot_5ghz_ap': true,
  };

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    final cmd = _cliCmd(arguments);
    if (cmd == 'peer-caps') {
      return {
        'capabilities': {
          'os': 'android',
          'wifi_5ghz': true,
          'wifi_6': true,
          'hotspot_ap': true,
          'hotspot_5ghz_ap': true,
          'hotspot_sta': true,
        },
      };
    }
    if (cmd == 'prepare-link') {
      final body = jsonDecode(input ?? '{}') as Map;
      if (body['kind'] == 'link_status' && body['ssid'] == 'DB-AP-saved') {
        return {'ok': true, 'kind': 'hotspot', 'status': 'active'};
      }
      if (body['kind'] == 'hotspot') {
        sentSsid = '${body['ssid'] ?? ''}';
        sentPassphrase = '${body['passphrase'] ?? ''}';
        hotspotPrepared = true;
        return {
          'ok': true,
          'kind': 'hotspot',
          'transport': 'lan',
          'interface': 'wlan0',
          'ip': '10.42.0.1',
          'endpoint': '10.42.0.1:8731',
          'ssid': sentSsid,
          'passphrase': sentPassphrase,
          'band': '5 GHz',
          'channel': 161,
          'frequency_mhz': 5805,
          'status': 'starting',
        };
      }
    }
    if (cmd == 'wifi-join') {
      final body = jsonDecode(input ?? '{}') as Map;
      joinedSsid = '${body['ssid'] ?? ''}';
      hotspotJoined = true;
      _customNet['cidr'] = '10.42.0.10/24';
      return {
        'ok': true,
        'transport': 'lan',
        'interface': 'wlan0',
        'ip': '10.42.0.10',
        'cidr': '10.42.0.10/24',
        'endpoint': '10.42.0.10:8731',
        'band': '5 GHz',
      };
    }
    if (cmd == 'restore-link') {
      restoreCalled = true;
      _customNet = {
        'interface': 'wlan0',
        'cidr': '10.100.102.33/24',
        'kind': 'wifi',
      };
      return {'ok': true, 'kind': 'restore', 'status': 'restored'};
    }
    final tr = _flagVal(arguments, '--transport');
    if (cmd == 'resolve' && (tr == null || tr == 'lan')) {
      if (_flagVal(arguments, '--lan-cidr') == '10.42.0.10/24' ||
          _customNet['cidr'] == '10.42.0.10/24') {
        return {
          'transport': 'direct-lan-v1',
          'endpoint': '10.42.0.1:8731',
          'interface': 'wlan0',
          'rtt': 1600000,
          'mib_per_second': 95.0,
        };
      }
      if (_flagVal(arguments, '--lan-cidr') == '10.100.102.33/24' ||
          _customNet['cidr'] == '10.100.102.33/24') {
        return {
          'transport': 'direct-lan-v1',
          'endpoint': '10.100.102.39:8731',
          'interface': 'wlan0',
          'rtt': 2100000,
          'mib_per_second': 32.0,
        };
      }
    }
    return super.run(arguments, input: input);
  }
}

class _WifiDirectRadioInfoCore extends FakeCore {
  @override
  Future<Map<String, dynamic>> platformCapabilities() async => {
    ...await super.platformCapabilities(),
    'os': 'linux',
    'hotspot_5ghz_ap': true,
    'usable_5ghz_channels': [165, 161, 157, 153, 149],
    'reg_country': 'PK',
    'reg_5ghz_limited': true,
  };

  @override
  Map<String, dynamic>? get network => {
    'interface': 'p2p-wlan0-0',
    'cidr': '192.168.49.1/24',
    'kind': 'wifi_direct',
  };

  @override
  Future<List<Map<String, dynamic>>> networks() async => [
    {
      'interface': 'p2p-wlan0-0',
      'cidr': '192.168.49.1/24',
      'kind': 'wifi_direct',
    },
  ];

  @override
  Future<Map<String, dynamic>> linkDetails({String interfaceName = ''}) async =>
      {
        'interface': 'p2p-wlan0-0',
        'band': '5 GHz',
        'frequency_mhz': 5745,
        'wifi_standard': '',
      };

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    calls.add(arguments);
    final cmd = _cliCmd(arguments);
    if (cmd == 'resolve') {
      final tr = _flagVal(arguments, '--transport');
      if (tr != null && tr != 'lan') {
        throw StateError('$tr unreachable');
      }
      return {
        'transport': 'direct-lan-v1',
        'endpoint': '192.168.49.161:8731',
        'interface': 'p2p-wlan0-0',
        'rtt': 2200000,
      };
    }
    if (cmd == 'peer-caps') {
      return {
        'capabilities': {
          'os': 'linux',
          'wifi_5ghz': true,
          'wifi_6': true,
          'wifi_direct': true,
          'hotspot_ap': true,
          'hotspot_5ghz_ap': true,
          'hotspot_sta': true,
          'usable_5ghz_channels': [165, 161, 157, 153, 149],
          'reg_country': 'PK',
          'reg_5ghz_limited': true,
          'link': {
            'interface': 'wlan0',
            'band': '5 GHz',
            'frequency_mhz': 5745,
            'bandwidth_mhz': 80,
            'wifi_standard': 'Wi-Fi 6 (802.11ax)',
          },
        },
      };
    }
    if (cmd == 'speedtest') {
      return {'mib': 110.0, 'seconds': 5.0, 'mib_per_second': 22.0};
    }
    return super.run(arguments, input: input);
  }
}

class _OrphanedWifiDirectFakeCore extends FakeCore {
  bool directOpen = true;
  int stopCalls = 0;
  final List<String> approvedIfaces = [];
  Map<String, dynamic> _net = {
    'interface': 'wlan0',
    'cidr': '10.100.102.33/24',
    'kind': 'wifi',
  };

  @override
  Map<String, dynamic>? get network => _net;

  @override
  Future<List<Map<String, dynamic>>> networks() async => [
    if (directOpen)
      {
        'interface': 'p2p-p2p0-0',
        'cidr': '192.168.49.1/24',
        'kind': 'wifi_direct',
      },
    {'interface': 'wlan0', 'cidr': '10.100.102.33/24', 'kind': 'wifi'},
  ];

  @override
  Future<void> approveNetwork(Map<String, dynamic> network) async {
    approvedIfaces.add('${network['interface'] ?? ''}');
    _net = Map<String, dynamic>.from(network);
  }

  @override
  Future<Map<String, dynamic>> activeDirectLink() async => directOpen
      ? {
          'active': true,
          'resumed': true,
          'kind': 'wifi_direct',
          'interface': 'p2p-p2p0-0',
          'ip': '192.168.49.1',
          'cidr': '192.168.49.1/24',
          'endpoint': '192.168.49.1:8731',
          'ssid': 'DIRECT-DB-abbf',
          'passphrase': '', // tests unconnected local-keep path
          'band': '5 GHz',
          'channel': 149,
          'frequency_mhz': 5745,
          'bandwidth_mhz': 80,
        }
      : {'active': false};

  @override
  Future<Map<String, dynamic>> stopDirectLink({bool forget = true}) async {
    stopCalls++;
    directOpen = false;
    _net = {'interface': 'wlan0', 'cidr': '10.100.102.33/24', 'kind': 'wifi'};
    return {'ok': true, 'status': 'restored'};
  }

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    calls.add(arguments);
    final cmd = _cliCmd(arguments);
    if (cmd == 'resolve' && _flagVal(arguments, '--transport') != 'tailnet') {
      final iface =
          _flagVal(arguments, '--interface') ?? '${_net['interface'] ?? ''}';
      if (iface.startsWith('p2p')) {
        throw StateError('peer not connected to p2p');
      }
      return {
        'transport': 'direct-lan-v1',
        'endpoint': '10.100.102.12:8731',
        'interface': 'wlan0',
        'rtt': 1800000,
        'capabilities': {
          'os': 'android',
          'wifi_5ghz': true,
          'wifi_direct': true,
          'wifi_direct_go': true,
          'hotspot_ap': true,
          'hotspot_sta': true,
          'tailnet_endpoint': '100.64.0.9:8731',
        },
      };
    }
    if (cmd == 'peer-caps') {
      return {
        'capabilities': {
          'os': 'android',
          'wifi_5ghz': true,
          'wifi_6': true,
          'wifi_direct': true,
          'wifi_direct_go': true,
          'hotspot_ap': true,
          'hotspot_5ghz_ap': true,
          'hotspot_sta': true,
        },
      };
    }
    return super.run(arguments, input: input);
  }
}

class _MultiPathCore extends FakeCore {
  String activeTransport = 'tailnet';
  final peerCapabilities = {'os': 'android', 'usb_adb': true};

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    calls.add(arguments);
    final cmd = _cliCmd(arguments);
    final tr = _flagVal(arguments, '--transport');
    if (cmd == 'ssh-probe') {
      return {
        'host': arguments[1],
        'port': int.tryParse(arguments.length > 2 ? arguments[2] : '22') ?? 22,
        'host_key_sha256': 'SHA256:probookhostkey',
        'key_type': 'ssh-ed25519',
        'resolved_host': '100.100.78.84',
        'via_tailnet': true,
      };
    }
    if (cmd == 'adb-devices') {
      return [
        {
          'serial': 'JBKJF6JFAAIZUGP7',
          'kind': 'usb',
          'label': 'ADB over USB',
          'endpoint': '127.0.0.1:18731',
        },
      ];
    }
    if (cmd == 'connection') {
      if (arguments.length > 2 && arguments[2] == '-') {
        final upd = jsonDecode(input ?? '{}') as Map;
        activeTransport = upd['transport'] as String? ?? activeTransport;
      }
      return {
        'transport': activeTransport,
        'tailnet_endpoint': '100.64.0.9:8731',
        'adb_endpoint': '127.0.0.1:18731',
        'remote_approved': true,
      };
    }
    if (cmd == 'peer-caps') return {'capabilities': peerCapabilities};
    if (cmd == 'resolve') {
      final eff = tr ?? activeTransport;
      if (eff == 'tailnet') {
        return {
          'transport': 'tailnet',
          'capabilities': peerCapabilities,
          'endpoint': '100.64.0.9:8731',
          'path_kind': 'derp',
          'relay': 'sin',
          'rtt': 42300000,
          'mib_per_second': 4.1,
        };
      }
      if (eff == 'adb') {
        return {
          'transport': 'adb',
          'endpoint': '127.0.0.1:18731',
          'rtt': 900000,
          'mib_per_second': 32.0,
        };
      }
      if (eff == 'lan') {
        return {
          'transport': 'direct-lan-v1',
          'endpoint': '192.168.50.3:8731',
          'interface': 'test0',
          'rtt': 1400000,
          'mib_per_second': 45.0,
        };
      }
    }
    return super.run(arguments, input: input);
  }
}

void registerMultiPathAndSshTests() {
  testWidgets(
    'Setup via SSH probes Tailscale hostname with blank port via tsnet',
    (tester) async {
      final core = _MultiPathCore();
      await tester.pumpWidget(
        MaterialApp(home: SshBootstrapDialog(core: core)),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Host / Tailscale hostname / IP'),
        'probook',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Port'), '');
      await tester.tap(find.text('Verify Host Key'));
      await tester.pumpAndSettle();

      expect(
        core.calls.any(
          (a) =>
              a.length >= 3 &&
              a[0] == 'ssh-probe' &&
              a[1] == 'probook' &&
              a[2] == '22',
        ),
        isTrue,
      );
      expect(
        find.textContaining('via Tailscale (100.100.78.84)'),
        findsOneWidget,
      );
      expect(find.textContaining('SHA256:probookhostkey'), findsOneWidget);
    },
  );

  testWidgets(
    'DeviceDetail shows Tailscale DERP/Direct, Wi-Fi LAN IP, and ADB over USB with live tap test',
    (tester) async {
      final core = _MultiPathCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('overview-transport-choice')));
      await tester.pumpAndSettle();
      expect(find.text('Tailscale'), findsOneWidget);
      expect(
        find.textContaining('via DERP (sin) · 100.64.0.9:8731'),
        findsOneWidget,
      );
      expect(find.textContaining('192.168.50.3:8731 · test0'), findsWidgets);
      final adb = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('ADB over USB'),
      );
      await tester.ensureVisible(adb);
      await tester.pumpAndSettle();
      await tester.tap(adb);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('device-connections-tab')));
      await tester.pumpAndSettle();
      expect(find.text('Connection successful'), findsNothing);
      expect(find.text('Started'), findsOneWidget);
    },
  );

  testWidgets(
    'WireGuard stays unconfigured until .conf import and strips default routes',
    (tester) async {
      final core = _WgImportCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Networks'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('networks-transports')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Import .conf'), 200);
      await tester.ensureVisible(find.text('Import .conf'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import .conf'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'WireGuard .conf contents'),
        '[Interface]\nPrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nAddress = 10.66.66.5/24\n\n[Peer]\nPublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=\nEndpoint = dubai.example.com:51820\nAllowedIPs = 0.0.0.0/0, ::/0\n',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      await tester.pumpAndSettle();

      expect(find.textContaining('10.66.66.0/24'), findsOneWidget);
      expect(find.textContaining('Default routes stripped'), findsOneWidget);
      expect(find.text('Replace .conf'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    },
  );

  testWidgets(
    'DeviceDetail ignores Wireless ADB and exposes Start buttons for USB ADB, Wi-Fi Direct, and 5GHz Wi-Fi 6 Hotspot',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final core = _StartableLinksCore()..tailnetReachable = true;
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop'));
      await tester.pumpAndSettle();

      // Wireless ADB must be ignored completely.
      expect(find.textContaining('Wireless ADB'), findsNothing);
      expect(find.textContaining('18732'), findsNothing);

      // Central Speed test button runs 5s throughput test on the selected connection only.
      await tester.ensureVisible(
        find.byKey(const ValueKey('overview-speed-test')),
      );
      await tester.tap(find.byKey(const ValueKey('overview-speed-test')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Speed test · 120.0 MiB in 5.0 s · 24.00 MiB/s'),
        findsOneWidget,
      );
      expect(find.textContaining('Speed: 24.00 MiB/s'), findsOneWidget);

      await tester.tap(find.widgetWithText(Tab, 'Connections'));
      await tester.pumpAndSettle();

      // Startable options appear with 5GHz Wi-Fi 6 indicator and Start buttons.
      final detailScroll = find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Wi-Fi Hotspot'),
        140,
        scrollable: detailScroll,
      );
      expect(find.text('ADB over USB'), findsOneWidget);
      expect(find.text('Wi-Fi Direct'), findsOneWidget);
      expect(find.text('Wi-Fi Hotspot'), findsOneWidget);
      expect(
        find.textContaining('5 GHz · Wi-Fi 6 (802.11ax)'),
        findsNWidgets(2),
      );
      expect(find.text('Phone (5 GHz)'), findsNWidgets(2));
      expect(find.text('Laptop (2.4 GHz)'), findsOneWidget);
      expect(find.byTooltip('Speed test Tailscale (5s)'), findsNothing);

      // Tapping Start on ADB over USB triggers adb-reverse / prepare-link adb_usb and connects.
      final adbTile = find.ancestor(
        of: find.text('ADB over USB'),
        matching: find.byType(ListTile),
      );
      final adbStart = find.descendant(
        of: adbTile,
        matching: find.widgetWithText(FilledButton, 'Start'),
      );
      await tester.ensureVisible(adbStart);
      await tester.pumpAndSettle();
      await tester.tap(adbStart);
      await tester.pumpAndSettle();
      expect(core.adbReversed, isTrue);
      expect(find.textContaining('Connection successful'), findsNothing);
      expect(find.text('Started'), findsOneWidget);

      // Tapping Phone (5 GHz) under Wi-Fi Hotspot triggers phone 5GHz LOHS + host wifi-join and connects.
      await tester.scrollUntilVisible(
        find.text('Wi-Fi Hotspot'),
        200,
        scrollable: detailScroll,
      );
      final hsTile = find.ancestor(
        of: find.text('Wi-Fi Hotspot'),
        matching: find.byType(ListTile),
      );
      final hsStart = find.descendant(
        of: hsTile,
        matching: find.text('Phone (5 GHz)'),
      );
      await tester.ensureVisible(hsStart);
      await tester.pumpAndSettle();
      await tester.tap(hsStart);
      await tester.pumpAndSettle();
      expect(core.hotspotPrepared, isTrue);
      expect(core.hotspotJoined, isTrue);

      // Tapping Stop restores standard Wi-Fi LAN, stays reachable, and preserves Tailscale.
      final stopBtn = find.widgetWithText(TextButton, 'Stop');
      await tester.scrollUntilVisible(stopBtn, -200, scrollable: detailScroll);
      await tester.ensureVisible(stopBtn.first);
      await tester.pumpAndSettle();
      await tester.tap(stopBtn.first);
      await tester.pumpAndSettle();
      expect(core.hotspotPrepared, isFalse);
      expect(core.hotspotJoined, isFalse);
      await tester.tap(find.widgetWithText(Tab, 'Overview'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('overview-transport-choice')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Tailscale'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('overview-speed-test')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Speed test · 120.0 MiB in 5.0 s · 24.00 MiB/s'),
        findsOneWidget,
      );
    },
  );
}

class _StartableLinksCore extends _MultiPathCore {
  bool adbReversed = false;
  bool hotspotPrepared = false;
  bool hotspotJoined = false;
  double measuredSpeed = 0;
  Map<String, dynamic> _net = {'interface': 'test0', 'cidr': '192.168.50.2/24'};

  @override
  Map<String, dynamic>? get network => _net;

  @override
  Future<void> approveNetwork(Map<String, dynamic> network) async {
    _net = Map<String, dynamic>.from(network);
  }

  @override
  Future<List<Map<String, dynamic>>> networks() async => [
    _net,
    if (hotspotPrepared && _net['interface'] != 'ap0')
      {'interface': 'ap0', 'cidr': '10.95.40.224/24', 'kind': 'hotspot'},
  ];

  @override
  Future<Map<String, dynamic>> platformCapabilities() async => {
    'os': 'linux',
    'wifi_5ghz': true,
    'wifi_6': true,
    'wifi_6ghz': false,
    'wifi_direct': true,
    'wifi_direct_go': false,
    'hotspot_ap': true,
    'hotspot_5ghz_ap': false,
    'hotspot_sta': true,
    'adb_enabled': true,
    'adb_wifi_enabled': true,
    'usb_adb': true,
    'usb_adb_connected': true,
  };

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    calls.add(arguments);
    final cmd = _cliCmd(arguments);
    final tr = _flagVal(arguments, '--transport');
    final ep = _flagVal(arguments, '--endpoint');
    if (cmd == 'adb-devices') {
      return adbReversed
          ? [
              {
                'serial': 'JBKJF6JFAAIZUGP7',
                'kind': 'usb',
                'label': 'ADB over USB',
                'endpoint': '127.0.0.1:18731',
              },
            ]
          : [];
    }
    if (cmd == 'adb-forward-peer') {
      adbReversed = true;
      return {
        'ok': true,
        'kind': 'adb_usb',
        'transport': 'adb',
        'endpoint': '127.0.0.1:18731',
      };
    }
    if (cmd == 'peer-caps') {
      return {
        'capabilities': {
          'os': 'android',
          'wifi_5ghz': true,
          'wifi_6': true,
          'wifi_6ghz': false,
          'wifi_direct': true,
          'wifi_direct_go': true,
          'hotspot_ap': true,
          'hotspot_5ghz_ap': true,
          'hotspot_sta': true,
          'usb_adb': true,
        },
      };
    }
    if (cmd == 'prepare-link') {
      final body = jsonDecode(input ?? '{}') as Map;
      if (body['kind'] == 'adb_usb') {
        adbReversed = true;
        return {
          'ok': true,
          'kind': 'adb_usb',
          'transport': 'adb',
          'endpoint': '127.0.0.1:18731',
        };
      }
      if (body['kind'] == 'hotspot') {
        hotspotPrepared = true;
        return {
          'ok': true,
          'kind': 'hotspot',
          'transport': 'lan',
          'interface': 'ap0',
          'ip': '10.95.40.224',
          'cidr': '10.95.40.224/24',
          'endpoint': '10.95.40.224:8731',
          'ssid': 'DB-AP-5G',
          'passphrase': 'devicebridge123',
          'band': '5 GHz',
          'wifi_standard': 'Wi-Fi 6 (802.11ax)',
        };
      }
    }
    if (cmd == 'wifi-join') {
      hotspotJoined = true;
      return {
        'ok': true,
        'transport': 'lan',
        'interface': 'wlan0',
        'ip': '10.95.40.161',
        'cidr': '10.95.40.161/24',
        'endpoint': '10.95.40.161:8731',
        'band': '5 GHz',
        'wifi_standard': 'Wi-Fi 6 (802.11ax)',
      };
    }
    if (cmd == 'restore-link') {
      hotspotPrepared = false;
      hotspotJoined = false;
      _net = {'interface': 'test0', 'cidr': '192.168.50.2/24'};
      return {'ok': true, 'kind': 'restore', 'status': 'restored'};
    }
    if (cmd == 'speedtest') {
      measuredSpeed = 24.0;
      return {
        'bytes': 125829120,
        'mib': 120.0,
        'seconds': 5.0,
        'mib_per_second': 24.0,
        'transport': 'direct-lan-v1',
        'endpoint': '192.168.50.3:8731',
      };
    }
    if (cmd == 'resolve') {
      final eff = tr ?? activeTransport;
      if (eff == 'adb' || ep == '127.0.0.1:18731') {
        if (!adbReversed) {
          throw StateError('adb reverse not started yet');
        }
        return {
          'transport': 'adb',
          'endpoint': '127.0.0.1:18731',
          'rtt': 850000,
          'mib_per_second': measuredSpeed > 0 ? measuredSpeed : 35.0,
        };
      }
      if (eff == 'lan' &&
          (hotspotJoined || _net['cidr'] == '10.95.40.161/24')) {
        return {
          'transport': 'direct-lan-v1',
          'endpoint': '10.95.40.224:8731',
          'interface': 'wlan0',
          'rtt': 1800000,
          'mib_per_second': measuredSpeed > 0 ? measuredSpeed : 95.0,
        };
      }
      if (eff == 'tailnet') {
        return {
          'transport': 'tailnet',
          'endpoint': '100.64.0.9:8731',
          'path_kind': 'derp',
          'relay': 'sin',
          'rtt': 42300000,
          'mib_per_second': measuredSpeed > 0 ? measuredSpeed : 4.1,
        };
      }
      if (eff == 'lan' && measuredSpeed > 0) {
        return {
          'transport': 'direct-lan-v1',
          'endpoint': '192.168.50.3:8731',
          'interface': 'test0',
          'rtt': 1400000,
          'mib_per_second': measuredSpeed,
        };
      }
    }
    return super.run(arguments, input: input);
  }
}

class _WgImportCore extends FakeCore {
  Map<String, dynamic> wgState = {
    'configured': false,
    'backend': 'userspace',
    'public_key': '',
    'local_tunnel_ip': '',
    'peers': [],
  };

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    if (arguments.isNotEmpty && arguments.first == 'wireguard') {
      if (arguments.length > 1 && arguments[1] == 'import-conf') {
        wgState = {
          'configured': true,
          'imported': true,
          'default_route_stripped': (input ?? '').contains('0.0.0.0/0'),
          'scoped_allowed_ips': ['10.66.66.0/24'],
          'backend': 'userspace',
          'public_key': 'importedPubKey==',
          'local_tunnel_ip': '10.66.66.5/24',
          'listen_port': 51820,
          'peers': [
            {
              'name': 'dubai.example.com',
              'server_endpoint': 'dubai.example.com:51820',
            },
          ],
        };
        return wgState;
      }
      if (arguments.length > 1 && arguments[1] == 'remove-conf') {
        wgState = {
          'configured': false,
          'backend': 'userspace',
          'public_key': '',
          'local_tunnel_ip': '',
          'peers': [],
        };
        return wgState;
      }
      return wgState;
    }
    return super.run(arguments, input: input);
  }
}

class _RevokedPeerCore extends FakeCore {
  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    if (arguments.first == 'peers') {
      return [
        {
          'id': 'revoked-laptop',
          'name': 'arch-laptop',
          'status': 'revoked',
          'addresses': [
            {'endpoint': '192.168.1.23:8731'},
          ],
        },
      ];
    }
    return super.run(arguments, input: input);
  }
}

const _syncPeerID =
    'BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB';

class _SyncModesCore extends FakeCore {
  _SyncModesCore({this.installed = true});

  final bool installed;

  final registrations = <Map<String, dynamic>>[
    {
      'group': 'mirror',
      'peer_id': _syncPeerID,
      'role': 'sendonly',
      'path': '/state/syncthing-v1/projections/mirror',
      'source': '/home/afzl/repo',
      'mode': 'full',
      'activity': 'paused',
      'devicebridge_peer': 'laptop',
    },
    {
      'group': 'work',
      'peer_id': _syncPeerID,
      'role': 'sendonly',
      'path': '/state/syncthing-v1/projections/work',
      'source': '/home/afzl/repo',
      'mode': 'non-git',
      'filter': 'working',
      'activity': 'paused',
    },
  ];

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    if (arguments.first == 'syncthing') {
      calls.add(arguments);
      switch (arguments[1]) {
        case 'status':
          return {
            'installed': installed,
            'prepared': installed,
            'device_id': 'AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA',
            'registered': installed ? registrations : [],
          };
        case 'build':
          return {
            'manifest_xxh64': '0123456789abcdef',
            'bytes': 10,
            'items': 2,
          };
        default:
          return {'status': 'ok'};
      }
    }
    if (arguments.first == 'peers') {
      calls.add(arguments);
      return [
        {'id': 'laptop', 'name': 'probook', 'status': 'paired'},
      ];
    }
    if (arguments.first == 'pull-tar') {
      calls.add(arguments);
      return {'mode': 'tar', 'mib_per_second': 12.5};
    }
    return super.run(arguments, input: input);
  }
}

void _syncModeTests() {
  testWidgets('Full pull works without Syncthing or registered folders', (
    tester,
  ) async {
    final core = _SyncModesCore(installed: false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncScreen(core: core)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Register folder'), findsNothing);
    await tester.tap(find.text('Full pull…'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(DropdownButtonFormField<String>, 'Peer'),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Remote folder path'),
      'repo',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Pull everything'));
    await tester.pumpAndSettle();
    final call = core.calls.lastWhere((c) => c.first == 'pull-tar');
    expect(call.sublist(0, 4), ['pull-tar', 'laptop', 'home', 'repo']);
    expect(call.length, 5);
    expect(find.textContaining('Full pull verified'), findsOneWidget);
    expect(
      core.calls
          .where((c) => c.first == 'syncthing')
          .every((c) => c[1] == 'status'),
      isTrue,
    );
  });

  testWidgets(
    'Sync register offers full and non-git modes with a source folder',
    (tester) async {
      final core = _SyncModesCore();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SyncScreen(core: core)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Register folder'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Shared group ID'),
        'mirror',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Peer Syncthing device ID'),
        _syncPeerID,
      );
      expect(find.text('Untracked & ignored only'), findsOneWidget);
      await tester.tap(find.text('Non-git files (filtered projection)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Full folder (incl. hidden & .git)').last);
      await tester.pumpAndSettle();
      expect(find.text('Untracked & ignored only'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Local folder to sync (required)'),
        '/home/afzl/repo',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Register'));
      await tester.pumpAndSettle();
      final call = core.calls.firstWhere(
        (c) => c.length > 1 && c[0] == 'syncthing' && c[1] == 'register',
      );
      expect(call, [
        'syncthing',
        'register',
        'mirror',
        _syncPeerID,
        'receiveonly',
        '--mode',
        'full',
        '--source',
        '/home/afzl/repo',
      ]);
    },
  );

  testWidgets('Full pull copies everything including .git by default', (
    tester,
  ) async {
    final core = _SyncModesCore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncScreen(core: core)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Full folder · incl. hidden & .git'),
      findsOneWidget,
    );
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full pull from peer…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Remote folder path'),
      'repo',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Pull everything'));
    await tester.pumpAndSettle();
    final call = core.calls.lastWhere((c) => c.first == 'pull-tar');
    expect(call.sublist(0, 4), ['pull-tar', 'laptop', 'home', 'repo']);
    expect(call.length, 5);
    expect(call[4], startsWith('/private/downloads/repo-'));
    expect(find.textContaining('Full pull verified'), findsOneWidget);
  });

  testWidgets('Full pull can exclude the root .git history', (tester) async {
    final core = _SyncModesCore();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SyncScreen(core: core)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full pull from peer…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Remote folder path'),
      'repo',
    );
    await tester.tap(
      find.widgetWithText(CheckboxListTile, 'Include .git history'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Pull everything'));
    await tester.pumpAndSettle();
    final call = core.calls.lastWhere((c) => c.first == 'pull-tar');
    expect(call.length, 6);
    expect(call[5], '.git');
  });

  testWidgets(
    'Working registrations build a projection and can switch to full',
    (tester) async {
      final core = _SyncModesCore();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SyncScreen(core: core)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Non-git · all working files except .git'),
        findsOneWidget,
      );
      await tester.tap(find.byType(PopupMenuButton<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Build working projection…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Build'));
      await tester.pumpAndSettle();
      expect(core.calls.lastWhere((c) => c.length > 1 && c[1] == 'build'), [
        'syncthing',
        'build',
        'work',
        '/home/afzl/repo',
      ]);
      await tester.tap(find.byType(PopupMenuButton<String>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change sync mode…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Non-git files (filtered projection)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Full folder (incl. hidden & .git)').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save mode'));
      await tester.pumpAndSettle();
      expect(core.calls.lastWhere((c) => c.length > 1 && c[1] == 'mode'), [
        'syncthing',
        'mode',
        'work',
        '--mode',
        'full',
        '--source',
        '/home/afzl/repo',
      ]);
    },
  );

  testWidgets(
    'Home Termux button opens full-screen Termux window with no bottom tab bar, preserves session on return, and opens Termux & Keyboard Settings',
    (tester) async {
      final core = FakeCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationDestination), findsNWidgets(3));
      expect(find.widgetWithText(FilledButton, 'Termux'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Termux'));
      await tester.pumpAndSettle();

      // Full-screen Termux window hides bottom NavigationBar and hides theme/wifi/app-settings icons
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byTooltip('Appearance'), findsNothing);
      expect(find.byTooltip('Connections'), findsNothing);
      expect(find.byTooltip('Settings'), findsNothing);
      expect(find.text('Termux'), findsOneWidget);
      expect(find.textContaining('Ghostty'), findsNothing);
      expect(find.text('Ctrl'), findsOneWidget);
      expect(find.text('Alt'), findsOneWidget);
      expect(find.text('123+'), findsOneWidget);
      expect(find.text('Esc'), findsOneWidget);

      // Opening Termux & Keyboard Settings via Termux title reveals system monitor toggles & tmux controls
      await tester.tap(find.text('Termux'));
      await tester.pumpAndSettle();
      expect(find.text('Termux & Keyboard Settings'), findsOneWidget);
      expect(find.text('tmux Tabs & Workspace'), findsOneWidget);
      expect(find.text('Top Bar System Monitor'), findsOneWidget);
      expect(find.text('Show CPU usage'), findsOneWidget);
      expect(find.text('Show RAM usage'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Monitor update interval'),
        80,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Show GPU usage'), findsOneWidget);
      expect(find.text('Monitor update interval'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('TouchFx press & swipe vector animation'),
        140,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Show dedicated number row (1–0)'), findsOneWidget);
      expect(find.text('Floating key & swipe preview popup'), findsOneWidget);
      expect(
        find.text('TouchFx press & swipe vector animation'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Key & Gesture Mappings'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text(r"Bell (printf '\a')"), findsOneWidget);
      expect(find.text('Key & Gesture Mappings'), findsOneWidget);
      Navigator.of(tester.element(find.text('Key & Gesture Mappings'))).pop();
      await tester.pumpAndSettle();

      // Returning to Home via Back button restores the 4-tab NavigationBar and reopening Termux preserves the session
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Termux'));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Termux'), findsOneWidget);
      expect(find.text('Ctrl'), findsOneWidget);

      // Verify theme adaptation under Matte paper theme
      await tester.pumpWidget(
        MaterialApp(
          theme: mattePaperTheme(),
          home: Scaffold(
            body: LocalTerminalScreen(core: core, appearance: 'matte'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ctrl'), findsOneWidget);
    },
  );

  testWidgets(
    'LocalTerminalScreen enables mouse/touch events (readOnly=false, hardwareKeyboardOnly=true), keeps focus, and relies on tmux native OSC 52 copy/paste without UI knobs',
    (tester) async {
      String? systemClipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>?;
            systemClipboard = args?['text'] as String?;
            return null;
          }
          if (call.method == 'Clipboard.getData') {
            return <String, dynamic>{'text': systemClipboard ?? ''};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final core = FakeCore();
      await tester.pumpWidget(
        MaterialApp(
          theme: mattePaperTheme(),
          home: Scaffold(
            body: LocalTerminalScreen(core: core, appearance: 'matte'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final termView = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(termView.readOnly, isFalse);
      expect(termView.hardwareKeyboardOnly, isTrue);
      expect(termView.autofocus, isTrue);
      expect(termView.focusNode?.hasFocus, isTrue);
      expect(find.byKey(const Key('termux-selection-copy')), findsNothing);
      expect(
        find.byKey(const Key('termux-selection-handle-start')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('termux-selection-handle-end')),
        findsNothing,
      );

      // Verify tmux OSC 52 clipboard store updates system clipboard cleanly
      termView.terminal.onClipboardStore?.call('c', 'tmux_osc52_payload');
      await tester.pump();
      expect(systemClipboard, 'tmux_osc52_payload');

      // Verify stats interval option changes and persists cleanly
      final state = tester.state<LocalTerminalScreenState>(
        find.byType(LocalTerminalScreen),
      );
      state.openTerminalSettings();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Monitor update interval'),
        80,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Monitor update interval'), findsOneWidget);
      await tester.tap(find.text('2s'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5s').last);
      await tester.pumpAndSettle();
      expect(
        jsonDecode(core.settings['terminal_keyboard_config'] as String),
        containsPair('stats_interval_ms', 5000),
      );
    },
  );

  testWidgets(
    'TailnetPanel manages tsnet SOCKS5, exit node and trusted SSH tags, and handles logged-out or stopped state without crashing',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Stopped / logged-out state must render cleanly without crashing and still persist settings.
      final offlineCore = FakeCore()..tailnetReachable = false;
      await tester.pumpWidget(
        MaterialApp(home: TailnetPanel(core: offlineCore)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tailscale (tsnet) settings'), findsOneWidget);
      expect(
        find.textContaining('not logged in / disconnected'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // Connected / Running state configures SOCKS5, port, exit node & trusted ACL tags.
      final core = FakeCore()..tailnetReachable = true;
      await tester.pumpWidget(MaterialApp(home: TailnetPanel(core: core)));
      await tester.pumpAndSettle();

      Future<void> scrollIntoView(Finder f) async {
        await tester.scrollUntilVisible(f, 250);
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
      }

      await scrollIntoView(find.text('Local SOCKS5 proxy'));
      await tester.tap(find.text('Local SOCKS5 proxy'));
      await tester.pumpAndSettle();
      expect(core.settings['tsnet_socks5_enabled'], isTrue);
      expect(find.textContaining('127.0.0.1:1055'), findsWidgets);

      await scrollIntoView(find.text('SOCKS5 listen port'));
      await tester.tap(find.text('SOCKS5 listen port'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '1080');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(core.settings['tsnet_socks5_port'], 1080);

      await scrollIntoView(find.text('SOCKS5 & tsnet exit node'));
      await tester.tap(find.text('SOCKS5 & tsnet exit node'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Laptop').last);
      await tester.pumpAndSettle();
      expect(core.settings['tsnet_exit_node_id'], 'node-laptop-1');

      expect(core.settings['tsnet_ssh_enabled'], isTrue);
      await scrollIntoView(find.text('Tailscale SSH (:22)'));
      expect(find.text('Tailscale SSH (:22)'), findsOneWidget);
      await tester.tap(find.text('Tailscale SSH (:22)'));
      await tester.pumpAndSettle();
      expect(core.settings['tsnet_ssh_enabled'], isFalse);
      await tester.tap(find.text('Tailscale SSH (:22)'));
      await tester.pumpAndSettle();
      expect(core.settings['tsnet_ssh_enabled'], isTrue);
      expect(
        find.text('Passwordless SSH for trusted Tailscale tags'),
        findsNothing,
      );
      expect(find.text('Add tag'), findsNothing);

      expect(core.settings['tsnet_openssh_enabled'], isFalse);
      await scrollIntoView(find.text('OpenSSH server (port 8022)'));
      await tester.tap(find.text('OpenSSH server (port 8022)'));
      await tester.pumpAndSettle();
      expect(core.settings['tsnet_openssh_enabled'], isTrue);

      // Peers stay collapsed behind ExpansionTile until tapped so settings stay on top.
      expect(find.textContaining('100.64.0.9'), findsNothing);
      await scrollIntoView(find.text('Tailscale peers (1)'));
      await tester.tap(find.text('Tailscale peers (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Laptop · 100.64.0.9'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Root features stay off and disabled when Root access is off, and Termux disables CPU/GPU when unavailable',
    (tester) async {
      final core = FakeCore();
      // Global settings moved tsnet section into Network/Tailscale panel.
      await tester.pumpWidget(MaterialApp(home: SettingsScreen(core: core)));
      await tester.pumpAndSettle();
      expect(find.text('Tailscale (tsnet)'), findsNothing);

      // Root features submenu renders switches OFF and disabled while root_enabled is false.
      await tester.scrollUntilVisible(find.text('Root features'), 200);
      await tester.ensureVisible(find.text('Root features'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Root features'));
      await tester.pumpAndSettle();
      final rootSwitches = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList();
      expect(rootSwitches, isNotEmpty);
      for (final sw in rootSwitches) {
        expect(sw.value, isFalse);
        expect(sw.onChanged, isNull);
      }

      // Termux settings disables CPU and GPU switches when unavailable (Standard mode), keeping RAM active.
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: Scaffold(body: LocalTerminalScreen(core: core)),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state<LocalTerminalScreenState>(
        find.byType(LocalTerminalScreen),
      );
      state.openTerminalSettings();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Show GPU usage'),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      final cpuTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Show CPU usage'),
      );
      final ramTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Show RAM usage'),
      );
      final gpuTile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Show GPU usage'),
      );
      expect(cpuTile.value, isFalse);
      expect(cpuTile.onChanged, isNull);
      expect(ramTile.value, isTrue);
      expect(ramTile.onChanged, isNotNull);
      expect(gpuTile.value, isFalse);
      expect(gpuTile.onChanged, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'FileManager supports Recycle Bin, permanent delete, and drag onto panel or folder for Copy/Move',
    (tester) async {
      tester.view.physicalSize = const Size(800, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final core = _InteractiveLocalFilesCore();
      await tester.pumpWidget(MaterialApp(home: FileManager(core: core)));
      await tester.pumpAndSettle();

      // 1. Move to Recycle Bin via File actions menu
      await tester.tap(find.byTooltip('File actions').first);
      await tester.pumpAndSettle();
      expect(find.text('Move to Recycle Bin'), findsOneWidget);
      expect(find.text('Delete permanently'), findsOneWidget);
      await tester.tap(find.text('Move to Recycle Bin'));
      await tester.pumpAndSettle();
      expect(core.localCalls.last, 'trash:internal:alpha.txt');
      expect(find.text('Moved alpha.txt to Recycle Bin'), findsOneWidget);

      // 2. Select Recycle Bin in the left pane and restore the file.
      await tester.tap(find.byKey(const ValueKey('file-pane-0-storage')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recycle Bin').last);
      await tester.pumpAndSettle();
      expect(find.text('alpha.txt'), findsOneWidget);
      await tester.tap(find.byTooltip('File actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(core.localCalls.last, 'restore:trash-1');
      expect(find.text('Recycle Bin is empty'), findsOneWidget);

      // Switch left pane back to Internal storage
      await tester.tap(find.text('Recycle Bin').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Internal storage').last);
      await tester.pumpAndSettle();

      // 3. Delete permanently with confirmation
      await tester.tap(find.byTooltip('File actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(find.text('Delete alpha.txt permanently?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(core.localCalls.last, 'delete:internal:alpha.txt');

      // 4. Drag file from left pane onto a folder in the right pane -> Move
      final leftFile = find.text('beta.txt').first;
      final rightFolder = find.text('docs').last;
      final gesture1 = await tester.startGesture(tester.getCenter(leftFile));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture1.moveTo(tester.getCenter(rightFolder));
      await tester.pump();
      await gesture1.up();
      await tester.pumpAndSettle();
      expect(find.text('Copy or move beta.txt?'), findsOneWidget);
      expect(find.textContaining('docs'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'Move'));
      await tester.pumpAndSettle();
      expect(
        core.localCalls.last,
        'transfer:internal:beta.txt->internal:docs:move=true',
      );

      // 5. Drag file from left pane onto a folder in the same pane -> Copy
      final leftFolder = find.text('docs').first;
      final gesture2 = await tester.startGesture(tester.getCenter(leftFile));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture2.moveTo(tester.getCenter(leftFolder));
      await tester.pump();
      await gesture2.up();
      await tester.pumpAndSettle();
      expect(find.text('Copy or move beta.txt?'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Copy'));
      await tester.pumpAndSettle();
      expect(
        core.localCalls.last,
        'transfer:internal:beta.txt->internal:docs:move=false',
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _InteractiveLocalFilesCore extends FakeCore {
  final localCalls = <String>[];
  final items = <Map<String, dynamic>>[
    {'name': 'alpha.txt', 'path': 'alpha.txt', 'kind': 'file', 'size': 12},
    {'name': 'beta.txt', 'path': 'beta.txt', 'kind': 'file', 'size': 24},
    {'name': 'docs', 'path': 'docs', 'kind': 'directory', 'size': 0},
  ];
  final trashItems = <Map<String, dynamic>>[];

  @override
  Future<dynamic> localFiles(
    String operation,
    Map<String, dynamic> arguments,
  ) async {
    switch (operation) {
      case 'roots':
        return [
          {
            'id': 'internal',
            'name': 'Internal storage',
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
        ];
      case 'list':
        if (arguments['kind'] == 'recycle_bin') {
          return {'entries': List<Map<String, dynamic>>.from(trashItems)};
        }
        if ((arguments['path'] as String? ?? '').isNotEmpty) {
          return {'entries': <Map<String, dynamic>>[]};
        }
        return {'entries': List<Map<String, dynamic>>.from(items)};
      case 'trash':
        final path = arguments['path'] as String;
        localCalls.add('trash:${arguments['kind']}:$path');
        final idx = items.indexWhere((e) => e['path'] == path);
        if (idx >= 0) {
          final removed = items.removeAt(idx);
          trashItems.add({
            'name': removed['name'],
            'path': 'trash-1',
            'kind': removed['kind'],
            'size': removed['size'],
            'original_label': 'Internal storage/$path',
          });
        }
        return {'id': 'trash-1', 'name': path};
      case 'restore':
        final id = arguments['path'] as String;
        localCalls.add('restore:$id');
        final idx = trashItems.indexWhere((e) => e['path'] == id);
        if (idx >= 0) {
          final restored = trashItems.removeAt(idx);
          items.insert(0, {
            'name': restored['name'],
            'path': restored['name'],
            'kind': restored['kind'],
            'size': restored['size'],
          });
        }
        return {'name': 'alpha.txt'};
      case 'delete':
        final path = arguments['path'] as String;
        localCalls.add('delete:${arguments['kind']}:$path');
        items.removeWhere((e) => e['path'] == path);
        return true;
      case 'empty-trash':
        localCalls.add('empty-trash');
        trashItems.clear();
        return {'removed': 0};
      case 'transfer':
        final src = arguments['source'] as Map;
        final dst = arguments['target'] as Map;
        localCalls.add(
          'transfer:${src['kind']}:${src['path']}->${dst['kind']}:${dst['path']}:move=${arguments['move']}',
        );
        return {'files': 1, 'source_remaining': false};
      default:
        return super.localFiles(operation, arguments);
    }
  }
}

class _UsageMonitorCore extends FakeCore {
  @override
  Future<Map<String, dynamic>> runtimeStatus({
    bool includeResources = false,
  }) async => {
    ...await super.runtimeStatus(includeResources: includeResources),
    if (includeResources)
      'resources': {
        'battery_percent': 84,
        'app_cpu_percent': 2.5,
        'child_cpu_percent': 1.5,
        'battery_stats': {'wakeup_alarms': 3},
      },
    'tailnet_status': {
      'state': 'Running',
      'socks5_addr': '127.0.0.1:1055',
      'proxy_stats': {
        'active_clients': 1,
        'connections': 1,
        'rx_bytes': 1024,
        'tx_bytes': 384,
        'destinations': [
          {'host': 'example.net', 'rx_bytes': 1024, 'tx_bytes': 384},
        ],
      },
    },
    'proxy_client_apps': [
      {
        'uid': 10001,
        'packages': ['org.example.client'],
      },
    ],
  };
}

class _HomeMonitorCore extends FakeCore {
  int statusReads = 0;
  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    final cmd = arguments.firstOrNull ?? '';
    if (cmd == 'peers') {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return [
        {
          'id': 'p1',
          'name': 'Pending Phone',
          'status': 'pending',
          'expires': now + 300,
        },
        {
          'id': 'p2',
          'name': 'Pending Tablet',
          'status': 'pending',
          'expires': now + 300,
        },
        {
          'id': 'p3',
          'name': 'Expired Phone',
          'status': 'pending',
          'expires': now - 60,
        },
      ];
    }
    if (cmd == 'tailnet' && arguments.length > 1 && arguments[1] == 'status') {
      return {
        'mode': 'app',
        'state': 'Running',
        'hostname': 'termux',
        'ips': ['100.64.0.2'],
        'tailscale_ssh_enabled': true,
        'openssh_enabled': true,
        'active_ssh_conns': 2,
        'ssh_sessions': [
          {'user': 'afzl', 'peer': 'probook', 'remote': '100.64.0.9'},
        ],
        'peers': [
          {
            'id': 'node-1',
            'name': 'probook',
            'ips': ['100.64.0.9'],
            'online': true,
          },
        ],
      };
    }
    return super.run(arguments, input: input);
  }

  @override
  Future<Map<String, dynamic>> runtimeStatus({
    bool includeResources = false,
  }) async {
    statusReads++;
    final base = await super.runtimeStatus(includeResources: includeResources);
    return {
      ...base,
      'physical_networks': [
        {
          'kind': 'wifi',
          'interface': 'wlan0',
          'cidr': '192.168.1.20/24',
          'unmetered': true,
          'connected': true,
        },
        {
          'kind': 'cellular',
          'interface': 'rmnet_data0',
          'cidr': '10.12.0.4/30',
          'unmetered': false,
          'connected': true,
        },
      ],
      'agent': {
        'running': true,
        'state': 'active',
        'endpoint': '192.168.1.20:8731',
        'discovery': true,
        'active_conns': 2,
        'active_requests': 1,
        'total_requests': 44,
        'bytes_sent': 524288,
        'bytes_received': 131072,
      },
      'ssh': {
        'tailscale_ssh_enabled': true,
        'openssh_enabled': true,
        'openssh_running': true,
        'openssh_port': 8022,
        'openssh_conns': 1,
      },
    };
  }
}

class _DirectHubCore extends FakeCore {
  final List<String> startedKinds = [];
  final List<String> approvedInterfaces = [];
  final List<Map<String, dynamic>> adbPrepareRequests = [];
  int stopCalls = 0;
  bool wiredAdb = true;
  bool supportsWifiDirect = true;
  String altWifiHandle = '42';
  Map<String, dynamic>? selected;

  @override
  Map<String, dynamic>? get network =>
      selected ??
      {
        'interface': 'wlan0',
        'cidr': '192.168.50.2/24',
        'kind': 'wifi',
        'unmetered': true,
      };

  @override
  Future<List<Map<String, dynamic>>> networks() async => [
    {...?network},
    if (activeSession['active'] == true) activeSession,
    {
      'interface': 'wlan1',
      'cidr': '192.168.51.2/24',
      'kind': 'wifi',
      'network_handle': altWifiHandle,
    },
    {'interface': 'rmnet_data0', 'cidr': '10.0.0.1/32', 'kind': 'cellular'},
    {'interface': 'tailscale0', 'cidr': '100.64.0.2/32'},
    {'interface': 'rndis0', 'cidr': '', 'kind': 'usb_net'},
  ];

  @override
  Future<Map<String, dynamic>> activeDirectLink() async => activeSession;
  Map<String, dynamic> activeSession = {'active': false};

  @override
  Future<void> approveNetwork(Map<String, dynamic> network) async {
    approvedInterfaces.add('${network['interface'] ?? ''}');
    selected = network;
  }

  @override
  Future<Map<String, dynamic>> platformCapabilities() async => {
    'os': 'android',
    'execution_mode': 'root',
    'wifi_5ghz': true,
    'wifi_6': true,
    'wifi_direct': supportsWifiDirect,
    'hotspot_ap': true,
    'adb_enabled': wiredAdb,
    'usb_adb_connected': wiredAdb,
    'usb_serial': 'JBKJF6JFAAIZUGP7',
  };

  @override
  Future<dynamic> run(List<String> arguments, {String? input}) async {
    if (arguments.isNotEmpty && arguments.first == 'peers') {
      return [
        {
          'id': 'laptop-1',
          'name': 'probook',
          'os': 'linux',
          'status': 'paired',
        },
      ];
    }
    if (arguments.contains('prepare-link') && input != null) {
      final decoded = jsonDecode(input) as Map<String, dynamic>;
      adbPrepareRequests.add(decoded);
      return {
        'ok': true,
        'kind': 'adb_usb',
        'message': 'USB ADB reverse tcp:18731->8731 active',
      };
    }
    return super.run(arguments, input: input);
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
  }) async {
    startedKinds.add(kind);
    activeSession = {
      'active': true,
      'kind': kind,
      'mode': 'root',
      'interface': kind == 'wifi_direct' ? 'p2p-wlan0-0' : 'ap0',
      'ip': '192.168.49.1',
      'cidr': '192.168.49.1/24',
      'endpoint': '192.168.49.1:8731',
      'ssid': ssid ?? (kind == 'wifi_direct' ? 'DIRECT-DB-test' : 'DB-AP-test'),
      'passphrase': passphrase ?? '12345678',
      'band': '5 GHz',
      'channel': 36,
    };
    return activeSession;
  }

  @override
  Future<Map<String, dynamic>> stopDirectLink({bool forget = true}) async {
    stopCalls++;
    activeSession = {'active': false};
    selected = null;
    return {'ok': true, 'status': 'restored'};
  }

  @override
  Future<Map<String, dynamic>> runtimeStatus({
    bool includeResources = false,
  }) async {
    final base = await super.runtimeStatus(includeResources: includeResources);
    return {
      ...base,
      'os': 'android',
      'direct_link': activeSession,
      'usb': {
        'cable_plugged': true,
        'adb_enabled': wiredAdb,
        'usb_adb_connected': wiredAdb,
      },
    };
  }
}

class _SSHHostsCore extends FakeCore {
  final hosts = <Map<String, dynamic>>[];
  final policy = <String, dynamic>{'network_agent_ssh': true};
  final aclPeerTags = <String, List<String>>{};
  Map<String, dynamic> aclPolicy = {
    'version': 1,
    'enabled': false,
    'groups': <String, List<String>>{},
    'rules': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> _evalFor(String id, String name) {
    final tags = List<String>.from(aclPeerTags[id] ?? const <String>[]);
    final groups = <String>[
      for (final e in (aclPolicy['groups'] as Map).entries)
        if ((e.value as List).contains(id)) '${e.key}',
    ];
    final enabled = aclPolicy['enabled'] == true;
    const resources = [
      'files:browse',
      'files:read',
      'ssh',
      'share:text',
      'share:file',
      'sync',
      'termux',
      'actions',
      'link',
    ];
    final rules = (aclPolicy['rules'] as List).whereType<Map>().toList();
    final decisions = <Map<String, dynamic>>[];
    for (final res in resources) {
      if (!enabled) {
        decisions.add({'resource': res, 'allowed': true, 'reason': 'off'});
        continue;
      }
      var allowed = false;
      for (final r in rules) {
        final srcs = (r['src'] as List).map((e) => '$e').toList();
        final dsts = (r['dst'] as List).map((e) => '$e').toList();
        final srcMatch = srcs.any(
          (s) =>
              s == '*' ||
              tags.contains(s) ||
              groups.contains(s) ||
              s == 'peer:$id',
        );
        final dstMatch = dsts.any((d) => d == '*' || d == res);
        if (srcMatch && dstMatch) {
          if (r['action'] == 'deny') {
            allowed = false;
            break;
          }
          allowed = true;
        }
      }
      decisions.add({
        'resource': res,
        'allowed': allowed,
        'reason': allowed ? 'rule' : 'default-deny',
      });
    }
    return {
      'peer_id': id,
      'name': name,
      'status': 'paired',
      'tags': tags,
      'groups': groups,
      'enabled': enabled,
      'decisions': decisions,
    };
  }

  Future<Map<String, dynamic>> _aclSnapshot() async {
    final peerList = (await super.run(['peers']) as List).whereType<Map>();
    return {
      'policy': aclPolicy,
      'peer_tags': aclPeerTags,
      'evaluations': [
        for (final p in peerList)
          if (p['status'] == 'paired') _evalFor('${p['id']}', '${p['name']}'),
      ],
    };
  }

  @override
  Future<dynamic> run(List<String> args, {String? input}) async {
    if (args.first == 'acl') {
      calls.add(List.of(args));
      if (args.length == 1) return await _aclSnapshot();
      if (args[1] == 'preset' && args[2] == 'trusted') {
        aclPolicy = {
          'version': 1,
          'enabled': true,
          'groups': aclPolicy['groups'],
          'rules': [
            {
              'id': 'trusted-all',
              'action': 'accept',
              'src': ['tag:trusted'],
              'dst': ['*'],
              'description':
                  'Trusted devices can access all services on this device',
            },
          ],
        };
        return await _aclSnapshot();
      }
      if (args[1] == 'set' && input != null) {
        aclPolicy = Map<String, dynamic>.from(jsonDecode(input) as Map);
        return await _aclSnapshot();
      }
      if (args[1] == 'eval') {
        final peerList = (await super.run(['peers']) as List).whereType<Map>();
        final p = peerList.firstWhere(
          (x) => x['id'] == args[2],
          orElse: () => {'id': args[2], 'name': 'Peer'},
        );
        return _evalFor('${p['id']}', '${p['name']}');
      }
    }
    if (args.first == 'peer-tags') {
      calls.add(List.of(args));
      final id = args[1];
      if (args.length == 3) {
        final raw = args[2];
        aclPeerTags[id] = raw == 'none'
            ? []
            : raw.split(',').where((e) => e.isNotEmpty).toList();
      }
      return {'peer_id': id, 'tags': aclPeerTags[id] ?? <String>[]};
    }
    if (args.first == 'acl-group') {
      calls.add(List.of(args));
      final grp = args[1].startsWith('group:') ? args[1] : 'group:${args[1]}';
      final groups = Map<String, List<String>>.from(
        (aclPolicy['groups'] as Map).map(
          (k, v) => MapEntry('$k', List<String>.from(v as List)),
        ),
      );
      if (args.length == 3) {
        if (args[2] == 'delete') {
          groups.remove(grp);
        } else {
          groups[grp] = args[2] == 'none'
              ? []
              : args[2].split(',').where((e) => e.isNotEmpty).toList();
        }
        aclPolicy = {...aclPolicy, 'groups': groups};
      }
      return aclPolicy;
    }
    if (args.first == 'network-policy') {
      calls.add(List.of(args));
      if (input != null) {
        policy.addAll(jsonDecode(input) as Map<String, dynamic>);
      }
      return Map<String, dynamic>.of(policy);
    }
    if (args.first == 'ssh-hosts') {
      calls.add(List.of(args));
      if (args.length == 1) return hosts;
      if (args[1] == 'probe') {
        return {'host_key_sha256': 'SHA256:verified-fixture'};
      }
      if (args[1] == 'save') {
        final h = Map<String, dynamic>.from(jsonDecode(input!) as Map)
          ..remove('password')
          ..remove('private_key_pem')
          ..remove('key_passphrase');
        h['id'] = 'fixture-ssh-host';
        hosts.add(h);
        return h;
      }
      if (args[1] == 'check') {
        return {
          'id': 'fixture-ssh-host',
          'os': 'Linux',
          'interfaces': [
            {'interface': 'wlan0', 'cidr': '192.168.50.10/24', 'kind': 'wifi'},
            {
              'interface': 'tailscale0',
              'cidr': '100.88.1.2/32',
              'kind': 'tailnet',
            },
          ],
          'checked_at_utc': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'exit_code': 0,
        };
      }
    }
    return super.run(args, input: input);
  }
}

void registerNetworkRefactorTests() {
  testWidgets(
    'SSH-only host is saved separately without installing Agent or requiring SFTP',
    (tester) async {
      final core = _SSHHostsCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add Device'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add SSH Device only (no agent)'));
      await tester.pumpAndSettle();
      expect(find.text('Install DeviceBridge agent'), findsNothing);
      await tester.enterText(
        find.widgetWithText(TextField, 'Device name'),
        'SSH fixture',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'SSH host'),
        '192.168.50.10',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Username'),
        'guest',
      );
      await tester.ensureVisible(find.text('Verify host key'));
      await tester.tap(find.text('Verify host key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fingerprint matches'));
      await tester.pumpAndSettle();
      final save = find.text('Test and save SSH device');
      await tester.scrollUntilVisible(
        save,
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(core.hosts.single['expected_host_key'], 'SHA256:verified-fixture');
      expect(core.calls.any((a) => a.contains('ssh-bootstrap')), isFalse);
      expect(find.byKey(const ValueKey('ssh-host-terminal')), findsOneWidget);
      final checkBtn = find.byKey(const ValueKey('ssh-host-check-links'));
      await tester.scrollUntilVisible(
        checkBtn,
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(checkBtn);
      await tester.pumpAndSettle();
      expect(find.textContaining('Host OS: Linux'), findsOneWidget);
      expect(
        find.textContaining('tailnet (tailscale0): 100.88.1.2/32'),
        findsOneWidget,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('SSH devices'), findsOneWidget);
      expect(find.text('SSH fixture'), findsOneWidget);
      expect(
        find.byKey(ValueKey('ssh-device-upgrade-${core.hosts.single['id']}')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(ValueKey('ssh-device-upgrade-${core.hosts.single['id']}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Setup & auto-pair via SSH'), findsOneWidget);
      expect(find.text('192.168.50.10'), findsOneWidget);
      expect(find.text('guest'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Direct'));
      await tester.pumpAndSettle();
      expect(find.text('DeviceBridge devices'), findsOneWidget);
    },
  );
  testWidgets(
    'Incoming Agent SSH can be disabled independently of tsnet and OpenSSH',
    (tester) async {
      final core = _SSHHostsCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Networks'));
      await tester.pumpAndSettle();
      final agent = find.byKey(const ValueKey('ssh-backend-agent'));
      await tester.ensureVisible(agent);
      await tester.tap(agent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disable'));
      await tester.pumpAndSettle();
      expect(core.policy['network_agent_ssh'], isFalse);
      expect(core.settings['tsnet_ssh_enabled'], isTrue);
      expect(core.settings['tsnet_openssh_enabled'], isFalse);
      expect(core.calls.any((a) => a.contains('restart-agent')), isFalse);
    },
  );
  testWidgets(
    'ACL rules and device groups evaluate tag:trusted full access vs untagged default-deny',
    (tester) async {
      final core = _SSHHostsCore();
      await tester.pumpWidget(DeviceBridgeApp(core: core));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Devices').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('devices-acl-button')));
      await tester.pumpAndSettle();

      expect(find.text('Tailscale-style ACL policy'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('acl-preset-trusted')));
      await tester.pumpAndSettle();

      final listScroll = find
          .descendant(
            of: find.byKey(const ValueKey('acl-listview')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Denied all services'),
        200,
        scrollable: listScroll,
      );
      expect(find.text('Denied all services'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('acl-add-tag-laptop')),
        -200,
        scrollable: listScroll,
      );
      await tester.tap(find.byKey(const ValueKey('acl-add-tag-laptop')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('tag:trusted'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('All services allowed'),
        200,
        scrollable: listScroll,
      );
      expect(find.text('All services allowed'), findsOneWidget);
    },
  );
  testWidgets(
    'FileManager prompts cleanly when Internal storage permission is missing and switches to Termux Home',
    (tester) async {
      var storageGranted = false;
      final core = _PermFileCore(() => storageGranted, () {
        storageGranted = true;
      });
      await tester.pumpWidget(MaterialApp(home: FileManager(core: core)));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('file-pane-0-storage-prompt')),
        findsOneWidget,
      );
      expect(find.text('Phone storage access needed'), findsNWidgets(2));
      expect(core.listedInternalBeforeGrant, isFalse);

      await tester.tap(
        find.byKey(const ValueKey('file-pane-0-open-termux-home')),
      );
      await tester.pumpAndSettle();
      expect(find.text('termux-notes.txt'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('file-pane-1-grant-storage')),
      );
      await tester.pumpAndSettle();
      expect(core.requestedPermissions, contains('storage'));
      expect(find.text('DCIM'), findsOneWidget);
    },
  );
  testWidgets(
    'PermissionWizardDialog requests Standard runtime permissions and supports Shizuku auto-grant',
    (tester) async {
      final core = _PermWizardCore();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PermissionWizardDialog(core: core)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Permissions setup'), findsOneWidget);
      expect(find.text('Phone storage (All files access)'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('permission-wizard-runtime-batch')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('permission-wizard-runtime-batch')),
      );
      await tester.pumpAndSettle();
      expect(core.requested, contains('runtime_batch'));

      await tester.tap(find.byKey(const ValueKey('permission-wizard-shizuku')));
      await tester.pumpAndSettle();
      expect(core.wizardSettings['shizuku_enabled'], isTrue);
      expect(
        find.text('Shizuku verified and all permissions granted automatically.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('permission-wizard-done')));
      await tester.pumpAndSettle();
      expect(core.wizardSettings['permissions_wizard_done'], isTrue);
    },
  );
  testWidgets(
    'pickSshPrivateKey picks from Termux ~/.ssh or Termux Home instead of only device storage',
    (tester) async {
      final core = _SshKeyPickerCore();
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  picked = await pickSshPrivateKey(context, core);
                },
                child: const Text('Pick key'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pick key'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('ssh-key-item-id_ed25519')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ssh-key-item-id_ed25519')));
      await tester.pumpAndSettle();
      expect(picked, 'TERMUX_ED25519_KEY');
      expect(core.usedSystemPicker, isFalse);
    },
  );
}

class _SshKeyPickerCore extends FakeCore {
  bool usedSystemPicker = false;

  @override
  Future<List<Map<String, String>>> listSshKeys() async => [
    {'name': 'id_ed25519', 'path': '.ssh/id_ed25519'},
  ];

  @override
  Future<String?> readSshKey(Map<String, String> keyRef) async =>
      keyRef['path'] == '.ssh/id_ed25519' ? 'TERMUX_ED25519_KEY' : null;

  @override
  Future<String?> pickSshKeyText() async {
    usedSystemPicker = true;
    return 'INTERNAL_KEY';
  }
}

class _PermFileCore extends FakeCore {
  _PermFileCore(this.hasStorage, this.grantStorage);

  final bool Function() hasStorage;
  final VoidCallback grantStorage;
  bool listedInternalBeforeGrant = false;
  final List<String> requestedPermissions = [];

  @override
  Future<dynamic> localFiles(
    String operation,
    Map<String, dynamic> arguments,
  ) async {
    final granted = hasStorage();
    if (operation == 'roots') {
      return [
        {'id': 'internal', 'name': 'Internal storage', 'available': granted},
        {
          'id': 'termux_home',
          'name': 'Termux Home',
          'available': true,
          'native_path':
              '/data/user/0/dev.devicebridge.devicebridge/files/terminal/files/home',
        },
        {'id': 'recycle_bin', 'name': 'Recycle Bin', 'available': true},
      ];
    }
    if (operation == 'list') {
      final kind = '${arguments['kind'] ?? ''}';
      if (kind == 'internal') {
        if (!granted) {
          listedInternalBeforeGrant = true;
          throw PlatformException(
            code: 'local_files_failed',
            message: 'Grant phone storage access first',
          );
        }
        return {
          'entries': [
            {'name': 'DCIM', 'path': 'DCIM', 'kind': 'directory', 'size': 0},
          ],
          'next': '',
        };
      }
      if (kind == 'termux_home') {
        return {
          'entries': [
            {
              'name': 'termux-notes.txt',
              'path': 'termux-notes.txt',
              'kind': 'file',
              'size': 42,
            },
          ],
          'next': '',
        };
      }
    }
    return {'entries': []};
  }

  @override
  Future<Map<String, dynamic>> requestAppPermission(String id) async {
    requestedPermissions.add(id);
    if (id == 'storage') {
      grantStorage();
    }
    return permissionsStatus(autoGrant: false);
  }
}

class _PermWizardCore extends FakeCore {
  final Map<String, dynamic> wizardSettings = {
    'permissions_wizard_done': false,
  };
  final List<String> requested = [];
  bool storageGranted = false;
  bool wifiGranted = false;
  bool notifGranted = false;
  bool shizukuGranted = false;

  Map<String, dynamic> _snapshot() {
    final mode = shizukuGranted ? 'shizuku' : 'standard';
    final items = [
      {
        'id': 'storage',
        'title': 'Phone storage (All files access)',
        'description': 'Browse internal phone folders.',
        'granted': storageGranted,
        'required': true,
        'kind': 'special',
      },
      {
        'id': 'wifi_nearby',
        'title': 'Wi-Fi & Nearby devices',
        'description': 'Required in Standard mode.',
        'granted': wifiGranted,
        'required': mode == 'standard',
        'kind': 'runtime',
      },
      {
        'id': 'notifications',
        'title': 'Notifications',
        'description': 'Transfer controls.',
        'granted': notifGranted,
        'required': true,
        'kind': 'runtime',
      },
    ];
    final allGranted = items.every((e) => e['granted'] == true);
    return {
      'execution_mode': mode,
      'root_enabled': false,
      'shizuku_running': true,
      'shizuku_granted': shizukuGranted,
      'shizuku_enabled': shizukuGranted,
      'wizard_completed': wizardSettings['permissions_wizard_done'] == true,
      'all_essential_granted': allGranted,
      'all_granted': allGranted,
      'has_missing_runtime': !wifiGranted || !notifGranted,
      'permissions': items,
    };
  }

  @override
  Future<Map<String, dynamic>> appSettings({
    Map<String, dynamic>? update,
  }) async {
    if (update != null) {
      wizardSettings.addAll(update);
      if (update['shizuku_enabled'] == true) {
        shizukuGranted = true;
      }
    }
    return Map<String, dynamic>.from(wizardSettings);
  }

  @override
  Future<Map<String, dynamic>> permissionsStatus({bool autoGrant = true}) async =>
      _snapshot();

  @override
  Future<Map<String, dynamic>> autoGrantPermissions() async {
    if (shizukuGranted) {
      storageGranted = true;
      wifiGranted = true;
      notifGranted = true;
    }
    return _snapshot();
  }

  @override
  Future<Map<String, dynamic>> requestAppPermission(String id) async {
    requested.add(id);
    if (id == 'runtime_batch') {
      wifiGranted = true;
      notifGranted = true;
    } else if (id == 'storage') {
      storageGranted = true;
    }
    return _snapshot();
  }
}
