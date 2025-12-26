import 'dart:convert';
import 'dart:math';

/// 记忆实体
///
/// 字段设计参考：记忆存储与召回方案.md、记忆重要性计算.md
/// - P=1 为核心记忆，不参与自动淘汰，timeCoef 强制为 1
/// - importance = infoImportance * timeCoef
class MemoryEntity {
  final String id;
  final String content; // 记忆文本（对话摘要/事实）
  final List<double> embedding; // 向量

  // AI 打分项（0~1）
  final double persistenceP; // P 持久性（1.0=核心记忆）
  final double emotionE; // E 情绪值（负面权重大）
  final double infoI; // I 信息量
  final double judgeJ; // J 综合判断

  // 计算后的重要性字段
  final double infoImportance; // 信息重要性
  final double timeCoef; // 时间系数 (0.8~1)
  final double importance; // 最终重要性

  // 系统维护字段
  final int useCount; // 被注入topK的次数
  final DateTime? lastActiveAt; // 最后被注入的时间

  // 回收站字段
  final DateTime? deletedAt;
  final DateTime? purgeAt;

  // 同步字段
  final bool isSynced;
  final String syncState; // local/synced/modified

  // 时间戳
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 是否为核心记忆（P=1，不参与自动淘汰）
  bool get isCoreMemory => persistenceP >= 1.0;

  /// 是否在回收站中
  bool get isDeleted => deletedAt != null;

  MemoryEntity({
    required this.id,
    required this.content,
    required this.embedding,
    this.persistenceP = 0.5,
    this.emotionE = 0.0,
    this.infoI = 0.5,
    this.judgeJ = 0.5,
    double? infoImportance,
    double? timeCoef,
    double? importance,
    this.useCount = 0,
    this.lastActiveAt,
    this.deletedAt,
    this.purgeAt,
    this.isSynced = false,
    this.syncState = 'local',
    required this.createdAt,
    DateTime? updatedAt,
  })  : infoImportance = infoImportance ?? _calcInfoImportance(persistenceP, emotionE, infoI, judgeJ),
        timeCoef = timeCoef ?? 1.0,
        importance = importance ?? (infoImportance ?? _calcInfoImportance(persistenceP, emotionE, infoI, judgeJ)) * (timeCoef ?? 1.0),
        updatedAt = updatedAt ?? createdAt;

  /// 计算信息重要性
  /// infoImportance = 0.60*P + 0.20*J + 0.15*E + 0.05*I
  static double _calcInfoImportance(double p, double e, double i, double j) {
    final raw = 0.60 * p + 0.20 * j + 0.15 * e + 0.05 * i;
    return raw.clamp(0.0, 1.0);
  }

  /// 计算时间系数
  /// timeCoef = 0.8 + 0.2 * exp(- effectiveAge / 30)
  /// effectiveAge = ageDays / (1 + ln(1 + useCount))
  /// P=1 强制 timeCoef = 1
  static double calcTimeCoef({
    required DateTime createdAt,
    required DateTime? lastActiveAt,
    required int useCount,
    required double persistenceP,
  }) {
    // 核心记忆不受时间衰减影响
    if (persistenceP >= 1.0) return 1.0;

    final referenceTime = lastActiveAt ?? createdAt;
    final ageDays = DateTime.now().difference(referenceTime).inDays.toDouble();
    final effectiveAge = ageDays / (1 + log(1 + useCount));
    final coef = 0.8 + 0.2 * exp(-effectiveAge / 30);
    return coef.clamp(0.8, 1.0);
  }

  /// 重新计算所有重要性字段
  MemoryEntity recalculateImportance() {
    final newInfoImportance = _calcInfoImportance(persistenceP, emotionE, infoI, judgeJ);
    final newTimeCoef = calcTimeCoef(
      createdAt: createdAt,
      lastActiveAt: lastActiveAt,
      useCount: useCount,
      persistenceP: persistenceP,
    );
    final newImportance = newInfoImportance * newTimeCoef;

    return copyWith(
      infoImportance: newInfoImportance,
      timeCoef: newTimeCoef,
      importance: newImportance,
      updatedAt: DateTime.now(),
    );
  }

  /// 记录被命中（注入topK时调用）
  MemoryEntity markAsHit() {
    final now = DateTime.now();
    final newUseCount = useCount + 1;
    final newTimeCoef = calcTimeCoef(
      createdAt: createdAt,
      lastActiveAt: now,
      useCount: newUseCount,
      persistenceP: persistenceP,
    );

    return copyWith(
      useCount: newUseCount,
      lastActiveAt: now,
      timeCoef: newTimeCoef,
      importance: infoImportance * newTimeCoef,
      updatedAt: now,
    );
  }

  /// 移入回收站
  MemoryEntity moveToTrash() {
    final now = DateTime.now();
    final purge = now.add(const Duration(days: 7));
    return copyWith(
      deletedAt: now,
      purgeAt: purge,
      updatedAt: now,
    );
  }

  /// 从回收站恢复
  MemoryEntity restoreFromTrash() {
    return MemoryEntity(
      id: id,
      content: content,
      embedding: embedding,
      persistenceP: persistenceP,
      emotionE: emotionE,
      infoI: infoI,
      judgeJ: judgeJ,
      infoImportance: infoImportance,
      timeCoef: timeCoef,
      importance: importance,
      useCount: useCount,
      lastActiveAt: lastActiveAt,
      deletedAt: null, // 清除回收站标记
      purgeAt: null,
      isSynced: isSynced,
      syncState: syncState,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
    );
  }

  /// 转换为数据库 Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'content': content,
      'embedding': embedding.isNotEmpty ? jsonEncode(embedding) : null,
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

  /// 从数据库 Map 创建
  factory MemoryEntity.fromMap(Map<String, dynamic> map) {
    List<double> embedding = [];
    if (map['embedding'] != null) {
      final embeddingData = map['embedding'];
      if (embeddingData is String && embeddingData.isNotEmpty) {
        embedding = (jsonDecode(embeddingData) as List)
            .map((e) => (e as num).toDouble())
            .toList();
      }
    }

    return MemoryEntity(
      id: map['id'] as String,
      content: map['content'] as String,
      embedding: embedding,
      persistenceP: (map['persistence_p'] as num?)?.toDouble() ?? 0.5,
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
      isSynced: (map['is_synced'] as int?) == 1,
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
    return 'MemoryEntity(id: $id, content: ${content.length > 30 ? '${content.substring(0, 30)}...' : content}, '
        'P: $persistenceP, importance: ${importance.toStringAsFixed(3)}, useCount: $useCount, '
        'isDeleted: $isDeleted)';
  }
}
