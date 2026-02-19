import 'message.dart';

class Conversation {
  final String id;
  final String title;
  final String displayName;
  final String? avatarUrl;
  final String? characterImage; // character image / reference image
  final String? chatBackgroundImage; // per-conversation chat background image
  final double? chatBackgroundMaskOpacity; // 0.0 - 1.0, null uses default
  final double? chatBackgroundBlurSigma; // 0.0 - 30.0, null uses default (0)
  final String? blurredBackground; // blurred poster background (base64)
  final String? selfAddress; // assistant self-address
  final String? addressUser; // how assistant addresses user
  final String? voiceFile; // voice id / bound voice asset
  final String? description; // character description for user
  final String personaPrompt; // persona prompt for model
  final List<Message> messages;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? defaultProvider;
  final String? sessionProvider;

  // Conversation-level settings
  final bool isPinned;
  final bool isFavorite;
  final bool isMuted;
  final bool notificationSound;

  // Plugin settings: null means allow all
  final List<String>? enabledPlugins;

  // Message list summary fields
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final int unreadCount;

  const Conversation({
    required this.id,
    required this.title,
    required this.displayName,
    this.avatarUrl,
    this.characterImage,
    this.chatBackgroundImage,
    this.chatBackgroundMaskOpacity,
    this.chatBackgroundBlurSigma,
    this.blurredBackground,
    this.selfAddress,
    this.addressUser,
    this.voiceFile,
    this.description,
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
    this.enabledPlugins,
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
    String? chatBackgroundImage,
    double? chatBackgroundMaskOpacity,
    double? chatBackgroundBlurSigma,
    String? blurredBackground,
    String? selfAddress,
    String? addressUser,
    String? voiceFile,
    String? description,
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
    List<String>? enabledPlugins,
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
      chatBackgroundImage: chatBackgroundImage ?? this.chatBackgroundImage,
      chatBackgroundMaskOpacity:
          chatBackgroundMaskOpacity ?? this.chatBackgroundMaskOpacity,
      chatBackgroundBlurSigma:
          chatBackgroundBlurSigma ?? this.chatBackgroundBlurSigma,
      blurredBackground: blurredBackground ?? this.blurredBackground,
      selfAddress: selfAddress ?? this.selfAddress,
      addressUser: addressUser ?? this.addressUser,
      voiceFile: voiceFile ?? this.voiceFile,
      description: description ?? this.description,
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
      enabledPlugins: enabledPlugins ?? this.enabledPlugins,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}
