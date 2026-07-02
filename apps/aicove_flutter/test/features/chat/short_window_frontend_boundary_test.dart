import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_page_queries.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_deferred_image_delivery.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';

final _deferredImageDeliveryProvider = Provider<ChatDeferredImageDelivery>(
  (ref) => ChatDeferredImageDelivery(
    ref: ref,
    enqueueStoreMutation: (task) => task(),
    runBackgroundTask: (_, __) {},
  ),
);

Future<void> _insertConversation(
  db.AppDatabase database,
  String conversationId,
  int timestamp,
) {
  return database.into(database.conversations).insert(
        db.ConversationsCompanion.insert(
          id: conversationId,
          title: '测试会话',
          displayName: '测试会话',
          createdAt: timestamp,
          updatedAt: timestamp,
        ),
      );
}

Future<void> _persistMessage(
  ProviderContainer container,
  String conversationId,
  Message message,
) async {
  final messageRepo = container.read(messageRepositoryProvider);
  final blockRepo = container.read(messageBlockRepositoryProvider);
  await messageRepo.upsert(
    MessageConverter.toCompanion(message, conversationId),
  );
  final blocks = message.blocks ?? const <MessageBlock>[];
  for (var index = 0; index < blocks.length; index++) {
    await blockRepo.upsert(
      MessageBlockConverter.toCompanion(blocks[index], message.id, index),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('conversationHasImageMessages 只按前端时间线缓存语义判断', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 3, 23, 9, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv_short_window_only', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv_short_window_only',
      Message.fromBlocks(
        id: 'm1',
        role: 'assistant',
        blocks: [
          ImageBlock(
            messageId: 'm1',
            localPath: r'C:\tmp\legacy-image.png',
            prompt: 'old image',
          ),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    for (var i = 2; i <= 25; i++) {
      await _persistMessage(
        container,
        'conv_short_window_only',
        Message(
          id: 'm$i',
          role: i.isOdd ? 'user' : 'assistant',
          content: 'message-$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
        ),
      );
    }

    final hasImage = await container
        .read(chatPageQueriesProvider)
        .conversationHasImageMessages('conv_short_window_only');

    expect(hasImage, isFalse);
  });

  test('resolvePlaceholderBaseTime 以前端时间线缓存最后一条消息为准', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 3, 23, 10, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv_placeholder_base', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv_placeholder_base',
      Message(
        id: 'raw_1',
        role: 'assistant',
        content: 'raw assistant',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    final projectedTailTime = DateTime(2099, 1, 1, 0, 0, 0);
    await container.read(conversationTimelineCacheProvider).upsertMessage(
          conversationId: 'conv_placeholder_base',
          message: Message(
            id: 'proj_1',
            role: 'assistant',
            content: 'frontend only placeholder',
            sourceMessageId: 'raw_1',
            createdAt: projectedTailTime,
          ),
        );

    final resolved = await container
        .read(_deferredImageDeliveryProvider)
        .resolvePlaceholderBaseTime('conv_placeholder_base');

    expect(
      resolved,
      projectedTailTime.add(const Duration(milliseconds: 1)),
    );
  });

  test('loadFrontendMessageById 只按前端时间线缓存当前投影取消息', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 3, 23, 11, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv_frontend_message', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv_frontend_message',
      Message(
        id: 'm1',
        role: 'assistant',
        content: 'db raw text',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    await container.read(conversationTimelineCacheProvider).upsertMessage(
          conversationId: 'conv_frontend_message',
          message: Message(
            id: 'm1',
            role: 'assistant',
            content: 'frontend projection text',
            createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
          ),
        );

    final frontendMessage =
        await container.read(chatHistoryStoreProvider).loadFrontendMessageById(
              'm1',
              conversationId: 'conv_frontend_message',
            );

    expect(frontendMessage, isNotNull);
    expect(frontendMessage!.content, 'frontend projection text');
  });
}
