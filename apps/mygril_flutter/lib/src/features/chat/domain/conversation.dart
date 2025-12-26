import 'message.dart';

class Conversation {
  final String id;
  final String title;
  final String displayName;
  final String? avatarUrl;
  final String? characterImage; // 角色立绘/参考图路径
  final String? selfAddress; // 角色的自称（例如：我、本小姐、奴家等）
  final String? addressUser; // 角色对"我"的称呼（例如：老师、先生、主人等）
  final String? voiceFile; // 音色文件路径/数据（用于 TTS）
  final String personaPrompt;
  final List<Message> messages;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? defaultProvider;
  final String? sessionProvider;
  // 聊天设置（每个角色独立）
  final bool isPinned; // 是否置顶
  final bool isFavorite; // 是否收藏（我的角色卡）
  final bool isMuted; // 消息免打扰
  final bool notificationSound; // 消息提示音
  // 消息列表相关字段
  final String? lastMessage; // 最后一条消息内容
  final DateTime? lastMessageTime; // 最后消息时间戳
  final int unreadCount; // 未读消息数量

  const Conversation({
    required this.id,
    required this.title,
    required this.displayName,
    this.avatarUrl,
    this.characterImage,
    this.selfAddress,
    this.addressUser,
    this.voiceFile,
    this.personaPrompt = '',
    this.messages = const [],
    required this.createdAt,
    required this.updatedAt,
    this.defaultProvider,
    this.sessionProvider,
    this.isPinned = false,
    this.isFavorite = false,
    this.isMuted = false,
    this.notificationSound = true,
    this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
  });

  Conversation copyWith({
    String? id,
    String? title,
    String? displayName,
    String? avatarUrl,
    String? characterImage,
    String? selfAddress,
    String? addressUser,
    String? voiceFile,
    String? personaPrompt,
    List<Message>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? defaultProvider,
    String? sessionProvider,
    bool? isPinned,
    bool? isFavorite,
    bool? isMuted,
    bool? notificationSound,
    String? lastMessage,
    DateTime? lastMessageTime,
    int? unreadCount,
  }) {
    return Conversation(
      id: id ?? this.id,
      title: title ?? this.title,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      characterImage: characterImage ?? this.characterImage,
      selfAddress: selfAddress ?? this.selfAddress,
      addressUser: addressUser ?? this.addressUser,
      voiceFile: voiceFile ?? this.voiceFile,
      personaPrompt: personaPrompt ?? this.personaPrompt,
      messages: messages ?? this.messages,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      defaultProvider: defaultProvider ?? this.defaultProvider,
      sessionProvider: sessionProvider ?? this.sessionProvider,
      isPinned: isPinned ?? this.isPinned,
      isFavorite: isFavorite ?? this.isFavorite,
      isMuted: isMuted ?? this.isMuted,
      notificationSound: notificationSound ?? this.notificationSound,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}

