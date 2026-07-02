import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/core/database/repositories/memory_repository.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_page_conversation_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/memory/services/memory_service.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

Future<void> _insertConversation(
  AppDatabase db, {
  required String id,
  String? contextStartMessageId,
  String? lastMessage,
  DateTime? lastMessageTime,
  int unreadCount = 0,
}) async {
  final now = DateTime(2026, 3, 21, 20).millisecondsSinceEpoch;
  await db.into(db.conversations).insert(
        ConversationsCompanion.insert(
          id: id,
          title: id,
          displayName: id,
          contextStartMessageId: Value(contextStartMessageId),
          lastMessage: Value(lastMessage),
          lastMessageTime: Value(lastMessageTime?.millisecondsSinceEpoch),
          unreadCount: Value(unreadCount),
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> _insertMessage(
  AppDatabase db, {
  required String id,
  required String conversationId,
  required String role,
  required DateTime createdAt,
}) async {
  await db.into(db.messages).insert(
        MessagesCompanion.insert(
          id: id,
          conversationId: conversationId,
          role: role,
          content: '$role:$id',
          status: const Value('sent'),
          createdAt: createdAt.millisecondsSinceEpoch,
        ),
      );
}

Future<void> _insertMemory(
  AppDatabase db, {
  required String id,
  required String conversationId,
}) async {
  final now = DateTime(2026, 3, 21, 20).millisecondsSinceEpoch;
  await db.into(db.memories).insert(
        MemoriesCompanion.insert(
          id: id,
          content: 'memory:$id',
          conversationId: Value(conversationId),
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> _insertDiary(
  AppDatabase db, {
  required String id,
  required String conversationId,
}) async {
  final now = DateTime(2026, 3, 21, 20).millisecondsSinceEpoch;
  await db.into(db.diaries).insert(
        DiariesCompanion.insert(
          id: id,
          conversationId: conversationId,
          date: now,
          content: 'diary:$id',
          createdAt: now,
          updatedAt: now,
        ),
      );
}

Future<void> _insertSummarizationRecord(
  AppDatabase db, {
  required String id,
  required String conversationId,
}) async {
  final now = DateTime(2026, 3, 21, 20).millisecondsSinceEpoch;
  await db.into(db.summarizationRecords).insert(
        SummarizationRecordsCompanion.insert(
          id: id,
          conversationId: conversationId,
          dateKey: '2026-03-21',
          roundKey: 'day:2026-03-21:$id',
          firstMsgTime: now,
          lastMsgTime: now,
          messageCount: 1,
          createdAt: now,
        ),
      );
}

class _RecordingMemoryService extends MemoryService {
  _RecordingMemoryService(
    MemoryRepository memoryRepository,
    MessageRepository messageRepository,
  ) : super(
          const MemoryServiceConfig(
            enabled: true,
            enableCapacityCompress: false,
            enableMemoryMerge: false,
            enableProfileLayer: false,
            enablePreFlush: false,
            enableNextDayTrigger: true,
          ),
          memoryRepository,
          messageRepository,
        );

  final List<List<String>> candidateMessageIds = <List<String>>[];
  final List<MemoryIngestTrigger> triggers = <MemoryIngestTrigger>[];
  final List<String?> contextStartMessageIds = <String?>[];
  final List<String> lastMessageIds = <String>[];

  @override
  Future<void> ingestConversationTopic({
    required String conversationId,
    required String lastMessageId,
    String? contextStartMessageId,
    required MemoryIngestTrigger trigger,
  }) async {
    contextStartMessageIds.add(contextStartMessageId);
    lastMessageIds.add(lastMessageId);
    await super.ingestConversationTopic(
      conversationId: conversationId,
      lastMessageId: lastMessageId,
      contextStartMessageId: contextStartMessageId,
      trigger: trigger,
    );
  }

  @override
  Future<void> ingestMessages({
    required String conversationId,
    Iterable<String>? candidateMessageIds,
    int? beforeTimestampExclusive,
    required MemoryIngestTrigger trigger,
  }) async {
    this.candidateMessageIds.add(
          candidateMessageIds?.toList(growable: false) ?? const <String>[],
        );
    triggers.add(trigger);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatPageConversationActions 记忆联动', () {
    late AppDatabase db;
    late PathProviderPlatform previousPathProvider;
    Directory? tempDir;

    setUp(() async {
      previousPathProvider = PathProviderPlatform.instance;
      tempDir = await Directory.systemTemp.createTemp('chat_page_actions_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      PathProviderPlatform.instance = previousPathProvider;
      await db.close();
      if (tempDir != null && await tempDir!.exists()) {
        await tempDir!.delete(recursive: true);
      }
    });

    test('开始新话题前会先总结当前上下文消息', () async {
      await _insertConversation(
        db,
        id: 'conv_topic',
        contextStartMessageId: 'm1',
      );
      final base = DateTime(2026, 3, 21, 10, 0);
      await _insertMessage(
        db,
        id: 'm1',
        conversationId: 'conv_topic',
        role: 'assistant',
        createdAt: base,
      );
      await _insertMessage(
        db,
        id: 'm2',
        conversationId: 'conv_topic',
        role: 'user',
        createdAt: base.add(const Duration(minutes: 1)),
      );
      await _insertMessage(
        db,
        id: 'm3',
        conversationId: 'conv_topic',
        role: 'assistant',
        createdAt: base.add(const Duration(minutes: 2)),
      );
      await _insertMessage(
        db,
        id: 'm4',
        conversationId: 'conv_topic',
        role: 'user',
        createdAt: base.add(const Duration(minutes: 3)),
      );

      final messageRepository = MessageRepository(db);
      final memoryService =
          _RecordingMemoryService(MemoryRepository(db), messageRepository);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          chatPageMemoryPluginProvider.overrideWithValue(null),
          chatPageMemoryServiceProvider.overrideWithValue(memoryService),
        ],
      );
      addTearDown(container.dispose);
      await container.read(conversationsProvider.future);

      await container.read(chatPageConversationActionsProvider).startNewTopic(
            conversationId: 'conv_topic',
            lastMessageId: 'm3',
          );

      expect(memoryService.triggers, [MemoryIngestTrigger.manual]);
      expect(memoryService.contextStartMessageIds, ['m1']);
      expect(memoryService.lastMessageIds, ['m3']);
      expect(memoryService.candidateMessageIds, [
        ['m2', 'm3']
      ]);

      final row = await (db.select(db.conversations)
            ..where((table) => table.id.equals('conv_topic')))
          .getSingle();
      expect(row.contextStartMessageId, 'm3');
    });

    test('清空聊天会同步清空该角色的记忆日记和总结记录', () async {
      await _insertConversation(
        db,
        id: 'conv_a',
        contextStartMessageId: 'm1',
        lastMessage: 'hello',
        lastMessageTime: DateTime(2026, 3, 21, 9, 0),
        unreadCount: 3,
      );
      await _insertConversation(
        db,
        id: 'conv_b',
        contextStartMessageId: 'n1',
        lastMessage: 'keep',
        lastMessageTime: DateTime(2026, 3, 21, 9, 5),
        unreadCount: 1,
      );

      final base = DateTime(2026, 3, 21, 9, 0);
      await _insertMessage(
        db,
        id: 'm1',
        conversationId: 'conv_a',
        role: 'user',
        createdAt: base,
      );
      await _insertMessage(
        db,
        id: 'n1',
        conversationId: 'conv_b',
        role: 'user',
        createdAt: base.add(const Duration(minutes: 1)),
      );
      await _insertMemory(db, id: 'mem_a', conversationId: 'conv_a');
      await _insertMemory(db, id: 'mem_b', conversationId: 'conv_b');
      await _insertDiary(db, id: 'diary_a', conversationId: 'conv_a');
      await _insertDiary(db, id: 'diary_b', conversationId: 'conv_b');
      await _insertSummarizationRecord(db,
          id: 'record_a', conversationId: 'conv_a');
      await _insertSummarizationRecord(db,
          id: 'record_b', conversationId: 'conv_b');

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          chatPageMemoryPluginProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      await container.read(conversationsProvider.future);

      await container.read(chatPageConversationActionsProvider).clearMessages(
            'conv_a',
          );

      final convARow = await (db.select(db.conversations)
            ..where((table) => table.id.equals('conv_a')))
          .getSingle();
      final convBRow = await (db.select(db.conversations)
            ..where((table) => table.id.equals('conv_b')))
          .getSingle();

      expect(convARow.contextStartMessageId, isNull);
      expect(convARow.lastMessage, isNull);
      expect(convARow.lastMessageTime, isNull);
      expect(convARow.unreadCount, 0);
      expect(convBRow.contextStartMessageId, 'n1');
      expect(convBRow.lastMessage, 'keep');
      expect(convBRow.unreadCount, 1);

      expect(
        await container
            .read(messageRepositoryProvider)
            .getAllByConversationOrdered('conv_a'),
        isEmpty,
      );
      expect(
        await container
            .read(messageRepositoryProvider)
            .getAllByConversationOrdered('conv_b'),
        hasLength(1),
      );

      final remainingMemoriesA = await (db.select(db.memories)
            ..where((table) => table.conversationId.equals('conv_a')))
          .get();
      final remainingMemoriesB = await (db.select(db.memories)
            ..where((table) => table.conversationId.equals('conv_b')))
          .get();
      final remainingDiariesA = await (db.select(db.diaries)
            ..where((table) => table.conversationId.equals('conv_a')))
          .get();
      final remainingDiariesB = await (db.select(db.diaries)
            ..where((table) => table.conversationId.equals('conv_b')))
          .get();
      final remainingRecordsA = await (db.select(db.summarizationRecords)
            ..where((table) => table.conversationId.equals('conv_a')))
          .get();
      final remainingRecordsB = await (db.select(db.summarizationRecords)
            ..where((table) => table.conversationId.equals('conv_b')))
          .get();

      expect(remainingMemoriesA, isEmpty);
      expect(remainingDiariesA, isEmpty);
      expect(remainingRecordsA, isEmpty);
      expect(remainingMemoriesB, hasLength(1));
      expect(remainingDiariesB, hasLength(1));
      expect(remainingRecordsB, hasLength(1));
    });
  });
}
