import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';

void main() {
  const projection = ChatFrontendMessageProjectionService();
  final at = DateTime(2026, 3, 23);
  Message snapshot(String id, List<MessageBlock> blocks, {String text = ''}) =>
      Message(
        id: id,
        role: 'assistant',
        content: text,
        createdAt: at,
        blocks: blocks,
      );

  test(
    'legacy snapshot retains identity but uses the authoritative block URL',
    () {
      final old = snapshot('old', [
        AudioBlock(id: 'voice', messageId: 'old', url: '/dead.wav'),
      ]);
      final raw = Message(
        id: 'raw',
        role: 'assistant',
        content: '',
        createdAt: at,
        blocks: [
          AudioBlock(id: 'voice', messageId: 'raw', url: '/original.wav'),
        ],
        rawPayload: {
          'projectedMessages': ChatMessageProjectionCodec.serializeMessages([
            old,
          ]),
        },
      );
      final result = projection.projectMessage(raw).single;
      expect(result.id, 'old');
      expect(result.blocks!.single.id, 'voice');
      expect((result.blocks!.single as AudioBlock).url, '/original.wav');
      expect(
        (ChatMessageProjectionCodec.projectedMessages(
                  raw.rawPayload,
                ).single.blocks!.single
                as AudioBlock)
            .url,
        '/dead.wav',
      );
    },
  );

  test('text semantics do not swallow completed snapshot media or old IDs', () {
    final raw = Message(
      id: 'raw',
      role: 'assistant',
      content: 'raw text',
      createdAt: at,
      rawPayload: {
        'processedText': '前 文后文',
        'projectedMessages': ChatMessageProjectionCodec.serializeMessages([
          snapshot('text1', [], text: '前 文'),
          snapshot('old-image', [
            ImageBlock(
              id: 'image',
              messageId: 'old-image',
              localPath: '/image.png',
            ),
          ]),
          snapshot('text2', [], text: '后文'),
          snapshot('old-audio', [
            AudioBlock(
              id: 'audio',
              messageId: 'old-audio',
              url: '/audio.wav',
              text: '声音',
            ),
          ]),
        ]),
      },
    );
    final result = projection.projectMessage(raw);
    expect(
      result
          .expand((m) => m.blocks ?? <MessageBlock>[])
          .whereType<ImageBlock>()
          .single
          .localPath,
      '/image.png',
    );
    expect(
      result
          .expand((m) => m.blocks ?? <MessageBlock>[])
          .whereType<AudioBlock>()
          .single
          .url,
      '/audio.wav',
    );
    expect(
      result.where((m) => m.id == 'old-image').single.blocks!.single.id,
      'image',
    );
    expect(
      result.where((m) => m.id == 'old-audio').single.blocks!.single.id,
      'audio',
    );
    expect(result.map((m) => m.content).join(), '前 文后文');
  });

  test(
    'normalization is idempotent and counts non-whitespace text inside blocks',
    () {
      final payload = {
        'processedText': '甲 乙丙',
        'projectedMessages': ChatMessageProjectionCodec.serializeMessages([
          snapshot('mixed', [
            TextBlock(id: 'text', messageId: 'mixed', content: '甲 乙'),
            ImageBlock(
              id: 'image',
              messageId: 'mixed',
              localPath: '/image.png',
            ),
          ]),
          snapshot('tail', [], text: '丙'),
        ]),
      };
      Map<String, dynamic>? normalize(Map<String, dynamic>? value) =>
          ChatMessageProjectionCodec.normalizeLegacyMediaPayload(
            rawMessageId: 'raw',
            role: 'assistant',
            payload: value,
          );
      final normalized = normalize(payload)!;
      final op = ChatMessageProjectionCodec.supplementInsertOps(
        normalized,
      ).single;
      expect(op.textCharsBefore, 2);
      expect(op.forceAppendToTail, isFalse);
      expect(identical(normalized, normalize(normalized)), isTrue);
    },
  );

  test(
    'existing media results and pending snapshot blocks are never promoted twice',
    () {
      final cached = ChatMessageProjectionCodec.serializeMessages([
        snapshot('old', [
          ImageBlock(id: 'image', messageId: 'old', localPath: '/old.png'),
        ]),
      ]);
      for (final media in [
        {
          'pluginContents': [
            {'type': 'image', 'localPath': '/new.png'},
          ],
        },
        {
          'toolAudioResults': [
            {'audioUrl': '/new.wav', 'text': '新'},
          ],
        },
        {
          'replyRounds': [
            {
              'replyText': '新',
              'pluginContents': [
                {'type': 'image', 'localPath': '/new.png'},
              ],
            },
          ],
        },
      ]) {
        final payload = <String, dynamic>{
          'processedText': '新',
          'projectedMessages': cached,
          ...media,
        };
        final normalized =
            ChatMessageProjectionCodec.normalizeLegacyMediaPayload(
              rawMessageId: 'raw',
              role: 'assistant',
              payload: payload,
            );
        expect(normalized, same(payload));
        expect(
          ChatMessageProjectionCodec.supplementInsertOps(normalized),
          isEmpty,
        );
      }
      (cached.single['blocks'] as List).single['status'] = 'pending';
      final pending = <String, dynamic>{
        'processedText': '正文',
        'projectedMessages': cached,
      };
      expect(
        ChatMessageProjectionCodec.normalizeLegacyMediaPayload(
          rawMessageId: 'raw',
          role: 'assistant',
          payload: pending,
        ),
        same(pending),
      );
    },
  );
}
