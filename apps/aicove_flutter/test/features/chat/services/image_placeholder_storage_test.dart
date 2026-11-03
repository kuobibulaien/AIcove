import 'dart:convert';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/block_status.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_media_regeneration.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late db.AppDatabase database;
  late ProviderContainer container;
  late ChatHistoryStore store;
  late ConversationTimelineCache timeline;
  final time = DateTime(2026, 10, 26);

  Message pending({String? source = 'raw'}) => Message.fromBlocks(
    id: 'pending',
    role: 'assistant',
    status: 'sent',
    sourceMessageId: source,
    createdAt: time,
    blocks: [
      ImageBlock(
        id: 'pending__b0_image',
        messageId: 'pending',
        prompt: 'private image prompt',
        width: 832,
        height: 1216,
        status: BlockStatus.pending,
      ),
    ],
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    store = container.read(chatHistoryStoreProvider);
    timeline = container.read(conversationTimelineCacheProvider);
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'conv',
            title: 'test',
            displayName: 'test',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await store.appendMessage(
      conversationId: 'conv',
      message: Message(
        id: 'raw',
        role: 'assistant',
        content: 'beforeafter',
        createdAt: time,
        rawPayload: {
          'rawReplyText': 'before<image>private image prompt</image>after',
          'displayReplyText': 'beforeafter',
          'processedText': 'beforeafter',
        },
      ),
    );
    await timeline.replaceMessagesTransient(
      conversationId: 'conv',
      removeMessageIds: (await timeline.loadCachedMessages(
        'conv',
      )).map((m) => m.id).toList(),
      messages: [
        Message(
          id: 'before',
          role: 'assistant',
          content: 'before',
          sourceMessageId: 'raw',
          createdAt: time,
        ),
        Message(
          id: 'after',
          role: 'assistant',
          content: 'after',
          sourceMessageId: 'raw',
          createdAt: time,
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test(
    'pending with or without a raw source stays entirely transient',
    () async {
      for (final source in <String?>['raw', null]) {
        await store.appendMessage(
          conversationId: 'conv',
          message: pending(source: source),
        );
        expect(
          (await timeline.loadCachedMessages(
            'conv',
          )).any((m) => m.id == 'pending'),
          isTrue,
        );
        expect(await database.select(database.messages).get(), hasLength(1));
        expect(await database.select(database.messageBlocks).get(), isEmpty);
        final projected = await store.loadProjectedMessagesFromRawStore('conv');
        expect(
          projected
              .expand((m) => m.blocks ?? <MessageBlock>[])
              .whereType<ImageBlock>(),
          isEmpty,
        );
      }
    },
  );

  test('pending is excluded from legacy projectedMessages fallback', () async {
    await database.customStatement(
      "UPDATE messages SET raw_payload=NULL WHERE id='raw'",
    );
    await store.appendMessage(conversationId: 'conv', message: pending());
    await store.syncRawSupplementsFromTimeline(
      conversationId: 'conv',
      rawMessageIds: {'raw'},
    );
    final raw = (await database.select(database.messages).get()).single;
    expect(raw.rawPayload, isNot(contains('private image prompt')));
    expect(raw.rawPayload, isNot(contains('pending__b0_image')));
  });

  test(
    'multiple completed images persist dimensions and reproject in place',
    () async {
      await store.insertMessagesAroundAnchor(
        conversationId: 'conv',
        anchorIds: ['before', 'after'],
        insertOps: [
          ConversationSupplementInsertOp(
            textCharsBefore: 6,
            message: pending(),
          ),
        ],
      );
      await store.updateMessage(
        conversationId: 'conv',
        message: Message.fromBlocks(
          id: 'pending',
          role: 'assistant',
          sourceMessageId: 'raw',
          createdAt: time,
          blocks: [
            ImageBlock(
              id: 'first',
              messageId: 'pending',
              localPath: '/first.png',
              prompt: 'first',
              width: 23,
              height: 41,
            ),
            ImageBlock(
              id: 'second',
              messageId: 'pending',
              localPath: '/second.png',
              prompt: 'second',
              width: 51,
              height: 17,
            ),
          ],
        ),
      );
      final result = await store.loadProjectedMessagesFromRawStore('conv');
      final images = result
          .expand((m) => m.blocks ?? <MessageBlock>[])
          .whereType<ImageBlock>()
          .toList();
      expect(images.map((b) => (b.localPath, b.width, b.height)), [
        ('/first.png', 23, 41),
        ('/second.png', 51, 17),
      ]);
      expect(result.map((m) => m.displayText), [
        'before',
        '[图片]',
        '[图片]',
        'after',
      ]);
      final raw = (await database.select(database.messages).get()).single;
      final payload = jsonDecode(raw.rawPayload!) as Map<String, dynamic>;
      expect(
        ChatMessageProjectionCodec.supplementInsertOps(payload),
        hasLength(2),
      );
      expect(ChatMessageProjectionCodec.pluginContents(payload), hasLength(2));
      final target = await store.loadMediaRegenerationTarget(
        conversationId: 'conv',
        messageId: 'pending',
        blockId: 'second',
      );
      await store.replaceGeneratedMedia(
        conversationId: 'conv',
        target: target,
        result: const GeneratedChatMedia.image(
          '/new.png',
          width: 11,
          height: 29,
        ),
      );
      final regenerated =
          (await store.loadProjectedMessagesFromRawStore('conv'))
              .expand((m) => m.blocks ?? <MessageBlock>[])
              .whereType<ImageBlock>()
              .toList();
      expect(regenerated.map((b) => b.localPath), ['/first.png', '/new.png']);
      expect((regenerated.last.width, regenerated.last.height), (11, 29));
    },
  );

  test(
    'raw refresh retains pending in its semantic position, not after merged text',
    () async {
      await store.insertMessagesAroundAnchor(
        conversationId: 'conv',
        anchorIds: ['before', 'after'],
        insertOps: [
          ConversationSupplementInsertOp(
            textCharsBefore: 6,
            message: pending(),
          ),
        ],
      );
      await timeline.refreshConversationsFromRawStore({
        'conv',
      }, canRefresh: (_) => true);
      final result = await timeline.loadCachedMessages('conv');
      expect(result.map((m) => m.displayText), ['before', '[图片]', 'after']);
      expect(result[1].id, 'pending');
      expect(
        (await database.select(database.messageProjectionMappings).get()).any(
          (mapping) => mapping.projectedMessageId == 'pending',
        ),
        isFalse,
      );
      await database.customStatement(
        "UPDATE messages SET deleted_at=1 WHERE id='raw'",
      );
      await timeline.refreshConversationsFromRawStore({
        'conv',
      }, canRefresh: (_) => true);
      expect(
        (await timeline.loadCachedMessages(
          'conv',
        )).any((m) => m.id == 'pending'),
        isFalse,
      );
    },
  );

  test('an image-only raw keeps its pending display through a refresh', () async {
    await database.customStatement('UPDATE messages SET content=?, raw_payload=? WHERE id=?',
      ['', jsonEncode({'displayReplyText': '', 'processedText': '', 'rawReplyText': '<image>cat</image>'}), 'raw']);
    await store.appendMessage(conversationId: 'conv', message: pending());
    await timeline.refreshConversationsFromRawStore({'conv'}, canRefresh: (_) => true);
    expect((await timeline.loadCachedMessages('conv')).map((m) => m.id), ['pending']);
  });

  test(
    'regeneration replaces intrinsic dimensions, including unknown dimensions',
    () {
      final original = ImageBlock(
        messageId: 'old',
        localPath: '/old.png',
        width: 400,
        height: 600,
      );
      final known =
          const GeneratedChatMedia.image(
                '/new.png',
                width: 20,
                height: 30,
              ).replace(original)
              as ImageBlock;
      expect((known.width, known.height), (20, 30));
      final unknown =
          const GeneratedChatMedia.image('/unknown.png').replace(original)
              as ImageBlock;
      expect((unknown.width, unknown.height), (null, null));
    },
  );
}
