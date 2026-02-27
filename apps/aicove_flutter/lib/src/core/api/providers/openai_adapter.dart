/// OpenAI API adapter
library;

import 'dart:convert';

import 'provider_adapter.dart';

class OpenAIAdapter implements ProviderAdapter {
  @override
  String get name => 'openai';

  @override
  String buildEndpoint(String baseUrl, {required String modelType}) {
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final base = normalized.endsWith('/v1') ? normalized : '$normalized/v1';

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
  }) {
    final hasTools = tools != null && tools.isNotEmpty;
    return {
      'model': model,
      'messages': messages,
      if (temperature != null) 'temperature': temperature,
      if (topP != null) 'top_p': topP,
      'stream': false,
      if (hasTools) 'tools': tools,
      if (hasTools) 'tool_choice': 'auto',
      ...?customConfig,
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
}
