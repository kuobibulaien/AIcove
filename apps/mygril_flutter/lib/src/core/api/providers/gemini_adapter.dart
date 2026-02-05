/// Gemini (Google) API 适配器
///
/// 更新记录：
/// - 2026-01-27: 添加 buildToolResultMessages 支持两回合工具调用
library;

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
    return {
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
    final contents = <Map<String, dynamic>>[];
    String? systemInstruction;

    for (final msg in messages) {
      final role = (msg['role'] ?? '').toString();
      final content = msg['content'];

      if (role == 'system') {
        systemInstruction = content is String ? content : content.toString();
      } else {
        contents.add({
          'role': role == 'assistant' ? 'model' : 'user',
          'parts': [
            {'text': content is String ? content : content.toString()}
          ],
        });
      }
    }

    // 转换 OpenAI 格式的 tools 为 Gemini 格式
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

    final body = {
      'contents': contents,
      if (systemInstruction != null) 
        'systemInstruction': {
          'parts': [{'text': systemInstruction}]
        },
      if (geminiTools != null)
        'tools': [{'functionDeclarations': geminiTools}],
      'generationConfig': {
        if (temperature != null) 'temperature': temperature,
        if (topP != null) 'topP': topP,
        ...?customConfig?['generationConfig'] as Map<String, dynamic>?,
      },
    };

    return body;
  }

  @override
  ApiCallResult parseResponse(Map<String, dynamic> response) {
    String text = '';
    final toolCalls = <ToolCall>[];
    final candidates = (response['candidates'] as List?) ?? const [];
    
    if (candidates.isNotEmpty) {
      final first = candidates.first as Map<String, dynamic>;
      final content = first['content'] as Map<String, dynamic>?;
      final parts = (content?['parts'] as List?) ?? const [];
      
      for (final part in parts) {
        if (part is Map<String, dynamic>) {
          if (part.containsKey('text')) {
            text += (part['text'] ?? '').toString();
          } else if (part.containsKey('functionCall')) {
            // Gemini 格式的工具调用
            final fc = part['functionCall'] as Map<String, dynamic>? ?? {};
            toolCalls.add(ToolCall(
              id: '', // Gemini 不返回 ID
              name: fc['name'] as String? ?? '',
              arguments: (fc['args'] as Map<String, dynamic>?) ?? {},
            ));
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
    // Gemini 格式：
    // 1. model 角色消息，包含 functionCall parts
    // 2. user 角色消息，包含 functionResponse parts
    // 注意：Gemini 使用 'model' 而不是 'assistant'
    final messages = <Map<String, dynamic>>[];

    // 重建 model 消息（包含 functionCall parts）
    // 从 rawResponse 的 candidates[0].content.parts 提取
    final rawContent = assistantMessage['content'];
    final modelParts = <Map<String, dynamic>>[];

    if (rawContent is Map<String, dynamic>) {
      final parts = rawContent['parts'] as List?;
      if (parts != null) {
        for (final part in parts) {
          if (part is Map<String, dynamic>) {
            modelParts.add(part);
          }
        }
      }
    }

    messages.add({
      'role': 'model',
      'parts': modelParts,
    });

    // 添加 user 消息，包含 functionResponse parts
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
}
