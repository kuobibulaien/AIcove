import 'dart:convert';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  final time = DateTime(2026, 10, 25);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'c',
            title: 'test',
            displayName: 'test',
            createdAt: 0,
            updatedAt: 0,
          ),
        );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  Message message(
    String id,
    List<MessageBlock> blocks, {
    String content = '',
  }) => Message(
    id: id,
    role: 'assistant',
    sourceMessageId: 'raw',
    content: content,
    blocks: blocks,
    createdAt: time,
  );

  AudioBlock audio(
    String id, {
    String url = '',
    String? text = '  语音正文  ',
    BlockStatus status = BlockStatus.pending,
  }) => AudioBlock(
    id: '${id}_audio',
    messageId: id,
    url: url,
    text: text,
    status: status,
    createdAt: time,
  );

  Future<void> insertRaw(Map<String, dynamic> payload) async {
    await database
        .into(database.messages)
        .insert(
          db.MessagesCompanion.insert(
            id: 'raw',
            conversationId: 'c',
            role: 'assistant',
            content: '模型原文',
            createdAt: time.millisecondsSinceEpoch,
            rawPayload: Value(jsonEncode(payload)),
          ),
        );
  }

  Future<Map<String, dynamic>> storedPayload() async =>
      jsonDecode(
            (await container.read(messageRepositoryProvider).getById('raw'))!
                .rawPayload!,
          )
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> sync(
    List<Message> messages, {
    Map<String, dynamic> payload = const {},
  }) async {
    await insertRaw(payload);
    final cache = container.read(conversationTimelineCacheProvider);
    final seeded = await cache.loadCachedMessages('c');
    await cache.replaceMessages(
      conversationId: 'c',
      removeMessageIds: [for (final m in seeded) m.id],
      messages: messages,
    );
    await container
        .read(chatHistoryStoreProvider)
        .syncRawSupplementsFromTimeline(
          conversationId: 'c',
          rawMessageIds: {'raw'},
        );
    return storedPayload();
  }

  test(
    'sync stores pending audio as trimmed text without mutating live blocks',
    () async {
      final pending = audio('pending');
      final live = message('pending', [pending]);
      final payload = await sync([live]);
      final stored = (payload['projectedMessages'] as List).single as Map;
      expect(stored['content'], '语音正文');
      final block = (stored['blocks'] as List).single as Map;
      expect(block['type'], 'mainText');
      expect(block['id'], pending.id);
      expect(block['messageId'], live.id);
      expect(block['content'], '语音正文');
      expect(block['status'], 'success');
      final cached = await container
          .read(conversationTimelineCacheProvider)
          .findCachedMessageById('pending', conversationId: 'c');
      expect(cached!.blocks!.single, same(pending));
      expect(cached.content, isEmpty);
      expect(pending.status, BlockStatus.pending);
    },
  );

  test(
    'mixed blocks downgrade empty-url and pending audio but retain successful audio',
    () async {
      final prefix = TextBlock(
        id: 'prefix',
        messageId: 'mixed',
        content: '前文',
        createdAt: time,
      );
      final ready = audio(
        'mixed',
        url: 'file:///ready.wav',
        status: BlockStatus.success,
      );
      final blocks = [
        prefix,
        audio('empty_url', status: BlockStatus.success),
        audio('pending_url', url: 'file:///not_ready.wav'),
        ready,
      ];
      final payload = await sync([message('mixed', blocks, content: '原有兼容文字')]);
      final stored = ChatMessageProjectionCodec.projectedMessages(
        payload,
      ).single;
      expect(stored.content, '原有兼容文字');
      expect(stored.blocks!.map((b) => b.runtimeType), [
        TextBlock,
        TextBlock,
        TextBlock,
        AudioBlock,
      ]);
      expect((stored.blocks![1] as TextBlock).content, '语音正文');
      expect((stored.blocks![2] as TextBlock).messageId, 'mixed');
      expect((stored.blocks!.last as AudioBlock).toJson(), ready.toJson());
    },
  );

  test('audio without usable text is not downgraded', () async {
    final payload = await sync([
      message('blank', [audio('blank', text: '  ')]),
    ]);
    final stored = ChatMessageProjectionCodec.projectedMessages(payload).single;
    expect(stored.content, isEmpty);
    expect(stored.blocks!.single, isA<AudioBlock>());
  });

  test(
    'semantic supplements retain existing anchor and do not restart snapshots',
    () async {
      final pending = message('pending', [audio('pending', text: '  中间  ')]);
      final payload = await sync(
        [
          Message.text(
            id: 'before',
            role: 'assistant',
            sourceMessageId: 'raw',
            content: '前',
            createdAt: time,
          ),
          pending,
          message('ready', [
            audio(
              'ready',
              url: 'file:///ready.wav',
              text: '完成',
              status: BlockStatus.success,
            ),
          ]),
          Message.text(
            id: 'after',
            role: 'assistant',
            sourceMessageId: 'raw',
            content: '后',
            createdAt: time,
          ),
        ],
        payload: {'displayReplyText': '前中间后', 'processedText': '前中间后'},
      );
      expect(payload.containsKey('projectedMessages'), isFalse);
      final op = ChatMessageProjectionCodec.supplementInsertOps(payload).single;
      expect(op.textCharsBefore, 1);
      expect(op.audioUrl, 'file:///ready.wav');
      expect(
        ChatMessageProjectionCodec.toolAudioResults(payload).single.audioUrl,
        'file:///ready.wav',
      );
      expect(payload['displayReplyText'], '前中间后');
      expect(payload['processedText'], '前中间后');
    },
  );

  test('successful synthesis replaces fallback with persisted audio', () async {
    final pending = message('voice', [audio('voice')]);
    await sync([pending]);
    final ready = message('voice', [
      audio('voice', url: 'file:///done.wav', status: BlockStatus.success),
    ]);
    await container
        .read(conversationTimelineCacheProvider)
        .upsertMessage(conversationId: 'c', message: ready);
    await container
        .read(chatHistoryStoreProvider)
        .syncRawSupplementsFromTimeline(
          conversationId: 'c',
          rawMessageIds: {'raw'},
        );
    final payload = await storedPayload();
    expect(
      ChatMessageProjectionCodec.toolAudioResults(payload).single.audioUrl,
      'file:///done.wav',
    );
    final reloaded = await container
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore('c');
    expect(
      reloaded
          .expand((m) => m.blocks ?? <MessageBlock>[])
          .whereType<AudioBlock>()
          .single
          .url,
      'file:///done.wav',
    );
  });

  test(
    'legacy empty-url audio is read as text without changing stored payload',
    () async {
      final old = message('legacy', [
        audio('legacy', status: BlockStatus.success),
      ]);
      final payload = ChatMessageProjectionCodec.copyWithProjectedMessages(
        null,
        [old],
      );
      await insertRaw(payload);
      final before =
          (await container.read(messageRepositoryProvider).getById('raw'))!
              .rawPayload;
      final output = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore('c');
      expect(output.single.content, '语音正文');
      final block = output.single.blocks!.single as TextBlock;
      expect(block.id, old.blocks!.single.id);
      expect(block.messageId, old.id);
      expect(block.status, BlockStatus.success);
      expect(
        (await container.read(messageRepositoryProvider).getById('raw'))!
            .rawPayload,
        before,
      );
      expect(
        (payload['projectedMessages'] as List).single['blocks'].single['type'],
        'audio',
      );
    },
  );

  test(
    'passthrough raw message with legacy empty-url audio block in message_blocks is read as text',
    () async {
      await database
          .into(database.messages)
          .insert(
            db.MessagesCompanion.insert(
              id: 'raw_passthrough',
              conversationId: 'c',
              role: 'assistant',
              content: '',
              createdAt: time.millisecondsSinceEpoch,
            ),
          );
      await database
          .into(database.messageBlocks)
          .insert(
            db.MessageBlocksCompanion.insert(
              id: 'legacy_audio_block',
              messageId: 'raw_passthrough',
              type: 'audio',
              status: const Value('pending'),
              sortOrder: const Value(0),
              data: jsonEncode(
                audio(
                  'raw_passthrough',
                  url: '',
                  text: '  直通语音回退文字  ',
                  status: BlockStatus.pending,
                ).toJson(),
              ),
              createdAt: time.millisecondsSinceEpoch,
            ),
          );
      final output = await container
          .read(chatHistoryStoreProvider)
          .loadProjectedMessagesFromRawStore('c');
      expect(output.single.content, '直通语音回退文字');
      final block = output.single.blocks!.single as TextBlock;
      expect(block.id, 'raw_passthrough_audio');
      expect(block.content, '直通语音回退文字');
      expect(block.status, BlockStatus.success);
    },
  );

  test(
    'semantic pending cold reload stays snapshot-free and late audio still persists',
    () async {
      final pending = message('voice', [audio('voice', text: '中间')]);
      const display = '前<tts>中间</tts>后';
      await sync(
        [
          Message.text(
            id: 'before',
            role: 'assistant',
            sourceMessageId: 'raw',
            content: '前',
            createdAt: time,
          ),
          pending,
          Message.text(
            id: 'after',
            role: 'assistant',
            sourceMessageId: 'raw',
            content: '后',
            createdAt: time,
          ),
        ],
        payload: {
          'rawReplyText': display,
          'displayReplyText': display,
          'processedText': display,
          'pluginEvents': [
            {
              'id': 'tts',
              'pluginId': 'tts',
              'type': 'tts_convert',
              'data': <String, dynamic>{},
              'createdAt': time.toIso8601String(),
            },
          ],
        },
      );
      container.dispose();
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      final store = container.read(chatHistoryStoreProvider);
      final cold = await store.loadCachedTimelineMessages('c');
      await store.updateMessage(
        conversationId: 'c',
        message: pending.copyWith(
          blocks: [
            audio(
              'voice',
              url: 'file:///late.wav',
              text: '中间',
              status: BlockStatus.success,
            ),
          ],
        ),
      );
      final canonical = await store.loadProjectedMessagesFromRawStore('c');
      expect(
        cold.expand((m) => m.audios).where((b) => b.url.trim().isEmpty),
        isEmpty,
      );
      expect(canonical.expand((m) => m.audios).single.url, 'file:///late.wav');
      final payload = await storedPayload();
      expect(payload.containsKey('projectedMessages'), isFalse);
      expect(payload['rawReplyText'], display);
      expect(payload['displayReplyText'], display);
      expect(payload['processedText'], display);
      expect((await store.loadAllRawMessages('c')).single.content, '模型原文');
    },
  );
}
