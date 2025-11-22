import 'dart:convert';

class MemoryEntity {
  final String id;
  final String content;
  final List<double> embedding;
  final int importance;
  final DateTime createdAt;
  final DateTime? lastAccessedAt;
  final bool isSynced;

  MemoryEntity({
    required this.id,
    required this.content,
    required this.embedding,
    this.importance = 1,
    required this.createdAt,
    this.lastAccessedAt,
    this.isSynced = false,
  });

  // Convert to Map for Database
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'content': content,
      'embedding': jsonEncode(embedding), // Store as JSON string
      'importance': importance,
      'created_at': createdAt.millisecondsSinceEpoch,
      'last_accessed_at': lastAccessedAt?.millisecondsSinceEpoch,
      'is_synced': isSynced ? 1 : 0,
    };
  }

  // Create from Map (Database)
  factory MemoryEntity.fromMap(Map<String, dynamic> map) {
    return MemoryEntity(
      id: map['id'] as String,
      content: map['content'] as String,
      embedding: (jsonDecode(map['embedding'] as String) as List)
          .map((e) => (e as num).toDouble())
          .toList(),
      importance: map['importance'] as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      lastAccessedAt: map['last_accessed_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['last_accessed_at'] as int)
          : null,
      isSynced: (map['is_synced'] as int) == 1,
    );
  }

  MemoryEntity copyWith({
    String? id,
    String? content,
    List<double>? embedding,
    int? importance,
    DateTime? createdAt,
    DateTime? lastAccessedAt,
    bool? isSynced,
  }) {
    return MemoryEntity(
      id: id ?? this.id,
      content: content ?? this.content,
      embedding: embedding ?? this.embedding,
      importance: importance ?? this.importance,
      createdAt: createdAt ?? this.createdAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      isSynced: isSynced ?? this.isSynced,
    );
  }
}
