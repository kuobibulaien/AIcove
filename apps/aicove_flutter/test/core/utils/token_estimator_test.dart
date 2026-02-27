import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/utils/token_estimator.dart';

void main() {
  group('truncateMessagesToFit tool-call integrity', () {
    test('drops leading orphan tool message after truncation', () {
      final truncated = truncateMessagesToFit(
        messages: <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'assistant',
            'content': '',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call_1',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'lookup_weather',
                  'arguments': '{}',
                },
              },
            ],
          },
          <String, dynamic>{
            'role': 'tool',
            'tool_call_id': 'call_1',
            'content': '{"ok":true}',
          },
          <String, dynamic>{
            'role': 'user',
            'content': 'hi',
          },
        ],
        maxContextTokens: 14,
        reserveTokens: 0,
      );

      expect(truncated.map((m) => m['role']).toList(), <String>['user']);
    });

    test('keeps assistant/tool pair when both are retained', () {
      final truncated = truncateMessagesToFit(
        messages: <Map<String, dynamic>>[
          <String, dynamic>{
            'role': 'assistant',
            'content': '',
            'tool_calls': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'call_1',
                'type': 'function',
                'function': <String, dynamic>{
                  'name': 'lookup_weather',
                  'arguments': '{}',
                },
              },
            ],
          },
          <String, dynamic>{
            'role': 'tool',
            'tool_call_id': 'call_1',
            'content': '{"ok":true}',
          },
          <String, dynamic>{
            'role': 'user',
            'content': 'hi',
          },
        ],
        maxContextTokens: 18,
        reserveTokens: 0,
      );

      expect(
        truncated.map((m) => m['role']).toList(),
        <String>['assistant', 'tool', 'user'],
      );
    });
  });
}
