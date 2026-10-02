import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/app_logger.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_provider.dart';
import 'package:aicove_flutter/src/features/observability/frontend_diagnostics_service.dart';

class _HeldRepository extends MessageRepository {
  _HeldRepository(super.database);
  final entered = Completer<void>();
  final gate = Completer<void>();
  int calls = 0;
  bool fail = false;
  @override
  Future<List<db.Message>> getByConversationForDisplay(String conversationId,
      {int limit = 50, int? beforeTime, String? beforeId}) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    await gate.future;
    if (fail) throw StateError('PRIVATE_FAILURE_TEXT');
    return super.getByConversationForDisplay(conversationId,
        limit: limit, beforeTime: beforeTime, beforeId: beforeId);
  }
}

Future<void> _seed(db.AppDatabase database) async {
  await database.into(database.conversations).insert(
      db.ConversationsCompanion.insert(
          id: 'synthetic',
          title: 'synthetic',
          displayName: 'synthetic',
          createdAt: 1,
          updatedAt: 1));
  await database.batch((batch) => batch.insertAll(database.messages, [
        for (var i = 0; i < 30; i++)
          db.MessagesCompanion.insert(
              id: 'm$i',
              conversationId: 'synthetic',
              role: 'assistant',
              content: 'PRIVATE_MESSAGE_TEXT',
              createdAt: i,
              rawPayload: const Value('{"source":"PRIVATE_PAYLOAD_TEXT"}')),
      ]));
  await database.into(database.messageBlocks).insert(
      db.MessageBlocksCompanion.insert(
          id: 'block29',
          messageId: 'm29',
          type: 'text',
          createdAt: 29,
          data: '{"text":"PRIVATE_BLOCK_TEXT"}'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('冷加载仅记一组数值阶段，并发进入共享读取，热重进不增加记录', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await _seed(database);
    final repository = _HeldRepository(database);
    final logs = <LogEntry>[];
    final diagnostics = FrontendDiagnosticsService(sink: logs.add);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      messageRepositoryProvider.overrideWithValue(repository),
      frontendDiagnosticsProvider.overrideWithValue(diagnostics),
    ]);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    final cache = container.read(conversationTimelineCacheProvider);
    final first =
        cache.watchWindow(conversationId: 'synthetic', limit: 20).first;
    await repository.entered.future;
    final second =
        cache.watchWindow(conversationId: 'synthetic', limit: 20).first;
    await Future<void>.delayed(Duration.zero);
    repository.gate.complete();
    final windows = await Future.wait([first, second]);
    for (final window in windows) {
      expect(window.messages.length, 20);
      expect(window.messages.first.sourceMessageIdOrSelf, 'm10');
      expect(window.messages.last.sourceMessageIdOrSelf, 'm29');
      expect(window.hasMoreMessages, isTrue);
    }
    expect(repository.calls, 1);
    await cache.watchWindow(conversationId: 'synthetic', limit: 20).first;
    cache.peekWindow(conversationId: 'synthetic', limit: 20);
    await Future<void>.delayed(Duration.zero);
    final events =
        logs.where((e) => e.metadata?['event'] == 'historyColdLoad').toList();
    expect(events.length, 2);
    expect(events.map((e) => e.metadata!['phase']), ['start', 'end']);
    expect(events.first.metadata!['operationId'],
        events.last.metadata!['operationId']);
    final state = events.last.metadata!['state'] as Map;
    expect(state['rawReadCount'], 21);
    expect(state['rawCount'], 20);
    expect(state['blockCount'], 1);
    expect(state['projectedCount'], 20);
    for (final key in [
      'queueMs',
      'rawReadMs',
      'blockReadMs',
      'decodeMs',
      'projectionMs',
      'installMs'
    ]) {
      expect(state[key], isNonNegative, reason: key);
    }
    expect(state['rawPayloadChars'], greaterThan(0));
    expect(state['payloadOtherChars'], 20 * 'PRIVATE_PAYLOAD_TEXT'.length);
    expect(state['payloadScanTruncated'], false);
    expect(state['payloadStatsMs'], isNonNegative);
    expect(state.length, lessThanOrEqualTo(32));
    expect(state['blockDataChars'], greaterThan(0));
    expect(state.values.every((v) => v is num || v is bool), isTrue);
    expect(jsonEncode(logs.map((e) => e.metadata).toList()),
        isNot(contains('PRIVATE_')));
  });

  test('冷读失败保留异常语义且有受控结束记录，失败后可再次加载', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    await _seed(database);
    final repository = _HeldRepository(database)..fail = true;
    repository.gate.complete();
    final logs = <LogEntry>[];
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      messageRepositoryProvider.overrideWithValue(repository),
      frontendDiagnosticsProvider
          .overrideWithValue(FrontendDiagnosticsService(sink: logs.add)),
    ]);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    final cache = container.read(conversationTimelineCacheProvider);
    await expectLater(
        cache.watchWindow(conversationId: 'synthetic', limit: 20).first,
        throwsStateError);
    repository.fail = false;
    expect(
        (await cache.watchWindow(conversationId: 'synthetic', limit: 20).first)
            .messages
            .length,
        20);
    await Future<void>.delayed(Duration.zero);
    final failure =
        logs.singleWhere((e) => e.metadata?['event'] == 'historyFailed');
    expect(failure.metadata!['phase'], 'error');
    expect(jsonEncode(logs.map((e) => e.metadata).toList()),
        isNot(contains('PRIVATE_')));
  });

  test('空历史也结束冷加载，关闭采集不影响正常读取', () async {
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final logs = <LogEntry>[];
    final diagnostics = FrontendDiagnosticsService(sink: logs.add);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      frontendDiagnosticsProvider.overrideWithValue(diagnostics),
    ]);
    addTearDown(() async {
      container.dispose();
      await database.close();
    });
    final cache = container.read(conversationTimelineCacheProvider);
    expect(
        (await cache.watchWindow(conversationId: 'empty', limit: 20).first)
            .messages,
        isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(logs.length, 2);
    expect((logs.last.metadata!['state'] as Map)['projectedCount'], 0);
    diagnostics.enabled = false;
    expect(
        (await cache.watchWindow(conversationId: 'disabled', limit: 20).first)
            .messages,
        isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(logs.length, 2);
  });
}
