import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import '../../../features/memory/models/memory_entity.dart';
import '../../../features/memory/utils/lexical_tokenizer_zh.dart';
import '../database.dart';

class MemoryRepository {
  final AppDatabase _db;

  static const int defaultLocalMaxMemories = 800;
  static const int candidateLimit = 300;
  static const int vectorTopK = 3;
  static const int trashRetentionDays = 7;

  int _localMaxMemories;

  MemoryRepository(
    this._db, {
    int localMaxMemories = defaultLocalMaxMemories,
  }) : _localMaxMemories = localMaxMemories;

  void setLocalMaxMemories(int value) {
    if (value <= 0) return;
    _localMaxMemories = value;
  }

  Future<void> addMemory(
    MemoryEntity memory, {
    bool triggerEviction = true,
  }) async {
    final convId = memory.conversationId?.trim();
    assert(convId != null && convId.isNotEmpty,
        'conversationId is required for new memory writes');
    if (convId == null || convId.isEmpty) {
      throw ArgumentError('conversationId is required for addMemory');
    }

    final now = DateTime.now();
    final normalized = memory
        .copyWith(
          conversationId: convId,
          persistenceP: MemoryEntity.categoryToPersistenceP(memory.category),
          updatedAt: now,
          contentHash: memory.contentHash ?? _sha256(memory.content),
        )
        .recalculateImportance();

    await _db
        .into(_db.memories)
        .insertOnConflictUpdate(_toCompanion(normalized, isInsert: true));
    await _upsertFts(normalized.id, convId, normalized.content);

    if (triggerEviction && normalized.layer != 'L1') {
      await evictIfNeeded(convId);
    }
  }

  Future<void> updateMemory(
    MemoryEntity memory, {
    String? conversationId,
  }) async {
    final existing = await (_db.select(_db.memories)
          ..where((t) => t.id.equals(memory.id)))
        .getSingleOrNull();
    if (existing == null) return;
    _validateConversationId(
      memoryId: memory.id,
      actualConversationId: existing.conversationId,
      expectedConversationId: conversationId,
      nextConversationId: memory.conversationId,
    );
    await (_db.update(_db.memories)..where((t) => t.id.equals(memory.id)))
        .write(_toCompanion(memory));
    if (memory.deletedAt == null &&
        memory.conversationId != null &&
        memory.conversationId!.isNotEmpty) {
      await _upsertFts(memory.id, memory.conversationId!, memory.content);
    } else {
      await _removeFts(memory.id);
    }
  }

  Future<MemoryEntity?> getById(String id) async {
    final row = await (_db.select(_db.memories)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _rowToEntity(row);
  }

  Future<MemoryEntity?> findByContentHash(
      String conversationId, String hash) async {
    final row = await (_db.select(_db.memories)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.contentHash.equals(hash) &
              t.deletedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _rowToEntity(row);
  }

  Future<List<MemoryEntity>> getProfileMemories(String conversationId) async {
    final rows = await (_db.select(_db.memories)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.layer.equals('L1') &
              t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
        .get();
    return rows.map(_rowToEntity).toList();
  }

  Future<void> upsertProfileMemory(MemoryEntity memory) async {
    final entity = memory.copyWith(layer: 'L1', needsEnrichment: false);
    await addMemory(entity, triggerEviction: false);
  }

  Future<int> getProfileCount(String conversationId) async {
    final count = _db.memories.id.count();
    final q = _db.selectOnly(_db.memories)
      ..addColumns([count])
      ..where(_db.memories.conversationId.equals(conversationId) &
          _db.memories.layer.equals('L1') &
          _db.memories.deletedAt.isNull());
    final row = await q.getSingle();
    return row.read(count) ?? 0;
  }

  Future<List<MemoryEntity>> getCandidates({
    required String conversationId,
    int? limit,
  }) async {
    final query = _db.select(_db.memories)
      ..where((t) =>
          t.conversationId.equals(conversationId) &
          t.layer.equals('L1').not() &
          t.deletedAt.isNull());
    if (limit != null && limit > 0) {
      query.limit(limit);
    }
    final rows = await query.get();
    return rows.map(_rowToEntity).toList();
  }

  Future<List<MemoryEntity>> getLayerMemories(
    String conversationId,
    String layer, {
    int limit = 200,
  }) async {
    final rows = await (_db.select(_db.memories)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.layer.equals(layer) &
              t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])
          ..limit(limit))
        .get();
    return rows.map(_rowToEntity).toList();
  }

  Future<List<MemoryEntity>> findPotentialRelatedL2({
    required String conversationId,
    required List<String> entities,
    int limit = 50,
  }) async {
    var query = _db.select(_db.memories)
      ..where((t) =>
          t.conversationId.equals(conversationId) &
          t.layer.equals('L2') &
          t.deletedAt.isNull());

    if (entities.isNotEmpty) {
      Expression<bool>? cond;
      for (final e in entities.where((e) => e.trim().isNotEmpty)) {
        final term = _db.memories.content.like('%$e%');
        cond = cond == null ? term : (cond | term);
      }
      if (cond != null) {
        query = query..where((_) => cond!);
      }
    }

    final rows = await (query..limit(limit)).get();
    return rows.map(_rowToEntity).toList();
  }

  Future<List<MemoryEntity>> getMemoriesNeedingEnrichment({
    required String conversationId,
    int limit = 20,
  }) async {
    final rows = await (_db.select(_db.memories)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.deletedAt.isNull() &
              t.needsEnrichment.equals(true))
          ..orderBy([(t) => OrderingTerm.desc(t.lastActiveAt)])
          ..limit(limit))
        .get();
    return rows.map(_rowToEntity).toList();
  }

  Future<List<MemoryEntity>> searchTopK(
    List<double> queryVector, {
    required String conversationId,
    int k = vectorTopK,
  }) async {
    if (queryVector.isEmpty) return const [];
    final candidates = await getCandidates(conversationId: conversationId);
    if (candidates.isEmpty) return const [];

    final scored = candidates
        .where((m) => m.embedding.isNotEmpty)
        .map((m) => MapEntry(m, _cosineSimilarity(queryVector, m.embedding)))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final results = scored.take(k).map((e) => e.key).toList();
    return _touchHits(results);
  }

  Future<List<MemoryEntity>> searchTopKHybrid(
    List<double> queryVector,
    String queryText, {
    required String conversationId,
    int k = 5,
  }) async {
    final vectorCandidates =
        await getCandidates(conversationId: conversationId);
    if (vectorCandidates.isEmpty) return const [];

    final vectorTop = vectorCandidates
        .where((m) => m.embedding.isNotEmpty && queryVector.isNotEmpty)
        .map((m) => MapEntry(m.id, _cosineSimilarity(queryVector, m.embedding)))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final vectorTop20 = vectorTop.take(20).toList();
    final vectorScores = {for (final e in vectorTop20) e.key: e.value};

    final bm25Scores = await _searchBm25Scores(conversationId, queryText);
    final ids = <String>{...vectorScores.keys, ...bm25Scores.keys};
    if (ids.isEmpty) return const [];

    final byId = await _loadByIds(ids.toList());

    final vectorNorm = _minMaxNormalize(vectorScores);
    final bm25Norm = _minMaxNormalize(bm25Scores);

    final scored = <MapEntry<MemoryEntity, double>>[];
    for (final id in ids) {
      final memory = byId[id];
      if (memory == null || memory.layer == 'L1') continue;
      final score = 0.7 * (vectorNorm[id] ?? 0.0) + 0.3 * (bm25Norm[id] ?? 0.0);
      scored.add(MapEntry(memory, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));

    final top = scored.take(k).map((e) => e.key).toList();
    return _touchHits(top);
  }

  Future<List<MemoryEntity>> searchTopKKeywordOnly(
    String queryText, {
    required String conversationId,
    int k = 5,
  }) async {
    if (queryText.trim().isEmpty) return const [];
    final bm25Scores = await _searchBm25Scores(conversationId, queryText);
    if (bm25Scores.isEmpty) return const [];

    final byId = await _loadByIds(bm25Scores.keys.toList());
    final scored = <MapEntry<MemoryEntity, double>>[];
    for (final entry in bm25Scores.entries) {
      final memory = byId[entry.key];
      if (memory == null || memory.layer == 'L1') continue;
      scored.add(MapEntry(memory, entry.value));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));

    final top = scored.take(k).map((e) => e.key).toList();
    return _touchHits(top);
  }

  Future<List<MemoryEntity>> _touchHits(List<MemoryEntity> hits) async {
    final updated = <MemoryEntity>[];
    for (final m in hits) {
      final markEnrichment = m.layer == 'L4';
      final next = m.markAsHit(markNeedsEnrichment: markEnrichment);
      await updateMemory(next);
      updated.add(next);
    }
    return updated;
  }

  Future<Map<String, double>> _searchBm25Scores(
      String conversationId, String queryText) async {
    final tokenized = LexicalTokenizerZh.tokenizeForFts(queryText);
    final idToRank = <String, double>{};
    if (tokenized.isNotEmpty) {
      final firstPass = await _ftsMatch(conversationId, tokenized);
      final rows = firstPass.isNotEmpty
          ? firstPass
          : await _ftsMatch(conversationId, tokenized.split(' ').join(' OR '));
      for (var i = 0; i < rows.length; i++) {
        final score = rows.length == 1 ? 1.0 : 1.0 - (i / (rows.length - 1));
        idToRank[rows[i]] = score;
      }
    }

    if (idToRank.isEmpty && LexicalTokenizerZh.isSingleHanQuery(queryText)) {
      final rows = await _db.customSelect(
        '''
SELECT id AS memory_id
FROM memories
WHERE conversation_id = ? AND layer != 'L1' AND deleted_at IS NULL AND instr(content, ?) > 0
LIMIT 20
''',
        variables: [
          Variable.withString(conversationId),
          Variable.withString(queryText.trim()),
        ],
      ).get();
      for (var i = 0; i < rows.length; i++) {
        final id = rows[i].read<String>('memory_id');
        final score = rows.length == 1 ? 1.0 : 1.0 - (i / (rows.length - 1));
        idToRank[id] = score;
      }
    }
    return idToRank;
  }

  Future<List<String>> _ftsMatch(
      String conversationId, String matchExpr) async {
    if (matchExpr.trim().isEmpty) return const [];
    final rows = await _db.customSelect(
      '''
SELECT memory_id, bm25(memory_fts) AS bm25_score
FROM memory_fts
WHERE conversation_id = ? AND tokenized_content MATCH ?
ORDER BY bm25_score ASC
LIMIT 20
''',
      variables: [
        Variable.withString(conversationId),
        Variable.withString(matchExpr),
      ],
    ).get();
    return rows.map((r) => r.read<String>('memory_id')).toList();
  }

  Future<Map<String, MemoryEntity>> _loadByIds(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final rows =
        await (_db.select(_db.memories)..where((t) => t.id.isIn(ids))).get();
    return {for (final r in rows) r.id: _rowToEntity(r)};
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length) return 0.0;
    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0.0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  Map<String, double> _minMaxNormalize(Map<String, double> input) {
    if (input.isEmpty) return const {};
    var minV = double.infinity;
    var maxV = double.negativeInfinity;
    for (final v in input.values) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    if ((maxV - minV).abs() < 1e-9) {
      return {for (final k in input.keys) k: 1.0};
    }
    return {
      for (final e in input.entries) e.key: (e.value - minV) / (maxV - minV),
    };
  }

  Future<void> softDelete(
    String id, {
    String reason = 'user_delete',
    String? conversationId,
  }) async {
    final row = await (_db.select(_db.memories)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    _validateConversationId(
      memoryId: id,
      actualConversationId: row.conversationId,
      expectedConversationId: conversationId,
    );
    final now = DateTime.now();
    final purge = now.add(const Duration(days: trashRetentionDays));

    await (_db.update(_db.memories)..where((t) => t.id.equals(id))).write(
      MemoriesCompanion(
        deletedAt: Value(now.millisecondsSinceEpoch),
        purgeAt: Value(purge.millisecondsSinceEpoch),
        updatedAt: Value(now.millisecondsSinceEpoch),
      ),
    );
    await _removeFts(id);
    await _writeTombstone(id, reason, now, purge);
  }

  Future<void> restore(String id, {String? conversationId}) async {
    final row = await (_db.select(_db.memories)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (row == null) return;
    _validateConversationId(
      memoryId: id,
      actualConversationId: row.conversationId,
      expectedConversationId: conversationId,
    );
    await (_db.update(_db.memories)..where((t) => t.id.equals(id))).write(
      MemoriesCompanion(
        deletedAt: const Value(null),
        purgeAt: const Value(null),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    if (row.conversationId != null) {
      await _upsertFts(row.id, row.conversationId!, row.content);
    }
  }

  void _validateConversationId({
    required String memoryId,
    required String? actualConversationId,
    String? expectedConversationId,
    String? nextConversationId,
  }) {
    final normalizedExpected = expectedConversationId?.trim();
    if (normalizedExpected == null || normalizedExpected.isEmpty) return;

    final normalizedActual = actualConversationId?.trim();
    if (normalizedActual != normalizedExpected) {
      throw StateError(
        'Memory $memoryId does not belong to conversation $normalizedExpected',
      );
    }

    final normalizedNext = nextConversationId?.trim();
    if (normalizedNext != null &&
        normalizedNext.isNotEmpty &&
        normalizedNext != normalizedExpected) {
      throw StateError(
        'Memory $memoryId cannot move to conversation $normalizedNext',
      );
    }
  }

  Future<List<MemoryEntity>> getTrash({String? conversationId}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final query = _db.select(_db.memories)
      ..where(
          (t) => t.deletedAt.isNotNull() & t.purgeAt.isBiggerThanValue(now));
    if (conversationId != null && conversationId.isNotEmpty) {
      query.where((t) => t.conversationId.equals(conversationId));
    }
    query.orderBy([(t) => OrderingTerm.desc(t.deletedAt)]);
    final rows = await query.get();
    return rows.map(_rowToEntity).toList();
  }

  Future<int> purgeExpired() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await (_db.select(_db.memories)
          ..where((t) =>
              t.purgeAt.isNotNull() & t.purgeAt.isSmallerOrEqualValue(now)))
        .get();
    for (final row in rows) {
      await _removeFts(row.id);
    }
    return (_db.delete(_db.memories)
          ..where((t) =>
              t.purgeAt.isNotNull() & t.purgeAt.isSmallerOrEqualValue(now)))
        .go();
  }

  Future<int> getActiveCount({String? conversationId}) async {
    final countExp = _db.memories.id.count();
    final query = _db.selectOnly(_db.memories)..addColumns([countExp]);
    if (conversationId != null && conversationId.isNotEmpty) {
      query.where(_db.memories.conversationId.equals(conversationId) &
          _db.memories.deletedAt.isNull());
    } else {
      query.where(_db.memories.deletedAt.isNull());
    }
    final row = await query.getSingle();
    return row.read(countExp) ?? 0;
  }

  Future<List<MemoryEntity>> getEvictionCandidates({
    required String conversationId,
    required int count,
  }) async {
    final rows = await _db.customSelect(
      '''
SELECT *
FROM memories
WHERE conversation_id = ?
  AND deleted_at IS NULL
  AND layer != 'L1'
  AND category != 'core_preference'
ORDER BY
  CASE category
    WHEN 'daily_chatter' THEN 1
    WHEN 'temporary_state' THEN 2
    WHEN 'ongoing_plan' THEN 3
    WHEN 'emotional_event' THEN 4
    WHEN 'identity_fact' THEN 5
    ELSE 99
  END ASC,
  CASE layer WHEN 'L4' THEN 0 ELSE 1 END ASC,
  use_count ASC,
  created_at ASC
LIMIT ?
''',
      variables: [
        Variable.withString(conversationId),
        Variable.withInt(count),
      ],
      readsFrom: {_db.memories},
    ).get();
    return rows.map((r) => MemoryEntity.fromMap(r.data)).toList();
  }

  Future<void> evictIfNeeded(String conversationId) async {
    var active = await getActiveCount(conversationId: conversationId);
    var guard = 0;
    while (active > _localMaxMemories && guard < 5000) {
      guard++;
      final candidates =
          await getEvictionCandidates(conversationId: conversationId, count: 1);
      if (candidates.isEmpty) break;
      final victim = candidates.first;

      if (victim.layer == 'L4') {
        await softDelete(victim.id, reason: 'evicted');
        active--;
        continue;
      }

      final compressed = _compressToL4(victim.content);
      final updated = victim.copyWith(
        layer: 'L4',
        content: compressed,
        contentHash: _sha256(compressed),
        updatedAt: DateTime.now(),
      );
      await updateMemory(updated);
      // compression does not reduce count; next iterations will naturally delete lower-value L4 items.
    }
  }

  String _compressToL4(String content) {
    final lines = LineSplitter.split(content)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    String base = lines.isNotEmpty ? lines.first : content.trim();
    String? eventLine;
    for (final line in lines) {
      if (line.startsWith('事件：')) {
        eventLine = line;
        break;
      }
    }
    if (eventLine != null) {
      base = eventLine.replaceFirst('事件：', '').trim();
    }
    if (base.length > 36) {
      base = '${base.substring(0, 36)}...';
    }
    return base;
  }

  Future<void> _upsertFts(
      String memoryId, String conversationId, String content) async {
    final tokenized = LexicalTokenizerZh.tokenizeForFts(content);
    // memory_fts 是普通 FTS5 表，未对 memory_id 建唯一约束；
    // 先删后插，确保单 memory_id 只有一条索引记录。
    await _db.customStatement(
        'DELETE FROM memory_fts WHERE memory_id = ?', [memoryId]);
    await _db.customStatement(
      '''
INSERT INTO memory_fts(memory_id, conversation_id, tokenized_content)
VALUES(?, ?, ?)
''',
      [
        memoryId,
        conversationId,
        tokenized,
      ],
    );
  }

  Future<void> _removeFts(String memoryId) async {
    await _db.customStatement(
        'DELETE FROM memory_fts WHERE memory_id = ?', [memoryId]);
  }

  Future<void> _writeTombstone(String memoryId, String reason,
      DateTime deletedAt, DateTime purgeAt) async {
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

  MemoriesCompanion _toCompanion(MemoryEntity memory, {bool isInsert = false}) {
    return MemoriesCompanion(
      id: isInsert ? Value(memory.id) : const Value.absent(),
      content: Value(memory.content),
      embedding: Value(
          memory.embedding.isNotEmpty ? jsonEncode(memory.embedding) : null),
      layer: Value(memory.layer),
      category: Value(memory.category),
      conversationId: Value(memory.conversationId),
      contentHash: Value(memory.contentHash),
      needsEnrichment: Value(memory.needsEnrichment),
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
      createdAt: isInsert
          ? Value(memory.createdAt.millisecondsSinceEpoch)
          : const Value.absent(),
      updatedAt: Value(memory.updatedAt.millisecondsSinceEpoch),
    );
  }

  MemoryEntity _rowToEntity(Memory row) {
    List<double> embedding = const [];
    if (row.embedding != null && row.embedding!.isNotEmpty) {
      embedding = (jsonDecode(row.embedding!) as List)
          .map((e) => (e as num).toDouble())
          .toList();
    }
    return MemoryEntity(
      id: row.id,
      content: row.content,
      embedding: embedding,
      layer: row.layer,
      category: row.category,
      conversationId: row.conversationId,
      contentHash: row.contentHash,
      needsEnrichment: row.needsEnrichment,
      persistenceP: row.persistenceP,
      emotionE: row.emotionE,
      infoI: row.infoI,
      judgeJ: row.judgeJ,
      infoImportance: row.infoImportance,
      timeCoef: row.timeCoef,
      importance: row.importance,
      useCount: row.useCount,
      lastActiveAt: row.lastActiveAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.lastActiveAt!),
      deletedAt: row.deletedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.deletedAt!),
      purgeAt: row.purgeAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.purgeAt!),
      isSynced: row.isSynced,
      syncState: row.syncState,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
    );
  }

  String _sha256(String input) => sha256.convert(utf8.encode(input)).toString();

  Future<List<MemoryEntity>> getAllActive(
      {String? conversationId, bool includeProfile = true}) async {
    final query = _db.select(_db.memories)..where((t) => t.deletedAt.isNull());
    if (conversationId != null && conversationId.isNotEmpty) {
      query.where((t) => t.conversationId.equals(conversationId));
    }
    if (!includeProfile) {
      query.where((t) => t.layer.equals('L1').not());
    }
    query.orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    final rows = await query.get();
    return rows.map(_rowToEntity).toList();
  }
}
