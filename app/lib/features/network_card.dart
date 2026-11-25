import 'package:material_ui/material_ui.dart';

import 'traffic_light.dart';

enum NetworkLayer {
  services('Connections', '', 'Agent and SSH services'),
  transports('Transports', '', 'Direct TCP and tunnels'),
  links('Links', '', 'Radios, cables and network interfaces');

  const NetworkLayer(this.label, this.layer, this.description);
  final String label;
  final String layer;
  final String description;

  String get heading => label;
}

class NetworkCard extends StatelessWidget {
  const NetworkCard({
    super.key,
    required this.icon,
    required this.title,
    this.detail,
    this.status,
    this.level = TrafficLightLevel.off,
    this.headingAction,
    this.extra,
    this.actions = const [],
  });

  final IconData icon;
  final String title;
  final String? detail;
  final String? status;
  final TrafficLightLevel level;
  final Widget? headingAction;
  final Widget? extra;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                if (status case final status?) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TrafficLightPill(
                        level: level,
                        label: status,
                        compact: true,
                      ),
                    ),
                  ),
                ],
                ?headingAction,
              ],
            ),
            if (detail case final detail?) ...[
              const SizedBox(height: 6),
              Text(detail, style: theme.textTheme.bodyMedium),
            ],
            ?extra,
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: actions),
            ],
          ],
        ),
      ),
    );
  }
}
