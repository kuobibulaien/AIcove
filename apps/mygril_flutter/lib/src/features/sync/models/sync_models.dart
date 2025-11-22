/// 联系人同步模型
class ContactSync {
  final String contactId;
  final String name;
  final String? avatarUrl;
  final Map<String, dynamic>? characterData;
  final DateTime updatedAt;
  final bool isDeleted;

  ContactSync({
    required this.contactId,
    required this.name,
    this.avatarUrl,
    this.characterData,
    required this.updatedAt,
    this.isDeleted = false,
  });

  factory ContactSync.fromJson(Map<String, dynamic> json) {
    return ContactSync(
      contactId: json['contact_id'] as String,
      name: json['name'] as String,
      avatarUrl: json['avatar_url'] as String?,
      characterData: json['character_data'] as Map<String, dynamic>?,
      updatedAt: DateTime.parse(json['updated_at']),
      isDeleted: json['is_deleted'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'contact_id': contactId,
      'name': name,
      'avatar_url': avatarUrl,
      'character_data': characterData,
      'updated_at': updatedAt.toIso8601String(),
      'is_deleted': isDeleted,
    };
  }
}

/// 消息同步模型
class MessageSync {
  final String messageId;
  final String contactId;
  final String role;
  final String content;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final bool isDeleted;

  MessageSync({
    required this.messageId,
    required this.contactId,
    required this.role,
    required this.content,
    this.metadata,
    required this.createdAt,
    this.isDeleted = false,
  });

  factory MessageSync.fromJson(Map<String, dynamic> json) {
    return MessageSync(
      messageId: json['message_id'] as String,
      contactId: json['contact_id'] as String,
      role: json['role'] as String,
      content: json['content'] as String,
      metadata: json['metadata'] as Map<String, dynamic>?,
      createdAt: DateTime.parse(json['created_at']),
      isDeleted: json['is_deleted'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'message_id': messageId,
      'contact_id': contactId,
      'role': role,
      'content': content,
      'metadata': metadata,
      'created_at': createdAt.toIso8601String(),
      'is_deleted': isDeleted,
    };
  }
}

/// 同步状态
class SyncStatus {
  final int contactsCount;
  final DateTime? contactsLastUpdated;
  final int messagesCount;
  final DateTime? messagesLastUpdated;
  final DateTime? settingsLastUpdated;
  final DateTime serverTime;

  SyncStatus({
    required this.contactsCount,
    this.contactsLastUpdated,
    required this.messagesCount,
    this.messagesLastUpdated,
    this.settingsLastUpdated,
    required this.serverTime,
  });

  factory SyncStatus.fromJson(Map<String, dynamic> json) {
    final contacts = json['contacts'] as Map<String, dynamic>;
    final messages = json['messages'] as Map<String, dynamic>;
    final settings = json['settings'] as Map<String, dynamic>;

    return SyncStatus(
      contactsCount: contacts['count'] as int? ?? 0,
      contactsLastUpdated: contacts['last_updated'] != null
          ? DateTime.parse(contacts['last_updated'])
          : null,
      messagesCount: messages['count'] as int? ?? 0,
      messagesLastUpdated: messages['last_updated'] != null
          ? DateTime.parse(messages['last_updated'])
          : null,
      settingsLastUpdated: settings['last_updated'] != null
          ? DateTime.parse(settings['last_updated'])
          : null,
      serverTime: DateTime.parse(json['server_time']),
    );
  }
}
