import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/memory/data/sqlite_memory_store.dart';
import 'package:aicove_flutter/src/features/memory/domain/memory_item.dart';

Message _message(String id) => Message(
  id: id,
  role: 'user',
  content: id,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1),
  status: 'sent',
);

void main() {
  late db.AppDatabase database;
  late SqliteMemoryStore store;
  setUp(() async {
    database = db.AppDatabase.forTesting(
      NativeDatabase.memory(
        setup: (db) {
          db.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
    await database.customStatement(
      "INSERT INTO conversations(id,title,display_name,created_at,updated_at) VALUES('a','a','a',1,1)",
    );
    store = SqliteMemoryStore(database);
  });
  tearDown(() => database.close());

  test('直接删记忆或级联删角色都清理FTS，包括旧v26库重开', () async {
    final root = await Directory.systemTemp.createTemp('memory_fts_repair_');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/db.sqlite');
    await database.close();
    database = db.AppDatabase.forTesting(
      NativeDatabase(
        file,
        setup: (db) {
          db.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
    await database.customStatement(
      "INSERT INTO conversations(id,title,display_name,created_at,updated_at) VALUES('a','a','a',1,1)",
    );
    // 模拟没有清理触发器的旧v26。
    final triggers = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='memory_items'",
        )
        .get();
    for (final trigger in triggers) {
      await database.customStatement(
        'DROP TRIGGER "${trigger.read<String>('name')}"',
      );
    }
    await database.close();
    database = db.AppDatabase.forTesting(
      NativeDatabase(
        file,
        setup: (db) {
          db.execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
    store = SqliteMemoryStore(database);
    for (final title in ['direct', 'cascade']) {
      await store.saveByUser(
        ownerId: 'a',
        layer: MemoryLayer.archive,
        title: title,
        content: title,
      );
    }
    await database.customStatement(
      "DELETE FROM memory_items WHERE title = 'direct'",
    );
    expect(
      await database.customSelect('SELECT * FROM memory_items_fts').get(),
      hasLength(1),
    );
    await database.customStatement("DELETE FROM conversations WHERE id = 'a'");
    expect(
      await database.customSelect('SELECT * FROM memory_items_fts').get(),
      isEmpty,
    );
  });

  test('清理保留锁定记忆并递增代次，旧agent结果不能写回', () async {
    await store.applyAgentOps(
      'a',
      [
        const AddMemory(
          layer: MemoryLayer.archive,
          title: '自动',
          content: '自动记忆',
          sourceIds: ['m'],
        ),
      ],
      processedUntil: _message('m'),
      generation: 0,
    );
    await store.saveByUser(
      ownerId: 'a',
      layer: MemoryLayer.archive,
      title: '手写',
      content: '保留',
    );
    await store.clearDerived('a');
    expect((await store.list('a')).single.title, '手写');
    expect((await store.progress('a')).generation, 1);
    expect((await store.progress('a')).untilId, isNull);
    expect(
      await store.applyAgentOps(
        'a',
        [
          const AddMemory(
            layer: MemoryLayer.archive,
            title: '过期',
            content: '过期结果',
            sourceIds: ['m'],
          ),
        ],
        processedUntil: _message('m'),
        generation: 0,
      ),
      isNull,
    );
    await store.clearDerived('a');
    expect((await store.progress('a')).generation, 2);
    expect(
      await database.customSelect('SELECT * FROM memory_progress').get(),
      hasLength(1),
    );
  });

  test('尚无进度时清理也创建代次1，挡住默认代次0结果', () async {
    await store.clearDerived('a');
    expect((await store.progress('a')).generation, 1);
    expect(
      await store.applyAgentOps(
        'a',
        const [],
        processedUntil: _message('m'),
        generation: 0,
      ),
      isNull,
    );
  });
}
