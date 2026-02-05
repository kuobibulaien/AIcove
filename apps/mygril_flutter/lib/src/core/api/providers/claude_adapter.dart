/// Claude (Anthropic) API 适配器
///
/// 更新记录：
/// - 2026-01-27: 添加 buildToolResultMessages 支持两回合工具调用
library;

import 'provider_adapter.dart';

class ClaudeAdapter implements ProviderAdapter {
  @override
  String get name => 'claude';

  @override
  String buildEndpoint(String baseUrl, {required String modelType}) {
    final normalized = baseUrl.endsWith('/') 
        ? baseUrl.substring(0, baseUrl.length - 1) 
        : baseUrl;
    
    final base = normalized.endsWith('/v1') ? normalized : '$normalized/v1';
    
    switch (modelType) {
      case 'chat':
      default:
        return '$base/messages';
    }
  }

  @override
  Map<String, String> buildHeaders(String apiKey) {
    return {
      'x-api-key': apiKey,
      'Content-Type': 'application/json',
      'anthropic-version': '2023-06-01',
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
    final systemMessages = <String>[];
    final chatMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      final role = (msg['role'] ?? '').toString();
      final content = msg['content'];

      if (role == 'system') {
        if (content is String) {
          systemMessages.add(content);
        }
      } else {
        chatMessages.add({
          'role': role == 'assistant' ? 'assistant' : 'user',
          'content': content,
        });
      }
    }

    // 转换 OpenAI 格式的 tools 为 Anthropic 格式
    List<Map<String, dynamic>>? anthropicTools;
    if (tools != null && tools.isNotEmpty) {
      anthropicTools = tools.map((t) {
        final function = t['function'] as Map<String, dynamic>? ?? {};
        return {
          'name': function['name'],
          'description': function['description'],
          'input_schema': function['parameters'],
        };
      }).toList();
    }

    return {
      'model': model,
      'messages': chatMessages,
      if (systemMessages.isNotEmpty) 'system': systemMessages.join('\n\n'),
      'max_tokens': customConfig?['max_tokens'] ?? 4096,
      if (temperature != null) 'temperature': temperature,
      if (topP != null) 'top_p': topP,
      if (anthropicTools != null) 'tools': anthropicTools,
      ...?customConfig,
    };
  }

  @override
  ApiCallResult parseResponse(Map<String, dynamic> response) {
    String text = '';
    final toolCalls = <ToolCall>[];
    final content = (response['content'] as List?) ?? const [];
    
    for (final block in content) {
      if (block is Map<String, dynamic>) {
        final type = block['type'] as String?;
        if (type == 'text') {
          text += (block['text'] ?? '').toString();
        } else if (type == 'tool_use') {
          // Anthropic 格式的工具调用
          toolCalls.add(ToolCall(
            id: block['id'] as String? ?? '',
            name: block['name'] as String? ?? '',
            arguments: (block['input'] as Map<String, dynamic>?) ?? {},
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
    // Anthropic 格式：
    // 1. assistant 消息的 content 是一个数组，包含 tool_use blocks
    // 2. 用户消息的 content 是一个数组，包含 tool_result blocks
    final messages = <Map<String, dynamic>>[];

    // 重建 assistant 消息（包含 tool_use blocks）
    // 从 rawResponse 提取原始 content
    final rawContent = assistantMessage['content'];
    final assistantContent = <Map<String, dynamic>>[];

    if (rawContent is List) {
      for (final block in rawContent) {
        if (block is Map<String, dynamic>) {
          assistantContent.add(block);
        }
      }
    }

    messages.add({
      'role': 'assistant',
      'content': assistantContent,
    });

    // 添加 user 消息，包含 tool_result blocks
    final toolResultBlocks = <Map<String, dynamic>>[];
    for (final result in toolResults) {
      toolResultBlocks.add({
        'type': 'tool_result',
        'tool_use_id': result.toolCallId,
        'content': result.result,
      });
    }

    messages.add({
      'role': 'user',
      'content': toolResultBlocks,
    });

    return messages;
  }
}
