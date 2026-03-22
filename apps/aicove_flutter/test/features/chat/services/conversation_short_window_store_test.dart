import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

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

String _snapshotFilePath(String rootPath, String conversationId) {
  final encoded =
      base64UrlEncode(utf8.encode(conversationId)).replaceAll('=', '');
  return p.join(
    rootPath,
    kConversationShortWindowRootDirectoryName,
    encoded,
    'window.json',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform previousPathProvider;
  Directory? tempDir;

  setUp(() {
    previousPathProvider = PathProviderPlatform.instance;
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPathProvider;
    if (tempDir != null && await tempDir!.exists()) {
      await tempDir!.delete(recursive: true);
    }
  });

  test('短列表首屏应返回最近 20 条原始消息', () async {
    tempDir = await Directory.systemTemp.createTemp('short_window_seed_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 3, 22, 10, 0, 0).millisecondsSinceEpoch;
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

    final store = container.read(conversationShortWindowStoreProvider);
    final window = await store
        .watchWindow(
          conversationId: 'conv-seed',
          limit: 20,
        )
        .first;

    expect(
      window.messages.map((message) => message.id).toList(),
      <String>[
        'm5',
        'm6',
        'm7',
        'm8',
        'm9',
        'm10',
        'm11',
        'm12',
        'm13',
        'm14',
        'm15',
        'm16',
        'm17',
        'm18',
        'm19',
        'm20',
        'm21',
        'm22',
        'm23',
        'm24',
      ],
    );
    expect(window.hasMoreMessages, isTrue);
  });

  test('上滑扩展后应把更多原始消息持久化到短列表文件', () async {
    tempDir = await Directory.systemTemp.createTemp('short_window_expand_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 3, 22, 11, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-expand', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    for (var i = 1; i <= 30; i++) {
      await _persistMessage(
        container,
        'conv-expand',
        Message(
          id: 'm$i',
          role: i.isOdd ? 'user' : 'assistant',
          content: 'message-$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
        ),
      );
    }

    final store = container.read(conversationShortWindowStoreProvider);
    final initialWindow = await store
        .watchWindow(
          conversationId: 'conv-expand',
          limit: 20,
        )
        .first;
    expect(
      initialWindow.messages.map((message) => message.id).toList(),
      <String>[
        'm11',
        'm12',
        'm13',
        'm14',
        'm15',
        'm16',
        'm17',
        'm18',
        'm19',
        'm20',
        'm21',
        'm22',
        'm23',
        'm24',
        'm25',
        'm26',
        'm27',
        'm28',
        'm29',
        'm30',
      ],
    );

    final expandedWindow = await store
        .watchWindow(
          conversationId: 'conv-expand',
          limit: 25,
        )
        .first;
    expect(
      expandedWindow.messages.map((message) => message.id).toList(),
      <String>[
        'm6',
        'm7',
        'm8',
        'm9',
        'm10',
        'm11',
        'm12',
        'm13',
        'm14',
        'm15',
        'm16',
        'm17',
        'm18',
        'm19',
        'm20',
        'm21',
        'm22',
        'm23',
        'm24',
        'm25',
        'm26',
        'm27',
        'm28',
        'm29',
        'm30',
      ],
    );
    expect(expandedWindow.hasMoreMessages, isTrue);

    final snapshotFile = File(_snapshotFilePath(tempDir!.path, 'conv-expand'));
    final snapshot = jsonDecode(await snapshotFile.readAsString()) as Map;
    final rawMessages = (snapshot['messages'] as List).cast<Map>();
    expect(rawMessages.length, 25);
  });

  test('replaceMessages 应原位替换流式临时消息而不清空其余短列表', () async {
    tempDir = await Directory.systemTemp.createTemp('short_window_replace_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 3, 22, 11, 20, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-replace', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    final store = container.read(conversationShortWindowStoreProvider);
    await store.upsertMessages(
      conversationId: 'conv-replace',
      messages: <Message>[
        Message(
          id: 'm1',
          role: 'user',
          content: 'user-1',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
        ),
        Message(
          id: 'temp-1',
          role: 'assistant',
          content: '第一段。',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
          status: 'sending',
        ),
        Message(
          id: 'temp-2',
          role: 'assistant',
          content: '第二段。',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
          status: 'sending',
        ),
      ],
    );

    await store.replaceMessages(
      conversationId: 'conv-replace',
      removeMessageIds: const <String>['temp-1', 'temp-2'],
      messages: <Message>[
        Message(
          id: 'msg-final',
          role: 'assistant',
          content: '第一段。第二段。',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 4),
          status: 'sent',
        ),
      ],
    );

    final window = await store
        .watchWindow(
          conversationId: 'conv-replace',
          limit: 20,
        )
        .first;
    expect(
      window.messages.map((message) => message.id).toList(),
      <String>['m1', 'msg-final'],
    );
    expect(window.messages.last.displayText, '第一段。第二段。');
  });

  test('loadOlderMessages 应保留短列表尾部临时收口消息，只向前补历史页', () async {
    tempDir = await Directory.systemTemp.createTemp('short_window_load_older_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 3, 22, 11, 25, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-load-older', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    for (var i = 1; i <= 30; i++) {
      await _persistMessage(
        container,
        'conv-load-older',
        Message(
          id: 'm$i',
          role: i.isOdd ? 'user' : 'assistant',
          content: 'message-$i',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + i),
        ),
      );
    }

    final store = container.read(conversationShortWindowStoreProvider);
    final initialWindow = await store
        .watchWindow(
          conversationId: 'conv-load-older',
          limit: 20,
        )
        .first;
    expect(initialWindow.messages.first.id, 'm11');

    await store.upsertMessages(
      conversationId: 'conv-load-older',
      messages: <Message>[
        Message(
          id: 'local-stream-final',
          role: 'assistant',
          content: 'stream-final',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 100),
          status: 'sent',
        ),
      ],
    );

    final addedCount = await store.loadOlderMessages(
      conversationId: 'conv-load-older',
      pageSize: 5,
    );
    expect(addedCount, 5);

    final expandedWindow = await store
        .watchWindow(
          conversationId: 'conv-load-older',
          limit: 26,
        )
        .first;
    expect(
      expandedWindow.messages.map((message) => message.id).toList(),
      <String>[
        'm6',
        'm7',
        'm8',
        'm9',
        'm10',
        'm11',
        'm12',
        'm13',
        'm14',
        'm15',
        'm16',
        'm17',
        'm18',
        'm19',
        'm20',
        'm21',
        'm22',
        'm23',
        'm24',
        'm25',
        'm26',
        'm27',
        'm28',
        'm29',
        'm30',
        'local-stream-final',
      ],
    );
    expect(expandedWindow.hasMoreMessages, isTrue);
  });

  test('短列表重建应回退到数据库原始消息并移除前端临时快照', () async {
    tempDir = await Directory.systemTemp.createTemp('short_window_rebuild_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 3, 22, 11, 30, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-rebuild', baseTime);

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);

    final dbMessages = <Message>[
      Message(
        id: 'm1',
        role: 'user',
        content: 'db-user',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
      ),
      Message(
        id: 'm2',
        role: 'assistant',
        content: 'db-assistant',
        createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 2),
      ),
    ];
    for (final message in dbMessages) {
      await _persistMessage(container, 'conv-rebuild', message);
    }

    final store = container.read(conversationShortWindowStoreProvider);
    await store.upsertMessages(
      conversationId: 'conv-rebuild',
      messages: <Message>[
        Message(
          id: 'stale-segment-1',
          role: 'assistant',
          content: 'stale-segment',
          createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 3),
        ),
      ],
    );

    final staleWindow = await store
        .watchWindow(
          conversationId: 'conv-rebuild',
          limit: 20,
        )
        .first;
    expect(
      staleWindow.messages.map((message) => message.id).toList(),
      <String>['m1', 'm2', 'stale-segment-1'],
    );

    await store.rebuildAllFromDb();

    final rebuiltWindow = await store
        .watchWindow(
          conversationId: 'conv-rebuild',
          limit: 20,
        )
        .first;
    expect(
      rebuiltWindow.messages.map((message) => message.id).toList(),
      <String>['m1', 'm2'],
    );

    final snapshotFile = File(_snapshotFilePath(tempDir!.path, 'conv-rebuild'));
    final snapshot = jsonDecode(await snapshotFile.readAsString()) as Map;
    final ids = ((snapshot['messages'] as List).cast<Map>())
        .map((raw) => raw['id'] as String)
        .toList(growable: false);
    expect(ids, <String>['m1', 'm2']);
  });

  test('图片和语音消息应落为短列表自有本地文件并可跨重启恢复', () async {
    tempDir = await Directory.systemTemp.createTemp('short_window_media_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);

    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final baseTime = DateTime(2026, 3, 22, 12, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-media', baseTime);

    final sourceImage = File(p.join(tempDir!.path, 'source.jpg'));
    await sourceImage.writeAsBytes(<int>[1, 2, 3, 4, 5], flush: true);

    final audioBytes = base64Encode(<int>[82, 73, 70, 70, 1, 2, 3, 4]);
    final mediaMessage = Message.fromBlocks(
      id: 'msg-media',
      role: 'assistant',
      blocks: <MessageBlock>[
        ImageBlock(
          messageId: 'msg-media',
          localPath: sourceImage.path,
        ),
        AudioBlock(
          messageId: 'msg-media',
          url: 'data:audio/wav;base64,$audioBytes',
          text: 'hello',
        ),
        TextBlock(
          messageId: 'msg-media',
          content: 'hello',
        ),
      ],
      createdAt: DateTime.fromMillisecondsSinceEpoch(baseTime + 1),
    );

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);
    await _persistMessage(container, 'conv-media', mediaMessage);

    final store = container.read(conversationShortWindowStoreProvider);
    final window = await store
        .watchWindow(
          conversationId: 'conv-media',
          limit: 20,
        )
        .first;
    final message = window.messages.single;
    final imageBlock = message.blocks!.whereType<ImageBlock>().single;
    final audioBlock = message.blocks!.whereType<AudioBlock>().single;

    expect(imageBlock.localPath, isNotNull);
    expect(imageBlock.localPath, isNot(equals(sourceImage.path)));
    expect(await File(imageBlock.localPath!).exists(), isTrue);
    expect(audioBlock.url.startsWith('data:'), isFalse);
    expect(await File(audioBlock.url).exists(), isTrue);

    final restartedContainer = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(restartedContainer.dispose);
    final restartedStore =
        restartedContainer.read(conversationShortWindowStoreProvider);
    final restartedWindow = await restartedStore
        .watchWindow(
          conversationId: 'conv-media',
          limit: 20,
        )
        .first;
    final restartedMessage = restartedWindow.messages.single;
    final restartedImage =
        restartedMessage.blocks!.whereType<ImageBlock>().single;
    final restartedAudio =
        restartedMessage.blocks!.whereType<AudioBlock>().single;

    expect(restartedImage.localPath, equals(imageBlock.localPath));
    expect(restartedAudio.url, equals(audioBlock.url));
  });
}
