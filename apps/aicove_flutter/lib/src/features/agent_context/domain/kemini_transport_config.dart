/// Reads companion metadata and selects preset scripts for the runtime.
class KeminiTransportConfig {
  static const ateScriptId = '9e566fbb-e8c8-4bd1-8816-f902ff175b83';
  static const scriptId = '2c7d747c-22d4-4e8b-95f8-5620b552fe6e';

  static Map<String, dynamic> read(Map extensions) {
    Map<String, dynamic> skipped(String diagnostic) => {
      'enabled': false,
      'diagnostics': [diagnostic],
    };
    try {
      final rawHelper = extensions['tavern_helper'];
      final helper = rawHelper is List
          ? Map.fromEntries(
              rawHelper
                  .whereType<List>()
                  .where((pair) => pair.length == 2)
                  .map((pair) => MapEntry(pair[0], pair[1])),
            )
          : rawHelper;
      if (helper == null) return skipped('transport_unrecognized');
      if (helper is! Map) return skipped('transport_config_read_failed');
      final scripts = helper['scripts'];
      if (scripts == null) return skipped('transport_unrecognized');
      if (scripts is! List) return skipped('transport_config_read_failed');
      bool isAte(Map item) {
        final content = item['content'];
        if (content is String &&
            content.contains('__antiTruncationFetchPatch__')) {
          return false;
        }
        return item['id'] == ateScriptId ||
            item['id'] == '09647ac7-5a12-4706-95f0-0781a6ed869d' ||
            (content is String &&
                const [
                  '__ATE_FETCH_HOOK__',
                  'AntiTruncationEngine',
                  'prepareRequestBody',
                  '__antiTruncationSelfTest',
                ].any(content.contains));
      }

      bool executable(Map item) {
        final content = item['content'];
        return item['enabled'] == true &&
            item['id'] != 'f0801c1a-3b0f-4e1c-82b6-f0f8990fbde6' &&
            content is String &&
            !content.contains('regex_bind/inject.js') &&
            content.trim().isNotEmpty &&
            content.trim() != 'synthetic' &&
            !content.contains('Imported JavaScript must not execute');
      }

      final matches = scripts.whereType<Map>().where((item) {
        final content = item['content'];
        return isAte(item) ||
            item['id'] == scriptId ||
            (content is String &&
                (content.contains('__antiTruncationFetchPatch__') ||
                    content.contains('__keminiAntiTruncation__') ||
                    content.contains('keminiCompanion')));
      }).toList();
      if (matches.isEmpty) {
        final enabledScripts = scripts
            .whereType<Map>()
            .where(executable)
            .toList();
        if (enabledScripts.isEmpty) return skipped('transport_unrecognized');
        return {
          'protocol': 'custom_script_v1',
          'enabled': true,
          'scripts': enabledScripts,
          'diagnostics': <String>[],
        };
      }
      final enabled = matches.where((item) => item['enabled'] == true);
      if (enabled.isEmpty) {
        final remaining = scripts.whereType<Map>().where(executable).toList();
        if (remaining.isEmpty) return skipped('transport_disabled');
        return {
          'protocol': 'custom_script_v1',
          'enabled': true,
          'scripts': remaining,
          'diagnostics': <String>[],
        };
      }
      final script = enabled.first;
      final source = script['content'];
      final data = script['data'];
      if (source is! String || (data != null && data is! Map)) {
        return skipped('transport_config_read_failed');
      }
      if (isAte(script)) {
        final settings = _readAteSettings(source);
        // Literal template bodies are configuration data, not executable code.
        final rules = RegExp(r'perspectiveRules\s*=\s*`([^`]*)`')
            .allMatches(source)
            .map(
              (match) => match[1]!
                  .replaceAll(r'\n', '\n')
                  .replaceAll(r'\r', '\r')
                  .replaceAll(r'\t', '\t'),
            )
            .toList();
        return {
          'protocol': 'ate_buffer_v1',
          'allScripts': scripts.whereType<Map>().where(executable).toList(),
          'enabled': settings.mode != 'NONE',
          'mode': settings.mode,
          'prefix': settings.prefix,
          'contentKey': settings.contentKey,
          if (!source.contains('Imported JavaScript must not execute') &&
              _hasAteEngine(source))
            'scriptSource': source,
          'scripts': scripts
              .whereType<Map>()
              .where(
                (item) =>
                    !identical(item, script) &&
                    !isAte(item) &&
                    executable(item),
              )
              .toList(),
          'perspectiveRules': rules.length == 3 ? rules : <String>[],
          'diagnostics': <String>[
            if (settings.mode == 'NONE') 'transport_disabled',
          ],
        };
      }
      final stored = data is Map ? data['keminiCompanion'] : null;
      if (stored != null && stored is! Map) {
        return skipped('transport_config_read_failed');
      }
      final setting = stored is Map ? stored['antiTruncationEnabled'] : null;
      if (setting != null && setting is! bool) {
        return skipped('transport_config_read_failed');
      }
      if (setting == false ||
          (data is Map &&
              (data['universalAntiTruncation'] == false ||
                  data['universalAntiTruncation'] == 'false'))) {
        return skipped('transport_disabled');
      }
      // Read a literal only; missing/new script syntax uses the append fallback.
      final anchor =
          RegExp(
            r'''const\s+transportControlAnchor\s*=\s*["']([^"'\r\n]*)["']\s*;''',
          ).firstMatch(source)?.group(1) ??
          '';
      return {
        'protocol': 'content_tool_v1',
        'enabled': true,
        if (source.contains('universalAntiTruncation'))
          'storageKey': 'universalAntiTruncation',
        'anchor': anchor,
        'scripts': scripts
            .whereType<Map>()
            .where((item) => !identical(item, script) && executable(item))
            .toList(),
        'diagnostics': [if (anchor.isEmpty) 'transport_anchor_missing'],
      };
    } catch (_) {
      return skipped('transport_config_read_failed');
    }
  }

  static bool _hasAteEngine(String source) {
    final tokens = _tokens(source);
    for (var i = 0; i + 1 < tokens.length; i++) {
      if ((tokens[i] == 'function' && tokens[i + 1] == 'prepareRequestBody') ||
          (tokens[i] == 'class' && tokens[i + 1] == 'AntiTruncationEngine')) {
        return true;
      }
    }
    return false;
  }

  static ({String mode, String prefix, String contentKey}) _readAteSettings(
    String source,
  ) {
    final tokens = _tokens(source);
    Map<String, String>? fields;
    for (var i = 0; i + 2 < tokens.length; i++) {
      if (tokens[i] != 'CONFIG' ||
          tokens[i + 1] != '=' ||
          (i > 0 && tokens[i - 1] == '.')) {
        continue;
      }
      if (tokens[i + 2] != '{') {
        throw const FormatException('ATE CONFIG must be an object literal');
      }
      fields = {};
      var depth = 1;
      var segment = <String>[];
      void readField() {
        if (segment.isEmpty) return;
        final key = _literalString(segment.first) ?? segment.first;
        if (key == '.') {
          throw const FormatException(
            'ATE CONFIG spreads are not literal settings',
          );
        }
        if (!const {'mode', 'prefix', 'toolPrefix'}.contains(key)) return;
        if (segment.length != 3 || segment[1] != ':') {
          throw const FormatException('ATE setting must be a string literal');
        }
        final value = _literalString(segment[2]);
        if (value == null) {
          throw const FormatException('ATE setting must be a string literal');
        }
        fields![key] = value;
      }

      var closed = false;
      for (var j = i + 3; j < tokens.length; j++) {
        final token = tokens[j];
        if (const {'{', '[', '('}.contains(token)) depth++;
        if (const {'}', ']', ')'}.contains(token)) depth--;
        if (depth == 0) {
          readField();
          closed = true;
          break;
        }
        if (depth == 1 && token == ',') {
          readField();
          segment = [];
        } else {
          segment.add(token);
        }
      }
      if (!closed) throw const FormatException('Unclosed ATE CONFIG');
      break;
    }
    String? declaredLiteral(String name) {
      for (var i = 0; i + 2 < tokens.length; i++) {
        if (tokens[i] == name &&
            tokens[i + 1] == '=' &&
            i > 0 &&
            const {'const', 'let', 'var'}.contains(tokens[i - 1]) &&
            (i + 3 == tokens.length ||
                const {';', ','}.contains(tokens[i + 3]))) {
          return _literalString(tokens[i + 2]);
        }
      }
      return null;
    }

    final mode = fields?['mode'] ?? 'AUTO_TOOL';
    final prefix =
        fields?['prefix'] ??
        fields?['toolPrefix'] ??
        declaredLiteral('DEFAULT_TOOL_PREFIX') ??
        'view_file_stream_';
    if (!const {'AUTO_TOOL', 'FORCED_SPECIFIC_TOOL', 'NONE'}.contains(mode) ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,40}$').hasMatch(prefix)) {
      throw const FormatException('Invalid ATE mode or tool prefix');
    }
    return (
      mode: mode,
      prefix: prefix,
      contentKey: declaredLiteral('PRIMARY_CONTENT_KEY') ?? 'buffer_content',
    );
  }

  // Lex only the data declaration. Comments and string/template bodies cannot
  // impersonate CONFIG; no expression is evaluated or executed.
  static List<String> _tokens(String source) {
    final result = <String>[];
    var i = 0;
    final whitespace = RegExp(r'\s');
    final identifier = RegExp(r'[a-zA-Z0-9_$]');
    while (i < source.length) {
      final ch = source[i];
      if (whitespace.hasMatch(ch)) {
        i++;
        continue;
      }
      if (source.startsWith('//', i)) {
        final end = source.indexOf('\n', i + 2);
        i = end < 0 ? source.length : end + 1;
        continue;
      }
      if (source.startsWith('/*', i)) {
        final end = source.indexOf('*/', i + 2);
        i = end < 0 ? source.length : end + 2;
        continue;
      }
      // Regex bodies may contain quotes and braces; keep them opaque too.
      if (ch == '/' &&
          (result.isEmpty ||
              const {
                '=',
                '(',
                '[',
                '{',
                ',',
                ':',
                ';',
                '!',
                '?',
                '|',
                '&',
                '>',
                'return',
              }.contains(result.last))) {
        final start = i++;
        var inClass = false;
        var closed = false;
        while (i < source.length && source[i] != '\n' && source[i] != '\r') {
          if (source[i] == r'\') {
            i += 2;
            continue;
          }
          if (source[i] == '[') inClass = true;
          if (source[i] == ']') inClass = false;
          if (source[i++] == '/' && !inClass) {
            closed = true;
            break;
          }
        }
        if (closed) {
          while (i < source.length && identifier.hasMatch(source[i])) {
            i++;
          }
          result.add(source.substring(start, i));
          continue;
        }
        i = start;
      }
      final start = i++;
      if (ch == '"' || ch == "'" || ch == '`') {
        while (i < source.length) {
          if (source[i] == r'\') {
            i += 2;
            continue;
          }
          if (source[i++] == ch) break;
        }
      } else if (identifier.hasMatch(ch)) {
        while (i < source.length && identifier.hasMatch(source[i])) {
          i++;
        }
      }
      result.add(
        source.substring(start, i > source.length ? source.length : i),
      );
    }
    return result;
  }

  static String? _literalString(String token) {
    if (token.length < 2 ||
        !const {'"', "'"}.contains(token[0]) ||
        token[token.length - 1] != token[0]) {
      return null;
    }
    final result = StringBuffer();
    const escapes = {
      'n': '\n',
      'r': '\r',
      't': '\t',
      'b': '\b',
      'f': '\f',
      '\\': '\\',
      '"': '"',
      "'": "'",
      '/': '/',
    };
    for (var i = 1; i < token.length - 1; i++) {
      var ch = token[i];
      if (ch != r'\') {
        result.write(ch);
        continue;
      }
      if (++i >= token.length - 1) {
        throw const FormatException('Invalid string escape');
      }
      ch = token[i];
      if (ch == 'u' || ch == 'x') {
        final width = ch == 'u' ? 4 : 2;
        if (i + width >= token.length - 1) {
          throw const FormatException('Invalid string escape');
        }
        final hex = token.substring(i + 1, i + 1 + width);
        if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
          throw const FormatException('Invalid string escape');
        }
        result.writeCharCode(int.parse(hex, radix: 16));
        i += width;
      } else {
        if (!escapes.containsKey(ch)) {
          throw const FormatException('Unsupported string escape');
        }
        result.write(escapes[ch]);
      }
    }
    return result.toString();
  }
}
