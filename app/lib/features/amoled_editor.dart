import 'package:material_ui/material_ui.dart';

import 'appearance.dart';

class AmoledThemeEditor extends StatefulWidget {
  const AmoledThemeEditor({
    super.key,
    required this.initialConfig,
    required this.onSave,
  });

  final AmoledStyleConfig initialConfig;
  final Future<void> Function(AmoledStyleConfig config) onSave;

  @override
  State<AmoledThemeEditor> createState() => _AmoledThemeEditorState();
}

class _AmoledThemeEditorState extends State<AmoledThemeEditor> {
  static const _swatches = <Color>[
    Color(0xff1cff68), // Neon green
    Color(0xff00b848), // Deep green
    Color(0xffff1738), // Neon red
    Color(0xffcc0022), // Deep crimson
    Color(0xff00e5ff), // Cyber cyan
    Color(0xff2979ff), // Electric blue
    Color(0xffd500f9), // Neon purple
    Color(0xffffd600), // Solar gold
    Color(0xffff6d00), // Neon orange
    Color(0xffffffff), // Pure white
    Color(0xff000000), // Pure black
  ];

  late AmoledStyleConfig config;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    config = widget.initialConfig;
  }

  Future<void> _applyAndClose() async {
    if (saving) return;
    setState(() => saving = true);
    await widget.onSave(config);
    if (mounted) {
      Navigator.pop(context, true);
    }
  }

  void _applyPreset({
    required int edge,
    required int peak,
    required int tab,
    required int button,
    required int border,
  }) {
    setState(() {
      config = config.copyWith(
        edgeColor: edge,
        peakColor: peak,
        selectedTabColor: tab,
        buttonColor: button,
        popupBorderColor: border,
      );
    });
  }

  Widget _swatchRow({
    required String label,
    required int selectedArgb,
    required ValueChanged<int> onPick,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              for (final c in _swatches)
                GestureDetector(
                  onTap: saving ? null : () => onPick(c.toARGB32()),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selectedArgb == c.toARGB32()
                            ? Colors.white
                            : Colors.white24,
                        width: selectedArgb == c.toARGB32() ? 2.6 : 1.0,
                      ),
                      boxShadow: selectedArgb == c.toARGB32()
                          ? [
                              BoxShadow(
                                color: c.withValues(alpha: 0.65),
                                blurRadius: 8,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final liveTheme = amoledTheme('amoled', config: config);
    return Theme(
      data: liveTheme,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text('AMOLED editor'),
          actions: [
            TextButton(
              onPressed: saving
                  ? null
                  : () => setState(() => config = AmoledStyleConfig.defaults()),
              child: const Text('Use defaults'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: saving ? null : _applyAndClose,
              child: Text(saving ? 'Applying…' : 'Activate'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: AppearanceSurface(
          appearance: 'amoled',
          amoledConfig: config,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xff080808),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Color(config.popupBorderColor).withValues(alpha: 0.8),
                    width: 1.4,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Live AMOLED preview (popup border & controls)',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        amoledNavIcon(
                          context,
                          Icons.devices,
                          'amoled',
                          config: config,
                        ),
                        FilledButton(
                          onPressed: () {},
                          child: const Text('Primary action'),
                        ),
                        OutlinedButton(
                          onPressed: () {},
                          child: const Text('Outline'),
                        ),
                        ChoiceChip(
                          label: const Text('Selected item'),
                          selected: true,
                          onSelected: (_) {},
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Quick neon presets',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: () => _applyPreset(
                      edge: 0xff00b848,
                      peak: 0xff1cff68,
                      tab: 0xff1cff68,
                      button: 0xff1cff68,
                      border: 0xff1cff68,
                    ),
                    child: const Text('Neon green'),
                  ),
                  OutlinedButton(
                    onPressed: () => _applyPreset(
                      edge: 0xffcc0022,
                      peak: 0xffff1738,
                      tab: 0xffff1738,
                      button: 0xffff1738,
                      border: 0xffff1738,
                    ),
                    child: const Text('Neon red'),
                  ),
                  OutlinedButton(
                    onPressed: () => _applyPreset(
                      edge: 0xff00838f,
                      peak: 0xff00e5ff,
                      tab: 0xff00e5ff,
                      button: 0xff00e5ff,
                      border: 0xff00e5ff,
                    ),
                    child: const Text('Cyber cyan'),
                  ),
                  OutlinedButton(
                    onPressed: () => _applyPreset(
                      edge: 0xff7b1fa2,
                      peak: 0xffd500f9,
                      tab: 0xffd500f9,
                      button: 0xffd500f9,
                      border: 0xffd500f9,
                    ),
                    child: const Text('Electric violet'),
                  ),
                  OutlinedButton(
                    onPressed: () => _applyPreset(
                      edge: 0xffcc5200,
                      peak: 0xffffd600,
                      tab: 0xffffd600,
                      button: 0xffff6d00,
                      border: 0xffffd600,
                    ),
                    child: const Text('Solar amber'),
                  ),
                  OutlinedButton(
                    onPressed: () => setState(
                      () => config = config.copyWith(
                        edgeColor: 0xffffffff,
                        peakColor: 0xffffffff,
                        selectedTabColor: 0xffffffff,
                        buttonColor: 0xffffffff,
                        popupBorderColor: 0xffffffff,
                        selectedTextColor: 0xff000000,
                      ),
                    ),
                    child: const Text('Monochrome white'),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _swatchRow(
                label: 'Side neon edge color',
                selectedArgb: config.edgeColor,
                onPick: (c) => setState(() => config = config.copyWith(edgeColor: c)),
              ),
              _swatchRow(
                label: 'Side neon peak & center color',
                selectedArgb: config.peakColor,
                onPick: (c) => setState(() => config = config.copyWith(peakColor: c)),
              ),
              Text(
                'Side neon line thickness: ${config.lineWidth.toStringAsFixed(1)} px',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Slider(
                value: config.lineWidth,
                min: 1.0,
                max: 6.0,
                divisions: 20,
                onChanged: saving
                    ? null
                    : (v) => setState(() => config = config.copyWith(lineWidth: v)),
              ),
              Text(
                'Luminous center glow: ${(config.centerGlow * 100).round()}%',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Slider(
                value: config.centerGlow,
                min: 0.0,
                max: 1.0,
                divisions: 20,
                onChanged: saving
                    ? null
                    : (v) => setState(() => config = config.copyWith(centerGlow: v)),
              ),
              const SizedBox(height: 8),
              _swatchRow(
                label: 'Selected tab pill color',
                selectedArgb: config.selectedTabColor,
                onPick: (c) =>
                    setState(() => config = config.copyWith(selectedTabColor: c)),
              ),
              _swatchRow(
                label: 'Button color',
                selectedArgb: config.buttonColor,
                onPick: (c) =>
                    setState(() => config = config.copyWith(buttonColor: c)),
              ),
              _swatchRow(
                label: 'Popup & dialog border color',
                selectedArgb: config.popupBorderColor,
                onPick: (c) =>
                    setState(() => config = config.copyWith(popupBorderColor: c)),
              ),
              _swatchRow(
                label: 'Selected text color (on white/selected background)',
                selectedArgb: config.selectedTextColor,
                onPick: (c) =>
                    setState(() => config = config.copyWith(selectedTextColor: c)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
