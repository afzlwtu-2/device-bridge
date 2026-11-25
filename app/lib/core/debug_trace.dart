import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

class DebugTraceEntry {
  const DebugTraceEntry({
    required this.timestamp,
    required this.kind,
    required this.source,
    required this.message,
    this.detail,
  });

  final DateTime timestamp;
  final String kind; // 'error' | 'flow' | 'screen' | 'core'
  final String source;
  final String message;
  final String? detail;

  Map<String, dynamic> toJson() => {
    'ts': timestamp.toIso8601String(),
    'kind': kind,
    'source': source,
    'message': message,
    if (detail != null && detail!.isNotEmpty) 'detail': detail,
  };

  static DebugTraceEntry? fromJson(Map<String, dynamic> m) {
    final tsRaw = m['ts'] as String?;
    final kind = m['kind'] as String?;
    final src = m['source'] as String?;
    final msg = m['message'] as String?;
    if (tsRaw == null || kind == null || src == null || msg == null) {
      return null;
    }
    final ts = DateTime.tryParse(tsRaw);
    if (ts == null) {
      return null;
    }
    return DebugTraceEntry(
      timestamp: ts,
      kind: kind,
      source: src,
      message: msg,
      detail: m['detail'] as String?,
    );
  }
}

/// Captures runtime failures, screen transitions, and connection/feature flows
/// whenever Global Settings -> `debug_mode` is enabled.
class DebugTrace extends ChangeNotifier {
  DebugTrace._();
  static final DebugTrace instance = DebugTrace._();

  static const int _maxEntries = 400;
  static const int _maxFileBytes = 512 * 1024;
  static bool enabled = true;

  final List<DebugTraceEntry> _entries = [];
  String _traceFilePath = '';
  bool _loadedFile = false;

  List<DebugTraceEntry> get entries => List.unmodifiable(_entries);
  int get errorCount => _entries.where((e) => e.kind == 'error').length;

  static void setEnabled(bool value) {
    if (enabled == value) {
      return;
    }
    enabled = value;
    instance.notifyListeners();
  }

  static Future<void> configureStateDir(String stateDir) async {
    if (stateDir.isEmpty) {
      return;
    }
    final nextPath = '$stateDir/debug-trace.jsonl';
    if (instance._traceFilePath == nextPath && instance._loadedFile) {
      return;
    }
    instance._traceFilePath = nextPath;
    instance._loadedFile = true;
    try {
      final f = File(nextPath);
      if (await f.exists()) {
        final lines = await f.readAsLines();
        final start = lines.length > 200 ? lines.length - 200 : 0;
        final loaded = <DebugTraceEntry>[];
        for (final line in lines.sublist(start)) {
          if (line.trim().isEmpty) continue;
          try {
            final parsed = DebugTraceEntry.fromJson(
              Map<String, dynamic>.from(jsonDecode(line) as Map),
            );
            if (parsed != null) {
              loaded.add(parsed);
            }
          } catch (_) {}
        }
        if (loaded.isNotEmpty) {
          final existingTs = instance._entries.map((e) => e.timestamp).toSet();
          for (final item in loaded.reversed) {
            if (!existingTs.contains(item.timestamp)) {
              instance._entries.add(item);
            }
          }
          if (instance._entries.length > _maxEntries) {
            instance._entries.removeRange(
              _maxEntries,
              instance._entries.length,
            );
          }
          instance.notifyListeners();
        }
      }
    } catch (_) {}
  }

  static String sanitizeText(String raw) {
    return raw
        .replaceAll(
          RegExp(
            r'("(?:passphrase|password|private_key_pem|key_passphrase|sudo_password)"\s*:\s*")([^"]*)(")',
            caseSensitive: false,
          ),
          r'$1***$3',
        )
        .replaceAll(
          RegExp(r'password\s+\S+', caseSensitive: false),
          'password ***',
        );
  }

  static void record(
    String kind,
    String source,
    String message, {
    Object? detail,
  }) {
    if (!enabled) {
      return;
    }
    final cleanMsg = sanitizeText(message);
    final rawDetail = detail == null ? null : sanitizeText('$detail');
    final cleanDetail = rawDetail == null
        ? null
        : (rawDetail.length > 1500
              ? '${rawDetail.substring(0, 1500)}…'
              : rawDetail);
    final entry = DebugTraceEntry(
      timestamp: DateTime.now(),
      kind: kind,
      source: source,
      message: cleanMsg,
      detail: cleanDetail,
    );
    final inst = instance;
    inst._entries.insert(0, entry);
    if (inst._entries.length > _maxEntries) {
      inst._entries.removeRange(_maxEntries, inst._entries.length);
    }
    inst.notifyListeners();
    if (inst._traceFilePath.isNotEmpty) {
      try {
        final f = File(inst._traceFilePath);
        if (f.existsSync() && f.lengthSync() > _maxFileBytes) {
          final keep = inst._entries.take(150).toList().reversed;
          f.writeAsStringSync(
            '${keep.map((e) => jsonEncode(e.toJson())).join('\n')}\n',
          );
        } else {
          f.writeAsStringSync(
            '${jsonEncode(entry.toJson())}\n',
            mode: FileMode.append,
          );
        }
      } catch (_) {}
    }
  }

  static void logScreen(String action, String screen, {String? detail}) =>
      record('screen', 'Navigation', '$action: $screen', detail: detail);

  static void logFlow(String source, String step, {Object? detail}) =>
      record('flow', source, step, detail: detail);

  static void logError(String source, String message, {Object? error}) =>
      record('error', source, message, detail: error);

  static void logCore(String op, String message, {Object? detail}) =>
      record('core', op, message, detail: detail);

  static Future<void> clear() async {
    instance._entries.clear();
    if (instance._traceFilePath.isNotEmpty) {
      try {
        final f = File(instance._traceFilePath);
        if (await f.exists()) {
          await f.writeAsString('');
        }
      } catch (_) {}
    }
    instance.notifyListeners();
  }

  static String exportText() {
    final buf = StringBuffer();
    for (final e in instance._entries) {
      final t = e.timestamp.toIso8601String();
      buf.writeln('[$t] [${e.kind.toUpperCase()}] [${e.source}] ${e.message}');
      if (e.detail != null && e.detail!.isNotEmpty) {
        buf.writeln('  ${e.detail}');
      }
    }
    return buf.toString();
  }
}

/// Automatically records Material route transitions when `DebugTrace.enabled` is true.
class DebugNavigatorObserver extends NavigatorObserver {
  String _label(Route<dynamic>? route) {
    if (route == null) return 'unknown';
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    if (route is PageRoute) {
      return route.runtimeType.toString();
    }
    return route.runtimeType.toString();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    DebugTrace.logScreen(
      'Push',
      _label(route),
      detail: previousRoute == null ? null : 'from ${_label(previousRoute)}',
    );
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    DebugTrace.logScreen(
      'Pop',
      _label(route),
      detail: previousRoute == null ? null : 'to ${_label(previousRoute)}',
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    DebugTrace.logScreen(
      'Replace',
      _label(newRoute),
      detail: oldRoute == null ? null : 'replaced ${_label(oldRoute)}',
    );
  }
}
