import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/sync/cloud_tracking.dart';
import 'package:aicove_flutter/src/features/memory/data/legacy_memory_retirement.dart';

// 历史版本的表定义：复现线上旧库，而不是复用被测的新 helper。
const _legacyStatements = [
  '''
CREATE TABLE IF NOT EXISTS topic_handoffs (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  boundary_id TEXT NOT NULL,
  previous_boundary_id TEXT,
  summary TEXT NOT NULL,
  source_ids TEXT NOT NULL,
  source_digest TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  memory_state TEXT NOT NULL
)''',
  '''
CREATE TABLE IF NOT EXISTS memories (
  id TEXT PRIMARY KEY NOT NULL, content TEXT NOT NULL, embedding TEXT,
  layer TEXT NOT NULL DEFAULT 'L3', conversation_id TEXT,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
)''',
  '''
CREATE TABLE IF NOT EXISTS diaries (
  id TEXT PRIMARY KEY NOT NULL, conversation_id TEXT NOT NULL,
  date INTEGER NOT NULL, content TEXT NOT NULL,
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
)''',
  'CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(memory_id, conversation_id, tokenized_content)',
];

/// 历史 v17 应用：只建当时的表。
class _LegacyV17 extends db.AppDatabase {
  _LegacyV17(super.executor) : super.forTesting();
  @override
  int get schemaVersion => 17;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      for (final statement in _legacyStatements) {
        await customStatement(statement);
      }
    },
  );
}

Future<int> _version(db.AppDatabase database) async =>
    (await database.customSelect('PRAGMA user_version').getSingle()).read<int>(
      'user_version',
    );

Future<Set<String>> _tables(db.AppDatabase database) async => (await database
        .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
        .get())
    .map((r) => r.read<String>('name'))
    .toSet();

const _newTables = {
  'context_summaries',
  'memory_items',
  'memory_items_fts',
  'memory_progress',
};

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('context_memory_migration_');
  });
  tearDown(() async => root.delete(recursive: true));

  File dbFile() => File('${root.path}/aicove.sqlite');

  test('全新安装直接建齐新表，没有旧记忆表；关闭再打开仍正常', () async {
    var database = db.AppDatabase.forTesting(NativeDatabase(dbFile()));
    expect(await _version(database), 18);
    expect(await _tables(database), containsAll(_newTables));
    expect(await _tables(database), isNot(contains('memories')));
    await database.close();
    database = db.AppDatabase.forTesting(NativeDatabase(dbFile()));
    expect(await _version(database), 18);
    await database.close();
  });

  test('v17 升级：先建新表；退役先备份、迁移手动摘要、再删旧表，幂等', () async {
    final legacy = _LegacyV17(NativeDatabase(dbFile()));
    await legacy.customStatement(
      "INSERT INTO conversations(id,title,display_name,created_at,updated_at,context_start_message_id) VALUES('a','角色','角色',1,1,'m2')",
    );
    await legacy.customStatement(
      "INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES('m1','a','user','旧消息',1),('m2','a','assistant','回复',2)",
    );
    await legacy.customStatement(
      "INSERT INTO topic_handoffs VALUES('h1','a','m2',NULL,'- 手动摘要','[\"m1\",\"m2\"]','digest',5,'archived'),"
      "('h2','a','m1',NULL,'- 自动摘要','[\"m1\"]','digest',6,'automatic')",
    );
    await legacy.customStatement(
      "INSERT INTO memories(id,content,conversation_id,created_at,updated_at) VALUES('x','旧记忆','a',1,1)",
    );
    await legacy.customStatement(
      "INSERT INTO diaries VALUES('d','a',1,'旧日记',1,1)",
    );
    // 旧版本在退役表上装过同步触发器，也可能留下待同步记录。
    await installCloudTracking(legacy);
    await legacy.customStatement(
      "INSERT INTO cloud_dirty(kind,entity_id,revision) VALUES('memories','x',1),('conversations','a',1)",
    );
    expect(await _version(legacy), 17);
    await legacy.close();

    final notebooks = Directory('${root.path}/contact_memories/abc');
    await notebooks.create(recursive: true);
    await File('${notebooks.path}/MEMORY.md').writeAsString('# 旧 MD');

    final database = db.AppDatabase.forTesting(NativeDatabase(dbFile()));
    expect(await _version(database), 18);
    final tables = await _tables(database);
    expect(tables, containsAll(_newTables));
    // onUpgrade 不直接删旧表，交给退役流程先备份。
    expect(tables, containsAll(['memories', 'topic_handoffs']));
    // 退役类型的待同步记录被清掉，正常类型保留。
    final dirty = await database
        .customSelect('SELECT kind FROM cloud_dirty')
        .get();
    expect(dirty.map((r) => r.read<String>('kind')), ['conversations']);

    final retirement = LegacyMemoryRetirement(
      database,
      supportDirectory: () async => root,
    );
    expect(await retirement.run(), isTrue);
    final after = await _tables(database);
    for (final table in LegacyMemoryRetirement.legacyTables) {
      expect(after, isNot(contains(table)), reason: table);
    }
    expect(await Directory('${root.path}/contact_memories').exists(), isFalse);

    final backups = Directory('${root.path}/legacy_memory_backup').listSync();
    expect(backups, hasLength(1));
    final backup = backups.single.path;
    expect(
      jsonDecode(await File('$backup/memories.json').readAsString()),
      hasLength(1),
    );
    expect(
      jsonDecode(await File('$backup/topic_handoffs.json').readAsString()),
      hasLength(2),
    );
    expect(
      await File('$backup/contact_memories/abc/MEMORY.md').readAsString(),
      '# 旧 MD',
    );

    final summaries = await database
        .customSelect('SELECT id, kind, boundary_id FROM context_summaries')
        .get();
    expect(summaries.map((r) => r.data), [
      {'id': 'h1', 'kind': 'manual', 'boundary_id': 'm2'},
    ]);
    // 原始聊天完整保留。
    expect(
      (await database.customSelect('SELECT id FROM messages').get()).length,
      2,
    );
    expect(await retirement.run(), isFalse);
    await database.close();

    final reopened = db.AppDatabase.forTesting(NativeDatabase(dbFile()));
    expect(await _version(reopened), 18);
    expect(await _tables(reopened), containsAll(_newTables));
    await reopened.close();
  });

  test('备份失败时不删除任何旧数据', () async {
    final legacy = _LegacyV17(NativeDatabase(dbFile()));
    await legacy.customStatement(
      "INSERT INTO conversations(id,title,display_name,created_at,updated_at) VALUES('a','角色','角色',1,1)",
    );
    await legacy.customStatement(
      "INSERT INTO memories(id,content,conversation_id,created_at,updated_at) VALUES('x','旧记忆','a',1,1)",
    );
    await legacy.close();
    final database = db.AppDatabase.forTesting(NativeDatabase(dbFile()));
    // 备份目录被同名文件占住，创建失败。
    await File('${root.path}/legacy_memory_backup').writeAsString('占位');
    await expectLater(
      LegacyMemoryRetirement(
        database,
        supportDirectory: () async => root,
      ).run(),
      throwsA(anything),
    );
    expect(await _tables(database), contains('memories'));
    await database.close();
  });

  test('同步载荷的表结构版本与整库版本解耦', () {
    expect(kCloudRowSchema, 17);
    expect(cloudTables.keys, isNot(contains('topic_handoffs')));
    expect(retiredCloudKinds, containsAll(['memories', 'contact_memory']));
  });
}
