/// Claude (Anthropic) API 适配器
///
/// 更新记录：
/// - 2026-01-27: 添加 buildToolResultMessages 支持两回合工具调用
library;

import 'dart:convert';

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
        final normalizedContent = _normalizeContent(content);
        if (normalizedContent == null) {
          continue;
        }
        chatMessages.add({
          'role': role == 'assistant' ? 'assistant' : 'user',
          'content': normalizedContent,
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

  dynamic _normalizeContent(dynamic content) {
    if (content == null) return null;
    if (content is String) return content;

    if (content is List) {
      final converted = _convertPartsToClaudeContent(content);
      if (converted.isNotEmpty) {
        return converted;
      }
      return null;
    }

    if (content is Map<String, dynamic>) {
      final parts = content['parts'];
      if (parts is List) {
        final converted = _convertPartsToClaudeContent(parts);
        if (converted.isNotEmpty) {
          return converted;
        }
      }
      return content;
    }

    return content.toString();
  }

  List<Map<String, dynamic>> _convertPartsToClaudeContent(List rawParts) {
    final content = <Map<String, dynamic>>[];
    for (final part in rawParts) {
      if (part is String) {
        if (part.trim().isEmpty) continue;
        content.add({'type': 'text', 'text': part});
        continue;
      }
      if (part is! Map) continue;
      final converted = _convertPartToClaudeBlock(part);
      if (converted != null) {
        content.add(converted);
      }
    }
    return content;
  }

  Map<String, dynamic>? _convertPartToClaudeBlock(Map rawPart) {
    final part = <String, dynamic>{};
    rawPart.forEach((key, value) {
      part[key.toString()] = value;
    });

    final type = (part['type'] ?? '').toString();
    if (type == 'text') {
      final text = part['text']?.toString();
      if (text == null || text.trim().isEmpty) return null;
      return {'type': 'text', 'text': text};
    }

    if (type == 'image_url') {
      final imageUrl = part['image_url'];
      final url =
          imageUrl is Map ? imageUrl['url']?.toString() : imageUrl?.toString();
      if (url == null || url.trim().isEmpty) return null;
      final trimmed = url.trim();

      if (trimmed.startsWith('data:')) {
        final parsed = _parseDataUri(trimmed);
        if (parsed == null) return null;
        return {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': parsed.$1,
            'data': parsed.$2,
          },
        };
      }

      return {
        'type': 'image',
        'source': {
          'type': 'url',
          'url': trimmed,
        },
      };
    }

    if (part.containsKey('type')) {
      return Map<String, dynamic>.from(part);
    }
    return null;
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
}
