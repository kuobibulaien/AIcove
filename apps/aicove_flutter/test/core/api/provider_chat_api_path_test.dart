import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/providers/provider_chat_api_path.dart';

void main() {
  group('buildProviderChatEndpoint', () {
    test('OpenAI 聊天地址严格按基础 URL + API 路径拼接，不再自动补 /v1', () {
      final endpoint = buildProviderChatEndpoint(
        provider: 'openai',
        apiBaseUrl: 'https://api.example.com',
        model: 'gpt-4o-mini',
      );

      expect(endpoint, 'https://api.example.com/chat/completions');
    });

    test('Claude 默认路径为 /messages', () {
      final endpoint = buildProviderChatEndpoint(
        provider: 'claude',
        apiBaseUrl: 'https://api.anthropic.com/v1',
        model: 'claude-sonnet-4-5',
      );

      expect(endpoint, 'https://api.anthropic.com/v1/messages');
    });

    test('Gemini 默认路径会替换模型占位符', () {
      final endpoint = buildProviderChatEndpoint(
        provider: 'gemini',
        apiBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-2.0-flash',
      );

      expect(
        endpoint,
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent',
      );
    });

    test('Gemini 流式路径会切到 streamGenerateContent', () {
      final endpoint = buildProviderChatEndpoint(
        provider: 'gemini',
        apiBaseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        model: 'gemini-2.0-flash',
        streaming: true,
      );

      expect(
        endpoint,
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent',
      );
    });

    test('Vertex Express 会自动补 publishers/google 前缀', () {
      final endpoint = buildProviderChatEndpoint(
        provider: 'gemini',
        apiBaseUrl: 'https://aiplatform.googleapis.com/v1',
        model: 'gemini-2.5-pro',
        customConfig: const <String, dynamic>{'vertexExpress': true},
      );

      expect(
        endpoint,
        'https://aiplatform.googleapis.com/v1/publishers/google/models/gemini-2.5-pro:generateContent',
      );
    });

    test('MiniMax 原生聊天端点默认不再追加额外路径', () {
      final endpoint = buildProviderChatEndpoint(
        provider: 'minimax',
        apiBaseUrl: 'https://api.minimax.io/v1/text/chatcompletion_v2',
        model: 'MiniMax-M2.7',
      );

      expect(endpoint, 'https://api.minimax.io/v1/text/chatcompletion_v2');
    });

    test('自定义 apiPath 可以覆盖默认聊天路径', () {
      final endpoint = buildProviderChatEndpoint(
        provider: 'openai',
        apiBaseUrl: 'https://unit.test',
        model: 'gpt-4o-mini',
        customConfig: const <String, dynamic>{
          kProviderChatApiPathField: '/v9/responses',
        },
      );

      expect(endpoint, 'https://unit.test/v9/responses');
    });
  });

  test('OpenAI 基础 URL 不以 /v1 结尾时给出推荐提示', () {
    expect(shouldSuggestOpenAiBaseUrlV1('https://api.openai.com'), isTrue);
    expect(shouldSuggestOpenAiBaseUrlV1('https://api.openai.com/v1'), isFalse);
  });
}
