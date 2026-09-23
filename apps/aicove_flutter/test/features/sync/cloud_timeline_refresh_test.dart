import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:aicove_flutter/src/features/sync/providers/cloud_sync_provider.dart';
import 'package:aicove_flutter/src/core/sync/cloud_tracking.dart';

final _controllerProvider = Provider((ref) {
  final controller = CloudSyncController(ref);
  ref.onDispose(controller.dispose);
  return controller;
});

class _MessageRepository extends MessageRepository {
  _MessageRepository(super.database);
  int reads = 0;
  Completer<void>? entered;
  Completer<void>? release;
  @override
  Future<List<db.Message>> getByConversationForDisplay(
    String conversationId, {
    int limit = 50,
    int? beforeTime,
    String? beforeId,
  }) async {
    final rows = await super.getByConversationForDisplay(
      conversationId,
      limit: limit,
      beforeTime: beforeTime,
      beforeId: beforeId,
    );
    if (conversationId == 'room') {
      reads++;
      final gate = release;
      if (gate != null) {
        release = null;
        entered!.complete();
        await gate.future;
      }
    }
    return rows;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  late CloudLocalStore local;
  late ConversationTimelineCache cache;
  late CloudSyncController controller;
  late Directory directory;
  late _MessageRepository repository;
  final now = DateTime(2026, 9, 13).millisecondsSinceEpoch;

  Future<void> applyMessage(int index, {int? deletedAt, String? content}) =>
      local.apply('messages', 'm$index', {
        'client_schema': kCloudRowSchema,
        'row': {
          'id': 'm$index',
          'conversation_id': 'room',
          'role': 'user',
          'content': content ?? 'message $index',
          'created_at': now + index,
          'deleted_at': deletedAt,
        },
      }, false);

  Future<ConversationTimelineWindowState> window() =>
      cache.watchWindow(conversationId: 'room', limit: 100).first;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    repository = _MessageRepository(database);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        messageRepositoryProvider.overrideWithValue(repository),
      ],
    );
    directory = await Directory.systemTemp.createTemp('cloud-timeline-');
    local = CloudLocalStore(
      database,
      await SharedPreferences.getInstance(),
      directory,
      directory,
    );
    cache = container.read(conversationTimelineCacheProvider);
    controller = container.read(_controllerProvider);
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'room',
            title: 'fixture',
            displayName: 'fixture',
            createdAt: now,
            updatedAt: now,
          ),
        );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
    await directory.delete(recursive: true);
  });

  test(
    'sync updates an already open timeline without reopening the page',
    () async {
      await applyMessage(1);
      expect((await window()).messages.map((m) => m.id), ['m1']);
      final next = cache
          .watchWindow(conversationId: 'room', limit: 20)
          .firstWhere((state) => state.messages.any((m) => m.id == 'm2'))
          .timeout(const Duration(seconds: 3));
      await applyMessage(2);
      controller.handleApplied({'messages'});
      expect((await next).messages.map((m) => m.id), ['m1', 'm2']);
      expect(
        await database.select(database.messageProjectionMappings).get(),
        isEmpty,
        reason: 'View refresh must not create local canonical changes',
      );
    },
  );

  test(
    'sync preserves a paged history anchor and local hiding while applying edits and deletion',
    () async {
      await database.transaction(() async {
        for (var i = 1; i <= 120; i++) {
          await applyMessage(i);
        }
      });
      await window();
      await cache.loadOlderMessages(conversationId: 'room', pageSize: 20);
      await cache.hideMessages(conversationId: 'room', rawMessageIds: ['m85']);
      expect((await window()).messages.first.id, 'm81');
      await database.transaction(() async {
        for (var i = 121; i <= 130; i++) {
          await applyMessage(i);
        }
        await applyMessage(100, content: 'edited remotely');
        await applyMessage(110, deletedAt: now + 200);
      });
      final next = cache
          .watchWindow(conversationId: 'room', limit: 100)
          .firstWhere((state) => state.messages.any((m) => m.id == 'm130'))
          .timeout(const Duration(seconds: 3));
      controller.handleApplied({'messages'});
      final refreshed = await next;
      final ids = refreshed.messages.map((m) => m.id);
      expect(ids, containsAll(['m81', 'm100', 'm120', 'm130']));
      expect(ids, isNot(contains('m85')));
      expect(ids, isNot(contains('m110')));
      expect(
        refreshed.messages.singleWhere((m) => m.id == 'm100').content,
        'edited remotely',
      );
      expect(refreshed.hasMoreMessages, isTrue);
      expect(ids.length, lessThan(70));
    },
  );

  test(
    'sync waits for a generating reply and retries without another cloud event',
    () async {
      await applyMessage(1);
      await window();
      container.read(conversationSendingProvider('room').notifier).state = true;
      await cache.replaceMessagesTransient(
        conversationId: 'room',
        messages: [
          Message(
            id: 'draft',
            role: 'assistant',
            content: 'streaming',
            createdAt: DateTime.fromMillisecondsSinceEpoch(now + 3),
          ),
        ],
      );
      await applyMessage(2);
      controller.handleApplied({'messages'});
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect((await window()).messages.map((m) => m.id), ['m1', 'draft']);
      await applyMessage(3);
      final next = cache
          .watchWindow(conversationId: 'room', limit: 20)
          .firstWhere((state) => state.messages.any((m) => m.id == 'm2'))
          .timeout(const Duration(seconds: 3));
      container.read(conversationSendingProvider('room').notifier).state =
          false;
      expect((await next).messages.map((m) => m.id), ['m1', 'm2', 'm3']);
    },
  );

  test(
    'generation starting during a refresh read cannot overwrite transient bubbles',
    () async {
      await applyMessage(1);
      await window();
      await applyMessage(2);
      final gate = Completer<void>();
      repository.release = gate;
      repository.entered = Completer<void>();
      controller.handleApplied({'messages'});
      await repository.entered!.future.timeout(const Duration(seconds: 3));
      container.read(conversationSendingProvider('room').notifier).state = true;
      final transient = cache.replaceMessagesTransient(
        conversationId: 'room',
        messages: [
          Message(
            id: 'draft',
            role: 'assistant',
            content: 'streaming',
            createdAt: DateTime.fromMillisecondsSinceEpoch(now + 3),
          ),
        ],
      );
      gate.complete();
      await transient;
      expect((await window()).messages.map((m) => m.id), ['m1', 'draft']);
      await applyMessage(3);
      final next = cache
          .watchWindow(conversationId: 'room', limit: 20)
          .firstWhere((state) => state.messages.any((m) => m.id == 'm2'))
          .timeout(const Duration(seconds: 3));
      container.read(conversationSendingProvider('room').notifier).state =
          false;
      expect((await next).messages.map((m) => m.id), ['m1', 'm2', 'm3']);
    },
  );

  test(
    'committed batches coalesce and unopened conversations remain cold',
    () async {
      await applyMessage(1);
      await window();
      final before = repository.reads;
      await applyMessage(2);
      final next = cache
          .watchWindow(conversationId: 'room', limit: 20)
          .firstWhere((state) => state.messages.any((m) => m.id == 'm2'))
          .timeout(const Duration(seconds: 3));
      for (var i = 0; i < 10; i++) {
        controller.handleApplied({'messages'});
      }
      await next;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(repository.reads, before + 1);
      expect(cache.peekWindow(conversationId: 'unopened', limit: 20), isNull);
    },
  );
}
