import 'package:material_ui/material_ui.dart';

enum TrafficLightLevel { green, amber, red, off }

Color trafficLightColor(BuildContext context, TrafficLightLevel level) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  return switch (level) {
    TrafficLightLevel.green =>
      isDark ? const Color(0xff34d399) : const Color(0xff15803d),
    TrafficLightLevel.amber =>
      isDark ? const Color(0xfffbbf24) : const Color(0xffb45309),
    TrafficLightLevel.red =>
      isDark ? const Color(0xfff87171) : const Color(0xffb91c1c),
    TrafficLightLevel.off => Theme.of(context).colorScheme.outline,
  };
}

class TrafficLightDot extends StatelessWidget {
  const TrafficLightDot({
    super.key,
    required this.level,
    this.size = 10,
  });

  final TrafficLightLevel level;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = trafficLightColor(context, level);
    final glowing = level != TrafficLightLevel.off;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: glowing
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.45),
                  blurRadius: size * 0.7,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
    );
  }
}

class TrafficLightPill extends StatelessWidget {
  const TrafficLightPill({
    super.key,
    required this.level,
    required this.label,
    this.compact = false,
  });

  final TrafficLightLevel level;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = trafficLightColor(context, level);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          color.withValues(alpha: level == TrafficLightLevel.off ? 0.08 : 0.14),
          scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        ),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: color.withValues(alpha: level == TrafficLightLevel.off ? 0.35 : 0.55),
          width: 0.9,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TrafficLightDot(level: level, size: compact ? 7 : 8),
          SizedBox(width: compact ? 5 : 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: level == TrafficLightLevel.off
                  ? scheme.onSurfaceVariant
                  : color,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

String formatBytesCompact(num bytes) {
  final b = bytes.toDouble();
  if (b <= 0) return '0 B';
  if (b < 1024) return '${b.toInt()} B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KiB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(2)} MiB';
  }
  return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}

String formatRateCompact(double bytesPerSec) {
  if (bytesPerSec <= 1) return '0 B/s';
  if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
  if (bytesPerSec < 1024 * 1024) {
    return '${(bytesPerSec / 1024).toStringAsFixed(1)} KiB/s';
  }
  return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(2)} MiB/s';
}
