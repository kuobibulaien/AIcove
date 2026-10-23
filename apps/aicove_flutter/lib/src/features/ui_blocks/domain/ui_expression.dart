import 'dart:math' as math;

/// Formula language of interactive blocks (ADR0073 交互组件).
///
/// A whitelisted syntax parsed to a tree and interpreted; there is no way to
/// reach the host. Values are JSON values: `num`, `String`, `bool`, `null`,
/// `List<Object?>` and `Map<String, Object?>`. Grammar, loosest to tightest:
///
///     cond ? a : b   ||   &&   == !=   < <= > >=   + -   * / %
///     unary ! -      ^ (right-associative; -2^2 is -(2^2))   a.b  a[i]  f(x)
///
/// Literals: numbers, 'text' or "text", true / false / null, [a, b]. `+`
/// joins text when either side is text. There is no assignment, loop or user
/// function. Semantics follow DEEIX-Chat `packages/core/src/ui-block/
/// expression.ts`, so the prompt describes one language.
class UiExpressionError implements Exception {
  const UiExpressionError(this.message);
  final String message;

  @override
  String toString() => message;
}

const int kUiExpressionMaxLength = 512;
const int kUiRangeMaxPoints = 1000;

/// Longest text a formula may build; joining past it is an error, so short
/// formulas that double a text cannot exhaust memory.
const int kUiTextMaxLength = 10000;

/// Steps shared by every formula of one block resolution.
class UiBudget {
  UiBudget([this.remaining = 200000]);
  int remaining;

  void spend([int steps = 1]) {
    remaining -= steps;
    if (remaining < 0) throw const UiExpressionError('formula too expensive');
  }
}

typedef UiScope = Map<String, Object?>;

class UiExpression {
  UiExpression._(this.source, this._root, this.variables);

  final String source;
  final _Node _root;

  /// Names read from the scope (constants and functions excluded).
  final Set<String> variables;

  static UiExpression parse(String source) {
    if (source.length > kUiExpressionMaxLength) {
      throw const UiExpressionError('formula too long');
    }
    final root = _Parser(_tokenize(source)).parse();
    final names = <String>{};
    root.collect(names);
    return UiExpression._(source, root, names);
  }

  Object? evaluate(UiScope scope, [UiBudget? budget]) {
    try {
      return _root.eval(scope, budget ?? UiBudget(100000));
    } on UnsupportedError catch (error) {
      // Integer conversions of non-finite numbers; the checks below should
      // catch them first, this keeps a missed one from breaking the block.
      throw UiExpressionError(error.message ?? 'unsupported number');
    } on ArgumentError catch (error) {
      throw UiExpressionError('${error.message}');
    }
  }
}

/// JS-like truthiness: null, false, 0, NaN and '' are false.
bool uiTruthy(Object? value) {
  if (value == null || value == false || value == '') return false;
  if (value is num) return value != 0 && !value.isNaN;
  return true;
}

/// Deep equality of JSON values; 1 and 1.0 are equal.
bool uiValuesEqual(Object? a, Object? b) {
  if (a is num && b is num) return a == b;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!uiValuesEqual(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !uiValuesEqual(a[key], b[key])) return false;
    }
    return true;
  }
  return a == b;
}

/// Longest text [uiStringify] prints for a list or object; past it the
/// text ends in "…". Shared structure can make a small value print huge.
const int kUiPrintMaxLength = 20000;

/// Text form of a value: numbers with grouping and at most two decimals.
String uiStringify(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is num) return uiFormatNumber(value);
  if (value is bool) return value.toString();
  if (value is UiExpressionError) return '—';
  if (value is! List && value is! Map) return value.toString();
  final out = StringBuffer();
  _print(value, out);
  if (out.length <= kUiPrintMaxLength) return out.toString();
  return '${out.toString().substring(0, kUiPrintMaxLength)}…';
}

/// Appends [value]; stops once [out] passes [kUiPrintMaxLength].
void _print(Object? value, StringBuffer out) {
  if (out.length > kUiPrintMaxLength) return;
  if (value is List) {
    for (var i = 0; i < value.length && out.length <= kUiPrintMaxLength; i++) {
      if (i > 0) out.write(', ');
      _print(value[i], out);
    }
  } else if (value is Map) {
    out.write('{');
    var first = true;
    for (final entry in value.entries) {
      if (out.length > kUiPrintMaxLength) break;
      if (!first) out.write(', ');
      first = false;
      out.write('${entry.key}: ');
      _print(entry.value, out);
    }
    out.write('}');
  } else {
    final text = value is String ? value : uiStringify(value);
    final room = kUiPrintMaxLength + 1 - out.length;
    out.write(text.length > room ? text.substring(0, room) : text);
  }
}

/// Text that parses back to exactly [value], for editing: no grouping and
/// no rounding.
String uiEditText(Object? value) {
  if (value is! num) return uiStringify(value);
  if (!value.isFinite) return '';
  if (value == value.truncate() && value.abs() < 1e15) return value.truncate().toString();
  return value.toString();
}

/// `1234.5` → `1,234.5`; non-finite → `—`.
String uiFormatNumber(num value, {int maxDecimals = 2, bool grouping = true}) {
  if (value.isNaN || value.isInfinite) return '—';
  final factor = math.pow(10, maxDecimals);
  final scaled = value * factor;
  final rounded = scaled.isFinite ? scaled.round() / factor : value;
  var text = rounded.toStringAsFixed(maxDecimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  if (text == '-0') text = '0';
  if (!grouping) return text;
  final negative = text.startsWith('-');
  final body = negative ? text.substring(1) : text;
  final dot = body.indexOf('.');
  final whole = dot < 0 ? body : body.substring(0, dot);
  final fraction = dot < 0 ? '' : body.substring(dot);
  final grouped = whole.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '${negative ? '-' : ''}$grouped$fraction';
}

// ---- Tokens ----

enum _Kind { number, string, ident, op, punct, end }

class _Token {
  const _Token(this.kind, this.value);
  final _Kind kind;
  final Object? value;
}

const _operators = [
  '===', '!==', '==', '!=', '<=', '>=', '&&', '||', //
  '<', '>', '+', '-', '*', '/', '%', '^', '!',
];
const _operatorAliases = {'===': '==', '!==': '!='};
const _punct = {'(', ')', '[', ']', ',', '.', '?', ':'};

List<_Token> _tokenize(String source) {
  final tokens = <_Token>[];
  var i = 0;
  while (i < source.length) {
    final char = source[i];
    if (char.trim().isEmpty) {
      i += 1;
      continue;
    }
    final number = RegExp(r'(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?')
        .matchAsPrefix(source, i);
    if (number != null) {
      tokens.add(_Token(_Kind.number, double.parse(number.group(0)!)));
      i = number.end;
      continue;
    }
    if (char == '"' || char == "'") {
      final buffer = StringBuffer();
      var j = i + 1;
      var closed = false;
      while (j < source.length) {
        final c = source[j];
        if (c == '\\' && j + 1 < source.length) {
          buffer.write(source[j + 1]);
          j += 2;
          continue;
        }
        if (c == char) {
          closed = true;
          break;
        }
        buffer.write(c);
        j += 1;
      }
      if (!closed) throw const UiExpressionError('unclosed text');
      tokens.add(_Token(_Kind.string, buffer.toString()));
      i = j + 1;
      continue;
    }
    final ident = RegExp(r'[A-Za-z_][A-Za-z0-9_]*').matchAsPrefix(source, i);
    if (ident != null) {
      tokens.add(_Token(_Kind.ident, ident.group(0)));
      i = ident.end;
      continue;
    }
    final op = _operators.firstWhere(
      (candidate) => source.startsWith(candidate, i),
      orElse: () => '',
    );
    if (op.isNotEmpty) {
      tokens.add(_Token(_Kind.op, _operatorAliases[op] ?? op));
      i += op.length;
      continue;
    }
    if (_punct.contains(char)) {
      tokens.add(_Token(_Kind.punct, char));
      i += 1;
      continue;
    }
    throw UiExpressionError('unexpected "$char"');
  }
  tokens.add(const _Token(_Kind.end, null));
  return tokens;
}

// ---- Parser ----

const _binaryPrecedence = {
  '||': 1, '&&': 2, '==': 3, '!=': 3, //
  '<': 4, '<=': 4, '>': 4, '>=': 4, '+': 5, '-': 5,
  '*': 6, '/': 6, '%': 6, '^': 8,
};
const _keywords = {'true': true, 'false': false, 'null': null};
const _constants = {'pi': math.pi, 'e': math.e};

class _Parser {
  _Parser(this.tokens);
  final List<_Token> tokens;
  int pos = 0;

  _Token get _peek => tokens[pos];

  bool _isPunct(String value) =>
      _peek.kind == _Kind.punct && _peek.value == value;

  void _expect(String value) {
    if (!_isPunct(value)) throw UiExpressionError('expected "$value"');
    pos += 1;
  }

  _Node parse() {
    final node = _conditional();
    if (_peek.kind != _Kind.end) throw const UiExpressionError('unexpected text');
    return node;
  }

  _Node _conditional() {
    final test = _binary(1);
    if (!_isPunct('?')) return test;
    pos += 1;
    final then = _conditional();
    _expect(':');
    return _CondNode(test, then, _conditional());
  }

  _Node _binary(int minPrecedence) {
    var left = _unary();
    while (_peek.kind == _Kind.op) {
      final op = _peek.value as String;
      final precedence = _binaryPrecedence[op];
      if (precedence == null || precedence < minPrecedence) break;
      pos += 1;
      // ^ is right-associative.
      final right = _binary(op == '^' ? precedence : precedence + 1);
      left = _BinaryNode(op, left, right);
    }
    return left;
  }

  _Node _unary() {
    if (_peek.kind == _Kind.op && (_peek.value == '-' || _peek.value == '!')) {
      final op = _peek.value as String;
      pos += 1;
      // -2^2 is -(2^2): the operand binds tighter than unary minus.
      return _UnaryNode(op, _binary(_binaryPrecedence['^']!));
    }
    if (_peek.kind == _Kind.op && _peek.value == '+') {
      pos += 1;
      return _unary();
    }
    return _postfix(_primary());
  }

  _Node _postfix(_Node node) {
    var current = node;
    while (true) {
      if (_isPunct('.')) {
        pos += 1;
        final name = _peek;
        if (name.kind != _Kind.ident) throw const UiExpressionError('expected a name');
        pos += 1;
        current = _MemberNode(current, _Literal(name.value));
      } else if (_isPunct('[')) {
        pos += 1;
        final property = _conditional();
        _expect(']');
        current = _MemberNode(current, property);
      } else {
        return current;
      }
    }
  }

  _Node _primary() {
    final token = _peek;
    switch (token.kind) {
      case _Kind.number:
      case _Kind.string:
        pos += 1;
        return _Literal(token.value);
      case _Kind.ident:
        pos += 1;
        final name = token.value as String;
        if (_isPunct('(')) {
          final fn = _functions[name];
          if (fn == null) throw UiExpressionError('unknown function $name');
          pos += 1;
          final args = <_Node>[];
          if (!_isPunct(')')) {
            while (true) {
              args.add(_conditional());
              if (_isPunct(',')) {
                pos += 1;
                continue;
              }
              break;
            }
          }
          _expect(')');
          return _CallNode(name, fn, args);
        }
        if (_keywords.containsKey(name)) return _Literal(_keywords[name]);
        return _VarNode(name);
      case _Kind.punct:
        if (token.value == '(') {
          pos += 1;
          final inner = _conditional();
          _expect(')');
          return inner;
        }
        if (token.value == '[') {
          pos += 1;
          final items = <_Node>[];
          while (!_isPunct(']')) {
            items.add(_conditional());
            if (_isPunct(',')) {
              pos += 1;
            } else {
              break;
            }
          }
          _expect(']');
          return _ArrayNode(items);
        }
      case _Kind.op:
      case _Kind.end:
        break;
    }
    throw const UiExpressionError('incomplete formula');
  }
}

// ---- Tree ----

sealed class _Node {
  Object? eval(UiScope scope, UiBudget budget);
  void collect(Set<String> names) {}
}

class _Literal extends _Node {
  _Literal(this.value);
  final Object? value;

  @override
  Object? eval(UiScope scope, UiBudget budget) => value;
}

class _VarNode extends _Node {
  _VarNode(this.name);
  final String name;

  @override
  Object? eval(UiScope scope, UiBudget budget) {
    budget.spend();
    if (scope.containsKey(name)) {
      final value = scope[name];
      if (value is UiExpressionError) throw value;
      return value;
    }
    final constant = _constants[name];
    if (constant != null) return constant;
    throw UiExpressionError('$name is not defined');
  }

  @override
  void collect(Set<String> names) {
    if (!_constants.containsKey(name)) names.add(name);
  }
}

class _ArrayNode extends _Node {
  _ArrayNode(this.items);
  final List<_Node> items;

  @override
  Object? eval(UiScope scope, UiBudget budget) {
    budget.spend(items.length + 1);
    final values = [for (final item in items) item.eval(scope, budget)];
    // Nesting a value twice doubles what printing it costs; charge the full
    // size so `[a, a]` repeated cannot grow past the budget.
    for (final value in values) {
      _chargeSize(value, budget);
    }
    return values;
  }

  @override
  void collect(Set<String> names) {
    for (final item in items) {
      item.collect(names);
    }
  }
}

class _UnaryNode extends _Node {
  _UnaryNode(this.op, this.operand);
  final String op;
  final _Node operand;

  @override
  Object? eval(UiScope scope, UiBudget budget) {
    budget.spend();
    final value = operand.eval(scope, budget);
    if (op == '!') return !uiTruthy(value);
    return -_number(value, '-');
  }

  @override
  void collect(Set<String> names) => operand.collect(names);
}

class _BinaryNode extends _Node {
  _BinaryNode(this.op, this.left, this.right);
  final String op;
  final _Node left;
  final _Node right;

  @override
  Object? eval(UiScope scope, UiBudget budget) {
    budget.spend();
    if (op == '&&') {
      final a = left.eval(scope, budget);
      return uiTruthy(a) ? right.eval(scope, budget) : a;
    }
    if (op == '||') {
      final a = left.eval(scope, budget);
      return uiTruthy(a) ? a : right.eval(scope, budget);
    }
    final a = left.eval(scope, budget);
    final b = right.eval(scope, budget);
    switch (op) {
      case '==':
        return uiValuesEqual(a, b);
      case '!=':
        return !uiValuesEqual(a, b);
      case '+':
        if (a is String || b is String) {
          _chargeSize(a, budget);
          _chargeSize(b, budget);
          final text = uiStringify(a) + uiStringify(b);
          if (text.length > kUiTextMaxLength) {
            throw const UiExpressionError('text longer than $kUiTextMaxLength characters');
          }
          budget.spend(text.length ~/ 64);
          return text;
        }
        return _number(a, '+') + _number(b, '+');
      case '-':
        return _number(a, '-') - _number(b, '-');
      case '*':
        return _number(a, '*') * _number(b, '*');
      case '/':
        return _number(a, '/') / _number(b, '/');
      case '%':
        return _number(a, '%').remainder(_number(b, '%'));
      case '^':
        return math.pow(_number(a, '^'), _number(b, '^')).toDouble();
    }
    if (a is String && b is String) {
      final order = a.compareTo(b);
      return switch (op) {
        '<' => order < 0,
        '<=' => order <= 0,
        '>' => order > 0,
        _ => order >= 0,
      };
    }
    final x = _number(a, op);
    final y = _number(b, op);
    return switch (op) {
      '<' => x < y,
      '<=' => x <= y,
      '>' => x > y,
      _ => x >= y,
    };
  }

  @override
  void collect(Set<String> names) {
    left.collect(names);
    right.collect(names);
  }
}

class _CondNode extends _Node {
  _CondNode(this.test, this.then, this.otherwise);
  final _Node test;
  final _Node then;
  final _Node otherwise;

  @override
  Object? eval(UiScope scope, UiBudget budget) {
    budget.spend();
    return uiTruthy(test.eval(scope, budget))
        ? then.eval(scope, budget)
        : otherwise.eval(scope, budget);
  }

  @override
  void collect(Set<String> names) {
    test.collect(names);
    then.collect(names);
    otherwise.collect(names);
  }
}

const _forbiddenMembers = {'__proto__', 'constructor', 'prototype'};

class _MemberNode extends _Node {
  _MemberNode(this.object, this.property);
  final _Node object;
  final _Node property;

  @override
  Object? eval(UiScope scope, UiBudget budget) {
    budget.spend();
    final target = object.eval(scope, budget);
    final key = property.eval(scope, budget);
    if (key is String && _forbiddenMembers.contains(key)) {
      throw UiExpressionError('property $key is not allowed');
    }
    if (target is List || target is String) {
      final length = target is List ? target.length : (target as String).length;
      if (key == 'length') return length;
      if (key is num && key.isFinite && key == key.truncate() && key >= 0 && key < length) {
        final i = key.toInt();
        return target is List ? target[i] : (target as String)[i];
      }
      throw const UiExpressionError('index out of range');
    }
    if (target is Map) {
      final name = key is num ? uiStringify(key) : key;
      if (name is String && target.containsKey(name)) return target[name];
      throw UiExpressionError('no field $name');
    }
    throw const UiExpressionError('not a list or object');
  }

  @override
  void collect(Set<String> names) {
    object.collect(names);
    property.collect(names);
  }
}

typedef _Fn = Object? Function(List<Object?> args, UiBudget budget);

class _CallNode extends _Node {
  _CallNode(this.name, this.fn, this.args);
  final String name;
  final _Fn fn;
  final List<_Node> args;

  @override
  Object? eval(UiScope scope, UiBudget budget) {
    budget.spend();
    return fn([for (final arg in args) arg.eval(scope, budget)], budget);
  }

  @override
  void collect(Set<String> names) {
    for (final arg in args) {
      arg.collect(names);
    }
  }
}

// ---- Functions ----

num _number(Object? value, String context) {
  if (value is num) return value;
  throw UiExpressionError('$context expects numbers');
}

/// A count or digit argument: finite, truncated.
int _whole(num value, String context) {
  if (!value.isFinite) throw UiExpressionError('$context expects a finite number');
  return value.truncate();
}

/// Walks a value, one step per list item and per 64 characters of text, so
/// what printing it would cost is paid before it can be built; stops at the
/// budget.
void _chargeSize(Object? value, UiBudget budget) {
  if (value is String) {
    budget.spend(value.length ~/ 64);
  } else if (value is List) {
    budget.spend(value.length);
    for (final item in value) {
      _chargeSize(item, budget);
    }
  } else if (value is Map) {
    budget.spend(value.length);
    for (final entry in value.entries) {
      _chargeSize(entry.key, budget);
      _chargeSize(entry.value, budget);
    }
  }
}

List<num> _numbers(String name, List<Object?> args, int min, [int? max]) {
  final upper = max ?? min;
  if (args.length < min || args.length > upper) {
    throw UiExpressionError('$name takes ${min == upper ? min : '$min-$upper'} arguments');
  }
  return [for (final arg in args) _number(arg, name)];
}

_Fn _math(String name, num Function(num) apply) =>
    (args, _) => apply(_numbers(name, args, 1).first).toDouble();

List<num> _list(String name, Object? value, UiBudget budget) {
  if (value is! List) throw UiExpressionError('$name expects a list');
  budget.spend(value.length);
  return [for (final item in value) _number(item, name)];
}

_Fn _extreme(String name, num Function(num, num) pick) => (args, budget) {
      final values = args.length == 1 && args.first is List
          ? _list(name, args.first, budget)
          : [for (final arg in args) _number(arg, name)];
      if (values.isEmpty) throw UiExpressionError('$name of nothing');
      return values.reduce(pick);
    };

double _roundFloat(num value) => (value * 1e10).round() / 1e10;

double _sign(num x) => x > 0 ? 1 : x < 0 ? -1 : 0;

final Map<String, _Fn> _functions = {
  'abs': _math('abs', (x) => x.abs()),
  'sqrt': _math('sqrt', math.sqrt),
  'cbrt': _math('cbrt', (x) => _sign(x) * math.pow(x.abs(), 1 / 3)),
  'floor': _math('floor', (x) => x.floorToDouble()),
  'ceil': _math('ceil', (x) => x.ceilToDouble()),
  'sign': _math('sign', _sign),
  'log': _math('log', math.log),
  'ln': _math('ln', math.log),
  'log10': _math('log10', (x) => math.log(x) / math.ln10),
  'log2': _math('log2', (x) => math.log(x) / math.ln2),
  'exp': _math('exp', math.exp),
  'sin': _math('sin', math.sin),
  'cos': _math('cos', math.cos),
  'tan': _math('tan', math.tan),
  'asin': _math('asin', math.asin),
  'acos': _math('acos', math.acos),
  'atan': _math('atan', math.atan),
  'sinh': _math('sinh', (x) => (math.exp(x) - math.exp(-x)) / 2),
  'cosh': _math('cosh', (x) => (math.exp(x) + math.exp(-x)) / 2),
  'tanh': _math('tanh', (x) {
    final a = math.exp(x);
    final b = math.exp(-x);
    return (a - b) / (a + b);
  }),
  'pow': (args, _) {
    final v = _numbers('pow', args, 2);
    return math.pow(v[0], v[1]).toDouble();
  },
  'min': _extreme('min', math.min),
  'max': _extreme('max', math.max),
  'round': (args, _) {
    final v = _numbers('round', args, 1, 2);
    final digits = (v.length > 1 ? _whole(v[1], 'round') : 0).clamp(-15, 15);
    if (!v[0].isFinite) return v[0];
    final factor = math.pow(10, digits);
    final scaled = v[0] * factor;
    return scaled.isFinite ? scaled.round() / factor : v[0];
  },
  'fixed': (args, _) {
    final v = _numbers('fixed', args, 1, 2);
    if (v[0].isNaN || v[0].isInfinite) return '—';
    final digits = (v.length > 1 ? _whole(v[1], 'fixed') : 0).clamp(0, 10);
    return v[0].toStringAsFixed(digits);
  },
  'clamp': (args, _) {
    final v = _numbers('clamp', args, 3);
    return math.min(v[2], math.max(v[1], v[0]));
  },
  // range(start, end, step = ±1), both ends included.
  'range': (args, budget) {
    final v = _numbers('range', args, 2, 3);
    final start = v[0];
    final end = v[1];
    final step = v.length > 2 ? v[2] : (end >= start ? 1 : -1);
    if (!start.isFinite || !end.isFinite || step == 0 || !step.isFinite || (end - start) / step < 0) {
      throw const UiExpressionError('range needs a step that moves from start to end');
    }
    final span = (end - start) / step + 1e-9;
    if (!span.isFinite || span >= kUiRangeMaxPoints) {
      throw const UiExpressionError('range is limited to $kUiRangeMaxPoints points');
    }
    final count = span.floor() + 1;
    if (count > kUiRangeMaxPoints) {
      throw const UiExpressionError('range is limited to $kUiRangeMaxPoints points');
    }
    budget.spend(count);
    return [for (var i = 0; i < count; i++) _roundFloat(start + i * step)];
  },
  'sum': (args, budget) =>
      _list('sum', args.firstOrNull, budget).fold<num>(0, (a, b) => a + b),
  'avg': (args, budget) {
    final values = _list('avg', args.firstOrNull, budget);
    if (values.isEmpty) throw const UiExpressionError('avg of an empty list');
    return values.fold<num>(0, (a, b) => a + b) / values.length;
  },
  'len': (args, _) {
    final value = args.firstOrNull;
    if (value is List) return value.length;
    if (value is String) return value.length;
    throw const UiExpressionError('len expects a list or text');
  },
  'contains': (args, budget) {
    final container = args.firstOrNull;
    final needle = args.length > 1 ? args[1] : null;
    if (container is String) return container.contains(uiStringify(needle));
    if (container is List) {
      budget.spend(container.length);
      return container.any((item) => uiValuesEqual(item, needle));
    }
    throw const UiExpressionError('contains expects a list or text');
  },
};

/// Function names, for the prompt.
Iterable<String> get kUiExpressionFunctions => _functions.keys;
