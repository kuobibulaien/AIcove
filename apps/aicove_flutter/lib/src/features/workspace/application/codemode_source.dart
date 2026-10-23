import 'dart:convert';

// Ported from pi-mono packages/codemode/src/source.ts (MIT, 476a303).
class CodemodeSource {
  const CodemodeSource(this.code, {this.maxOutputTokens = 10000, this.timeout});
  final String code;
  final int maxOutputTokens;
  final Duration? timeout;
}

CodemodeSource parseCodemodeSource(String input) {
  if (input.trim().isEmpty)
    throw const FormatException('Expected non-empty JavaScript source');
  final lines = input.split('\n');
  const prefix = '// @options:';
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trimLeft().startsWith(prefix))
      throw FormatException(
        '@options must be the first line; found on line ${i + 1}',
      );
  }
  if (!lines.first.trimLeft().startsWith(prefix)) return CodemodeSource(input);
  final newline = input.indexOf('\n');
  if (newline < 0 || input.substring(newline).trim().isEmpty)
    throw const FormatException(
      '@options must be followed by JavaScript source',
    );
  final options = jsonDecode(lines.first.trimLeft().substring(prefix.length));
  if (options is! Map)
    throw const FormatException('@options must be a JSON object');
  for (final key in options.keys) {
    if (!['max_output_tokens', 'timeout_ms'].contains(key))
      throw FormatException('Unsupported @options field: $key');
  }
  final tokens = options['max_output_tokens'] ?? 10000;
  final ms = options['timeout_ms'];
  if (tokens is! int || tokens < 0 || tokens > 9007199254740991)
    throw const FormatException(
      'max_output_tokens must be a non-negative safe integer',
    );
  if (ms != null && (ms is! int || ms <= 0 || ms > 2147483647))
    throw const FormatException(
      'timeout_ms must be a positive integer up to 2147483647',
    );
  return CodemodeSource(
    input.substring(newline),
    maxOutputTokens: tokens,
    timeout: ms == null ? null : Duration(milliseconds: ms as int),
  );
}
