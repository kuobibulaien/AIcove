import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/features/chat/domain/chat_display_policy.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart'
    as domain;

/// ADR0047：v18 旧库升级到 v19 后 chat_display_style 为空（跟随全局）；实体 ↔ 表往返无损。
void main() {
  test('v18 database upgrades to v19 with empty chat_display_style', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customStatement(
      'ALTER TABLE conversations DROP COLUMN chat_display_style',
    );
    await db.customStatement(
      "INSERT INTO conversations (id, title, display_name, created_at, updated_at) "
      "VALUES ('c1', 't', 'd', 1, 1)",
    );

    await db.migration.onUpgrade(Migrator(db), 18, 19);

    final row = await db
        .customSelect(
            "SELECT chat_display_style FROM conversations WHERE id='c1'")
        .getSingle();
    expect(row.read<String?>('chat_display_style'), isNull);
    await db.close();
  });

  test('converter round-trips override and null', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.fromMillisecondsSinceEpoch(1000);
    for (final style in [null, ...ChatDisplayStyle.values]) {
      final id = 'c_${style?.name ?? 'none'}';
      await db.into(db.conversations).insert(ConversationConverter.toCompanion(
            domain.Conversation(
              id: id,
              title: 't',
              displayName: 'd',
              createdAt: now,
              updatedAt: now,
              chatDisplayStyle: style,
            ),
          ));
      final stored = await (db.select(db.conversations)
            ..where((t) => t.id.equals(id)))
          .getSingle();
      expect(ConversationConverter.fromDb(stored).chatDisplayStyle, style);
    }
    await db.close();
  });

  test('copyWith can set and clear the override', () {
    final now = DateTime(2026, 10, 1);
    final base = domain.Conversation(
      id: 'c',
      title: 't',
      displayName: 'd',
      createdAt: now,
      updatedAt: now,
    );
    final doc = base.copyWith(chatDisplayStyle: ChatDisplayStyle.document);
    expect(doc.chatDisplayStyle, ChatDisplayStyle.document);
    expect(doc.copyWith(title: 'x').chatDisplayStyle, ChatDisplayStyle.document);
    expect(doc.copyWith(chatDisplayStyle: null).chatDisplayStyle, isNull);
  });
}
