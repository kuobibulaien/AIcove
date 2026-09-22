import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/core/database/database.dart' as db;
import 'package:aicove_flutter/src/core/database/database_provider.dart';
import 'package:aicove_flutter/src/features/memory/data/sqlite_compaction_memory_queue.dart';
import 'package:aicove_flutter/src/features/chat/data/sqlite_topic_handoff_store.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:aicove_flutter/src/features/chat/domain/topic_compaction_port.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_history_store.dart';
import 'package:aicove_flutter/src/features/memory/domain/compaction_memory.dart';

// v16 当时的交接表定义：新建库必须用它复现线上，而不是复用被测的新helper。
const _legacyTopicHandoffs = '''
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
)
''';

const _jobs = '''
CREATE TABLE IF NOT EXISTS compaction_memory_jobs (
 id TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
 source_ids TEXT NOT NULL, source_digest TEXT NOT NULL, updates_json TEXT NOT NULL,
 runtime_record TEXT, state TEXT NOT NULL
)
''';

// 缺 raw_ids/raw_digest 的历史版本。
const _runtimeWithoutDigest = '''
CREATE TABLE IF NOT EXISTS runtime_context_records (
 id TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
 source_json TEXT NOT NULL, replacement_json TEXT NOT NULL, created_at INTEGER NOT NULL
)
''';

const _runtimeComplete = '''
CREATE TABLE IF NOT EXISTS runtime_context_records (
 id TEXT PRIMARY KEY, owner_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
 source_json TEXT NOT NULL, replacement_json TEXT NOT NULL, created_at INTEGER NOT NULL,
 raw_ids TEXT NOT NULL DEFAULT '[]', raw_digest TEXT NOT NULL DEFAULT ''
)
''';

/// 历史 v16 应用：只建当时的表，不共享当前迁移helper。
class _LegacyV16 extends db.AppDatabase {
  _LegacyV16(super.executor, {this.extraStatements = const []})
    : super.forTesting();

  final List<String> extraStatements;

  @override
  int get schemaVersion => 16;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await customStatement(_legacyTopicHandoffs);
      for (final statement in extraStatements) {
        await customStatement(statement);
      }
    },
  );
}

Future<int> _version(db.AppDatabase database) async =>
    (await database
            .customSelect('PRAGMA user_version')
            .getSingle())
        .read<int>('user_version');

Future<List<String>> _tables(db.AppDatabase database) async => (await database
        .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        .get())
    .map((r) => r.read<String>('name'))
    .toList();

Future<Set<String>> _columns(db.AppDatabase database, String table) async =>
    (await database.customSelect('PRAGMA table_info($table)').get())
        .map((r) => r.read<String>('name'))
        .toSet();

Future<List<Map<String, dynamic>>> _rows(
  db.AppDatabase database,
  String table,
) async => (await database
        .customSelect('SELECT rowid, * FROM $table ORDER BY rowid')
        .get())
    .map((r) => r.data)
    .toList();

Future<void> _seedOwner(
  db.AppDatabase database,
  String owner, {
  String? contextStart,
}) async {
  await database
      .into(database.conversations)
      .insert(
        db.ConversationsCompanion.insert(
          id: owner,
          title: '合成角色',
          displayName: '合成角色',
          createdAt: 1,
          updatedAt: 1,
          contextStartMessageId: Value(contextStart),
        ),
      );
  await database
      .into(database.messages)
      .insert(
        db.MessagesCompanion.insert(
          id: 'm1',
          conversationId: owner,
          role: 'user',
          content: '合成第一条',
          createdAt: 1,
        ),
      );
  await database
      .into(database.messages)
      .insert(
        db.MessagesCompanion.insert(
          id: 'm2',
          conversationId: owner,
          role: 'assistant',
          content: '合成第二条',
          createdAt: 2,
        ),
      );
}

({
  ProviderContainer container,
  SqliteTopicHandoffStore store,
  SqliteCompactionMemoryQueue queue,
}) _wire(db.AppDatabase database) {
  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(database)],
  );
  Future<List<Message>> loadRaw(String owner) =>
      container.read(chatHistoryStoreProvider).loadAllRawMessages(owner);
  return (
    container: container,
    store: SqliteTopicHandoffStore(database, loadRaw),
    queue: SqliteCompactionMemoryQueue(database, loadRaw),
  );
}

const _summary = '## 重要背景\n- 升级后自动压缩跨表写入成功';

CompactionMemoryUpdate _update(String sourceId) => CompactionMemoryUpdate(
  key: 'no_cilantro',
  title: '不吃香菜',
  body: '用户不吃香菜',
  kind: 'core',
  sourceIds: [sourceId],
);

void main() {
  test('旧v16库确实缺压缩表，INSERT复现手机上的no such table', () async {
    final directory =
        await Directory.systemTemp.createTemp('aicove-compaction-baseline-');
    addTearDown(() => directory.delete(recursive: true));
    final legacy = _LegacyV16(
      NativeDatabase(File('${directory.path}/legacy.sqlite')),
    );
    try {
      await _seedOwner(legacy, 'a');
      expect(await _version(legacy), 16);
      expect(await _tables(legacy), isNot(contains('compaction_memory_jobs')));
      await expectLater(
        enqueueCompactionMemory(
          legacy,
          id: 'auto_synthetic',
          owner: 'a',
          sourceIds: const ['m1'],
          digest: 'synthetic',
          updates: [_update('m1')],
        ),
        throwsA(
          isA<SqliteException>().having(
            (error) => error.toString(),
            'message',
            contains('no such table: compaction_memory_jobs'),
          ),
        ),
      );
    } finally {
      await legacy.close();
    }
  });

  test('v16只有旧交接表时升到17并补齐压缩表，自动压缩与队列可用', () async {
    final directory = await Directory.systemTemp.createTemp('aicove-compaction-v16-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/legacy.sqlite');

    late List<Map<String, dynamic>> legacyMessages;
    late List<Map<String, dynamic>> legacyHandoffs;
    late String legacyDigest;
    final legacy = _LegacyV16(NativeDatabase(file));
    try {
      expect(await _version(legacy), 16);
      await _seedOwner(legacy, 'a');
      final legacyWire = _wire(legacy);
      final all = await legacyWire.container
          .read(chatHistoryStoreProvider)
          .loadAllRawMessages('a');
      legacyDigest = topicSourceDigest(all.where((m) => m.id == 'm1'));
      await legacy.customStatement(
        'INSERT INTO topic_handoffs (id, owner_id, boundary_id, '
        'previous_boundary_id, summary, source_ids, source_digest, created_at, '
        "memory_state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'archived')",
        [
          'legacy-handoff',
          'a',
          'm1',
          null,
          '旧摘要原文',
          jsonEncode(['m1']),
          legacyDigest,
          1,
        ],
      );
      legacyWire.container.dispose();
      legacyMessages = await _rows(legacy, 'messages');
      legacyHandoffs = await _rows(legacy, 'topic_handoffs');
      expect(legacyDigest, isNotEmpty);
      expect(await _tables(legacy), isNot(contains('compaction_memory_jobs')));
    } finally {
      await legacy.close();
    }

    var database = db.AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect(await _version(database), 17);
      expect(
        await _tables(database),
        containsAll(['topic_handoffs', 'compaction_memory_jobs']),
      );
      expect(
        await _columns(database, 'runtime_context_records'),
        containsAll(['raw_ids', 'raw_digest']),
      );
      expect(await _rows(database, 'messages'), legacyMessages);
      expect(await _rows(database, 'topic_handoffs'), legacyHandoffs);

      final wire = _wire(database);
      addTearDown(wire.container.dispose);
      final snapshot = await wire.store.snapshot('a');
      expect(snapshot.messages.map((m) => m.id), ['m1', 'm2']);
      final saved = await wire.store.saveAutomatic(
        snapshot.withMemoryUpdates([_update('m2')]),
        _summary,
      );
      final pending = await wire.queue.pending('a');
      expect(pending.map((j) => j.id), [saved.id]);
      expect(pending.single.updates.single.body, '用户不吃香菜');
      expect(
        pending.single.updates.single.sourceIds.toSet().difference({'m1', 'm2'}),
        isEmpty,
      );
      expect(await wire.queue.sourcesValid(saved.id), isTrue);
      expect(
        (await database
                .customSelect(
                  'SELECT summary FROM topic_handoffs WHERE id = ?',
                  variables: [Variable(saved.id)],
                )
                .getSingle())
            .read<String>('summary'),
        _summary,
      );
      final handoffs = await _rows(database, 'topic_handoffs');
      expect(handoffs.length, legacyHandoffs.length + 1);
      expect(handoffs.first, legacyHandoffs.first);
      expect(await _rows(database, 'messages'), legacyMessages);
    } finally {
      await database.close();
    }

    database = db.AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect(await _version(database), 17);
      expect(
        await _tables(database),
        containsAll(['topic_handoffs', 'compaction_memory_jobs']),
      );
      final wire = _wire(database);
      addTearDown(wire.container.dispose);
      expect((await wire.queue.pending('a')).length, 1);
      expect(await _rows(database, 'messages'), legacyMessages);
      expect((await _rows(database, 'topic_handoffs')).length, 2);
    } finally {
      await database.close();
    }
  });

  test('v16已有压缩表但runtime缺列时升级补列默认值并保留旧行', () async {
    final directory =
        await Directory.systemTemp.createTemp('aicove-compaction-cols-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/legacy.sqlite');

    late List<Map<String, dynamic>> legacyJobs;
    final legacy = _LegacyV16(
      NativeDatabase(file),
      extraStatements: const [_jobs, _runtimeWithoutDigest],
    );
    try {
      expect(await _version(legacy), 16);
      await _seedOwner(legacy, 'a', contextStart: 'm1');
      await legacy.customStatement(
        'INSERT INTO compaction_memory_jobs (id, owner_id, source_ids, '
        'source_digest, updates_json, runtime_record, state) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['legacy-job', 'a', jsonEncode(['m1']), 'legacy', '[]', 'rt-1', 'pending'],
      );
      await legacy.customStatement(
        'INSERT INTO runtime_context_records (id, owner_id, source_json, '
        'replacement_json, created_at) VALUES (?, ?, ?, ?, ?)',
        ['rt-1', 'a', '{"raw":["m1"]}', '{"replaced":[]}', 7],
      );
      legacyJobs = await _rows(legacy, 'compaction_memory_jobs');
      expect(
        await _columns(legacy, 'runtime_context_records'),
        isNot(contains('raw_ids')),
      );
    } finally {
      await legacy.close();
    }

    final database = db.AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect(await _version(database), 17);
      expect(
        await _columns(database, 'runtime_context_records'),
        containsAll(['raw_ids', 'raw_digest']),
      );
      expect(await _rows(database, 'compaction_memory_jobs'), legacyJobs);
      final runtime = await database
          .customSelect('SELECT * FROM runtime_context_records')
          .getSingle();
      expect(runtime.read<String>('id'), 'rt-1');
      expect(runtime.read<String>('source_json'), '{"raw":["m1"]}');
      expect(runtime.read<String>('replacement_json'), '{"replaced":[]}');
      expect(runtime.read<int>('created_at'), 7);
      expect(runtime.read<String>('raw_ids'), '[]');
      expect(runtime.read<String>('raw_digest'), '');
    } finally {
      await database.close();
    }
  });

  test('v16已完整的压缩表重复升级不丢行', () async {
    final directory =
        await Directory.systemTemp.createTemp('aicove-compaction-again-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/legacy.sqlite');

    late List<Map<String, dynamic>> jobs;
    late List<Map<String, dynamic>> handoffs;
    late List<Map<String, dynamic>> runtime;
    final legacy = _LegacyV16(
      NativeDatabase(file),
      extraStatements: const [_jobs, _runtimeComplete],
    );
    try {
      await _seedOwner(legacy, 'a');
      await legacy.customStatement(
        'INSERT INTO topic_handoffs (id, owner_id, boundary_id, '
        'previous_boundary_id, summary, source_ids, source_digest, created_at, '
        "memory_state) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'archived')",
        ['legacy-handoff', 'a', 'm1', null, '旧摘要原文', '["m1"]', 'd', 1],
      );
      await legacy.customStatement(
        'INSERT INTO compaction_memory_jobs (id, owner_id, source_ids, '
        'source_digest, updates_json, runtime_record, state) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['legacy-job', 'a', '["m1"]', 'd', '[]', null, 'pending'],
      );
      await legacy.customStatement(
        'INSERT INTO runtime_context_records (id, owner_id, source_json, '
        'replacement_json, created_at, raw_ids, raw_digest) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        ['rt-1', 'a', '{}', '{}', 7, '["m1"]', 'd'],
      );
      jobs = await _rows(legacy, 'compaction_memory_jobs');
      handoffs = await _rows(legacy, 'topic_handoffs');
      runtime = await _rows(legacy, 'runtime_context_records');
    } finally {
      await legacy.close();
    }

    for (var round = 0; round < 2; round++) {
      final database = db.AppDatabase.forTesting(NativeDatabase(file));
      try {
        expect(await _version(database), 17);
        expect(await _rows(database, 'compaction_memory_jobs'), jobs);
        expect(await _rows(database, 'topic_handoffs'), handoffs);
        expect(await _rows(database, 'runtime_context_records'), runtime);
      } finally {
        await database.close();
      }
    }
  });

  test('新库直接是17，压缩表、runtime列与队列入口可用', () async {
    final directory =
        await Directory.systemTemp.createTemp('aicove-compaction-new-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/fresh.sqlite');
    final database = db.AppDatabase.forTesting(NativeDatabase(file));
    try {
      expect(
        await _tables(database),
        containsAll(['topic_handoffs', 'compaction_memory_jobs']),
      );
      expect(await _version(database), 17);
      expect(
        await _columns(database, 'runtime_context_records'),
        containsAll(['raw_ids', 'raw_digest']),
      );
      await _seedOwner(database, 'a');
      final wire = _wire(database);
      addTearDown(wire.container.dispose);
      expect(await wire.queue.pending('a'), isEmpty);
      final snapshot = await wire.store.snapshot('a');
      final saved = await wire.store.saveAutomatic(
        snapshot.withMemoryUpdates([_update('m1')]),
        _summary,
      );
      expect((await wire.queue.pending('a')).single.id, saved.id);
    } finally {
      await database.close();
    }
  });
}
