import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart' hide SyncScope;
import 'package:aicove_flutter/src/features/backup/data/transfer_safety.dart';
import 'package:aicove_flutter/src/features/backup/models/export_format.dart';
import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart'
    as domain;

/// 角色壁纸的宽窄屏截取存会话表一列（v23），随同步与备份走。
void main() {
  test('v22 database upgrades to v23 with an empty framing column', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customStatement(
      'ALTER TABLE conversations DROP COLUMN chat_background_framing',
    );
    await db.customStatement(
      "INSERT INTO conversations (id, title, display_name, created_at, updated_at) "
      "VALUES ('c1', 't', 'd', 1, 1)",
    );

    await db.migration.onUpgrade(Migrator(db), 22, 23);

    final row = await db
        .customSelect(
          "SELECT chat_background_framing FROM conversations WHERE id='c1'",
        )
        .getSingle();
    expect(row.read<String?>('chat_background_framing'), isNull);
    await db.close();
  });

  test('converter round-trips the framing and the change is synced', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.fromMillisecondsSinceEpoch(1000);
    const framing = '{"wide":{"x":0.5,"y":0.0,"scale":1.5}}';
    await db
        .into(db.conversations)
        .insert(
          ConversationConverter.toCompanion(
            domain.Conversation(
              id: 'c1',
              title: 't',
              displayName: 'd',
              chatBackgroundFraming: framing,
              createdAt: now,
              updatedAt: now,
            ),
          ),
        );
    await db.customStatement('DELETE FROM cloud_dirty');

    await (db.update(db.conversations)..where((t) => t.id.equals('c1'))).write(
      const ConversationsCompanion(chatBackgroundFraming: Value('{}')),
    );

    final stored = await (db.select(
      db.conversations,
    )..where((t) => t.id.equals('c1'))).getSingle();
    expect(ConversationConverter.fromDb(stored).chatBackgroundFraming, '{}');
    final dirty = await db
        .customSelect(
          "SELECT 1 FROM cloud_dirty WHERE kind='conversations' AND entity_id='c1'",
        )
        .get();
    expect(dirty, isNotEmpty);
    await db.close();
  });

  test('backup keeps the framing with character settings', () {
    final filtered = filterTransferConversation(
      {'id': 'c1', 'chat_background_framing': '{}'},
      {SyncScope.characterSettings},
    );
    expect(filtered['chat_background_framing'], '{}');
    expect(
      filterTransferConversation(
        {'id': 'c1', 'chat_background_framing': '{}'},
        {SyncScope.characterCards},
      ),
      isNot(contains('chat_background_framing')),
    );
  });

  group('nextChatBackgroundFraming', () {
    final current = domain.Conversation(
      id: 'c1',
      title: 't',
      displayName: 'd',
      chatBackgroundImage: 'a.png',
      chatBackgroundFraming: '{"narrow":{}}',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

    test('keeps the framing when only mask or blur change', () {
      expect(nextChatBackgroundFraming(current), '{"narrow":{}}');
      expect(
        nextChatBackgroundFraming(current, image: 'a.png'),
        '{"narrow":{}}',
      );
    });

    test('resets it when the image is replaced or cleared', () {
      expect(nextChatBackgroundFraming(current, image: 'b.png'), isNull);
      expect(nextChatBackgroundFraming(current, clearImage: true), isNull);
    });

    test('an explicit framing wins over the reset', () {
      expect(
        nextChatBackgroundFraming(current, image: 'b.png', framing: '{}'),
        '{}',
      );
      expect(nextChatBackgroundFraming(current, clearFraming: true), isNull);
    });
  });
}
