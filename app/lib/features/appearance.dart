import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

bool isAmoledTheme(String appearance) =>
    appearance == 'amoled' ||
    appearance == 'amoled-green' ||
    appearance == 'amoled-red';

/// Static decoration: no animation controller, timer, image asset or wake lock.
class AppearanceSurface extends StatelessWidget {
  const AppearanceSurface({
    super.key,
    required this.appearance,
    required this.child,
  });
  final String appearance;
  final Widget child;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      if (appearance == 'matte')
        const ColoredBox(
          color: Color(0xffb5be68),
          child: CustomPaint(painter: _MattePaperArt()),
        ),
      child,
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

/// Unobstructed illustrated meadow footer for the matte paper theme.
class MatteMeadowFooter extends StatelessWidget {
  const MatteMeadowFooter({super.key});
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(top: 16),
    child: SizedBox(
      height: 112,
      width: double.infinity,
      child: CustomPaint(painter: _MatteMeadowPainter()),
    ),
  );
}

/// Olive matte-paper textured container with subtle corner sprouts for the bottom bar.
class MatteNavBarSurface extends StatelessWidget {
  const MatteNavBarSurface({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _MatteNavBarPainter(),
    child: child,
  );
}

class _MatteNavBarPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xff929e3a));
    // Subtle paper grain.
    final grain = Paint()
      ..color = const Color(0x141b1e14)
      ..strokeWidth = 0.7;
    var value = 192837;
    for (var i = 0; i < 360; i++) {
      value = (value * 48271) % 2147483647;
      final x = value / 2147483647 * size.width;
      value = (value * 48271) % 2147483647;
      final y = value / 2147483647 * size.height;
      canvas.drawLine(Offset(x, y), Offset(x + 0.8, y + 0.15), grain);
    }
    // Delicate ink grass blades & tiny dots tucked into the bottom edges.
    final ink = Paint()
      ..color = const Color(0xff1b1e14)
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round;
    for (final bx in [18.0, size.width - 18.0]) {
      final by = size.height - 8;
      canvas.drawLine(Offset(bx, by), Offset(bx - 5, by - 7), ink);
      canvas.drawLine(Offset(bx, by), Offset(bx, by - 9), ink);
      canvas.drawLine(Offset(bx, by), Offset(bx + 5, by - 7), ink);
    }
    canvas.drawCircle(
      Offset(34, size.height - 12),
      2.6,
      Paint()..color = const Color(0xffe5b93c),
    );
    canvas.drawCircle(
      Offset(size.width - 34, size.height - 12),
      2.6,
      Paint()..color = const Color(0xfff7f3dd),
    );
    // Crisp top ink border matching AppBar.
    canvas.drawLine(
      Offset.zero,
      Offset(size.width, 0),
      Paint()
        ..color = const Color(0xff1b1e14)
        ..strokeWidth = 2.0,
    );
  }

  @override
  bool shouldRepaint(covariant _MatteNavBarPainter oldDelegate) => false;
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

ThemeData amoledTheme(String appearance) {
  final isRed = appearance == 'amoled-red';
  final accent = isRed ? const Color(0xffff3b5c) : const Color(0xff1be86c);
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: accent,
    onPrimary: Colors.black,
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
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Colors.black,
      surfaceTintColor: Colors.transparent,
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
  const _MattePaperArt();

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
      Rect.fromLTWH(-40, size.height * 0.72, size.width + 80, size.height * 0.35),
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

    // Playful comic ink rays in the upper-right open margin away from titles.
    _drawComicRays(canvas, Offset(size.width * 0.89, size.height * 0.14), 0.35);
  }

  @override
  bool shouldRepaint(covariant _MattePaperArt oldDelegate) => false;
}

class _MatteMeadowPainter extends CustomPainter {
  const _MatteMeadowPainter();

  static const _ink = Color(0xff1b1e14);
  static const _cream = Color(0xfff7f3dd);
  static const _gold = Color(0xffe5b93c);
  static const _leaf = Color(0xff5c7e22);

  @override
  void paint(Canvas canvas, Size size) {
    final groundY = size.height - 16;
    _drawGrassTuft(canvas, Offset(size.width * 0.23, groundY - 12), 1.0);
    _drawGrassTuft(canvas, Offset(size.width * 0.39, groundY - 26), 0.85);
    _drawGrassTuft(canvas, Offset(size.width * 0.75, groundY - 16), 0.9);
    _drawDots(canvas, Offset(size.width * 0.15, groundY - 4));
    _drawDots(canvas, Offset(size.width * 0.84, groundY - 2));

    _drawFlower(canvas, Offset(size.width * 0.08, groundY - 40), _cream, 1.0);
    _drawFlower(canvas, Offset(size.width * 0.17, groundY - 18), _gold, 0.82);
    _drawFlower(canvas, Offset(size.width * 0.80, groundY - 22), _cream, 0.88);
    _drawFlower(canvas, Offset(size.width * 0.91, groundY - 38), _gold, 1.02);

    _drawComicRays(canvas, Offset(size.width * 0.67, groundY - 58), 0.45);
    _drawCoolCrow(canvas, Offset(size.width * 0.53, groundY - 22), 0.76);
  }

  void _drawGrassTuft(Canvas canvas, Offset base, double scale) {
    final p = Paint()
      ..color = _ink
      ..strokeWidth = 2.0 * scale
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(base, base + Offset(-7 * scale, -8 * scale), p);
    canvas.drawLine(base, base + Offset(0, -11 * scale), p);
    canvas.drawLine(base, base + Offset(7 * scale, -8 * scale), p);
  }

  void _drawDots(Canvas canvas, Offset at) {
    final p = Paint()..color = _ink;
    canvas.drawOval(Rect.fromCenter(center: at, width: 3.5, height: 5), p);
    canvas.drawOval(
      Rect.fromCenter(center: at + const Offset(6, 0.5), width: 3.5, height: 5),
      p,
    );
  }

  void _drawFlower(Canvas canvas, Offset center, Color petalColor, double s) {
    final outline = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9 * s
      ..strokeJoin = StrokeJoin.round;
    final stemBottom = center + Offset(0, 34 * s);

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
        ..color = _ink
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
      canvas.drawPath(leaf, Paint()..color = _leaf);
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

    final centerColor = petalColor == _gold ? const Color(0xffd47922) : _gold;
    canvas.drawCircle(center, 4.6 * s, Paint()..color = centerColor);
    canvas.drawCircle(center, 4.6 * s, outline);
  }

  void _drawCoolCrow(Canvas canvas, Offset center, double s) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(s, s);

    final bodyFill = Paint()..color = const Color(0xff20231c);
    final outline = Paint()
      ..color = _ink
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
        ..color = _ink
        ..strokeWidth = 2.0,
    );
    final shine = Paint()
      ..color = _cream
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(13, -26), const Offset(16, -21), shine);
    canvas.drawLine(const Offset(27, -25), const Offset(30, -20), shine);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MatteMeadowPainter oldDelegate) => false;
}

void _drawComicRays(Canvas canvas, Offset origin, double tilt) {
  final p = Paint()
    ..color = const Color(0xff1b1e14)
    ..strokeWidth = 3.2
    ..strokeCap = StrokeCap.round;
  canvas.save();
  canvas.translate(origin.dx, origin.dy);
  canvas.rotate(tilt);
  canvas.drawLine(const Offset(-14, -10), const Offset(-26, -22), p);
  canvas.drawLine(const Offset(-2, -16), const Offset(-4, -32), p);
  canvas.drawLine(const Offset(10, -10), const Offset(20, -22), p);
  canvas.restore();
}

ThemeData mattePaperTheme() {
  const ink = Color(0xff1b1e14),
      cream = Color(0xfff7f3dd),
      olive = Color(0xff4e5c1f),
      oliveBar = Color(0xff929e3a),
      gold = Color(0xffe5b93c);
  final scheme = ColorScheme.fromSeed(seedColor: olive).copyWith(
    primary: olive,
    onPrimary: cream,
    secondary: gold,
    onSecondary: ink,
    surface: cream,
    onSurface: ink,
    surfaceContainerLow: const Color(0xffede9c9),
    surfaceContainer: const Color(0xffede9c9),
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
    appBarTheme: const AppBarTheme(
      backgroundColor: oliveBar,
      foregroundColor: ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: Border(bottom: BorderSide(color: ink, width: 2.0)),
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
