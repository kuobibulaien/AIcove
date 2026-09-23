import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../../core/app_logger.dart';
import '../../../core/database/database.dart' as db;

/// 旧记忆数据退役（ADR0038）：先备份，再迁移手动摘要，最后删除。
///
/// 每次启动检查，幂等。任何一步失败都不删除；下次启动从头再来，
/// 备份目录按时间另建，不覆盖上一次的备份。
class LegacyMemoryRetirement {
  LegacyMemoryRetirement(this.database, {required this.supportDirectory});
  final db.AppDatabase database;
  final Future<Directory> Function() supportDirectory;

  static const legacyTables = [
    'memories',
    'memory_fts',
    'summarization_records',
    'memory_tombstones',
    'diaries',
    'topic_handoffs',
    'compaction_memory_jobs',
    'runtime_context_records',
  ];

  /// 派生索引，不需要备份。
  static const _skipBackup = {'memory_fts'};

  Future<bool> _tableExists(String name) async =>
      (await database
              .customSelect(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
                variables: [Variable(name)],
              )
              .get())
          .isNotEmpty;

  /// 返回是否做了退役（没有旧数据时返回 false）。
  Future<bool> run() async {
    final support = await supportDirectory();
    final notebooks = Directory(p.join(support.path, 'contact_memories'));
    final existing = <String>[
      for (final table in legacyTables)
        if (await _tableExists(table)) table,
    ];
    final hasNotebooks = await notebooks.exists();
    if (existing.isEmpty && !hasNotebooks) return false;

    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final backup = Directory(
      p.join(support.path, 'legacy_memory_backup', stamp),
    );
    await backup.create(recursive: true);

    // 1. 备份：每张旧表导出成 JSON，写完回读校验条数。
    for (final table in existing.where((t) => !_skipBackup.contains(t))) {
      final rows = (await database.customSelect('SELECT * FROM "$table"').get())
          .map((row) => row.data)
          .toList();
      final file = File(p.join(backup.path, '$table.json'));
      await file.writeAsString(
        jsonEncode(rows, toEncodable: _encodable),
        flush: true,
      );
      final check = jsonDecode(await file.readAsString()) as List;
      if (check.length != rows.length) {
        throw StateError('旧记忆备份校验失败：$table');
      }
    }
    if (hasNotebooks) {
      await _copyDirectory(
        notebooks,
        Directory(p.join(backup.path, 'contact_memories')),
      );
    }

    // 2. 迁移手动摘要，保证已有话题边界的衔接不断；3. 删除旧表。
    await database.transaction(() async {
      if (existing.contains('topic_handoffs')) {
        await database.customStatement('''
INSERT OR IGNORE INTO context_summaries
(id, owner_id, kind, boundary_id, topic_boundary, summary, source_ids, source_digest, created_at)
SELECT id, owner_id, 'manual', boundary_id, previous_boundary_id, summary,
       source_ids, source_digest, created_at
FROM topic_handoffs
WHERE memory_state != 'automatic'
  AND owner_id IN (SELECT id FROM conversations)
''');
      }
      for (final table in existing) {
        await database.customStatement('DROP TABLE IF EXISTS "$table"');
      }
    });
    if (hasNotebooks) await notebooks.delete(recursive: true);

    AppLogger.info(
      'LegacyMemoryRetirement',
      '旧记忆数据已备份并退役',
      metadata: {'tables': existing, 'backup': backup.path},
    );
    return true;
  }

  static Object? _encodable(Object? value) =>
      value is List<int> ? base64Encode(value) : value.toString();

  static Future<void> _copyDirectory(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: from.path);
      if (entity is Directory) {
        await Directory(p.join(to.path, relative)).create(recursive: true);
      } else if (entity is File) {
        final target = File(p.join(to.path, relative));
        await target.parent.create(recursive: true);
        await entity.copy(target.path);
        if (await target.length() != await entity.length()) {
          throw StateError('旧记忆文件备份校验失败：$relative');
        }
      }
    }
  }
}
