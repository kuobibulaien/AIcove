library;

import 'dart:convert';

import '../../../core/api/providers/provider_adapter.dart' show ToolCall;

class ChatToolFallbackParser {
  const ChatToolFallbackParser();

  List<ToolCall> extractFallbackToolCalls(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const <ToolCall>[];

    final calls = <ToolCall>[];
    var callIndex = 0;

    final executeRegex = RegExp(
      r'<execute_tool>\s*([\s\S]*?)\s*</execute_tool>',
      caseSensitive: false,
    );
    for (final match in executeRegex.allMatches(trimmed)) {
      final raw = match.group(1)?.trim() ?? '';
      final currentCallIndex = ++callIndex;
      final parsedPayload =
          _parseExecuteToolPayload(raw, callIndex: currentCallIndex);
      if (parsedPayload != null) {
        calls.add(parsedPayload);
        continue;
      }
      final parsed =
          _parseFallbackFunctionCall(raw, callIndex: currentCallIndex);
      if (parsed != null) {
        calls.add(parsed);
      }
    }

    if (calls.isNotEmpty) {
      return calls;
    }

    final actionPayloadCall =
        _parseActionPayloadFallbackToolCall(trimmed, callIndex: ++callIndex);
    if (actionPayloadCall != null) {
      calls.add(actionPayloadCall);
      return calls;
    }

    final promptBlockCall =
        _parsePromptBlockFallbackToolCall(trimmed, callIndex: ++callIndex);
    if (promptBlockCall != null) {
      calls.add(promptBlockCall);
    }

    return calls;
  }

  Map<String, dynamic>? tryParseJsonMap(String raw) {
    final candidates = <String>{};
    final trimmed = raw.trim();
    if (trimmed.isNotEmpty) {
      candidates.add(trimmed);
    }

    final unfenced = _stripMarkdownCodeFence(trimmed);
    if (unfenced.isNotEmpty) {
      candidates.add(unfenced);
    }

    final wrapped = _extractFirstJsonObject(unfenced);
    if (wrapped != null && wrapped.isNotEmpty) {
      candidates.add(wrapped);
    }

    for (final candidate in candidates) {
      try {
        final decoded = jsonDecode(candidate);
        if (decoded is Map) {
          return toStringDynamicMap(decoded);
        }
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Map<String, dynamic> toStringDynamicMap(Map raw) {
    final map = <String, dynamic>{};
    raw.forEach((key, value) {
      map[key.toString()] = value;
    });
    return map;
  }

  ToolCall? _parseExecuteToolPayload(String raw, {required int callIndex}) {
    final payload = tryParseJsonMap(raw);
    if (payload == null) return null;

    final toolName = _readFirstNonEmptyString(payload, const [
      'tool_name',
      'toolName',
      'tool',
      'action',
      'function_name',
      'functionName',
      'name',
    ]);
    final toolCode = _readFirstNonEmptyString(payload, const [
      'tool_code',
      'toolCode',
      'code',
      'call',
      'function_call',
    ]);
    if (toolName.isEmpty && toolCode.isEmpty) return null;

    if (toolCode.isNotEmpty) {
      String? expression;
      if (toolName.isNotEmpty) {
        expression = _extractNamedFunctionCall(toolCode, toolName);
      }
      expression ??= _extractNamedFunctionCall(toolCode, 'draw_image');
      expression ??= _extractAnyFunctionCall(toolCode);

      if (expression != null) {
        final parsed =
            _parseFallbackFunctionCall(expression, callIndex: callIndex);
        if (parsed != null) {
          if (toolName.isNotEmpty && parsed.name != toolName) {
            return ToolCall(
              id: parsed.id,
              name: toolName,
              arguments: _normalizeToolArguments(toolName, parsed.arguments),
            );
          }
          return parsed;
        }
      }
    }

    final fallbackName =
        toolName.isNotEmpty ? toolName : _inferToolNameFromPayload(payload);
    if (fallbackName.isNotEmpty) {
      final args = _extractToolArgumentsFromPayload(payload, fallbackName);
      if (args.isNotEmpty) {
        return ToolCall(
          id: 'fallback_execute_$callIndex',
          name: fallbackName,
          arguments: _normalizeToolArguments(fallbackName, args),
        );
      }
    }

    return null;
  }

  ToolCall? _parseActionPayloadFallbackToolCall(
    String text, {
    required int callIndex,
  }) {
    final payload = tryParseJsonMap(text);
    if (payload == null) return null;

    final action = _readFirstNonEmptyString(payload, const [
      'action',
      'tool_name',
      'toolName',
      'tool',
      'function_name',
      'functionName',
      'name',
    ]);
    if (action.isEmpty) return null;

    final args = _extractToolArgumentsFromPayload(payload, action);
    if (args.isEmpty) return null;

    return ToolCall(
      id: 'fallback_action_$callIndex',
      name: action,
      arguments: _normalizeToolArguments(action, args),
    );
  }

  String _readFirstNonEmptyString(
    Map<String, dynamic> payload,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = payload[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  String _inferToolNameFromPayload(Map<String, dynamic> payload) {
    final action = payload['action']?.toString().trim() ?? '';
    if (action.isNotEmpty) return action;

    final prompt = payload['prompt']?.toString().trim() ?? '';
    if (prompt.isNotEmpty) return 'draw_image';

    const keys = <String>[
      'arguments',
      'args',
      'tool_args',
      'toolArgs',
      'params',
      'parameters',
    ];
    for (final key in keys) {
      final argMap =
          _coerceToolArgumentsMap(payload[key], defaultToolName: 'draw_image');
      final promptInArgs = argMap?['prompt']?.toString().trim() ?? '';
      if (promptInArgs.isNotEmpty) return 'draw_image';
    }

    return '';
  }

  Map<String, dynamic> _extractToolArgumentsFromPayload(
    Map<String, dynamic> payload,
    String toolName,
  ) {
    final args = <String, dynamic>{};

    const containerKeys = <String>[
      'arguments',
      'args',
      'tool_args',
      'toolArgs',
      'action_input',
      'actionInput',
      'params',
      'parameters',
      'tool_input',
      'toolInput',
    ];
    for (final key in containerKeys) {
      final parsed = _coerceToolArgumentsMap(
        payload[key],
        defaultToolName: toolName,
      );
      if (parsed != null && parsed.isNotEmpty) {
        args.addAll(parsed);
      }
    }

    const knownRootKeys = <String>[
      'prompt',
      'negative_prompt',
      'width',
      'height',
      'size',
      'steps',
      'guidance_scale',
      'count',
      'seed',
      'sampler',
    ];
    for (final key in knownRootKeys) {
      if (payload.containsKey(key)) {
        args[key] = payload[key];
      }
    }

    return args;
  }

  Map<String, dynamic>? _coerceToolArgumentsMap(
    dynamic raw, {
    required String defaultToolName,
  }) {
    if (raw == null) return null;

    if (raw is Map) {
      return toStringDynamicMap(raw);
    }

    if (raw is! String) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    final jsonMap = tryParseJsonMap(trimmed);
    if (jsonMap != null) {
      return jsonMap;
    }

    final directCall = _parseFallbackFunctionCall(trimmed, callIndex: 0);
    if (directCall != null && directCall.arguments.isNotEmpty) {
      return directCall.arguments;
    }

    final wrappedCall = _parseFallbackFunctionCall(
      '$defaultToolName($trimmed)',
      callIndex: 0,
    );
    if (wrappedCall != null && wrappedCall.arguments.isNotEmpty) {
      return wrappedCall.arguments;
    }

    return null;
  }

  String _stripMarkdownCodeFence(String raw) {
    final match = RegExp(
      r'^```(?:[a-zA-Z0-9_-]+)?\s*([\s\S]*?)\s*```$',
      caseSensitive: false,
    ).firstMatch(raw.trim());
    if (match == null) return raw.trim();
    return (match.group(1) ?? '').trim();
  }

  String? _extractFirstJsonObject(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    return raw.substring(start, end + 1).trim();
  }

  String? _extractAnyFunctionCall(String text) {
    final regex = RegExp(r'\b([a-zA-Z_][a-zA-Z0-9_]*)\s*\(');
    String? firstExpression;
    for (final match in regex.allMatches(text)) {
      final openParenIndex = text.indexOf('(', match.start);
      if (openParenIndex < 0) continue;
      final closeParenIndex = _findMatchingParen(text, openParenIndex);
      if (closeParenIndex < 0) continue;
      final expression = text.substring(match.start, closeParenIndex + 1);
      firstExpression ??= expression;
      final parsed = _parseFallbackFunctionCall(expression, callIndex: 0);
      if (parsed != null && parsed.arguments.isNotEmpty) {
        return expression;
      }
    }
    return firstExpression;
  }

  String? _extractNamedFunctionCall(String text, String functionName) {
    final regex = RegExp('\\b${RegExp.escape(functionName)}\\s*\\(',
        caseSensitive: false);
    for (final match in regex.allMatches(text)) {
      final openParenIndex = text.indexOf('(', match.start);
      if (openParenIndex < 0) continue;
      final closeParenIndex = _findMatchingParen(text, openParenIndex);
      if (closeParenIndex < 0) continue;
      return text.substring(match.start, closeParenIndex + 1);
    }
    return null;
  }

  int _findMatchingParen(String text, int openParenIndex) {
    var depth = 0;
    String? quote;
    var escape = false;

    for (var i = openParenIndex; i < text.length; i++) {
      final ch = text[i];

      if (escape) {
        escape = false;
        continue;
      }

      if (quote != null) {
        if (ch == '\\') {
          escape = true;
          continue;
        }
        if (ch == quote) {
          quote = null;
        }
        continue;
      }

      if (ch == '"' || ch == '\'') {
        quote = ch;
        continue;
      }

      if (ch == '(') {
        depth++;
        continue;
      }
      if (ch == ')') {
        depth--;
        if (depth == 0) {
          return i;
        }
      }
    }

    return -1;
  }

  ToolCall? _parsePromptBlockFallbackToolCall(
    String text, {
    required int callIndex,
  }) {
    final lines = const LineSplitter().convert(text);
    final buffers = <String, StringBuffer>{
      'prompt': StringBuffer(),
      'negative_prompt': StringBuffer(),
      'size': StringBuffer(),
    };

    String? current;
    final marker = RegExp(
      r'^\s*\[(prompt|negative_prompt|size)\]\s*$',
      caseSensitive: false,
    );

    for (final line in lines) {
      final m = marker.firstMatch(line);
      if (m != null) {
        current = m.group(1)!.toLowerCase();
        continue;
      }
      if (current == null) continue;
      buffers[current]!.writeln(line);
    }

    final prompt = buffers['prompt']!.toString().trim();
    if (prompt.isEmpty) return null;

    final args = <String, dynamic>{'prompt': prompt};
    final negative = buffers['negative_prompt']!.toString().trim();
    if (negative.isNotEmpty) {
      args['negative_prompt'] = negative;
    }
    final sizeRaw = buffers['size']!.toString().trim();
    if (sizeRaw.isNotEmpty) {
      args['size'] = sizeRaw;
    }

    return ToolCall(
      id: 'fallback_prompt_$callIndex',
      name: 'draw_image',
      arguments: _normalizeToolArguments('draw_image', args),
    );
  }

  ToolCall? _parseFallbackFunctionCall(String text, {required int callIndex}) {
    final cleaned = text
        .replaceAll(RegExp(r'^```[a-zA-Z0-9_-]*\s*'), '')
        .replaceAll(RegExp(r'\s*```$'), '')
        .trim();
    final match = RegExp(
      r'^([a-zA-Z_][a-zA-Z0-9_]*)\s*\(([\s\S]*)\)$',
    ).firstMatch(cleaned);
    if (match == null) return null;

    final name = match.group(1)!.trim();
    final argsBody = match.group(2)?.trim() ?? '';
    final arguments = <String, dynamic>{};

    if (argsBody.isNotEmpty) {
      final parts = _splitTopLevelArguments(argsBody);
      for (final part in parts) {
        final eqIndex = part.indexOf('=');
        if (eqIndex <= 0) continue;
        final key = part.substring(0, eqIndex).trim();
        if (key.isEmpty) continue;
        final rawValue = part.substring(eqIndex + 1).trim();
        arguments[key] = _parseToolArgumentValue(rawValue);
      }
    }

    return ToolCall(
      id: 'fallback_call_$callIndex',
      name: name,
      arguments: _normalizeToolArguments(name, arguments),
    );
  }

  List<String> _splitTopLevelArguments(String input) {
    final parts = <String>[];
    var current = StringBuffer();
    String? quote;
    var escape = false;
    var depth = 0;

    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);

      if (escape) {
        current.write(ch);
        escape = false;
        continue;
      }

      if (quote != null) {
        if (ch == '\\') {
          current.write(ch);
          escape = true;
          continue;
        }
        current.write(ch);
        if (ch == quote) {
          quote = null;
        }
        continue;
      }

      if (ch == '"' || ch == '\'') {
        quote = ch;
        current.write(ch);
        continue;
      }

      if (ch == '(' || ch == '[' || ch == '{') {
        depth += 1;
        current.write(ch);
        continue;
      }
      if (ch == ')' || ch == ']' || ch == '}') {
        if (depth > 0) depth -= 1;
        current.write(ch);
        continue;
      }

      if (ch == ',' && depth == 0) {
        final segment = current.toString().trim();
        if (segment.isNotEmpty) {
          parts.add(segment);
        }
        current = StringBuffer();
        continue;
      }

      current.write(ch);
    }

    final tail = current.toString().trim();
    if (tail.isNotEmpty) {
      parts.add(tail);
    }
    return parts;
  }

  dynamic _parseToolArgumentValue(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';

    if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
      try {
        return jsonDecode(value);
      } catch (_) {
        return value
            .substring(1, value.length - 1)
            .replaceAll(r'\"', '"')
            .replaceAll(r'\\', '\\');
      }
    }

    if (value.startsWith('\'') && value.endsWith('\'') && value.length >= 2) {
      return value
          .substring(1, value.length - 1)
          .replaceAll(r"\'", "'")
          .replaceAll(r'\\', '\\');
    }

    if (value == 'true') return true;
    if (value == 'false') return false;

    final intValue = int.tryParse(value);
    if (intValue != null) return intValue;

    final doubleValue = double.tryParse(value);
    if (doubleValue != null) return doubleValue;

    return value;
  }

  Map<String, dynamic> _normalizeToolArguments(
    String toolName,
    Map<String, dynamic> arguments,
  ) {
    final normalized = Map<String, dynamic>.from(arguments);
    if (toolName != 'draw_image') {
      return normalized;
    }

    final sizeRaw = normalized['size']?.toString().trim();
    final widthMissing = normalized['width'] == null;
    final heightMissing = normalized['height'] == null;
    if ((widthMissing || heightMissing) &&
        sizeRaw != null &&
        sizeRaw.isNotEmpty) {
      final parsed = _parseImageSize(sizeRaw);
      if (parsed != null) {
        normalized['width'] ??= parsed[0];
        normalized['height'] ??= parsed[1];
      }
    }

    final prompt = normalized['prompt']?.toString().trim() ?? '';
    if (prompt.isNotEmpty) {
      normalized['prompt'] = prompt;
    }
    final negative = normalized['negative_prompt']?.toString().trim() ?? '';
    if (negative.isNotEmpty) {
      normalized['negative_prompt'] = negative;
    }

    return normalized;
  }

  List<int>? _parseImageSize(String raw) {
    final match =
        RegExp(r'^\s*(\d{2,5})\s*[xX]\s*(\d{2,5})\s*$').firstMatch(raw);
    if (match == null) return null;
    final width = int.tryParse(match.group(1)!);
    final height = int.tryParse(match.group(2)!);
    if (width == null || height == null) return null;
    return [width, height];
  }
}
