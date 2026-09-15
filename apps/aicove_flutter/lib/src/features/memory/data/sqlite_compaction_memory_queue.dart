import 'dart:convert';
import 'package:drift/drift.dart';
import '../../../core/database/database.dart' as db;
import '../../chat/domain/message.dart';
import '../../chat/domain/topic_compaction_port.dart';
import '../domain/compaction_memory.dart';

/// 与摘要在同一SQLite事务写入；文件保存成功后才标记完成。
Future<void> enqueueCompactionMemory(
  db.AppDatabase database, {
  required String id,
  required String owner,
  required List<String> sourceIds,
  required String digest,
  required List<CompactionMemoryUpdate> updates,
  String? runtimeRecord,
}) async {
  if (updates.isEmpty) return;
  await database.customStatement(
    '''
INSERT OR IGNORE INTO compaction_memory_jobs
(id, owner_id, source_ids, source_digest, updates_json, runtime_record, state)
VALUES (?, ?, ?, ?, ?, ?, 'pending')
''',
    [
      id,
      owner,
      jsonEncode(sourceIds),
      digest,
      jsonEncode(updates.map((u) => u.toJson()).toList()),
      runtimeRecord,
    ],
  );
}

class SqliteCompactionMemoryQueue implements CompactionMemoryQueuePort {
  SqliteCompactionMemoryQueue(this.database, this.loadRaw);
  final db.AppDatabase database;
  final Future<List<Message>> Function(String) loadRaw;
  @override
  Future<List<CompactionMemoryJob>> pending(String owner) async {
    final rows = await database
        .customSelect(
          "SELECT * FROM compaction_memory_jobs WHERE owner_id = ? AND state = 'pending' ORDER BY rowid LIMIT 32",
          variables: [Variable(owner)],
        )
        .get();
    return rows
        .map(
          (r) => CompactionMemoryJob(
            r.read<String>('id'),
            owner,
            (jsonDecode(r.read<String>('updates_json')) as List)
                .map(
                  (u) => CompactionMemoryUpdate.fromJson(
                    (u as Map).cast<String, dynamic>(),
                  ),
                )
                .toList(),
          ),
        )
        .toList();
  }

  @override
  Future<bool> sourcesValid(String jobId) async {
    final row = await database
        .customSelect(
          'SELECT * FROM compaction_memory_jobs WHERE id = ?',
          variables: [Variable(jobId)],
        )
        .getSingle();
    if (row.read<String>('state') != 'pending') return false;
    final owner = row.read<String>('owner_id');
    final role = await (database.select(
      database.conversations,
    )..where((t) => t.id.equals(owner))).getSingleOrNull();
    if (role == null || role.deletedAt != null) return false;
    final runtime = row.readNullable<String>('runtime_record');
    if (runtime != null) {
      final source = await database
          .customSelect(
            'SELECT source_json FROM runtime_context_records WHERE id = ? AND owner_id = ?',
            variables: [Variable(runtime), Variable(owner)],
          )
          .getSingleOrNull();
      if (source == null) return false;
    }
    final ids = (jsonDecode(row.read<String>('source_ids')) as List)
        .cast<String>()
        .toSet();
    final sources = (await loadRaw(
      owner,
    )).where((m) => ids.contains(m.id)).toList();
    return sources.length == ids.length &&
        topicSourceDigest(sources) == row.read<String>('source_digest');
  }

  @override
  Future<void> finish(String jobId, {bool discarded = false}) =>
      database.customStatement(
        'UPDATE compaction_memory_jobs SET state = ? WHERE id = ?',
        [discarded ? 'discarded' : 'saved', jobId],
      );
}
