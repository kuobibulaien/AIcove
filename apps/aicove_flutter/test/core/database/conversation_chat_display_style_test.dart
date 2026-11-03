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

  test('v25 database upgrades to v26 with empty per-chat view preferences',
      () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    // SQLite cannot drop a column with a CHECK, so stand in a v25-shaped
    // table without the three columns.
    await db.customStatement('DROP TABLE conversations');
    await db.customStatement(
      'CREATE TABLE conversations (id TEXT PRIMARY KEY, title TEXT)',
    );
    await db.customStatement(
      "INSERT INTO conversations (id, title) VALUES ('c1', 't')",
    );

    await db.migration.onUpgrade(Migrator(db), 25, 26);

    final row = await db
        .customSelect(
          'SELECT image_preview_scale, expand_audio_text, hide_user_avatar, '
          'chunk_enabled, filter_punctuation, chunk_punctuation_set_id '
          "FROM conversations WHERE id='c1'",
        )
        .getSingle();
    expect(row.read<double?>('image_preview_scale'), isNull);
    expect(row.read<int?>('expand_audio_text'), isNull);
    expect(row.read<int?>('hide_user_avatar'), isNull);
    expect(row.read<int?>('chunk_enabled'), isNull);
    expect(row.read<int?>('filter_punctuation'), isNull);
    expect(row.read<String?>('chunk_punctuation_set_id'), isNull);
    await db.customStatement(
      "UPDATE conversations SET hide_user_avatar = 0 WHERE id='c1'",
    );
    await db.close();
  });

  test('converter round-trips per-chat view preferences', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime.fromMillisecondsSinceEpoch(1000);
    await db.into(db.conversations).insert(ConversationConverter.toCompanion(
          domain.Conversation(
            id: 'c1',
            title: 't',
            displayName: 'd',
            createdAt: now,
            updatedAt: now,
            imagePreviewScale: 1.25,
            expandAudioText: false,
            hideUserAvatar: false,
            chunkEnabled: false,
            filterPunctuation: true,
            chunkPunctuationSetId: 'set_a',
          ),
        ));
    final stored = await (db.select(db.conversations)
          ..where((t) => t.id.equals('c1')))
        .getSingle();
    final conv = ConversationConverter.fromDb(stored);
    expect(conv.imagePreviewScale, 1.25);
    expect(conv.expandAudioText, isFalse);
    expect(conv.hideUserAvatar, isFalse);
    expect(conv.chunkEnabled, isFalse);
    expect(conv.filterPunctuation, isTrue);
    expect(conv.chunkPunctuationSetId, 'set_a');
    expect(conv.copyWith(hideUserAvatar: null).hideUserAvatar, isNull);
    await db.close();
  });
}
