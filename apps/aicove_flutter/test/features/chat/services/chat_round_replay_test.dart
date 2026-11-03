import 'dart:convert';
import 'package:aicove_flutter/src/core/api/providers/openai_adapter.dart';
import 'package:aicove_flutter/src/core/api/providers/gemini_adapter.dart';

import 'package:aicove_flutter/src/core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_plugin_context_policy.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/chat_segmented_fixture.dart';

void main() {
  final builder = ChatRequestMessageBuilder(
    readImageAsBase64: (_) async => null,
  );
  Message raw({
    String? stopReason,
    ApiRunStatus status = ApiRunStatus.completed,
  }) => Message(
    id: 'raw',
    role: 'assistant',
    content: '合并后文字不是上下文',
    createdAt: DateTime(2026),
    rawPayload: ChatMessageProjectionCodec.buildRawAssistantPayload(
      apiResult: ApiCallResult(
        status: status,
        stopReason: stopReason,
        replyText: '第一轮\n第二轮\n完成',
        processedText: '',
        pluginEvents: const [],
        toolResults: const [],
        toolCalls: const [
          ToolCall(
            id: 'a',
            name: 'read',
            arguments: {'path': 'a'},
            thoughtSignature: 'signature',
          ),
          ToolCall(id: 'hidden', name: 'draw_image', arguments: {}),
          ToolCall(id: 'b', name: 'read', arguments: {'path': 'b'}),
        ],
        rawToolResults: const [
          ToolResult(toolCallId: 'a', name: 'read', result: 'A'),
          ToolResult(toolCallId: 'hidden', name: 'draw_image', result: 'image'),
          ToolResult(toolCallId: 'b', name: 'read', result: 'B'),
        ],
        replyRounds: const [
          ReplyRound(
            replyText: '第一轮<image>hidden</image>',
            processedText: '错误的投影',
            reasoning: '私有思考',
            toolCallIds: ['a', 'hidden'],
          ),
          ReplyRound(replyText: '第二轮', processedText: '', toolCallIds: ['b']),
          ReplyRound(replyText: '完成', processedText: ''),
        ],
      ),
    ),
  );

  test(
    'raw with rounds but no blocks replays paired results and thoughtSignature',
    () async {
      final request = await builder.buildRequestMessages([
        raw(),
      ], settings: segmentedProbeSettings);
      expect(request.map((m) => m['role']), [
        'assistant',
        'tool',
        'tool',
        'assistant',
        'tool',
        'assistant',
      ]);
      expect(request[0]['content'], '第一轮<image>hidden</image>');
      expect(
        (request[0]['tool_calls'] as List).first['extra_content'],
        {'google': {'thought_signature': 'signature'}},
      );
      expect(request[1]['content'], 'A');
      expect(request[3]['content'], '第二轮');
      expect(request[5]['content'], '完成');
      expect(jsonEncode(request), isNot(contains('私有思考')));
      expect(jsonEncode(request), isNot(contains('错误的投影')));
    },
  );

  test(
    'strict OpenAI history has no signature extension and does not mutate input',
    () async {
      final request = await builder.buildRequestMessages([
        raw(),
      ], settings: segmentedProbeSettings);
      final before = jsonEncode(request);
      final body = OpenAIAdapter().buildRequestBody(
        model: 'gpt-4o',
        messages: request,
      );
      final call = (body['messages'][0]['tool_calls'] as List).first as Map;
      expect(call.keys, unorderedEquals(['id', 'type', 'function']));
      expect(jsonEncode(request), before);
      final native = GeminiAdapter().buildRequestBody(
        model: 'gemini-3-flash-preview',
        messages: request,
      );
      expect(
        native['contents'][0]['parts'][1]['thoughtSignature'],
        'signature',
      );
    },
  );

  test(
    'Gemini OpenAI history uses the same official signature position as rebuilt live calls',
    () async {
      final request = await builder.buildRequestMessages([
        raw(),
      ], settings: segmentedProbeSettings);
      final body = OpenAIAdapter().buildRequestBody(
        model: 'google/gemini-3-flash-preview',
        messages: request,
      );
      final call = (body['messages'][0]['tool_calls'] as List).first as Map;
      expect(call.containsKey('thoughtSignature'), isFalse);
      expect(call['extra_content'], {
        'google': {'thought_signature': 'signature'},
      });
      final live = OpenAIAdapter().parseResponse({
        'choices': [
          {
            'message': {
              'tool_calls': [
                {
                  'id': 'a',
                  'type': 'function',
                  'function': {'name': 'read', 'arguments': '{"path":"a"}'},
                  'extra_content': {
                    'google': {'thought_signature': 'signature'},
                  },
                },
              ],
            },
          },
        ],
      });
      expect(live.toolCalls.single.thoughtSignature, 'signature');
      expect(live.toolCalls.single.toOpenAIFormat(), call);
    },
  );

  Message withUnclaimedCalls() {
    final message = raw();
    final payload = message.rawPayload!;
    final originalCalls = payload['toolCalls'] as List;
    return message.copyWith(
      rawPayload: {
        ...payload,
        'toolCalls': [
          {
            'id': 'extra_1',
            'name': 'read',
            'arguments': {'path': 'one'},
          },
          ...originalCalls,
          {'id': 'extra_hidden', 'name': 'draw_image', 'arguments': {}},
          {
            'id': 'extra_2',
            'name': 'read',
            'arguments': {'path': 'two'},
          },
        ],
        // Result completion order need not match declaration order.
        'rawToolResults': [
          {'toolCallId': 'extra_2', 'name': 'read', 'result': 'TWO'},
          ...payload['rawToolResults'] as List,
          {
            'toolCallId': 'extra_hidden',
            'name': 'draw_image',
            'result': 'hidden extra',
          },
          {'toolCallId': 'extra_1', 'name': 'read', 'result': 'ONE'},
        ],
      },
    );
  }

  test(
    'unclaimed completed calls replay once after the final round, in declaration order',
    () async {
      final message = withUnclaimedCalls();
      final before = jsonEncode(message.rawPayload);
      final request = await builder.buildRequestMessages([
        message,
      ], settings: segmentedProbeSettings);
      final finalText = request.indexWhere((m) => m['content'] == '完成');
      expect(request.sublist(finalText + 1).map((m) => m['role']), [
        'assistant',
        'tool',
        'tool',
        'tool',
      ]);
      expect(
        (request[finalText + 1]['tool_calls'] as List).map((c) => c['id']),
        ['extra_1', 'extra_hidden', 'extra_2'],
      );
      expect(request.sublist(finalText + 2).map((m) => m['content']), [
        'ONE',
        'hidden extra',
        'TWO',
      ]);
      final calls = [for (final m in request) ...?m['tool_calls'] as List?];
      expect(calls.map((c) => c['id']), [
        'a',
        'hidden',
        'b',
        'extra_1',
        'extra_hidden',
        'extra_2',
      ]);
      expect(jsonEncode(message.rawPayload), before);
    },
  );

  test('unclaimed calls still go through paired plugin filtering', () async {
    final policy = ChatPluginContextPolicy.firstParty(activeProviderIds: {});
    final request = policy.filterMessages(
      await builder.buildRequestMessages(
        [withUnclaimedCalls()],
        settings: segmentedProbeSettings,
        pluginPolicy: policy,
      ),
    );
    final calls = [for (final m in request) ...?m['tool_calls'] as List?];
    expect(calls.map((c) => c['id']), ['a', 'b', 'extra_1', 'extra_2']);
    expect(
      request.where((m) => m['role'] == 'tool').map((m) => m['tool_call_id']),
      ['a', 'b', 'extra_1', 'extra_2'],
    );
    expect(jsonEncode(request), isNot(contains('hidden')));
  });

  test(
    'per-round plugin filtering removes disabled tags and both sides of calls',
    () async {
      final policy = ChatPluginContextPolicy.firstParty(activeProviderIds: {});
      final request = policy.filterMessages(
        await builder.buildRequestMessages(
          [raw()],
          settings: segmentedProbeSettings,
          pluginPolicy: policy,
        ),
      );
      expect(request.map((m) => m['role']), [
        'assistant',
        'tool',
        'assistant',
        'tool',
        'assistant',
      ]);
      expect(request[0]['content'], '第一轮');
      expect((request[0]['tool_calls'] as List).single['id'], 'a');
      expect(jsonEncode(request), isNot(contains('hidden')));
    },
  );

  test(
    'ordinary legacy messages retain the aggregated tool representation',
    () async {
      final old = Message.fromBlocks(
        id: 'old',
        role: 'assistant',
        blocks: [
          TextBlock(messageId: 'old', content: '旧消息'),
          ToolBlock(
            messageId: 'old',
            toolCallId: 'old_call',
            toolName: 'read',
            result: {'content': 'old result'},
          ),
        ],
      );
      final request = await builder.buildRequestMessages([
        old,
      ], settings: segmentedProbeSettings);
      expect(request.map((m) => m['role']), ['assistant', 'tool']);
      expect(request[0]['content'], '旧消息');
      expect(request[1]['content'], '{"content":"old result"}');
    },
  );

  test('round replay retains media conversion on the final round', () async {
    final withImage = raw().copyWith(
      blocks: [
        ImageBlock(
          messageId: 'raw',
          url: 'https://example.test/image.png',
          prompt: '生成图片',
        ),
      ],
    );
    final request = await builder.buildRequestMessages([
      withImage,
    ], settings: segmentedProbeSettings);
    expect(request.last['content'], [
      {'type': 'text', 'text': '完成'},
      {'type': 'text', 'text': '<image>生成图片</image>'},
    ]);
  });
}
