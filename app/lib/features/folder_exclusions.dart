import 'package:material_ui/material_ui.dart';

/// Lazy, exact-path exclusions, shared by local copy/move and network pulls.
class FolderExclusions extends StatefulWidget {
  const FolderExclusions({
    super.key,
    required this.load,
    this.initial = const [],
  });
  final Future<List<Map<String, dynamic>>> Function(String relative) load;
  final List<String> initial;
  @override
  State<FolderExclusions> createState() => _FolderExclusionsState();
}

class _FolderExclusionsState extends State<FolderExclusions> {
  late Set<String> excluded;
  String path = '';
  List<Map<String, dynamic>> entries = [];
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    excluded = widget.initial.toSet();
    load();
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final list = await widget.load(path);
      if (mounted) {
        setState(() => entries = list);
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
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Exclude from this transfer'),
    content: SizedBox(
      width: 500,
      height: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Checked items stay on the source. Excluding a folder excludes everything inside it.',
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (path.isNotEmpty)
                IconButton(
                  tooltip: 'Parent folder',
                  onPressed: () {
                    setState(
                      () => path = path.contains('/')
                          ? path.substring(0, path.lastIndexOf('/'))
                          : '',
                    );
                    load();
                  },
                  icon: const Icon(Icons.arrow_upward),
                ),
              Expanded(
                child: Text(
                  path.isEmpty ? 'Selected folder' : path,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${excluded.length} excluded'),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null) Text(error!),
          Expanded(
            child: ListView(
              children: [
                for (final entry in entries)
                  Builder(
                    builder: (context) {
                      final relative = path.isEmpty
                          ? '${entry['name']}'
                          : '$path/${entry['name']}';
                      final inherited = excluded.any(
                        (e) => relative.startsWith('$e/'),
                      );
                      return CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '${entry['name']}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          entry['kind'] == 'directory'
                              ? 'Folder and its contents'
                              : '${entry['size']} bytes',
                        ),
                        value: inherited || excluded.contains(relative),
                        onChanged: inherited
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  excluded.removeWhere(
                                    (e) => e.startsWith('$relative/'),
                                  );
                                  excluded.add(relative);
                                } else {
                                  excluded.remove(relative);
                                }
                              }),
                        secondary: entry['kind'] == 'directory'
                            ? IconButton(
                                tooltip: 'Browse ${entry['name']}',
                                onPressed: () {
                                  setState(() => path = relative);
                                  load();
                                },
                                icon: const Icon(Icons.folder_open_outlined),
                              )
                            : const Icon(Icons.insert_drive_file_outlined),
                      );
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, excluded.toList()..sort()),
        child: const Text('Apply exclusions'),
      ),
    ],
  );
}
