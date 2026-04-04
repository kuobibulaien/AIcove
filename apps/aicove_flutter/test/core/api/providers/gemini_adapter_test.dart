import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';

void main() {
  group('GeminiAdapter', () {
    test('buildRequestBody should merge system messages and keep user reminder in contents',
        () {
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
            'role': 'user',
            'content':
                '<system-reminder>\n当前时间为2026-03-23 10:30:15 +08:00 (周日)。自行判断当前与历史对话的关系。\n</system-reminder>',
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
      expect(systemInstruction, isNot(contains('<system-reminder>')));

      final contents = body['contents'] as List<dynamic>;
      expect(contents, hasLength(3));
      expect(
        (contents[0] as Map<String, dynamic>)['role'],
        'model',
      );
      expect(
        (contents[1] as Map<String, dynamic>)['role'],
        'user',
      );
      final reminderParts =
          (contents[1] as Map<String, dynamic>)['parts'] as List;
      expect(
        (reminderParts.first as Map<String, dynamic>)['text'].toString(),
        contains('当前时间为2026-03-23 10:30:15'),
      );
      expect(
        (contents[2] as Map<String, dynamic>)['role'],
        'user',
      );
    });
  });
}
