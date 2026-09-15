import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/providers/claude_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/openai_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';

/// AC6：三家适配器对各档位的请求体形状。
void main() {
  const messages = <Map<String, dynamic>>[
    {'role': 'user', 'content': 'hi'},
  ];

  ProviderChatRequestOptions opts(ThinkingLevel level, ThinkingScheme scheme,
          {int? maxTokens, String? presetEffort}) =>
      ProviderChatRequestOptions(
        thinkingLevel: level,
        thinkingScheme: scheme,
        maxOutputTokens: maxTokens,
        reasoningEffort: presetEffort,
      );

  group('OpenAI reasoning_effort', () {
    Map<String, dynamic> build(ThinkingLevel level, ThinkingScheme scheme) =>
        OpenAIAdapter().buildRequestBody(
          model: 'gpt-5.2',
          messages: messages,
          requestOptions: opts(level, scheme),
        );

    test('native levels map by name, off → none, auto omits', () {
      expect(build(ThinkingLevel.off, ThinkingScheme.openaiEffort),
          containsPair('reasoning_effort', 'none'));
      expect(build(ThinkingLevel.xhigh, ThinkingScheme.openaiEffort),
          containsPair('reasoning_effort', 'xhigh'));
      expect(build(ThinkingLevel.minimal, ThinkingScheme.openaiEffort),
          containsPair('reasoning_effort', 'minimal'));
      expect(build(ThinkingLevel.auto, ThinkingScheme.openaiEffort),
          isNot(contains('reasoning_effort')));
    });

    test('generic clamps xhigh/max to high', () {
      expect(build(ThinkingLevel.xhigh, ThinkingScheme.generic),
          containsPair('reasoning_effort', 'high'));
      expect(build(ThinkingLevel.max, ThinkingScheme.generic),
          containsPair('reasoning_effort', 'high'));
    });

    test('thinkingLevel takes precedence over preset reasoningEffort', () {
      final body = OpenAIAdapter().buildRequestBody(
        model: 'gpt-5.2',
        messages: messages,
        requestOptions: opts(ThinkingLevel.low, ThinkingScheme.openaiEffort,
            presetEffort: 'high'),
      );
      expect(body, containsPair('reasoning_effort', 'low'));
    });

    test('preset reasoningEffort still works without thinkingLevel', () {
      final body = OpenAIAdapter().buildRequestBody(
        model: 'gpt-5.2',
        messages: messages,
        requestOptions: const ProviderChatRequestOptions(reasoningEffort: 'high'),
      );
      expect(body, containsPair('reasoning_effort', 'high'));
    });
  });

  group('Claude thinking', () {
    Map<String, dynamic> build(ThinkingLevel level, ThinkingScheme scheme,
            {int? maxTokens, Map<String, dynamic>? customConfig}) =>
        ClaudeAdapter().buildRequestBody(
          model: 'claude-opus-5',
          messages: messages,
          customConfig: customConfig,
          requestOptions: opts(level, scheme, maxTokens: maxTokens),
        );

    test('effort scheme writes adaptive + output_config.effort', () {
      final body = build(ThinkingLevel.xhigh, ThinkingScheme.claudeEffort);
      expect(body['thinking'], {'type': 'adaptive'});
      expect(body['output_config'], {'effort': 'xhigh'});
    });

    test('effort scheme merges into existing output_config from customConfig', () {
      final body = build(
        ThinkingLevel.low,
        ThinkingScheme.claudeEffort,
        customConfig: {
          'output_config': {'format': 'x', 'effort': 'max'},
        },
      );
      expect(body['output_config'], {'format': 'x', 'effort': 'low'});
    });

    test('off writes thinking disabled and strips effort', () {
      final body = build(
        ThinkingLevel.off,
        ThinkingScheme.claudeEffort,
        customConfig: {
          'output_config': {'effort': 'high'},
        },
      );
      expect(body['thinking'], {'type': 'disabled'});
      expect(body, isNot(contains('output_config')));
    });

    test('budget scheme writes enabled + budget_tokens < max_tokens', () {
      final body = build(ThinkingLevel.high, ThinkingScheme.claudeBudget,
          maxTokens: 30000);
      expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 16384});

      final clamped = build(ThinkingLevel.high, ThinkingScheme.claudeBudget,
          maxTokens: 4096);
      expect(clamped['thinking'], {'type': 'enabled', 'budget_tokens': 4095});
      expect((clamped['thinking'] as Map)['budget_tokens'],
          lessThan(clamped['max_tokens']));
    });

    test('budget scheme skips when max_tokens too small', () {
      final body = build(ThinkingLevel.low, ThinkingScheme.claudeBudget,
          maxTokens: 1024);
      expect(body, isNot(contains('thinking')));
    });

    test('auto leaves body untouched', () {
      final body = build(ThinkingLevel.auto, ThinkingScheme.claudeEffort);
      expect(body, isNot(contains('thinking')));
      expect(body, isNot(contains('output_config')));
    });
  });

  group('Gemini thinkingConfig', () {
    Map<String, dynamic> gen(ThinkingLevel level, ThinkingScheme scheme,
        {Map<String, dynamic>? customConfig}) {
      final body = GeminiAdapter().buildRequestBody(
        model: 'gemini-3-flash',
        messages: messages,
        customConfig: customConfig,
        requestOptions: opts(level, scheme),
      );
      return body['generationConfig'] as Map<String, dynamic>;
    }

    test('level scheme writes upper-case thinkingLevel and includeThoughts', () {
      final config = gen(ThinkingLevel.minimal, ThinkingScheme.geminiLevel);
      expect(config['thinkingConfig'],
          {'thinkingLevel': 'MINIMAL', 'includeThoughts': true});
    });

    test('budget scheme writes thinkingBudget; off is 0 without thoughts', () {
      expect(gen(ThinkingLevel.high, ThinkingScheme.geminiBudget)['thinkingConfig'],
          {'thinkingBudget': -1, 'includeThoughts': true});
      expect(gen(ThinkingLevel.off, ThinkingScheme.geminiBudget)['thinkingConfig'],
          {'thinkingBudget': 0});
    });

    test('never emits thinkingLevel and thinkingBudget together', () {
      final config = gen(
        ThinkingLevel.medium,
        ThinkingScheme.geminiLevel,
        customConfig: {
          'generationConfig': {
            'thinkingConfig': {'thinkingBudget': 2048, 'foo': 1},
          },
        },
      );
      final thinking = config['thinkingConfig'] as Map;
      expect(thinking, isNot(contains('thinkingBudget')));
      expect(thinking['thinkingLevel'], 'MEDIUM');
      expect(thinking['foo'], 1);
    });

    test('auto keeps customConfig thinkingConfig as-is', () {
      final config = gen(
        ThinkingLevel.auto,
        ThinkingScheme.geminiLevel,
        customConfig: {
          'generationConfig': {
            'thinkingConfig': {'thinkingBudget': 2048},
          },
        },
      );
      expect(config['thinkingConfig'], {'thinkingBudget': 2048});
    });
  });

  test('trace marks thinking_level applied for claude and gemini', () {
    const options = ProviderChatRequestOptions(
      thinkingLevel: ThinkingLevel.high,
      thinkingScheme: ThinkingScheme.claudeEffort,
      reasoningEffort: 'high',
    );
    for (final provider in ['claude', 'gemini', 'openai']) {
      final trace = options.parameterTraceForProvider(provider);
      final byField = {for (final e in trace) e['field']: e};
      expect(byField['thinking_level']?['status'], 'applied', reason: provider);
      expect(byField['reasoning_effort']?['status'], 'notApplicable',
          reason: provider);
    }
  });
}
