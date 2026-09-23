import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/chat/application/chat_page_conversation_actions.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart' as chat;
import 'package:aicove_flutter/src/features/memory/data/sqlite_memory_store.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_item.dart';
import 'package:aicove_flutter/src/ui/features/character/services/contact_edit_snapshot_store.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

Future<void> _insertConversation(
  AppDatabase db, {
  required String id,
  String? recipeId,
  String? contextStartMessageId,
  String? lastMessage,
  DateTime? lastMessageTime,
  int unreadCount = 0,
}) async {
  final now = DateTime(2026, 3, 21, 20).millisecondsSinceEpoch;
  await db
      .into(db.conversations)
      .insert(
        ConversationsCompanion.insert(
          id: id,
          title: id,
          displayName: id,
          recipeId: Value(recipeId),
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
  await db
      .into(db.messages)
      .insert(
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatPageConversationActions', () {
    late AppDatabase db;
    late PathProviderPlatform previousPathProvider;
    Directory? tempDir;

    setUp(() async {
      await ContactEditSnapshotStore.instance.clearMemory();
      previousPathProvider = PathProviderPlatform.instance;
      tempDir = await Directory.systemTemp.createTemp('chat_page_actions_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir!.path);
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await ContactEditSnapshotStore.instance.clearMemory();
      PathProviderPlatform.instance = previousPathProvider;
      await db.close();
      if (tempDir != null && await tempDir!.exists()) {
        await tempDir!.delete(recursive: true);
      }
    });

    test('角色编辑会持久化并清除酒馆上下文预设绑定', () async {
      await _insertConversation(db, id: 'conv_recipe');
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
        ],
      );
      addTearDown(container.dispose);
      await container.read(conversationsProvider.future);

      final actions = container.read(chatPageConversationActionsProvider);
      await actions.applyConversationEdits(
        'conv_recipe',
        recipeId: 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      var row = await (db.select(
        db.conversations,
      )..where((table) => table.id.equals('conv_recipe'))).getSingle();
      expect(row.recipeId, 'st_preset_aaaaaaaaaaaaaaaaaaaaaaaa');

      await actions.applyConversationEdits('conv_recipe', clearRecipeId: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      row = await (db.select(
        db.conversations,
      )..where((table) => table.id.equals('conv_recipe'))).getSingle();
      expect(row.recipeId, isNull);
    });

    test('清空聊天会同步清空该角色的摘要和自动整理的记忆，锁定记忆保留', () async {
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
      final memory = SqliteMemoryStore(db);
      for (final owner in ['conv_a', 'conv_b']) {
        await memory.applyAgentOps(
          owner,
          [
            AddMemory(
              layer: MemoryLayer.archive,
              title: '自动 $owner',
              content: '自动整理 $owner',
              sourceIds: const ['x'],
            ),
          ],
          processedUntil: chat.Message(
            id: owner == 'conv_a' ? 'm1' : 'n1',
            role: 'user',
            content: '',
            createdAt: base,
          ),
          generation: 0,
        );
        await db.customStatement(
          "INSERT INTO context_summaries VALUES(?, ?, 'manual', ?, NULL, '摘要', '[]', 'd', 1)",
          ['s_$owner', owner, owner == 'conv_a' ? 'm1' : 'n1'],
        );
      }
      await memory.saveByUser(
        ownerId: 'conv_a',
        layer: MemoryLayer.core,
        title: '手写',
        content: '保留',
      );

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
        ],
      );
      addTearDown(container.dispose);
      await container.read(conversationsProvider.future);

      await container
          .read(chatPageConversationActionsProvider)
          .clearMessages('conv_a');

      final convARow = await (db.select(
        db.conversations,
      )..where((table) => table.id.equals('conv_a'))).getSingle();
      final convBRow = await (db.select(
        db.conversations,
      )..where((table) => table.id.equals('conv_b'))).getSingle();

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

      expect((await memory.list('conv_a')).map((i) => i.title), ['手写']);
      expect(await memory.list('conv_b'), hasLength(1));
      final summaries = await db
          .customSelect('SELECT owner_id FROM context_summaries')
          .get();
      expect(summaries.map((r) => r.read<String>('owner_id')), ['conv_b']);
    });
  });
}
