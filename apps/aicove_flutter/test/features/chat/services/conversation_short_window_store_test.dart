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

  test('缓存层应补全本地图片尺寸而不回写第二套持久时间线', () async {
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

    final messages = await container
        .read(conversationTimelineCacheProvider)
        .loadCachedMessages('conv-image');
    final imageBlock = messages.single.blocks!.single as ImageBlock;

    expect(imageBlock.width, 64);
    expect(imageBlock.height, 48);
  });
}
