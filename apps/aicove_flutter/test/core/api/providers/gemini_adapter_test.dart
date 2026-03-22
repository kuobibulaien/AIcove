import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';

void main() {
  group('GeminiAdapter', () {
    test('buildRequestBody should merge multiple system messages', () {
      final adapter = GeminiAdapter();

      final body = adapter.buildRequestBody(
        model: 'gemini-2.0-flash',
        messages: <Map<String, dynamic>>[
          {
            'role': 'system',
            'content': '你是贴心助手。',
          },
          {
            'role': 'assistant',
            'content': '上一轮回复',
          },
          {
            'role': 'system',
            'content':
                '<system-reminder>\ncurrent_datetime=2026-03-23 10:30:15 +08:00 (周日)\n</system-reminder>',
          },
          {
            'role': 'user',
            'content': '现在几点了？',
          },
        ],
      );

      final systemInstruction = ((((body['systemInstruction']
                  as Map<String, dynamic>)['parts'] as List<dynamic>)
              .first as Map<String, dynamic>)['text'])
          .toString();

      expect(systemInstruction, contains('你是贴心助手。'));
      expect(systemInstruction, contains('<system-reminder>'));
      expect(
        systemInstruction,
        contains('current_datetime=2026-03-23 10:30:15'),
      );

      final contents = body['contents'] as List<dynamic>;
      expect(contents, hasLength(2));
      expect(
        (contents.first as Map<String, dynamic>)['role'],
        'model',
      );
      expect(
        (contents.last as Map<String, dynamic>)['role'],
        'user',
      );
    });
  });
}
