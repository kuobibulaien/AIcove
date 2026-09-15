import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/api/thinking/thinking_level.dart';
import 'package:aicove_flutter/src/core/database/converters/database_converters.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart'
    as domain;

/// AC8：v14 旧库升级到 v15 后 thinking_levels 为空；实体 ↔ 表往返无损。
void main() {
  test('v14 database upgrades to v15 with empty thinking_levels', () async {
    final executor = NativeDatabase.memory();
    final db = AppDatabase.forTesting(executor);

    // 库首次打开会按 v15 建全表；去掉新列以模拟 v14 旧库。
    await db.customStatement(
      'ALTER TABLE conversations DROP COLUMN thinking_levels',
    );
    await db.customStatement(
      "INSERT INTO conversations (id, title, display_name, created_at, updated_at) "
      "VALUES ('c1', 't', 'd', 1, 1)",
    );

    await db.migration.onUpgrade(Migrator(db), 14, 15);

    final columns = await db
        .customSelect('PRAGMA table_info(conversations)')
        .get()
        .then((rows) => rows.map((r) => r.read<String>('name')).toSet());
    expect(columns, contains('thinking_levels'));

    final row = await db
        .customSelect("SELECT thinking_levels FROM conversations WHERE id='c1'")
        .getSingle();
    expect(row.read<String?>('thinking_levels'), isNull);
    expect(decodeThinkingLevels(row.read<String?>('thinking_levels')), isEmpty);

    await db.close();
  });

  test('converter round-trips per-model thinking levels', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.fromMillisecondsSinceEpoch(1000);
    final conv = domain.Conversation(
      id: 'c2',
      title: 't',
      displayName: 'd',
      createdAt: now,
      updatedAt: now,
      thinkingLevels: const {
        'openai:gpt-5.2': ThinkingLevel.xhigh,
        'claude:claude-opus-5': ThinkingLevel.off,
      },
    );

    await db.into(db.conversations).insert(ConversationConverter.toCompanion(conv));
    final stored = await (db.select(db.conversations)
          ..where((t) => t.id.equals('c2')))
        .getSingle();
    final restored = ConversationConverter.fromDb(stored);

    expect(restored.thinkingLevels, {
      'openai:gpt-5.2': ThinkingLevel.xhigh,
      'claude:claude-opus-5': ThinkingLevel.off,
    });

    final empty = conv.copyWith(thinkingLevels: const {});
    expect(ConversationConverter.toCompanion(empty).thinkingLevels.value, isNull);

    await db.close();
  });

  test('decodeThinkingLevels tolerates garbage', () {
    expect(decodeThinkingLevels('not json'), isEmpty);
    expect(decodeThinkingLevels('[1,2]'), isEmpty);
    expect(decodeThinkingLevels('{"a":"bogus","b":"HIGH"}'),
        {'b': ThinkingLevel.high});
  });
}
