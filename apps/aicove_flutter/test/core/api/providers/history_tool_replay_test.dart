import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/api/providers/claude_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart';

void main() {
  final history = <Map<String, dynamic>>[
    {'role': 'user', 'content': '开始'},
    {
      'role': 'assistant',
      'content': '先读文件',
      'tool_calls': [
        {
          'id': 'a',
          'type': 'function',
          'function': {'name': 'read', 'arguments': '{"path":"a"}'},
          'thoughtSignature': 'signed',
        },
        {
          'id': 'b',
          'type': 'function',
          'function': {'name': 'read', 'arguments': '{"path":"b"}'},
        },
      ],
    },
    {'role': 'tool', 'tool_call_id': 'a', 'name': 'read', 'content': 'A'},
    {
      'role': 'tool',
      'tool_call_id': 'b',
      'name': 'read',
      'content': '已中断，未拿到结果',
      'is_error': true,
    },
    {'role': 'user', 'content': '继续'},
  ];
  test(
    'Claude preserves historical calls, result ids and merged user blocks',
    () {
      final body = ClaudeAdapter().buildRequestBody(
        model: 'test',
        messages: history,
      );
      final messages = body['messages'] as List;
      expect(messages.map((m) => m['role']), ['user', 'assistant', 'user']);
      expect(messages[1]['content'], [
        {'type': 'text', 'text': '先读文件'},
        {
          'type': 'tool_use',
          'id': 'a',
          'name': 'read',
          'input': {'path': 'a'},
        },
        {
          'type': 'tool_use',
          'id': 'b',
          'name': 'read',
          'input': {'path': 'b'},
        },
      ]);
      expect(messages[2]['content'], [
        {'type': 'tool_result', 'tool_use_id': 'a', 'content': 'A'},
        {
          'type': 'tool_result',
          'tool_use_id': 'b',
          'content': '已中断，未拿到结果',
          'is_error': true,
        },
        {'type': 'text', 'text': '继续'},
      ]);
    },
  );
  test(
    'Gemini preserves historical calls, paired responses and signatures',
    () {
      final body = GeminiAdapter().buildRequestBody(
        model: 'test',
        messages: history,
      );
      final contents = body['contents'] as List;
      expect(contents.map((m) => m['role']), ['user', 'model', 'user']);
      expect(contents[1]['parts'], [
        {'text': '先读文件'},
        {
          'functionCall': {
            'id': 'a',
            'name': 'read',
            'args': {'path': 'a'},
          },
          'thoughtSignature': 'signed',
        },
        {
          'functionCall': {
            'id': 'b',
            'name': 'read',
            'args': {'path': 'b'},
          },
        },
      ]);
      expect(contents[2]['parts'], [
        {
          'functionResponse': {
            'id': 'a',
            'name': 'read',
            'response': {'result': 'A'},
          },
        },
        {
          'functionResponse': {
            'id': 'b',
            'name': 'read',
            'response': {'result': '已中断，未拿到结果'},
          },
        },
        {'text': '继续'},
      ]);
    },
  );
  for (final adapter in <ProviderAdapter>[ClaudeAdapter(), GeminiAdapter()]) {
    test('${adapter.name} leaves native follow-up calls single', () {
      final native = adapter.name == 'claude'
          ? <String, dynamic>{
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'a',
                  'name': 'read',
                  'input': {'path': 'a'},
                },
              ],
            }
          : <String, dynamic>{
              'content': {
                'parts': [
                  {
                    'functionCall': {
                      'id': 'a',
                      'name': 'read',
                      'args': {'path': 'a'},
                    },
                    'thoughtSignature': 'signed',
                  },
                ],
              },
            };
      final followup = adapter.buildToolResultMessages(
        assistantMessage: native,
        toolResults: const [ToolResult(toolCallId: 'a', name: 'read', result: 'A')],
      );
      final body = adapter.buildRequestBody(model: 'test', messages: followup);
      expect(
        RegExp(
          adapter.name == 'claude' ? 'tool_use"' : 'functionCall"',
        ).allMatches(jsonEncode(body)).length,
        1,
      );
    });
  }
}
