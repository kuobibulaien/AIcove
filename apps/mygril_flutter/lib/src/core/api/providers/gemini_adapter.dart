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
  }) {
    final contents = <Map<String, dynamic>>[];
    String? systemInstruction;

    for (final msg in messages) {
      final role = (msg['role'] ?? '').toString();
      if (role == 'system') {
        final content = msg['content'];
        if (content != null) {
          systemInstruction = content is String ? content : content.toString();
        }
        continue;
      }

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

    final body = {
      'contents': contents,
      if (systemInstruction != null)
        'systemInstruction': {
          'parts': [
            {'text': systemInstruction}
          ]
        },
      if (geminiTools != null)
        'tools': [
          {'functionDeclarations': geminiTools}
        ],
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
        if (part is! Map<String, dynamic>) continue;
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
}
