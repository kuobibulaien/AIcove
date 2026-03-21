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

  test('短列表首屏应返回最近 5 条原始消息', () async {
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

    for (var i = 1; i <= 7; i++) {
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
          limit: 5,
        )
        .first;

    expect(
      window.messages.map((message) => message.id).toList(),
      <String>['m3', 'm4', 'm5', 'm6', 'm7'],
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

    for (var i = 1; i <= 12; i++) {
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
          limit: 5,
        )
        .first;
    expect(
      initialWindow.messages.map((message) => message.id).toList(),
      <String>['m8', 'm9', 'm10', 'm11', 'm12'],
    );

    final expandedWindow = await store
        .watchWindow(
          conversationId: 'conv-expand',
          limit: 10,
        )
        .first;
    expect(
      expandedWindow.messages.map((message) => message.id).toList(),
      <String>['m3', 'm4', 'm5', 'm6', 'm7', 'm8', 'm9', 'm10', 'm11', 'm12'],
    );
    expect(expandedWindow.hasMoreMessages, isTrue);

    final snapshotFile = File(_snapshotFilePath(tempDir!.path, 'conv-expand'));
    final snapshot = jsonDecode(await snapshotFile.readAsString()) as Map;
    final rawMessages = (snapshot['messages'] as List).cast<Map>();
    expect(rawMessages.length, 10);
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
          limit: 5,
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
          limit: 5,
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
