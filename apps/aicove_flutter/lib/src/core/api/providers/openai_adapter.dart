/// OpenAI API adapter
library;

import 'dart:convert';

import 'provider_adapter.dart';
import 'zai_compat.dart';

class OpenAIAdapter implements ProviderAdapter {
  static const int _kimiThinkingSafeMaxTokens = 16384;

  @override
  String get name => 'openai';

  @override
  String buildEndpoint(String baseUrl, {required String modelType}) {
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final base = isZaiApiUrl(normalized)
        ? normalized
        : (normalized.endsWith('/v1') ? normalized : '$normalized/v1');

    switch (modelType) {
      case 'embedding':
        return '$base/embeddings';
      case 'tts':
        return '$base/audio/speech';
      case 'stt':
        return '$base/audio/transcriptions';
      case 'image':
        return '$base/images/generations';
      case 'chat':
      default:
        return '$base/chat/completions';
    }
  }

  @override
  Map<String, String> buildHeaders(String apiKey) {
    return {
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    };
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
    final hasTools = tools != null && tools.isNotEmpty;
    final hasCustomMaxTokens = _hasCustomMaxTokens(customConfig);
    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      if (temperature != null) 'temperature': temperature,
      if (topP != null) 'top_p': topP,
      'stream': false,
      if (hasTools) 'tools': tools,
      if (hasTools) 'tool_choice': 'auto',
    };
    if (!hasCustomMaxTokens &&
        _shouldApplyKimiThinkingSafeMaxTokens(
          model: model,
          customConfig: customConfig,
        )) {
      body['max_tokens'] = _kimiThinkingSafeMaxTokens;
    }
    if (customConfig != null && customConfig.isNotEmpty) {
      body.addAll(customConfig);
    }
    if (requestOptions?.toolChoice != null) {
      // The request-owned transport must survive unrelated channel defaults.
      body['messages'] = messages;
      if (hasTools) body['tools'] = tools;
    }
    _applyRequestOptions(body, requestOptions);
    return body;
  }

  void _applyRequestOptions(
    Map<String, dynamic> body,
    ProviderChatRequestOptions? options,
  ) {
    if (options == null) return;
    if (options.toolChoice != null) body['tool_choice'] = options.toolChoice;
    if (options.temperature != null) {
      body['temperature'] = options.temperature;
    }
    if (options.topP != null) body['top_p'] = options.topP;
    if ((options.topK ?? 0) > 0) body['top_k'] = options.topK;
    if ((options.minP ?? 0) > 0) body['min_p'] = options.minP;
    if ((options.topA ?? 0) > 0) body['top_a'] = options.topA;
    if (options.repetitionPenalty != null && options.repetitionPenalty != 1) {
      body['repetition_penalty'] = options.repetitionPenalty;
    }
    if (options.frequencyPenalty != null && options.frequencyPenalty != 0) {
      body['frequency_penalty'] = options.frequencyPenalty;
    }
    if (options.presencePenalty != null && options.presencePenalty != 0) {
      body['presence_penalty'] = options.presencePenalty;
    }
    if ((options.seed ?? -1) >= 0) body['seed'] = options.seed;
    if (options.maxOutputTokens != null) {
      body['max_tokens'] = options.maxOutputTokens;
    }
    final thinkingLevel = options.thinkingLevel;
    if (thinkingLevel != null) {
      final effort = _reasoningEffortFor(thinkingLevel, options.thinkingScheme);
      if (effort != null) body['reasoning_effort'] = effort;
      return;
    }
    final reasoningEffort = options.reasoningEffort?.trim();
    if (reasoningEffort != null &&
        reasoningEffort.isNotEmpty &&
        reasoningEffort != 'auto') {
      body['reasoning_effort'] = reasoningEffort;
    }
  }

  /// 档位 → `reasoning_effort`。返回 null 表示不发该字段。
  String? _reasoningEffortFor(ThinkingLevel level, ThinkingScheme? scheme) {
    final isGeneric = scheme == null || scheme == ThinkingScheme.generic;
    return switch (level) {
      ThinkingLevel.auto => null,
      ThinkingLevel.off => 'none',
      ThinkingLevel.minimal => 'minimal',
      ThinkingLevel.low => 'low',
      ThinkingLevel.medium => 'medium',
      ThinkingLevel.high => 'high',
      ThinkingLevel.xhigh => isGeneric ? 'high' : 'xhigh',
      ThinkingLevel.max => isGeneric ? 'high' : 'max',
    };
  }

  @override
  ApiCallResult parseResponse(Map<String, dynamic> response) {
    String text = '';
    final toolCalls = <ToolCall>[];

    final choices = (response['choices'] as List?) ?? const [];
    if (choices.isNotEmpty) {
      final first = choices.first as Map<String, dynamic>;
      final msg = (first['message'] as Map<String, dynamic>?) ??
          const <String, dynamic>{};
      text = _extractText(msg['content']);

      final rawToolCalls = msg['tool_calls'] as List?;
      if (rawToolCalls != null) {
        for (final tc in rawToolCalls) {
          if (tc is Map<String, dynamic>) {
            toolCalls.add(ToolCall.fromOpenAI(tc));
          }
        }
      }

      if (toolCalls.isEmpty) {
        final functionCall = msg['function_call'] as Map<String, dynamic>?;
        if (functionCall != null) {
          toolCalls.add(ToolCall(
            id: '',
            name: functionCall['name']?.toString() ?? '',
            arguments: _parseArguments(functionCall['arguments']),
            rawArguments: functionCall['arguments'] is String
                ? functionCall['arguments'] as String : null,
          ));
        }
      }
    }

    return ApiCallResult(
      text: text,
      toolResults: const [],
      toolCalls: toolCalls,
      rawResponse: response,
    );
  }

  @override
  List<Map<String, dynamic>> buildToolResultMessages({
    required Map<String, dynamic> assistantMessage,
    required List<ToolResult> toolResults,
  }) {
    final messages = <Map<String, dynamic>>[];
    final hasLegacyFunctionCall = assistantMessage['function_call'] is Map &&
        ((assistantMessage['tool_calls'] as List?)?.isEmpty ?? true);

    messages.add({'role': 'assistant', ...assistantMessage});

    if (hasLegacyFunctionCall) {
      for (final result in toolResults) {
        messages.add({
          'role': 'function',
          'name': result.name,
          'content': result.result,
        });
      }
      return messages;
    }

    for (final result in toolResults) {
      if (result.toolCallId.trim().isNotEmpty) {
        messages.add({
          'role': 'tool',
          'tool_call_id': result.toolCallId,
          'content': result.result,
        });
      } else {
        messages.add({
          'role': 'function',
          'name': result.name,
          'content': result.result,
        });
      }
    }

    return messages;
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

  String _extractText(dynamic content) {
    if (content == null) return '';
    if (content is String) return content;
    if (content is List) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map<String, dynamic>) {
          final text = part['text']?.toString();
          if (text != null) buffer.write(text);
        }
      }
      return buffer.toString();
    }
    return content.toString();
  }

  bool _hasCustomMaxTokens(Map<String, dynamic>? customConfig) {
    if (customConfig == null) return false;
    final raw = customConfig['max_tokens'];
    if (raw is num) return true;
    if (raw is String) return raw.trim().isNotEmpty;
    return false;
  }

  bool _shouldApplyKimiThinkingSafeMaxTokens({
    required String model,
    required Map<String, dynamic>? customConfig,
  }) {
    if (_isThinkingDisabled(customConfig)) {
      return false;
    }

    final normalized = model.trim().toLowerCase();
    return normalized.contains('kimi-k2.5') ||
        normalized.contains('kimi-k2-thinking');
  }

  bool _isThinkingDisabled(Map<String, dynamic>? customConfig) {
    if (customConfig == null) return false;
    final thinking = customConfig['thinking'];
    if (thinking is! Map) return false;
    final type = thinking['type']?.toString().trim().toLowerCase();
    return type == 'disabled';
  }
}
