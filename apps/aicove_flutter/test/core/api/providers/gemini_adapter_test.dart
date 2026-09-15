import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';

void main() {
  group('GeminiAdapter', () {
    test(
        'buildRequestBody should merge system messages and keep user reminder in contents',
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

    test('parseResponse should keep thought parts hidden from visible text',
        () {
      final adapter = GeminiAdapter();

      final result = adapter.parseResponse(
        <String, dynamic>{
          'candidates': <Map<String, dynamic>>[
            <String, dynamic>{
              'content': <String, dynamic>{
                'role': 'model',
                'parts': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'text': '先想一下',
                    'thought': true,
                  },
                  <String, dynamic>{
                    'text': '你好呀',
                  },
                  <String, dynamic>{
                    'text': '，今天过得怎么样？',
                  },
                ],
              },
            },
          ],
        },
      );

      expect(result.text, '你好呀，今天过得怎么样？');
      expect(result.hiddenThoughtParts, hasLength(1));
      expect(result.hiddenThoughtParts.first['text'], '先想一下');
      expect(result.hiddenThoughtParts.first['thought'], isTrue);
    });

    test('use_sysprompt false keeps every system node in ordered contents', () {
      final body = GeminiAdapter().buildRequestBody(
        model: 'gemini-2.0-flash',
        messages: const <Map<String, dynamic>>[
          {'role': 'system', 'content': 'first system'},
          {'role': 'user', 'content': 'question'},
          {'role': 'system', 'content': 'late system'},
        ],
        requestOptions: const ProviderChatRequestOptions(
          useSystemPrompt: false,
          temperature: 1,
          topP: 0.98,
          topK: 64,
          frequencyPenalty: 0.1,
          presencePenalty: 0.2,
          seed: 42,
          maxOutputTokens: 30000,
        ),
        customConfig: const <String, dynamic>{
          'generationConfig': <String, dynamic>{
            'topK': 1,
            'maxOutputTokens': 1,
          },
        },
      );

      expect(body.containsKey('systemInstruction'), isFalse);
      final contents = body['contents'] as List<dynamic>;
      expect(contents.map((item) => item['role']),
          <dynamic>['user', 'user', 'user']);
      final generationConfig = body['generationConfig'] as Map<String, dynamic>;
      expect(generationConfig, containsPair('temperature', 1));
      expect(generationConfig, containsPair('topP', 0.98));
      expect(generationConfig, containsPair('topK', 64));
      expect(generationConfig, containsPair('frequencyPenalty', 0.1));
      expect(generationConfig, containsPair('presencePenalty', 0.2));
      expect(generationConfig, containsPair('seed', 42));
      expect(generationConfig, containsPair('maxOutputTokens', 30000));
    });
  });
}
