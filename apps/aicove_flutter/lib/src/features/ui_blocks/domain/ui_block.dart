import 'dart:convert';
import 'dart:math' as math;

import 'ui_expression.dart';
import 'ui_json.dart';
import 'ui_lines.dart';
import 'ui_template.dart';

/// Interactive block model (ADR0073 交互组件): from the fenced text to a tree
/// whose props are plain values, recomputed whenever the block's state
/// changes. Structure follows DEEIX-Chat `packages/core/src/ui-block/
/// block.ts`.
///
///     UiBlock.parse(raw)        lenient parse (JSON or line syntax)
///     UiProgram.compile(block)  compile formulas, order computed
///     program.resolve(state)    evaluate computed and templates
///
/// Nothing here throws on model mistakes: broken parts are dropped or show
/// as "—" and are listed in `issues`, so one bad node never blanks a block.

/// Info string of the fence the model writes blocks in.
const String kUiBlockFenceLanguage = 'aicove-ui';

/// Whether a fence's info string names a block; case-insensitive, since
/// models sometimes shout it. The renderer and <ui_state> both use this.
bool uiIsBlockLanguage(String language) => language.trim().toLowerCase() == kUiBlockFenceLanguage;

const int kUiBlockMaxNodes = 300;
const int kUiBlockMaxDepth = 8;
const int kUiBlockMaxComputed = 64;
const int kUiBlockStateMaxDepth = 4;

const _structureKeys = {
  'component', 'id', 'version', 'state', 'computed', //
  'children', 'visible', 'bind', 'props',
};

final _blockIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final _identifierPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Names formulas already give a meaning; state and computed cannot reuse
/// them, or a formula would read the constant or the value by accident.
const _reservedNames = {'pi', 'e', 'true', 'false', 'null'};

bool _isStateName(String name) => _identifierPattern.hasMatch(name) && !_reservedNames.contains(name);

/// Controls: nodes that read and write a state variable through `bind`.
const kUiControls = {'slider', 'select', 'segmented', 'switch', 'input'};

class UiNodeSource {
  const UiNodeSource({
    required this.component,
    required this.props,
    required this.children,
    required this.path,
    this.bind,
    this.visible,
  });

  final String component;
  final Map<String, Object?> props;
  final List<UiNodeSource> children;
  final String? bind;
  final Object? visible;

  /// Index path from the root.
  final String path;
}

class UiBlock {
  const UiBlock({
    required this.component,
    required this.id,
    required this.key,
    required this.root,
    required this.live,
    this.state,
    this.computed,
  });

  final String component;

  /// Model-given id when valid, otherwise ''.
  final String id;

  /// What state is stored and reported under: the id, or `auto-<hash>` of
  /// the content for a block without a valid one.
  final String key;
  final Map<String, Object?>? state;
  final Map<String, Object?>? computed;
  final UiNodeSource root;

  /// Has state, computed or children: its templates are evaluated. A static
  /// block passes its props through untouched.
  final bool live;

  String get title {
    final value = root.props['title'];
    return value is String ? value.trim() : '';
  }

  /// Null with [error] set when the text is not a block. Text starting
  /// with `{` is JSON; anything else is the line syntax of catalog blocks.
  static UiBlockParse parse(String raw) {
    final Object? value;
    try {
      value = raw.trimLeft().startsWith('{') ? readLenientJson(raw) : readUiLines(raw);
    } on FormatException catch (error) {
      return UiBlockParse._error(error.message);
    }
    if (value is! Map<String, Object?> ||
        value['component'] is! String ||
        (value['component'] as String).isEmpty) {
      return const UiBlockParse._error('expected an object with a component');
    }
    final state = value['state'];
    final computed = value['computed'];
    final id = _normalizeId(value['id']);
    return UiBlockParse._ok(UiBlock(
      component: value['component'] as String,
      id: id,
      key: id.isNotEmpty ? id : 'auto-${uiHashText(jsonEncode(value))}',
      state: state is Map<String, Object?> ? state : null,
      computed: computed is Map<String, Object?> ? computed : null,
      root: _readNode(value, ''),
      live: state is Map || computed is Map || value['children'] is List,
    ));
  }

  static UiNodeSource _readNode(Map<String, Object?> value, String path) {
    // Props sit either in a `props` object or flat on the node.
    final legacy = value['props'];
    final props = <String, Object?>{};
    if (legacy is Map<String, Object?>) {
      props.addAll(legacy);
    } else {
      for (final entry in value.entries) {
        if (!_structureKeys.contains(entry.key)) props[entry.key] = entry.value;
      }
    }
    final children = <UiNodeSource>[];
    final rawChildren = value['children'];
    if (rawChildren is List) {
      for (var i = 0; i < rawChildren.length; i++) {
        final child = rawChildren[i];
        if (child is Map<String, Object?> &&
            child['component'] is String &&
            (child['component'] as String).isNotEmpty) {
          children.add(_readNode(child, path.isEmpty ? '$i' : '$path.$i'));
        }
      }
    }
    final bind = value['bind'];
    return UiNodeSource(
      component: value['component'] as String? ?? '',
      props: props,
      children: children,
      path: path,
      bind: bind is String && bind.isNotEmpty ? bind : null,
      visible: value['visible'],
    );
  }

  static String _normalizeId(Object? id) {
    final text = id is num ? uiStringify(id) : id is String ? id.trim() : '';
    return _blockIdPattern.hasMatch(text) ? text : '';
  }
}

class UiBlockParse {
  const UiBlockParse._ok(UiBlock this.block) : error = null;
  const UiBlockParse._error(String this.error) : block = null;

  final UiBlock? block;
  final String? error;
}

/// FNV-1a, 32 bits, base 36: collisions only matter within one message.
String uiHashText(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(36);
}

class UiBlockIssue {
  const UiBlockIssue(this.path, this.message);
  final String path;
  final String message;

  @override
  String toString() => path.isEmpty ? message : '$path: $message';
}

// ---- Compilation ----

sealed class _Value {
  const _Value();
}

class _Static extends _Value {
  const _Static(this.value);
  final Object? value;
}

/// A prop whose formula did not compile; shows as null, and a strict check
/// sees the failure.
class _Broken extends _Value {
  const _Broken();
}

class _Templated extends _Value {
  const _Templated(this.template);
  final UiTemplate template;
}

class _ListValue extends _Value {
  const _ListValue(this.items);
  final List<_Value> items;
}

class _ObjectValue extends _Value {
  const _ObjectValue(this.fields);
  final Map<String, _Value> fields;
}

class _CompiledNode {
  _CompiledNode(this.source, this.bind, this.visible, this.props, this.children);
  final UiNodeSource source;
  final String? bind;
  final UiExpression? visible;
  final Map<String, _Value> props;
  final List<_CompiledNode> children;
}

/// A node with every prop evaluated, ready to render.
class UiNode {
  const UiNode({
    required this.component,
    required this.props,
    required this.children,
    required this.path,
    this.bind,
  });

  final String component;
  final Map<String, Object?> props;
  final List<UiNode> children;
  final String path;
  final String? bind;

  String? text(String key) {
    final value = props[key];
    return value == null ? null : uiStringify(value);
  }

  /// Finite numbers only: sizes and counts are taken from it.
  num? number(String key) {
    final value = props[key];
    final number = value is num ? value : value is String ? num.tryParse(value.trim()) : null;
    return number != null && number.isFinite ? number : null;
  }

  bool flag(String key) => uiTruthy(props[key]);

  List<Object?> list(String key) {
    final value = props[key];
    return value is List ? value : const [];
  }
}

class UiProgram {
  UiProgram._(this.block, this.initialState, this._computed, this._root,
      this.issues);

  final UiBlock block;

  /// Declared initial state (JSON values), before any user change; controls
  /// bound to undeclared names get a default here.
  final Map<String, Object?> initialState;
  final List<(String, UiExpression?, Object?)> _computed;
  final _CompiledNode? _root;
  final List<UiBlockIssue> issues;

  static UiProgram compile(UiBlock block) {
    final issues = <UiBlockIssue>[];
    final initial = _readInitialState(block.state, issues);
    final computed = _orderComputed(block.computed, initial.keys.toSet(), issues);
    final context = _CompileContext(issues, block.live);
    final root = _compileNode(block.root, 0, context);
    if (root != null) _implicitState(root, initial);
    return UiProgram._(block, initial, computed, root, issues);
  }

  /// Evaluates computed values and templates against [state].
  UiNode resolve(Map<String, Object?> state) {
    final budget = UiBudget();
    final scope = _scope(state, budget);
    final root = _root;
    if (root == null) {
      return UiNode(component: block.component, props: const {}, children: const [], path: '');
    }
    return _resolveNode(root, scope, budget) ??
        UiNode(component: block.component, props: const {}, children: const [], path: '');
  }

  /// Every node of [component], hidden ones included, with only [keys]
  /// evaluated, each node on its own budget so nothing else in the block can
  /// use it up. `failed` is true when one of those props did not evaluate:
  /// a check built on them cannot trust what it sees.
  List<({String? bind, Map<String, Object?> props, bool failed})> resolveEach(
    String component,
    Map<String, Object?> state,
    Set<String> keys,
  ) {
    final scope = _scope(state, UiBudget());
    final result = <({String? bind, Map<String, Object?> props, bool failed})>[];
    void walk(_CompiledNode node) {
      if (node.source.component == component) {
        final budget = UiBudget();
        var failed = false;
        final props = <String, Object?>{};
        for (final key in keys) {
          final value = node.props[key];
          if (value == null) continue;
          try {
            props[key] = _resolveStrict(value, scope, budget);
          } on UiExpressionError {
            failed = true;
          }
        }
        result.add((bind: node.bind, props: props, failed: failed));
      }
      node.children.forEach(walk);
    }

    final root = _root;
    if (root != null) walk(root);
    return result;
  }

  UiScope _scope(Map<String, Object?> state, UiBudget budget) {
    final scope = <String, Object?>{...initialState, ...state};
    for (final (name, expression, constant) in _computed) {
      if (expression == null) {
        scope[name] = constant;
        continue;
      }
      try {
        scope[name] = expression.evaluate(scope, budget);
      } on UiExpressionError catch (error) {
        scope[name] = error;
      }
    }
    return scope;
  }

  UiNode? _resolveNode(_CompiledNode node, UiScope scope, UiBudget budget) {
    if (node.visible != null) {
      try {
        if (!uiTruthy(node.visible!.evaluate(scope, budget))) return null;
      } on UiExpressionError {
        return null;
      }
    }
    final props = <String, Object?>{
      for (final entry in node.props.entries)
        entry.key: _resolveValue(entry.value, scope, budget),
    };
    if (node.bind != null) {
      // A bound computed that failed holds its error; controls get nothing.
      final bound = scope[node.bind];
      props['value'] = bound is UiExpressionError ? null : bound;
    }
    return UiNode(
      component: node.source.component,
      props: props,
      children: [
        for (final child in node.children)
          ?_resolveNode(child, scope, budget),
      ],
      path: node.source.path,
      bind: node.bind,
    );
  }

  /// Like [_resolveValue], but any formula that did not compile or evaluate,
  /// at any depth or inside mixed text, throws.
  static Object? _resolveStrict(_Value value, UiScope scope, UiBudget budget) => switch (value) {
        _Static(:final value) => value,
        _Broken() => throw const UiExpressionError('formula did not compile'),
        _Templated(:final template) => template.evaluate(scope, budget, strict: true),
        _ListValue(:final items) => [for (final item in items) _resolveStrict(item, scope, budget)],
        _ObjectValue(:final fields) => {
            for (final entry in fields.entries) entry.key: _resolveStrict(entry.value, scope, budget),
          },
      };

  static Object? _resolveValue(_Value value, UiScope scope, UiBudget budget) {
    switch (value) {
      case _Static(:final value):
        return value;
      case _Broken():
        return null;
      case _Templated(:final template):
        try {
          return template.evaluate(scope, budget);
        } on UiExpressionError {
          return null;
        }
      case _ListValue(:final items):
        return [for (final item in items) _resolveValue(item, scope, budget)];
      case _ObjectValue(:final fields):
        return {
          for (final entry in fields.entries)
            entry.key: _resolveValue(entry.value, scope, budget),
        };
    }
  }
}

class _CompileContext {
  _CompileContext(this.issues, this.live);
  final List<UiBlockIssue> issues;
  final bool live;
  int nodes = 0;
}

_CompiledNode? _compileNode(UiNodeSource source, int depth, _CompileContext context) {
  if (depth >= kUiBlockMaxDepth) {
    context.issues.add(UiBlockIssue(source.path, 'nesting deeper than $kUiBlockMaxDepth dropped'));
    return null;
  }
  context.nodes += 1;
  if (context.nodes > kUiBlockMaxNodes) {
    if (context.nodes == kUiBlockMaxNodes + 1) {
      context.issues.add(UiBlockIssue(source.path, 'more than $kUiBlockMaxNodes nodes; the rest are dropped'));
    }
    return null;
  }
  var bind = source.bind;
  final props = <String, _Value>{};
  for (final entry in source.props.entries) {
    final key = entry.key;
    final value = entry.value;
    if (!context.live) {
      props[key] = _Static(value);
      continue;
    }
    // A control written as `"value": "{x}"` binds x.
    if (key == 'value' && bind == null && value is String && kUiControls.contains(source.component)) {
      final bound = RegExp(r'^\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}$').firstMatch(value);
      if (bound != null) {
        bind = bound.group(1);
        continue;
      }
    }
    props[key] = _compileValue(value, '${source.path}.$key', context.issues);
  }
  UiExpression? visible;
  if (context.live && source.visible != null) {
    final raw = source.visible;
    try {
      visible = UiExpression.parse(raw is bool ? '$raw' : unwrapUiFormula(raw is String ? raw : 'false'));
    } on UiExpressionError catch (error) {
      context.issues.add(UiBlockIssue('${source.path}.visible', error.message));
      visible = UiExpression.parse('false');
    }
  }
  final children = <_CompiledNode>[
    for (final child in source.children) ?_compileNode(child, depth + 1, context),
  ];
  return _CompiledNode(source, bind, visible, props, children);
}

_Value _compileValue(Object? value, String path, List<UiBlockIssue> issues) {
  if (value is String) {
    try {
      final template = UiTemplate.compile(value);
      return template == null ? _Static(uiTemplateLiteral(value)) : _Templated(template);
    } on UiExpressionError catch (error) {
      issues.add(UiBlockIssue(path, error.message));
      return const _Broken();
    }
  }
  if (value is List) {
    return _ListValue([
      for (var i = 0; i < value.length; i++) _compileValue(value[i], '$path[$i]', issues),
    ]);
  }
  if (value is Map<String, Object?>) {
    return _ObjectValue({
      for (final entry in value.entries)
        entry.key: _compileValue(entry.value, '$path.${entry.key}', issues),
    });
  }
  return _Static(value);
}

/// JSON values at most [kUiBlockStateMaxDepth] levels deep, else null.
Object? _jsonValue(Object? value, int depth, {required void Function() onInvalid}) {
  if (value == null || value is num || value is String || value is bool) return value;
  if (depth > kUiBlockStateMaxDepth) {
    onInvalid();
    return null;
  }
  if (value is List) return [for (final item in value) _jsonValue(item, depth + 1, onInvalid: onInvalid)];
  if (value is Map) {
    return {
      for (final entry in value.entries)
        '${entry.key}': _jsonValue(entry.value, depth + 1, onInvalid: onInvalid),
    };
  }
  onInvalid();
  return null;
}

Map<String, Object?> _readInitialState(Map<String, Object?>? state, List<UiBlockIssue> issues) {
  final result = <String, Object?>{};
  if (state == null) return result;
  for (final entry in state.entries) {
    if (!_isStateName(entry.key)) {
      issues.add(UiBlockIssue('state.${entry.key}', 'state names are letters, digits and _, not pi, e, true, false or null'));
      continue;
    }
    var invalid = false;
    final value = _jsonValue(entry.value, 1, onInvalid: () => invalid = true);
    if (invalid) {
      issues.add(UiBlockIssue('state.${entry.key}', 'state is nested too deep'));
      continue;
    }
    result[entry.key] = value;
  }
  return result;
}

/// Orders computed entries so each one is evaluated after what it reads.
/// Entries in a cycle still compile; they evaluate to an error ("—").
List<(String, UiExpression?, Object?)> _orderComputed(
  Map<String, Object?>? computed,
  Set<String> stateNames,
  List<UiBlockIssue> issues,
) {
  if (computed == null) return const [];
  final compiled = <String, (UiExpression?, Object?)>{};
  for (final entry in computed.entries) {
    final name = entry.key;
    if (!_isStateName(name)) {
      issues.add(UiBlockIssue('computed.$name', 'computed names are letters, digits and _, not pi, e, true, false or null'));
      continue;
    }
    if (stateNames.contains(name)) {
      issues.add(UiBlockIssue('computed.$name', 'already declared in state'));
      continue;
    }
    if (compiled.length >= kUiBlockMaxComputed) {
      issues.add(const UiBlockIssue('computed', 'more than $kUiBlockMaxComputed entries; the rest are dropped'));
      break;
    }
    final value = entry.value;
    if (value is String) {
      try {
        compiled[name] = (UiExpression.parse(unwrapUiFormula(value)), null);
      } on UiExpressionError catch (error) {
        issues.add(UiBlockIssue('computed.$name', error.message));
        // An error value, not the text "—": formulas reading it fail too,
        // so strict checks see the failure; display still shows "—".
        compiled[name] = (null, error);
      }
    } else {
      // Non-string values are constants: lookup tables, lists, flags.
      compiled[name] = (null, value);
    }
  }

  // Every value in a cycle is an error ("—"), even when a short-circuit
  // would let one evaluate: what it shows must not depend on order. Cycles
  // are the strongly connected components (Tarjan), so crossed loops count.
  final dependencies = {
    for (final entry in compiled.entries)
      entry.key: [
        for (final name in entry.value.$1?.variables ?? const <String>{})
          if (compiled.containsKey(name)) name,
      ],
  };
  final cyclic = <String>{};
  final index = <String, int>{};
  final low = <String, int>{};
  final stack = <String>[];
  final onStack = <String>{};
  void connect(String name) {
    index[name] = low[name] = index.length;
    stack.add(name);
    onStack.add(name);
    for (final next in dependencies[name]!) {
      if (!index.containsKey(next)) {
        connect(next);
        low[name] = math.min(low[name]!, low[next]!);
      } else if (onStack.contains(next)) {
        low[name] = math.min(low[name]!, index[next]!);
      }
    }
    if (low[name] != index[name]) return;
    final component = <String>[];
    String member;
    do {
      member = stack.removeLast();
      onStack.remove(member);
      component.add(member);
    } while (member != name);
    if (component.length > 1 || dependencies[name]!.contains(name)) cyclic.addAll(component);
  }

  for (final name in compiled.keys) {
    if (!index.containsKey(name)) connect(name);
  }
  for (final name in cyclic) {
    issues.add(UiBlockIssue('computed.$name', 'computed values read each other in a cycle'));
  }

  // Dependencies first; names in a cycle become errors.
  const cycleError = UiExpressionError('computed values read each other in a cycle');
  final order = <(String, UiExpression?, Object?)>[];
  final done = <String>{};
  void visit(String name) {
    if (!done.add(name)) return;
    if (!cyclic.contains(name)) {
      for (final dependency in dependencies[name]!) {
        visit(dependency);
      }
    }
    final (expression, constant) = compiled[name]!;
    order.add(cyclic.contains(name) ? (name, null, cycleError) : (name, expression, constant));
  }

  for (final name in compiled.keys) {
    visit(name);
  }
  return order;
}

/// Controls bound to a name the block never declared start from a default.
void _implicitState(_CompiledNode node, Map<String, Object?> state) {
  final bind = node.bind;
  if (bind != null && !state.containsKey(bind) && _isStateName(bind)) {
    state[bind] = _controlDefault(node.source);
  }
  for (final child in node.children) {
    _implicitState(child, state);
  }
}

Object? _controlDefault(UiNodeSource node) {
  switch (node.component) {
    case 'slider':
      final min = node.props['min'];
      return min is num ? min : 0;
    case 'switch':
      return false;
    case 'select':
    case 'segmented':
      final options = uiOptions(node.props['options']);
      return options.isEmpty ? null : options.first.value;
    case 'input':
      return node.props['type'] == 'number' ? 0 : '';
  }
  return null;
}

/// `["文字"]` or `[{label, value}]`.
List<({String label, Object? value})> uiOptions(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is Map)
        (label: uiStringify(item['label'] ?? item['value']), value: item.containsKey('value') ? item['value'] : item['label'])
      else if (item != null)
        (label: uiStringify(item), value: item),
  ];
}

/// [value] with every non-finite number (from `1/0` and the like) turned
/// into null, so it can be stored and reported as JSON.
Object? uiJsonSafe(Object? value) {
  if (value is num) return value.isFinite ? value : null;
  if (value is List) return [for (final item in value) uiJsonSafe(item)];
  if (value is Map) return {for (final e in value.entries) '${e.key}': uiJsonSafe(e.value)};
  return value;
}

/// The keys of [current] that differ from [initial]: what is stored and
/// reported to the model.
Map<String, Object?> uiStateDiff(Map<String, Object?> initial, Map<String, Object?> current) => {
      for (final entry in current.entries)
        if (!initial.containsKey(entry.key) || !uiValuesEqual(initial[entry.key], entry.value))
          entry.key: entry.value,
    };

/// Rebuilds state from untrusted saved values: names the block no longer
/// declares and values of another type are dropped.
Map<String, Object?> uiRestoreState(Map<String, Object?> initial, Map<String, Object?>? saved) {
  final result = <String, Object?>{...initial};
  if (saved == null) return result;
  for (final entry in saved.entries) {
    if (!initial.containsKey(entry.key)) continue;
    final base = initial[entry.key];
    final value = entry.value;
    final sameKind = base == null ||
        (base is num && value is num) ||
        (base is String && value is String) ||
        (base is bool && value is bool) ||
        (base is List && value is List) ||
        (base is Map && value is Map);
    if (sameKind) result[entry.key] = value;
  }
  return result;
}
