import 'dart:convert';

/// 日记实体
///
/// 以角色视角记录每天与用户的互动，作为长期记忆存储
/// 每天最多一篇日记，由AI在对话结束时自动生成
class DiaryEntry {
  final String id;
  final String conversationId; // 关联的角色/会话ID
  final DateTime date; // 日记日期（精确到天）
  final String content; // 日记内容（角色视角，第一人称）
  final List<double> embedding; // 向量（用于语义搜索）

  // 元数据
  final String? mood; // 当天心情（可选）
  final List<String>? keywords; // 关键词标签（可选）

  // 系统字段
  final DateTime createdAt;
  final DateTime updatedAt;

  // 同步字段
  final bool isSynced;
  final String syncState; // local/synced/modified

  DiaryEntry({
    required this.id,
    required this.conversationId,
    required this.date,
    required this.content,
    this.embedding = const [],
    this.mood,
    this.keywords,
    required this.createdAt,
    DateTime? updatedAt,
    this.isSynced = false,
    this.syncState = 'local',
  }) : updatedAt = updatedAt ?? createdAt;

  /// 获取日期key（用于按天去重）
  String get dateKey => '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  /// 格式化日期显示
  String get formattedDate {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diaryDate = DateTime(date.year, date.month, date.day);
    final diff = today.difference(diaryDate).inDays;

    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff == 2) return '前天';
    if (diff < 7) return '$diff天前';

    return '${date.year}年${date.month}月${date.day}日';
  }

  /// 转换为数据库 Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'conversation_id': conversationId,
      'date': date.millisecondsSinceEpoch,
      'content': content,
      'embedding': embedding.isNotEmpty ? jsonEncode(embedding) : null,
      'mood': mood,
      'keywords': keywords != null ? jsonEncode(keywords) : null,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
      'is_synced': isSynced ? 1 : 0,
      'sync_state': syncState,
    };
  }

  /// 从数据库 Map 创建
  factory DiaryEntry.fromMap(Map<String, dynamic> map) {
    List<double> embedding = [];
    if (map['embedding'] != null) {
      final decoded = jsonDecode(map['embedding'] as String);
      embedding = (decoded as List).map((e) => (e as num).toDouble()).toList();
    }

    List<String>? keywords;
    if (map['keywords'] != null) {
      final decoded = jsonDecode(map['keywords'] as String);
      keywords = (decoded as List).cast<String>();
    }

    return DiaryEntry(
      id: map['id'] as String,
      conversationId: map['conversation_id'] as String,
      date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int),
      content: map['content'] as String,
      embedding: embedding,
      mood: map['mood'] as String?,
      keywords: keywords,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
      isSynced: (map['is_synced'] as int?) == 1,
      syncState: map['sync_state'] as String? ?? 'local',
    );
  }

  DiaryEntry copyWith({
    String? id,
    String? conversationId,
    DateTime? date,
    String? content,
    List<double>? embedding,
    String? mood,
    List<String>? keywords,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isSynced,
    String? syncState,
  }) {
    return DiaryEntry(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      date: date ?? this.date,
      content: content ?? this.content,
      embedding: embedding ?? this.embedding,
      mood: mood ?? this.mood,
      keywords: keywords ?? this.keywords,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isSynced: isSynced ?? this.isSynced,
      syncState: syncState ?? this.syncState,
    );
  }

  @override
  String toString() => 'DiaryEntry(id: $id, date: $dateKey, content: ${content.length > 50 ? '${content.substring(0, 50)}...' : content})';
}
