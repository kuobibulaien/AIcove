import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/sync/cloud_setting_policy.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart'
    as domain;
import 'package:aicove_flutter/src/features/sync/data/cloud_local_store.dart';

/// ADR0070：隐私空间隐藏标记存会话表，随同步走；密码哈希随设置同步。
void main() {
  test('v19 database upgrades to v20 with is_hidden false', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customStatement('ALTER TABLE conversations DROP COLUMN is_hidden');
    await db.customStatement(
      "INSERT INTO conversations (id, title, display_name, created_at, updated_at) "
      "VALUES ('c1', 't', 'd', 1, 1)",
    );

    await db.migration.onUpgrade(Migrator(db), 19, 20);

    final row = await db
        .customSelect("SELECT is_hidden FROM conversations WHERE id='c1'")
        .getSingle();
    expect(row.read<bool>('is_hidden'), isFalse);
    await db.close();
  });

  test(
    'converter round-trips is_hidden and change is captured for sync',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final now = DateTime.fromMillisecondsSinceEpoch(1000);
      final conversation = domain.Conversation(
        id: 'c1',
        title: 't',
        displayName: 'd',
        createdAt: now,
        updatedAt: now,
      );
      await db
          .into(db.conversations)
          .insert(ConversationConverter.toCompanion(conversation));
      await db.customStatement('DELETE FROM cloud_dirty');

      await (db.update(db.conversations)..where((t) => t.id.equals('c1')))
          .write(const ConversationsCompanion(isHidden: Value(true)));

      final stored = await (db.select(
        db.conversations,
      )..where((t) => t.id.equals('c1'))).getSingle();
      expect(ConversationConverter.fromDb(stored).isHidden, isTrue);
      final dirty = await db
          .customSelect(
            "SELECT 1 FROM cloud_dirty WHERE kind='conversations' AND entity_id='c1'",
          )
          .get();
      expect(dirty, isNotEmpty);
      final clock = await db
          .customSelect(
            "SELECT 1 FROM cloud_setting_times WHERE kind='conversations' "
            "AND entity_id='c1' AND field='is_hidden'",
          )
          .get();
      expect(clock, isNotEmpty, reason: '字段级时钟让两台设备的显隐修改按时间合并');
      await db.close();
    },
  );

  test('privacy space password preference is cloud synced', () {
    expect(CloudLocalStore.syncPreference(privacySpacePasswordKey), isTrue);
  });
}
