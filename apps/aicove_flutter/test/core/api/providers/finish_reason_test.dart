import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/providers/claude_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/openai_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';

void main() {
  test('raw finish reasons of the three providers map to one set', () {
    const table = {
      // OpenAI-compatible
      'stop': FinishReason.stop,
      'tool_calls': FinishReason.toolCalls,
      'function_call': FinishReason.toolCalls,
      'length': FinishReason.length,
      'content_filter': FinishReason.contentFilter,
      // Claude
      'end_turn': FinishReason.stop,
      'stop_sequence': FinishReason.stop,
      'tool_use': FinishReason.toolCalls,
      'max_tokens': FinishReason.length,
      'refusal': FinishReason.contentFilter,
      'pause_turn': FinishReason.unknown,
      // Gemini
      'STOP': FinishReason.stop,
      'MAX_TOKENS': FinishReason.length,
      'SAFETY': FinishReason.contentFilter,
      'RECITATION': FinishReason.contentFilter,
      'PROHIBITED_CONTENT': FinishReason.contentFilter,
      'MALFORMED_FUNCTION_CALL': FinishReason.unknown,
    };
    for (final MapEntry(:key, :value) in table.entries) {
      expect(normalizeFinishReason(key), value, reason: key);
    }
    expect(normalizeFinishReason(null), isNull);
    expect(normalizeFinishReason('  '), isNull);
  });

  test('each adapter reads its provider finish reason', () {
    final openai = OpenAIAdapter().parseResponse({
      'choices': [
        {
          'finish_reason': 'tool_calls',
          'message': {'content': ''},
        },
      ],
    });
    expect(openai.rawFinishReason, 'tool_calls');
    expect(openai.finishReason, FinishReason.toolCalls);

    final claude = ClaudeAdapter().parseResponse({
      'stop_reason': 'end_turn',
      'content': [
        {'type': 'text', 'text': 'hi'},
      ],
    });
    expect(claude.finishReason, FinishReason.stop);

    final gemini = GeminiAdapter().parseResponse({
      'candidates': [
        {
          'finishReason': 'MAX_TOKENS',
          'content': {
            'parts': [
              {'text': 'cut'},
            ],
          },
        },
      ],
    });
    expect(gemini.finishReason, FinishReason.length);

    expect(OpenAIAdapter().parseResponse({'choices': []}).finishReason, isNull);
  });
}
