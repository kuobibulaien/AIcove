import 'dart:async';
import 'dart:convert';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/background_message_reprocessor.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart' as model;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final processed in [false, true]) {
    test('warm cache includes plain bg raw even when reprocessed=$processed', () async {
      SharedPreferences.setMockInitialValues({});
      final database = db.AppDatabase.forTesting(NativeDatabase.memory());
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(database),
        backgroundReprocessDeviceIdProvider.overrideWith((_) async => 'local'),
      ]);
      try {
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final conv in ['c1', 'c2']) {
          await database.into(database.conversations).insert(db.ConversationsCompanion.insert(
            id: conv, title: conv, displayName: conv, createdAt: now, updatedAt: now,
          ));
        }
        final cache = container.read(conversationTimelineCacheProvider);
        for (final conv in ['c1', 'c2']) {
          expect(await cache.loadCachedMessages(conv), isEmpty);
          await database.into(database.messages).insert(db.MessagesCompanion.insert(
            id: 'bg_$conv', conversationId: conv, role: 'assistant',
            content: '后台文字', createdAt: now,
            rawPayload: Value(jsonEncode({
              'rawReplyText': '后台文字', 'bg_origin_device_id': 'local',
              if (processed) 'bg_reprocessed': true,
            })),
          ));
          // Simulate an isolate write: bypass drift table invalidation.
          expect(await cache.loadCachedMessages(conv), isEmpty);
          await cache.replaceMessagesTransient(
            conversationId: conv,
            messages: [
              model.Message(
                id: 'draft_$conv', sourceMessageId: 'inflight_$conv',
                role: 'assistant', content: 'still streaming',
                createdAt: DateTime.now(),
              ),
            ],
          );
        }
        await container.read(backgroundMessageReprocessorProvider).reprocessRecentBackgroundMessages();
        for (final conv in ['c1', 'c2']) {
          expect((await cache.loadCachedMessages(conv)).map((m) => m.sourceMessageId ?? m.id), contains('bg_$conv'));
          expect((await cache.loadCachedMessages(conv)).map((m) => m.id), contains('draft_$conv'));
        }
      } finally {
        container.dispose();
        await database.close();
      }
    });
  }

  test('sweep invalidates foreground drift watchers after isolate writes', () async {
    SharedPreferences.setMockInitialValues({});
    final database = db.AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      backgroundReprocessDeviceIdProvider.overrideWith((_) async => 'local'),
    ]);
    final changes = StreamIterator(database.select(database.messages).watch());
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      await database.into(database.conversations).insert(db.ConversationsCompanion.insert(
        id: 'c', title: 'c', displayName: 'c', createdAt: now, updatedAt: now,
      ));
      expect(await changes.moveNext(), isTrue);
      expect(changes.current, isEmpty);
      // A separate isolate cannot emit on this connection's drift stream.
      await database.customStatement(
        'INSERT INTO messages (id, conversation_id, role, content, created_at) VALUES (?, ?, ?, ?, ?)',
        ['bg_external', 'c', 'assistant', '后台', now],
      );
      await container.read(backgroundMessageReprocessorProvider).reprocessRecentBackgroundMessages();
      expect(await changes.moveNext().timeout(const Duration(seconds: 5)), isTrue);
      expect(changes.current.map((row) => row.id), contains('bg_external'));
    } finally {
      await changes.cancel();
      container.dispose();
      await database.close();
    }
  });

}
