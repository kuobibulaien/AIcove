import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
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

Future<void> _insertMessage(
  db.AppDatabase database,
  String conversationId, {
  required String id,
  required String role,
  required String content,
  required int createdAt,
}) {
  return database.into(database.messages).insert(
        db.MessagesCompanion.insert(
          id: id,
          conversationId: conversationId,
          role: role,
          content: content,
          createdAt: createdAt,
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('聊天首屏窗口默认应为 20 条消息', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final visibleCount =
        container.read(conversationVisibleCountProvider('conv-1'));

    expect(kConversationInitialVisibleCount, 20);
    expect(kConversationVisiblePageSize, 20);
    expect(visibleCount, kConversationInitialVisibleCount);
  });

  test('分页加载应按 20 轮递增', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier =
        container.read(conversationVisibleCountProvider('conv-2').notifier);

    notifier.state += kConversationVisiblePageSize;

    expect(
      container.read(conversationVisibleCountProvider('conv-2')),
      kConversationInitialVisibleCount + kConversationVisiblePageSize,
    );
  });

  test('真实时间线应按最近 20 条原始消息收口，并在本地扩展后继续展示更多消息', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final baseTime = DateTime(2026, 3, 19, 10, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-turn-window', baseTime);

    final rows = List<({String id, String role, int offset})>.generate(
      30,
      (index) => (
        id: 'm${index + 1}',
        role: index.isEven ? 'user' : 'assistant',
        offset: index,
      ),
      growable: false,
    );
    for (final row in rows) {
      await _insertMessage(
        database,
        'conv-turn-window',
        id: row.id,
        role: row.role,
        content: row.id,
        createdAt: baseTime + row.offset,
      );
    }

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(container.dispose);
    final windowSubscription =
        container.listen<AsyncValue<ConversationMessageWindow>>(
      conversationMessageWindowProvider('conv-turn-window'),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(windowSubscription.close);

    await container
        .read(conversationTimelineCacheProvider)
        .reloadConversationFromRawStore(
          'conv-turn-window',
          targetMessageCount: 20,
        );

    final initialWindow = await container.read(
      conversationMessageWindowProvider('conv-turn-window').future,
    );

    expect(
      initialWindow.messages.map((message) => message.id).toList(),
      List<String>.generate(20, (index) => 'm${index + 11}', growable: false),
    );
    expect(initialWindow.hasMore, isTrue);

    final addedCount = await container
        .read(conversationTimelineCacheProvider)
        .loadOlderMessages(
          conversationId: 'conv-turn-window',
          pageSize: kConversationVisiblePageSize,
        );
    expect(addedCount, 10);

    final notifier = container.read(
      conversationVisibleCountProvider('conv-turn-window').notifier,
    );
    notifier.state += addedCount;
    await container.pump();

    final expandedWindow = await container.read(
      conversationMessageWindowProvider('conv-turn-window').future,
    );
    expect(
      expandedWindow.messages.map((message) => message.id).toList(),
      rows.map((row) => row.id).toList(),
    );
    expect(expandedWindow.hasMore, isFalse);
  });

  test('移除持久前端时间线缓存后，冷启动重进会话应只从数据库尾部 20 条重建', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);

    final baseTime = DateTime(2026, 3, 27, 10, 0, 0).millisecondsSinceEpoch;
    await _insertConversation(database, 'conv-restore-full', baseTime);

    final writerContainer = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(writerContainer.dispose);

    for (var i = 1; i <= 30; i++) {
      await _insertMessage(
        database,
        'conv-restore-full',
        id: 'm$i',
        role: i.isOdd ? 'user' : 'assistant',
        content: 'message-$i',
        createdAt: baseTime + i,
      );
    }

    final writerStore = writerContainer.read(conversationTimelineCacheProvider);
    await writerStore.reloadConversationFromRawStore(
      'conv-restore-full',
      targetMessageCount: 20,
    );
    final addedCount = await writerStore.loadOlderMessages(
      conversationId: 'conv-restore-full',
      pageSize: 5,
    );
    expect(addedCount, 5);

    final readerContainer = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
      ],
    );
    addTearDown(readerContainer.dispose);
    final restoredWindowSubscription =
        readerContainer.listen<AsyncValue<ConversationMessageWindow>>(
      conversationMessageWindowProvider('conv-restore-full'),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(restoredWindowSubscription.close);

    final restoredWindow = await readerContainer.read(
      conversationMessageWindowProvider('conv-restore-full').future,
    );
    final localMessageCount = await readerContainer
        .read(conversationTimelineCacheProvider)
        .loadCachedMessageCount('conv-restore-full');

    expect(
      restoredWindow.messages.map((message) => message.id).toList(),
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
    expect(restoredWindow.hasMore, isTrue);
    expect(
      readerContainer
          .read(conversationVisibleCountProvider('conv-restore-full')),
      kConversationInitialVisibleCount,
      reason: '重进会话首帧应维持 20 条尾部窗口',
    );
    expect(
      localMessageCount,
      kConversationInitialVisibleCount,
      reason: '移除 JSON 持久前端时间线缓存后，新容器只保留数据库尾部窗口',
    );
  });
}
