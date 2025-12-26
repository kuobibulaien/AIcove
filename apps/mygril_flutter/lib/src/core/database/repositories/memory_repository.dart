import 'dart:convert';
import 'dart:math';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../database.dart';
import '../../../features/memory/models/memory_entity.dart';

/// 记忆 Repository（基于 Drift）
///
/// 实现：候选筛选、相似度搜索、命中维护、回收站、超额淘汰、墓碑
class MemoryRepository {
  final AppDatabase _db;

  // 固定参数（来自设计文档）
  static const int localMaxMemories = 800;
  static const int candidateLimit = 300;
  static const int topK = 3;
  static const int trashRetentionDays = 7;

  MemoryRepository(this._db);

  // ==================== 基础 CRUD ====================

  /// 添加记忆
  Future<void> addMemory(MemoryEntity memory) async {
    await _db.into(_db.memories).insertOnConflictUpdate(
          MemoriesCompanion.insert(
            id: memory.id,
            content: memory.content,
            embedding: Value(memory.embedding.isNotEmpty ? jsonEncode(memory.embedding) : null),
            persistenceP: Value(memory.persistenceP),
            emotionE: Value(memory.emotionE),
            infoI: Value(memory.infoI),
            judgeJ: Value(memory.judgeJ),
            infoImportance: Value(memory.infoImportance),
            timeCoef: Value(memory.timeCoef),
            importance: Value(memory.importance),
            useCount: Value(memory.useCount),
            lastActiveAt: Value(memory.lastActiveAt?.millisecondsSinceEpoch),
            deletedAt: Value(memory.deletedAt?.millisecondsSinceEpoch),
            purgeAt: Value(memory.purgeAt?.millisecondsSinceEpoch),
            isSynced: Value(memory.isSynced),
            syncState: Value(memory.syncState),
            createdAt: memory.createdAt.millisecondsSinceEpoch,
            updatedAt: memory.updatedAt.millisecondsSinceEpoch,
          ),
        );

    // 检查是否需要淘汰
    await _evictIfNeeded();
  }

  /// 更新记忆
  Future<void> updateMemory(MemoryEntity memory) async {
    await (_db.update(_db.memories)..where((t) => t.id.equals(memory.id))).write(
      MemoriesCompanion(
        content: Value(memory.content),
        embedding: Value(memory.embedding.isNotEmpty ? jsonEncode(memory.embedding) : null),
        persistenceP: Value(memory.persistenceP),
        emotionE: Value(memory.emotionE),
        infoI: Value(memory.infoI),
        judgeJ: Value(memory.judgeJ),
        infoImportance: Value(memory.infoImportance),
        timeCoef: Value(memory.timeCoef),
        importance: Value(memory.importance),
        useCount: Value(memory.useCount),
        lastActiveAt: Value(memory.lastActiveAt?.millisecondsSinceEpoch),
        deletedAt: Value(memory.deletedAt?.millisecondsSinceEpoch),
        purgeAt: Value(memory.purgeAt?.millisecondsSinceEpoch),
        isSynced: Value(memory.isSynced),
        syncState: Value(memory.syncState),
        updatedAt: Value(memory.updatedAt.millisecondsSinceEpoch),
      ),
    );
  }

  /// 获取单条记忆
  Future<MemoryEntity?> getById(String id) async {
    final row = await (_db.select(_db.memories)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row != null ? _rowToEntity(row) : null;
  }

  // ==================== 召回逻辑 ====================

  /// 获取候选记忆（按 importance 降序，仅有效记忆）
  Future<List<MemoryEntity>> getCandidates({int limit = candidateLimit}) async {
    final rows = await (_db.select(_db.memories)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.importance)])
          ..limit(limit))
        .get();
    return rows.map(_rowToEntity).toList();
  }

  /// 向量搜索：候选筛选 → 相似度排序 → topK
  /// 返回命中的记忆（已更新 use_count 和 last_active_at）
  Future<List<MemoryEntity>> searchTopK(List<double> queryVector, {int k = topK}) async {
    if (queryVector.isEmpty) return [];

    final candidates = await getCandidates();
    if (candidates.isEmpty) return [];

    // 计算相似度并排序
    final scored = candidates
        .where((m) => m.embedding.isNotEmpty)
        .map((m) => MapEntry(m, _cosineSimilarity(queryVector, m.embedding)))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // 取 topK 并更新命中状态
    final topResults = scored.take(k).map((e) => e.key).toList();
    final updatedResults = <MemoryEntity>[];

    for (final mem in topResults) {
      final updated = mem.markAsHit();
      await updateMemory(updated);
      updatedResults.add(updated);
    }

    return updatedResults;
  }

  /// 余弦相似度
  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;

    double dot = 0.0, normA = 0.0, normB = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0.0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  // ==================== 回收站 ====================

  /// 软删除（移入回收站）
  Future<void> softDelete(String id, {String reason = 'user_delete'}) async {
    final now = DateTime.now();
    final purge = now.add(const Duration(days: trashRetentionDays));

    await (_db.update(_db.memories)..where((t) => t.id.equals(id))).write(
      MemoriesCompanion(
        deletedAt: Value(now.millisecondsSinceEpoch),
        purgeAt: Value(purge.millisecondsSinceEpoch),
        updatedAt: Value(now.millisecondsSinceEpoch),
      ),
    );

    // 写入墓碑
    await _writeTombstone(id, reason, now, purge);
  }

  /// 恢复记忆
  Future<void> restore(String id) async {
    await (_db.update(_db.memories)..where((t) => t.id.equals(id))).write(
      MemoriesCompanion(
        deletedAt: const Value(null),
        purgeAt: const Value(null),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// 获取回收站记忆
  Future<List<MemoryEntity>> getTrash() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await (_db.select(_db.memories)
          ..where((t) => t.deletedAt.isNotNull() & t.purgeAt.isBiggerThanValue(now))
          ..orderBy([(t) => OrderingTerm.desc(t.deletedAt)]))
        .get();
    return rows.map(_rowToEntity).toList();
  }

  /// 物理删除过期记忆
  Future<int> purgeExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return (_db.delete(_db.memories)..where((t) => t.purgeAt.isNotNull() & t.purgeAt.isSmallerOrEqualValue(now))).go();
  }

  // ==================== 超额淘汰 ====================

  /// 获取有效记忆数量
  Future<int> getActiveCount() async {
    final count = await (_db.select(_db.memories)..where((t) => t.deletedAt.isNull())).get();
    return count.length;
  }

  /// 超额淘汰：有效记忆 > 800 时，按 importance 从低到高淘汰普通记忆
  Future<void> _evictIfNeeded() async {
    final activeCount = await getActiveCount();
    if (activeCount <= localMaxMemories) return;

    final toEvict = activeCount - localMaxMemories;

    // 获取非核心记忆（P<1），按 importance 升序
    final rows = await (_db.select(_db.memories)
          ..where((t) => t.deletedAt.isNull() & t.persistenceP.isSmallerThanValue(1.0))
          ..orderBy([(t) => OrderingTerm.asc(t.importance)])
          ..limit(toEvict))
        .get();

    for (final row in rows) {
      await softDelete(row.id, reason: 'evicted');
    }
  }

  // ==================== 墓碑 ====================

  Future<void> _writeTombstone(String memoryId, String reason, DateTime deletedAt, DateTime purgeAt) async {
    await _db.into(_db.memoryTombstones).insertOnConflictUpdate(
          MemoryTombstonesCompanion.insert(
            tombstoneId: const Uuid().v4(),
            memoryId: memoryId,
            reason: reason,
            deletedAt: deletedAt.millisecondsSinceEpoch,
            purgeAt: purgeAt.millisecondsSinceEpoch,
          ),
        );
  }

  // ==================== 辅助方法 ====================

  MemoryEntity _rowToEntity(Memory row) {
    List<double> embedding = [];
    if (row.embedding != null && row.embedding!.isNotEmpty) {
      embedding = (jsonDecode(row.embedding!) as List).map((e) => (e as num).toDouble()).toList();
    }

    return MemoryEntity(
      id: row.id,
      content: row.content,
      embedding: embedding,
      persistenceP: row.persistenceP,
      emotionE: row.emotionE,
      infoI: row.infoI,
      judgeJ: row.judgeJ,
      infoImportance: row.infoImportance,
      timeCoef: row.timeCoef,
      importance: row.importance,
      useCount: row.useCount,
      lastActiveAt: row.lastActiveAt != null ? DateTime.fromMillisecondsSinceEpoch(row.lastActiveAt!) : null,
      deletedAt: row.deletedAt != null ? DateTime.fromMillisecondsSinceEpoch(row.deletedAt!) : null,
      purgeAt: row.purgeAt != null ? DateTime.fromMillisecondsSinceEpoch(row.purgeAt!) : null,
      isSynced: row.isSynced,
      syncState: row.syncState,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
    );
  }

  /// 获取所有有效记忆
  Future<List<MemoryEntity>> getAllActive() async {
    final rows = await (_db.select(_db.memories)
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
        .get();
    return rows.map(_rowToEntity).toList();
  }
}
