/// OpenAI API 适配器
///
/// 更新记录：
/// - 2026-01-27: 添加 buildToolResultMessages 支持两回合工具调用
library;

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
    return {
      'model': model,
      'messages': messages,
      if (temperature != null) 'temperature': temperature,
      if (topP != null) 'top_p': topP,
      'stream': false,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
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
      final msg =
          (first['message'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
      text = (msg['content'] ?? '').toString();

      // 解析 tool_calls
      final rawToolCalls = msg['tool_calls'] as List?;
      if (rawToolCalls != null) {
        for (final tc in rawToolCalls) {
          if (tc is Map<String, dynamic>) {
            toolCalls.add(ToolCall.fromOpenAI(tc));
          }
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
    // OpenAI 格式：
    // 1. assistant 消息（带 tool_calls）
    // 2. 每个工具调用对应一条 role=tool 消息
    final messages = <Map<String, dynamic>>[];

    // 添加 assistant 消息（确保有 role 字段）
    messages.add({
      'role': 'assistant',
      ...assistantMessage,
    });

    // 添加 tool 结果消息
    for (final result in toolResults) {
      messages.add({
        'role': 'tool',
        'tool_call_id': result.toolCallId,
        'content': result.result,
      });
    }

    return messages;
  }
}
