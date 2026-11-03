import 'dart:convert';

import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_request_message_builder.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/chat_segmented_fixture.dart';

void main() {
  const projection = ChatFrontendMessageProjectionService();
  Message raw(Map<String, dynamic> payload) => Message(
    id: 'raw_contract',
    role: 'assistant',
    content: '原文',
    createdAt: DateTime(2026, 10, 25),
    rawPayload: payload,
  );
  String encoded(List<Message> messages) =>
      jsonEncode(ChatMessageProjectionCodec.serializeMessages(messages));

  test(
    'round request replay uses rawText, strips think, and supports legacy rounds',
    () async {
      final builder = ChatRequestMessageBuilder(
        readImageAsBase64: (_) async => null,
      );
      final messages = await builder.buildRequestMessages([
        raw({
          'replyRounds': [
            {
              'rawText': '<think>私有思考</think>原始话术',
              'replyText': '<div>展示状态栏</div>',
            },
            {'replyText': '<think>旧思考</think>旧话术'},
          ],
        }),
      ], settings: segmentedProbeSettings);
      final text = jsonEncode(messages);
      expect(text, contains('原始话术'));
      expect(text, contains('旧话术'));
      expect(text, isNot(contains('展示状态栏')));
      expect(text, isNot(contains('思考')));
    },
  );

  test(
    'single-round assistant replay strips inline think in text blocks and plain content',
    () async {
      final builder = ChatRequestMessageBuilder(
        readImageAsBase64: (_) async => null,
      );
      for (final blocks in <List<MessageBlock>?>[
        null,
        [
          TextBlock(
            messageId: 'raw_contract',
            content: '正文<think>私密</think>结尾',
          ),
        ],
      ]) {
        final messages = await builder.buildRequestMessages([
          raw({}).copyWith(content: '正文<think>私密</think>结尾', blocks: blocks),
        ], settings: segmentedProbeSettings);
        expect(messages.single['content'], '正文结尾');
      }
    },
  );

  test('semantic facts take precedence over stale projected snapshots', () {
    final message = raw({
      'displayReplyText': '当前展示',
      'processedText': '当前展示',
      'projectedMessages': ChatMessageProjectionCodec.serializeMessages([
        Message.text(id: 'stale', role: 'assistant', content: '过时快照'),
      ]),
    });
    expect(projection.projectMessage(message).single.displayText, '当前展示');
    expect(message.rawPayload!['projectedMessages'], isNotNull);
  });

  test('complete semantics ignore even a corrupt historical snapshot', () {
    expect(
      projection
          .projectMessage(
            raw({
              'displayReplyText': '有效展示',
              'processedText': '有效展示',
              'projectedMessages': [
                {'id': 1, 'role': 'assistant'},
              ],
            }),
          )
          .single
          .displayText,
      '有效展示',
    );
  });

  test(
    'projection is byte-identical for rounds, thinking, tools and supplement media',
    () {
      final message = raw({
        'displayReplyText': '正文',
        'processedText': '正文',
        'replyRounds': [
          {
            'replyText': '查一下',
            'processedText': '查一下',
            'reasoning': '想一下',
            'toolCallIds': ['call'],
          },
          {'replyText': '正文', 'processedText': '正文'},
        ],
        'toolCalls': [
          {
            'id': 'call',
            'name': 'read',
            'arguments': {'path': 'a'},
          },
        ],
        'rawToolResults': [
          {'toolCallId': 'call', 'name': 'read', 'result': 'ok'},
        ],
        'supplementInsertOps': [
          {
            'kind': 'image',
            'textCharsBefore': 0,
            'forceAppendToTail': false,
            'localPath': '/tmp/a.png',
          },
          {
            'kind': 'audio',
            'textCharsBefore': 3,
            'forceAppendToTail': false,
            'audioUrl': 'file:///tmp/a.wav',
            'text': '语音',
            'unread': true,
          },
        ],
        'runStatus': 'truncated',
        'stopReason': 'length',
      });
      final first = projection.projectMessage(message);
      final second = projection.projectMessage(message);
      expect(encoded(first), encoded(second));
      expect(first.map((m) => m.id).toSet(), hasLength(first.length));
      for (final m in first) {
        expect(m.id, startsWith(message.id));
        for (final block in m.blocks ?? <MessageBlock>[]) {
          expect(block.messageId, m.id);
          expect(block.id, startsWith(m.id));
          expect(block.createdAt, message.createdAt);
        }
      }
      expect(first.last.rawPayload?['runStatus'], 'truncated');
      expect(first.last.rawPayload?['stopReason'], 'length');
    },
  );

  test(
    'each semantic media kind has deterministic bubble and block identities',
    () {
      final message = raw({
        'displayReplyText': '开头<tts>你好</tts><sticker tag="收到"/>结尾',
        'processedText': '开头结尾',
        'pluginEvents': [
          {
            'id': 'speech',
            'createdAt': '2026-10-25T00:00:00.000',
            'pluginId': 'tts',
            'type': 'tts_convert',
            'data': {'text': '你好'},
          },
          {
            'id': 'emoji',
            'createdAt': '2026-10-25T00:00:00.000',
            'pluginId': 'sticker',
            'type': 'sticker_convert',
            'data': {
              'tag': '收到',
              'stickerId': 'ok',
              'assetPath': '/tmp/ok.png',
            },
          },
        ],
        'pluginContents': [
          {'type': 'audio', 'localPath': '/tmp/voice.wav', 'durationMs': 1000},
          {'type': 'image', 'localPath': '/tmp/image.png', 'caption': 'cat'},
        ],
      });
      final first = projection.projectMessage(message);
      expect(first.expand((m) => m.audios), hasLength(1));
      expect(first.expand((m) => m.images), hasLength(1));
      expect(
        first
            .expand((m) => m.blocks ?? <MessageBlock>[])
            .whereType<EmojiBlock>(),
        hasLength(1),
      );
      expect(encoded(first), encoded(projection.projectMessage(message)));
    },
  );

  test('identical narratives in separate raw rounds are not deduplicated', () {
    final message = raw({
      'replyRounds': [
        {'replyText': '继续', 'processedText': '继续'},
        {'replyText': '继续', 'processedText': '继续'},
      ],
    });
    final messages = projection.projectMessage(message);
    expect(messages.map((m) => m.displayText), ['继续', '继续']);
    expect(messages.map((m) => m.id).toSet(), hasLength(2));
  });

  test('serialized display bubbles preserve interrupted status', () {
    final bubbles = ChatMessageProjectionCodec.applyRunStatus(
      [Message.text(id: 'bubble', role: 'assistant', content: '部分内容')],
      {'runStatus': 'cancelled', 'stopReason': 'userCancelled'},
    );
    final restored = ChatMessageProjectionCodec.deserializeMessages(
      ChatMessageProjectionCodec.serializeMessages(bubbles),
    );
    expect(restored.single.rawPayload?['runStatus'], 'cancelled');
    expect(restored.single.rawPayload?['stopReason'], 'userCancelled');
  });
}
