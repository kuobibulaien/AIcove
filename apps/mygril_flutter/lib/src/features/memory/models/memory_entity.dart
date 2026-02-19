import 'dart:convert';
import 'dart:math';

/// 记忆实体（四层架构）
class MemoryEntity {
  final String id;
  final String content;
  final List<double> embedding;

  // v2 memory fields
  final String layer; // L1/L2/L3/L4
  final String category; // 6分类
  final String? conversationId; // 旧数据可空，新写入必须非空
  final String? contentHash;
  final bool needsEnrichment;

  // legacy scoring fields (kept for backward compatibility)
  final double persistenceP;
  final double emotionE;
  final double infoI;
  final double judgeJ;
  final double infoImportance;
  final double timeCoef;
  final double importance;

  // system maintenance
  final int useCount;
  final DateTime? lastActiveAt;
  final DateTime? deletedAt;
  final DateTime? purgeAt;
  final bool isSynced;
  final String syncState;
  final DateTime createdAt;
  final DateTime updatedAt;

  const MemoryEntity({
    required this.id,
    required this.content,
    this.embedding = const [],
    this.layer = 'L3',
    this.category = 'daily_chatter',
    this.conversationId,
    this.contentHash,
    this.needsEnrichment = false,
    this.persistenceP = 0.5,
    this.emotionE = 0.0,
    this.infoI = 0.5,
    this.judgeJ = 0.5,
    this.infoImportance = 0.5,
    this.timeCoef = 1.0,
    this.importance = 0.5,
    this.useCount = 0,
    this.lastActiveAt,
    this.deletedAt,
    this.purgeAt,
    this.isSynced = false,
    this.syncState = 'local',
    required this.createdAt,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  bool get isCoreMemory => category == 'core_preference' || persistenceP >= 1.0;
  bool get isProfileMemory => layer == 'L1';
  bool get isDeleted => deletedAt != null;

  static double categoryToPersistenceP(String category) {
    switch (category) {
      case 'core_preference':
        return 1.0;
      case 'identity_fact':
        return 0.9;
      case 'emotional_event':
        return 0.7;
      case 'ongoing_plan':
        return 0.5;
      case 'temporary_state':
        return 0.3;
      case 'daily_chatter':
      default:
        return 0.1;
    }
  }

  static double calcTimeCoef({
    required DateTime createdAt,
    required DateTime? lastActiveAt,
    required int useCount,
    required double persistenceP,
  }) {
    if (persistenceP >= 1.0) return 1.0;
    final ref = lastActiveAt ?? createdAt;
    final ageDays = DateTime.now().difference(ref).inDays.toDouble();
    final effectiveAge = ageDays / (1 + log(1 + useCount));
    final coef = 0.8 + 0.2 * exp(-effectiveAge / 30);
    return coef.clamp(0.8, 1.0);
  }

  MemoryEntity recalculateImportance() {
    final info =
        (0.60 * persistenceP + 0.20 * judgeJ + 0.15 * emotionE + 0.05 * infoI)
            .clamp(0.0, 1.0);
    final coef = calcTimeCoef(
      createdAt: createdAt,
      lastActiveAt: lastActiveAt,
      useCount: useCount,
      persistenceP: persistenceP,
    );
    return copyWith(
      infoImportance: info,
      timeCoef: coef,
      importance: info * coef,
      updatedAt: DateTime.now(),
    );
  }

  MemoryEntity markAsHit({bool markNeedsEnrichment = false}) {
    final now = DateTime.now();
    final newUse = useCount + 1;
    final coef = calcTimeCoef(
      createdAt: createdAt,
      lastActiveAt: now,
      useCount: newUse,
      persistenceP: persistenceP,
    );
    return copyWith(
      useCount: newUse,
      lastActiveAt: now,
      timeCoef: coef,
      importance: infoImportance * coef,
      needsEnrichment: markNeedsEnrichment ? true : needsEnrichment,
      updatedAt: now,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'content': content,
      'embedding': embedding.isNotEmpty ? jsonEncode(embedding) : null,
      'layer': layer,
      'category': category,
      'conversation_id': conversationId,
      'content_hash': contentHash,
      'needs_enrichment': needsEnrichment ? 1 : 0,
      'persistence_p': persistenceP,
      'emotion_e': emotionE,
      'info_i': infoI,
      'judge_j': judgeJ,
      'info_importance': infoImportance,
      'time_coef': timeCoef,
      'importance': importance,
      'use_count': useCount,
      'last_active_at': lastActiveAt?.millisecondsSinceEpoch,
      'deleted_at': deletedAt?.millisecondsSinceEpoch,
      'purge_at': purgeAt?.millisecondsSinceEpoch,
      'is_synced': isSynced ? 1 : 0,
      'sync_state': syncState,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory MemoryEntity.fromMap(Map<String, dynamic> map) {
    List<double> embedding = const [];
    final emb = map['embedding'];
    if (emb is String && emb.isNotEmpty) {
      embedding =
          (jsonDecode(emb) as List).map((e) => (e as num).toDouble()).toList();
    }
    final category = (map['category'] as String?) ?? 'daily_chatter';
    final persistence = (map['persistence_p'] as num?)?.toDouble() ??
        categoryToPersistenceP(category);

    return MemoryEntity(
      id: map['id'] as String,
      content: (map['content'] as String?) ?? '',
      embedding: embedding,
      layer: (map['layer'] as String?) ?? 'L3',
      category: category,
      conversationId: map['conversation_id'] as String?,
      contentHash: map['content_hash'] as String?,
      needsEnrichment: map['needs_enrichment'] is bool
          ? (map['needs_enrichment'] as bool)
          : ((map['needs_enrichment'] as int? ?? 0) == 1),
      persistenceP: persistence,
      emotionE: (map['emotion_e'] as num?)?.toDouble() ?? 0.0,
      infoI: (map['info_i'] as num?)?.toDouble() ?? 0.5,
      judgeJ: (map['judge_j'] as num?)?.toDouble() ?? 0.5,
      infoImportance: (map['info_importance'] as num?)?.toDouble() ?? 0.5,
      timeCoef: (map['time_coef'] as num?)?.toDouble() ?? 1.0,
      importance: (map['importance'] as num?)?.toDouble() ?? 0.5,
      useCount: (map['use_count'] as int?) ?? 0,
      lastActiveAt: map['last_active_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['last_active_at'] as int)
          : null,
      deletedAt: map['deleted_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['deleted_at'] as int)
          : null,
      purgeAt: map['purge_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['purge_at'] as int)
          : null,
      isSynced: map['is_synced'] is bool
          ? (map['is_synced'] as bool)
          : ((map['is_synced'] as int?) == 1),
      syncState: (map['sync_state'] as String?) ?? 'local',
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: map['updated_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int)
          : DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
    );
  }

  MemoryEntity copyWith({
    String? id,
    String? content,
    List<double>? embedding,
    String? layer,
    String? category,
    String? conversationId,
    String? contentHash,
    bool? needsEnrichment,
    double? persistenceP,
    double? emotionE,
    double? infoI,
    double? judgeJ,
    double? infoImportance,
    double? timeCoef,
    double? importance,
    int? useCount,
    DateTime? lastActiveAt,
    DateTime? deletedAt,
    DateTime? purgeAt,
    bool? isSynced,
    String? syncState,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return MemoryEntity(
      id: id ?? this.id,
      content: content ?? this.content,
      embedding: embedding ?? this.embedding,
      layer: layer ?? this.layer,
      category: category ?? this.category,
      conversationId: conversationId ?? this.conversationId,
      contentHash: contentHash ?? this.contentHash,
      needsEnrichment: needsEnrichment ?? this.needsEnrichment,
      persistenceP: persistenceP ?? this.persistenceP,
      emotionE: emotionE ?? this.emotionE,
      infoI: infoI ?? this.infoI,
      judgeJ: judgeJ ?? this.judgeJ,
      infoImportance: infoImportance ?? this.infoImportance,
      timeCoef: timeCoef ?? this.timeCoef,
      importance: importance ?? this.importance,
      useCount: useCount ?? this.useCount,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      deletedAt: deletedAt ?? this.deletedAt,
      purgeAt: purgeAt ?? this.purgeAt,
      isSynced: isSynced ?? this.isSynced,
      syncState: syncState ?? this.syncState,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() {
    final short =
        content.length > 30 ? '${content.substring(0, 30)}...' : content;
    return 'MemoryEntity(id: $id, layer: $layer, category: $category, content: $short)';
  }
}
