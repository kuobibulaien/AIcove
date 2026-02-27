import 'dart:convert';
import 'dart:math' as math;
import 'package:drift/drift.dart';
import '../database.dart';
import '../../../features/diary/models/diary_entry.dart';

/// 日记 Repository（基于 Drift）
///
/// 实现：日记的增删改查、按角色查询、按日期查询
class DiaryRepository {
  final AppDatabase _db;

  DiaryRepository(this._db);

  // ==================== 基础 CRUD ====================

  /// 添加或更新日记
  Future<void> saveDiary(DiaryEntry diary) async {
    await _db.into(_db.diaries).insertOnConflictUpdate(
          DiariesCompanion.insert(
            id: diary.id,
            conversationId: diary.conversationId,
            date: diary.date.millisecondsSinceEpoch,
            content: diary.content,
            embedding: Value(diary.embedding.isNotEmpty ? jsonEncode(diary.embedding) : null),
            mood: Value(diary.mood),
            keywords: Value(diary.keywords != null ? jsonEncode(diary.keywords) : null),
            isSynced: Value(diary.isSynced),
            syncState: Value(diary.syncState),
            createdAt: diary.createdAt.millisecondsSinceEpoch,
            updatedAt: diary.updatedAt.millisecondsSinceEpoch,
          ),
        );
  }

  /// 根据ID获取日记
  Future<DiaryEntry?> getDiaryById(String id) async {
    final row = await (_db.select(_db.diaries)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row != null ? _rowToEntity(row) : null;
  }

  /// 删除日记
  Future<void> deleteDiary(String id) async {
    await (_db.delete(_db.diaries)..where((t) => t.id.equals(id))).go();
  }

  // ==================== 按角色查询 ====================

  /// 获取指定角色的所有日记（按日期倒序）
  Future<List<DiaryEntry>> getDiariesByConversation(String conversationId, {int? limit}) async {
    var query = _db.select(_db.diaries)
      ..where((t) => t.conversationId.equals(conversationId))
      ..orderBy([(t) => OrderingTerm.desc(t.date)]);

    if (limit != null) {
      query = query..limit(limit);
    }

    final rows = await query.get();
    return rows.map(_rowToEntity).toList();
  }

  /// 获取指定角色的日记数量
  Future<int> getDiaryCountByConversation(String conversationId) async {
    final count = _db.diaries.id.count();
    final query = _db.selectOnly(_db.diaries)
      ..addColumns([count])
      ..where(_db.diaries.conversationId.equals(conversationId));
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  // ==================== 按日期查询 ====================

  /// 获取指定角色在某一天的日记
  Future<DiaryEntry?> getDiaryByDate(String conversationId, DateTime date) async {
    // 获取当天的起始和结束时间戳
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));

    final row = await (_db.select(_db.diaries)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.date.isBiggerOrEqualValue(dayStart.millisecondsSinceEpoch) &
              t.date.isSmallerThanValue(dayEnd.millisecondsSinceEpoch)))
        .getSingleOrNull();

    return row != null ? _rowToEntity(row) : null;
  }

  /// 检查指定角色今天是否已有日记
  Future<bool> hasTodayDiary(String conversationId) async {
    final today = DateTime.now();
    final diary = await getDiaryByDate(conversationId, today);
    return diary != null;
  }

  /// 获取指定角色最近N天有日记的日期
  Future<List<DateTime>> getRecentDiaryDates(String conversationId, {int days = 30}) async {
    final cutoff = DateTime.now().subtract(Duration(days: days));

    final rows = await (_db.select(_db.diaries)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.date.isBiggerOrEqualValue(cutoff.millisecondsSinceEpoch))
          ..orderBy([(t) => OrderingTerm.desc(t.date)]))
        .get();

    return rows.map((r) => DateTime.fromMillisecondsSinceEpoch(r.date)).toList();
  }

  // ==================== 语义搜索 ====================

  /// 搜索日记（基于向量相似度）
  /// 返回相似度最高的topK条日记
  Future<List<DiaryEntry>> searchByEmbedding(
    String conversationId,
    List<double> queryEmbedding, {
    int topK = 5,
  }) async {
    // 获取该角色所有有embedding的日记
    final rows = await (_db.select(_db.diaries)
          ..where((t) =>
              t.conversationId.equals(conversationId) &
              t.embedding.isNotNull()))
        .get();

    if (rows.isEmpty) return [];

    // 计算相似度并排序
    final scored = <MapEntry<Diary, double>>[];
    for (final row in rows) {
      if (row.embedding == null) continue;
      final embedding = (jsonDecode(row.embedding!) as List)
          .map((e) => (e as num).toDouble())
          .toList();
      final similarity = _cosineSimilarity(queryEmbedding, embedding);
      scored.add(MapEntry(row, similarity));
    }

    scored.sort((a, b) => b.value.compareTo(a.value));

    return scored.take(topK).map((e) => _rowToEntity(e.key)).toList();
  }

  // ==================== 辅助方法 ====================

  DiaryEntry _rowToEntity(Diary row) {
    List<double> embedding = [];
    if (row.embedding != null) {
      embedding = (jsonDecode(row.embedding!) as List)
          .map((e) => (e as num).toDouble())
          .toList();
    }

    List<String>? keywords;
    if (row.keywords != null) {
      keywords = (jsonDecode(row.keywords!) as List).cast<String>();
    }

    return DiaryEntry(
      id: row.id,
      conversationId: row.conversationId,
      date: DateTime.fromMillisecondsSinceEpoch(row.date),
      content: row.content,
      embedding: embedding,
      mood: row.mood,
      keywords: keywords,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row.updatedAt),
      isSynced: row.isSynced,
      syncState: row.syncState,
    );
  }

  /// 计算余弦相似度
  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;

    double dotProduct = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (int i = 0; i < a.length; i++) {
      dotProduct += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }

    final denominator = math.sqrt(normA) * math.sqrt(normB);
    if (denominator == 0) return 0.0;

    return dotProduct / denominator;
  }
}
