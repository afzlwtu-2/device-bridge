import 'package:material_ui/material_ui.dart';

/// Selection specification returned by [showTermuxBackupDialog].
class TermuxBackupSelection {
  const TermuxBackupSelection({
    required this.includePaths,
    required this.excludePatterns,
  });

  final List<String> includePaths;
  final List<String> excludePatterns;

  Map<String, dynamic> toSpec() => {
    'include_paths': includePaths,
    'exclude_patterns': excludePatterns,
  };
}

/// Interactive dialog allowing the user to pick Termux Home folders/files,
/// browse subfolders, and customize excluded generated directories while
/// keeping `.env*` files always protected.
Future<TermuxBackupSelection?> showTermuxBackupDialog(
  BuildContext context, {
  required Map<String, dynamic> initialListing,
  required Future<Map<String, dynamic>?> Function(String? subpath) loadFolder,
}) {
  return showDialog<TermuxBackupSelection>(
    context: context,
    builder: (context) => _TermuxBackupDialog(
      initialListing: initialListing,
      loadFolder: loadFolder,
    ),
  );
}

class _TermuxBackupDialog extends StatefulWidget {
  const _TermuxBackupDialog({
    required this.initialListing,
    required this.loadFolder,
  });

  final Map<String, dynamic> initialListing;
  final Future<Map<String, dynamic>?> Function(String? subpath) loadFolder;

  @override
  State<_TermuxBackupDialog> createState() => _TermuxBackupDialogState();
}

class _TermuxBackupDialogState extends State<_TermuxBackupDialog> {
  final TextEditingController _excludeController = TextEditingController();
  final Set<String> _selectedPaths = <String>{};
  final Map<String, List<Map<String, dynamic>>> _listings = {};
  late final List<String> _excludePatterns;
  List<Map<String, dynamic>> _entries = const [];
  String _currentPath = '';
  bool _loadingFolder = false;
  String? _loadError;
  bool _initializedRootSelection = false;

  @override
  void initState() {
    super.initState();
    final defaults =
        (widget.initialListing['default_excludes'] as List?)
            ?.whereType<String>()
            .toList() ??
        const [
          '.cache',
          'node_modules',
          '.node_modules',
          '.npm',
          'target',
          '__pycache__',
          '.venv',
          'build',
          'dist',
        ];
    _excludePatterns = List<String>.from(defaults);
    _applyListing(widget.initialListing, initializeSelection: true);
  }

  @override
  void dispose() {
    _excludeController.dispose();
    super.dispose();
  }

  void _applyListing(
    Map<String, dynamic> data, {
    bool initializeSelection = false,
  }) {
    final raw = (data['entries'] as List?) ?? const [];
    final entries = raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    if (initializeSelection && !_initializedRootSelection) {
      _initializedRootSelection = true;
      for (final entry in entries) {
        final path = entry['path'] as String? ?? '';
        final excludedByDefault = entry['excluded_by_default'] == true;
        final always = entry['always_included'] == true;
        if (path.isNotEmpty && (!excludedByDefault || always)) {
          _selectedPaths.add(path);
        }
      }
    }
    _listings[_currentPath] = entries;
    _entries = entries;
  }

  Future<void> _openFolder(String subpath) async {
    setState(() {
      _loadingFolder = true;
      _loadError = null;
    });
    try {
      final data = await widget.loadFolder(subpath.isEmpty ? null : subpath);
      if (!mounted) return;
      if (data == null) {
        setState(() {
          _loadingFolder = false;
          _loadError = 'Unable to read folder contents.';
        });
        return;
      }
      setState(() {
        _currentPath = subpath;
        _loadingFolder = false;
        _applyListing(data);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingFolder = false;
        _loadError = error.toString();
      });
    }
  }

  bool _isPathCovered(String path) {
    if (_selectedPaths.contains(path)) return true;
    var cursor = path;
    while (true) {
      final slash = cursor.lastIndexOf('/');
      if (slash <= 0) break;
      cursor = cursor.substring(0, slash);
      if (_selectedPaths.contains(cursor)) return true;
    }
    return false;
  }

  bool _hasSelectedDescendant(String path) {
    final prefix = '$path/';
    return _selectedPaths.any((p) => p.startsWith(prefix));
  }

  void _toggleEntry(Map<String, dynamic> entry, bool selected) {
    final path = entry['path'] as String? ?? '';
    if (path.isEmpty || entry['always_included'] == true) return;
    setState(() {
      final prefix = '$path/';
      // Unselecting a child under a selected ancestor expands sibling entries at the ancestor?
      // Simpler & predictable: toggle exact path and clear nested selections under it;
      // if unselecting while an ancestor is checked, remove the ancestor so the user can choose siblings cleanly.
      if (selected) {
        _selectedPaths.removeWhere((p) => p.startsWith(prefix));
        _selectedPaths.add(path);
      } else {
        _selectedPaths.removeWhere((p) => p == path || p.startsWith(prefix));
        final parts = path.split('/');
        var parent = parts.first;
        for (final segment in parts.skip(1)) {
          final child = '$parent/$segment';
          if (_selectedPaths.remove(parent)) {
            for (final sibling in _listings[parent] ?? const []) {
              final siblingPath = sibling['path'] as String? ?? '';
              if (siblingPath.isNotEmpty && siblingPath != path) {
                _selectedPaths.add(siblingPath);
              }
            }
          }
          parent = child;
        }
      }
    });
  }

  void _addExcludePattern() {
    final value = _excludeController.text.trim();
    if (value.isEmpty) return;
    final clean = value.replaceAll(RegExp(r'^/+|/+$'), '');
    if (clean.isEmpty) return;
    setState(() {
      if (!_excludePatterns.contains(clean)) {
        _excludePatterns.add(clean);
      }
      _excludeController.clear();
    });
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final parentPath = _currentPath.contains('/')
        ? _currentPath.substring(0, _currentPath.lastIndexOf('/'))
        : '';

    return AlertDialog(
      key: const ValueKey('termux-backup-dialog'),
      title: const Text('Back up Termux Home'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Choose folders and files to include. Caches and generated '
                'folders inside them can still be excluded below, while .env* '
                'files are always backed up.',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_currentPath.isNotEmpty)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Up',
                      onPressed: _loadingFolder
                          ? null
                          : () => _openFolder(parentPath),
                      icon: const Icon(Icons.arrow_upward, size: 18),
                    ),
                  Expanded(
                    child: Text(
                      _currentPath.isEmpty
                          ? '~ (Termux Home)'
                          : '~/$_currentPath',
                      style: Theme.of(context).textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (_loadError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _loadError!,
                    style: TextStyle(color: scheme.error),
                  ),
                ),
              Container(
                constraints: const BoxConstraints(maxHeight: 185),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.6),
                  ),
                ),
                child: _loadingFolder
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    : _entries.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('This folder is empty.'),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          final path = entry['path'] as String? ?? '';
                          final name = entry['name'] as String? ?? path;
                          final isDir = entry['is_dir'] == true;
                          final always = entry['always_included'] == true;
                          final excludedByDefault =
                              entry['excluded_by_default'] == true;
                          final sizeText = _formatSize(
                            (entry['size_bytes'] as num?)?.toInt() ?? 0,
                          );
                          final covered = always || _isPathCovered(path);
                          final partial =
                              !covered && isDir && _hasSelectedDescendant(path);
                          final subtitleParts = <String>[
                            if (always)
                              'Always backed up (.env*)'
                            else if (excludedByDefault)
                              'Excluded by default',
                            if (sizeText.isNotEmpty) sizeText,
                          ];
                          return ListTile(
                            dense: true,
                            key: ValueKey('backup-entry-$path'),
                            leading: Checkbox(
                              tristate: partial,
                              value: partial ? null : covered,
                              onChanged: always
                                  ? null
                                  : (checked) =>
                                        _toggleEntry(entry, checked ?? false),
                            ),
                            title: Row(
                              children: [
                                Icon(
                                  isDir
                                      ? Icons.folder_outlined
                                      : Icons.insert_drive_file_outlined,
                                  size: 18,
                                  color: scheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            subtitle: subtitleParts.isEmpty
                                ? null
                                : Text(subtitleParts.join(' · ')),
                            trailing: isDir
                                ? IconButton(
                                    tooltip: 'Browse $name',
                                    icon: const Icon(Icons.chevron_right),
                                    onPressed: () => _openFolder(path),
                                  )
                                : null,
                            onTap: always
                                ? null
                                : () => _toggleEntry(entry, !covered),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 14),
              Text(
                'Excluded folders inside selected items',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final pattern in _excludePatterns)
                    InputChip(
                      key: ValueKey('backup-exclude-$pattern'),
                      label: Text(pattern),
                      onDeleted: () => setState(() {
                        _excludePatterns.remove(pattern);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('termux-backup-exclude-input'),
                      controller: _excludeController,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Add folder or pattern (e.g. .next, *.log)',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _addExcludePattern(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    key: const ValueKey('termux-backup-exclude-add'),
                    onPressed: _addExcludePattern,
                    child: const Text('Exclude'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('termux-backup-confirm'),
          onPressed: _selectedPaths.isEmpty
              ? null
              : () {
                  final sorted = _selectedPaths.toList()..sort();
                  Navigator.pop(
                    context,
                    TermuxBackupSelection(
                      includePaths: sorted,
                      excludePatterns: List<String>.from(_excludePatterns),
                    ),
                  );
                },
          child: const Text('Choose save location'),
        ),
      ],
    );
  }
}
