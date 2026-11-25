import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/debug_trace.dart';

/// Displays captured runtime errors, screen transitions, and transport/link flows
/// recorded while Global `debug_mode` is enabled.
class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    DebugTrace.instance.addListener(_onUpdate);
  }

  @override
  void dispose() {
    DebugTrace.instance.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final all = DebugTrace.instance.entries;
    final filtered = _filter == 'all'
        ? all
        : all.where((e) => e.kind == _filter).toList();
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug & Flow Tracker'),
        actions: [
          IconButton(
            tooltip: 'Copy log',
            onPressed: all.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(
                      ClipboardData(text: DebugTrace.exportText()),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Copied debug log to clipboard'),
                        ),
                      );
                    }
                  },
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Clear log',
            onPressed: all.isEmpty ? null : () => DebugTrace.clear(),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final item in [
                  ('all', 'All (${all.length})'),
                  (
                    'error',
                    'Errors (${all.where((e) => e.kind == 'error').length})',
                  ),
                  (
                    'flow',
                    'Flows (${all.where((e) => e.kind == 'flow').length})',
                  ),
                  (
                    'screen',
                    'Screens (${all.where((e) => e.kind == 'screen').length})',
                  ),
                  (
                    'core',
                    'Core (${all.where((e) => e.kind == 'core').length})',
                  ),
                ])
                  ChoiceChip(
                    label: Text(item.$2),
                    selected: _filter == item.$1,
                    onSelected: (_) => setState(() => _filter = item.$1),
                  ),
              ],
            ),
          ),
          if (!DebugTrace.enabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: MaterialBanner(
                content: const Text(
                  'Debug tracker is currently OFF. Turn on "Debug & flow tracker" in Settings to record new events.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Back'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: filtered.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No recorded events for this filter yet.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final e = filtered[i];
                      final ts = e.timestamp;
                      final hh = ts.hour.toString().padLeft(2, '0');
                      final mm = ts.minute.toString().padLeft(2, '0');
                      final ss = ts.second.toString().padLeft(2, '0');
                      final IconData icon;
                      final Color? tint;
                      switch (e.kind) {
                        case 'error':
                          icon = Icons.error_outline;
                          tint = cs.error;
                        case 'screen':
                          icon = Icons.layers_outlined;
                          tint = cs.secondary;
                        case 'core':
                          icon = Icons.terminal_outlined;
                          tint = cs.tertiary;
                        default:
                          icon = Icons.route_outlined;
                          tint = cs.primary;
                      }
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(icon, size: 18, color: tint),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '[${e.kind.toUpperCase()}] ${e.source}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: tint,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '$hh:$mm:$ss',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              SelectableText(
                                e.message,
                                style: const TextStyle(fontSize: 13),
                              ),
                              if (e.detail != null && e.detail!.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                SelectableText(
                                  e.detail!,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ],
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
}
