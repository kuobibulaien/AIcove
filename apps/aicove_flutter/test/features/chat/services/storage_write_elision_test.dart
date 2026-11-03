import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/repositories/repositories.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingMessages extends MessageRepository {
  _CountingMessages(super.database);

  int upserts = 0;
  int counts = 0;

  @override
  Future<void> upsert(db.MessagesCompanion data) {
    upserts++;
    return super.upsert(data);
  }

  @override
  Future<int> countByConversation(String conversationId) {
    counts++;
    return super.countByConversation(conversationId);
  }
}

class _CountingMappings extends MessageProjectionMappingRepository {
  _CountingMappings(super.database);

  final replacements = <String>[];

  @override
  Future<void> replaceForRawMessage({
    required String rawMessageId,
    required List<db.MessageProjectionMappingsCompanion> mappings,
  }) {
    replacements.add(rawMessageId);
    return super.replaceForRawMessage(
      rawMessageId: rawMessageId,
      mappings: mappings,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  late _CountingMessages messages;
  late _CountingMappings mappings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    messages = _CountingMessages(database);
    mappings = _CountingMappings(database);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        messageRepositoryProvider.overrideWithValue(messages),
        messageProjectionMappingRepositoryProvider.overrideWithValue(mappings),
      ],
    );
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: 'c',
            title: 'test',
            displayName: 'test',
            createdAt: 0,
            updatedAt: 0,
          ),
        );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test('unchanged supplements do not rewrite the raw message', () async {
    final raw = Message(
      id: 'raw',
      role: 'assistant',
      content: '原文',
      createdAt: DateTime(2026, 10, 26),
      rawPayload: {'displayReplyText': '展示', 'processedText': '展示'},
    );
    final store = container.read(chatHistoryStoreProvider);
    await store.appendAssistantRawMessage(
      conversationId: 'c',
      userMessageId: '',
      rawMessage: raw,
      projectedMessages: const ChatFrontendMessageProjectionService()
          .projectMessage(raw),
      lastMessagePreview: '展示',
    );
    // Let the first synchronization normalize any supplement fields.
    await store.syncRawSupplementsFromTimeline(
      conversationId: 'c',
      rawMessageIds: {'raw'},
    );
    final before = await messages.getById('raw');
    messages.upserts = 0;
    await store.syncRawSupplementsFromTimeline(
      conversationId: 'c',
      rawMessageIds: {'raw'},
    );
    expect(messages.upserts, 0);
    expect((await messages.getById('raw'))!.rawPayload, before!.rawPayload);
  });

  test('empty timeline skips the stale-history count query', () async {
    final cache = container.read(conversationTimelineCacheProvider);
    expect(await cache.loadCachedMessages('c'), isEmpty);
    messages.counts = 0;
    await container
        .read(chatHistoryStoreProvider)
        .appendUserMessage(
          conversationId: 'c',
          message: Message.text(id: 'user', role: 'user', content: '新消息'),
          displayText: '新消息',
        );
    expect(messages.counts, 0);
  });

  test(
    'nonempty stale timeline is still cleared before a new user message',
    () async {
      final cache = container.read(conversationTimelineCacheProvider);
      await cache.upsertMessage(
        conversationId: 'c',
        message: Message.text(id: 'stale', role: 'user', content: '旧缓存'),
      );
      messages.counts = 0;
      await container
          .read(chatHistoryStoreProvider)
          .appendUserMessage(
            conversationId: 'c',
            message: Message.text(id: 'user', role: 'user', content: '新消息'),
            displayText: '新消息',
          );
      expect(messages.counts, 1);
      expect((await cache.loadCachedMessages('c')).map((m) => m.id), ['user']);
    },
  );

  test(
    'legacy projection with a distinct raw source still writes its mapping',
    () async {
      final cache = container.read(conversationTimelineCacheProvider);
      await cache.loadCachedMessages('c');
      mappings.replacements.clear();
      await cache.upsertMessage(
        conversationId: 'c',
        message: Message.text(
          id: 'legacy_projection',
          role: 'assistant',
          content: '消息',
          sourceMessageId: 'raw',
        ),
      );
      expect(mappings.replacements, ['raw']);
      expect(
        (await mappings.getByRawMessage('raw')).single.projectedMessageId,
        'legacy_projection',
      );
    },
  );

  for (final role in ['user', 'assistant', 'system']) {
    for (final source in <String?>[null, '', 'raw']) {
      test('raw $role skips mapping replacement (source: $source)', () async {
        final cache = container.read(conversationTimelineCacheProvider);
        await cache.loadCachedMessages('c');
        mappings.replacements.clear();
        await cache.upsertMessage(
          conversationId: 'c',
          message: Message.text(
            id: 'raw',
            role: role,
            content: '消息',
            sourceMessageId: source,
          ),
        );
        expect(mappings.replacements, isEmpty);
        // Once absent from the snapshot, cleanup must still run.
        await cache.replaceMessages(
          conversationId: 'c',
          removeMessageIds: ['raw'],
        );
        expect(mappings.replacements, ['raw']);
      });
    }
  }
}
