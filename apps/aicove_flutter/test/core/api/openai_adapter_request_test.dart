import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/providers/openai_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';

void main() {
  group('OpenAIAdapter.buildEndpoint', () {
    final adapter = OpenAIAdapter();

    test('z.ai 官方 paas/v4 基址不再额外拼接 /v1', () {
      final endpoint = adapter.buildEndpoint(
        'https://api.z.ai/api/paas/v4',
        modelType: 'chat',
      );

      expect(endpoint, 'https://api.z.ai/api/paas/v4/chat/completions');
    });

    test('普通 OpenAI 兼容基址仍保持补 /v1 行为', () {
      final endpoint = adapter.buildEndpoint(
        'https://api.example.com',
        modelType: 'chat',
      );

      expect(endpoint, 'https://api.example.com/v1/chat/completions');
    });
  });

  group('OpenAIAdapter.buildRequestBody', () {
    final adapter = OpenAIAdapter();

    test('为 kimi-k2.5 默认注入安全 max_tokens，避免只返回 reasoning_content', () {
      final body = adapter.buildRequestBody(
        model: 'kimi-k2.5',
        messages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': '你好'}
        ],
      );

      expect(body['max_tokens'], 16384);
    });

    test('用户手动设置 max_tokens 时保持用户配置优先', () {
      final body = adapter.buildRequestBody(
        model: 'kimi-k2.5',
        messages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': '你好'}
        ],
        customConfig: const <String, dynamic>{
          'max_tokens': 32768,
        },
      );

      expect(body['max_tokens'], 32768);
    });

    test('thinking 已关闭时不再额外注入安全 max_tokens', () {
      final body = adapter.buildRequestBody(
        model: 'kimi-k2.5',
        messages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': '你好'}
        ],
        customConfig: const <String, dynamic>{
          'thinking': <String, dynamic>{'type': 'disabled'},
        },
      );

      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('非 Kimi 模型保持原行为，不自动注入 max_tokens', () {
      final body = adapter.buildRequestBody(
        model: 'gpt-4o-mini',
        messages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': '你好'}
        ],
      );

      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('SillyTavern request options override channel config at final payload',
        () {
      final body = adapter.buildRequestBody(
        model: 'custom-model',
        messages: const <Map<String, dynamic>>[
          {'role': 'user', 'content': 'continue'}
        ],
        temperature: 0.3,
        customConfig: const <String, dynamic>{
          'temperature': 0.4,
          'max_tokens': 2048,
        },
        requestOptions: const ProviderChatRequestOptions(
          temperature: 1.1,
          topP: 0.95,
          topK: 64,
          minP: 0.08,
          topA: 0.2,
          repetitionPenalty: 1.05,
          frequencyPenalty: 0.1,
          presencePenalty: 0.2,
          seed: 42,
          maxOutputTokens: 30000,
          reasoningEffort: 'high',
        ),
      );

      expect(body, containsPair('temperature', 1.1));
      expect(body, containsPair('top_p', 0.95));
      expect(body, containsPair('top_k', 64));
      expect(body, containsPair('min_p', 0.08));
      expect(body, containsPair('top_a', 0.2));
      expect(body, containsPair('repetition_penalty', 1.05));
      expect(body, containsPair('frequency_penalty', 0.1));
      expect(body, containsPair('presence_penalty', 0.2));
      expect(body, containsPair('seed', 42));
      expect(body, containsPair('max_tokens', 30000));
      expect(body, containsPair('reasoning_effort', 'high'));
    });
  });
}
