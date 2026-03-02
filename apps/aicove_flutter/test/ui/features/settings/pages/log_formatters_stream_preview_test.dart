import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api_logger.dart';
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

  group('formatApiLogFull', () {
    test('conversation log includes full request/response/tool sections', () {
      final longSystemPrompt = List.filled(130, 'S').join();
      final log = ApiLogEntry(
        time: DateTime(2026, 3, 2, 12, 30, 45),
        method: 'POST',
        url: 'https://example.test/v1/chat/completions',
        status: 200,
        durationMs: 1234,
        requestBody: '{}',
        responseBody: '{}',
        ok: true,
        rawContext: jsonEncode([
          {'role': 'system', 'content': longSystemPrompt},
          {'role': 'user', 'content': '你好'},
        ]),
        rawRequestBody: jsonEncode({
          'model': 'openai:gpt-4o-mini',
          'stream': true,
          'messages': [
            {'role': 'system', 'content': longSystemPrompt},
            {'role': 'user', 'content': '你好'},
          ],
        }),
        rawResponseBody: jsonEncode({
          'streamEvents': [
            {
              'choices': [
                {
                  'delta': {'content': '你'}
                }
              ]
            },
            '[DONE]',
          ],
        }),
        rawToolCalls: jsonEncode([
          {
            'id': 'call_1',
            'name': 'search_web',
            'arguments': {'q': '天气'},
          }
        ]),
        rawToolResults: jsonEncode([
          {
            'toolCallId': 'call_1',
            'name': 'search_web',
            'result': jsonEncode({'success': true}),
          }
        ]),
        rawAiResponse: '你好呀',
        finalReply: '你好呀（用户可见）',
        sessionId: 'session_1',
        turnId: 'turn_1',
        roundIndex: 1,
        eventType: 'round_stream',
      );

      final full = formatApiLogFull(log);

      expect(full, contains('AI 实际收到的完整上下文（messages）'));
      expect(full, contains('AI 实际发送的完整请求体（rawRequestBody）'));
      expect(full, contains('"model": "openai:gpt-4o-mini"'));
      expect(full, contains(longSystemPrompt));
      expect(full, contains('AI 原始 JSON 响应（模型回包）'));
      expect(full, contains('AI -> 工具调用'));
      expect(full, contains('工具 -> AI 返回'));
      expect(full, contains('最终展示给用户的回复'));
    });
  });
}
