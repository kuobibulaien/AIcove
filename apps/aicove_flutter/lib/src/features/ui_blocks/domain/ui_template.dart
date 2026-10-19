import 'ui_expression.dart';

/// A prop string with `{formula}` holes (ADR0073 交互组件).
///
///     "{round(monthly)}"   one hole and nothing else: the raw value
///     "共 {years} 年"       mixed text: numbers print with grouping and at
///                          most two decimals; a failing hole prints "—"
///     "{{literal}}"        doubled braces are literal braces
class UiTemplate {
  UiTemplate._(this.source, this._segments);

  final String source;
  final List<Object> _segments; // String or UiExpression

  /// True when the whole string is a single hole: the result keeps its type.
  bool get raw => _segments.length == 1 && _segments.single is UiExpression;

  Set<String> get variables => {
        for (final segment in _segments)
          if (segment is UiExpression) ...segment.variables,
      };

  /// Null for plain text (no holes). Throws [UiExpressionError] when a hole
  /// does not parse or a brace is left open.
  static UiTemplate? compile(String source) {
    if (!source.contains('{')) {
      return null;
    }
    final segments = <Object>[];
    final text = StringBuffer();
    var i = 0;
    while (i < source.length) {
      final char = source[i];
      if (char == '{' && source.startsWith('{{', i)) {
        text.write('{');
        i += 2;
        continue;
      }
      if (char == '}' && source.startsWith('}}', i)) {
        text.write('}');
        i += 2;
        continue;
      }
      if (char == '{') {
        final end = _closingBrace(source, i + 1);
        if (end < 0) throw const UiExpressionError('unclosed "{"');
        if (text.isNotEmpty) {
          segments.add(text.toString());
          text.clear();
        }
        segments.add(UiExpression.parse(source.substring(i + 1, end).trim()));
        i = end + 1;
        continue;
      }
      text.write(char);
      i += 1;
    }
    if (text.isNotEmpty) segments.add(text.toString());
    if (!segments.any((segment) => segment is UiExpression)) return null;
    return UiTemplate._(source, segments);
  }

  /// Finds the `}` that closes a hole, skipping quoted text inside it.
  static int _closingBrace(String source, int from) {
    String? quote;
    for (var i = from; i < source.length; i++) {
      final char = source[i];
      if (quote != null) {
        if (char == '\\') {
          i += 1;
        } else if (char == quote) {
          quote = null;
        }
        continue;
      }
      if (char == '"' || char == "'") {
        quote = char;
      } else if (char == '}') {
        return i;
      }
    }
    return -1;
  }

  /// A single hole throws on error; mixed text prints "—" for that hole.
  Object? evaluate(UiScope scope, UiBudget budget) {
    if (raw) return (_segments.single as UiExpression).evaluate(scope, budget);
    final out = StringBuffer();
    for (final segment in _segments) {
      if (segment is String) {
        out.write(segment);
        continue;
      }
      try {
        out.write(uiStringify((segment as UiExpression).evaluate(scope, budget)));
      } on UiExpressionError {
        out.write('—');
      }
    }
    return out.toString();
  }
}

/// A formula written with or without its braces: `"{a > 1}"` or `"a > 1"`.
String unwrapUiFormula(String source) {
  final trimmed = source.trim();
  if (trimmed.startsWith('{') &&
      trimmed.endsWith('}') &&
      !trimmed.startsWith('{{')) {
    return trimmed.substring(1, trimmed.length - 1).trim();
  }
  return trimmed;
}
