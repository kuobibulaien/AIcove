/// Lenient JSON reader for model-written interactive blocks (ADR0073 交互组件).
///
/// Models routinely deviate from strict JSON. This reader accepts trailing
/// commas, `//` and `/* */` comments, raw line breaks inside strings, and
/// unescaped double quotes inside text (typical when Chinese prose uses ASCII
/// quotes): a quote ends a string only when the next significant character is
/// structural (`,` `}` `]` `:`) or the input ends there. Rules follow
/// DEEIX-Chat `packages/core/src/ui-block/partial-json.ts`. Objects and
/// arrays still open when the input ends are closed there (models often drop
/// the final `]}`); callers only pass text whose fence has closed. A cut-off
/// string or a key without a value is still a [FormatException].
///
/// Objects become `Map<String, Object?>`, arrays `List<Object?>`.
Object? readLenientJson(String text) => _Reader(text).readDocument();

/// Far deeper than any block allows; a hard stop for hostile input.
const int kUiJsonMaxDepth = 64;

class _Reader {
  _Reader(this.text);

  final String text;
  int index = 0;
  int depth = 0;

  Object? readDocument() {
    _skip();
    if (_atEnd) throw const FormatException('empty JSON');
    final value = _value();
    _skip();
    if (!_atEnd) throw FormatException('unexpected text after JSON', text, index);
    return value;
  }

  bool get _atEnd => index >= text.length;

  String get _char => text[index];

  void _skip() {
    while (!_atEnd) {
      final char = _char;
      if (char == ' ' || char == '\n' || char == '\r' || char == '\t' ||
          char == '\uFEFF') {
        index += 1;
      } else if (text.startsWith('//', index)) {
        final end = text.indexOf('\n', index);
        index = end < 0 ? text.length : end + 1;
      } else if (text.startsWith('/*', index)) {
        final end = text.indexOf('*/', index + 2);
        if (end < 0) throw FormatException('unclosed comment', text, index);
        index = end + 2;
      } else {
        return;
      }
    }
  }

  Object? _value() {
    _skip();
    if (_atEnd) throw FormatException('unexpected end of JSON', text, index);
    final char = _char;
    if (char == '{') return _nested(_object);
    if (char == '[') return _nested(_array);
    if (char == '"') return _string();
    if (char == '-' || _isDigit(char)) return _number();
    for (final (word, value) in const [
      ('true', true),
      ('false', false),
      ('null', null),
    ]) {
      if (text.startsWith(word, index)) {
        index += word.length;
        return value;
      }
    }
    throw FormatException('unexpected character', text, index);
  }

  T _nested<T>(T Function() read) {
    depth += 1;
    if (depth > kUiJsonMaxDepth) {
      throw FormatException('JSON nested too deep', text, index);
    }
    try {
      return read();
    } finally {
      depth -= 1;
    }
  }

  Map<String, Object?> _object() {
    index += 1; // {
    final result = <String, Object?>{};
    while (true) {
      _skip();
      if (_atEnd || _char == '}') {
        if (!_atEnd) index += 1;
        return result;
      }
      if (_char == ',') {
        index += 1;
        continue;
      }
      final key = _char == '"' ? _string() : _bareKey();
      _skip();
      if (_atEnd || _char != ':') {
        throw FormatException('expected ":"', text, index);
      }
      index += 1;
      result[key] = _value();
      _skip();
      if (!_atEnd && _char == ',') index += 1;
    }
  }

  /// Unquoted keys (`{title: "x"}`) are read as identifiers.
  String _bareKey() {
    final start = index;
    while (!_atEnd && RegExp(r'[A-Za-z0-9_$-]').hasMatch(_char)) {
      index += 1;
    }
    if (index == start) throw FormatException('expected a key', text, index);
    return text.substring(start, index);
  }

  List<Object?> _array() {
    index += 1; // [
    final result = <Object?>[];
    while (true) {
      _skip();
      if (_atEnd || _char == ']') {
        if (!_atEnd) index += 1;
        return result;
      }
      if (_char == ',') {
        index += 1;
        continue;
      }
      result.add(_value());
      _skip();
      if (!_atEnd && _char == ',') index += 1;
    }
  }

  String _string() {
    index += 1; // opening quote
    final buffer = StringBuffer();
    while (true) {
      if (_atEnd) throw FormatException('unclosed string', text, index);
      final char = _char;
      if (char == '\\') {
        if (index + 1 >= text.length) {
          throw FormatException('unclosed string', text, index);
        }
        final escape = text[index + 1];
        index += 2;
        switch (escape) {
          case 'n':
            buffer.write('\n');
          case 't':
            buffer.write('\t');
          case 'r':
            buffer.write('\r');
          case 'b':
            buffer.write('\b');
          case 'f':
            buffer.write('\f');
          case 'u':
            final hex = index + 4 <= text.length
                ? text.substring(index, index + 4)
                : '';
            final code = int.tryParse(hex, radix: 16);
            if (hex.length == 4 && code != null) {
              buffer.writeCharCode(code);
              index += 4;
            } else {
              buffer.write('u');
            }
          default:
            buffer.write(escape);
        }
        continue;
      }
      if (char == '"') {
        if (_quoteEndsString(index + 1)) {
          index += 1;
          return buffer.toString();
        }
        buffer.write('"');
        index += 1;
        continue;
      }
      buffer.write(char);
      index += 1;
    }
  }

  /// A quote closes the string when what follows is structural or nothing.
  bool _quoteEndsString(int from) {
    var cursor = from;
    while (cursor < text.length) {
      final char = text[cursor];
      if (char == ' ' || char == '\n' || char == '\r' || char == '\t') {
        cursor += 1;
        continue;
      }
      if (text.startsWith('//', cursor) || text.startsWith('/*', cursor)) {
        return true;
      }
      return char == ',' || char == '}' || char == ']' || char == ':';
    }
    return true;
  }

  num _number() {
    final match = RegExp(r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?')
        .matchAsPrefix(text, index);
    if (match == null) throw FormatException('bad number', text, index);
    index = match.end;
    final source = match.group(0)!;
    final value = int.tryParse(source) ?? double.parse(source);
    // 1e999 parses to infinity, which JSON cannot hold or write back.
    if (!value.isFinite) throw FormatException('number out of range', text, index);
    return value;
  }

  static bool _isDigit(String char) =>
      char.codeUnitAt(0) >= 0x30 && char.codeUnitAt(0) <= 0x39;
}
