import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'appearance.dart';

class MatteThemeEditor extends StatefulWidget {
  const MatteThemeEditor({
    super.key,
    required this.initialItems,
    required this.onSave,
  });

  final List<MatteArtItem> initialItems;
  final Future<void> Function(List<MatteArtItem> items) onSave;

  @override
  State<MatteThemeEditor> createState() => _MatteThemeEditorState();
}

class _MatteThemeEditorState extends State<MatteThemeEditor> {
  static const _palette = [
    Color(0xfff7f3dd),
    Color(0xffe5b93c),
    Color(0xffd96b43),
    Color(0xffd47922),
    Color(0xff5c7e22),
    Color(0xff7da5b8),
    Color(0xff20231c),
    Color(0xff6e4555),
  ];

  late List<MatteArtItem> items;
  int? selected;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    items = List<MatteArtItem>.from(widget.initialItems);
    if (items.isNotEmpty) {
      selected = 0;
    }
  }

  void _updateSelected(MatteArtItem Function(MatteArtItem item) transform) {
    final index = selected;
    if (index == null || index < 0 || index >= items.length) {
      return;
    }
    setState(() => items[index] = transform(items[index]));
  }

  void _addItem(String kind) {
    final next = MatteArtItem(
      kind: kind,
      x: 0.5,
      y: 0.45,
      scale: kind == 'bird' ? 1.0 : 0.9,
      tilt: 0,
      color: kind == 'bird' ? 0xff20231c : 0xfff7f3dd,
      foreground: false,
    );
    setState(() {
      items.add(next);
      selected = items.length - 1;
    });
  }

  void _pickAt(Offset local, Size size) {
    int? hit;
    var best = double.infinity;
    for (var i = items.length - 1; i >= 0; i--) {
      final item = items[i];
      final pos = Offset(size.width * item.x, size.height * item.y);
      final dist = (local - pos).distance;
      final radius = (item.kind == 'bird' ? 56.0 : 40.0) * item.scale;
      if (dist <= math.max(36.0, radius) && dist < best) {
        best = dist;
        hit = i;
      }
    }
    if (hit != null) {
      setState(() => selected = hit);
    }
  }

  Future<void> _saveAndClose() async {
    setState(() => saving = true);
    await widget.onSave(List<MatteArtItem>.from(items));
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = selected != null && selected! < items.length
        ? items[selected!]
        : null;
    return Scaffold(
      backgroundColor: const Color(0xffa3ad4c),
      appBar: AppBar(
        backgroundColor: const Color(0xffa3ad4c),
        title: const Text('Matte editor'),
        actions: [
          IconButton(
            tooltip: 'Add flower',
            onPressed: saving ? null : () => _addItem('flower'),
            icon: const Icon(Icons.local_florist_outlined),
          ),
          IconButton(
            tooltip: 'Add bird',
            onPressed: saving ? null : () => _addItem('bird'),
            icon: const Icon(Icons.flutter_dash_outlined),
          ),
          IconButton(
            tooltip: 'Export preset',
            onPressed: saving
                ? null
                : () {
                    final encoded = encodeMatteItems(items);
                    showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Matte preset'),
                        content: SizedBox(
                          width: 420,
                          child: SingleChildScrollView(
                            child: SelectableText(encoded),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: encoded));
                              Navigator.pop(ctx);
                            },
                            child: const Text('Copy'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    );
                  },
            icon: const Icon(Icons.code),
          ),
          IconButton(
            tooltip: 'Reset default art',
            onPressed: saving
                ? null
                : () => setState(() {
                    items = defaultMatteItems();
                    selected = items.isEmpty ? null : 0;
                  }),
            icon: const Icon(Icons.restart_alt),
          ),
          FilledButton(
            onPressed: saving ? null : _saveAndClose,
            child: const Text('Done'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _pickAt(d.localPosition, size),
                  onPanStart: (d) => _pickAt(d.localPosition, size),
                  onPanUpdate: (d) {
                    final index = selected;
                    if (index == null || index >= items.length) {
                      return;
                    }
                    final nx = (d.localPosition.dx / size.width).clamp(
                      0.02,
                      0.98,
                    );
                    final ny = (d.localPosition.dy / size.height).clamp(
                      0.02,
                      0.98,
                    );
                    setState(() {
                      items[index] = items[index].copyWith(x: nx, y: ny);
                    });
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: Color(0xffa3ad4c)),
                      CustomPaint(
                        painter: _EditorLayerPainter(
                          items: items,
                          foreground: false,
                          selectedIndex: selected,
                        ),
                      ),
                      IgnorePointer(
                        child: Column(
                          children: [
                            const SizedBox(height: 18),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                              ),
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: Row(
                                    children: const [
                                      Icon(Icons.drag_indicator),
                                      SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          'Drag birds & flowers. Background sits behind cards; Foreground draws above them.',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      CustomPaint(
                        painter: _EditorLayerPainter(
                          items: items,
                          foreground: true,
                          selectedIndex: selected,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (current != null)
            Card(
              margin: const EdgeInsets.all(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          current.kind == 'bird' ? 'Bird' : 'Flower',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(width: 12),
                        ChoiceChip(
                          label: const Text('Behind text'),
                          selected: !current.foreground,
                          onSelected: (_) => _updateSelected(
                            (it) => it.copyWith(foreground: false),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: const Text('Foreground'),
                          selected: current.foreground,
                          onSelected: (_) => _updateSelected(
                            (it) => it.copyWith(foreground: true),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: 'Remove selected',
                          onPressed: () {
                            final idx = selected!;
                            setState(() {
                              items.removeAt(idx);
                              selected = items.isEmpty
                                  ? null
                                  : math.min(idx, items.length - 1);
                            });
                          },
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final swatch in _palette)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(16),
                                onTap: () => _updateSelected(
                                  (it) => it.copyWith(color: swatch.toARGB32()),
                                ),
                                child: Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: swatch,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: current.color == swatch.toARGB32()
                                          ? const Color(0xff1b1e14)
                                          : const Color(0x551b1e14),
                                      width: current.color == swatch.toARGB32()
                                          ? 3
                                          : 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 44, child: Text('Size')),
                        Expanded(
                          child: Slider(
                            min: 0.4,
                            max: 2.2,
                            value: current.scale.clamp(0.4, 2.2),
                            onChanged: (v) => _updateSelected(
                              (it) => it.copyWith(scale: v),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 42,
                          child: Text('${current.scale.toStringAsFixed(1)}x'),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 44, child: Text('Tilt')),
                        Expanded(
                          child: Slider(
                            min: -math.pi,
                            max: math.pi,
                            value: current.tilt.clamp(-math.pi, math.pi),
                            onChanged: (v) => _updateSelected(
                              (it) => it.copyWith(tilt: v),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 42,
                          child: Text(
                            '${(current.tilt * 180 / math.pi).round()}°',
                          ),
                        ),
                      ],
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

class _EditorLayerPainter extends CustomPainter {
  const _EditorLayerPainter({
    required this.items,
    required this.foreground,
    required this.selectedIndex,
  });

  final List<MatteArtItem> items;
  final bool foreground;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.foreground != foreground) {
        continue;
      }
      drawMatteItem(canvas, size, item);
      if (i == selectedIndex) {
        final center = Offset(size.width * item.x, size.height * item.y);
        final radius = (item.kind == 'bird' ? 48.0 : 32.0) * item.scale;
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = const Color(0xff1b1e14)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _EditorLayerPainter oldDelegate) => true;
}
