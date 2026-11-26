import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm3/xterm.dart';

import '../core/bridge.dart';
import 'appearance.dart';

class _TerminalVisualPalette {
  const _TerminalVisualPalette({
    required this.terminalTheme,
    required this.backgroundOpacity,
    required this.terminalCardColor,
    required this.terminalCardBorder,
    required this.terminalCardMargin,
    required this.terminalCardRadius,
    required this.deckColor,
    required this.keyColor,
    required this.actionKeyColor,
    required this.spaceBarColor,
    required this.activeKeyColor,
    required this.pressedKeyColor,
    required this.borderColor,
    required this.activeBorderColor,
    required this.borderWidth,
    required this.labelColor,
    required this.activeLabelColor,
    required this.lockedLabelColor,
    required this.subLabelColor,
    required this.spaceLabelColor,
  });

  final TerminalTheme terminalTheme;
  final double backgroundOpacity;
  final Color terminalCardColor;
  final Border? terminalCardBorder;
  final EdgeInsets terminalCardMargin;
  final BorderRadius terminalCardRadius;
  final Color deckColor;
  final Color keyColor;
  final Color actionKeyColor;
  final Color spaceBarColor;
  final Color activeKeyColor;
  final Color pressedKeyColor;
  final Color borderColor;
  final Color activeBorderColor;
  final double borderWidth;
  final Color labelColor;
  final Color activeLabelColor;
  final Color lockedLabelColor;
  final Color subLabelColor;
  final Color spaceLabelColor;

  static _TerminalVisualPalette resolve(
    BuildContext context,
    String appearance,
    AmoledStyleConfig amoled,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (appearance == 'matte') {
      const ink = Color(0xff1b1e14);
      const cream = Color(0xfff7f3dd);
      const parchment = Color(0xffede9c9);
      const olive = Color(0xff4e5c1f);
      const gold = Color(0xffe5b93c);
      return _TerminalVisualPalette(
        terminalTheme: const TerminalTheme(
          cursor: olive,
          selection: Color(0x66e5b93c),
          foreground: ink,
          background: cream,
          black: ink,
          red: Color(0xffb91c1c),
          green: Color(0xff3f6212),
          yellow: Color(0xffa16207),
          blue: Color(0xff1d4ed8),
          magenta: Color(0xff7e22ce),
          cyan: Color(0xff0f766e),
          white: Color(0xff57534e),
          brightBlack: Color(0xff78716c),
          brightRed: Color(0xffdc2626),
          brightGreen: Color(0xff4d7c0f),
          brightYellow: Color(0xffca8a04),
          brightBlue: Color(0xff2563eb),
          brightMagenta: Color(0xff9333ea),
          brightCyan: Color(0xff0d9488),
          brightWhite: ink,
          searchHitBackground: gold,
          searchHitBackgroundCurrent: olive,
          searchHitForeground: cream,
        ),
        backgroundOpacity: 0.0,
        terminalCardColor: const Color(0xebf7f3dd),
        terminalCardBorder: Border.all(color: ink, width: 2.0),
        terminalCardMargin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
        terminalCardRadius: BorderRadius.circular(18),
        deckColor: Colors.transparent,
        keyColor: cream,
        actionKeyColor: parchment,
        spaceBarColor: cream,
        activeKeyColor: gold,
        pressedKeyColor: const Color(0xfff0dda1),
        borderColor: ink,
        activeBorderColor: ink,
        borderWidth: 1.6,
        labelColor: ink,
        activeLabelColor: ink,
        lockedLabelColor: olive,
        subLabelColor: const Color(0xff4b503a),
        spaceLabelColor: const Color(0xff4b503a),
      );
    }

    if (isAmoledTheme(appearance)) {
      final accent = Color(amoled.selectedTabColor);
      final peak = Color(amoled.peakColor);
      final edge = Color(amoled.edgeColor);
      final selText = Color(amoled.selectedTextColor);
      final activeFg =
          ThemeData.estimateBrightnessForColor(accent) == Brightness.light
          ? selText
          : Colors.white;
      return _TerminalVisualPalette(
        terminalTheme: TerminalTheme(
          cursor: Color(amoled.buttonColor),
          selection: peak.withValues(alpha: 0.35),
          foreground: const Color(0xfff0f6fc),
          background: Colors.black,
          black: const Color(0xff161b22),
          red: const Color(0xffff7b72),
          green: const Color(0xff3fb950),
          yellow: const Color(0xffd29922),
          blue: const Color(0xff58a6ff),
          magenta: const Color(0xffbc8cff),
          cyan: const Color(0xff39c5cf),
          white: const Color(0xffb1bac4),
          brightBlack: const Color(0xff6e7681),
          brightRed: const Color(0xffffa198),
          brightGreen: const Color(0xff56d364),
          brightYellow: const Color(0xffe3b341),
          brightBlue: const Color(0xff79c0ff),
          brightMagenta: const Color(0xffd2a8ff),
          brightCyan: const Color(0xff56d4dd),
          brightWhite: Colors.white,
          searchHitBackground: const Color(0xffd29922),
          searchHitBackgroundCurrent: peak,
          searchHitForeground: Colors.black,
        ),
        backgroundOpacity: 0.0,
        terminalCardColor: Colors.transparent,
        terminalCardBorder: null,
        terminalCardMargin: EdgeInsets.zero,
        terminalCardRadius: BorderRadius.zero,
        deckColor: Colors.transparent,
        keyColor: const Color(0xff080808),
        actionKeyColor: const Color(0xff040404),
        spaceBarColor: const Color(0xff0a0a0a),
        activeKeyColor: accent,
        pressedKeyColor: const Color(0xff1a1a1a),
        borderColor: Color.lerp(const Color(0xff262626), edge, 0.28)!,
        activeBorderColor: accent,
        borderWidth: 1.0,
        labelColor: const Color(0xfff5f5f5),
        activeLabelColor: activeFg,
        lockedLabelColor: peak,
        subLabelColor: const Color(0xffb8b8b8),
        spaceLabelColor: const Color(0xff8a8a8a),
      );
    }

    final isLight =
        appearance == 'light' ||
        (appearance == 'system' && theme.brightness == Brightness.light);
    if (isLight) {
      const fg = Color(0xff172120);
      final bg = theme.scaffoldBackgroundColor;
      return _TerminalVisualPalette(
        terminalTheme: TerminalTheme(
          cursor: scheme.primary,
          selection: scheme.primary.withValues(alpha: 0.24),
          foreground: fg,
          background: bg,
          black: fg,
          red: const Color(0xffb91c1c),
          green: const Color(0xff15803d),
          yellow: const Color(0xffb45309),
          blue: const Color(0xff1d4ed8),
          magenta: const Color(0xff7e22ce),
          cyan: const Color(0xff0f766e),
          white: const Color(0xff64748b),
          brightBlack: const Color(0xff475569),
          brightRed: const Color(0xffdc2626),
          brightGreen: const Color(0xff16a34a),
          brightYellow: const Color(0xffd97706),
          brightBlue: const Color(0xff2563eb),
          brightMagenta: const Color(0xff9333ea),
          brightCyan: const Color(0xff0d9488),
          brightWhite: fg,
          searchHitBackground: const Color(0xfffacc15),
          searchHitBackgroundCurrent: scheme.primary,
          searchHitForeground: Colors.white,
        ),
        backgroundOpacity: 0.0,
        terminalCardColor: Colors.transparent,
        terminalCardBorder: null,
        terminalCardMargin: EdgeInsets.zero,
        terminalCardRadius: BorderRadius.zero,
        deckColor: const Color(0xffe5ecea),
        keyColor: Colors.white,
        actionKeyColor: const Color(0xffd6e0dd),
        spaceBarColor: const Color(0xfff0f5f3),
        activeKeyColor: scheme.primary,
        pressedKeyColor: scheme.primaryContainer,
        borderColor: const Color(0xffb8c7c3),
        activeBorderColor: scheme.primary,
        borderWidth: 1.0,
        labelColor: fg,
        activeLabelColor: scheme.onPrimary,
        lockedLabelColor: const Color(0xff15803d),
        subLabelColor: const Color(0xff4c5c59),
        spaceLabelColor: const Color(0xff647572),
      );
    }

    // Standard Dark theme
    final bg = theme.scaffoldBackgroundColor;
    return _TerminalVisualPalette(
      terminalTheme: TerminalTheme(
        cursor: scheme.primary,
        selection: scheme.primary.withValues(alpha: 0.28),
        foreground: const Color(0xffe6edf3),
        background: bg,
        black: const Color(0xff161b22),
        red: const Color(0xffff7b72),
        green: const Color(0xff3fb950),
        yellow: const Color(0xffd29922),
        blue: const Color(0xff58a6ff),
        magenta: const Color(0xffbc8cff),
        cyan: const Color(0xff39c5cf),
        white: const Color(0xffb1bac4),
        brightBlack: const Color(0xff6e7681),
        brightRed: const Color(0xffffa198),
        brightGreen: const Color(0xff56d364),
        brightYellow: const Color(0xffe3b341),
        brightBlue: const Color(0xff79c0ff),
        brightMagenta: const Color(0xffd2a8ff),
        brightCyan: const Color(0xff56d4dd),
        brightWhite: Colors.white,
        searchHitBackground: const Color(0xffd29922),
        searchHitBackgroundCurrent: scheme.primary,
        searchHitForeground: Colors.black,
      ),
      backgroundOpacity: 0.0,
      terminalCardColor: Colors.transparent,
      terminalCardBorder: null,
      terminalCardMargin: EdgeInsets.zero,
      terminalCardRadius: BorderRadius.zero,
      deckColor: const Color(0xff141c1b),
      keyColor: const Color(0xff212c2a),
      actionKeyColor: const Color(0xff18211f),
      spaceBarColor: const Color(0xff1c2624),
      activeKeyColor: scheme.primary,
      pressedKeyColor: const Color(0xff2c3a37),
      borderColor: const Color(0xff31403d),
      activeBorderColor: scheme.primary,
      borderWidth: 1.0,
      labelColor: const Color(0xffe6edf3),
      activeLabelColor: scheme.onPrimary,
      lockedLabelColor: const Color(0xff3fb950),
      subLabelColor: const Color(0xffa5b8b4),
      spaceLabelColor: const Color(0xff7c908c),
    );
  }
}

class TerminalSystemStats {
  const TerminalSystemStats({
    this.rooted = false,
    this.shizuku = false,
    this.cpuAvailable = false,
    this.ramAvailable = true,
    this.gpuAvailable = false,
    this.cpuSource = '',
    this.gpuSource = '',
    this.cpuPercent = 0,
    this.ramPercent = 0,
    this.ramUsedGb = 0.0,
    this.ramTotalGb = 0.0,
    this.gpuPercent = 0,
  });

  final bool rooted;
  final bool shizuku;
  final bool cpuAvailable;
  final bool ramAvailable;
  final bool gpuAvailable;
  final String cpuSource;
  final String gpuSource;
  final int cpuPercent;
  final int ramPercent;
  final double ramUsedGb;
  final double ramTotalGb;
  final int gpuPercent;
}

class TerminalKeyboardConfig {
  const TerminalKeyboardConfig({
    this.fontSize = 13.5,
    this.rowHeight = 48.0,
    this.showNumberRow = false,
    this.showSubLabels = true,
    this.hapticFeedback = true,
    this.soundFeedback = false,
    this.vibrateDurationMs = 18,
    this.showKeyPopup = true,
    this.pressAnimation = true,
    this.bellMode = 'beep_vibrate',
    this.flickThreshold = 12.0,
    this.shell = 'fish',
    this.showCpuUsage = true,
    this.showRamUsage = true,
    this.showGpuUsage = true,
    this.statsIntervalMs = 2000,
    this.configKeyAction = 'terminal_settings',
    this.spaceNorthAction = 'command_palette',
    this.spaceSouthAction = 'switch_backward',
    this.enterNorthAction = 'command_palette',
  });

  final double fontSize;
  final double rowHeight;
  final bool showNumberRow;
  final bool showSubLabels;
  final bool hapticFeedback;
  final bool soundFeedback;
  final int vibrateDurationMs;
  final bool showKeyPopup;
  final bool pressAnimation;
  final String bellMode;
  final double flickThreshold;
  final String shell;
  final bool showCpuUsage;
  final bool showRamUsage;
  final bool showGpuUsage;
  final int statsIntervalMs;
  final String configKeyAction;
  final String spaceNorthAction;
  final String spaceSouthAction;
  final String enterNorthAction;

  TerminalKeyboardConfig copyWith({
    double? fontSize,
    double? rowHeight,
    bool? showNumberRow,
    bool? showSubLabels,
    bool? hapticFeedback,
    bool? soundFeedback,
    int? vibrateDurationMs,
    bool? showKeyPopup,
    bool? pressAnimation,
    String? bellMode,
    double? flickThreshold,
    String? shell,
    bool? showCpuUsage,
    bool? showRamUsage,
    bool? showGpuUsage,
    int? statsIntervalMs,
    String? configKeyAction,
    String? spaceNorthAction,
    String? spaceSouthAction,
    String? enterNorthAction,
  }) => TerminalKeyboardConfig(
    fontSize: fontSize ?? this.fontSize,
    rowHeight: rowHeight ?? this.rowHeight,
    showNumberRow: showNumberRow ?? this.showNumberRow,
    showSubLabels: showSubLabels ?? this.showSubLabels,
    hapticFeedback: hapticFeedback ?? this.hapticFeedback,
    soundFeedback: soundFeedback ?? this.soundFeedback,
    vibrateDurationMs: vibrateDurationMs ?? this.vibrateDurationMs,
    showKeyPopup: showKeyPopup ?? this.showKeyPopup,
    pressAnimation: pressAnimation ?? this.pressAnimation,
    bellMode: bellMode ?? this.bellMode,
    flickThreshold: flickThreshold ?? this.flickThreshold,
    shell: shell ?? this.shell,
    showCpuUsage: showCpuUsage ?? this.showCpuUsage,
    showRamUsage: showRamUsage ?? this.showRamUsage,
    showGpuUsage: showGpuUsage ?? this.showGpuUsage,
    statsIntervalMs: statsIntervalMs ?? this.statsIntervalMs,
    configKeyAction: configKeyAction ?? this.configKeyAction,
    spaceNorthAction: spaceNorthAction ?? this.spaceNorthAction,
    spaceSouthAction: spaceSouthAction ?? this.spaceSouthAction,
    enterNorthAction: enterNorthAction ?? this.enterNorthAction,
  );

  Map<String, dynamic> toJson() => {
    'font_size': fontSize,
    'row_height': rowHeight,
    'show_number_row': showNumberRow,
    'show_sub_labels': showSubLabels,
    'haptic_feedback': hapticFeedback,
    'sound_feedback': soundFeedback,
    'vibrate_duration_ms': vibrateDurationMs,
    'show_key_popup': showKeyPopup,
    'press_animation': pressAnimation,
    'bell_mode': bellMode,
    'flick_threshold': flickThreshold,
    'shell': shell,
    'show_cpu_usage': showCpuUsage,
    'show_ram_usage': showRamUsage,
    'show_gpu_usage': showGpuUsage,
    'stats_interval_ms': statsIntervalMs,
    'config_key_action': configKeyAction,
    'space_north_action': spaceNorthAction,
    'space_south_action': spaceSouthAction,
    'enter_north_action': enterNorthAction,
  };

  factory TerminalKeyboardConfig.fromJson(Map<String, dynamic> map) {
    const base = TerminalKeyboardConfig();
    return TerminalKeyboardConfig(
      fontSize: ((map['font_size'] as num?)?.toDouble() ?? base.fontSize).clamp(
        8.0,
        28.0,
      ),
      rowHeight: ((map['row_height'] as num?)?.toDouble() ?? base.rowHeight)
          .clamp(34.0, 66.0),
      showNumberRow: map['show_number_row'] == true,
      showSubLabels: map['show_sub_labels'] != false,
      hapticFeedback: map['haptic_feedback'] != false,
      soundFeedback: map['sound_feedback'] == true,
      vibrateDurationMs:
          ((map['vibrate_duration_ms'] as num?)?.toInt() ??
                  base.vibrateDurationMs)
              .clamp(0, 60),
      showKeyPopup: map['show_key_popup'] != false,
      pressAnimation: map['press_animation'] != false,
      bellMode: (map['bell_mode'] as String?)?.isNotEmpty == true
          ? map['bell_mode'] as String
          : base.bellMode,
      flickThreshold:
          ((map['flick_threshold'] as num?)?.toDouble() ?? base.flickThreshold)
              .clamp(6.0, 32.0),
      shell: (map['shell'] as String?)?.isNotEmpty == true
          ? map['shell'] as String
          : base.shell,
      showCpuUsage: map['show_cpu_usage'] != false,
      showRamUsage: map['show_ram_usage'] != false,
      showGpuUsage: map['show_gpu_usage'] != false,
      statsIntervalMs:
          ((map['stats_interval_ms'] as num?)?.toInt() ?? base.statsIntervalMs)
              .clamp(500, 30000),
      configKeyAction:
          (map['config_key_action'] as String?) == 'termux_settings'
          ? 'terminal_settings'
          : ((map['config_key_action'] as String?) ?? base.configKeyAction),
      spaceNorthAction:
          (map['space_north_action'] as String?) ?? base.spaceNorthAction,
      spaceSouthAction:
          (map['space_south_action'] as String?) ?? base.spaceSouthAction,
      enterNorthAction:
          (map['enter_north_action'] as String?) ?? base.enterNorthAction,
    );
  }
}

class TerminalWorkspaceScope extends InheritedWidget {
  const TerminalWorkspaceScope({
    super.key,
    required this.openRemote,
    required super.child,
  });

  final void Function(Map<String, dynamic> target) openRemote;

  static TerminalWorkspaceScope? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<TerminalWorkspaceScope>();

  @override
  bool updateShouldNotify(TerminalWorkspaceScope oldWidget) =>
      openRemote != oldWidget.openRemote;
}

class _TerminalSessionEntry {
  _TerminalSessionEntry({
    required this.id,
    required this.name,
    required this.terminal,
    this.remote,
  });

  final String id;
  String name;
  final Terminal terminal;
  final Map<String, dynamic>? remote;
  final GlobalKey<TerminalViewState> viewKey = GlobalKey<TerminalViewState>();
  final FocusNode focusNode = FocusNode();
  VoidCallback? onBell;
  bool resourcesDisposed = false;

  void disposeResources() {
    if (resourcesDisposed) return;
    resourcesDisposed = true;
    focusNode.dispose();
  }

  StreamController<List<int>>? rawOutput;
  GuestTerminalLink? link;
  StreamSubscription<String>? frames;
  StreamSubscription<String>? text;
  bool ready = false;
  bool closing = false;
  String? setupPhase;
  String? setupMessage;
  int? setupBytes;
  int? setupTotal;

  Future<void> close() async {
    closing = true;
    await frames?.cancel();
    frames = null;
    await text?.cancel();
    text = null;
    await rawOutput?.close();
    rawOutput = null;
    final active = link;
    link = null;
    if (active != null) {
      try {
        await active.close();
      } catch (_) {}
    }
  }
}

class _TerminalWorkspaceCache {
  final List<_TerminalSessionEntry> sessions = [];
  int currentIndex = 0;
  int nextSessionNumber = 1;
  TerminalKeyboardConfig config = const TerminalKeyboardConfig();
  bool configLoaded = false;
  TerminalSystemStats stats = const TerminalSystemStats();
  final List<String> clipboardHistory = [];
}

class LocalTerminalScreen extends StatefulWidget {
  const LocalTerminalScreen({
    super.key,
    required this.core,
    this.appearance = 'system',
    this.amoledConfig,
    this.isActive = true,
    this.onConfigChanged,
    this.onStatsChanged,
    this.onOpenAppSettings,
    this.onTerminalExited,
    this.onSessionChanged,
  });

  final CoreBridge core;
  final String appearance;
  final AmoledStyleConfig? amoledConfig;
  final bool isActive;
  final ValueChanged<TerminalKeyboardConfig>? onConfigChanged;
  final ValueChanged<TerminalSystemStats>? onStatsChanged;
  final VoidCallback? onOpenAppSettings;
  final VoidCallback? onTerminalExited;
  final ValueChanged<String?>? onSessionChanged;

  @override
  State<LocalTerminalScreen> createState() => LocalTerminalScreenState();
}

enum _KeyboardLayer { qwerty, numeric, greekMath }

class LocalTerminalScreenState extends State<LocalTerminalScreen>
    with WidgetsBindingObserver {
  static final Expando<_TerminalWorkspaceCache> _workspaces =
      Expando<_TerminalWorkspaceCache>('terminalWorkspaces');

  late final _TerminalWorkspaceCache _workspace;
  final GlobalKey _stackRootKey = GlobalKey();
  final _KeyPopupOverlayController _popupController =
      _KeyPopupOverlayController();
  final Map<int, Offset> _touchPointers = <int, Offset>{};
  double? _pinchBaseDistance;
  double? _pinchBaseFontSize;
  bool _keyboardVisible = true;
  bool _clipboardPanelOpen = false;
  bool _composePending = false;
  DateTime? _lastShiftTap;
  Timer? _statsTimer;
  bool _samplingStats = false;
  bool _restoringSessions = false;

  // Unexpected Keyboard sticky modifiers
  bool _shift = false;
  bool _capsLock = false;
  bool _ctrl = false;
  bool _alt = false;
  bool _fn = false;
  bool _meta = false;
  _KeyboardLayer _layer = _KeyboardLayer.qwerty;

  _TerminalSessionEntry get _currentSession =>
      _workspace.sessions[_workspace.currentIndex.clamp(
        0,
        _workspace.sessions.length - 1,
      )];

  TerminalKeyboardConfig get _config => _workspace.config;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _workspace =
        _workspaces[widget.core] ??
        (_workspaces[widget.core] = _TerminalWorkspaceCache());
    if (!_workspace.configLoaded) {
      unawaited(_loadSavedConfig());
    }
    if (_workspace.sessions.isEmpty) {
      unawaited(_restoreOrCreateSession());
    } else {
      // Rebind callbacks to the current mounted state
      for (final s in _workspace.sessions) {
        _bindTerminalCallbacks(s);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onConfigChanged?.call(_config);
      widget.onStatsChanged?.call(_workspace.stats);
      _syncStatsPolling();
      _ensureTerminalFocus();
    });
  }

  @override
  void didUpdateWidget(covariant LocalTerminalScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      if (widget.isActive && _workspace.sessions.isEmpty) {
        unawaited(_restoreOrCreateSession());
      }
      _syncStatsPolling();
      if (widget.isActive) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _ensureTerminalFocus(),
        );
      }
    }
  }

  void _ensureTerminalFocus() {
    if (!mounted || !widget.isActive || _workspace.sessions.isEmpty) return;
    widget.onSessionChanged?.call(_currentSession.remote?['name'] as String?);
    final node = _currentSession.focusNode;
    if (!node.hasFocus) {
      node.requestFocus();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _workspace.sessions) {
      s.onBell = null;
    }
    _statsTimer?.cancel();
    _statsTimer = null;
    _popupController.clearAll();
    _popupController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _syncStatsPolling();

  bool get _statsVisible {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return widget.isActive &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }

  void _syncStatsPolling() {
    _statsTimer?.cancel();
    _statsTimer = null;
    if (!_statsVisible) return;
    if (widget.core is! LocalCore || !Platform.isAndroid) return;
    unawaited(_refreshSystemStats());
    if (!_config.showCpuUsage &&
        !_config.showRamUsage &&
        !_config.showGpuUsage) {
      return;
    }
    final intervalMs = _config.statsIntervalMs.clamp(500, 30000);
    _statsTimer = Timer.periodic(Duration(milliseconds: intervalMs), (_) {
      if (mounted && _statsVisible) {
        unawaited(_refreshSystemStats());
      }
    });
  }

  Future<void> refreshStatsNow() => _refreshSystemStats();

  Future<void> _refreshSystemStats() async {
    if (_samplingStats ||
        !mounted ||
        !_statsVisible ||
        widget.core is! LocalCore ||
        !Platform.isAndroid) {
      return;
    }
    _samplingStats = true;
    try {
      final raw = await LocalCore.channel.invokeMethod<dynamic>(
        'terminalSystemStats',
        <String, dynamic>{
          'need_cpu': _config.showCpuUsage,
          'need_ram': _config.showRamUsage,
          'need_gpu': _config.showGpuUsage,
        },
      );
      if (!mounted || raw is! Map) return;
      final parsed = TerminalSystemStats(
        rooted: raw['rooted'] == true,
        shizuku: raw['shizuku'] == true,
        cpuAvailable: raw['cpu_available'] == true,
        ramAvailable: raw['ram_available'] != false,
        gpuAvailable: raw['gpu_available'] == true,
        cpuSource: '${raw['cpu_source'] ?? ''}',
        gpuSource: '${raw['gpu_source'] ?? ''}',
        cpuPercent: (raw['cpu_percent'] as num?)?.toInt() ?? 0,
        ramPercent: (raw['ram_percent'] as num?)?.toInt() ?? 0,
        ramUsedGb: (raw['ram_used_gb'] as num?)?.toDouble() ?? 0.0,
        ramTotalGb: (raw['ram_total_gb'] as num?)?.toDouble() ?? 0.0,
        gpuPercent: (raw['gpu_percent'] as num?)?.toInt() ?? 0,
      );
      _workspace.stats = parsed;
      widget.onStatsChanged?.call(parsed);
    } catch (_) {
    } finally {
      _samplingStats = false;
    }
  }

  Future<void> _loadSavedConfig() async {
    _workspace.configLoaded = true;
    try {
      final settings = await widget.core.appSettings();
      final raw =
          (settings['terminal_keyboard_config'] ??
                  settings['termux_keyboard_config'])
              as String?;
      if (raw != null && raw.isNotEmpty) {
        final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final next = TerminalKeyboardConfig.fromJson(decoded);
        if (mounted) {
          setState(() {
            _workspace.config = next;
          });
          widget.onConfigChanged?.call(next);
          _syncStatsPolling();
        } else {
          _workspace.config = next;
        }
      }
    } catch (_) {}
  }

  Future<void> _saveConfig(TerminalKeyboardConfig updated) async {
    final prev = _workspace.config;
    setState(() => _workspace.config = updated);
    widget.onConfigChanged?.call(updated);
    if (prev.statsIntervalMs != updated.statsIntervalMs ||
        prev.showCpuUsage != updated.showCpuUsage ||
        prev.showRamUsage != updated.showRamUsage ||
        prev.showGpuUsage != updated.showGpuUsage) {
      _syncStatsPolling();
    }
    try {
      await widget.core.appSettings(
        update: {'terminal_keyboard_config': jsonEncode(updated.toJson())},
      );
    } catch (_) {}
  }

  void _recordClipboard(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _workspace.clipboardHistory.remove(trimmed);
    _workspace.clipboardHistory.insert(0, trimmed);
    if (_workspace.clipboardHistory.length > 12) {
      _workspace.clipboardHistory.removeLast();
    }
  }

  void _bindTerminalCallbacks(_TerminalSessionEntry session) {
    session.onBell = _handleTerminalBell;
    session.terminal.onOutput = (text) => _sendRawText(text, session: session);
    session.terminal.onResize = (columns, rows, _, _) {
      unawaited(
        _sendFrame({'columns': columns, 'rows': rows}, session: session),
      );
    };
  }

  void _handleTerminalBell() {
    if (_config.bellMode == 'ignore') return;
    if (widget.core is LocalCore) {
      if (Platform.isAndroid) {
        unawaited(
          LocalCore.channel
              .invokeMethod<void>('terminalBell', {'mode': _config.bellMode})
              .catchError((_) {}),
        );
        return;
      }
      if (Platform.isLinux &&
          (_config.bellMode == 'beep' || _config.bellMode == 'beep_vibrate')) {
        unawaited(
          Process.run('/usr/bin/paplay', [
            '/usr/share/sounds/freedesktop/stereo/bell.oga',
          ]).catchError((_) => ProcessResult(0, 0, '', '')),
        );
        return;
      }
    }
    if (_config.bellMode == 'vibrate' || _config.bellMode == 'beep_vibrate') {
      HapticFeedback.mediumImpact();
    } else {
      SystemSound.play(SystemSoundType.alert);
    }
  }

  void _triggerKeyFeedback(
    String token, {
    bool isSwipeSlot = false,
    bool isRepeat = false,
  }) {
    if (isRepeat) {
      if (_config.hapticFeedback) {
        HapticFeedback.selectionClick();
      }
      return;
    }
    if (!_config.hapticFeedback && !_config.soundFeedback) return;
    if (widget.core is LocalCore && Platform.isAndroid) {
      unawaited(
        LocalCore.channel
            .invokeMethod<void>('terminalKeyFeedback', {
              'key': token,
              'haptic': _config.hapticFeedback,
              'sound': _config.soundFeedback,
              'is_swipe_slot': isSwipeSlot,
              'duration_ms': _config.vibrateDurationMs,
            })
            .catchError((_) {}),
      );
      return;
    }
    if (_config.hapticFeedback) {
      if (isSwipeSlot) {
        HapticFeedback.selectionClick();
      } else {
        HapticFeedback.lightImpact();
      }
    }
    if (_config.soundFeedback && !isSwipeSlot) {
      SystemSound.play(SystemSoundType.click);
    }
  }

  Future<void> _restoreOrCreateSession() async {
    if (_restoringSessions) return;
    _restoringSessions = true;
    try {
      final local = widget.core;
      var existing = const <String>[];
      if (local is LocalCore) {
        try {
          existing = await local.detachedLocalTerminals();
        } on PlatformException {
          // The normal terminal remains available if lookup fails.
        } on MissingPluginException {
          // A platform without the persistence method uses its normal terminal.
        }
      }
      if (!mounted || _workspace.sessions.isNotEmpty) return;
      if (existing.isEmpty) {
        await _createNewSession();
      } else {
        for (final id in existing) {
          if (!mounted) break;
          await _createNewSession(existingId: id);
        }
      }
    } finally {
      _restoringSessions = false;
    }
  }

  Future<void> openRemote(Map<String, dynamic> target) =>
      _createNewSession(remote: target);

  Future<void> _createNewSession({
    String? existingId,
    Map<String, dynamic>? remote,
  }) async {
    final num = _workspace.nextSessionNumber++;
    final id =
        existingId ?? 'terminal-$num-${DateTime.now().microsecondsSinceEpoch}';
    late final _TerminalSessionEntry entry;
    final terminal = Terminal(
      maxLines: 5000,
      allowRemoteResize: false,
      onBell: () => entry.onBell?.call(),
      onClipboardQuery: (_) => _workspace.clipboardHistory.isNotEmpty
          ? _workspace.clipboardHistory.first
          : null,
      onClipboardStore: (_, data) {
        _recordClipboard(data);
        Clipboard.setData(ClipboardData(text: data));
      },
    );
    entry = _TerminalSessionEntry(
      id: id,
      name: remote?['name'] as String? ?? 'Session $num',
      terminal: terminal,
      remote: remote,
    );
    _bindTerminalCallbacks(entry);
    setState(() {
      _workspace.sessions.add(entry);
      _workspace.currentIndex = _workspace.sessions.length - 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureTerminalFocus());
    await _startSessionProcess(entry, reattach: existingId != null);
  }

  Future<void> _startSessionProcess(
    _TerminalSessionEntry entry, {
    bool reattach = false,
  }) async {
    await entry.close();
    if (!mounted) return;
    entry.closing = false;
    setState(() {
      entry.ready = false;
      if (!reattach && entry.remote == null && Platform.isAndroid) {
        entry.setupPhase = 'prepare';
        entry.setupMessage = 'Starting Termux terminal...';
        entry.setupBytes = null;
        entry.setupTotal = null;
      } else {
        entry.setupPhase = null;
        entry.setupMessage = null;
        entry.setupBytes = null;
        entry.setupTotal = null;
      }
    });

    final local = widget.core;
    if (local is! LocalCore) {
      entry.terminal.write('\x1b[1;36m\uf120 ~\x1b[0m \x1b[1;32m❯\x1b[0m \r\n');
      if (mounted) setState(() => entry.ready = true);
      return;
    }

    final rawOut = StreamController<List<int>>();
    entry.rawOutput = rawOut;
    entry.text = rawOut.stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(entry.terminal.write);

    try {
      final link = await local.openLocalTerminal({
        'session_id': entry.id,
        if (reattach) 'reattach': true,
        if (entry.remote != null) 'remote': entry.remote,
        'columns': entry.terminal.viewWidth > 0 ? entry.terminal.viewWidth : 80,
        'rows': entry.terminal.viewHeight > 0 ? entry.terminal.viewHeight : 24,
        if (_config.shell.isNotEmpty && _config.shell != 'fish')
          'shell': _config.shell,
      });
      if (!mounted) {
        await link.close();
        return;
      }
      entry.link = link;
      entry.frames = link.frames.listen(
        (event) => _onFrame(entry, event),
        onDone: () => _handleSessionExited(entry),
        onError: (Object _) {
          if (mounted) setState(() => entry.ready = false);
        },
      );
    } catch (error) {
      if (mounted) {
        final message = error is PlatformException ? error.message : null;
        entry.terminal.write(
          '\r\n${message ?? 'Unable to open this terminal.'}\r\n',
        );
        setState(() {
          entry.ready = false;
          entry.setupMessage = null;
          entry.setupPhase = null;
          entry.setupBytes = null;
          entry.setupTotal = null;
        });
      }
    }
  }

  void _handleSessionExited(_TerminalSessionEntry entry) {
    if (!mounted || entry.closing) return;
    final idx = _workspace.sessions.indexOf(entry);
    if (idx < 0) return;
    unawaited(entry.close().whenComplete(entry.disposeResources));
    setState(() {
      _workspace.sessions.removeAt(idx);
      if (_workspace.sessions.isNotEmpty) {
        _workspace.currentIndex = _workspace.currentIndex.clamp(
          0,
          _workspace.sessions.length - 1,
        );
      } else {
        _workspace.currentIndex = 0;
      }
    });
    if (_workspace.sessions.isEmpty) {
      if (widget.onTerminalExited != null) {
        widget.onTerminalExited!();
      } else {
        unawaited(_createNewSession());
      }
    }
  }

  void _onFrame(_TerminalSessionEntry entry, String event) {
    if (!mounted) return;
    try {
      final frame = jsonDecode(event) as Map;
      if (frame['data'] case final String data) {
        entry.rawOutput?.add(base64Decode(data));
      }
      if (frame['state'] == 'setup') {
        setState(() {
          entry.setupPhase = frame['phase'] as String? ?? 'setup';
          entry.setupMessage =
              frame['message'] as String? ?? 'Setting up Termux environment...';
          entry.setupBytes = (frame['bytes'] as num?)?.toInt();
          entry.setupTotal = (frame['total'] as num?)?.toInt();
        });
      } else if (frame['state'] == 'ready') {
        setState(() {
          entry.ready = true;
          entry.setupPhase = null;
          entry.setupMessage = null;
          entry.setupBytes = null;
          entry.setupTotal = null;
        });
        if (entry.terminal.viewWidth > 0 && entry.terminal.viewHeight > 0) {
          unawaited(
            _sendFrame({
              'columns': entry.terminal.viewWidth,
              'rows': entry.terminal.viewHeight,
            }, session: entry),
          );
        }
      } else if (frame['state'] == 'closed') {
        if (frame['error'] case final String error when error.isNotEmpty) {
          entry.terminal.write('\r\n$error\r\n');
          setState(() {
            entry.ready = false;
            entry.setupPhase = null;
            entry.setupMessage = null;
            entry.setupBytes = null;
            entry.setupTotal = null;
          });
          return;
        }
        _handleSessionExited(entry);
      }
    } on FormatException {
      // ignore malformed frame
    }
  }

  Widget _buildSetupBanner(BuildContext context, _TerminalSessionEntry entry) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = entry.setupBytes;
    final total = entry.setupTotal;
    final double? fraction = (bytes != null && total != null && total > 0)
        ? (bytes / total).clamp(0.0, 1.0)
        : null;
    String formatMiB(int value) =>
        '${(value / (1024 * 1024)).toStringAsFixed(1)} MiB';
    final detail = switch ((bytes, total, fraction)) {
      (final int b, final int t, final double f) when t > 0 =>
        '${formatMiB(b)} / ${formatMiB(t)} · ${(f * 100).floor()}%',
      (final int b, _, _) when b > 0 => formatMiB(b),
      _ => null,
    };
    return Padding(
      key: const ValueKey('termux-setup-progress'),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.setupMessage ?? 'Setting up Termux environment...',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      detail,
                      style: Theme.of(context).textTheme.labelMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: fraction),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _sendRawText(String text, {_TerminalSessionEntry? session}) {
    if (text.isEmpty) return;
    final target = session ?? _currentSession;
    if (widget.core is! LocalCore) {
      target.terminal.write(text);
      return;
    }
    if (!target.ready) return;
    final bytes = utf8.encode(text);
    unawaited(() async {
      const frameBytes = 8 * 1024;
      for (
        var index = 0;
        index < bytes.length && mounted && target.ready;
        index += frameBytes
      ) {
        final end = (index + frameBytes).clamp(0, bytes.length);
        await _sendFrame({
          'data': base64Encode(bytes.sublist(index, end)),
        }, session: target);
      }
    }());
  }

  Future<void> _sendFrame(
    Map<String, dynamic> frame, {
    _TerminalSessionEntry? session,
  }) async {
    final target = session ?? _currentSession;
    if (!target.ready) return;
    try {
      await target.link?.send(frame);
    } catch (_) {
      if (mounted) setState(() => target.ready = false);
    }
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _recordClipboard(text);
      _currentSession.terminal.paste(text);
    }
    _ensureTerminalFocus();
  }

  Future<void> _copyTerminalBuffer() async {
    final lines = <String>[];
    final buf = _currentSession.terminal.buffer;
    for (var i = 0; i < buf.lines.length; i++) {
      final line = buf.lines[i].toString().trimRight();
      if (line.isNotEmpty) lines.add(line);
    }
    final text = lines.join('\n');
    if (text.isNotEmpty) {
      _recordClipboard(text);
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Termux output copied to clipboard'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
  }

  void _sendTmuxPrefixCommand(String key) {
    // Ctrl-B (prefix) + key controls tmux tabs/windows & sessions cleanly
    _sendRawText('\x02$key');
  }

  void _executeMappedAction(String action) {
    switch (action) {
      case 'terminal_settings':
      case 'termux_settings':
        openTerminalSettings();
        return;
      case 'app_settings':
        widget.onOpenAppSettings?.call();
        return;
      case 'command_palette':
        _openCommandPalette();
        return;
      case 'new_session':
        _sendTmuxPrefixCommand('c');
        return;
      case 'next_session':
        _sendTmuxPrefixCommand('n');
        return;
      case 'prev_session':
        _sendTmuxPrefixCommand('p');
        return;
      case 'tmux_scratchpad':
        _sendTmuxPrefixCommand('f');
        return;
      case 'copy_mode':
        _sendTmuxPrefixCommand('[');
        return;
      case 'paste':
        unawaited(_pasteClipboard());
        return;
      case 'copy_buffer':
        unawaited(_copyTerminalBuffer());
        return;
      case 'switch_backward':
        setState(() {
          _layer = switch (_layer) {
            _KeyboardLayer.qwerty => _KeyboardLayer.numeric,
            _KeyboardLayer.numeric => _KeyboardLayer.qwerty,
            _KeyboardLayer.greekMath => _KeyboardLayer.qwerty,
          };
        });
        return;
      case 'hide_keyboard':
        setState(() => _keyboardVisible = !_keyboardVisible);
        return;
      case 'clear_screen':
        _sendRawText('\x0c');
        return;
      case 'tab':
        _sendRawText('\t');
        return;
      case 'esc':
        _sendRawText('\x1b');
        return;
      case 'ctrl_c':
        _sendRawText('\x03');
        return;
    }
  }

  void _handleUnexpectedKey(String token, {bool isRepeat = false}) {
    if (token.isEmpty || token == 'noop') return;
    if (isRepeat) {
      _triggerKeyFeedback(token, isRepeat: true);
    }

    if (token == 'config') {
      _executeMappedAction(_config.configKeyAction);
      return;
    }
    if (token == 'tool:app.command_palette:󱎱') {
      _executeMappedAction(_config.spaceNorthAction);
      return;
    }
    if (token == 'switch_backward') {
      _executeMappedAction(_config.spaceSouthAction);
      return;
    }
    if (token == 'tool:voice.dictate:') {
      _executeMappedAction(_config.enterNorthAction);
      return;
    }
    if (token.startsWith('tool:window.previous')) {
      _sendTmuxPrefixCommand('p');
      return;
    }
    if (token.startsWith('tool:window.next')) {
      _sendTmuxPrefixCommand('n');
      return;
    }
    if (token.startsWith('tool:session.previous')) {
      _sendTmuxPrefixCommand('(');
      return;
    }
    if (token.startsWith('tool:session.next')) {
      _sendTmuxPrefixCommand(')');
      return;
    }

    switch (token) {
      case 'shift':
        final now = DateTime.now();
        final isDoubleTap =
            _lastShiftTap != null &&
            now.difference(_lastShiftTap!).inMilliseconds < 350;
        _lastShiftTap = now;
        setState(() {
          if (isDoubleTap) {
            _capsLock = true;
            _shift = false;
          } else if (_capsLock) {
            _capsLock = false;
            _shift = false;
          } else {
            _shift = !_shift;
          }
        });
        return;
      case 'capslock':
        setState(() {
          _capsLock = !_capsLock;
          _shift = false;
        });
        return;
      case 'ctrl':
        setState(() => _ctrl = !_ctrl);
        return;
      case 'alt':
        setState(() => _alt = !_alt);
        return;
      case 'fn':
        setState(() => _fn = !_fn);
        return;
      case 'meta':
      case 'superscript':
      case 'subscript':
      case 'ordinal':
      case 'arrows':
      case 'box':
        setState(() => _meta = !_meta);
        return;
      case 'switch_numeric':
        setState(() => _layer = _KeyboardLayer.numeric);
        return;
      case 'switch_text':
        setState(() => _layer = _KeyboardLayer.qwerty);
        return;
      case 'switch_greekmath':
        setState(() => _layer = _KeyboardLayer.greekMath);
        return;
      case 'switch_clipboard':
        setState(() => _clipboardPanelOpen = !_clipboardPanelOpen);
        return;
      case 'paste':
        unawaited(_pasteClipboard());
        return;
      case 'change_method':
        setState(() => _keyboardVisible = !_keyboardVisible);
        return;
      case 'compose':
        setState(() => _composePending = !_composePending);
        if (_composePending) {
          unawaited(_copyTerminalBuffer());
          setState(() => _composePending = false);
        }
        return;
    }

    var effective = token;
    if (_fn && _fnModmap.containsKey(token)) {
      effective = _fnModmap[token]!;
    }

    String? seq = _specialSequence(effective);
    if (seq == null) {
      var ch = effective;
      final upper = _shift || _capsLock;
      if (upper && ch.length == 1) {
        ch = _shiftedChar(ch);
      }
      if (_ctrl && ch.length == 1) {
        final code = ch.toUpperCase().codeUnitAt(0);
        if (code >= 64 && code <= 95) {
          seq = String.fromCharCode(code - 64);
        } else if (ch == ' ') {
          seq = '\x00';
        } else if (ch == '_') {
          seq = '\x1f';
        } else {
          seq = ch;
        }
      } else {
        seq = ch;
      }
      if (_alt || _meta) {
        seq = '\x1b$seq';
      }
    } else if ((_alt || _meta) && !seq.startsWith('\x1b')) {
      seq = '\x1b$seq';
    }

    _sendRawText(seq);

    if (!isRepeat && (_shift || _ctrl || _alt || _fn || _meta)) {
      setState(() {
        _shift = false;
        _ctrl = false;
        _alt = false;
        _fn = false;
        _meta = false;
      });
    }
  }

  String _shiftedChar(String ch) {
    const map = {
      '`': '~',
      '1': '!',
      '2': '@',
      '3': '#',
      '4': r'$',
      '5': '%',
      '6': '^',
      '7': '&',
      '8': '*',
      '9': '(',
      '0': ')',
      '-': '_',
      '=': '+',
      '[': '{',
      ']': '}',
      r'\': '|',
      ';': ':',
      "'": '"',
      ',': '<',
      '.': '>',
      '/': '?',
    };
    return map[ch] ?? ch.toUpperCase();
  }

  String? _specialSequence(String token) => switch (token) {
    'esc' => '\x1b',
    'tab' => '\t',
    'enter' || 'action' => '\r',
    'space' => ' ',
    'backspace' => '\x7f',
    'delete' => '\x1b[3~',
    'insert' => '\x1b[2~',
    'up' || 'cursor_up' => '\x1b[A',
    'down' || 'cursor_down' => '\x1b[B',
    'right' || 'cursor_right' => '\x1b[C',
    'left' || 'cursor_left' => '\x1b[D',
    'home' => '\x1b[H',
    'end' => '\x1b[F',
    'page_up' => '\x1b[5~',
    'page_down' => '\x1b[6~',
    'f1' => '\x1bOP',
    'f2' => '\x1bOQ',
    'f3' => '\x1bOR',
    'f4' => '\x1bOS',
    'f5' => '\x1b[15~',
    'f6' => '\x1b[17~',
    'f7' => '\x1b[18~',
    'f8' => '\x1b[19~',
    'f9' => '\x1b[20~',
    'f10' => '\x1b[21~',
    'f11' => '\x1b[23~',
    'f12' => '\x1b[24~',
    '^C' => '\x03',
    '^D' => '\x04',
    '^Z' => '\x1a',
    '^L' => '\x0c',
    _ => null,
  };

  // Exact <modmap> from termux_launcher_qwerty.xml + KeyModifier.java apply_fn_*
  static const Map<String, String> _fnModmap = {
    'q': 'f1',
    'w': 'f2',
    'e': 'f3',
    'r': 'f4',
    't': 'f5',
    'y': 'f6',
    'u': 'f7',
    'i': 'f8',
    'o': 'f9',
    'p': 'f10',
    'a': 'esc',
    's': 'tab',
    'd': 'home',
    'f': 'up',
    'g': 'end',
    'h': 'page_up',
    'j': 'left',
    'k': 'down',
    'l': 'right',
    'z': 'f11',
    'x': 'f12',
    'c': 'insert',
    'v': 'delete',
    'b': 'page_down',
    'n': '^C',
    'm': '^D',
    // KeyModifier.apply_fn_keyevent / apply_fn_event (KeyModifier.java:274-299)
    'up': 'page_up',
    'down': 'page_down',
    'left': 'home',
    'right': 'end',
    'esc': 'insert',
    'switch_numeric': 'switch_greekmath',
  };

  void _openCommandPalette() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final actions = <(IconData, String, String, VoidCallback)>[
          (
            Icons.add_box_outlined,
            'New tmux tab (^B c)',
            'Create a new tmux window in this session',
            () {
              Navigator.pop(ctx);
              _sendTmuxPrefixCommand('c');
            },
          ),
          (
            Icons.swap_horiz_outlined,
            'Next tmux tab (^B n)',
            'Switch to next tmux window',
            () {
              Navigator.pop(ctx);
              _sendTmuxPrefixCommand('n');
            },
          ),
          (
            Icons.vertical_split_outlined,
            'Split pane side-by-side (^B %)',
            'Split current tmux pane horizontally',
            () {
              Navigator.pop(ctx);
              _sendTmuxPrefixCommand('%');
            },
          ),
          (
            Icons.horizontal_split_outlined,
            'Split pane top/bottom (^B ")',
            'Split current tmux pane vertically',
            () {
              Navigator.pop(ctx);
              _sendTmuxPrefixCommand('"');
            },
          ),
          (
            Icons.layers_outlined,
            'Floating scratchpad (^B f)',
            'Open persistent tmux scratch popup (~/.tmux.conf)',
            () {
              Navigator.pop(ctx);
              _sendTmuxPrefixCommand('f');
            },
          ),
          (
            Icons.highlight_alt_outlined,
            'Selection / Copy mode (^B [)',
            'Activate tmux selection with key (v select, y copy, q exit)',
            () {
              Navigator.pop(ctx);
              _sendTmuxPrefixCommand('[');
            },
          ),
          (
            Icons.content_paste_outlined,
            'Paste from clipboard',
            'Insert system clipboard into tmux',
            () {
              Navigator.pop(ctx);
              unawaited(_pasteClipboard());
            },
          ),
          (
            Icons.copy_all_outlined,
            'Copy Termux output',
            'Copy visible scrollback buffer to clipboard',
            () {
              Navigator.pop(ctx);
              unawaited(_copyTerminalBuffer());
            },
          ),
          (
            Icons.tune_outlined,
            'Termux & Keyboard Settings',
            'Font size, row height, system monitor, and key mappings',
            () {
              Navigator.pop(ctx);
              openTerminalSettings();
            },
          ),
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.terminal_outlined),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Termux Command Palette',
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                    ),
                    Text(
                      _currentSession.name,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final (icon, title, sub, tap) in actions)
                  ListTile(
                    dense: true,
                    leading: Icon(icon),
                    title: Text(title),
                    subtitle: Text(sub),
                    onTap: tap,
                  ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(
      () => WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureTerminalFocus(),
      ),
    );
  }

  void openTerminalSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          Future<void> updateCfg(TerminalKeyboardConfig next) async {
            await _saveConfig(next);
            setSheetState(() {});
          }

          const actionLabels = <String, String>{
            'terminal_settings': 'Termux & Keyboard Settings',
            'command_palette': 'Command Palette',
            'new_session': 'New tmux Tab (^B c)',
            'next_session': 'Next tmux Tab (^B n)',
            'prev_session': 'Previous tmux Tab (^B p)',
            'tmux_scratchpad': 'Floating tmux Scratchpad (^B f)',
            'copy_mode': 'Selection / Copy Mode (^B [)',
            'paste': 'Paste Clipboard',
            'copy_buffer': 'Copy Termux Scrollback',
            'switch_backward': 'Switch Layout (QWERTY ↔ 123+)',
            'hide_keyboard': 'Hide / Show In-App Keyboard',
            'clear_screen': 'Clear Screen (^L)',
            'tab': 'Send Tab',
            'esc': 'Send Esc',
            'ctrl_c': 'Send Ctrl+C',
            'app_settings': 'DeviceBridge App Settings',
          };

          Widget mappingTile({
            required String title,
            required String subtitle,
            required String currentValue,
            required ValueChanged<String> onSelected,
          }) {
            return ListTile(
              dense: true,
              title: Text(title),
              subtitle: Text(
                '$subtitle · ${actionLabels[currentValue] ?? currentValue}',
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                final chosen = await showDialog<String>(
                  context: ctx,
                  builder: (dCtx) => SimpleDialog(
                    title: Text(title),
                    children: [
                      for (final entry in actionLabels.entries)
                        SimpleDialogOption(
                          onPressed: () => Navigator.pop(dCtx, entry.key),
                          child: Row(
                            children: [
                              Icon(
                                entry.key == currentValue
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                size: 18,
                              ),
                              const SizedBox(width: 10),
                              Expanded(child: Text(entry.value)),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
                if (chosen != null) {
                  onSelected(chosen);
                }
              },
            );
          }

          return SafeArea(
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.82,
              minChildSize: 0.45,
              maxChildSize: 0.94,
              builder: (ctx, scrollController) => ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tune_outlined),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Termux & Keyboard Settings',
                          style: Theme.of(ctx).textTheme.titleLarge,
                        ),
                      ),
                      if (widget.onOpenAppSettings != null)
                        TextButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            widget.onOpenAppSettings!.call();
                          },
                          icon: const Icon(Icons.settings_outlined, size: 16),
                          label: const Text('App Settings'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'tmux Tabs & Workspace',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ActionChip(
                        avatar: const Icon(Icons.add, size: 16),
                        label: const Text('New tab (^B c)'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _sendTmuxPrefixCommand('c');
                        },
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.chevron_left, size: 16),
                        label: const Text('Prev tab (^B p)'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _sendTmuxPrefixCommand('p');
                        },
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.chevron_right, size: 16),
                        label: const Text('Next tab (^B n)'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _sendTmuxPrefixCommand('n');
                        },
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.layers_outlined, size: 16),
                        label: const Text('Scratchpad (^B f)'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _sendTmuxPrefixCommand('f');
                        },
                      ),
                      ActionChip(
                        avatar: const Icon(Icons.refresh, size: 16),
                        label: const Text('Reattach tmux'),
                        onPressed: () {
                          unawaited(_startSessionProcess(_currentSession));
                        },
                      ),
                    ],
                  ),
                  const Divider(height: 28),
                  Text(
                    'Top Bar System Monitor',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _workspace.stats.rooted
                        ? 'Root active — CPU, RAM & GPU monitors available'
                        : (_workspace.stats.shizuku
                              ? 'Shizuku active — CPU & RAM available${_workspace.stats.gpuAvailable ? ', GPU available' : ' (GPU restricted to Root on this kernel)'}'
                              : 'Standard mode — RAM works via Binder; CPU & GPU disabled until Root or Shizuku is enabled in Settings'),
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show CPU usage'),
                    subtitle: Text(
                      _workspace.stats.cpuAvailable
                          ? 'Active via ${_workspace.stats.cpuSource == 'shizuku' ? 'Shizuku' : 'Root'} (/proc/stat)'
                          : 'Disabled — enable Root or Shizuku in Global Settings',
                    ),
                    value:
                        _config.showCpuUsage && _workspace.stats.cpuAvailable,
                    onChanged: _workspace.stats.cpuAvailable
                        ? (v) => updateCfg(_config.copyWith(showCpuUsage: v))
                        : null,
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show RAM usage'),
                    subtitle: const Text(
                      'Available in Standard, Shizuku & Root via Binder MemoryInfo',
                    ),
                    value:
                        _config.showRamUsage && _workspace.stats.ramAvailable,
                    onChanged: _workspace.stats.ramAvailable
                        ? (v) => updateCfg(_config.copyWith(showRamUsage: v))
                        : null,
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show GPU usage'),
                    subtitle: Text(
                      _workspace.stats.gpuAvailable
                          ? 'Active via ${_workspace.stats.gpuSource == 'shizuku' ? 'Shizuku' : 'Root'}'
                          : (_workspace.stats.shizuku
                                ? 'Disabled — GPU sysfs requires Root on this kernel'
                                : 'Disabled — enable Root access in Global Settings'),
                    ),
                    value:
                        _config.showGpuUsage && _workspace.stats.gpuAvailable,
                    onChanged: _workspace.stats.gpuAvailable
                        ? (v) => updateCfg(_config.copyWith(showGpuUsage: v))
                        : null,
                  ),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Monitor update interval'),
                    subtitle: Text(
                      'Poll frequency (${(_config.statsIntervalMs / 1000).toStringAsFixed(_config.statsIntervalMs % 1000 == 0 ? 0 : 1)}s) via single persistent shell & Binder API',
                    ),
                    trailing: DropdownButton<int>(
                      value:
                          const {
                            500,
                            1000,
                            2000,
                            3000,
                            5000,
                            10000,
                          }.contains(_config.statsIntervalMs)
                          ? _config.statsIntervalMs
                          : 2000,
                      items: const [
                        DropdownMenuItem(value: 500, child: Text('0.5s')),
                        DropdownMenuItem(value: 1000, child: Text('1s')),
                        DropdownMenuItem(value: 2000, child: Text('2s')),
                        DropdownMenuItem(value: 3000, child: Text('3s')),
                        DropdownMenuItem(value: 5000, child: Text('5s')),
                        DropdownMenuItem(value: 10000, child: Text('10s')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        updateCfg(_config.copyWith(statsIntervalMs: v));
                      },
                    ),
                  ),
                  const Divider(height: 28),
                  Text(
                    'Termux Display & Shell',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Expanded(child: Text('Termux font size')),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.remove),
                        onPressed: () => updateCfg(
                          _config.copyWith(
                            fontSize: (_config.fontSize - 0.5).clamp(8.0, 28.0),
                          ),
                        ),
                      ),
                      Text('${_config.fontSize.toStringAsFixed(1)} pt'),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.add),
                        onPressed: () => updateCfg(
                          _config.copyWith(
                            fontSize: (_config.fontSize + 0.5).clamp(8.0, 28.0),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: _config.fontSize,
                    min: 8.0,
                    max: 24.0,
                    divisions: 32,
                    label: '${_config.fontSize.toStringAsFixed(1)} pt',
                    onChanged: (v) => updateCfg(_config.copyWith(fontSize: v)),
                  ),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Default shell'),
                    subtitle: Text(_config.shell),
                    trailing: DropdownButton<String>(
                      value:
                          const {
                            'fish',
                            'bash',
                            '/system/bin/sh',
                          }.contains(_config.shell)
                          ? _config.shell
                          : 'fish',
                      items: const [
                        DropdownMenuItem(
                          value: 'fish',
                          child: Text('fish (Termux default)'),
                        ),
                        DropdownMenuItem(value: 'bash', child: Text('bash')),
                        DropdownMenuItem(
                          value: '/system/bin/sh',
                          child: Text('/system/bin/sh'),
                        ),
                      ],
                      onChanged: (v) async {
                        if (v == null) return;
                        await updateCfg(_config.copyWith(shell: v));
                        unawaited(_startSessionProcess(_currentSession));
                      },
                    ),
                  ),
                  const Divider(height: 28),
                  Text(
                    'Unexpected Keyboard Layout & Sizing',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Expanded(child: Text('Key row height')),
                      Text('${_config.rowHeight.round()} dp'),
                    ],
                  ),
                  Slider(
                    value: _config.rowHeight,
                    min: 36.0,
                    max: 62.0,
                    divisions: 26,
                    label: '${_config.rowHeight.round()} dp',
                    onChanged: (v) => updateCfg(_config.copyWith(rowHeight: v)),
                  ),
                  Row(
                    children: [
                      const Expanded(child: Text('Corner flick threshold')),
                      Text('${_config.flickThreshold.round()} px'),
                    ],
                  ),
                  Slider(
                    value: _config.flickThreshold,
                    min: 8.0,
                    max: 26.0,
                    divisions: 18,
                    label: '${_config.flickThreshold.round()} px',
                    onChanged: (v) =>
                        updateCfg(_config.copyWith(flickThreshold: v)),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show dedicated number row (1–0)'),
                    subtitle: const Text(
                      'Adds number_row.xml above QWERTY keys',
                    ),
                    value: _config.showNumberRow,
                    onChanged: (v) =>
                        updateCfg(_config.copyWith(showNumberRow: v)),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show corner sub-labels'),
                    subtitle: const Text(
                      'Display NW / NE / SW / SE flick symbols on keycaps',
                    ),
                    value: _config.showSubLabels,
                    onChanged: (v) =>
                        updateCfg(_config.copyWith(showSubLabels: v)),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Floating key & swipe preview popup'),
                    subtitle: const Text(
                      'In-app keyboard glyph popup above pressed/swiped key',
                    ),
                    value: _config.showKeyPopup,
                    onChanged: (v) =>
                        updateCfg(_config.copyWith(showKeyPopup: v)),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('TouchFx press & swipe vector animation'),
                    subtitle: const Text(
                      'Keycap press scale, directional swipe vector & trail',
                    ),
                    value: _config.pressAnimation,
                    onChanged: (v) =>
                        updateCfg(_config.copyWith(pressAnimation: v)),
                  ),
                  const Divider(height: 28),
                  Text(
                    'Haptics, Keypress Sound & Bell',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Haptic feedback on key & swipe'),
                    subtitle: const Text(
                      'Vibrates on key down and when crossing into a corner flick',
                    ),
                    value: _config.hapticFeedback,
                    onChanged: (v) =>
                        updateCfg(_config.copyWith(hapticFeedback: v)),
                  ),
                  if (_config.hapticFeedback) ...[
                    Row(
                      children: [
                        const Expanded(child: Text('Vibration duration')),
                        Text('${_config.vibrateDurationMs} ms'),
                      ],
                    ),
                    Slider(
                      value: _config.vibrateDurationMs.toDouble(),
                      min: 0,
                      max: 60,
                      divisions: 30,
                      label: '${_config.vibrateDurationMs} ms',
                      onChanged: (v) {
                        final ms = v.round();
                        updateCfg(_config.copyWith(vibrateDurationMs: ms));
                      },
                      onChangeEnd: (_) => _triggerKeyFeedback('space'),
                    ),
                  ],
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Keypress sound click'),
                    subtitle: const Text(
                      'Play Android system keypress sound on tap',
                    ),
                    value: _config.soundFeedback,
                    onChanged: (v) {
                      updateCfg(_config.copyWith(soundFeedback: v));
                    },
                  ),
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(r"Bell (printf '\a')"),
                    subtitle: const Text(
                      'Audio bell.ogg and/or vibration when shell emits BEL (0x07)',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DropdownButton<String>(
                          value:
                              const {
                                'beep_vibrate',
                                'beep',
                                'vibrate',
                                'ignore',
                              }.contains(_config.bellMode)
                              ? _config.bellMode
                              : 'beep_vibrate',
                          items: const [
                            DropdownMenuItem(
                              value: 'beep_vibrate',
                              child: Text('Beep + Vibrate'),
                            ),
                            DropdownMenuItem(
                              value: 'beep',
                              child: Text('Beep (bell.ogg)'),
                            ),
                            DropdownMenuItem(
                              value: 'vibrate',
                              child: Text('Vibrate only'),
                            ),
                            DropdownMenuItem(
                              value: 'ignore',
                              child: Text('Ignore'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            updateCfg(_config.copyWith(bellMode: v));
                          },
                        ),
                        IconButton(
                          tooltip: 'Test bell',
                          icon: const Icon(
                            Icons.notifications_active_outlined,
                            size: 18,
                          ),
                          onPressed: _handleTerminalBell,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 28),
                  Text(
                    'Key & Gesture Mappings',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  mappingTile(
                    title: 'Settings key (Alt ↘ gear icon)',
                    subtitle: 'Bottom-right flick on Alt key',
                    currentValue: _config.configKeyAction,
                    onSelected: (v) =>
                        updateCfg(_config.copyWith(configKeyAction: v)),
                  ),
                  mappingTile(
                    title: 'Spacebar North swipe (Space ↑)',
                    subtitle: 'Upward flick on Spacebar',
                    currentValue: _config.spaceNorthAction,
                    onSelected: (v) =>
                        updateCfg(_config.copyWith(spaceNorthAction: v)),
                  ),
                  mappingTile(
                    title: 'Spacebar South swipe (Space ↓)',
                    subtitle: 'Downward flick on Spacebar',
                    currentValue: _config.spaceSouthAction,
                    onSelected: (v) =>
                        updateCfg(_config.copyWith(spaceSouthAction: v)),
                  ),
                  mappingTile(
                    title: 'Enter North swipe (Enter ↑)',
                    subtitle: 'Upward flick on Enter key',
                    currentValue: _config.enterNorthAction,
                    onSelected: (v) =>
                        updateCfg(_config.copyWith(enterNorthAction: v)),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => updateCfg(const TerminalKeyboardConfig()),
                    icon: const Icon(Icons.restore_outlined),
                    label: const Text('Reset Termux & Keyboard defaults'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(
      () => WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureTerminalFocus(),
      ),
    );
  }

  Widget _buildClipboardPanel(_TerminalVisualPalette palette) {
    return Container(
      height: _config.rowHeight * 4 + 22,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.deckColor == Colors.transparent
            ? palette.keyColor
            : palette.deckColor,
        border: Border(
          top: BorderSide(
            color: palette.borderColor,
            width: palette.borderWidth,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.content_paste_outlined,
                size: 18,
                color: palette.labelColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Clipboard & Quick Actions',
                  style: TextStyle(
                    fontFamily: 'MesloLGS NF',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: palette.labelColor,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () {
                  unawaited(_pasteClipboard());
                  setState(() => _clipboardPanelOpen = false);
                },
                icon: const Icon(Icons.paste, size: 16),
                label: const Text('Paste now'),
              ),
              TextButton.icon(
                onPressed: () {
                  unawaited(_copyTerminalBuffer());
                  setState(() => _clipboardPanelOpen = false);
                },
                icon: const Icon(Icons.copy_all_outlined, size: 16),
                label: const Text('Copy output'),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.keyboard_return,
                  size: 18,
                  color: palette.labelColor,
                ),
                onPressed: () => setState(() => _clipboardPanelOpen = false),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: _workspace.clipboardHistory.isEmpty
                ? Center(
                    child: Text(
                      'Tap "Paste now" to paste system clipboard, or "Copy output" to copy scrollback.',
                      style: TextStyle(
                        fontFamily: 'MesloLGS NF',
                        fontSize: 11.5,
                        color: palette.subLabelColor,
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _workspace.clipboardHistory.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 4),
                    itemBuilder: (context, idx) {
                      final item = _workspace.clipboardHistory[idx];
                      return InkWell(
                        onTap: () {
                          _sendRawText(item);
                          setState(() => _clipboardPanelOpen = false);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: palette.actionKeyColor,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: palette.borderColor,
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            item.replaceAll('\n', ' ↵ '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'MesloLGS NF',
                              fontSize: 12,
                              color: palette.labelColor,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _handleTerminalPointerDown(PointerDownEvent event) {
    _touchPointers[event.pointer] = event.position;
    if (_touchPointers.length == 2) {
      final pts = _touchPointers.values.toList(growable: false);
      _pinchBaseDistance = (pts[0] - pts[1]).distance;
      _pinchBaseFontSize = _config.fontSize;
    } else if (_touchPointers.length > 2) {
      _pinchBaseDistance = null;
      _pinchBaseFontSize = null;
    }
  }

  void _handleTerminalPointerMove(PointerMoveEvent event) {
    if (!_touchPointers.containsKey(event.pointer)) return;
    _touchPointers[event.pointer] = event.position;
    if (_touchPointers.length == 2 &&
        _pinchBaseDistance != null &&
        _pinchBaseDistance! > 12 &&
        _pinchBaseFontSize != null) {
      final pts = _touchPointers.values.toList(growable: false);
      final currentDist = (pts[0] - pts[1]).distance;
      final scale = currentDist / _pinchBaseDistance!;
      final next = (_pinchBaseFontSize! * scale).clamp(8.0, 26.0);
      if ((next - _config.fontSize).abs() >= 0.25) {
        setState(() => _workspace.config = _config.copyWith(fontSize: next));
      }
    }
  }

  void _handleTerminalPointerEnd(PointerEvent event) {
    _touchPointers.remove(event.pointer);
    if (_touchPointers.length < 2 && _pinchBaseFontSize != null) {
      _pinchBaseDistance = null;
      _pinchBaseFontSize = null;
      unawaited(_saveConfig(_config));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_workspace.sessions.isEmpty) {
      return const SizedBox.shrink();
    }
    final palette = _TerminalVisualPalette.resolve(
      context,
      widget.appearance,
      widget.amoledConfig ??
          AmoledStyleConfig.defaults(red: widget.appearance == 'amoled-red'),
    );
    final current = _currentSession;

    return Stack(
      key: _stackRootKey,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _handleTerminalPointerDown,
                onPointerMove: _handleTerminalPointerMove,
                onPointerUp: _handleTerminalPointerEnd,
                onPointerCancel: _handleTerminalPointerEnd,
                child: Container(
                  margin: palette.terminalCardMargin,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: palette.terminalCardColor,
                    borderRadius: palette.terminalCardRadius,
                    border: palette.terminalCardBorder,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!current.ready && current.setupMessage != null)
                        _buildSetupBanner(context, current),
                      Expanded(
                        child: TerminalView(
                          key: current.viewKey,
                          current.terminal,
                          focusNode: current.focusNode,
                          theme: palette.terminalTheme,
                          backgroundOpacity: palette.backgroundOpacity,
                          textStyle: TerminalStyle(
                            fontFamily: 'MesloLGS NF',
                            fontSize: _config.fontSize,
                            height: 1.18,
                          ),
                          autofocus: true,
                          hardwareKeyboardOnly: _keyboardVisible,
                          readOnly: false,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_clipboardPanelOpen)
              _buildClipboardPanel(palette)
            else if (_keyboardVisible)
              _UnexpectedKeyboardWidget(
                palette: palette,
                config: _config,
                shift: _shift,
                capsLock: _capsLock,
                ctrl: _ctrl,
                alt: _alt,
                fn: _fn,
                meta: _meta,
                layer: _layer,
                onKey: _handleUnexpectedKey,
                onFeedback: _triggerKeyFeedback,
                stackRootKey: _stackRootKey,
                popupController: _popupController,
              ),
          ],
        ),
        if (_config.showKeyPopup)
          Positioned.fill(
            child: IgnorePointer(
              child: _KeyPopupOverlay(
                controller: _popupController,
                palette: palette,
              ),
            ),
          ),
        if (!_keyboardVisible)
          Positioned(
            right: 12,
            bottom: 12,
            child: FloatingActionButton.small(
              tooltip: 'Show Unexpected Keyboard',
              backgroundColor: palette.activeKeyColor,
              foregroundColor: palette.activeLabelColor,
              onPressed: () => setState(() => _keyboardVisible = true),
              child: const Icon(Icons.keyboard_alt_outlined),
            ),
          ),
      ],
    );
  }
}

class _UnexpectedKeySpec {
  const _UnexpectedKeySpec({
    required this.c,
    this.nw,
    this.ne,
    this.sw,
    this.se,
    this.n,
    this.s,
    this.w,
    this.e,
    this.flex = 100,
    this.isAction = false,
    this.isSpaceBar = false,
  }) : isSpacer = false;

  const _UnexpectedKeySpec.spacer(this.flex)
    : c = '',
      nw = null,
      ne = null,
      sw = null,
      se = null,
      n = null,
      s = null,
      w = null,
      e = null,
      isAction = false,
      isSpaceBar = false,
      isSpacer = true;

  final String c;
  final String? nw;
  final String? ne;
  final String? sw;
  final String? se;
  final String? n;
  final String? s;
  final String? w;
  final String? e;
  final int flex;
  final bool isAction;
  final bool isSpaceBar;
  final bool isSpacer;
}

class _UnexpectedKeyboardWidget extends StatelessWidget {
  const _UnexpectedKeyboardWidget({
    required this.palette,
    required this.config,
    required this.shift,
    required this.capsLock,
    required this.ctrl,
    required this.alt,
    required this.fn,
    required this.meta,
    required this.layer,
    required this.onKey,
    required this.onFeedback,
    required this.stackRootKey,
    required this.popupController,
  });

  final _TerminalVisualPalette palette;
  final TerminalKeyboardConfig config;
  final bool shift;
  final bool capsLock;
  final bool ctrl;
  final bool alt;
  final bool fn;
  final bool meta;
  final _KeyboardLayer layer;
  final void Function(String token, {bool isRepeat}) onKey;
  final void Function(String token, {bool isSwipeSlot, bool isRepeat})
  onFeedback;
  final GlobalKey stackRootKey;
  final _KeyPopupOverlayController popupController;

  // Optional number_row.xml from termux-launcher/inapp-keyboard
  static const List<_UnexpectedKeySpec> _numberRow = [
    _UnexpectedKeySpec(c: '1', se: '!', isAction: true),
    _UnexpectedKeySpec(c: '2', se: '@', isAction: true),
    _UnexpectedKeySpec(c: '3', se: '#', isAction: true),
    _UnexpectedKeySpec(c: '4', se: r'$', isAction: true),
    _UnexpectedKeySpec(c: '5', se: '%', isAction: true),
    _UnexpectedKeySpec(c: '6', sw: '^', isAction: true),
    _UnexpectedKeySpec(c: '7', sw: '&', isAction: true),
    _UnexpectedKeySpec(c: '8', sw: '*', isAction: true),
    _UnexpectedKeySpec(c: '9', sw: '(', isAction: true),
    _UnexpectedKeySpec(c: '0', sw: ')', isAction: true),
  ];

  // Exact 1:1 layout from termux-launcher's inapp-keyboard/src/main/res/xml/termux_launcher_qwerty.xml
  static const List<List<_UnexpectedKeySpec>> _qwertyRows = [
    [
      _UnexpectedKeySpec(c: 'q', ne: '1', se: 'esc'),
      _UnexpectedKeySpec(c: 'w', nw: '~', ne: '2', sw: '@'),
      _UnexpectedKeySpec(c: 'e', nw: '!', ne: '3', sw: '#', se: '€'),
      _UnexpectedKeySpec(c: 'r', ne: '4', sw: r'$'),
      _UnexpectedKeySpec(c: 't', ne: '5', sw: '%'),
      _UnexpectedKeySpec(c: 'y', ne: '6', sw: '^'),
      _UnexpectedKeySpec(c: 'u', ne: '7', sw: '&'),
      _UnexpectedKeySpec(c: 'i', ne: '8', sw: '*'),
      _UnexpectedKeySpec(c: 'o', ne: '9', sw: '(', se: ')'),
      _UnexpectedKeySpec(c: 'p', ne: '0'),
    ],
    [
      _UnexpectedKeySpec.spacer(50),
      _UnexpectedKeySpec(c: 'a', nw: 'tab', ne: '`'),
      _UnexpectedKeySpec(c: 's', ne: '§', sw: 'ß'),
      _UnexpectedKeySpec(c: 'd'),
      _UnexpectedKeySpec(c: 'f'),
      _UnexpectedKeySpec(c: 'g', ne: '-', sw: '_'),
      _UnexpectedKeySpec(c: 'h', ne: '=', sw: '+'),
      _UnexpectedKeySpec(c: 'j', sw: '{', se: '}'),
      _UnexpectedKeySpec(c: 'k', sw: '[', se: ']'),
      _UnexpectedKeySpec(c: 'l', ne: '|', sw: r'\'),
      _UnexpectedKeySpec.spacer(50),
    ],
    [
      _UnexpectedKeySpec(c: 'shift', ne: 'capslock', flex: 150, isAction: true),
      _UnexpectedKeySpec(c: 'z'),
      _UnexpectedKeySpec(c: 'x', ne: '†'),
      _UnexpectedKeySpec(c: 'c', ne: '<', sw: '.'),
      _UnexpectedKeySpec(c: 'v', ne: '>', sw: ','),
      _UnexpectedKeySpec(c: 'b', ne: '?', sw: '/'),
      _UnexpectedKeySpec(c: 'n', ne: ':', sw: ';'),
      _UnexpectedKeySpec(c: 'm', ne: '"', sw: "'"),
      _UnexpectedKeySpec(
        c: 'backspace',
        ne: 'delete',
        flex: 150,
        isAction: true,
      ),
    ],
    [
      _UnexpectedKeySpec(
        c: 'ctrl',
        ne: 'switch_clipboard',
        sw: 'meta',
        se: 'switch_numeric',
        flex: 170,
        isAction: true,
      ),
      _UnexpectedKeySpec(
        c: 'alt',
        nw: 'fn',
        ne: 'change_method',
        se: 'config',
        flex: 130,
        isAction: true,
      ),
      _UnexpectedKeySpec(
        c: 'space',
        w: 'cursor_left',
        e: 'cursor_right',
        s: 'switch_backward',
        n: 'tool:app.command_palette:󱎱',
        nw: 'tool:window.previous:󰜳',
        ne: 'tool:window.next:󰜶',
        sw: 'tool:session.previous:󰜹',
        se: 'tool:session.next:󰜰',
        flex: 400,
        isAction: true,
        isSpaceBar: true,
      ),
      _UnexpectedKeySpec(
        c: 'compose',
        nw: 'home',
        ne: 'page_up',
        sw: 'page_down',
        se: 'end',
        w: 'left',
        e: 'right',
        n: 'up',
        s: 'down',
        flex: 130,
        isAction: true,
      ),
      _UnexpectedKeySpec(
        c: 'enter',
        n: 'tool:voice.dictate:',
        flex: 170,
        isAction: true,
      ),
    ],
  ];

  // Exact 1:1 layout from termux-launcher's inapp-keyboard/src/main/res/xml/numeric.xml
  static const List<List<_UnexpectedKeySpec>> _numericRows = [
    [
      _UnexpectedKeySpec(c: 'esc', ne: '~', se: '!', flex: 75, isAction: true),
      _UnexpectedKeySpec(c: '(', ne: '[', se: '{', flex: 75, isAction: true),
      _UnexpectedKeySpec(c: '7', nw: '<', ne: '>', flex: 100),
      _UnexpectedKeySpec(c: '8', ne: '∞', flex: 100),
      _UnexpectedKeySpec(c: '9', ne: 'π', flex: 100),
      _UnexpectedKeySpec(
        c: '*',
        nw: '√',
        ne: '×',
        sw: '#',
        flex: 75,
        isAction: true,
      ),
      _UnexpectedKeySpec(c: '/', nw: '%', sw: '÷', flex: 75, isAction: true),
    ],
    [
      _UnexpectedKeySpec(c: 'tab', ne: '|', se: r'\', flex: 75, isAction: true),
      _UnexpectedKeySpec(c: ')', ne: ']', se: '}', flex: 75, isAction: true),
      _UnexpectedKeySpec(c: '4', nw: 'box', sw: 'arrows', flex: 100),
      _UnexpectedKeySpec(
        c: '5',
        n: 'up',
        e: 'right',
        w: 'left',
        s: 'down',
        flex: 100,
      ),
      _UnexpectedKeySpec(c: '6', flex: 100),
      _UnexpectedKeySpec(c: '+', nw: 'Σ', ne: r'$', flex: 75, isAction: true),
      _UnexpectedKeySpec(c: '-', nw: '^', flex: 75, isAction: true),
    ],
    [
      _UnexpectedKeySpec(c: 'switch_greekmath', flex: 75, isAction: true),
      _UnexpectedKeySpec(
        c: 'shift',
        ne: 'fn',
        se: 'alt',
        flex: 75,
        isAction: true,
      ),
      _UnexpectedKeySpec(
        c: '1',
        nw: 'superscript',
        ne: 'ordinal',
        sw: 'subscript',
        flex: 100,
      ),
      _UnexpectedKeySpec(c: '2', flex: 100),
      _UnexpectedKeySpec(c: '3', flex: 100),
      _UnexpectedKeySpec(
        c: 'backspace',
        ne: 'delete',
        flex: 150,
        isAction: true,
      ),
    ],
    [
      _UnexpectedKeySpec(
        c: 'switch_text',
        ne: 'ctrl',
        flex: 150,
        isAction: true,
      ),
      _UnexpectedKeySpec(c: '0', flex: 150),
      _UnexpectedKeySpec(
        c: '.',
        nw: ':',
        ne: ',',
        sw: ';',
        flex: 75,
        isAction: true,
      ),
      _UnexpectedKeySpec(
        c: 'action',
        nw: '"',
        ne: "'",
        sw: 'compose',
        se: '_',
        flex: 75,
        isAction: true,
      ),
      _UnexpectedKeySpec(
        c: 'enter',
        nw: '±',
        sw: '=',
        flex: 150,
        isAction: true,
      ),
    ],
  ];

  // Exact 1:1 layout from termux-launcher's inapp-keyboard/src/main/res/xml/greekmath.xml
  static const List<List<_UnexpectedKeySpec>> _greekMathRows = [
    [
      _UnexpectedKeySpec(c: 'θ', ne: '^'),
      _UnexpectedKeySpec(c: 'ω', nw: '⌊', ne: '∨', sw: '↔', se: '⊂'),
      _UnexpectedKeySpec(c: 'ε', nw: '⌋', ne: '∧', sw: '↑', se: '⊃'),
      _UnexpectedKeySpec(c: 'ρ', nw: '⌈', ne: '⊥', sw: '↕', se: '∀'),
      _UnexpectedKeySpec(c: 'τ', nw: '⌉', ne: '∡', se: '⊷'),
      _UnexpectedKeySpec(c: 'ψ', nw: '∥', ne: '⊢', sw: '≪', se: '7'),
      _UnexpectedKeySpec(c: 'υ', nw: '⌀', ne: '⟨', sw: '≡', se: '8'),
      _UnexpectedKeySpec(c: 'ι', nw: '∞', ne: '⟩', sw: '≫', se: '9'),
      _UnexpectedKeySpec(c: 'ο', nw: '∝', sw: '□'),
      _UnexpectedKeySpec(c: 'π', nw: '∅', sw: '∘'),
    ],
    [
      _UnexpectedKeySpec(c: 'α', se: 'ℂ'),
      _UnexpectedKeySpec(c: 'σ', sw: '←', se: '∂'),
      _UnexpectedKeySpec(c: 'δ', sw: '↓', se: '∫'),
      _UnexpectedKeySpec(c: 'φ', sw: '→', se: '∃'),
      _UnexpectedKeySpec(c: 'γ', sw: '∋', se: '∈'),
      _UnexpectedKeySpec(c: 'η', nw: '⊕', se: '4'),
      _UnexpectedKeySpec(c: 'ξ', nw: '⊖', sw: 'ℕ', se: '5'),
      _UnexpectedKeySpec(c: 'κ', nw: '⊙', sw: 'ℝ', se: '6'),
      _UnexpectedKeySpec(c: 'λ', nw: '⊗'),
      _UnexpectedKeySpec(c: 'ϡ', nw: '⌀'),
    ],
    [
      _UnexpectedKeySpec(c: 'shift', ne: 'capslock', flex: 150, isAction: true),
      _UnexpectedKeySpec(c: 'ζ', sw: '⇌', se: '√'),
      _UnexpectedKeySpec(c: 'χ', se: '∪'),
      _UnexpectedKeySpec(c: 'ϛ', se: '∩'),
      _UnexpectedKeySpec(c: 'ϟ', sw: '∇', se: 'ℵ'),
      _UnexpectedKeySpec(c: 'β', nw: '≤', sw: 'ℤ', se: '1'),
      _UnexpectedKeySpec(c: 'ν', nw: '≠', sw: 'ℚ', se: '2'),
      _UnexpectedKeySpec(c: 'μ', nw: '≥', sw: '×', se: '3'),
      _UnexpectedKeySpec(
        c: 'backspace',
        sw: 'delete',
        flex: 150,
        isAction: true,
      ),
    ],
    [
      _UnexpectedKeySpec(
        c: 'switch_text',
        ne: 'esc',
        flex: 120,
        isAction: true,
      ),
      _UnexpectedKeySpec(
        c: 'switch_numeric',
        ne: 'tab',
        flex: 120,
        isAction: true,
      ),
      _UnexpectedKeySpec(c: 'fn', flex: 120, isAction: true),
      _UnexpectedKeySpec(
        c: 'space',
        nw: 'superscript',
        sw: 'subscript',
        flex: 280,
        isAction: true,
        isSpaceBar: true,
      ),
      _UnexpectedKeySpec(c: '0', ne: '.', flex: 120, isAction: true),
      _UnexpectedKeySpec(
        c: 'compose',
        n: 'up',
        e: 'right',
        w: 'left',
        s: 'down',
        flex: 120,
        isAction: true,
      ),
      _UnexpectedKeySpec(
        c: 'enter',
        nw: '=',
        ne: 'action',
        flex: 120,
        isAction: true,
      ),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final baseRows = switch (layer) {
      _KeyboardLayer.qwerty => _qwertyRows,
      _KeyboardLayer.numeric => _numericRows,
      _KeyboardLayer.greekMath => _greekMathRows,
    };
    final rows = <List<_UnexpectedKeySpec>>[
      if (config.showNumberRow && layer == _KeyboardLayer.qwerty) _numberRow,
      ...baseRows,
    ];
    final rowH = config.rowHeight;
    return Container(
      padding: const EdgeInsets.fromLTRB(2, 3, 2, 4),
      decoration: BoxDecoration(color: palette.deckColor),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var rIdx = 0; rIdx < rows.length; rIdx++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SizedBox(
                height:
                    (config.showNumberRow &&
                        layer == _KeyboardLayer.qwerty &&
                        rIdx == 0)
                    ? rowH * 0.78
                    : (rIdx == rows.length - 1 ? rowH * 0.95 : rowH),
                child: Row(
                  children: [
                    for (final spec in rows[rIdx])
                      if (spec.isSpacer)
                        Spacer(flex: spec.flex)
                      else
                        Expanded(
                          flex: spec.flex,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: _UnexpectedKeyCap(
                              palette: palette,
                              config: config,
                              spec: spec,
                              shift: shift || capsLock,
                              capsLock: capsLock,
                              active:
                                  (spec.c == 'shift' && (shift || capsLock)) ||
                                  (spec.c == 'ctrl' && ctrl) ||
                                  (spec.c == 'alt' && alt) ||
                                  (spec.c == 'fn' && fn) ||
                                  (spec.c == 'meta' && meta),
                              fnActive: fn,
                              onTrigger: onKey,
                              onFeedback: onFeedback,
                              stackRootKey: stackRootKey,
                              popupController: popupController,
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RenderedSymbol {
  const _RenderedSymbol(
    this.text, {
    this.useSpecialFont = false,
    this.smaller = false,
  });
  final String text;
  final bool useSpecialFont;
  final bool smaller;
}

class _FlickResolution {
  const _FlickResolution(this.slot, this.token);
  final String slot; // 'c', 'nw', 'ne', 'sw', 'se', 'n', 's', 'w', 'e'
  final String token;
}

class _UnexpectedKeyCap extends StatefulWidget {
  const _UnexpectedKeyCap({
    required this.palette,
    required this.config,
    required this.spec,
    required this.shift,
    required this.capsLock,
    required this.active,
    required this.fnActive,
    required this.onTrigger,
    required this.onFeedback,
    required this.stackRootKey,
    required this.popupController,
  });

  final _TerminalVisualPalette palette;
  final TerminalKeyboardConfig config;
  final _UnexpectedKeySpec spec;
  final bool shift;
  final bool capsLock;
  final bool active;
  final bool fnActive;
  final void Function(String token, {bool isRepeat}) onTrigger;
  final void Function(String token, {bool isSwipeSlot, bool isRepeat})
  onFeedback;
  final GlobalKey stackRootKey;
  final _KeyPopupOverlayController popupController;

  @override
  State<_UnexpectedKeyCap> createState() => _UnexpectedKeyCapState();
}

class _UnexpectedKeyCapState extends State<_UnexpectedKeyCap>
    with SingleTickerProviderStateMixin {
  Offset? _panStart;
  Offset _panDelta = Offset.zero;
  double? _firstAngle;
  double? _lastAngle;
  double _angularTravel = 0.0;
  final List<Offset> _trailPoints = <Offset>[];
  String _activeSlot = 'c';
  int? _activePointerId;
  double _sliderAccumDx = 0.0;
  bool _sliderMoved = false;
  bool _pressed = false;
  Timer? _repeatDelayTimer;
  Timer? _repeatTickTimer;
  late final AnimationController _pressFxController;

  static const Set<String> _repeatableKeys = {
    'backspace',
    'delete',
    'up',
    'down',
    'left',
    'right',
  };

  static const Set<String> _latchableModifiers = {
    'shift',
    'ctrl',
    'alt',
    'fn',
    'meta',
  };

  // Exact Pointers.DIRECTION_TO_INDEX (Pointers.java:336-338):
  // 16 clockwise sectors starting at Top (0=N, 1..2=NE, 3..4=E, 5..6=SE, 7..8=S, 9..10=SW, 11..12=W, 13..14=NW, 15=N)
  // Slot indices: 1=nw, 2=ne, 3=sw, 4=se, 5=w, 6=e, 7=n, 8=s
  static const List<int> _directionToIndex = <int>[
    7,
    2,
    2,
    6,
    6,
    4,
    4,
    8,
    8,
    3,
    3,
    5,
    5,
    1,
    1,
    7,
  ];
  static const List<int> _sectorSearchOrder = <int>[0, -1, 1, -2, 2, -3, 3];

  @override
  void initState() {
    super.initState();
    // termux-launcher Keyboard2View: PRESS_RAMP_MS = 60L, RELEASE_FADE_MS = 150L
    _pressFxController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 60),
      reverseDuration: const Duration(milliseconds: 150),
    );
  }

  @override
  void dispose() {
    _cancelRepeat();
    _pressFxController.dispose();
    super.dispose();
  }

  void _cancelRepeat() {
    _repeatDelayTimer?.cancel();
    _repeatDelayTimer = null;
    _repeatTickTimer?.cancel();
    _repeatTickTimer = null;
  }

  void _startRepeatIfApplicable(String token) {
    _cancelRepeat();
    if (!_repeatableKeys.contains(token)) return;
    _repeatDelayTimer = Timer(const Duration(milliseconds: 320), () {
      _repeatTickTimer = Timer.periodic(const Duration(milliseconds: 45), (_) {
        if (mounted && _pressed) {
          widget.onTrigger(token, isRepeat: true);
        } else {
          _cancelRepeat();
        }
      });
    });
  }

  String _effectiveToken(String raw) {
    if (widget.fnActive &&
        LocalTerminalScreenState._fnModmap.containsKey(raw)) {
      return LocalTerminalScreenState._fnModmap[raw]!;
    }
    return raw;
  }

  (String, String?) _slotAtIndex(int slotIndex) {
    final s = widget.spec;
    return switch (slotIndex) {
      1 => ('nw', s.nw),
      2 => ('ne', s.ne),
      3 => ('sw', s.sw),
      4 => ('se', s.se),
      5 => ('w', s.w),
      6 => ('e', s.e),
      7 => ('n', s.n),
      8 => ('s', s.s),
      _ => ('c', s.c),
    };
  }

  // Exact 16-sector Pointers.onTouchMove + getNearestKeyAtDirection (Pointers.java:326-445)
  _FlickResolution _resolveFlickWithSlot(Offset delta) {
    final s = widget.spec;
    // Pointers.MODIFIER_SWIPE_SLACK = 1.75f for latchable modifiers
    final isLatchable = _latchableModifiers.contains(s.c);
    final threshold = widget.config.flickThreshold * (isLatchable ? 1.35 : 1.0);
    if (delta.distance < threshold) {
      return _FlickResolution('c', s.c);
    }

    // Pointers.java:424-427:
    // double a = Math.atan2(dy, dx) + Math.PI;
    // int direction = ((int)(a * 8 / Math.PI) + 12) % 16;
    final a = math.atan2(delta.dy, delta.dx) + math.pi;
    final direction = ((a * 8.0 / math.pi).floor() + 12) % 16;

    // Pointers.getNearestKeyAtDirection (Pointers.java:357-382):
    // Scans [0, -1, +1, -2, +2, -3, +3] (43% of the circle centered on initial swipe direction)
    for (final offset in _sectorSearchOrder) {
      final d = (direction + offset + 16) % 16;
      final slotIdx = _directionToIndex[d];
      final (slotName, token) = _slotAtIndex(slotIdx);
      if (token != null && token.isNotEmpty) {
        // Pointers.java:374: When the nearest key is a slider (cursor_left/cursor_right),
        // only select it if placed within 18% of the original swipe direction (|offset| < 2).
        final isSlider = token == 'cursor_left' || token == 'cursor_right';
        if (isSlider && offset.abs() >= 2) {
          continue;
        }
        return _FlickResolution(slotName, token);
      }
    }
    return _FlickResolution('c', s.c);
  }

  Rect? _computeKeyBoundsInStack() {
    final keyObj = context.findRenderObject();
    final stackObj = widget.stackRootKey.currentContext?.findRenderObject();
    if (keyObj is! RenderBox || stackObj is! RenderBox || !keyObj.hasSize) {
      return null;
    }
    final topLeft = keyObj.localToGlobal(Offset.zero, ancestor: stackObj);
    return topLeft & keyObj.size;
  }

  // Exact KeyValue.java symbol table from termux-launcher/inapp-keyboard
  _RenderedSymbol _renderToken(String? val, {bool applyShift = false}) {
    if (val == null || val.isEmpty) return const _RenderedSymbol('');
    if (val.startsWith('tool:')) {
      final idx = val.indexOf(':', 5);
      final sym = (idx >= 0 && idx + 1 < val.length)
          ? val.substring(idx + 1)
          : '⌘';
      return _RenderedSymbol(sym, smaller: true);
    }
    return switch (val) {
      'shift' => const _RenderedSymbol('\uE00A', useSpecialFont: true),
      'capslock' => const _RenderedSymbol('\uE012', useSpecialFont: true),
      'backspace' => const _RenderedSymbol('\uE011', useSpecialFont: true),
      'delete' => const _RenderedSymbol('\uE010', useSpecialFont: true),
      'enter' => const _RenderedSymbol('\uE00E', useSpecialFont: true),
      'tab' => const _RenderedSymbol(
        '\uE00F',
        useSpecialFont: true,
        smaller: true,
      ),
      'space' => const _RenderedSymbol(
        '\uE00D',
        useSpecialFont: true,
        smaller: true,
      ),
      'compose' => const _RenderedSymbol('\uE016', useSpecialFont: true),
      'config' => const _RenderedSymbol(
        '\uE004',
        useSpecialFont: true,
        smaller: true,
      ),
      'change_method' => const _RenderedSymbol(
        '\uE009',
        useSpecialFont: true,
        smaller: true,
      ),
      'switch_clipboard' => const _RenderedSymbol(
        '\uE017',
        useSpecialFont: true,
      ),
      'switch_forward' => const _RenderedSymbol(
        '\uE013',
        useSpecialFont: true,
        smaller: true,
      ),
      'switch_backward' => const _RenderedSymbol(
        '\uE014',
        useSpecialFont: true,
        smaller: true,
      ),
      'up' => const _RenderedSymbol('\uE005', useSpecialFont: true),
      'right' || 'cursor_right' => const _RenderedSymbol(
        '\uE006',
        useSpecialFont: true,
        smaller: true,
      ),
      'down' => const _RenderedSymbol('\uE007', useSpecialFont: true),
      'left' || 'cursor_left' => const _RenderedSymbol(
        '\uE008',
        useSpecialFont: true,
        smaller: true,
      ),
      'page_up' => const _RenderedSymbol('\uE002', useSpecialFont: true),
      'page_down' => const _RenderedSymbol('\uE003', useSpecialFont: true),
      'home' => const _RenderedSymbol(
        '\uE00B',
        useSpecialFont: true,
        smaller: true,
      ),
      'end' => const _RenderedSymbol(
        '\uE00C',
        useSpecialFont: true,
        smaller: true,
      ),
      'esc' => const _RenderedSymbol('Esc', smaller: true),
      'ctrl' => const _RenderedSymbol('Ctrl', smaller: true),
      'alt' => const _RenderedSymbol('Alt', smaller: true),
      'fn' => const _RenderedSymbol('Fn', smaller: true),
      'meta' => const _RenderedSymbol('Meta', smaller: true),
      'switch_numeric' => const _RenderedSymbol('123+', smaller: true),
      'switch_text' => const _RenderedSymbol('ABC', smaller: true),
      'switch_greekmath' => const _RenderedSymbol('πλ∇¬', smaller: true),
      'superscript' => const _RenderedSymbol('Sup', smaller: true),
      'subscript' => const _RenderedSymbol('Sub', smaller: true),
      'ordinal' => const _RenderedSymbol('Ord', smaller: true),
      'arrows' => const _RenderedSymbol('Arr', smaller: true),
      'box' => const _RenderedSymbol('Box', smaller: true),
      'insert' => const _RenderedSymbol('Ins', smaller: true),
      'action' => const _RenderedSymbol('↵', smaller: true),
      _ => () {
        if (val.startsWith('f') &&
            val.length <= 3 &&
            int.tryParse(val.substring(1)) != null) {
          return _RenderedSymbol(val.toUpperCase(), smaller: val.length == 3);
        }
        final txt = (applyShift && val.length == 1) ? val.toUpperCase() : val;
        return _RenderedSymbol(txt, smaller: txt.length > 1);
      }(),
    };
  }

  Widget _subLabel(
    Alignment alignment,
    String slotName,
    String? rawToken,
    Color baseColor,
  ) {
    if (!widget.config.showSubLabels || rawToken == null) {
      return const SizedBox.shrink();
    }
    final token = _effectiveToken(rawToken);
    final sym = _renderToken(token);
    if (sym.text.isEmpty) return const SizedBox.shrink();
    final isTargeted = _pressed && _activeSlot == slotName;
    final color = isTargeted ? widget.palette.activeKeyColor : baseColor;
    final baseFontSize = sym.useSpecialFont ? 10.5 : (sym.smaller ? 9.0 : 10.0);
    return Align(
      alignment: alignment,
      child: AnimatedScale(
        scale: isTargeted ? 1.24 : 1.0,
        duration: const Duration(milliseconds: 55),
        child: Text(
          sym.text,
          style: TextStyle(
            fontFamily: sym.useSpecialFont
                ? 'UnexpectedKeyboard'
                : 'MesloLGS NF',
            fontSize: baseFontSize,
            fontWeight: isTargeted ? FontWeight.w700 : FontWeight.w400,
            color: color,
            height: 1.0,
            shadows: isTargeted
                ? [
                    Shadow(
                      color: widget.palette.activeKeyColor.withValues(
                        alpha: 0.65,
                      ),
                      blurRadius: 6,
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.spec;
    final p = widget.palette;
    final centerToken = _effectiveToken(s.c);
    final centerSym = _renderToken(centerToken, applyShift: widget.shift);

    final baseBgColor = widget.active
        ? p.activeKeyColor
        : s.isSpaceBar
        ? p.spaceBarColor
        : s.isAction
        ? p.actionKeyColor
        : p.keyColor;

    final labelColor = (s.c == 'shift' && widget.capsLock)
        ? p.lockedLabelColor
        : widget.active
        ? p.activeLabelColor
        : (s.isSpaceBar ? p.spaceLabelColor : p.labelColor);

    final subLabelColor = widget.active
        ? p.activeLabelColor.withValues(alpha: 0.78)
        : p.subLabelColor;

    final swiped =
        _pressed &&
        _panDelta.distance >= widget.config.flickThreshold * 0.72 &&
        _activeSlot != 'c';

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _panStart = event.localPosition;
        _panDelta = Offset.zero;
        _firstAngle = null;
        _lastAngle = null;
        _angularTravel = 0.0;
        _trailPoints
          ..clear()
          ..add(event.localPosition);
        _activeSlot = 'c';
        _activePointerId = event.pointer;
        _sliderAccumDx = 0.0;
        _sliderMoved = false;
        setState(() => _pressed = true);
        if (widget.config.pressAnimation) {
          _pressFxController.forward();
        }
        widget.onFeedback(centerToken, isSwipeSlot: false);
        if (widget.config.showKeyPopup) {
          final bounds = _computeKeyBoundsInStack();
          if (bounds != null) {
            widget.popupController.show(
              pointerId: event.pointer,
              keyBounds: bounds,
              symbol: centerSym,
              slot: 'c',
            );
          }
        }
        _startRepeatIfApplicable(s.c);
      },
      onPointerMove: (event) {
        final start = _panStart;
        if (start == null) return;
        final delta = event.localPosition - start;
        if (delta.distance >= widget.config.flickThreshold) {
          _cancelRepeat();
        }
        // Continuous horizontal cursor slider on the spacebar
        if (s.isSpaceBar && delta.dx.abs() > delta.dy.abs() * 1.4) {
          _sliderAccumDx += event.delta.dx;
          const stepPx = 14.0;
          while (_sliderAccumDx.abs() >= stepPx) {
            _sliderMoved = true;
            if (_sliderAccumDx > 0) {
              widget.onTrigger('cursor_right', isRepeat: true);
              _sliderAccumDx -= stepPx;
            } else {
              widget.onTrigger('cursor_left', isRepeat: true);
              _sliderAccumDx += stepPx;
            }
          }
          if (_sliderMoved) return;
        }

        final resolved = _resolveFlickWithSlot(delta);
        final slotChanged = resolved.slot != _activeSlot;
        // TouchFx.update angular tracking (Keyboard2View.java:2954-2967)
        if (delta.distance >= widget.config.flickThreshold * 0.72) {
          final angle = math.atan2(delta.dy, delta.dx);
          _firstAngle ??= angle;
          if (_lastAngle != null) {
            var dAngle = angle - _lastAngle!;
            while (dAngle > math.pi) {
              dAngle -= math.pi * 2.0;
            }
            while (dAngle < -math.pi) {
              dAngle += math.pi * 2.0;
            }
            if (dAngle.abs() < 1.25) {
              _angularTravel += dAngle;
            }
          }
          _lastAngle = angle;
        }
        setState(() {
          _panDelta = delta;
          _activeSlot = resolved.slot;
          _trailPoints.add(event.localPosition);
          if (_trailPoints.length > 18) {
            _trailPoints.removeAt(0);
          }
        });
        if (slotChanged) {
          final effToken = _effectiveToken(resolved.token);
          final sym = _renderToken(
            effToken,
            applyShift: resolved.slot == 'c' && widget.shift,
          );
          widget.onFeedback(effToken, isSwipeSlot: true);
          if (widget.config.showKeyPopup && _activePointerId != null) {
            widget.popupController.target(
              pointerId: _activePointerId!,
              symbol: sym,
              slot: resolved.slot,
            );
          }
        }
      },
      onPointerCancel: (event) {
        _cancelRepeat();
        _panStart = null;
        _panDelta = Offset.zero;
        _trailPoints.clear();
        _activeSlot = 'c';
        _sliderMoved = false;
        if (_activePointerId != null) {
          widget.popupController.hide(_activePointerId!);
          _activePointerId = null;
        }
        if (_pressed) setState(() => _pressed = false);
        _pressFxController.reverse();
      },
      onPointerUp: (event) {
        _cancelRepeat();
        final start = _panStart;
        _panStart = null;
        final movedSlider = _sliderMoved;
        _sliderMoved = false;
        if (_activePointerId != null) {
          widget.popupController.hide(_activePointerId!);
          _activePointerId = null;
        }
        if (_pressed) {
          setState(() {
            _pressed = false;
            _panDelta = Offset.zero;
            _trailPoints.clear();
            _activeSlot = 'c';
          });
        }
        _pressFxController.reverse();
        if (start != null && !movedSlider) {
          final delta = event.localPosition - start;
          final resolved = _resolveFlickWithSlot(delta);
          widget.onTrigger(resolved.token);
        }
      },
      child: AnimatedBuilder(
        animation: _pressFxController,
        builder: (context, child) {
          final strength = widget.config.pressAnimation
              ? _pressFxController.value
              : (_pressed ? 1.0 : 0.0);
          // Keyboard2View.java:2539: float scale = (!fx.swiped && fxStrength > 0f) ? (1f - 0.035f * fxStrength) : 1f
          final scale = (!swiped && strength > 0.0)
              ? (1.0 - 0.035 * strength)
              : 1.0;
          final bgColor = Color.lerp(baseBgColor, p.pressedKeyColor, strength)!;
          final borderColor = widget.active
              ? p.activeBorderColor
              : Color.lerp(
                  p.borderColor,
                  p.activeBorderColor.withValues(alpha: 0.72),
                  swiped ? 0.85 : (strength * 0.45),
                )!;
          return Transform.scale(
            scale: scale,
            child: CustomPaint(
              foregroundPainter:
                  (widget.config.pressAnimation && (strength > 0 || swiped))
                  ? _TouchFxPainter(
                      strength: strength,
                      swiped: swiped,
                      panDelta: _panDelta,
                      firstAngle: _firstAngle,
                      angularTravel: _angularTravel,
                      trailPoints: List<Offset>.of(_trailPoints),
                      accentColor: p.activeKeyColor,
                      pressedColor: p.pressedKeyColor,
                    )
                  : null,
              child: Container(
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: borderColor,
                    width: swiped ? (p.borderWidth + 0.35) : p.borderWidth,
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 3.5,
                  vertical: 2.5,
                ),
                child: child,
              ),
            ),
          );
        },
        child: Stack(
          children: [
            _subLabel(Alignment.topLeft, 'nw', s.nw, subLabelColor),
            _subLabel(Alignment.topRight, 'ne', s.ne, subLabelColor),
            _subLabel(Alignment.bottomLeft, 'sw', s.sw, subLabelColor),
            _subLabel(Alignment.bottomRight, 'se', s.se, subLabelColor),
            _subLabel(Alignment.topCenter, 'n', s.n, subLabelColor),
            _subLabel(Alignment.bottomCenter, 's', s.s, subLabelColor),
            _subLabel(Alignment.centerLeft, 'w', s.w, subLabelColor),
            _subLabel(Alignment.centerRight, 'e', s.e, subLabelColor),
            Center(
              child: AnimatedOpacity(
                opacity: (_pressed && _activeSlot != 'c') ? 0.48 : 1.0,
                duration: const Duration(milliseconds: 55),
                child: Text(
                  centerSym.text,
                  style: TextStyle(
                    fontFamily: centerSym.useSpecialFont
                        ? 'UnexpectedKeyboard'
                        : 'MesloLGS NF',
                    fontSize: centerSym.useSpecialFont
                        ? 17.0
                        : (centerSym.smaller ? 12.5 : 16.0),
                    fontWeight: FontWeight.w500,
                    color: labelColor,
                    height: 1.0,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// 1:1 port of Keyboard2View.drawTouchFx (lines 2577-2640) + swipe trail
class _TouchFxPainter extends CustomPainter {
  const _TouchFxPainter({
    required this.strength,
    required this.swiped,
    required this.panDelta,
    required this.firstAngle,
    required this.angularTravel,
    required this.trailPoints,
    required this.accentColor,
    required this.pressedColor,
  });

  final double strength;
  final bool swiped;
  final Offset panDelta;
  final double? firstAngle;
  final double angularTravel;
  final List<Offset> trailPoints;
  final Color accentColor;
  final Color pressedColor;

  bool get _isRotating => angularTravel.abs() > 1.05 && firstAngle != null;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(5));
    canvas.save();
    canvas.clipRRect(rrect);

    if (!swiped && strength > 0) {
      // Non-swiped press highlight overlay (Keyboard2View.drawTouchFx:2583-2597)
      final fillPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = Colors.white.withValues(alpha: 0.06 * strength);
      canvas.drawRRect(rrect, fillPaint);
    }

    if (swiped) {
      // Swipe trail across finger path
      if (trailPoints.length >= 2) {
        for (var i = 1; i < trailPoints.length; i++) {
          final t = i / trailPoints.length;
          final trailPaint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = 1.6 + 2.4 * t
            ..color = accentColor.withValues(alpha: 0.14 + 0.36 * t);
          canvas.drawLine(trailPoints[i - 1], trailPoints[i], trailPaint);
        }
      }

      final cx = size.width / 2.0;
      final cy = size.height / 2.0;
      final center = Offset(cx, cy);
      final minDim = math.min(size.width, size.height);

      if (_isRotating) {
        // Circular rotation arc (Keyboard2View.drawTouchFx:2602-2619)
        final ringRadius = minDim * 0.31;
        final arcRect = Rect.fromCircle(center: center, radius: ringRadius);
        final sweep = angularTravel.clamp(-5.76, 5.76);
        final haloPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(5.0, ringRadius * 0.24)
          ..color = accentColor.withValues(alpha: 0.22);
        canvas.drawArc(arcRect, firstAngle!, sweep, false, haloPaint);
        final strokePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(1.8, ringRadius * 0.085)
          ..color = accentColor.withValues(alpha: 0.88);
        canvas.drawArc(arcRect, firstAngle!, sweep, false, strokePaint);
      } else {
        // Directional swipe vector line + halo + endpoint dot (Keyboard2View.drawTouchFx:2621-2639)
        final dx = panDelta.dx;
        final dy = panDelta.dy;
        final scale = math.max(
          1.0,
          math.max(
            dx.abs() / math.max(1.0, size.width * 0.40),
            dy.abs() / math.max(1.0, size.height * 0.38),
          ),
        );
        final end = Offset(cx + dx / scale, cy + dy / scale);

        final haloPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(5.0, minDim * 0.17)
          ..color = accentColor.withValues(alpha: 0.24);
        canvas.drawLine(center, end, haloPaint);

        final linePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(1.8, minDim * 0.05)
          ..color = accentColor.withValues(alpha: 0.90);
        canvas.drawLine(center, end, linePaint);

        final dotHaloPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = accentColor.withValues(alpha: 0.28);
        canvas.drawCircle(end, math.max(4.8, minDim * 0.11), dotHaloPaint);

        final dotPaint = Paint()
          ..style = PaintingStyle.fill
          ..color = accentColor.withValues(alpha: 0.92);
        canvas.drawCircle(end, math.max(2.2, minDim * 0.058), dotPaint);
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TouchFxPainter oldDelegate) =>
      oldDelegate.strength != strength ||
      oldDelegate.swiped != swiped ||
      oldDelegate.panDelta != panDelta ||
      oldDelegate.angularTravel != angularTravel ||
      oldDelegate.trailPoints.length != trailPoints.length;
}

// 1:1 port of termux-launcher's KeyPopupOverlayView.java + KeyPopupGeometry.java
class _KeyPopupEntry {
  _KeyPopupEntry({
    required this.pointerId,
    required this.keyBounds,
    required this.symbol,
    required this.slot,
    required this.shownAt,
  }) : updatedAt = shownAt;

  final int pointerId;
  final Rect keyBounds;
  _RenderedSymbol symbol;
  _RenderedSymbol? previousSymbol;
  String slot;
  final DateTime shownAt;
  DateTime updatedAt;
  DateTime? exitStartedAt;
  Timer? dwellTimer;
}

class _KeyPopupOverlayController extends ChangeNotifier {
  final Map<int, _KeyPopupEntry> active = <int, _KeyPopupEntry>{};
  final List<_KeyPopupEntry> exiting = <_KeyPopupEntry>[];

  // KeyPopupOverlayView.MIN_VISIBLE_MS = 180L, EXIT_MS = 140L
  static const int minVisibleMs = 180;
  static const int enterMs = 130;
  static const int swapMs = 60;
  static const int exitMs = 140;

  void show({
    required int pointerId,
    required Rect keyBounds,
    required _RenderedSymbol symbol,
    required String slot,
  }) {
    final prev = active.remove(pointerId);
    prev?.dwellTimer?.cancel();
    exiting.removeWhere((e) {
      if (e.keyBounds == keyBounds) {
        e.dwellTimer?.cancel();
        return true;
      }
      return false;
    });
    active[pointerId] = _KeyPopupEntry(
      pointerId: pointerId,
      keyBounds: keyBounds,
      symbol: symbol,
      slot: slot,
      shownAt: DateTime.now(),
    );
    notifyListeners();
  }

  void target({
    required int pointerId,
    required _RenderedSymbol symbol,
    required String slot,
  }) {
    final popup = active[pointerId];
    if (popup == null) return;
    if (popup.slot == slot && popup.symbol.text == symbol.text) return;
    popup.previousSymbol = popup.symbol;
    popup.symbol = symbol;
    popup.slot = slot;
    popup.updatedAt = DateTime.now();
    notifyListeners();
  }

  void hide(int pointerId) {
    final popup = active.remove(pointerId);
    if (popup == null) return;
    exiting.add(popup);
    final elapsedMs = DateTime.now().difference(popup.shownAt).inMilliseconds;
    final remainingMs = minVisibleMs - elapsedMs;
    if (remainingMs > 0) {
      popup.dwellTimer = Timer(Duration(milliseconds: remainingMs), () {
        _startExit(popup);
      });
    } else {
      _startExit(popup);
    }
    notifyListeners();
  }

  void _startExit(_KeyPopupEntry popup) {
    popup.exitStartedAt = DateTime.now();
    notifyListeners();
    popup.dwellTimer = Timer(const Duration(milliseconds: exitMs + 20), () {
      exiting.remove(popup);
      notifyListeners();
    });
  }

  void clearAll() {
    for (final p in active.values) {
      p.dwellTimer?.cancel();
    }
    active.clear();
    for (final p in exiting) {
      p.dwellTimer?.cancel();
    }
    exiting.clear();
  }
}

class _KeyPopupOverlay extends StatefulWidget {
  const _KeyPopupOverlay({required this.controller, required this.palette});

  final _KeyPopupOverlayController controller;
  final _TerminalVisualPalette palette;

  @override
  State<_KeyPopupOverlay> createState() => _KeyPopupOverlayState();
}

class _KeyPopupOverlayState extends State<_KeyPopupOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;

  static const Cubic _enterCurve = Cubic(0.05, 0.7, 0.1, 1.0);
  static const Cubic _exitCurve = Cubic(0.3, 0.0, 0.8, 0.15);

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant _KeyPopupOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _ticker.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final hasAny =
        widget.controller.active.isNotEmpty ||
        widget.controller.exiting.isNotEmpty;
    if (hasAny && !_ticker.isAnimating) {
      _ticker.repeat();
    } else if (!hasAny && _ticker.isAnimating) {
      _ticker.stop();
    }
    if (mounted) setState(() {});
  }

  // KeyPopupGeometry.metricsFor(label, density)
  double _glyphFontSize(_RenderedSymbol sym) {
    if (sym.useSpecialFont) return 28.0;
    final len = sym.text.runes.length;
    if (len <= 1) return 27.0;
    if (len == 2) return 18.0;
    if (len <= 4) return 14.0;
    return 12.0;
  }

  Widget _buildGlyphText(
    _RenderedSymbol sym,
    double fontSize,
    double alpha,
    _TerminalVisualPalette palette,
  ) {
    final clampedAlpha = alpha.clamp(0.0, 1.0);
    if (clampedAlpha <= 0.01 || sym.text.isEmpty) {
      return const SizedBox.shrink();
    }
    // KeyPopupOverlayView.drawGlyph: dual zero-offset accent glow + crisp foreground ink
    return Text(
      sym.text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontFamily: sym.useSpecialFont ? 'UnexpectedKeyboard' : 'MesloLGS NF',
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        color: palette.labelColor.withValues(alpha: clampedAlpha),
        height: 1.0,
        shadows: [
          Shadow(
            color: palette.activeKeyColor.withValues(
              alpha: 0.78 * clampedAlpha,
            ),
            blurRadius: 4.5,
          ),
          Shadow(
            color: palette.activeKeyColor.withValues(
              alpha: 0.36 * clampedAlpha,
            ),
            blurRadius: 14.0,
          ),
          Shadow(
            color: Colors.black.withValues(alpha: 0.65 * clampedAlpha),
            blurRadius: 6.0,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = <_KeyPopupEntry>[
      ...widget.controller.active.values,
      ...widget.controller.exiting,
    ];
    if (entries.isEmpty) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _ticker,
      builder: (context, _) {
        final now = DateTime.now();
        return LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth;
            final children = <Widget>[];
            for (final popup in entries) {
              final enterRaw =
                  (now.difference(popup.shownAt).inMilliseconds /
                          _KeyPopupOverlayController.enterMs)
                      .clamp(0.0, 1.0);
              final enterT = _enterCurve.transform(enterRaw);

              final isExiting = popup.exitStartedAt != null;
              final exitRaw = isExiting
                  ? (now.difference(popup.exitStartedAt!).inMilliseconds /
                            _KeyPopupOverlayController.exitMs)
                        .clamp(0.0, 1.0)
                  : 0.0;
              final exitT = _exitCurve.transform(exitRaw);

              final alpha = isExiting
                  ? (1.0 - exitT).clamp(0.0, 1.0)
                  : (enterT * 1.5).clamp(0.0, 1.0);
              if (alpha <= 0.01) continue;

              // KeyPopupOverlayView: ENTER_FROM_SCALE = 0.82f, EXIT_TO_SCALE = 0.9f
              final scale = isExiting
                  ? (1.0 + (0.90 - 1.0) * exitT)
                  : (0.82 + (1.0 - 0.82) * enterT);

              final fontSize = _glyphFontSize(popup.symbol);
              // KeyPopupGeometry: GAP_ABOVE_CAP_DP = 6f, SIDE_MARGIN_DP = 4f
              const gapAboveCap = 8.0;
              const sideMargin = 6.0;
              final anchorY = math.max(
                fontSize / 2 + 4.0,
                popup.keyBounds.top - gapAboveCap - fontSize / 2,
              );
              // KeyPopupOverlayView.translateYPx: rises from keyBounds.top to anchorY, exits -10dp upwards
              final fromCap = popup.keyBounds.top - anchorY;
              final dy = isExiting
                  ? (-10.0 * exitT)
                  : (fromCap * (1.0 - enterT));

              final estHalfWidth = math.max(
                18.0,
                popup.symbol.text.runes.length * fontSize * 0.36 + 10.0,
              );
              final anchorX = popup.keyBounds.center.dx.clamp(
                sideMargin + estHalfWidth,
                math.max(
                  sideMargin + estHalfWidth,
                  maxW - sideMargin - estHalfWidth,
                ),
              );

              final swapRaw =
                  (now.difference(popup.updatedAt).inMilliseconds /
                          _KeyPopupOverlayController.swapMs)
                      .clamp(0.0, 1.0);

              children.add(
                Positioned(
                  left: anchorX - estHalfWidth,
                  top: (anchorY + dy) - fontSize * 0.75,
                  width: estHalfWidth * 2,
                  child: Transform.scale(
                    scale: scale,
                    child: Center(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          if (popup.previousSymbol != null && swapRaw < 1.0)
                            _buildGlyphText(
                              popup.previousSymbol!,
                              _glyphFontSize(popup.previousSymbol!),
                              alpha * (1.0 - swapRaw),
                              widget.palette,
                            ),
                          _buildGlyphText(
                            popup.symbol,
                            fontSize,
                            alpha *
                                (popup.previousSymbol != null ? swapRaw : 1.0),
                            widget.palette,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }
            return Stack(clipBehavior: Clip.none, children: children);
          },
        );
      },
    );
  }
}
