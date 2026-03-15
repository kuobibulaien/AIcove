import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/repositories/memory_repository.dart';
import 'package:aicove_flutter/src/features/memory/models/memory_entity.dart';

Future<void> _insertConversation(AppDatabase db, String id) async {
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.into(db.conversations).insert(
        ConversationsCompanion.insert(
          id: id,
          title: id,
          displayName: id,
          createdAt: now,
          updatedAt: now,
        ),
      );
}

MemoryEntity _buildMemory(String id, String conversationId) {
  final now = DateTime.now();
  return MemoryEntity(
    id: id,
    content: 'memory:$id',
    conversationId: conversationId,
    createdAt: now,
  );
}

void main() {
  group('MemoryRepository 会话校验', () {
    late AppDatabase db;
    late MemoryRepository repository;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repository = MemoryRepository(db);
      await _insertConversation(db, 'conv_a');
      await _insertConversation(db, 'conv_b');
    });

    tearDown(() async {
      await db.close();
    });

    test('updateMemory 在会话不匹配时拒绝更新', () async {
      final memory = _buildMemory('mem_update', 'conv_a');
      await repository.addMemory(memory, triggerEviction: false);

      await expectLater(
        repository.updateMemory(
          memory.copyWith(content: 'updated'),
          conversationId: 'conv_b',
        ),
        throwsA(isA<StateError>()),
      );

      final stored = await repository.getById(memory.id);
      expect(stored, isNotNull);
      expect(stored!.content, memory.content);
    });

    test('softDelete 和 restore 会校验 conversationId', () async {
      final memory = _buildMemory('mem_restore', 'conv_a');
      await repository.addMemory(memory, triggerEviction: false);

      await expectLater(
        repository.softDelete(memory.id, conversationId: 'conv_b'),
        throwsA(isA<StateError>()),
      );
      expect((await repository.getById(memory.id))!.deletedAt, isNull);

      await repository.softDelete(memory.id, conversationId: 'conv_a');
      expect((await repository.getById(memory.id))!.deletedAt, isNotNull);

      await expectLater(
        repository.restore(memory.id, conversationId: 'conv_b'),
        throwsA(isA<StateError>()),
      );
      expect((await repository.getById(memory.id))!.deletedAt, isNotNull);

      await repository.restore(memory.id, conversationId: 'conv_a');
      expect((await repository.getById(memory.id))!.deletedAt, isNull);
    });
  });
}
