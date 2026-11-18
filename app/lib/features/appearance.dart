import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

bool isAmoledTheme(String appearance) =>
    appearance == 'amoled' ||
    appearance == 'amoled-green' ||
    appearance == 'amoled-red';

class MatteArtItem {
  const MatteArtItem({
    required this.kind,
    required this.x,
    required this.y,
    required this.scale,
    required this.tilt,
    required this.color,
    required this.foreground,
  });

  final String kind; // 'bird' or 'flower'
  final double x; // normalized 0..1
  final double y; // normalized 0..1
  final double scale;
  final double tilt; // radians
  final int color; // ARGB
  final bool foreground;

  MatteArtItem copyWith({
    String? kind,
    double? x,
    double? y,
    double? scale,
    double? tilt,
    int? color,
    bool? foreground,
  }) => MatteArtItem(
    kind: kind ?? this.kind,
    x: x ?? this.x,
    y: y ?? this.y,
    scale: scale ?? this.scale,
    tilt: tilt ?? this.tilt,
    color: color ?? this.color,
    foreground: foreground ?? this.foreground,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'x': x,
    'y': y,
    'scale': scale,
    'tilt': tilt,
    'color': color,
    'foreground': foreground,
  };

  factory MatteArtItem.fromJson(Map<String, dynamic> map) => MatteArtItem(
    kind: map['kind'] == 'bird' ? 'bird' : 'flower',
    x: ((map['x'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0),
    y: ((map['y'] as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0),
    scale: ((map['scale'] as num?)?.toDouble() ?? 0.9).clamp(0.35, 2.2),
    tilt: ((map['tilt'] as num?)?.toDouble() ?? 0.0).clamp(-math.pi, math.pi),
    color: (map['color'] as num?)?.toInt() ?? 0xfff7f3dd,
    foreground: map['foreground'] == true,
  );
}

List<MatteArtItem> defaultMatteItems() => const [
  // Topbar flowers
  MatteArtItem(kind: 'flower', x: 0.54, y: 0.060, scale: 0.66, tilt: 0, color: 0xfff7f3dd, foreground: false),
  MatteArtItem(kind: 'flower', x: 0.62, y: 0.073, scale: 0.50, tilt: 0, color: 0xffe5b93c, foreground: false),
  // One side-edge flower
  MatteArtItem(kind: 'flower', x: 0.95, y: 0.360, scale: 0.90, tilt: 0, color: 0xfff7f3dd, foreground: false),
  // Horizontal center flower
  MatteArtItem(kind: 'flower', x: 0.50, y: 0.480, scale: 1.00, tilt: 0, color: 0xffe5b93c, foreground: false),
  // Bigger bird centered horizontally above the bottom bar, surrounded by flowers
  MatteArtItem(kind: 'flower', x: 0.16, y: 0.845, scale: 0.96, tilt: 0, color: 0xfff7f3dd, foreground: false),
  MatteArtItem(kind: 'flower', x: 0.29, y: 0.858, scale: 0.74, tilt: 0, color: 0xffe5b93c, foreground: false),
  MatteArtItem(kind: 'bird', x: 0.50, y: 0.850, scale: 1.00, tilt: 0, color: 0xff20231c, foreground: false),
  MatteArtItem(kind: 'flower', x: 0.71, y: 0.856, scale: 0.78, tilt: 0, color: 0xfff7f3dd, foreground: false),
  MatteArtItem(kind: 'flower', x: 0.84, y: 0.845, scale: 0.94, tilt: 0, color: 0xffe5b93c, foreground: false),
  // Single larger flower at the bottom, tilted 45 degrees
  MatteArtItem(kind: 'flower', x: 0.45, y: 0.952, scale: 1.18, tilt: math.pi / 4, color: 0xfff7f3dd, foreground: false),
];

List<MatteArtItem> decodeMatteItems(String? raw) {
  if (raw == null || raw.isEmpty) return defaultMatteItems();
  try {
    final list = jsonDecode(raw) as List;
    if (list.isEmpty) return const [];
    return list
        .take(40)
        .map((e) => MatteArtItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  } catch (_) {
    return defaultMatteItems();
  }
}

String encodeMatteItems(List<MatteArtItem> items) =>
    jsonEncode(items.map((e) => e.toJson()).toList());

/// Static decoration: no animation controller, timer, image asset or wake lock.
class AppearanceSurface extends StatelessWidget {
  const AppearanceSurface({
    super.key,
    required this.appearance,
    required this.child,
    this.matteItems,
  });
  final String appearance;
  final Widget child;
  final List<MatteArtItem>? matteItems;
  @override
  Widget build(BuildContext context) {
    final items = matteItems ?? defaultMatteItems();
    return Stack(
      fit: StackFit.expand,
      children: [
        if (appearance == 'matte')
          ColoredBox(
            color: const Color(0xffa3ad4c),
            child: CustomPaint(painter: _MattePaperArt(items: items)),
          ),
        child,
        if (appearance == 'matte' && items.any((e) => e.foreground))
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _MatteForegroundArt(items: items)),
            ),
          ),
        if (isAmoledTheme(appearance))
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _EdgeGlow(isRed: appearance == 'amoled-red'),
              ),
            ),
          ),
      ],
    );
  }
}

class _EdgeGlow extends CustomPainter {
  const _EdgeGlow({required this.isRed});
  final bool isRed;

  @override
  void paint(Canvas canvas, Size size) {
    // Cover ~80% of the screen height, centered vertically, fading out cleanly
    // before reaching the corners. Straight stationary left & right edges only.
    final top = size.height * 0.10;
    final bottom = size.height * 0.90;
    final left = Offset(1.0, top);
    final leftEnd = Offset(1.0, bottom);
    final right = Offset(size.width - 1.0, top);
    final rightEnd = Offset(size.width - 1.0, bottom);
    final lineRect = Rect.fromLTRB(0, top, size.width, bottom);

    final edgeColor = isRed ? const Color(0xffcc0022) : const Color(0xff00b848);
    final peakColor = isRed ? const Color(0xffff1738) : const Color(0xff1cff68);
    const stops = [0.0, 0.20, 0.50, 0.80, 1.0];

    final haloShader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: stops,
      colors: [
        Colors.transparent,
        edgeColor.withValues(alpha: 0.36),
        peakColor.withValues(alpha: 0.78),
        edgeColor.withValues(alpha: 0.36),
        Colors.transparent,
      ],
    ).createShader(lineRect);

    final coreShader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: stops,
      colors: [
        Colors.transparent,
        edgeColor,
        peakColor,
        edgeColor,
        Colors.transparent,
      ],
    ).createShader(lineRect);

    final haloPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeCap = StrokeCap.round
      ..shader = haloShader
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3.5);

    final corePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..shader = coreShader;

    canvas.drawLine(left, leftEnd, haloPaint);
    canvas.drawLine(right, rightEnd, haloPaint);
    canvas.drawLine(left, leftEnd, corePaint);
    canvas.drawLine(right, rightEnd, corePaint);
  }

  @override
  bool shouldRepaint(covariant _EdgeGlow oldDelegate) =>
      oldDelegate.isRed != isRed;
}

Widget amoledNavIcon(BuildContext context, IconData icon, String appearance) {
  if (!isAmoledTheme(appearance)) {
    return Icon(icon);
  }
  final isRed = appearance == 'amoled-red';
  final edge = isRed ? const Color(0xffcc0022) : const Color(0xff00b848);
  final peak = isRed ? const Color(0xffff1738) : const Color(0xff1cff68);
  return Container(
    width: 64,
    height: 32,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [edge, peak, edge],
      ),
      boxShadow: [
        BoxShadow(
          color: peak.withValues(alpha: 0.45),
          blurRadius: 10,
          spreadRadius: 0.5,
        ),
      ],
    ),
    child: Center(child: Icon(icon, color: Colors.black)),
  );
}

ThemeData amoledTheme(String appearance) {
  final isRed = appearance == 'amoled-red';
  final edge = isRed ? const Color(0xffcc0022) : const Color(0xff00b848);
  final neon = isRed ? const Color(0xffff1738) : const Color(0xff1cff68);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: neon,
        brightness: Brightness.dark,
      ).copyWith(
        primary: neon,
        onPrimary: Colors.black,
        primaryContainer: neon.withValues(alpha: 0.22),
        onPrimaryContainer: neon,
        secondary: neon,
        onSecondary: Colors.black,
        secondaryContainer: neon,
        onSecondaryContainer: Colors.black,
        tertiary: neon,
        onTertiary: Colors.black,
        surface: Colors.black,
        surfaceContainer: Colors.black,
        surfaceContainerLow: Colors.black,
        surfaceContainerHigh: const Color(0xff080808),
        surfaceContainerHighest: const Color(0xff111111),
      );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: Colors.black,
    useMaterial3: true,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.black,
      indicatorColor: Colors.transparent,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? Colors.black
              : Colors.white70,
        ),
      ),
      surfaceTintColor: Colors.transparent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.disabled) ? Colors.white38 : Colors.black,
        ),
        backgroundColor: WidgetStateProperty.all(Colors.transparent),
        elevation: WidgetStateProperty.all(0),
        shape: WidgetStateProperty.all(const StadiumBorder()),
        backgroundBuilder: (context, states, child) {
          if (states.contains(WidgetState.disabled)) {
            return DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xff181818),
                borderRadius: BorderRadius.circular(24),
              ),
              child: child,
            );
          }
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [edge, neon, edge],
              ),
              boxShadow: [
                BoxShadow(
                  color: neon.withValues(alpha: 0.45),
                  blurRadius: 10,
                  spreadRadius: 0.5,
                ),
              ],
            ),
            child: child,
          );
        },
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.all(neon),
        side: WidgetStateProperty.all(
          BorderSide(color: neon.withValues(alpha: 0.72), width: 1.2),
        ),
        shape: WidgetStateProperty.all(const StadiumBorder()),
        backgroundBuilder: (context, states, child) => DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(color: neon.withValues(alpha: 0.18), blurRadius: 8),
            ],
          ),
          child: child,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: neon),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? neon : Colors.transparent,
      ),
      checkColor: WidgetStateProperty.all(Colors.black),
      side: BorderSide(color: neon, width: 1.8),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.black : Colors.white70,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) =>
            s.contains(WidgetState.selected) ? neon : const Color(0xff1a1a1a),
      ),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? neon : Colors.white70,
      ),
    ),
    listTileTheme: ListTileThemeData(
      selectedColor: neon,
      selectedTileColor: neon.withValues(alpha: 0.14),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: neon,
      linearTrackColor: const Color(0xff141414),
    ),
    inputDecorationTheme: InputDecorationTheme(
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: neon, width: 2.0),
      ),
    ),
    cardTheme: const CardThemeData(
      color: Color(0xff060606),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: Color(0xff1b1b1b), width: 0.8),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Color(0xff0a0a0a),
      surfaceTintColor: Colors.transparent,
    ),
  );
}

class _MattePaperArt extends CustomPainter {
  const _MattePaperArt({required this.items});
  final List<MatteArtItem> items;

  @override
  void paint(Canvas canvas, Size size) {
    // Soft olive-moss watercolor washes so the edges evoke the reference meadow
    // while keeping center text high-contrast against the matte sage paper.
    final wash = Paint()
      ..color = const Color(0x5584902c)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 48);
    canvas.drawCircle(Offset(size.width * 0.12, size.height * 0.14), 140, wash);
    canvas.drawCircle(Offset(size.width * 0.88, size.height * 0.22), 160, wash);
    canvas.drawOval(
      Rect.fromLTWH(
        -40,
        size.height * 0.72,
        size.width + 80,
        size.height * 0.35,
      ),
      Paint()
        ..color = const Color(0x6684902c)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 36),
    );

    // Paper grain speckle.
    final grain = Paint()
      ..color = const Color(0x1438421d)
      ..strokeWidth = 0.75;
    var value = 739391;
    for (var i = 0; i < 1600; i++) {
      value = (value * 48271) % 2147483647;
      final x = value / 2147483647 * size.width;
      value = (value * 48271) % 2147483647;
      final y = value / 2147483647 * size.height;
      canvas.drawLine(Offset(x, y), Offset(x + 0.9, y + 0.15), grain);
    }

    for (final item in items) {
      if (!item.foreground) {
        drawMatteItem(canvas, size, item);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MattePaperArt oldDelegate) =>
      oldDelegate.items != items;
}

class _MatteForegroundArt extends CustomPainter {
  const _MatteForegroundArt({required this.items});
  final List<MatteArtItem> items;

  @override
  void paint(Canvas canvas, Size size) {
    for (final item in items) {
      if (item.foreground) {
        drawMatteItem(canvas, size, item);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MatteForegroundArt oldDelegate) =>
      oldDelegate.items != items;
}

void drawMatteItem(Canvas canvas, Size size, MatteArtItem item) {
  final center = Offset(size.width * item.x, size.height * item.y);
  if (item.kind == 'bird') {
    _drawCoolCrow(
      canvas,
      center,
      item.scale,
      bodyColor: Color(item.color),
      tilt: item.tilt,
    );
  } else {
    _drawFlower(
      canvas,
      center,
      Color(item.color),
      item.scale,
      tilt: item.tilt,
    );
  }
}

abstract final class _MatteMeadowArt {
  static const ink = Color(0xff1b1e14);
  static const cream = Color(0xfff7f3dd);
  static const gold = Color(0xffe5b93c);
  static const leaf = Color(0xff5c7e22);
}

void _drawFlower(
  Canvas canvas,
  Offset center,
  Color petalColor,
  double s, {
  double tilt = 0,
}) {
  final outline = Paint()
    ..color = _MatteMeadowArt.ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.9 * s
    ..strokeJoin = StrokeJoin.round;
  final stemBottom = center + Offset(0, 34 * s);

  if (tilt != 0) {
    canvas.save();
    canvas.translate(stemBottom.dx, stemBottom.dy);
    canvas.rotate(tilt);
    canvas.translate(-stemBottom.dx, -stemBottom.dy);
  }

  canvas.drawOval(
    Rect.fromCenter(
      center: stemBottom + Offset(0, 2 * s),
      width: 22 * s,
      height: 6 * s,
    ),
    Paint()..color = const Color(0x381b1e14),
  );
  canvas.drawLine(
    center + Offset(0, 6 * s),
    stemBottom,
    Paint()
      ..color = _MatteMeadowArt.ink
      ..strokeWidth = 2.2 * s
      ..strokeCap = StrokeCap.round,
  );

  for (final dir in [-1.0, 1.0]) {
    final leaf = Path()
      ..moveTo(stemBottom.dx, stemBottom.dy - 4 * s)
      ..quadraticBezierTo(
        stemBottom.dx + dir * 12 * s,
        stemBottom.dy - 14 * s,
        stemBottom.dx + dir * 14 * s,
        stemBottom.dy - 6 * s,
      )
      ..quadraticBezierTo(
        stemBottom.dx + dir * 8 * s,
        stemBottom.dy + 1 * s,
        stemBottom.dx,
        stemBottom.dy - 4 * s,
      );
    canvas.drawPath(leaf, Paint()..color = _MatteMeadowArt.leaf);
    canvas.drawPath(leaf, outline);
  }

  final petalFill = Paint()..color = petalColor;
  for (var i = 0; i < 5; i++) {
    final angle = i * (2 * 3.14159265 / 5) - 3.14159265 / 2;
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    final rect = Rect.fromCenter(
      center: Offset(0, -8.5 * s),
      width: 8.5 * s,
      height: 11 * s,
    );
    canvas.drawOval(rect, petalFill);
    canvas.drawOval(rect, outline);
    canvas.restore();
  }

  final centerColor = petalColor == _MatteMeadowArt.gold
      ? const Color(0xffd47922)
      : _MatteMeadowArt.gold;
  canvas.drawCircle(center, 4.6 * s, Paint()..color = centerColor);
  canvas.drawCircle(center, 4.6 * s, outline);

  if (tilt != 0) {
    canvas.restore();
  }
}

void _drawCoolCrow(
  Canvas canvas,
  Offset center,
  double s, {
  Color bodyColor = const Color(0xff20231c),
  double tilt = 0,
}) {
  canvas.save();
  canvas.translate(center.dx, center.dy);
  if (tilt != 0) {
    canvas.rotate(tilt);
  }
  canvas.scale(s, s);

  final bodyFill = Paint()..color = bodyColor;
  final outline = Paint()
    ..color = _MatteMeadowArt.ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.4
    ..strokeJoin = StrokeJoin.round;

  canvas.drawOval(
    Rect.fromCenter(center: const Offset(-4, 24), width: 108, height: 14),
    Paint()..color = const Color(0x3a1b1e14),
  );

  final leg = Paint()
    ..color = const Color(0xff6b7068)
    ..strokeWidth = 4.2
    ..strokeCap = StrokeCap.round;
  canvas.drawLine(const Offset(-28, 10), const Offset(-54, 18), leg);
  canvas.drawLine(const Offset(-20, 14), const Offset(-46, 23), leg);
  canvas.drawLine(const Offset(-54, 18), const Offset(-62, 14), leg);
  canvas.drawLine(const Offset(-54, 18), const Offset(-63, 21), leg);

  final body = Path()
    ..moveTo(-36, 10)
    ..quadraticBezierTo(-18, -14, 16, -16)
    ..quadraticBezierTo(44, -18, 48, 0)
    ..quadraticBezierTo(44, 18, 12, 21)
    ..quadraticBezierTo(-24, 24, -36, 10)
    ..close();
  canvas.drawPath(body, bodyFill);
  canvas.drawPath(body, outline);

  canvas.drawCircle(const Offset(26, -18), 16, bodyFill);
  canvas.drawCircle(const Offset(26, -18), 16, outline);
  final tuft = Path()
    ..moveTo(26, -33)
    ..lineTo(31, -41)
    ..lineTo(33, -32)
    ..lineTo(39, -38)
    ..lineTo(37, -28);
  canvas.drawPath(tuft, bodyFill);

  final beak = Path()
    ..moveTo(14, -20)
    ..lineTo(-2, -16)
    ..lineTo(14, -10)
    ..close();
  canvas.drawPath(beak, Paint()..color = const Color(0xff7f8580));
  canvas.drawPath(beak, outline);

  final glassPaint = Paint()..color = const Color(0xff11130e);
  final lens1 = RRect.fromRectAndRadius(
    const Rect.fromLTWH(10, -28, 12, 9),
    const Radius.circular(2.5),
  );
  final lens2 = RRect.fromRectAndRadius(
    const Rect.fromLTWH(23, -27, 13, 9),
    const Radius.circular(2.5),
  );
  canvas.drawRRect(lens1, glassPaint);
  canvas.drawRRect(lens2, glassPaint);
  canvas.drawLine(
    const Offset(36, -23),
    const Offset(42, -20),
    Paint()
      ..color = _MatteMeadowArt.ink
      ..strokeWidth = 2.0,
  );
  final shine = Paint()
    ..color = _MatteMeadowArt.cream
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round;
  canvas.drawLine(const Offset(13, -26), const Offset(16, -21), shine);
  canvas.drawLine(const Offset(27, -25), const Offset(30, -20), shine);

  canvas.restore();
}

ThemeData mattePaperTheme() {
  const ink = Color(0xff1b1e14),
      cream = Color(0xfff7f3dd),
      olive = Color(0xff4e5c1f),
      gold = Color(0xffe5b93c);
  final scheme = ColorScheme.fromSeed(seedColor: olive).copyWith(
    primary: olive,
    onPrimary: cream,
    primaryContainer: const Color(0xffdbe4a0),
    onPrimaryContainer: ink,
    secondary: gold,
    onSecondary: ink,
    secondaryContainer: const Color(0xfff0dda1),
    onSecondaryContainer: ink,
    tertiary: const Color(0xff69753b),
    onTertiary: cream,
    tertiaryContainer: const Color(0xffd7dec1),
    onTertiaryContainer: ink,
    surface: cream,
    onSurface: ink,
    onSurfaceVariant: const Color(0xff4b503a),
    surfaceContainerLow: const Color(0xffede9c9),
    surfaceContainer: const Color(0xffede9c9),
    surfaceContainerHighest: const Color(0xffe6e6c7),
    inverseSurface: cream,
    onInverseSurface: ink,
    outline: ink,
  );
  const border = BorderSide(color: ink, width: 2.0);
  final pillShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(18),
    side: border,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: Colors.transparent,
    // The paper art lives behind Navigator. Android's default route fade
    // otherwise paints ColorScheme.surface (cream) across it during a push/pop.
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        ...const PageTransitionsTheme().builders,
        TargetPlatform.android: const PredictiveBackPageTransitionsBuilder(
          fallbackColor: Colors.transparent,
        ),
        TargetPlatform.linux: const FadeForwardsPageTransitionsBuilder(
          backgroundColor: Colors.transparent,
        ),
        TargetPlatform.windows: const FadeForwardsPageTransitionsBuilder(
          backgroundColor: Colors.transparent,
        ),
      },
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: ink,
      actionsIconTheme: IconThemeData(color: cream),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: cream,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: ink, width: 1.8),
      ),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: cream,
      elevation: 3,
      shadowColor: ink,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: border,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: cream,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shadowColor: ink,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: ink, width: 2.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: gold,
        foregroundColor: ink,
        disabledBackgroundColor: const Color(0xffd7cf9e),
        disabledForegroundColor: const Color(0xff6b6e56),
        elevation: 2,
        shadowColor: ink,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: pillShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: cream,
        foregroundColor: ink,
        side: border,
        elevation: 2,
        shadowColor: ink,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: pillShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: cream,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: border,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: border,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: ink, width: 2.5),
      ),
    ),
    bannerTheme: const MaterialBannerThemeData(
      backgroundColor: cream,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: cream,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: border,
      ),
      behavior: SnackBarBehavior.floating,
    ),
    dividerColor: const Color(0xff7f8a36),
  );
}
