import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/core/database/database.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_repository.dart';
import 'package:aicove_flutter/src/core/database/repositories/message_block_repository.dart';

const _indexNames = [
  'messages_active_conversation_time',
  'message_blocks_active_message_order',
];

// 模拟此前v16打开策略：没有新增的beforeOpen物理索引维护。
class _LegacyV16 extends AppDatabase {
  _LegacyV16(super.executor) : super.forTesting();
  @override
  MigrationStrategy get migration => MigrationStrategy();
}

// 解释 Repository 真正执行的 SQL，而不是复制一份可能漂移的查询。
class _QueryPlans extends QueryInterceptor {
  final raw = <List<String>>[];
  final blocks = <List<String>>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
      QueryExecutor executor, String statement, List<Object?> args) async {
    final rows = await executor.runSelect(statement, args);
    if (statement.startsWith('SELECT')) {
      final target = statement.contains('FROM messages m')
          ? raw
          : statement.contains('FROM "message_blocks"')
              ? blocks
              : null;
      if (target != null) {
        final plan =
            await executor.runSelect('EXPLAIN QUERY PLAN $statement', args);
        target.add(plan.map((r) => r['detail']! as String).toList());
      }
    }
    return rows;
  }
}

class _IndexFailureDatabase extends AppDatabase {
  _IndexFailureDatabase(this.code) : super.forTesting(NativeDatabase.memory());
  final int code;
  int attempts = 0;
  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) {
    if (statement.contains(
        'CREATE INDEX IF NOT EXISTS messages_active_conversation_time')) {
      attempts++;
      throw SqliteException(code, 'synthetic index failure');
    }
    return super.customStatement(statement, args);
  }
}

Future<void> _seed(AppDatabase db) async {
  for (final id in ['owner', 'other']) {
    await db.into(db.conversations).insert(ConversationsCompanion.insert(
        id: id, title: id, displayName: id, createdAt: 1, updatedAt: 1));
  }
  for (var i = 0; i < 8; i++) {
    // id字典序故意与入库顺序相反，时间戳相同不能改成按id排序。
    await db.into(db.messages).insert(MessagesCompanion.insert(
          id: 'm${8 - i}',
          conversationId: i == 7 ? 'other' : 'owner',
          role: 'assistant',
          content: 'synthetic-$i',
          createdAt: 100,
          deletedAt: i == 5 ? const Value(1) : const Value.absent(),
          replacedBy: i == 6 ? const Value('m8') : const Value.absent(),
          rawPayload: const Value('{"synthetic":true}'),
        ));
    for (var j = 2; j >= 0; j--) {
      await db.into(db.messageBlocks).insert(MessageBlocksCompanion.insert(
            id: 'b${i}_$j',
            messageId: 'm${8 - i}',
            type: 'text',
            data: '{"text":"synthetic-$j"}',
            sortOrder: Value(j),
            createdAt: 100,
            deletedAt: j == 1 ? const Value(1) : const Value.absent(),
          ));
    }
  }
}

Future<List<String>> _indexes(AppDatabase db) async => (await db
        .customSelect(
            "SELECT name FROM sqlite_master WHERE type='index' ORDER BY name")
        .get())
    .map((r) => r.read<String>('name'))
    .toList();

Future<void> _assertQueries(AppDatabase db, _QueryPlans plans) async {
  final repo = MessageRepository(db);
  final latest = await repo.getByConversationStable('owner', limit: 2);
  expect(latest.map((m) => m.id), ['m4', 'm5']);
  final older = await repo.getByConversationStable('owner',
      limit: 2, beforeTime: latest.last.createdAt, beforeId: latest.last.id);
  expect(older.map((m) => m.id), ['m6', 'm7']);
  final all = await repo.getAllByConversationOrderedStable('owner');
  expect(all.map((m) => m.id), ['m8', 'm7', 'm6', 'm5', 'm4']);
  final blocks = await MessageBlockRepository(db).getByMessages(['m4', 'm5']);
  expect(blocks.length, 4);
  expect(blocks.map((b) => b.sortOrder), [0, 0, 2, 2]);
  for (final plan in plans.raw) {
    expect(plan.join('\n'), contains('USING INDEX ${_indexNames.first}'));
    expect(plan.join('\n'), isNot(contains('SCAN m')));
    expect(plan.join('\n'), isNot(contains('TEMP B-TREE')),
        reason: '时间和隐含rowid都需同向扫描，不能为同时间戳再次全量排序');
  }
  expect(plans.raw, isNotEmpty);
  expect(plans.blocks.single.join('\n'),
      contains('USING INDEX ${_indexNames.last}'));
  // 多个message_id的块仍允许对选中小集合排序，不能扫描整张块表。
  expect(
      plans.blocks.single.join('\n'), isNot(contains('SCAN message_blocks')));
}

Future<Map<String, Object?>> _snapshot(AppDatabase db) async => {
      'version':
          (await db.customSelect('PRAGMA user_version').getSingle()).data,
      for (final table in [
        'conversations',
        'messages',
        'message_blocks',
        'context_summaries'
      ])
        table: (await db
                .customSelect('SELECT rowid, * FROM $table ORDER BY rowid')
                .get())
            .map((r) => r.data)
            .toList(),
    };

void main() {
  for (final code in [1, 5]) {
    test('索引失败不静默放过：SQLite code=$code，非锁错误不重试、锁重试有界', () async {
      final db = _IndexFailureDatabase(code);
      addTearDown(db.close);
      await expectLater(
          _indexes(db),
          throwsA(isA<SqliteException>()
              .having((e) => e.resultCode, 'code', code)));
      expect(db.attempts, code == 5 ? 7 : 1);
    });
  }
  test('新库真实读取走索引，同时保留rowid顺序、分页、软删除与替换过滤', () async {
    final plans = _QueryPlans();
    final db =
        AppDatabase.forTesting(NativeDatabase.memory().interceptWith(plans));
    addTearDown(db.close);
    await _seed(db);
    expect(await _indexes(db), containsAll(_indexNames));
    await _assertQueries(db, plans);
  });

  test('已有v16文件库补齐索引、重开幂等，旧v16策略仍可打开且数据不变', () async {
    final directory =
        await Directory.systemTemp.createTemp('aicove-entry-index-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/synthetic.sqlite');
    var db = AppDatabase.forTesting(NativeDatabase(file));
    Map<String, Object?> before;
    try {
      await _seed(db);
      // 模拟上线前未加索引的v16；只操作测试生成的库。
      for (final name in _indexNames) {
        await db.customStatement('DROP INDEX IF EXISTS $name');
      }
      before = await _snapshot(db);
      expect((before['version'] as Map)['user_version'], db.schemaVersion);
    } finally {
      await db.close();
    }
    for (var round = 0; round < 3; round++) {
      final plans = _QueryPlans();
      db = round == 2
          ? _LegacyV16(NativeDatabase(file).interceptWith(plans))
          : AppDatabase.forTesting(NativeDatabase(file).interceptWith(plans));
      try {
        expect(await _indexes(db), containsAll(_indexNames));
        expect(await _snapshot(db), before);
        await _assertQueries(db, plans);
      } finally {
        await db.close();
      }
    }
  });

  test('v15升级保留记录并补齐索引，随后旧策略可单独撤销物理索引', () async {
    final directory =
        await Directory.systemTemp.createTemp('aicove-entry-upgrade-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/synthetic.sqlite');
    var database = AppDatabase.forTesting(NativeDatabase(file));
    late Map<String, Object?> before;
    try {
      await _seed(database);
      before = await _snapshot(database);
      for (final name in _indexNames) {
        await database.customStatement('DROP INDEX $name');
      }
      await database.customStatement('DROP TABLE context_summaries');
      await database.customStatement('PRAGMA user_version = 15');
    } finally {
      await database.close();
    }
    database = AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect(await _indexes(database), containsAll(_indexNames));
      expect(await _snapshot(database), before);
    } finally {
      await database.close();
    }
    database = _LegacyV16(NativeDatabase(file));
    try {
      for (final name in _indexNames) {
        await database.customStatement('DROP INDEX $name');
      }
      expect(await _indexes(database), isNot(contains(anyOf(_indexNames))));
      expect(await _snapshot(database), before);
    } finally {
      await database.close();
    }
  });

  test('两个连接同时首次补索引，不因写锁冲突使打开失败', () async {
    final directory =
        await Directory.systemTemp.createTemp('aicove-entry-concurrent-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/synthetic.sqlite');
    final seed = AppDatabase.forTesting(NativeDatabase(file));
    try {
      await _seed(seed);
      for (final name in _indexNames) {
        await seed.customStatement('DROP INDEX $name');
      }
    } finally {
      await seed.close();
    }
    final first = AppDatabase.forTesting(NativeDatabase(file));
    final second = AppDatabase.forTesting(NativeDatabase(file));
    try {
      final results = await Future.wait([_indexes(first), _indexes(second)]);
      for (final names in results) {
        expect(names, containsAll(_indexNames));
      }
    } finally {
      await first.close();
      await second.close();
    }
  });

  test('索引随写入、软删除、恢复与替换同步，不固化旧结果', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await _seed(db);
    final repo = MessageRepository(db);
    await (db.update(db.messages)..where((t) => t.id.equals('m4')))
        .write(const MessagesCompanion(deletedAt: Value(1)));
    expect((await repo.getByConversationStable('owner', limit: 1)).single.id,
        'm5');
    await (db.update(db.messages)..where((t) => t.id.equals('m4')))
        .write(const MessagesCompanion(deletedAt: Value(null)));
    expect((await repo.getByConversationStable('owner', limit: 1)).single.id,
        'm4');
    await (db.update(db.messages)..where((t) => t.id.equals('m4')))
        .write(const MessagesCompanion(replacedBy: Value('m5')));
    expect((await repo.getByConversationStable('owner', limit: 1)).single.id,
        'm5');
  });
}
