import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';

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

void main() {
  group('MessageRepository 稳定顺序', () {
    late AppDatabase db;
    late MessageRepository repository;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repository = MessageRepository(db);
      await _insertConversation(db, 'conv_stable_order');
    });

    tearDown(() async {
      await db.close();
    });

    test('边界查询严格排除锚点及此前同毫秒消息，并拒绝无效锚点', () async {
      const conversationId = 'conv_stable_order';
      final time = DateTime(2026, 4, 4);
      for (final id in [
        'before',
        'anchor',
        'z_after',
        'a_after',
        'deleted',
        'replaced',
      ]) {
        await _insertMessage(
          db,
          id: id,
          conversationId: conversationId,
          role: 'user',
          createdAt: time,
        );
      }
      await db.customStatement(
        "UPDATE messages SET deleted_at = 1 WHERE id = 'deleted'",
      );
      await db.customStatement(
        "UPDATE messages SET replaced_by = 'a_after' WHERE id = 'replaced'",
      );
      await _insertConversation(db, 'other');
      await _insertMessage(
        db,
        id: 'foreign',
        conversationId: 'other',
        role: 'user',
        createdAt: time,
      );
      final rows = await repository.getByConversationAfterBoundaryOrderedStable(
        conversationId,
        boundaryMessageId: 'anchor',
      );
      expect(rows.map((row) => row.id), ['z_after', 'a_after']);
      for (final invalid in ['missing', 'deleted', 'replaced', 'foreign']) {
        await expectLater(
          repository.getByConversationAfterBoundaryOrderedStable(
            conversationId,
            boundaryMessageId: invalid,
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              '话题边界已失效，请先恢复或撤销上次压缩，本轮未发送。',
            ),
          ),
        );
      }
    });

    test('全量升序读取在同一时间戳下应保留真实入库顺序', () async {
      final createdAt = DateTime(2026, 4, 4, 12, 0, 0);

      await _insertMessage(
        db,
        id: 'user_02',
        conversationId: 'conv_stable_order',
        role: 'user',
        createdAt: createdAt,
      );
      await _insertMessage(
        db,
        id: 'assistant_01',
        conversationId: 'conv_stable_order',
        role: 'assistant',
        createdAt: createdAt,
      );
      await _insertMessage(
        db,
        id: 'user_01',
        conversationId: 'conv_stable_order',
        role: 'user',
        createdAt: createdAt,
      );
      await _insertMessage(
        db,
        id: 'assistant_02',
        conversationId: 'conv_stable_order',
        role: 'assistant',
        createdAt: createdAt,
      );

      final messages = await repository
          .getAllByConversationOrderedStable('conv_stable_order');

      expect(
        messages.map((message) => message.id).toList(growable: false),
        <String>['user_02', 'assistant_01', 'user_01', 'assistant_02'],
      );
    });

    test('分页读取在同一时间戳下应按入库顺序前后翻页', () async {
      final createdAt = DateTime(2026, 4, 4, 12, 0, 0);

      await _insertMessage(
        db,
        id: 'user_02',
        conversationId: 'conv_stable_order',
        role: 'user',
        createdAt: createdAt,
      );
      await _insertMessage(
        db,
        id: 'assistant_01',
        conversationId: 'conv_stable_order',
        role: 'assistant',
        createdAt: createdAt,
      );
      await _insertMessage(
        db,
        id: 'user_01',
        conversationId: 'conv_stable_order',
        role: 'user',
        createdAt: createdAt,
      );
      await _insertMessage(
        db,
        id: 'assistant_02',
        conversationId: 'conv_stable_order',
        role: 'assistant',
        createdAt: createdAt,
      );

      final latestPage = await repository.getByConversationStable(
        'conv_stable_order',
        limit: 2,
      );
      expect(
        latestPage.map((message) => message.id).toList(growable: false),
        <String>['assistant_02', 'user_01'],
      );

      final olderPage = await repository.getByConversationStable(
        'conv_stable_order',
        limit: 2,
        beforeTime: createdAt.millisecondsSinceEpoch,
        beforeId: latestPage.last.id,
      );
      expect(
        olderPage.map((message) => message.id).toList(growable: false),
        <String>['assistant_01', 'user_02'],
      );
    });
  });
}
