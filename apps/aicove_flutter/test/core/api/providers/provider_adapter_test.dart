import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';

void main() {
  const options = ProviderChatRequestOptions(
    useSystemPrompt: false,
    temperature: 1,
    topP: 0.98,
    topK: 64,
    minP: 0.05,
    topA: 0.1,
    repetitionPenalty: 1.1,
    frequencyPenalty: 0.2,
    presencePenalty: 0.3,
    seed: 42,
    maxOutputTokens: 30000,
    reasoningEffort: 'high',
  );

  test('provider trace marks OpenAI-compatible fields as emitted', () {
    final trace = options.parameterTraceForProvider('openai');

    expect(
      trace.where((entry) => entry['status'] != 'applied'),
      isEmpty,
    );
  });

  test('provider trace exposes Claude unsupported fields explicitly', () {
    final trace = options.parameterTraceForProvider('claude');
    final byField = <String, Map<String, dynamic>>{
      for (final entry in trace) entry['field'] as String: entry,
    };

    expect(byField['top_k']?['status'], 'applied');
    expect(byField['max_tokens']?['status'], 'applied');
    expect(byField['min_p']?['status'], 'intentionallyUnsupported');
    expect(
      byField['reasoning_effort']?['status'],
      'intentionallyUnsupported',
    );
  });

  test('provider trace exposes Gemini mappings and unsupported fields', () {
    final trace = options.parameterTraceForProvider('gemini');
    final byField = <String, Map<String, dynamic>>{
      for (final entry in trace) entry['field'] as String: entry,
    };

    expect(byField['top_k']?['status'], 'applied');
    expect(byField['frequency_penalty']?['status'], 'applied');
    expect(byField['presence_penalty']?['status'], 'applied');
    expect(byField['seed']?['status'], 'applied');
    expect(byField['top_a']?['status'], 'intentionallyUnsupported');
    expect(
      byField['reasoning_effort']?['status'],
      'intentionallyUnsupported',
    );
  });

  test('default-only values are not reported as applied', () {
    const defaults = ProviderChatRequestOptions(
      topK: 0,
      minP: 0,
      repetitionPenalty: 1,
      frequencyPenalty: 0,
      presencePenalty: 0,
      seed: -1,
      reasoningEffort: 'auto',
    );
    final trace = defaults.parameterTraceForProvider('openai');

    expect(
      trace
          .where((entry) => entry['field'] != 'use_sysprompt')
          .map((entry) => entry['status'])
          .toSet(),
      <String>{'notApplicable'},
    );
  });
}
