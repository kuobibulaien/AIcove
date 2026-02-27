import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/ui/features/settings/pages/log_formatters.dart';

void main() {
  group('parseStreamResponsePreview', () {
    test('merges choices.delta.content into one readable text', () {
      final raw = jsonEncode({
        'streamEvents': [
          {
            'choices': [
              {
                'delta': {'content': '你'}
              }
            ]
          },
          {
            'choices': [
              {
                'delta': {'content': '好'}
              }
            ]
          },
          '[DONE]',
        ],
      });

      final preview = parseStreamResponsePreview(raw);
      expect(preview, isNotNull);
      expect(preview!.mergedText, '你好');
      expect(preview.eventCount, 3);
      expect(preview.hasDoneMarker, isTrue);
      expect(preview.parseErrorCount, 0);
    });

    test('supports root response.output_text.delta style events', () {
      final raw = jsonEncode({
        'streamEvents': [
          {'type': 'response.output_text.delta', 'delta': '今'},
          {'type': 'response.output_text.delta', 'delta': '天'},
        ],
      });

      final preview = parseStreamResponsePreview(raw);
      expect(preview, isNotNull);
      expect(preview!.mergedText, '今天');
      expect(preview.hasDoneMarker, isFalse);
    });

    test('returns null when raw body is not streamEvents envelope', () {
      final normalRaw = jsonEncode({
        'choices': [
          {
            'message': {'content': '完整一次性响应'}
          }
        ],
      });

      expect(parseStreamResponsePreview(normalRaw), isNull);
      expect(parseStreamResponsePreview(null), isNull);
      expect(parseStreamResponsePreview(''), isNull);
    });
  });

  group('buildToolCallTraceText', () {
    test('shows failed tool result from rawToolCalls/rawToolResults', () {
      final rawToolCalls = jsonEncode([
        {
          'id': 'call_1',
          'name': 'lookup_weather',
          'arguments': {'city': '上海'},
        }
      ]);
      final rawToolResults = jsonEncode([
        {
          'toolCallId': 'call_1',
          'name': 'lookup_weather',
          'result': jsonEncode({'error': 'timeout'}),
        }
      ]);

      final trace = buildToolCallTraceText(
        rawToolCalls: rawToolCalls,
        rawToolResults: rawToolResults,
      );

      expect(trace, isNotNull);
      expect(trace!, contains('状态: 失败'));
      expect(trace, contains('lookup_weather'));
      expect(trace, contains('timeout'));
      expect(trace, contains('call_1'));
    });

    test('falls back to streamEvents tool_calls when rawToolCalls absent', () {
      final rawResponseBody = jsonEncode({
        'streamEvents': [
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_2',
                      'function': {
                        'name': 'search_web',
                        'arguments': '{"q":"今',
                      }
                    }
                  ],
                }
              }
            ]
          },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {
                        'arguments': '天天气"}',
                      }
                    }
                  ],
                }
              }
            ]
          },
          '[DONE]',
        ],
      });

      final trace = buildToolCallTraceText(
        rawToolCalls: null,
        rawToolResults: null,
        rawResponseBody: rawResponseBody,
      );

      expect(trace, isNotNull);
      expect(trace!, contains('search_web'));
      expect(trace, contains('call_2'));
      expect(trace, contains('今天天气'));
      expect(trace, contains('状态: 未返回结果'));
    });
  });
}
