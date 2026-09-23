import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/database.dart' as db;
import '../../../core/utils/token_estimator.dart';
import '../../chat/domain/message.dart';
import '../domain/memory_item.dart';
import '../domain/memory_ports.dart';
import '../utils/lexical_tokenizer_zh.dart';

/// 常驻层总预算（估算 tokens）。超出时新的常驻条目改存档案层。
const kCoreMemoryTokenBudget = 2000;
const kMemoryTitleMaxChars = 120;
const kMemoryContentMaxChars = 4000;

/// `memory_items` + `memory_items_fts` + `memory_progress` 的专用 Adapter。
/// 全文索引由 Dart 分词后写入（中文二元切分），不依赖 SQLite 分词器。
class SqliteMemoryStore implements MemoryStorePort {
  SqliteMemoryStore(this.database, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();
  final db.AppDatabase database;
  final Uuid _uuid;

  @override
  Future<List<MemoryItem>> list(String ownerId, {MemoryLayer? layer}) async {
    final rows = await database
        .customSelect(
          'SELECT * FROM memory_items WHERE owner_id = ?'
          '${layer == null ? '' : ' AND layer = ?'}'
          ' ORDER BY layer, updated_at DESC, id',
          variables: [
            Variable(ownerId),
            if (layer != null) Variable(layer.name),
          ],
        )
        .get();
    return rows.map(_decode).toList();
  }

  @override
  Future<MemoryItem?> get(String ownerId, String id) async {
    final row = await database
        .customSelect(
          'SELECT * FROM memory_items WHERE owner_id = ? AND id = ?',
          variables: [Variable(ownerId), Variable(id)],
        )
        .getSingleOrNull();
    return row == null ? null : _decode(row);
  }

  @override
  Future<MemoryItem> saveByUser({
    required String ownerId,
    String? id,
    required MemoryLayer layer,
    required String title,
    required String content,
  }) async {
    final normalizedTitle = _checkTitle(title);
    final normalizedContent = _checkContent(content);
    return database.transaction(() async {
      final existing = id == null ? null : await get(ownerId, id);
      if (id != null && existing == null) {
        throw const MemoryException('这条记忆已不存在。');
      }
      if (layer == MemoryLayer.core) {
        final others = (await list(ownerId, layer: MemoryLayer.core))
            .where((i) => i.id != id)
            .fold<int>(0, (n, i) => n + _tokens(i));
        if (others + estimateTokenCount('$normalizedTitle\n$normalizedContent') >
            kCoreMemoryTokenBudget) {
          throw const MemoryException('常驻记忆合计超过约 2000 tokens，请精简，或改存到档案。');
        }
      }
      final now = DateTime.now();
      final item = MemoryItem(
        id: existing?.id ?? _uuid.v4(),
        ownerId: ownerId,
        layer: layer,
        title: normalizedTitle,
        content: normalizedContent,
        sourceIds: existing?.sourceIds ?? const [],
        locked: true,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      );
      await _write(item);
      return item;
    });
  }

  @override
  Future<void> setLocked(String ownerId, String id, bool locked) =>
      database.customStatement(
        'UPDATE memory_items SET locked = ? WHERE owner_id = ? AND id = ?',
        [locked ? 1 : 0, ownerId, id],
      );

  @override
  Future<void> deleteByUser(String ownerId, String id) =>
      database.transaction(() => _delete(ownerId, id));

  @override
  Future<int?> applyAgentOps(
    String ownerId,
    List<MemoryOp> ops, {
    required Message processedUntil,
    required int generation,
  }) => database.transaction(() async {
    if ((await progress(ownerId)).generation != generation) return null;
    final now = DateTime.now();
    var applied = 0;
    final current = {for (final item in await list(ownerId)) item.id: item};
    var coreTokens = current.values
        .where((i) => i.layer == MemoryLayer.core)
        .fold<int>(0, (n, i) => n + _tokens(i));
    for (final op in ops) {
      switch (op) {
        case AddMemory():
          final title = _valid(op.title, kMemoryTitleMaxChars, line: true);
          final content = _valid(op.content, kMemoryContentMaxChars);
          if (title == null || content == null) continue;
          final duplicate = current.values.any(
            (i) => _normalize(i.content) == _normalize(content),
          );
          if (duplicate) continue;
          var layer = op.layer;
          final size = estimateTokenCount('$title\n$content');
          if (layer == MemoryLayer.core &&
              coreTokens + size > kCoreMemoryTokenBudget) {
            layer = MemoryLayer.archive;
          }
          if (layer == MemoryLayer.core) coreTokens += size;
          final item = MemoryItem(
            id: _uuid.v4(),
            ownerId: ownerId,
            layer: layer,
            title: title,
            content: content,
            sourceIds: op.sourceIds,
            locked: false,
            createdAt: now,
            updatedAt: now,
          );
          await _write(item);
          current[item.id] = item;
          applied++;
        case UpdateMemory():
          final old = current[op.id];
          if (old == null || old.locked) continue;
          final title = op.title == null
              ? old.title
              : _valid(op.title!, kMemoryTitleMaxChars, line: true);
          final content = op.content == null
              ? old.content
              : _valid(op.content!, kMemoryContentMaxChars);
          if (title == null || content == null) continue;
          var layer = op.layer ?? old.layer;
          final oldCore = old.layer == MemoryLayer.core ? _tokens(old) : 0;
          final size = estimateTokenCount('$title\n$content');
          if (layer == MemoryLayer.core &&
              coreTokens - oldCore + size > kCoreMemoryTokenBudget) {
            layer = MemoryLayer.archive;
          }
          coreTokens += (layer == MemoryLayer.core ? size : 0) - oldCore;
          final next = old.copyWith(
            layer: layer,
            title: title,
            content: content,
            sourceIds: {...old.sourceIds, ...op.sourceIds}.toList(),
            updatedAt: now,
          );
          await _write(next);
          current[next.id] = next;
          applied++;
        case DeleteMemory():
          final old = current.remove(op.id);
          if (old == null) continue;
          if (old.locked) {
            current[old.id] = old;
            continue;
          }
          if (old.layer == MemoryLayer.core) coreTokens -= _tokens(old);
          await _delete(ownerId, old.id);
          applied++;
      }
    }
    await database.customStatement(
      '''
INSERT INTO memory_progress(owner_id, until_at, until_id, last_error, updated_at)
VALUES (?, ?, ?, NULL, ?)
ON CONFLICT(owner_id) DO UPDATE SET
  until_at = excluded.until_at, until_id = excluded.until_id,
  last_error = NULL, updated_at = excluded.updated_at
''',
      [
        ownerId,
        processedUntil.createdAt.millisecondsSinceEpoch,
        processedUntil.id,
        now.millisecondsSinceEpoch,
      ],
    );
    return applied;
  });

  @override
  Future<MemoryProgress> progress(String ownerId) async {
    final row = await database
        .customSelect(
          'SELECT * FROM memory_progress WHERE owner_id = ?',
          variables: [Variable(ownerId)],
        )
        .getSingleOrNull();
    if (row == null) return MemoryProgress(ownerId: ownerId);
    return MemoryProgress(
      ownerId: ownerId,
      untilAt: row.readNullable<int>('until_at'),
      untilId: row.readNullable<String>('until_id'),
      rebuildUntilId: row.readNullable<String>('rebuild_until_id'),
      generation: row.read<int>('generation'),
      paused: row.read<int>('paused') == 1,
      lastError: row.readNullable<String>('last_error'),
    );
  }

  @override
  Future<void> setPaused(String ownerId, bool paused) =>
      database.customStatement(
        '''
INSERT INTO memory_progress(owner_id, paused, updated_at) VALUES (?, ?, ?)
ON CONFLICT(owner_id) DO UPDATE SET paused = excluded.paused,
  updated_at = excluded.updated_at
''',
        [ownerId, paused ? 1 : 0, DateTime.now().millisecondsSinceEpoch],
      );

  @override
  Future<void> recordError(String ownerId, String? error) =>
      database.customStatement(
        '''
INSERT INTO memory_progress(owner_id, last_error, updated_at) VALUES (?, ?, ?)
ON CONFLICT(owner_id) DO UPDATE SET last_error = excluded.last_error,
  updated_at = excluded.updated_at
''',
        [ownerId, error, DateTime.now().millisecondsSinceEpoch],
      );

  @override
  Future<void> resetForRebuild(String ownerId, Message until) =>
      database.transaction(() async {
        await _deleteUnlocked(ownerId);
        await database.customStatement(
          '''
INSERT INTO memory_progress(owner_id, until_at, until_id, rebuild_until_id, generation, paused, last_error, updated_at)
VALUES (?, NULL, NULL, ?, 1, 0, NULL, ?)
ON CONFLICT(owner_id) DO UPDATE SET until_at = NULL, until_id = NULL,
  rebuild_until_id = excluded.rebuild_until_id,
  generation = memory_progress.generation + 1,
  paused = 0, last_error = NULL, updated_at = excluded.updated_at
''',
          [ownerId, until.id, DateTime.now().millisecondsSinceEpoch],
        );
      });

  @override
  Future<void> clearRebuildTarget(String ownerId, int generation) =>
      database.customStatement(
        'UPDATE memory_progress SET rebuild_until_id = NULL '
        'WHERE owner_id = ? AND generation = ?',
        [ownerId, generation],
      );

  @override
  Future<void> clearDerived(String ownerId) => database.transaction(() async {
    await _deleteUnlocked(ownerId);
    await database.customStatement(
      'DELETE FROM memory_progress WHERE owner_id = ?',
      [ownerId],
    );
  });

  @override
  Future<List<MemoryItem>> searchKeyword(
    String ownerId,
    String query, {
    int limit = 8,
  }) async {
    final tokens = LexicalTokenizerZh.tokenizeForFts(query)
        .split(' ')
        .where((t) => t.isNotEmpty)
        .toSet();
    if (tokens.isEmpty || limit <= 0) return const [];
    // 每个词加引号，避免用户文字被当成 FTS 语法；OR 让长查询也能命中。
    final match = tokens
        .take(64)
        .map((t) => '"${t.replaceAll('"', '""')}"')
        .join(' OR ');
    final rows = await database
        .customSelect(
          '''
SELECT m.*, bm25(memory_items_fts) AS score
FROM memory_items_fts f JOIN memory_items m ON m.id = f.item_id
WHERE f.owner_id = ? AND memory_items_fts MATCH ?
ORDER BY score ASC, m.updated_at DESC
LIMIT ?
''',
          variables: [Variable(ownerId), Variable(match), Variable(limit)],
        )
        .get();
    return rows.map(_decode).toList();
  }

  Future<void> _write(MemoryItem item) async {
    await database.customStatement(
      '''
INSERT INTO memory_items(id, owner_id, layer, title, content, source_ids, locked, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET layer = excluded.layer, title = excluded.title,
  content = excluded.content, source_ids = excluded.source_ids,
  locked = excluded.locked, updated_at = excluded.updated_at
''',
      [
        item.id,
        item.ownerId,
        item.layer.name,
        item.title,
        item.content,
        jsonEncode(item.sourceIds),
        item.locked ? 1 : 0,
        item.createdAt.millisecondsSinceEpoch,
        item.updatedAt.millisecondsSinceEpoch,
      ],
    );
    await database.customStatement(
      'DELETE FROM memory_items_fts WHERE item_id = ?',
      [item.id],
    );
    await database.customStatement(
      'INSERT INTO memory_items_fts(item_id, owner_id, tokens) VALUES (?, ?, ?)',
      [
        item.id,
        item.ownerId,
        LexicalTokenizerZh.tokenizeForFts('${item.title}\n${item.content}'),
      ],
    );
  }

  Future<void> _delete(String ownerId, String id) async {
    await database.customStatement(
      'DELETE FROM memory_items WHERE owner_id = ? AND id = ?',
      [ownerId, id],
    );
    await database.customStatement(
      'DELETE FROM memory_items_fts WHERE item_id = ? AND owner_id = ?',
      [id, ownerId],
    );
  }

  Future<void> _deleteUnlocked(String ownerId) async {
    await database.customStatement(
      'DELETE FROM memory_items_fts WHERE item_id IN '
      '(SELECT id FROM memory_items WHERE owner_id = ? AND locked = 0)',
      [ownerId],
    );
    await database.customStatement(
      'DELETE FROM memory_items WHERE owner_id = ? AND locked = 0',
      [ownerId],
    );
  }

  static int _tokens(MemoryItem item) =>
      estimateTokenCount('${item.title}\n${item.content}');

  static String _normalize(String text) =>
      text.replaceAll(RegExp(r'\s+'), '').toLowerCase();

  /// 模型给的内容不合规时跳过这一条，不让整批失败。
  static String? _valid(String text, int max, {bool line = false}) {
    final value = text.trim();
    if (value.isEmpty || value.length > max) return null;
    return line && value.contains('\n') ? null : value;
  }

  static String _checkTitle(String title) {
    final value = title.trim();
    if (value.isEmpty ||
        value.length > kMemoryTitleMaxChars ||
        value.contains('\n')) {
      throw const MemoryException('记忆标题须为 1–120 字的单行文字。');
    }
    return value;
  }

  static String _checkContent(String content) {
    final value = content.trim();
    if (value.isEmpty || value.length > kMemoryContentMaxChars) {
      throw const MemoryException('记忆内容须为 1–4000 字。');
    }
    return value;
  }

  MemoryItem _decode(QueryRow row) => MemoryItem(
    id: row.read<String>('id'),
    ownerId: row.read<String>('owner_id'),
    layer: MemoryLayer.parse(row.read<String>('layer')),
    title: row.read<String>('title'),
    content: row.read<String>('content'),
    sourceIds: (jsonDecode(row.read<String>('source_ids')) as List)
        .cast<String>(),
    locked: row.read<int>('locked') == 1,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('created_at')),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('updated_at')),
  );
}
