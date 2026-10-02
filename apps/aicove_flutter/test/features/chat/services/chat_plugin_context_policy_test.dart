import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_plugin_context_policy.dart';

void main() {
  final off = ChatPluginContextPolicy.firstParty(activeProviderIds: {});
  test('disabled tags remove bodies, attributes, nesting and unfinished bodies',
      () {
    expect(
        off.filterText(
            'a<IMAGE source="history">x\n<image>nested</image>y</IMAGE>b<TtS voice="x>y">voice</tTs>c'),
        'abc');
    expect(off.filterText('a<image />b<tts/>c'), 'abc');
    expect(off.filterText('a<image>unfinished'), 'a');
    expect(off.filterText('a</image>b'), 'ab');
    expect(off.filterText('<image_url>keep</image_url><ttstyle>keep</ttstyle>'),
        '<image_url>keep</image_url><ttstyle>keep</ttstyle>');
  });
  test('each switch is independent and re-enabling preserves original text',
      () {
    const original = 'a<image>image</image>b<tts>voice</tts>c';
    expect(
        ChatPluginContextPolicy.firstParty(activeProviderIds: {'image'})
            .filterText(original),
        'a<image>image</image>bc');
    expect(
        ChatPluginContextPolicy.firstParty(activeProviderIds: {'tts'})
            .filterText(original),
        'ab<tts>voice</tts>c');
    expect(
        ChatPluginContextPolicy.firstParty(activeProviderIds: {'image', 'tts'})
            .filterText(original),
        original);
  });
  test('tool calls and results are removed together without mutating raw input',
      () {
    final messages = <Map<String, dynamic>>[
      {
        'role': 'assistant',
        'content': 'hello<image>hidden</image>',
        'tool_calls': [
          {
            'id': 'draw',
            'function': {
              'name': 'draw_image',
              'arguments': '{"prompt":"hidden"}'
            }
          },
          {
            'id': 'voice',
            'function': {'name': 'speak', 'arguments': '{}'}
          },
          {
            'id': 'search',
            'function': {'name': 'search', 'arguments': '{}'}
          },
        ]
      },
      {'role': 'tool', 'tool_call_id': 'draw', 'content': 'hidden'},
      {'role': 'tool', 'tool_call_id': 'voice', 'content': 'hidden'},
      {'role': 'tool', 'tool_call_id': 'search', 'content': 'result'},
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '<tts>hidden</tts>'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,userupload'}
          },
          {'type': 'text', 'text': 'question'},
        ]
      },
      {'role': 'system', 'content': '<image>preset hidden</image>'},
    ];
    final before = jsonEncode(messages);
    final result = off.filterMessages(messages);
    expect(result, hasLength(3));
    expect(result.first['content'], 'hello');
    expect((result.first['tool_calls'] as List).single['id'], 'search');
    expect(result[1]['tool_call_id'], 'search');
    expect(result.last['content'], hasLength(2));
    expect(jsonEncode(result), isNot(contains('hidden')));
    expect(jsonEncode(messages), before);
  });
  test('legacy function calls and replies are filtered as a pair', () {
    expect(
        off.filterMessages([
          {
            'role': 'assistant',
            'function_call': {'name': 'speak', 'arguments': '{}'}
          },
          {'role': 'function', 'name': 'speak', 'content': 'voice'},
          {'role': 'user', 'content': 'hello'},
        ]),
        [
          {'role': 'user', 'content': 'hello'}
        ]);
  });
  test('retired memory tools are dropped in pairs even when all plugins are on',
      () {
    final on = ChatPluginContextPolicy.firstParty(activeProviderIds: {'image', 'tts'});
    final messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': '还记得吗'},
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'old',
            'type': 'function',
            'function': {'name': 'memory_search', 'arguments': '{}'},
          },
          {
            'id': 'keep',
            'type': 'function',
            'function': {'name': 'draw_image', 'arguments': '{}'},
          },
        ],
      },
      {'role': 'tool', 'tool_call_id': 'old', 'content': '旧记忆'},
      {'role': 'tool', 'tool_call_id': 'keep', 'content': '图'},
    ];
    final filtered = on.filterMessages(messages);
    expect(jsonEncode(filtered), isNot(contains('memory_search')));
    expect(jsonEncode(filtered), isNot(contains('旧记忆')));
    expect(jsonEncode(filtered), contains('draw_image'));
    expect(filtered.last['tool_call_id'], 'keep');
    expect(jsonEncode(messages), contains('memory_search'));
    for (final name in ['memory_read', 'context_read']) {
      expect(on.allowsTool(name), isFalse);
    }
  });
}
