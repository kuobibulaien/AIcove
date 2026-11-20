import 'dart:async';
import 'dart:io';

import 'package:aicove_flutter/src/features/chat/chat_actions.dart'
    show chatActionsProvider;
import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/features/chat/application/active_stream_projection.dart';
import 'package:aicove_flutter/src/features/chat/chat_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/conversation_timeline_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/chat/services/conversation_short_window_store.dart';
import 'package:aicove_flutter/src/features/context/data/sqlite_context_summary_store.dart';
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';
import 'package:drift/drift.dart' show Value;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RecoveryPaths extends PathProviderPlatform {
  _RecoveryPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

/// Hold a real ChatActions generation after its local commit. No API
/// preparation or model request is reached, even when the test releases it.
class _BlockedSendService extends ChatSendService {
  _BlockedSendService(super.ref, this.committed, this.release);

  final Completer<Message> committed;
  final Completer<void> release;

  @override
  Future<void> addUserMessage({
    required String convId,
    required Message userMsg,
    required String displayText,
  }) async {
    await super.addUserMessage(
      convId: convId,
      userMsg: userMsg,
      displayText: displayText,
    );
    committed.complete(userMsg);
    await release.future;
    throw StateError('Synthetic send stopped before API preparation');
  }
}

/// Exercises the committed-database boundary of process death, not an API
/// exception: persist through the production send service, abandon transient
/// state, and reopen the same SQLite file with a fresh provider container.
///
/// Closing the test database only releases its connection. No ChatActions
/// catch/finally, cancellation, or message-status cleanup is invoked. This is
/// not an OS-level kill test and does not start the app or make model requests.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const conversationId = 'process-death-conversation';
  const placeholderId = 'uncommitted-assistant-placeholder';
  late Directory directory;
  late PathProviderPlatform oldPaths;
  late File databaseFile;
  late db.AppDatabase database;
  late ProviderContainer container;
  late Message userMessage;
  late DateTime recoveryNow;

  void openDatabase() {
    database = db.AppDatabase.forTesting(NativeDatabase(databaseFile));
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        messageRepositoryProvider.overrideWith(
          (ref) => MessageRepository(
            ref.watch(databaseProvider),
            now: () => recoveryNow,
          ),
        ),
      ],
    );
  }

  Future<ConversationMessageWindow> reopenConversation() async {
    container.dispose();
    await database.close();
    openDatabase();
    // Exercise both production conversation loading and the official UI
    // timeline provider, including AppDatabase's beforeOpen migration hook.
    final conversations = await container.read(conversationsProvider.future);
    expect(
      conversations.map((conversation) => conversation.id),
      contains(conversationId),
    );
    return container.read(
      conversationMessageWindowProvider(conversationId).future,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    recoveryNow = DateTime.now();
    directory = await Directory.systemTemp.createTemp('aicove-process-death-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _RecoveryPaths(directory.path);
    databaseFile = File('${directory.path}/chat.sqlite');
    openDatabase();
    addTearDown(() async {
      container.dispose();
      await database.close();
      PathProviderPlatform.instance = oldPaths;
      await directory.delete(recursive: true);
    });

    final now = DateTime.now().millisecondsSinceEpoch;
    await database
        .into(database.conversations)
        .insert(
          db.ConversationsCompanion.insert(
            id: conversationId,
            title: 'Process death test',
            displayName: 'Process death test',
            createdAt: now,
            updatedAt: now,
          ),
        );
    final sendService = container.read(chatSendServiceProvider);
    userMessage = sendService.createUserMessage(
      text: 'Synthetic interrupted request',
      imagePath: null,
    );
    // Strictly older than the threshold, without waiting in real time.
    recoveryNow = userMessage.createdAt
        .add(kInterruptedSendRecoveryThreshold)
        .add(const Duration(milliseconds: 1));
    await sendService.addUserMessage(
      convId: conversationId,
      userMsg: userMessage,
      displayText: userMessage.displayText,
    );
    final stored = await container
        .read(messageRepositoryProvider)
        .getById(userMessage.id);
    expect(stored?.status, 'sending');
  });

  test('expired assistant tombstone survives cold restart and sync', () async {
    await database
        .into(database.messages)
        .insert(
          db.MessagesCompanion.insert(
            id: placeholderId,
            conversationId: conversationId,
            role: 'assistant',
            content: '生成中...',
            status: const Value('sending'),
            createdAt: userMessage.createdAt.millisecondsSinceEpoch,
          ),
        );
    final cloud = CloudLocalStore(
      database,
      await SharedPreferences.getInstance(),
      directory,
      directory,
    );
    for (final table in ['cloud_dirty', 'lan_dirty']) {
      await cloud.execute(
        "DELETE FROM $table WHERE kind='messages' AND entity_id=?",
        [placeholderId],
      );
    }
    await reopenConversation();
    final stored = await container
        .read(messageRepositoryProvider)
        .getById(placeholderId);
    expect(stored?.status, 'failed');
    expect(stored?.deletedAt, recoveryNow.millisecondsSinceEpoch);
    expect(
      stored?.purgeAt,
      recoveryNow.add(const Duration(days: 30)).millisecondsSinceEpoch,
    );
    final raw = await container
        .read(chatHistoryStoreProvider)
        .loadAllRawMessages(conversationId);
    final window = await container.read(
      conversationMessageWindowProvider(conversationId).future,
    );
    expect(raw.map((m) => m.id), isNot(contains(placeholderId)));
    expect(window.messages.map((m) => m.id), isNot(contains(placeholderId)));
    final reopenedCloud = CloudLocalStore(
      database,
      await SharedPreferences.getInstance(),
      directory,
      directory,
    );
    for (final table in ['cloud_dirty', 'lan_dirty']) {
      expect(
        await reopenedCloud.rows(
          "SELECT * FROM $table WHERE kind='messages' AND entity_id=?",
          [placeholderId],
        ),
        hasLength(1),
      );
    }
    final snapshot = await reopenedCloud.read('messages', placeholderId);
    expect(snapshot, isNotNull);
    expect((snapshot!.payload['row'] as Map)['status'], 'failed');
    expect((snapshot.payload['row'] as Map)['deleted_at'], stored!.deletedAt);
  });

  test(
    'warm recovery removes cached assistant and its related records',
    () async {
      await database
          .into(database.messages)
          .insert(
            db.MessagesCompanion.insert(
              id: placeholderId,
              conversationId: conversationId,
              role: 'assistant',
              content: '生成中...',
              status: const Value('sending'),
              createdAt: 1,
            ),
          );
      await database
          .into(database.messageBlocks)
          .insert(
            db.MessageBlocksCompanion.insert(
              id: 'orphan-block',
              messageId: placeholderId,
              type: 'mainText',
              data: '{}',
              createdAt: 1,
            ),
          );
      await database
          .into(database.messageProjectionMappings)
          .insert(
            db.MessageProjectionMappingsCompanion.insert(
              id: 'orphan-mapping',
              conversationId: conversationId,
              rawMessageId: placeholderId,
              projectedMessageId: 'orphan-projection',
              createdAt: 1,
            ),
          );
      await database.customStatement(
        "INSERT INTO message_states(conversation_id,anchor_id,kind,raw_hash,engine_version,status,updated_at) VALUES(?,?,'test','hash',1,'ready',1)",
        [conversationId, placeholderId],
      );
      final cache = container.read(conversationTimelineCacheProvider);
      await cache.upsertMessages(
        conversationId: conversationId,
        messages: [
          Message.text(
            id: placeholderId,
            role: 'assistant',
            content: '生成中...',
            status: 'sending',
            createdAt: userMessage.createdAt,
          ),
          Message.text(
            id: 'orphan-projection',
            role: 'assistant',
            content: '生成中...',
            status: 'sending',
            createdAt: userMessage.createdAt,
          ).copyWith(sourceMessageId: placeholderId),
        ],
      );
      await cache.hideMessages(
        conversationId: conversationId,
        rawMessageIds: [placeholderId],
      );
      await container
          .read(chatHistoryStoreProvider)
          .recoverInterruptedUserMessages(
            conversationId,
            isActiveSend: (_) => false,
          );
      expect(
        (await cache.loadCachedMessages(conversationId)).map((m) => m.id),
        isNot(anyOf(contains(placeholderId), contains('orphan-projection'))),
      );
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('aicove.frontend_hidden.v1.$conversationId'),
        isNot(contains(placeholderId)),
      );
      expect(
        (await database.select(database.messageBlocks).get()).single.deletedAt,
        recoveryNow.millisecondsSinceEpoch,
      );
      expect(
        await database.select(database.messageProjectionMappings).get(),
        isEmpty,
      );
      expect(
        await database.customSelect('SELECT * FROM message_states').get(),
        isEmpty,
      );
    },
  );

  test('assistant topic boundary and live send are never recovered', () async {
    for (final id in [
      'boundary-assistant',
      'live-assistant',
      'fresh-assistant',
    ]) {
      await database
          .into(database.messages)
          .insert(
            db.MessagesCompanion.insert(
              id: id,
              conversationId: conversationId,
              role: 'assistant',
              content: '生成中...',
              status: const Value('sending'),
              createdAt: id == 'fresh-assistant'
                  ? recoveryNow.millisecondsSinceEpoch
                  : 1,
            ),
          );
    }
    await database.customStatement(
      'UPDATE conversations SET context_start_message_id=? WHERE id=?',
      ['boundary-assistant', conversationId],
    );
    final cloud = CloudLocalStore(
      database,
      await SharedPreferences.getInstance(),
      directory,
      directory,
    );
    for (final table in ['cloud_dirty', 'lan_dirty']) {
      await cloud.execute('DELETE FROM $table');
    }
    await container
        .read(chatHistoryStoreProvider)
        .recoverInterruptedUserMessages(
          conversationId,
          isActiveSend: (id) => id == 'live-assistant',
        );
    for (final id in [
      'boundary-assistant',
      'live-assistant',
      'fresh-assistant',
    ]) {
      final stored = await container
          .read(messageRepositoryProvider)
          .getById(id);
      expect(stored?.status, 'sending');
      expect(stored?.deletedAt, isNull);
      for (final table in ['cloud_dirty', 'lan_dirty']) {
        expect(
          await cloud.rows(
            "SELECT * FROM $table WHERE kind='messages' AND entity_id=?",
            [id],
          ),
          isEmpty,
        );
      }
    }
  });

  test(
    'cold restart makes an interrupted send retryable in DB and timeline',
    () async {
      // Reproduce the public transient writes used by the streaming delivery.
      // The assistant has not reached appendAssistantRawMessage yet.
      await container
          .read(conversationTimelineCacheProvider)
          .replaceMessagesTransient(
            conversationId: conversationId,
            messages: [
              Message.text(
                id: placeholderId,
                role: 'assistant',
                content: '生成中...',
                status: 'sending',
                createdAt: userMessage.createdAt.add(
                  const Duration(seconds: 1),
                ),
              ),
            ],
          );
      container
              .read(conversationSendingProvider(conversationId).notifier)
              .state =
          true;
      container.read(chatStatusProvider.notifier).state = ChatStatus.thinking;
      container
          .read(activeStreamProjectionsProvider.notifier)
          .publish(
            const ActiveStreamProjection(
              conversationId: conversationId,
              generationSeq: 1,
              writeEpoch: 0,
              tailMessageId: placeholderId,
              tailText: 'Synthetic partial reply',
              phase: ActiveStreamPhase.streamingTail,
            ),
          );
      final before = await container
          .read(conversationTimelineCacheProvider)
          .loadCachedMessages(conversationId);
      expect(before.map((message) => message.id), contains(placeholderId));
      expect(
        await container.read(messageRepositoryProvider).getById(placeholderId),
        isNull,
      );

      final window = await reopenConversation();
      // These assertions distinguish a stuck persisted message from a stuck
      // generation lock or a resurrected transient assistant bubble.
      expect(
        container.read(conversationSendingProvider(conversationId)),
        isFalse,
      );
      expect(container.read(chatStatusProvider), ChatStatus.idle);
      expect(container.read(activeStreamProjectionsProvider), isEmpty);
      expect(window.messages.map((message) => message.id), [userMessage.id]);
      expect(window.messages.single.displayText, userMessage.displayText);
      final raw = await container
          .read(chatHistoryStoreProvider)
          .loadAllRawMessages(conversationId);
      final stored = await container
          .read(messageRepositoryProvider)
          .getById(userMessage.id);

      // Only failed messages can enter the existing retry/recall flow.
      // An expired orphan must be recovered consistently across all three views.
      expect(
        {
          'database': stored?.status,
          'raw history': raw.single.status,
          'UI timeline': window.messages.single.status,
        },
        {
          'database': 'failed',
          'raw history': 'failed',
          'UI timeline': 'failed',
        },
        reason:
            'The old process cannot finish this send. Cold loading must make '
            'the committed user message retryable instead of leaving sending.',
      );
    },
  );

  for (final age in [
    const Duration(milliseconds: -1),
    Duration.zero,
    kInterruptedSendRecoveryThreshold - const Duration(milliseconds: 1),
    kInterruptedSendRecoveryThreshold,
  ]) {
    test(
      'cold restart preserves sending at age ${age.inMilliseconds}ms',
      () async {
        recoveryNow = userMessage.createdAt.add(age);
        final window = await reopenConversation();
        final raw = await container
            .read(chatHistoryStoreProvider)
            .loadAllRawMessages(conversationId);
        final stored = await container
            .read(messageRepositoryProvider)
            .getById(userMessage.id);
        expect(
          {
            'database': stored?.status,
            'raw history': raw.single.status,
            'UI timeline': window.messages.single.status,
          },
          {
            'database': 'sending',
            'raw history': 'sending',
            'UI timeline': 'sending',
          },
        );
      },
    );
  }

  test(
    'cold restart preserves an already committed successful reply',
    () async {
      final assistant = Message.text(
        id: 'committed-assistant',
        role: 'assistant',
        content: 'Synthetic completed reply',
        status: 'sent',
        createdAt: userMessage.createdAt.add(const Duration(seconds: 1)),
      );
      await container
          .read(chatHistoryStoreProvider)
          .appendAssistantRawMessage(
            conversationId: conversationId,
            userMessageId: userMessage.id,
            rawMessage: assistant,
            projectedMessages: [assistant],
            lastMessagePreview: assistant.displayText,
          );

      final window = await reopenConversation();
      final stored = await container
          .read(messageRepositoryProvider)
          .getById(userMessage.id);
      expect(stored?.status, 'sent');
      expect(window.messages.map((message) => message.role), [
        'user',
        'assistant',
      ]);
      expect(window.messages.map((message) => message.status), [
        'sent',
        'sent',
      ]);
      expect(window.messages.last.displayText, assistant.displayText);
    },
  );

  test(
    'cold entry recovers an orphan without touching a live generation',
    () async {
      final committed = Completer<Message>();
      final release = Completer<void>();
      container.dispose();
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(database),
          messageRepositoryProvider.overrideWith(
            (ref) => MessageRepository(
              ref.watch(databaseProvider),
              now: () => recoveryNow,
            ),
          ),
          chatSendServiceProvider.overrideWith(
            (ref) => _BlockedSendService(ref, committed, release),
          ),
        ],
      );
      await container.read(conversationsProvider.future);
      container.read(activeConversationIdProvider.notifier).state =
          conversationId;
      // The user message is already committed: the send reports failure on
      // that record instead of throwing a pre-commit draft/edit failure.
      final sending = container
          .read(chatActionsProvider)
          .send('Synthetic live send');
      try {
        final live = await committed.future.timeout(
          const Duration(seconds: 10),
        );
        // A local live task must remain protected even after the age gate opens.
        recoveryNow = live.createdAt
            .add(kInterruptedSendRecoveryThreshold)
            .add(const Duration(milliseconds: 1));
        final cache = container.read(conversationTimelineCacheProvider);
        await cache.replaceMessagesTransient(
          conversationId: conversationId,
          messages: [
            Message.text(
              id: placeholderId,
              role: 'assistant',
              content: 'Synthetic live placeholder',
              status: 'sending',
              createdAt: live.createdAt.add(const Duration(seconds: 1)),
            ),
          ],
        );
        // The UI flag is not the authoritative generation registry.
        container
                .read(conversationSendingProvider(conversationId).notifier)
                .state =
            false;
        final window = await container.read(
          conversationMessageWindowProvider(conversationId).future,
        );
        expect(
          {for (final message in window.messages) message.id: message.status},
          {
            userMessage.id: 'failed',
            live.id: 'sending',
            placeholderId: 'sending',
          },
        );
        expect(
          (await container.read(messageRepositoryProvider).getById(live.id))
              ?.status,
          'sending',
        );
        // Re-entering while generation is still running must also be safe.
        container.invalidate(conversationMessageWindowProvider(conversationId));
        final reentered = await container.read(
          conversationMessageWindowProvider(conversationId).future,
        );
        expect(
          reentered.messages.firstWhere((m) => m.id == live.id).status,
          'sending',
        );
      } finally {
        release.complete();
        await sending;
      }
      final live = await committed.future;
      expect(
        (await container.read(messageRepositoryProvider).getById(live.id))
            ?.status,
        'failed',
      );
    },
  );

  test(
    'recovery is scoped to valid sending messages and is idempotent',
    () async {
      final now = userMessage.createdAt.millisecondsSinceEpoch;
      for (final row in [
        ('assistant', 'assistant', 'sending', false, false),
        ('deleted', 'user', 'sending', true, false),
        ('replaced', 'user', 'sending', false, true),
        ('sent', 'user', 'sent', false, false),
        ('failed', 'user', 'failed', false, false),
      ]) {
        await database
            .into(database.messages)
            .insert(
              db.MessagesCompanion.insert(
                id: row.$1,
                conversationId: conversationId,
                role: row.$2,
                content: 'Synthetic ${row.$1}',
                status: Value(row.$3),
                deletedAt: Value(row.$4 ? now : null),
                replacedBy: Value(row.$5 ? 'replacement' : null),
                createdAt: now,
              ),
            );
      }
      final repository = container.read(messageRepositoryProvider);
      expect(
        await repository.recoverInterruptedUserMessages(
          'different-conversation',
          isActiveSend: (_) => false,
        ),
        isEmpty,
      );
      expect(
        await repository.recoverInterruptedUserMessages(
          conversationId,
          isActiveSend: (_) => false,
        ),
        unorderedEquals([userMessage.id, 'assistant']),
      );
      expect(
        await repository.recoverInterruptedUserMessages(
          conversationId,
          isActiveSend: (_) => false,
        ),
        isEmpty,
      );
      expect((await repository.getById('assistant'))?.deletedAt, isNotNull);
      expect((await repository.getById('assistant'))?.status, 'failed');
      for (final id in ['deleted', 'replaced']) {
        expect((await repository.getById(id))?.status, 'sending');
      }
      expect((await repository.getById('sent'))?.status, 'sent');
      expect((await repository.getById('failed'))?.status, 'failed');
    },
  );

  test(
    'recovered send no longer blocks a manual compaction snapshot',
    () async {
      await database
          .into(database.messages)
          .insert(
            db.MessagesCompanion.insert(
              id: 'previous-completed-user',
              conversationId: conversationId,
              role: 'user',
              content: 'Synthetic completed history',
              createdAt: userMessage.createdAt.millisecondsSinceEpoch - 1000,
            ),
          );
      await reopenConversation();
      final store = SqliteContextSummaryStore(
        database,
        container.read(chatHistoryStoreProvider).loadAllRawMessages,
      );
      final snapshot = await store.manualSnapshot(conversationId);
      expect(snapshot.messages.map((m) => m.id), ['previous-completed-user']);
      expect(snapshot.allMessages.last.status, 'failed');
    },
  );

  test(
    'recovery checks live ownership after waiting for the database',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final busy = database.transaction(() async {
        await database.customSelect('SELECT 1').get();
        entered.complete();
        await release.future;
      });
      await entered.future;
      var active = false;
      final recovery = container
          .read(messageRepositoryProvider)
          .recoverInterruptedUserMessages(
            conversationId,
            isActiveSend: (_) => active,
          );
      active = true;
      release.complete();
      await busy;
      expect(await recovery, isEmpty);
      expect(
        (await container
                .read(messageRepositoryProvider)
                .getById(userMessage.id))
            ?.status,
        'sending',
      );
    },
  );

  for (final remoteRole in ['user', 'assistant']) {
    test(
      'fresh synced $remoteRole sending stays unchanged without cloud or LAN dirty marks',
      () async {
        const remoteId = 'fresh-remote-user';
        final cloud = CloudLocalStore(
          database,
          await SharedPreferences.getInstance(),
          directory,
          directory,
        );
        final source = await cloud.read(
          'messages',
          userMessage.id,
          includeRelated: false,
        );
        // Exercise the production sync apply path without networking. Received
        // rows are applied with local change capture suspended, then capture is
        // restored before recovery so an accidental UPDATE would be observable.
        await database.transaction(() async {
          await cloud.execute(
            'UPDATE cloud_client_state SET suspended=1 WHERE id=1',
          );
          await cloud.execute('UPDATE lan_state SET suspended=1 WHERE id=1');
          try {
            await cloud.apply('messages', remoteId, {
              ...source!.payload,
              'row': {
                ...Map<String, dynamic>.from(source.payload['row'] as Map),
                'id': remoteId,
                'role': remoteRole,
                'content': 'Synthetic incoming in-flight user message',
                'created_at': recoveryNow.millisecondsSinceEpoch,
              },
            }, false);
          } finally {
            await cloud.execute(
              'UPDATE cloud_client_state SET suspended=0 WHERE id=1',
            );
            await cloud.execute('UPDATE lan_state SET suspended=0 WHERE id=1');
          }
        });
        // The sync engine normally refreshes the frontend cache after applying
        // rows; this test uses a cold timeline to exercise that read boundary.
        container.invalidate(conversationTimelineCacheProvider);
        Future<void> expectNoRemoteDirtyMarks() async {
          for (final table in ['cloud_dirty', 'lan_dirty']) {
            expect(
              await cloud.rows(
                "SELECT * FROM $table WHERE kind='messages' AND entity_id=?",
                [remoteId],
              ),
              isEmpty,
              reason: 'Recovery must not queue the fresh remote send in $table',
            );
          }
        }

        await expectNoRemoteDirtyMarks();
        final window = await container.read(
          conversationMessageWindowProvider(conversationId).future,
        );
        final raw = await container
            .read(chatHistoryStoreProvider)
            .loadAllRawMessages(conversationId);
        expect(
          (await container.read(messageRepositoryProvider).getById(remoteId))
              ?.status,
          'sending',
        );
        expect(
          raw.firstWhere((message) => message.id == remoteId).status,
          'sending',
        );
        expect(
          window.messages
              .firstWhere((message) => message.id == remoteId)
              .status,
          'sending',
        );
        // Recovery still processes an expired orphan in the same conversation.
        expect(
          (await container
                  .read(messageRepositoryProvider)
                  .getById(userMessage.id))
              ?.status,
          'failed',
        );
        await expectNoRemoteDirtyMarks();
      },
    );
  }

  test(
    'recovery is tracked by cloud and LAN and included in sync snapshots',
    () async {
      final cloud = CloudLocalStore(
        database,
        await SharedPreferences.getInstance(),
        directory,
        directory,
      );
      Future<int> revision(String table) async =>
          (await cloud.rows(
                "SELECT revision FROM $table WHERE kind='messages' AND entity_id=?",
                [userMessage.id],
              )).single['revision']
              as int;
      final cloudBefore = await revision('cloud_dirty');
      final lanBefore = await revision('lan_dirty');
      await container
          .read(chatActionsProvider)
          .recoverInterruptedUserMessages(conversationId);
      expect(await revision('cloud_dirty'), greaterThan(cloudBefore));
      expect(await revision('lan_dirty'), greaterThan(lanBefore));
      final snapshot = await cloud.read('messages', userMessage.id);
      expect((snapshot!.payload['row'] as Map)['status'], 'failed');
    },
  );
}
