import 'dart:convert';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/models/message_block.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_frontend_message_projection_service.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_message_projection_codec.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  const projection = ChatFrontendMessageProjectionService();
  final time = DateTime(2026, 10, 25);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
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

  Future<void> insert(String id, Map<String, dynamic> payload) => database
      .into(database.messages)
      .insert(
        db.MessagesCompanion.insert(
          id: id,
          conversationId: 'c',
          role: 'assistant',
          content: '原始文本',
          createdAt: time.millisecondsSinceEpoch,
          rawPayload: Value(jsonEncode(payload)),
        ),
      )
      .then((_) {});

  test(
    'displayOnly keeps run status for legacy snapshots and semantic rows',
    () async {
      for (final semantic in [false, true]) {
        await insert('raw_$semantic', {
          'projectedMessages': ChatMessageProjectionCodec.serializeMessages([
            Message.text(id: 'old', role: 'assistant', content: '旧缓存'),
          ]),
          if (semantic) 'displayReplyText': '新展示',
          if (semantic) 'processedText': '新展示',
          'runStatus': 'truncated',
          'stopReason': 'length',
        });
      }
      final rows = await container
          .read(messageRepositoryProvider)
          .getByConversationForDisplay('c');
      for (final row in rows) {
        final payload = jsonDecode(row.rawPayload!) as Map<String, dynamic>;
        expect(payload['runStatus'], 'truncated');
        expect(payload['stopReason'], 'length');
        final output = projection.projectMessage(
          Message(
            id: row.id,
            role: row.role,
            content: row.content,
            createdAt: time,
            rawPayload: payload,
          ),
        );
        expect(output.last.rawPayload?['runStatus'], 'truncated');
        expect(output.last.rawPayload?['stopReason'], 'length');
        expect(output.single.displayText, row.id == 'raw_true' ? '新展示' : '旧缓存');
      }
    },
  );

  test(
    'semantic supplements persist without snapshots and reload with identical round counts',
    () async {
      final raw = Message(
        id: 'raw',
        role: 'assistant',
        content: '原文',
        createdAt: time,
        rawPayload: {
          'displayReplyText': '第一轮\n最后一轮',
          'processedText': '第一轮\n最后一轮',
          'replyRounds': [
            {'replyText': '第一轮', 'processedText': '第一轮'},
            {'replyText': '最后一轮', 'processedText': '最后一轮'},
          ],
          'runStatus': 'cancelled',
          'stopReason': 'userCancelled',
        },
      );
      final store = container.read(chatHistoryStoreProvider);
      final projected = projection.projectMessage(raw);
      await store.appendAssistantRawMessage(
        conversationId: 'c',
        userMessageId: '',
        rawMessage: raw,
        projectedMessages: projected,
        lastMessagePreview: '最后一轮',
      );
      expect(
        await container
            .read(messageProjectionMappingRepositoryProvider)
            .getByRawMessage('raw'),
        isEmpty,
      );
      final firstPage = await store.loadRecentProjectedMessages('c');
      expect(firstPage, hasLength(2));
      expect(firstPage.last.rawPayload?['runStatus'], 'cancelled');

      final image = Message.fromBlocks(
        id: 'delivered_image',
        role: 'assistant',
        sourceMessageId: 'raw',
        createdAt: time,
        blocks: [
          ImageBlock(messageId: 'delivered_image', localPath: '/tmp/demo.png'),
        ],
      );
      await container
          .read(conversationTimelineCacheProvider)
          .upsertMessages(conversationId: 'c', messages: [...projected, image]);
      await store.syncRawSupplementsFromTimeline(
        conversationId: 'c',
        rawMessageIds: {'raw'},
      );
      final reloaded = (await store.loadAllRawMessages('c')).single;
      expect(reloaded.rawPayload!.containsKey('projectedMessages'), isFalse);
      expect(
        ChatMessageProjectionCodec.supplementInsertOps(reloaded.rawPayload),
        hasLength(1),
      );
      final rebuilt = projection.projectMessage(reloaded);
      expect(rebuilt, hasLength(3));
      final paged = await store.loadRecentProjectedMessages('c');
      expect(paged.map((m) => m.id), rebuilt.map((m) => m.id));
      expect(paged.last.rawPayload?['runStatus'], 'cancelled');
      expect(paged.last.rawPayload?['stopReason'], 'userCancelled');

      // Canonical IDs resolve even with no timeline and no projection-map row.
      container.dispose();
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      final found = await container
          .read(chatHistoryStoreProvider)
          .loadFrontendMessageById(rebuilt.first.id);
      expect(found?.id, rebuilt.first.id);
    },
  );
  test(
    'partial round deletion remains hidden after a cold timeline reload',
    () async {
      final raw = Message(
        id: 'raw_rounds',
        role: 'assistant',
        content: '原文',
        createdAt: time,
        rawPayload: {
          'replyRounds': [
            {'replyText': '第一轮', 'processedText': '第一轮'},
            {'replyText': '第二轮', 'processedText': '第二轮'},
          ],
        },
      );
      final store = container.read(chatHistoryStoreProvider);
      final messages = projection.projectMessage(raw);
      await store.appendAssistantRawMessage(
        conversationId: 'c',
        userMessageId: '',
        rawMessage: raw,
        projectedMessages: messages,
        lastMessagePreview: '第二轮',
      );
      await store.softDeleteMessages('c', [messages.first.id]);
      await container
          .read(conversationTimelineCacheProvider)
          .reloadConversationFromRawStore('c');
      final window = await container
          .read(conversationTimelineCacheProvider)
          .watchWindow(conversationId: 'c', limit: 20)
          .first;
      expect(window.messages.map((m) => m.displayText), ['第二轮']);
      final canonical = (await store.loadAllRawMessages('c')).single;
      expect(
        ChatMessageProjectionCodec.replyRounds(canonical.rawPayload),
        hasLength(2),
      );
      expect(canonical.rawPayload!.containsKey('projectedMessages'), isFalse);
    },
  );
  test('display-only round text updates keep raw replay and other rounds intact', () async {
    final raw = Message(id: 'raw_round_edit', role: 'assistant', content: '原文', createdAt: time,
      rawPayload: {'displayReplyText': '相同\n相同', 'processedText': '相同\n相同', 'replyRounds': [
        {'rawText': '第一轮原文', 'replyText': '相同', 'processedText': '相同'},
        {'rawText': '第二轮原文', 'replyText': '相同', 'processedText': '相同'},
      ]});
    final store = container.read(chatHistoryStoreProvider);
    final messages = projection.projectMessage(raw);
    await store.appendAssistantRawMessage(conversationId: 'c', userMessageId: '', rawMessage: raw,
      projectedMessages: messages, lastMessagePreview: '相同');
    await store.updateMessage(conversationId: 'c', message: messages.last.copyWith(content: '更新展示'));
    final canonical = (await store.loadAllRawMessages('c')).single;
    final rounds = ChatMessageProjectionCodec.replyRounds(canonical.rawPayload);
    expect(rounds.map((r) => r.rawText), ['第一轮原文', '第二轮原文']);
    expect(rounds.map((r) => r.replyText), ['相同', '更新展示']);
    expect(canonical.rawPayload!['displayReplyText'], '相同\n更新展示');
    expect(canonical.rawPayload!.containsKey('projectedMessages'), isFalse);
  });

}
