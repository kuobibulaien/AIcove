/// Gemini (Google) API adapter
library;

import 'dart:convert';

import 'provider_adapter.dart';

class GeminiAdapter implements ProviderAdapter {
  @override
  String get name => 'gemini';

  @override
  String buildEndpoint(String baseUrl, {required String modelType}) {
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;

    switch (modelType) {
      case 'chat':
      default:
        return normalized;
    }
  }

  @override
  Map<String, String> buildHeaders(String apiKey) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    final trimmed = apiKey.trim();
    if (trimmed.isNotEmpty) {
      headers['x-goog-api-key'] = trimmed;
    }
    return headers;
  }

  @override
  Map<String, dynamic> buildRequestBody({
    required String model,
    required List<Map<String, dynamic>> messages,
    double? temperature,
    double? topP,
    Map<String, dynamic>? customConfig,
    List<Map<String, dynamic>>? tools,
    ProviderChatRequestOptions? requestOptions,
  }) {
    final contents = <Map<String, dynamic>>[];
    final systemInstructions = <String>[];
    final useSystemPrompt = requestOptions?.useSystemPrompt ?? true;
    var reachedChat = false;

    for (final msg in messages) {
      final role = (msg['role'] ?? '').toString();
      if (role == 'system' && useSystemPrompt && !reachedChat) {
        final content = msg['content'];
        if (content != null) {
          final text = content is String ? content : content.toString();
          if (text.trim().isNotEmpty) {
            systemInstructions.add(text);
          }
        }
        continue;
      }
      reachedChat = true;

      final normalizedRole =
          (role == 'assistant' || role == 'model') ? 'model' : 'user';
      final existingParts = _extractParts(msg);
      if (existingParts != null && existingParts.isNotEmpty) {
        contents.add({
          'role': normalizedRole,
          'parts': existingParts,
        });
        continue;
      }

      final content = msg['content'];
      if (content is List) {
        final converted = _convertOpenAiPartsToGeminiParts(content);
        if (converted.isNotEmpty) {
          contents.add({
            'role': normalizedRole,
            'parts': converted,
          });
          continue;
        }
      }
      if (content == null) continue;
      contents.add({
        'role': normalizedRole,
        'parts': [
          {'text': content is String ? content : content.toString()}
        ],
      });
    }

    List<Map<String, dynamic>>? geminiTools;
    if (tools != null && tools.isNotEmpty) {
      geminiTools = tools.map((t) {
        final function = t['function'] as Map<String, dynamic>? ?? {};
        return {
          'name': function['name'],
          'description': function['description'],
          'parameters': function['parameters'],
        };
      }).toList();
    }

    final generationConfig = <String, dynamic>{
      if (temperature != null) 'temperature': temperature,
      if (topP != null) 'topP': topP,
      ...?customConfig?['generationConfig'] as Map<String, dynamic>?,
    };
    _applyRequestOptions(generationConfig, requestOptions);
    final body = <String, dynamic>{
      'contents': contents,
      if (systemInstructions.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': systemInstructions.join('\n\n')}
          ]
        },
      if (geminiTools != null)
        'tools': [
          {'functionDeclarations': geminiTools}
        ],
      if (geminiTools != null && requestOptions?.toolChoice != null)
        'toolConfig': {
          'functionCallingConfig': {'mode': requestOptions!.toolChoice!.toUpperCase()},
        },
      'generationConfig': generationConfig,
    };

    return body;
  }

  void _applyRequestOptions(
    Map<String, dynamic> generationConfig,
    ProviderChatRequestOptions? options,
  ) {
    if (options == null) return;
    if (options.temperature != null) {
      generationConfig['temperature'] = options.temperature;
    }
    if (options.topP != null) generationConfig['topP'] = options.topP;
    if ((options.topK ?? 0) > 0) generationConfig['topK'] = options.topK;
    if (options.frequencyPenalty != null && options.frequencyPenalty != 0) {
      generationConfig['frequencyPenalty'] = options.frequencyPenalty;
    }
    if (options.presencePenalty != null && options.presencePenalty != 0) {
      generationConfig['presencePenalty'] = options.presencePenalty;
    }
    if ((options.seed ?? -1) >= 0) generationConfig['seed'] = options.seed;
    if (options.maxOutputTokens != null) {
      generationConfig['maxOutputTokens'] = options.maxOutputTokens;
    }
    _applyThinking(generationConfig, options);
  }

  static const _thinkingBudgetByLevel = <ThinkingLevel, int>{
    ThinkingLevel.off: 0,
    ThinkingLevel.minimal: 512,
    ThinkingLevel.low: 1024,
    ThinkingLevel.medium: 8192,
    ThinkingLevel.high: -1,
  };

  /// Gemini 3 用 `thinkingLevel`，2.5 用 `thinkingBudget`；两者互斥，
  /// 渠道 customConfig 里已有的同名键会被本设置覆盖。
  void _applyThinking(
    Map<String, dynamic> generationConfig,
    ProviderChatRequestOptions options,
  ) {
    final level = options.thinkingLevel;
    if (level == null || level.isAuto) return;
    final existing = generationConfig['thinkingConfig'];
    final thinkingConfig = <String, dynamic>{
      if (existing is Map) ...Map<String, dynamic>.from(existing),
    }
      ..remove('thinkingLevel')
      ..remove('thinkingBudget')
      ..remove('thinking_level')
      ..remove('thinking_budget');

    if (options.thinkingScheme == ThinkingScheme.geminiLevel) {
      final name = switch (level) {
        ThinkingLevel.xhigh || ThinkingLevel.max => 'HIGH',
        ThinkingLevel.off => 'MINIMAL',
        _ => level.name.toUpperCase(),
      };
      thinkingConfig['thinkingLevel'] = name;
      thinkingConfig['includeThoughts'] = true;
    } else {
      final budget = _thinkingBudgetByLevel[level] ?? -1;
      thinkingConfig['thinkingBudget'] = budget;
      if (budget != 0) thinkingConfig['includeThoughts'] = true;
    }
    generationConfig['thinkingConfig'] = thinkingConfig;
  }

  @override
  ApiCallResult parseResponse(Map<String, dynamic> response) {
    String text = '';
    final toolCalls = <ToolCall>[];
    final hiddenThoughtParts = <Map<String, dynamic>>[];
    final candidates = (response['candidates'] as List?) ?? const [];

    if (candidates.isNotEmpty) {
      final first = candidates.first as Map<String, dynamic>;
      final content = first['content'] as Map<String, dynamic>?;
      final parts = (content?['parts'] as List?) ?? const [];

      for (final part in parts) {
        if (part is! Map<String, dynamic>) continue;
        if (_isThoughtPart(part)) {
          hiddenThoughtParts.add(Map<String, dynamic>.from(part));
          continue;
        }
        if (part.containsKey('text')) {
          text += (part['text'] ?? '').toString();
          continue;
        }
        if (part.containsKey('functionCall')) {
          final fc = part['functionCall'] as Map<String, dynamic>? ?? {};
          toolCalls.add(ToolCall(
            id: fc['id']?.toString() ?? '',
            name: fc['name']?.toString() ?? '',
            arguments: _parseArguments(fc['args']),
            rawArguments: fc['args'] is String ? fc['args'] as String : null,
            thoughtSignature: part['thoughtSignature']?.toString(),
          ));
        }
      }
    }

    return ApiCallResult(
      text: text,
      toolResults: const [],
      toolCalls: toolCalls,
      hiddenThoughtParts: hiddenThoughtParts,
      rawResponse: response,
    );
  }

  @override
  List<Map<String, dynamic>> buildToolResultMessages({
    required Map<String, dynamic> assistantMessage,
    required List<ToolResult> toolResults,
  }) {
    final messages = <Map<String, dynamic>>[];

    final rawContent = assistantMessage['content'];
    final modelParts = <Map<String, dynamic>>[];
    if (rawContent is Map<String, dynamic>) {
      final parts = rawContent['parts'] as List?;
      if (parts != null) {
        for (final part in parts) {
          if (part is Map<String, dynamic>) {
            modelParts.add(Map<String, dynamic>.from(part));
          }
        }
      }
    }

    messages.add({
      'role': 'model',
      'parts': modelParts,
    });

    final responseParts = <Map<String, dynamic>>[];
    for (final result in toolResults) {
      responseParts.add({
        'functionResponse': {
          'name': result.name,
          'response': {
            'result': result.result,
          },
        },
      });
    }

    messages.add({
      'role': 'user',
      'parts': responseParts,
    });

    return messages;
  }

  List<Map<String, dynamic>>? _extractParts(Map<String, dynamic> msg) {
    final rawParts = msg['parts'];
    if (rawParts is List) {
      final parts = <Map<String, dynamic>>[];
      for (final part in rawParts) {
        if (part is Map<String, dynamic>) {
          parts.add(Map<String, dynamic>.from(part));
        }
      }
      return parts;
    }

    final content = msg['content'];
    if (content is List) {
      final converted = _convertOpenAiPartsToGeminiParts(content);
      if (converted.isNotEmpty) {
        return converted;
      }
    }

    if (content is Map<String, dynamic>) {
      final contentParts = content['parts'];
      if (contentParts is List) {
        final parts = <Map<String, dynamic>>[];
        for (final part in contentParts) {
          if (part is Map<String, dynamic>) {
            parts.add(Map<String, dynamic>.from(part));
          }
        }
        return parts;
      }
    }

    return null;
  }

  List<Map<String, dynamic>> _convertOpenAiPartsToGeminiParts(List rawParts) {
    final parts = <Map<String, dynamic>>[];
    for (final part in rawParts) {
      if (part is! Map) continue;
      final converted = _convertOpenAiPartToGeminiPart(part);
      if (converted != null) {
        parts.add(converted);
      }
    }
    return parts;
  }

  Map<String, dynamic>? _convertOpenAiPartToGeminiPart(Map rawPart) {
    final part = <String, dynamic>{};
    rawPart.forEach((key, value) {
      part[key.toString()] = value;
    });

    final type = (part['type'] ?? '').toString();
    if (type == 'text') {
      final text = (part['text'] ?? part['input_text'])?.toString();
      if (text == null || text.trim().isEmpty) return null;
      return {'text': text};
    }

    if (type == 'file') {
      final file = part['file'];
      final data = file is Map ? file['file_data']?.toString() : null;
      if (data == null || !data.startsWith('data:')) return null;
      return _convertImageUrlToGeminiPart(data);
    }

    if (type == 'image_url') {
      final imageUrl = part['image_url'];
      final url =
          imageUrl is Map ? imageUrl['url']?.toString() : imageUrl?.toString();
      if (url == null || url.trim().isEmpty) return null;
      return _convertImageUrlToGeminiPart(url.trim());
    }

    return null;
  }

  Map<String, dynamic>? _convertImageUrlToGeminiPart(String url) {
    if (url.startsWith('data:')) {
      final parsed = _parseDataUri(url);
      if (parsed == null) return null;
      return {
        'inlineData': {
          'mimeType': parsed.$1,
          'data': parsed.$2,
        }
      };
    }

    return {
      'fileData': {
        'mimeType': 'image/jpeg',
        'fileUri': url,
      }
    };
  }

  (String, String)? _parseDataUri(String uri) {
    final commaIndex = uri.indexOf(',');
    if (commaIndex <= 5) return null;

    final header = uri.substring(5, commaIndex);
    final body = uri.substring(commaIndex + 1);
    if (body.trim().isEmpty) return null;

    final headerParts = header.split(';');
    final mimeType = headerParts.isNotEmpty && headerParts.first.isNotEmpty
        ? headerParts.first
        : 'image/jpeg';
    final isBase64 = headerParts.any((p) => p.toLowerCase() == 'base64');

    if (isBase64) {
      return (mimeType, body);
    }

    final decoded = Uri.decodeComponent(body);
    return (mimeType, base64Encode(utf8.encode(decoded)));
  }

  Map<String, dynamic> _parseArguments(dynamic rawArgs) {
    if (rawArgs is Map<String, dynamic>) {
      return Map<String, dynamic>.from(rawArgs);
    }
    if (rawArgs is String && rawArgs.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(rawArgs);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      } catch (_) {
        return <String, dynamic>{};
      }
    }
    return <String, dynamic>{};
  }

  bool _isThoughtPart(Map<String, dynamic> part) {
    final thought = part['thought'];
    if (thought is bool) return thought;
    return thought?.toString().trim().toLowerCase() == 'true';
  }
}
