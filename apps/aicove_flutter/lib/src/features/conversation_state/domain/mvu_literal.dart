/// MVU 命令参数与数据块的字面量解析（ADR0071）。
///
/// 只解析数据，不执行任何脚本：JSON → 宽松 JSON5 → YAML → 纯数字四则运算。
/// `math.*` / `Math.*` 等表达式不求值，由调用方跳过并诊断。
library;

import 'dart:convert';

import 'package:yaml/yaml.dart';

import 'state_path.dart';

class MvuUnsupportedExpression implements Exception {
  const MvuUnsupportedExpression(this.text);
  final String text;
  @override
  String toString() => '不支持的表达式：$text';
}

/// 对齐 MVU `parseCommandValue`。
Object? parseMvuCommandValue(String raw) {
  final trimmed = raw.trim();
  switch (trimmed) {
    case 'true':
      return true;
    case 'false':
      return false;
    case 'null':
    case 'undefined':
      return null;
  }
  final json = _tryJson(trimmed);
  if (json.ok) return json.value;
  if ((trimmed.startsWith('{') && trimmed.endsWith('}')) ||
      (trimmed.startsWith('[') && trimmed.endsWith(']'))) {
    final relaxed = _tryJson(relaxedJsonToStrict(trimmed));
    if (relaxed.ok && (relaxed.value is Map || relaxed.value is List)) {
      return relaxed.value;
    }
  }
  if (trimmed.length >= 2 && trimmed.startsWith("'") && trimmed.endsWith("'")) {
    return trimmed.substring(1, trimmed.length - 1).replaceAll("''", "'");
  }
  if (_mathCall.hasMatch(trimmed)) throw MvuUnsupportedExpression(trimmed);
  if (_arithmetic.hasMatch(trimmed) && _hasDigit.hasMatch(trimmed)) {
    final value = _ArithmeticParser(trimmed).parse();
    if (value != null) return _roundPrecision(value);
  }
  try {
    final yaml = yamlToJson(loadYaml(trimmed));
    if (yaml != null) return yaml;
  } catch (_) {
    // 不是 YAML，按字符串处理。
  }
  return trimQuotesAndBackslashes(raw);
}

/// 解析 InitVar 条目或 JSON Patch 负载：去代码围栏后依次尝试 JSON、宽松 JSON5、YAML。
Object? parseMvuDataBlock(String raw) {
  final text = stripCodeFence(raw).trim();
  if (text.isEmpty) throw const FormatException('内容为空');
  final json = _tryJson(text);
  if (json.ok) return json.value;
  final relaxed = _tryJson(relaxedJsonToStrict(text));
  if (relaxed.ok) return relaxed.value;
  try {
    return yamlToJson(loadYaml(text));
  } on YamlException catch (error) {
    throw FormatException('既不是 JSON 也不是 YAML：${error.message}');
  }
}

String stripCodeFence(String raw) {
  final text = raw.trim();
  final match = _fence.firstMatch(text);
  return match == null ? text : match.group(1)!;
}

Object? yamlToJson(Object? node) {
  if (node is YamlMap || node is Map) {
    return <String, Object?>{
      for (final entry in (node as Map).entries)
        entry.key.toString(): yamlToJson(entry.value),
    };
  }
  if (node is YamlList || node is List) {
    return <Object?>[for (final item in node as List) yamlToJson(item)];
  }
  if (node is YamlScalar) return node.value;
  return node;
}

/// 把宽松 JSON5（注释、单引号、未加引号的键、尾逗号）改写为标准 JSON。
String relaxedJsonToStrict(String source) {
  final out = StringBuffer();
  var i = 0;
  final n = source.length;
  while (i < n) {
    final c = source[i];
    if (c == '"' || c == "'") {
      final quote = c;
      final value = StringBuffer();
      i++;
      while (i < n && source[i] != quote) {
        if (source[i] == '\\' && i + 1 < n) {
          final next = source[i + 1];
          if (next == quote) {
            value.write(quote);
          } else if (next == '\n') {
            // JSON5 行尾续行
          } else {
            value.write('\\$next');
          }
          i += 2;
          continue;
        }
        final ch = source[i];
        if (ch == '"') {
          value.write(r'\"');
        } else if (ch == '\n') {
          value.write(r'\n');
        } else {
          value.write(ch);
        }
        i++;
      }
      out
        ..write('"')
        ..write(value)
        ..write('"');
      i++;
      continue;
    }
    if (c == '/' && i + 1 < n && source[i + 1] == '/') {
      while (i < n && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < n && source[i + 1] == '*') {
      final end = source.indexOf('*/', i + 2);
      i = end < 0 ? n : end + 2;
      continue;
    }
    if (c == ',') {
      final j = _skipSpaceAndComments(source, i + 1);
      if (j < n && (source[j] == '}' || source[j] == ']')) {
        i++;
        continue;
      }
    }
    if (_identStart.hasMatch(c)) {
      var j = i;
      while (j < n && _identPart.hasMatch(source[j])) {
        j++;
      }
      final word = source.substring(i, j);
      var k = j;
      while (k < n && _isSpace(source[k])) {
        k++;
      }
      if (k < n && source[k] == ':' && !_literals.contains(word)) {
        out.write(jsonEncode(word));
      } else {
        out.write(switch (word) {
          'undefined' => 'null',
          'Infinity' || 'NaN' => 'null',
          _ => word,
        });
      }
      i = j;
      continue;
    }
    if (c == '+' && i + 1 < n && RegExp(r'[0-9.]').hasMatch(source[i + 1])) {
      i++;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

({bool ok, Object? value}) _tryJson(String text) {
  try {
    return (ok: true, value: cloneJson(jsonDecode(text)));
  } on FormatException {
    return (ok: false, value: null);
  }
}

num _roundPrecision(num value) {
  if (value is int) return value;
  if (value.isNaN || value.isInfinite) return value;
  final rounded = double.parse(value.toStringAsPrecision(12));
  return rounded == rounded.truncateToDouble() && rounded.abs() < 9e15
      ? rounded.toInt()
      : rounded;
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

int _skipSpaceAndComments(String source, int from) {
  var j = from;
  final n = source.length;
  while (j < n) {
    if (_isSpace(source[j])) {
      j++;
    } else if (source.startsWith('//', j)) {
      final end = source.indexOf('\n', j);
      j = end < 0 ? n : end + 1;
    } else if (source.startsWith('/*', j)) {
      final end = source.indexOf('*/', j + 2);
      j = end < 0 ? n : end + 2;
    } else {
      break;
    }
  }
  return j;
}

final RegExp _fence = RegExp(r'^```[^\n]*\n([\s\S]*?)\n?```$');
final RegExp _identStart = RegExp(r'[A-Za-z_$\u0080-￿]');
final RegExp _identPart = RegExp(r'[A-Za-z0-9_$\u0080-￿]');
const Set<String> _literals = {'true', 'false', 'null'};
final RegExp _mathCall = RegExp(r'\b(?:math|Math)\s*\.');
final RegExp _arithmetic = RegExp(r'^[\d\s+\-*/%().eE]+$');
final RegExp _hasDigit = RegExp(r'\d');

/// `+ - * / % ( )` 与一元正负号的递归下降求值；格式不对返回 null。
class _ArithmeticParser {
  _ArithmeticParser(this.source);
  final String source;
  int _pos = 0;

  num? parse() {
    try {
      final value = _expression();
      _skip();
      return _pos == source.length ? value : null;
    } on FormatException {
      return null;
    }
  }

  num _expression() {
    var value = _term();
    while (true) {
      _skip();
      if (_eat('+')) {
        value = value + _term();
      } else if (_eat('-')) {
        value = value - _term();
      } else {
        return value;
      }
    }
  }

  num _term() {
    var value = _factor();
    while (true) {
      _skip();
      if (_eat('*')) {
        value = value * _factor();
      } else if (_eat('/')) {
        final divisor = _factor();
        if (divisor == 0) throw const FormatException('除以零');
        value = value / divisor;
      } else if (_eat('%')) {
        final divisor = _factor();
        if (divisor == 0) throw const FormatException('除以零');
        value = value.remainder(divisor);
      } else {
        return value;
      }
    }
  }

  num _factor() {
    _skip();
    if (_eat('+')) return _factor();
    if (_eat('-')) return -_factor();
    if (_eat('(')) {
      final value = _expression();
      _skip();
      if (!_eat(')')) throw const FormatException('缺少右括号');
      return value;
    }
    final match = _number.matchAsPrefix(source, _pos);
    if (match == null) throw const FormatException('缺少数字');
    _pos = match.end;
    return num.parse(match[0]!);
  }

  void _skip() {
    while (_pos < source.length && _isSpace(source[_pos])) {
      _pos++;
    }
  }

  bool _eat(String char) {
    if (_pos < source.length && source[_pos] == char) {
      _pos++;
      return true;
    }
    return false;
  }

  static final RegExp _number = RegExp(r'\d+(?:\.\d*)?(?:[eE][+-]?\d+)?|\.\d+');
}
