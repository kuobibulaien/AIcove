import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/providers/claude_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';

void main() {
  group('ClaudeAdapter', () {
    test('only leading system nodes become system prompt', () {
      final body = ClaudeAdapter().buildRequestBody(
        model: 'claude-sonnet-4-5',
        messages: const <Map<String, dynamic>>[
          {'role': 'system', 'content': 'leading'},
          {'role': 'user', 'content': 'question'},
          {'role': 'system', 'content': 'late'},
          {'role': 'assistant', 'content': 'prefill'},
        ],
        requestOptions: const ProviderChatRequestOptions(
          useSystemPrompt: true,
          topK: 64,
          maxOutputTokens: 30000,
        ),
        customConfig: const <String, dynamic>{
          'top_k': 1,
          'max_tokens': 1,
        },
      );

      expect(body['system'], 'leading');
      expect(body['messages'], <Map<String, dynamic>>[
        {'role': 'user', 'content': 'question\n\nlate'},
        {'role': 'assistant', 'content': 'prefill'},
      ]);
      expect(body['top_k'], 64);
      expect(body['max_tokens'], 30000);
    });

    test('use_sysprompt false converts all system nodes to user messages', () {
      final body = ClaudeAdapter().buildRequestBody(
        model: 'claude-sonnet-4-5',
        messages: const <Map<String, dynamic>>[
          {'role': 'system', 'content': 'one'},
          {'role': 'system', 'content': 'two'},
          {'role': 'assistant', 'content': 'prefill'},
        ],
        requestOptions: const ProviderChatRequestOptions(
          useSystemPrompt: false,
        ),
      );

      expect(body.containsKey('system'), isFalse);
      expect(body['messages'], <Map<String, dynamic>>[
        {'role': 'user', 'content': 'one\n\ntwo'},
        {'role': 'assistant', 'content': 'prefill'},
      ]);
    });
  });
}
