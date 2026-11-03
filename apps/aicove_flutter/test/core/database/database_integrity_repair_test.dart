import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';

const _retiredTables = ['sync_scopes', 'sync_cursors', 'pending_operations'];

class _StatementFailureDatabase extends AppDatabase {
  _StatementFailureDatabase(
    super.executor,
    this.target,
    this.code, {
    this.failures = 1,
    this.message = 'synthetic failure',
  }) : super.forTesting();

  final String target;
  final int code;
  final int failures;
  final String message;
  int attempts = 0;

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) {
    if (statement.contains(target)) {
      attempts++;
      if (attempts <= failures) throw SqliteException(code, message);
    }
    return super.customStatement(statement, args);
  }
}

Future<void> _owner(AppDatabase db, String id) => db
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

Future<List<String>> _tables(AppDatabase db) async =>
    (await db
            .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
            .get())
        .map((r) => r.read<String>('name'))
        .toList();

void main() {
  test('新库不创建三张退役表，Drift schema 也不再暴露它们', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final tables = await _tables(db);
    for (final table in _retiredTables) {
      expect(tables, isNot(contains(table)));
      expect(
        db.allTables.map((t) => t.actualTableName),
        isNot(contains(table)),
      );
    }
    expect(db.schemaVersion, 26);
  });

  test('已有v26每次打开清理三张退役表，锁冲突重试且不改变版本和业务数据', () async {
    final root = await Directory.systemTemp.createTemp('database_repair_');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/db.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    await _owner(db, 'kept');
    for (final table in _retiredTables) {
      await db.customStatement('CREATE TABLE IF NOT EXISTS $table (id TEXT)');
    }
    await db.close();
    for (var round = 0; round < 2; round++) {
      final reopened = _StatementFailureDatabase(
        NativeDatabase(file),
        'DROP TABLE IF EXISTS sync_scopes',
        5,
      );
      db = reopened;
      final tables = await _tables(db);
      for (final table in _retiredTables) {
        expect(tables, isNot(contains(table)));
      }
      expect(reopened.attempts, 2);
      expect((await db.select(db.conversations).get()).single.id, 'kept');
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        26,
      );
      await db.close();
    }
  });

  test('退役表清理的非锁错误不被吞掉', () async {
    final db = _StatementFailureDatabase(
      NativeDatabase.memory(),
      'DROP TABLE IF EXISTS sync_scopes',
      1,
    );
    addTearDown(db.close);
    await expectLater(_tables(db), throwsA(isA<SqliteException>()));
    expect(db.attempts, 1);
  });

  test('退役表清理的SQLITE_LOCKED重试有界', () async {
    final db = _StatementFailureDatabase(
      NativeDatabase.memory(),
      'DROP TABLE IF EXISTS sync_scopes',
      6,
      failures: 100,
    );
    addTearDown(db.close);
    await expectLater(_tables(db), throwsA(isA<SqliteException>()));
    expect(db.attempts, 7);
  });

  test('deleteByConversation删除全量消息及依赖，事务失败时全部回滚', () async {
    final db = AppDatabase.forTesting(
      NativeDatabase.memory(
        setup: (db) {
          db.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
    addTearDown(db.close);
    await _owner(db, 'a');
    await _owner(db, 'b');
    for (final id in ['active', 'deleted', 'replaced', 'other']) {
      await db
          .into(db.messages)
          .insert(
            MessagesCompanion.insert(
              id: id,
              conversationId: id == 'other' ? 'b' : 'a',
              role: 'user',
              content: id,
              createdAt: 1,
              deletedAt: id == 'deleted'
                  ? const Value(2)
                  : const Value.absent(),
              replacedBy: id == 'replaced'
                  ? const Value('active')
                  : const Value.absent(),
            ),
          );
      await db
          .into(db.messageBlocks)
          .insert(
            MessageBlocksCompanion.insert(
              id: 'block-$id',
              messageId: id,
              type: 'mainText',
              data: '{}',
              createdAt: 1,
            ),
          );
      await db
          .into(db.messageProjectionMappings)
          .insert(
            MessageProjectionMappingsCompanion.insert(
              id: 'map-$id',
              conversationId: id == 'other' ? 'b' : 'a',
              rawMessageId: id,
              projectedMessageId: 'projection-$id',
              createdAt: 1,
            ),
          );
    }
    // 会话映射按自己的归属清空，不依赖raw消息刚好属于同一会话。
    await db
        .into(db.messageProjectionMappings)
        .insert(
          MessageProjectionMappingsCompanion.insert(
            id: 'cross-raw-map',
            conversationId: 'a',
            rawMessageId: 'other',
            projectedMessageId: 'cross-raw-projection',
            createdAt: 1,
          ),
        );
    await db.customStatement(
      "CREATE TRIGGER reject_message_delete BEFORE DELETE ON messages "
      "WHEN OLD.id = 'deleted' BEGIN SELECT RAISE(ABORT, 'rollback'); END",
    );
    final repo = MessageRepository(db);
    await expectLater(
      repo.deleteByConversation('a'),
      throwsA(isA<SqliteException>()),
    );
    expect(await db.select(db.messageBlocks).get(), hasLength(4));
    expect(await db.select(db.messageProjectionMappings).get(), hasLength(5));
    await db.customStatement('DROP TRIGGER reject_message_delete');
    expect(await repo.deleteByConversation('a'), 3);
    expect((await db.select(db.messages).get()).single.id, 'other');
    expect((await db.select(db.messageBlocks).get()).single.id, 'block-other');
    expect(
      (await db.select(db.messageProjectionMappings).get()).single.id,
      'map-other',
    );
    expect(await db.customSelect('PRAGMA foreign_key_check').get(), isEmpty);
  });

  for (final code in [1, 5]) {
    test('升级补列不吞非duplicate错误 code=$code', () async {
      final root = await Directory.systemTemp.createTemp('database_upgrade_');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/db.sqlite');
      final old = AppDatabase.forTesting(NativeDatabase(file));
      await _tables(old);
      await old.customStatement('PRAGMA user_version = 25');
      await old.close();
      final db = _StatementFailureDatabase(
        NativeDatabase(file),
        'ALTER TABLE conversations ADD COLUMN image_preview_scale',
        code,
      );
      addTearDown(db.close);
      await expectLater(
        _tables(db),
        throwsA(
          isA<SqliteException>().having((e) => e.resultCode, 'code', code),
        ),
      );
    });
  }

  test('升级补列仅忽略duplicate column，重复迁移保留已有字段', () async {
    final root = await Directory.systemTemp.createTemp('database_duplicate_');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/db.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    await _owner(old, 'kept');
    await old.customStatement('PRAGMA user_version = 25');
    await old.close();
    final db = _StatementFailureDatabase(
      NativeDatabase(file),
      'ALTER TABLE conversations ADD COLUMN image_preview_scale',
      1,
      message: 'DuPlIcAtE CoLuMn: image_preview_scale',
    );
    addTearDown(db.close);
    expect((await db.select(db.conversations).get()).single.id, 'kept');
    expect(db.attempts, 1);
    expect(
      (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
        'user_version',
      ),
      26,
    );
  });

  test('proactive confirmed旧表补列遇锁重试，旧记录视为已确认', () async {
    final root = await Directory.systemTemp.createTemp('proactive_upgrade_');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/db.sqlite');
    final old = AppDatabase.forTesting(NativeDatabase(file));
    await _tables(old);
    await old.customStatement(
      'ALTER TABLE proactive_calls DROP COLUMN confirmed',
    );
    await old.customStatement(
      "INSERT INTO proactive_calls VALUES('t','a','hello',1,2,'ringing',NULL)",
    );
    await old.close();
    final db = _StatementFailureDatabase(
      NativeDatabase(file),
      'ADD COLUMN confirmed INTEGER',
      5,
    );
    addTearDown(db.close);
    expect(
      (await db
              .customSelect('SELECT confirmed FROM proactive_calls')
              .getSingle())
          .read<int>('confirmed'),
      1,
    );
    expect(db.attempts, 2);
  });
}
