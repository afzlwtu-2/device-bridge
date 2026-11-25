import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../core/bridge.dart';
import 'network_card.dart';
import 'traffic_light.dart';

const List<(String, String)> aclResourceChoices = [
  ('*', 'Everything (*)'),
  ('files:browse', 'Files · Browse'),
  ('files:read', 'Files · Download / Read'),
  ('ssh', 'Agent SSH'),
  ('share:text', 'Quick Share · Text'),
  ('share:file', 'Quick Share · Files & Folders'),
  ('sync', 'Folder Sync'),
  ('termux', 'Termux File Management'),
  ('actions', 'Agent Actions'),
  ('link', 'Direct Link Setup'),
];

const List<String> commonDeviceTags = [
  'tag:trusted',
  'tag:guest',
  'tag:family',
  'tag:work',
];

String normalizeTagInput(String raw) {
  final cleaned = raw.trim().toLowerCase();
  if (cleaned.isEmpty) return '';
  return cleaned.startsWith('tag:') ? cleaned : 'tag:$cleaned';
}

String normalizeGroupInput(String raw) {
  final cleaned = raw.trim().toLowerCase();
  if (cleaned.isEmpty) return '';
  return cleaned.startsWith('group:') ? cleaned : 'group:$cleaned';
}

/// Tailscale-style ACL rules, device tags, and device groups for this device.
class AclScreen extends StatefulWidget {
  const AclScreen({super.key, required this.core});
  final CoreBridge core;

  @override
  State<AclScreen> createState() => _AclScreenState();
}

class _AclScreenState extends State<AclScreen> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  Map<String, dynamic> _policy = {
    'version': 1,
    'enabled': false,
    'groups': {},
    'rules': [],
  };
  Map<String, List<String>> _peerTags = {};
  List<Map<String, dynamic>> _evaluations = [];
  List<Map<String, dynamic>> _peers = [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  void _applySnapshot(dynamic rawSnap, dynamic rawPeers) {
    if (rawSnap is Map) {
      final p = rawSnap['policy'];
      if (p is Map) {
        _policy = Map<String, dynamic>.from(p);
      }
      final pt = rawSnap['peer_tags'];
      if (pt is Map) {
        _peerTags = {
          for (final e in pt.entries)
            '${e.key}': (e.value as List? ?? const [])
                .map((x) => '$x')
                .toList(),
        };
      }
      final ev = rawSnap['evaluations'];
      if (ev is List) {
        _evaluations = ev
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }
    if (rawPeers is List) {
      _peers = rawPeers
          .whereType<Map>()
          .where((p) => p['status'] != 'revoked')
          .map((p) => Map<String, dynamic>.from(p))
          .toList();
    }
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.core.run(['acl']),
        widget.core.run(['peers']),
      ]);
      if (!mounted) return;
      setState(() {
        _applySnapshot(results[0], results[1]);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _runOp(Future<void> Function() op) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await op();
    } catch (e) {
      if (mounted) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _savePolicy(Map<String, dynamic> next) => _runOp(() async {
    final snap = await widget.core.run([
      'acl',
      'set',
      '-',
    ], input: jsonEncode(next));
    final peers = await widget.core.run(['peers']);
    if (mounted) {
      setState(() => _applySnapshot(snap, peers));
    }
  });

  Future<void> _applyPresetTrusted() => _runOp(() async {
    final snap = await widget.core.run(['acl', 'preset', 'trusted']);
    final peers = await widget.core.run(['peers']);
    if (mounted) {
      setState(() => _applySnapshot(snap, peers));
    }
  });

  Future<void> _setPeerTags(String peerId, List<String> tags) =>
      _runOp(() async {
        await widget.core.run([
          'peer-tags',
          peerId,
          tags.isEmpty ? 'none' : tags.join(','),
        ]);
        final results = await Future.wait([
          widget.core.run(['acl']),
          widget.core.run(['peers']),
        ]);
        if (mounted) {
          setState(() => _applySnapshot(results[0], results[1]));
        }
      });

  Future<void> _saveGroup(
    String groupName,
    List<String> members, {
    bool delete = false,
  }) => _runOp(() async {
    await widget.core.run([
      'acl-group',
      groupName,
      delete ? 'delete' : (members.isEmpty ? 'none' : members.join(',')),
    ]);
    final results = await Future.wait([
      widget.core.run(['acl']),
      widget.core.run(['peers']),
    ]);
    if (mounted) {
      setState(() => _applySnapshot(results[0], results[1]));
    }
  });

  Future<void> _addTagDialog(Map<String, dynamic> peer) async {
    final peerId = '${peer['id']}';
    final current = List<String>.from(_peerTags[peerId] ?? const []);
    final ctrl = TextEditingController();
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Tag ${peer['name']}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final t in commonDeviceTags)
                  if (!current.contains(t))
                    ActionChip(
                      label: Text(t),
                      onPressed: () => Navigator.pop(ctx, t),
                    ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'Custom tag (e.g. trusted, servers)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Add tag'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (selected == null) return;
    final tag = normalizeTagInput(selected);
    if (tag.isEmpty || current.contains(tag)) return;
    await _setPeerTags(peerId, [...current, tag]);
  }

  Future<void> _editGroupDialog([
    String? existingGroup,
    List<String>? existingMembers,
  ]) async {
    final nameCtrl = TextEditingController(text: existingGroup ?? 'group:');
    final selected = Set<String>.from(existingMembers ?? const []);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text(
            existingGroup == null ? 'New device group' : 'Edit $existingGroup',
          ),
          content: SizedBox(
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    readOnly: existingGroup != null,
                    decoration: const InputDecoration(
                      labelText: 'Group name (e.g. group:trusted)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_peers.isEmpty)
                    const Text('No paired devices available.')
                  else
                    for (final p in _peers)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${p['name']}'),
                        value: selected.contains('${p['id']}'),
                        onChanged: (v) => setDlg(() {
                          if (v == true) {
                            selected.add('${p['id']}');
                          } else {
                            selected.remove('${p['id']}');
                          }
                        }),
                      ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save group'),
            ),
          ],
        ),
      ),
    );
    final rawName = nameCtrl.text;
    nameCtrl.dispose();
    if (confirmed != true) return;
    final grp = normalizeGroupInput(rawName);
    if (grp.isEmpty) return;
    await _saveGroup(grp, selected.toList());
  }

  Future<void> _addRuleDialog() async {
    final groups =
        (_policy['groups'] as Map? ?? const {}).keys.map((k) => '$k').toList()
          ..sort();
    final knownTags = <String>{
      ...commonDeviceTags,
      for (final list in _peerTags.values) ...list,
    }.toList()..sort();
    var action = 'accept';
    final srcCtrl = TextEditingController(text: 'tag:trusted');
    final descCtrl = TextEditingController();
    final dst = <String>{'*'};

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Add ACL rule'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'accept', label: Text('Allow')),
                      ButtonSegment(value: 'deny', label: Text('Deny')),
                    ],
                    selected: {action},
                    onSelectionChanged: (s) => setDlg(() => action = s.single),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: srcCtrl,
                    decoration: const InputDecoration(
                      labelText:
                          'Source (tag:trusted, group:name, peer:<id>, or *)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in knownTags)
                        ActionChip(
                          label: Text(t),
                          onPressed: () => setDlg(() => srcCtrl.text = t),
                        ),
                      for (final g in groups)
                        ActionChip(
                          label: Text(g),
                          onPressed: () => setDlg(() => srcCtrl.text = g),
                        ),
                      ActionChip(
                        label: const Text('* (Any paired)'),
                        onPressed: () => setDlg(() => srcCtrl.text = '*'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('Allowed / blocked access'),
                  for (final choice in aclResourceChoices)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(choice.$2),
                      value: dst.contains(choice.$1),
                      onChanged: (v) => setDlg(() {
                        if (choice.$1 == '*') {
                          dst.clear();
                          if (v == true) dst.add('*');
                        } else {
                          dst.remove('*');
                          if (v == true) {
                            dst.add(choice.$1);
                          } else {
                            dst.remove(choice.$1);
                          }
                        }
                      }),
                    ),
                  TextField(
                    controller: descCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save rule'),
            ),
          ],
        ),
      ),
    );
    final srcText = srcCtrl.text.trim();
    final descText = descCtrl.text.trim();
    srcCtrl.dispose();
    descCtrl.dispose();
    if (ok != true || srcText.isEmpty || dst.isEmpty) return;

    final currentRules = List<Map<String, dynamic>>.from(
      (_policy['rules'] as List? ?? const []).whereType<Map>().map(
        (r) => Map<String, dynamic>.from(r),
      ),
    );
    final newRule = <String, dynamic>{
      'id': 'rule-${DateTime.now().millisecondsSinceEpoch}',
      'action': action,
      'src': srcText
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      'dst': dst.toList(),
      if (descText.isNotEmpty) 'description': descText,
    };
    currentRules.add(newRule);
    await _savePolicy({..._policy, 'rules': currentRules});
  }

  String _peerName(String id) {
    for (final p in _peers) {
      if (p['id'] == id) return '${p['name']}';
    }
    return id.length > 12 ? '${id.substring(0, 12)}…' : id;
  }

  String _evalSummary(Map<String, dynamic> ev) {
    final decisions = (ev['decisions'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final allowed = decisions
        .where((d) => d['allowed'] == true)
        .map((d) => '${d['resource']}')
        .toList();
    final denied = decisions
        .where((d) => d['allowed'] != true)
        .map((d) => '${d['resource']}')
        .toList();
    if (denied.isEmpty && allowed.isNotEmpty) {
      return 'All services allowed';
    }
    if (allowed.isEmpty) {
      return 'Denied all services';
    }
    return 'Allowed: ${allowed.join(', ')}\nDenied: ${denied.join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _policy['enabled'] == true;
    final groups = (_policy['groups'] as Map? ?? const {});
    final rules = (_policy['rules'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('ACL rules & device groups'),
        actions: [
          IconButton(
            tooltip: 'Refresh ACL',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: const ValueKey('acl-listview'),
              padding: const EdgeInsets.all(16),
              children: [
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  MaterialBanner(
                    content: SelectableText(_error!),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _error = null),
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                NetworkCard(
                  icon: Icons.security_outlined,
                  title: 'Tailscale-style ACL policy',
                  status: enabled ? 'Enforced' : 'Off',
                  level: enabled
                      ? TrafficLightLevel.green
                      : TrafficLightLevel.off,
                  detail: enabled
                      ? 'Default-deny is active: only devices matched by an Allow rule can access services on this device.'
                      : 'ACL enforcement is off. Existing per-device grants apply until you enable ACL rules.',
                  extra: SwitchListTile.adaptive(
                    key: const ValueKey('acl-enforce-switch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enforce ACL rules (default deny)'),
                    subtitle: const Text(
                      'Explicit Deny rules override Allow rules.',
                    ),
                    value: enabled,
                    onChanged: _busy
                        ? null
                        : (v) => _savePolicy({..._policy, 'enabled': v}),
                  ),
                  actions: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('acl-preset-trusted'),
                      onPressed: _busy ? null : _applyPresetTrusted,
                      icon: const Icon(Icons.verified_user_outlined),
                      label: const Text('Apply Trusted / Guest preset'),
                    ),
                  ],
                ),
                NetworkCard(
                  icon: Icons.label_outline,
                  title: 'Device tags',
                  detail: 'Assign tags like tag:trusted or tag:guest to paired devices.',
                  extra: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_peers.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('Pair a device first to assign tags.'),
                        ),
                      for (final p in _peers)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${p['name']}'),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                for (final tag
                                    in (_peerTags['${p['id']}'] ??
                                        const <String>[]))
                                  InputChip(
                                    label: Text(tag),
                                    onDeleted: _busy
                                        ? null
                                        : () {
                                            final next = List<String>.from(
                                              _peerTags['${p['id']}'] ??
                                                  const [],
                                            )..remove(tag);
                                            _setPeerTags('${p['id']}', next);
                                          },
                                  ),
                                ActionChip(
                                  key: ValueKey('acl-add-tag-${p['id']}'),
                                  avatar: const Icon(Icons.add, size: 16),
                                  label: const Text('Tag'),
                                  onPressed: _busy
                                      ? null
                                      : () => _addTagDialog(p),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                NetworkCard(
                  icon: Icons.group_outlined,
                  title: 'Device groups',
                  detail: 'Reference groups in ACL rules as group:<name>.',
                  extra: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (groups.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('No groups created yet.'),
                        ),
                      for (final entry in groups.entries)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${entry.key}'),
                          subtitle: Text(
                            (entry.value as List? ?? const []).isEmpty
                                ? 'No members'
                                : (entry.value as List)
                                      .map((m) => _peerName('$m'))
                                      .join(', '),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Edit group',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: _busy
                                    ? null
                                    : () => _editGroupDialog(
                                        '${entry.key}',
                                        (entry.value as List? ?? const [])
                                            .map((m) => '$m')
                                            .toList(),
                                      ),
                              ),
                              IconButton(
                                tooltip: 'Delete group',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: _busy
                                    ? null
                                    : () => _saveGroup(
                                        '${entry.key}',
                                        const [],
                                        delete: true,
                                      ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  actions: [
                    OutlinedButton.icon(
                      key: const ValueKey('acl-new-group'),
                      onPressed: _busy ? null : () => _editGroupDialog(),
                      icon: const Icon(Icons.group_add_outlined),
                      label: const Text('New group'),
                    ),
                  ],
                ),
                NetworkCard(
                  icon: Icons.rule_outlined,
                  title: 'ACL rules',
                  detail:
                      'Rules control what sources can access on this device.',
                  extra: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (rules.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'No ACL rules yet. Add a rule or apply the Trusted / Guest preset.',
                          ),
                        ),
                      for (var i = 0; i < rules.length; i++)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            rules[i]['action'] == 'deny'
                                ? Icons.block
                                : Icons.check_circle_outline,
                          ),
                          title: Text(
                            '${rules[i]['action'] == 'deny' ? 'Deny' : 'Allow'} ${(rules[i]['src'] as List? ?? const []).join(', ')} → ${(rules[i]['dst'] as List? ?? const []).join(', ')}',
                          ),
                          subtitle:
                              '${rules[i]['description'] ?? ''}'.isNotEmpty
                              ? Text('${rules[i]['description']}')
                              : null,
                          trailing: IconButton(
                            tooltip: 'Remove rule',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: _busy
                                ? null
                                : () {
                                    final next =
                                        List<Map<String, dynamic>>.from(
                                          rules.map(
                                            (r) => Map<String, dynamic>.from(r),
                                          ),
                                        )..removeAt(i);
                                    _savePolicy({..._policy, 'rules': next});
                                  },
                          ),
                        ),
                    ],
                  ),
                  actions: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('acl-add-rule'),
                      onPressed: _busy ? null : _addRuleDialog,
                      icon: const Icon(Icons.add),
                      label: const Text('Add rule'),
                    ),
                  ],
                ),
                NetworkCard(
                  icon: Icons.fact_check_outlined,
                  title: 'Effective device access',
                  detail: 'Evaluated permissions for each paired device on this device.',
                  extra: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_evaluations.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text('No paired devices to evaluate.'),
                        ),
                      for (final ev in _evaluations)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            '${ev['name']}${((ev['tags'] as List?)?.isNotEmpty == true) ? ' (${(ev['tags'] as List).join(', ')})' : ''}',
                          ),
                          subtitle: Text(_evalSummary(ev)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
