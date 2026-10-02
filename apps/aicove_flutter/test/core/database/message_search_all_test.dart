import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('跨会话搜索只返回有效的用户与助手消息，最新在前', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (final id in ['a', 'b']) {
      await db
          .into(db.conversations)
          .insert(
            ConversationsCompanion.insert(
              id: id,
              title: id,
              displayName: id,
              createdAt: 1,
              updatedAt: 1,
            ),
          );
    }
    Future<void> add(
      String id,
      String conversationId,
      String role,
      int at, {
      Value<int?> deletedAt = const Value.absent(),
      Value<String?> replacedBy = const Value.absent(),
    }) {
      return db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: id,
              conversationId: conversationId,
              role: role,
              content: '今天喝了橘子汽水 $id',
              createdAt: at,
              deletedAt: deletedAt,
              replacedBy: replacedBy,
            ),
          );
    }

    await add('old', 'a', 'user', 1);
    await add('new', 'b', 'assistant', 2);
    await add('system', 'a', 'system', 3);
    await add('deleted', 'a', 'user', 4, deletedAt: const Value(9));
    await add('replaced', 'b', 'assistant', 5, replacedBy: const Value('new'));
    await db
        .into(db.messages)
        .insert(
          MessagesCompanion.insert(
            id: 'other',
            conversationId: 'a',
            role: 'user',
            content: '无关',
            createdAt: 6,
          ),
        );

    final repo = MessageRepository(db);
    final hits = await repo.searchAll('  橘子汽水 ');
    expect(hits.map((m) => m.id), ['new', 'old']);
    expect(hits.map((m) => m.conversationId), ['b', 'a']);
    expect(await repo.searchAll('   '), isEmpty);
  });
}
