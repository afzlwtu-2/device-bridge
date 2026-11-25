import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'ssh_bootstrap.dart';

class TermuxTools extends StatefulWidget {
  const TermuxTools({super.key, required this.core});
  final CoreBridge core;
  @override
  State<TermuxTools> createState() => _TermuxToolsState();
}

class _TermuxToolsState extends State<TermuxTools> {
  Map<String, dynamic> status = {};
  final program = TextEditingController(text: 'pwd');
  final arguments = <TextEditingController>[];
  bool busy = false;
  String? error, output;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    program.dispose();
    for (final controller in arguments) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> load() async {
    try {
      final result = await widget.core.localFiles('termux-status', {}) as Map;
      if (mounted) {
        setState(() => status = Map<String, dynamic>.from(result));
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    }
  }

  Future<void> permission() async {
    try {
      await widget.core.localFiles('termux-permission', {});
      await load();
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    }
  }

  Future<void> run() async {
    final name = program.text.trim();
    final argv = arguments.map((c) => c.text).toList();
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Run in Termux?'),
        content: SelectableText(
          '$name\n${argv.map((a) => '• $a').join('\n')}\n\nRuns locally as Termux in /data/data/com.termux/files/home. The command can change files your Termux user can access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Run'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
      output = null;
    });
    try {
      final result = await widget.core.localFiles('termux-run', {
        'program': name,
        'arguments': argv,
      }) as Map;
      if (mounted) {
        setState(
          () => output =
              'Exit ${result['exit_code']}\n${result['stdout'] ?? ''}${result['stderr'] ?? ''}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
      }
    }
    if (mounted) {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Termux tools')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'This phone · Termux',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const SelectableText(
                        'Home: /data/data/com.termux/files/home',
                      ),
                      const SizedBox(height: 12),
                      Text(
                        status['permission'] == true
                            ? 'Command permission granted'
                            : 'Command permission required',
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed: busy ? null : permission,
                            icon: const Icon(Icons.key_outlined),
                            label: const Text('Grant Termux permission'),
                          ),
                          OutlinedButton(
                            onPressed: () =>
                                widget.core.openConnectionSetup('termux'),
                            child: const Text('Open Termux'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'One-time Termux setup: enable allow-external-apps=true in ~/.termux/termux.properties, then run termux-reload-settings while Termux is open. Existing sessions are preserved.',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (status['installed'] == true)
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('Set up Termux folder sync'),
                  subtitle: const Text(
                    'Connect to Termux SSH to install the companion and its Syncthing engine. Then choose the paired Termux device in Files.',
                  ),
                  onTap: busy
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) => SshBootstrapDialog(
                            core: widget.core,
                            initialHost:
                                (widget.core.network?['cidr'] as String?)
                                    ?.split('/')
                                    .first,
                            initialPort: 8022,
                            termuxCompanion: true,
                          ),
                        ),
                ),
              const SizedBox(height: 20),
              TextField(
                controller: program,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Installed tool',
                  hintText: 'pwd, git, go, rsync, xxhsum…',
                ),
              ),
              for (var i = 0; i < arguments.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextField(
                    controller: arguments[i],
                    enabled: !busy,
                    decoration: InputDecoration(labelText: 'Argument ${i + 1}'),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => setState(
                          () => arguments.add(TextEditingController()),
                        ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add argument'),
                ),
              ),
              FilledButton.icon(
                onPressed: busy || status['permission'] != true ? null : run,
                icon: const Icon(Icons.play_arrow_outlined),
                label: const Text('Review & run'),
              ),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: SelectableText(error!),
                ),
              if (output != null)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: SelectableText(output!),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
