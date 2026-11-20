import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/openai_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/claude_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:aicove_flutter/src/core/utils/token_estimator.dart';
import 'package:aicove_flutter/src/core/api_logger.dart';
import 'package:aicove_flutter/src/features/observability/diagnostic_bundle.dart';

void main() {
  test('OpenAI numeric values and subsets', () {
    final u = TokenUsage.fromOpenAiUsage({
      'prompt_tokens': '100',
      'completion_tokens': 30.0,
      'prompt_tokens_details': {'cached_tokens': '40'},
      'completion_tokens_details': {'reasoning_tokens': 12},
    })!;
    expect(u.inputTokens, 100);
    expect(u.outputTokens, 30);
    expect(u.uncachedInputTokens, 60);
    expect(u.reasoningTokens, 12);
    expect(u.totalTokens, 130);
  });
  test('reported USD cost validates the response and round trips', () {
    TokenUsage parse(Object? cost) => TokenUsage.fromOpenAiUsage({
      'prompt_tokens': 10,
      'completion_tokens': 5,
      'cost': cost,
    })!;
    for (final cost in [
      null,
      -1,
      1000.0001,
      double.nan,
      double.infinity,
      'bad',
    ]) {
      final u = parse(cost);
      expect(u.reportedCostUsd, isNull, reason: '$cost');
      expect(u.toJson(), isNot(contains('reportedCostUsd')));
    }
    expect(parse(0).reportedCostUsd, 0);
    expect(parse('1000').reportedCostUsd, 1000);
    final sum = parse('0.125') + parse(0.25);
    expect(sum.reportedCostUsd, 0.375);
    expect(TokenUsage.fromJson(sum.toJson()).reportedCostUsd, 0.375);
    expect(
      TokenUsage.fromJson((parse(800) + parse(600)).toJson()).reportedCostUsd,
      1400,
    );
    expect((parse('0.125') + parse(null)).reportedCostUsd, isNull);
    expect((parse(null) + parse('0.125')).reportedCostUsd, isNull);
  });
  test('DeepSeek recovers input from cache breakdown', () {
    final u = TokenUsage.fromOpenAiUsage({
      'prompt_cache_hit_tokens': 70,
      'prompt_cache_miss_tokens': '30',
    })!;
    expect(u.inputTokens, 100);
    expect(u.cachedInputTokens, 70);
  });
  test('Responses nested usage', () {
    final u = OpenAIAdapter().parseResponse({
      'response': {
        'usage': {
          'input_tokens': 100,
          'output_tokens': 20,
          'input_tokens_details': {'cached_tokens': 50},
          'output_tokens_details': {'reasoning_tokens': 10},
        },
      },
    }).usage!;
    expect(u.totalTokens, 120);
    expect(u.cachedInputTokens, 50);
    expect(u.reasoningTokens, 10);
  });
  test('Claude sums all input categories', () {
    final u = ClaudeAdapter().parseResponse({
      'usage': {
        'input_tokens': '10',
        'output_tokens': 5,
        'cache_read_input_tokens': 20.0,
        'cache_creation_input_tokens': 30,
      },
    }).usage!;
    expect(u.inputTokens, 60);
    expect(u.uncachedInputTokens, 10);
    expect(u.cacheWriteTokens, 30);
    expect(u.totalTokens, 65);
  });
  test('Gemini includes thoughts and tool prompt', () {
    final u = GeminiAdapter().parseResponse({
      'usageMetadata': {
        'promptTokenCount': 100,
        'toolUsePromptTokenCount': 5,
        'cachedContentTokenCount': 80,
        'candidatesTokenCount': 20,
        'thoughtsTokenCount': 30,
        'totalTokenCount': 155,
      },
    }).usage!;
    expect(u.inputTokens, 105);
    expect(u.outputTokens, 50);
    expect(u.reasoningTokens, 30);
  });
  test('Gemini already-inclusive gateway candidates', () {
    expect(
      TokenUsage.fromGeminiUsageMetadata({
        'promptTokenCount': '100',
        'candidatesTokenCount': 50,
        'thoughtsTokenCount': 30,
        'totalTokenCount': 150,
      })!.outputTokens,
      50,
    );
  });
  test('Gemini missing candidates retains thoughts', () {
    expect(
      TokenUsage.fromGeminiUsageMetadata({
        'promptTokenCount': 100,
        'thoughtsTokenCount': 30,
      })!.outputTokens,
      30,
    );
  });
  test('Absent and malformed usage stays absent', () {
    for (final value in [
      null,
      <String, dynamic>{},
      <String, dynamic>{'prompt_tokens': 'bad'},
    ]) {
      expect(TokenUsage.fromOpenAiUsage(value), isNull);
      expect(TokenUsage.fromClaudeUsage(value), isNull);
      expect(TokenUsage.fromGeminiUsageMetadata(value), isNull);
    }
  });
  test('Estimation includes tool definitions, arguments and reasoning', () {
    final messages = [
      {'role': 'user', 'content': 'hello'},
    ];
    final plain = TokenUsage.estimate(messages: messages, outputText: 'world');
    final u = TokenUsage.estimate(
      messages: messages,
      outputText: 'world',
      reasoningText: 'think',
      tools: [
        {'name': 'lookup'},
      ],
      toolCalls: [
        const ToolCall(id: 'a', name: 'lookup', arguments: {'query': 'hello'}),
      ],
    );
    expect(plain.inputTokens, estimateMessageTokens(messages.first));
    expect(u.inputTokens, greaterThan(plain.inputTokens));
    expect(u.outputTokens, greaterThan(plain.outputTokens));
    expect(u.reasoningTokens, estimateTokenCount('think'));
    expect(u.isEstimated, true);
  });
  test('Addition and serialization', () {
    const a = TokenUsage(
      inputTokens: 100,
      outputTokens: 20,
      cachedInputTokens: 30,
      cacheWriteTokens: 10,
      reasoningTokens: 5,
    );
    final u = TokenUsage.fromJson(
      (a + const TokenUsage(inputTokens: 2, outputTokens: 3, isEstimated: true))
          .toJson(),
    );
    expect(u.totalTokens, 125);
    expect(u.isEstimated, true);
    expect(u.uncachedInputTokens, 62);
    expect(const TokenUsage(inputTokens: 0, outputTokens: 0).isZero, true);
  });
  test('Log roundtrip and diagnostic whitelist', () {
    final log = ApiLogEntry(
      time: DateTime(2026),
      method: 'POST',
      url: 'https://x',
      status: 200,
      durationMs: 5,
      requestBody: 'secret',
      responseBody: 'secret',
      ok: true,
      inputTokens: 100,
      outputTokens: 20,
      cachedInputTokens: 30,
      cacheWriteTokens: 10,
      reasoningTokens: 5,
      usageEstimated: false,
    );
    expect(ApiLogEntry.fromJson(log.toJson()).cacheWriteTokens, 10);
    final api = sanitizeDiagnosticEntry(log.toJson(), 'api_2026-01-01.jsonl')!;
    expect(api['inputTokens'], 100);
    expect(api['usageEstimated'], false);
    expect(api.containsKey('requestBody'), false);
    final trace = sanitizeDiagnosticEntry({
      'startedAt': DateTime(2026).toIso8601String(),
      'meta': {'inputTokens': 100, 'usageEstimated': true, 'secret': 'content'},
    }, 'trace/index_2026-01-01.jsonl')!;
    expect(trace['meta'], {'inputTokens': 100, 'usageEstimated': true});
  });
}
