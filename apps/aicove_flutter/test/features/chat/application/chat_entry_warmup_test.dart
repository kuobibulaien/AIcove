import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_page_queries.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';

class _FakeCache extends ConversationTimelineCache {
  _FakeCache(super.ref);

  final reads = <String>[];
  final hot = <String>{};
  final failures = <String>{};
  Completer<void>? gate;
  int concurrent = 0;
  int maxConcurrent = 0;

  @override
  ConversationTimelineWindowState? peekWindow({
    required String conversationId,
    required int limit,
  }) =>
      hot.contains(conversationId)
          ? const ConversationTimelineWindowState(
              messages: [], hasMoreMessages: false)
          : null;

  @override
  Stream<ConversationTimelineWindowState> watchWindow({
    required String conversationId,
    required int limit,
  }) async* {
    expect(limit, kConversationTimelineSeedMessageCount);
    reads.add(conversationId);
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    try {
      await gate?.future;
      if (failures.contains(conversationId)) throw StateError('test failure');
      hot.add(conversationId);
      yield const ConversationTimelineWindowState(
          messages: [], hasMoreMessages: false);
    } finally {
      concurrent--;
    }
  }
}

void main() {
  test('预读去空去重、最多三场，串行且跨联系人页重建只执行一次', () async {
    late _FakeCache cache;
    final container = ProviderContainer(overrides: [
      conversationTimelineCacheProvider
          .overrideWith((ref) => cache = _FakeCache(ref)),
    ]);
    addTearDown(container.dispose);
    final queries = container.read(chatPageQueriesProvider);
    await queries.warmEntryMessages([' ', ' a ', 'a', 'b', 'c', 'd']);
    await queries.warmEntryMessages(['e', 'f', 'g']);
    expect(cache.reads, ['a', 'b', 'c']);
    expect(cache.maxConcurrent, 1);
    expect(cache.concurrent, 0, reason: '首值后释放临时订阅');
  });

  test('已有热缓存不排读取队列，预读失败不阻断其他会话', () async {
    late _FakeCache cache;
    final container = ProviderContainer(overrides: [
      conversationTimelineCacheProvider
          .overrideWith((ref) => cache = _FakeCache(ref)),
    ]);
    addTearDown(container.dispose);
    container.read(conversationTimelineCacheProvider);
    cache.hot.add('hot');
    cache.failures.add('bad');
    await container
        .read(chatPageQueriesProvider)
        .warmEntryMessages(['hot', 'bad', 'ok']);
    expect(cache.reads, ['bad', 'ok']);
    expect(cache.hot, contains('ok'));
  });

  test('空联系人不消耗预读机会，并发请求共享任务，销毁后不继续下一场', () async {
    late _FakeCache cache;
    final container = ProviderContainer(overrides: [
      conversationTimelineCacheProvider
          .overrideWith((ref) => cache = _FakeCache(ref)),
    ]);
    final queries = container.read(chatPageQueriesProvider);
    await queries.warmEntryMessages([]);
    container.read(conversationTimelineCacheProvider);
    final gate = Completer<void>();
    cache.gate = gate;
    final first = queries.warmEntryMessages(['a', 'b', 'c']);
    final second = queries.warmEntryMessages(['a', 'b', 'c']);
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(cache.reads, ['a']);
    container.dispose();
    gate.complete();
    await first;
    expect(cache.reads, ['a']);
  });

  test('真实本地库预读只取末尾窗口，重进可同步读取完整最后一条 AI 消息', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
    ]);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    final now = DateTime(2026, 9, 5).millisecondsSinceEpoch;
    await database
        .into(database.conversations)
        .insert(db.ConversationsCompanion.insert(
          id: 'history',
          title: '历史',
          displayName: '历史',
          createdAt: now,
          updatedAt: now,
        ));
    await database.batch((batch) => batch.insertAll(database.messages, [
          for (var i = 0; i < 100; i++)
            db.MessagesCompanion.insert(
              id: 'm_$i',
              conversationId: 'history',
              role: i.isEven ? 'user' : 'assistant',
              content: '本地历史 $i',
              createdAt: now + i,
            ),
        ]));
    final cache = container.read(conversationTimelineCacheProvider);
    expect(cache.peekWindow(conversationId: 'history', limit: 20), isNull);
    await container
        .read(chatPageQueriesProvider)
        .warmEntryMessages(['history']);
    final first = cache.peekWindow(conversationId: 'history', limit: 20)!;
    expect(first.messages.length, 20);
    expect(first.messages.first.id, 'm_80');
    expect(first.messages.last.id, 'm_99');
    expect(first.messages.last.role, 'assistant');
    expect(first.hasMoreMessages, isTrue);
    final reopened =
        await cache.watchWindow(conversationId: 'history', limit: 20).first;
    expect(reopened.messages.last.id, 'm_99');
    expect(reopened.messages.length, 20);
  });
}
