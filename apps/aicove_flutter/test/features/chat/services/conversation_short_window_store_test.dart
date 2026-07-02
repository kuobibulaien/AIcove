import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';

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

Future<File> _writeTestPng(
  String filePath, {
  required int width,
  required int height,
}) async {
  final image = img.Image(width: width, height: height);
  final bytes = img.encodePng(image);
  final file = File(filePath);
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? tempDir;

  tearDown(() async {
    if (tempDir != null && await tempDir!.exists()) {
      await tempDir!.delete(recursive: true);
    }
  });

  test('无热缓存时应从数据库尾部 raw 消息构建前端时间线', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 10, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-seed', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    for (var i = 1; i <= 24; i++) {
      await _persistMessage(
        container,
        'conv-seed',
        Message(
          id: 'm$i',
          role: i.isOdd ? 'user' : 'assistant',
          content: 'message-$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
        ),
      );
    }

    final store = container.read(conversationTimelineCacheProvider);
    final window = await store
        .watchWindow(
          conversationId: 'conv-seed',
          limit: 20,
        )
        .first;

    expect(
      window.messages.map((message) => message.id).toList(),
      List<String>.generate(20, (index) => 'm${index + 5}', growable: false),
    );
    expect(window.hasMoreMessages, isTrue);
    expect(await store.loadCachedMessageCount('conv-seed'), 20);
  });

  test('loadOlderMessages 应按 raw 分页扩展前端缓存', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 10, 30, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-page', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    for (var i = 1; i <= 30; i++) {
      await _persistMessage(
        container,
        'conv-page',
        Message(
          id: 'm$i',
          role: i.isOdd ? 'user' : 'assistant',
          content: 'message-$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
        ),
      );
    }

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore('conv-page',
        targetMessageCount: 20);
    final addedCount = await store.loadOlderMessages(
      conversationId: 'conv-page',
      pageSize: 20,
    );

    expect(addedCount, 10);
    expect(
      (await store.loadCachedMessages('conv-page'))
          .map((message) => message.id)
          .toList(),
      List<String>.generate(30, (index) => 'm${index + 1}', growable: false),
    );

    final expandedWindow = await store
        .watchWindow(
          conversationId: 'conv-page',
          limit: 40,
        )
        .first;
    expect(expandedWindow.hasMoreMessages, isFalse);
  });

  test('窗口应按 raw 消息数裁切，而不是按前端投影气泡数裁切', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 10, 45, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-projection-window', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-projection-window',
      Message.text(
        id: 'raw_old_user',
        role: 'user',
        content: '更早的一条用户消息',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );
    await _persistMessage(
      container,
      'conv-projection-window',
      Message.text(
        id: 'raw_mid_ai',
        role: 'assistant',
        content: '中间这条助手消息',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
      ),
    );
    await _persistMessage(
      container,
      'conv-projection-window',
      Message.fromBlocks(
        id: 'raw_latest_user_mixed',
        role: 'user',
        blocks: <MessageBlock>[
          TextBlock(
            messageId: 'raw_latest_user_mixed',
            content: '最新一条用户图文消息',
          ),
          ImageBlock(
            messageId: 'raw_latest_user_mixed',
            localPath: r'C:\mock\latest_image.png',
            width: 120,
            height: 80,
          ),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    final window = await store
        .watchWindow(
          conversationId: 'conv-projection-window',
          limit: 2,
        )
        .first;

    expect(
      window.messages.map((message) => message.id).toList(),
      <String>[
        'raw_mid_ai',
        'raw_latest_user_mixed__proj_00_text',
        'raw_latest_user_mixed__proj_01_image',
      ],
      reason: '最近 2 条 raw 消息中，最后一条被前端拆成 2 个气泡时，窗口仍应完整保留这 2 条 raw 的全部投影。',
    );
    expect(window.hasMoreMessages, isTrue);
    expect(
      await store.loadCachedMessageCount('conv-projection-window'),
      3,
      reason: '缓存计数应以 raw 消息数为准，而不是投影后的气泡条数。',
    );
  });

  test('共享 pending source id 的流式占位在短窗里只占一个 raw 槽位', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 10, 47, 0).millisecondsSinceEpoch;
    await _insertConversation(
      database,
      'conv-stream-placeholder-window',
      baseTime,
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-stream-placeholder-window',
      Message.text(
        id: 'raw_old_user',
        role: 'user',
        content: '更早的一条用户消息',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );
    await _persistMessage(
      container,
      'conv-stream-placeholder-window',
      Message.text(
        id: 'raw_mid_ai',
        role: 'assistant',
        content: '短窗里应该保留的上一轮助手消息',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore(
      'conv-stream-placeholder-window',
      targetMessageCount: 20,
    );
    await store.replaceMessagesTransient(
      conversationId: 'conv-stream-placeholder-window',
      messages: <Message>[
        Message.text(
          id: 'stream_part_1',
          role: 'assistant',
          content: '第一段。',
          sourceMessageId: 'raw_msg_pending_stream',
          status: 'sending',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
        ),
        Message.text(
          id: 'stream_part_2',
          role: 'assistant',
          content: '第二段。',
          sourceMessageId: 'raw_msg_pending_stream',
          status: 'sending',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 4),
        ),
      ],
    );

    final window = await store
        .watchWindow(
          conversationId: 'conv-stream-placeholder-window',
          limit: 2,
        )
        .first;

    expect(
      window.messages.map((message) => message.id).toList(),
      <String>['raw_mid_ai', 'stream_part_1', 'stream_part_2'],
      reason:
          '同一轮流式占位拆成多条前端气泡时，短窗应按共享 pending source id 把它们算作一个 raw 槽位。',
    );
    expect(window.hasMoreMessages, isTrue);
  });

  test('loadOlderMessages 返回值应按 raw 消息条数计算，而不是按投影气泡数计算', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 10, 50, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-load-older-raw-count', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-load-older-raw-count',
      Message.fromBlocks(
        id: 'raw_old_mixed',
        role: 'assistant',
        blocks: <MessageBlock>[
          TextBlock(
            messageId: 'raw_old_mixed',
            content: '更早的一条图文助手消息',
          ),
          ImageBlock(
            messageId: 'raw_old_mixed',
            localPath: r'C:\mock\older_image.png',
            width: 96,
            height: 72,
          ),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await _persistMessage(
        container,
        'conv-load-older-raw-count',
        Message.text(
          id: 'raw_seed_$i',
          role: i.isEven ? 'user' : 'assistant',
          content: 'seed-$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2 + i),
        ),
      );
    }

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore(
      'conv-load-older-raw-count',
      targetMessageCount: 20,
    );

    final addedCount = await store.loadOlderMessages(
      conversationId: 'conv-load-older-raw-count',
      pageSize: 1,
    );

    expect(addedCount, 1);
    expect(
      (await store.loadCachedMessages('conv-load-older-raw-count'))
          .map((message) => message.id)
          .toList(),
      <String>[
        'raw_old_mixed__proj_00_text',
        'raw_old_mixed__proj_01_image',
        for (var i = 0; i < 20; i++) 'raw_seed_$i',
      ],
    );
  });

  test('syncConversation 应按 raw 数据重建并清掉前端临时气泡', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 11, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-sync', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-sync',
      Message(
        id: 'raw_1',
        role: 'assistant',
        content: 'raw assistant',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore('conv-sync',
        targetMessageCount: 20);
    await store.upsertMessage(
      conversationId: 'conv-sync',
      message: Message(
        id: 'proj_1',
        role: 'assistant',
        content: 'frontend only bubble',
        sourceMessageId: 'raw_1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
      ),
    );
    expect(
      (await store.loadCachedMessages('conv-sync'))
          .map((message) => message.id),
      contains('proj_1'),
    );

    await store.reloadConversationFromRawStore('conv-sync',
        targetMessageCount: 20);

    expect(
      (await store.loadCachedMessages('conv-sync'))
          .map((message) => message.id)
          .toList(),
      <String>['raw_1'],
    );
  });

  test('前端缓存改动不应污染 raw 数据库消息', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 11, 30, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-separate', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-separate',
      Message(
        id: 'raw_1',
        role: 'assistant',
        content: 'raw content',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore('conv-separate',
        targetMessageCount: 20);
    await store.replaceMessages(
      conversationId: 'conv-separate',
      removeMessageIds: const <String>['raw_1'],
      messages: <Message>[
        Message(
          id: 'proj_1',
          role: 'assistant',
          content: 'frontend override',
          sourceMessageId: 'raw_1',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      ],
    );

    expect(
      (await store.loadCachedMessages('conv-separate')).single.content,
      'frontend override',
    );
    expect(
      (await container.read(chatHistoryStoreProvider).loadAllRawMessages(
                'conv-separate',
              ))
          .single
          .content,
      'raw content',
    );
  });

  test('transient replaceMessages 不应重写 raw projection mapping', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 11, 40, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-transient-replace', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-transient-replace',
      Message(
        id: 'raw_1',
        role: 'assistant',
        content: 'raw content',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    await store.reloadConversationFromRawStore(
      'conv-transient-replace',
      targetMessageCount: 20,
    );
    final mappingRepo =
        container.read(messageProjectionMappingRepositoryProvider);
    final beforeMappings = await mappingRepo.getByRawMessage('raw_1');

    await store.replaceMessagesTransient(
      conversationId: 'conv-transient-replace',
      removeMessageIds: const <String>['raw_1'],
      messages: <Message>[
        Message(
          id: 'proj_streaming_1',
          role: 'assistant',
          content: 'streaming content',
          sourceMessageId: 'raw_1',
          status: 'sending',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
        ),
      ],
    );

    expect(
      (await store.loadCachedMessages('conv-transient-replace')).single.id,
      'proj_streaming_1',
    );
    expect(
      await mappingRepo.getByRawMessage('raw_1'),
      beforeMappings,
      reason:
          '流式占位只应更新前台时间线，不应在每次 flush 时把 raw projection mapping 改写成临时 sending 气泡。',
    );
  });

  test('findMessageById 应优先返回当前前端缓存中的投影消息', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 12, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-find', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    await _persistMessage(
      container,
      'conv-find',
      Message(
        id: 'raw_1',
        role: 'assistant',
        content: 'raw content',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    await store.upsertMessage(
      conversationId: 'conv-find',
      message: Message(
        id: 'proj_1',
        role: 'assistant',
        content: 'frontend projection',
        sourceMessageId: 'raw_1',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
      ),
    );

    final found = await store.findCachedMessageById(
      'proj_1',
      conversationId: 'conv-find',
    );

    expect(found, isNotNull);
    expect(found!.content, 'frontend projection');
  });

  test('本地图片尺寸应在后台补齐，而不阻塞首个时间线窗口返回', () async {
    tempDir = await Directory.systemTemp.createTemp('timeline_image_dim_');

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 4, 2, 12, 30, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-image', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    final imageFile = await _writeTestPng(
      '${tempDir!.path}\\image.png',
      width: 64,
      height: 48,
    );
    await _persistMessage(
      container,
      'conv-image',
      Message.fromBlocks(
        id: 'img_1',
        role: 'assistant',
        blocks: <MessageBlock>[
          ImageBlock(
            messageId: 'img_1',
            localPath: imageFile.path,
            prompt: 'test image',
          ),
        ],
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
    );

    final store = container.read(conversationTimelineCacheProvider);
    final firstWindow = await store
        .watchWindow(
          conversationId: 'conv-image',
          limit: 20,
        )
        .first;
    final firstImageBlock =
        firstWindow.messages.single.blocks!.single as ImageBlock;
    expect(firstImageBlock.width, isNull);
    expect(firstImageBlock.height, isNull);

    ImageBlock? upgradedImageBlock;
    for (var i = 0; i < 40; i++) {
      final cachedMessages = await store.loadCachedMessages('conv-image');
      final candidate = cachedMessages.single.blocks!.single as ImageBlock;
      if (candidate.width != null && candidate.height != null) {
        upgradedImageBlock = candidate;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(upgradedImageBlock, isNotNull);
    final resolvedImageBlock = upgradedImageBlock!;
    expect(resolvedImageBlock.width, 64);
    expect(resolvedImageBlock.height, 48);
  });
}
