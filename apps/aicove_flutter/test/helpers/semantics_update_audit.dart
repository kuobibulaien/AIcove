import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Checks every semantics update the framework sends against the rules the
/// desktop engine's accessibility bridge (ui::AXTree) enforces. An update that
/// breaks them makes the macOS bridge keep freed nodes and crash on the next
/// accessibility query (flutter/flutter#193588).
class SemanticsUpdateAudit {
  SemanticsUpdateAudit._();

  static final SemanticsUpdateAudit instance = SemanticsUpdateAudit._();

  /// Parent -> children (traversal order) as the engine currently holds it.
  final Map<int, List<int>> _children = <int, List<int>>{};
  final Map<int, String> _labels = <int, String>{};
  final List<String> violations = <String>[];

  void reset() {
    _children.clear();
    _labels.clear();
    violations.clear();
  }

  void _commit(Map<int, List<int>> update, Map<int, String> labels) {
    final Map<int, int> oldParent = _parentsOf(_children);
    final Map<int, List<int>> next = Map<int, List<int>>.of(_children)
      ..addAll(update);
    _labels.addAll(labels);

    final List<String> errors = <String>[];
    for (final MapEntry<int, List<int>> entry in update.entries) {
      for (final int child in entry.value) {
        final int? previous = oldParent[child];
        final bool known = _children.containsKey(child);
        if (!known && !update.containsKey(child)) {
          errors.add('node ${entry.key} claims unknown child $child');
        } else if (previous != null &&
            previous != entry.key &&
            !update.containsKey(child)) {
          errors.add(
            'child $child moved from $previous to ${entry.key} '
            'without being sent',
          );
        }
      }
    }

    final Map<int, int> claimedBy = <int, int>{};
    final Set<int> reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final int child in next[id] ?? const <int>[]) {
        final int? other = claimedBy[child];
        if (other != null && other != id) {
          errors.add('child $child claimed by both $other and $id');
        }
        claimedBy[child] = id;
        visit(child);
      }
    }

    if (next.containsKey(0)) visit(0);
    for (final int id in update.keys) {
      if (!reachable.contains(id)) {
        errors.add('node $id will not be in the tree and is not the root');
      }
    }

    if (errors.isNotEmpty) {
      violations.add(
        '${errors.map((String e) => '$e ${_describe(e)}').join('\n')}\n'
        '${_testFrames()}',
      );
    }

    // Mirror the engine: keep only what is reachable from the root.
    _children
      ..clear()
      ..addEntries(next.entries.where((e) => reachable.contains(e.key)));
  }

  String _describe(String error) {
    final Iterable<int> ids = RegExp(
      r'\d+',
    ).allMatches(error).map((Match m) => int.parse(m.group(0)!));
    return ids
        .map((int id) => '#$id="${_labels[id] ?? ''}"')
        .toSet()
        .join(' ');
  }

  static String _testFrames() => StackTrace.current
      .toString()
      .split('\n')
      .where((String line) => line.contains('_test.dart'))
      .take(3)
      .join('\n');

  static Map<int, int> _parentsOf(Map<int, List<int>> tree) => <int, int>{
    for (final MapEntry<int, List<int>> entry in tree.entries)
      for (final int child in entry.value) child: entry.key,
  };
}

/// Test binding that routes semantics updates through [SemanticsUpdateAudit].
class SemanticsAuditBinding extends AutomatedTestWidgetsFlutterBinding {
  /// Installs the binding unless flutter_test_config.dart already did.
  static void ensureInitialized() {
    try {
      WidgetsBinding.instance;
    } on FlutterError {
      SemanticsAuditBinding();
    }
  }

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _AuditingUpdateBuilder(super.createSemanticsUpdateBuilder());
}

class _AuditingUpdateBuilder implements ui.SemanticsUpdateBuilder {
  _AuditingUpdateBuilder(this._inner);

  final ui.SemanticsUpdateBuilder _inner;
  final Map<int, List<int>> _update = <int, List<int>>{};
  final Map<int, String> _labels = <int, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final Map<Symbol, dynamic> named = invocation.namedArguments;
    switch (invocation.memberName) {
      case #updateNode:
        final int id = named[#id] as int;
        final Int32List order = named[#childrenInTraversalOrder] as Int32List;
        _update[id] = order.toList();
        _labels[id] = '${named[#identifier] ?? ''}/${named[#label] ?? ''}'
            .replaceAll('\n', ' ');
        return Function.apply(_inner.updateNode, const <Object?>[], named);
      case #updateCustomAction:
        return Function.apply(
          _inner.updateCustomAction,
          const <Object?>[],
          named,
        );
      case #build:
        SemanticsUpdateAudit.instance._commit(_update, _labels);
        return _inner.build();
    }
    return super.noSuchMethod(invocation);
  }
}
