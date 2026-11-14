import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_timeline_deletion.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/chat_actions.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_page_conversation_actions.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late db.AppDatabase database;
  late ProviderContainer container;
  ChatHistoryStore store() => container.read(chatHistoryStoreProvider);
  ConversationTimelineCache cache() =>
      container.read(conversationTimelineCacheProvider);
  Future<void> seed(
    String id,
    int time, {
    String role = 'assistant',
    String conversationId = 'a',
  }) => database
      .into(database.messages)
      .insert(
        db.MessagesCompanion.insert(
          id: id,
          conversationId: conversationId,
          role: role,
          content: id,
          createdAt: time,
        ),
      );
  Future<db.Conversation?> conversation() =>
      container.read(conversationRepositoryProvider).getById('a');
  Future<void> boundary(String id) =>
      (database.update(database.conversations)..where((t) => t.id.equals('a')))
          .write(db.ConversationsCompanion(contextStartMessageId: Value(id)));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    database = db.AppDatabase.forTesting(NativeDatabase.memory());
    for (final id in ['a', 'b']) {
      await database
          .into(database.conversations)
          .insert(
            db.ConversationsCompanion.insert(
              id: id,
              title: id,
              displayName: id,
              createdAt: 0,
              updatedAt: 0,
            ),
          );
    }
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
  });
  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test('piece identity and empty plan contract', () {
    const projected = 'raw__proj_r0_s0_text';
    final piece = ChatTimelinePieceId.compose(projected, 'text');
    expect(ChatTimelinePieceId.parentMessageIdOf(piece), projected);
    expect(ChatTimelinePieceId.rawMessageIdOf(piece), 'raw');
    expect(
      ChatTimelinePieceId.rawMessageIdOf(piece, explicitSourceId: ' explicit '),
      'explicit',
    );
    expect(ChatTimelinePieceId.parentMessageIdOf('__piece_x'), isNull);
    expect(const ChatTimelineDeletePlan().isEmpty, isTrue);
    expect(
      const ChatTimelineDeletePlan(pieceIdsToHide: ['x']).hasPartialHide,
      isTrue,
    );
    expect(
      const ChatTimelineDeletePlan(
        turnAnchorMessageIdsToDelete: ['x'],
      ).hasCanonicalDeletion,
      isTrue,
    );
  });

  test('oldest raw window retains all sibling projections', () async {
    await seed('old', 0);
    await seed('edge', 1);
    await seed('new', 2);
    await cache().replaceMessages(
      conversationId: 'a',
      removeMessageIds: ['edge', 'new'],
      messages: [
        for (final entry in [('edge', 'one'), ('edge', 'two'), ('new', 'one')])
          Message(
            id: '${entry.$1}_${entry.$2}',
            sourceMessageId: entry.$1,
            role: 'assistant',
            content: entry.$2,
            createdAt: DateTime.fromMillisecondsSinceEpoch(
              entry.$1 == 'edge' ? 1 : 2,
            ),
          ),
      ],
    );
    final window = cache().peekWindow(conversationId: 'a', limit: 2)!;
    expect(window.messages.map((m) => m.id), [
      'edge_one',
      'edge_two',
      'new_one',
    ]);
  });

  test(
    'piece-only hiding persists, streams immutable sets and leaves canonical summary intact',
    () async {
      await seed('raw', 1);
      await store().softDeleteMessages('a', ['missing']);
      final before = await conversation();
      final events = <Set<String>>[];
      final subscription = cache().watchHiddenPieceIds('a').listen(events.add);
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      await store().hideMessagesInFrontendTimeline(
        'a',
        [],
        pieceIds: ['raw__piece_text'],
      );
      await Future<void>.delayed(Duration.zero);
      expect(events.last, {'raw__piece_text'});
      expect(() => events.last.add('bad'), throwsUnsupportedError);
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString('aicove.frontend_hidden.v1.a')!)['pieces'],
        ['raw__piece_text'],
      );
      expect((await store().loadAllRawMessages('a')).single.id, 'raw');
      expect((await conversation())!.lastMessage, before!.lastMessage);
      container.dispose();
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
      expect(await cache().loadHiddenPieceIds('a'), {'raw__piece_text'});
    },
  );

  test(
    'canonical deletion is conversation-scoped and cleans local hidden entries',
    () async {
      await seed('raw', 1);
      await seed('foreign', 2, conversationId: 'b');
      const projected = 'raw__proj_r0_s0_text';
      await cache().hideMessages(
        conversationId: 'a',
        rawMessageIds: ['raw'],
        projectedMessageIds: [projected],
        pieceIds: [
          '$projected${ChatTimelinePieceId.separator}text',
          'other__piece_text',
        ],
      );
      await store().executeTimelineDeletePlan(
        'a',
        const ChatTimelineDeletePlan(rawMessageIdsToDelete: ['raw', 'foreign']),
      );
      expect(
        (await container.read(messageRepositoryProvider).getById('raw'))!
            .deletedAt,
        isNotNull,
      );
      expect(
        (await container.read(messageRepositoryProvider).getById('foreign'))!
            .deletedAt,
        isNull,
      );
      final prefs = await SharedPreferences.getInstance();
      final hidden = jsonDecode(
        prefs.getString('aicove.frontend_hidden.v1.a')!,
      );
      expect(hidden['pieces'], ['other__piece_text']);
      expect(hidden['raw'], isEmpty);
      expect(hidden['projected'], isEmpty);
    },
  );

  test(
    'deleted boundary shifts left across deleted and replaced rows, or clears at start',
    () async {
      await seed('u0', 0, role: 'user');
      await seed('a0', 1);
      await seed('replaced', 1);
      await seed('deleted', 1);
      await (database.update(database.messages)
            ..where((t) => t.id.equals('replaced')))
          .write(const db.MessagesCompanion(replacedBy: Value('boundary')));
      await (database.update(database.messages)
            ..where((t) => t.id.equals('deleted')))
          .write(const db.MessagesCompanion(deletedAt: Value(100)));
      await seed('boundary', 2);
      await seed('u1', 3, role: 'user');
      await boundary('boundary');
      await store().executeTimelineDeletePlan(
        'a',
        const ChatTimelineDeletePlan(rawMessageIdsToDelete: ['a0', 'boundary']),
      );
      expect((await conversation())!.contextStartMessageId, 'u0');
      expect(
        (await store().loadCanonicalContextMessages('a')).map((m) => m.id),
        ['u1'],
      );
      await store().executeTimelineDeletePlan(
        'a',
        const ChatTimelineDeletePlan(rawMessageIdsToDelete: ['u0']),
      );
      expect((await conversation())!.contextStartMessageId, isNull);
    },
  );

  test(
    'turn deletion expands through full history and summary falls back outside short window',
    () async {
      await seed('user', 0, role: 'user');
      for (var i = 1; i <= 25; i++) {
        await seed('a$i', i);
      }
      await store().loadCachedTimelineMessages('a');
      await store().executeTimelineDeletePlan(
        'a',
        const ChatTimelineDeletePlan(
          turnAnchorMessageIdsToDelete: ['a25__piece_text'],
        ),
      );
      expect((await store().loadAllRawMessages('a')).map((m) => m.id), [
        'user',
      ]);
      expect((await conversation())!.lastMessage, 'user');
      for (var i = 1; i <= 20; i++) {
        await seed('tail$i', 30 + i);
      }
      await cache().reloadConversationFromRawStore('a');
      await store().softDeleteMessages('a', [
        for (var i = 1; i <= 20; i++) 'tail$i',
      ]);
      expect((await conversation())!.lastMessage, 'user');
    },
  );
  test(
    'plan clears staged and quoted pieces, and quotes elsewhere in an expanded turn',
    () async {
      final actions = container.read(chatPageConversationActionsProvider);
      container.read(stagedUserMessagesProvider('a').notifier).state = [
        Message(
          id: 'staged',
          role: 'user',
          content: 'draft',
          createdAt: DateTime(2026),
        ),
      ];
      container.read(quotedMessageProvider.notifier).state =
          const QuotedMessage(id: 'staged', content: 'draft', isUser: true);
      await actions.executeDeletePlan(
        'a',
        const ChatTimelineDeletePlan(stagedMessageIds: ['staged']),
      );
      expect(container.read(stagedUserMessagesProvider('a')), isEmpty);
      expect(container.read(quotedMessageProvider), isNull);
      await seed('u0', 0, role: 'user');
      await seed('a0', 1);
      await seed('a1', 2);
      await seed('u1', 3, role: 'user');
      await seed('a2', 4);
      container
          .read(quotedMessageProvider.notifier)
          .state = const QuotedMessage(
        id: 'a1__proj_r0_s0_text__piece_text',
        content: 'quote',
        isUser: false,
      );
      await actions.executeDeletePlan(
        'a',
        const ChatTimelineDeletePlan(turnAnchorMessageIdsToDelete: ['a0']),
      );
      expect(container.read(quotedMessageProvider), isNull);
      expect((await store().loadAllRawMessages('a')).map((m) => m.id), [
        'u0',
        'u1',
        'a2',
      ]);
      container.read(quotedMessageProvider.notifier).state =
          const QuotedMessage(id: 'a2', content: 'quote', isUser: false);
      await actions.executeDeletePlan(
        'a',
        const ChatTimelineDeletePlan(pieceIdsToHide: ['a2__piece_text']),
      );
      expect(container.read(quotedMessageProvider), isNull);
      expect(
        (await container.read(messageRepositoryProvider).getById('a2'))!
            .deletedAt,
        isNull,
      );
    },
  );

  test(
    'legacy preferences and cold custom aliases are cleaned without recreating deleted hides',
    () async {
      await seed('raw', 0);
      await seed('keep', 1, role: 'user');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'aicove.frontend_hidden.v1.a',
        jsonEncode({
          'raw': [],
          'projected': ['legacy'],
        }),
      );
      expect(await cache().loadHiddenPieceIds('a'), isEmpty);
      await container
          .read(messageProjectionMappingRepositoryProvider)
          .upsert(
            db.MessageProjectionMappingsCompanion.insert(
              id: 'mapping_legacy',
              projectedMessageId: 'legacy',
              conversationId: 'a',
              rawMessageId: 'raw',
              segmentIndex: const Value(0),
              createdAt: 0,
            ),
          );
      await cache().hideMessages(
        conversationId: 'a',
        pieceIds: ['legacy__piece_text'],
      );
      await store().executeTimelineDeletePlan(
        'a',
        const ChatTimelineDeletePlan(
          turnAnchorMessageIdsToDelete: ['legacy__piece_text'],
          projectedMessageIdsToHide: ['legacy'],
          pieceIdsToHide: ['legacy__piece_text', 'keep__piece_text'],
        ),
      );
      final hidden = jsonDecode(
        prefs.getString('aicove.frontend_hidden.v1.a')!,
      );
      expect(hidden['projected'], isEmpty);
      expect(hidden['pieces'], ['keep__piece_text']);
      expect((await store().loadAllRawMessages('a')).single.id, 'keep');
      expect(
        await container
            .read(messageProjectionMappingRepositoryProvider)
            .getByProjectedMessageId('legacy'),
        isNull,
      );
    },
  );
}
