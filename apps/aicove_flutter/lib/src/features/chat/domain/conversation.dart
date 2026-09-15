import '../../../core/api/thinking/thinking_level.dart';
import 'message.dart';

/// Sentinel value used by [Conversation.copyWith] to distinguish
/// "parameter not provided" from "explicitly set to null".
const Object _sentinel = Object();

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

  // SillyTavern preset recipe ID
  final String? recipeId;

  // 会话级思考档位覆盖，按 modelRef 分别记录；空表示未设置
  final Map<String, ThinkingLevel> thinkingLevels;

  // 上下文截断：新话题起始消息ID，此ID之后的消息才纳入AI上下文
  final String? contextStartMessageId;

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
    this.recipeId,
    this.thinkingLevels = const {},
    this.contextStartMessageId,
    this.lastMessage,
    this.lastMessageTime,
    this.unreadCount = 0,
  });

  bool allowsPlugin(String pluginId) {
    final normalizedPluginId = pluginId.trim();
    if (normalizedPluginId.isEmpty) {
      return true;
    }
    final allowedPlugins = enabledPlugins;
    return allowedPlugins == null ||
        allowedPlugins.contains(normalizedPluginId);
  }

  bool blocksPlugin(String pluginId) => !allowsPlugin(pluginId);

  /// Fields that are inherently nullable and may need to be explicitly cleared
  /// use [Object] type with [_sentinel] default so that `copyWith(field: null)`
  /// can be distinguished from "field not provided".
  Conversation copyWith({
    String? id,
    String? title,
    String? displayName,
    Object? avatarUrl = _sentinel,
    Object? characterImage = _sentinel,
    Object? chatBackgroundImage = _sentinel,
    Object? chatBackgroundMaskOpacity = _sentinel,
    Object? chatBackgroundBlurSigma = _sentinel,
    Object? blurredBackground = _sentinel,
    Object? selfAddress = _sentinel,
    Object? addressUser = _sentinel,
    Object? voiceFile = _sentinel,
    Object? description = _sentinel,
    String? personaPrompt,
    List<Message>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? defaultProvider = _sentinel,
    Object? sessionProvider = _sentinel,
    bool? isPinned,
    bool? isFavorite,
    bool? isMuted,
    bool? notificationSound,
    Object? enabledPlugins = _sentinel,
    Object? recipeId = _sentinel,
    Map<String, ThinkingLevel>? thinkingLevels,
    Object? contextStartMessageId = _sentinel,
    Object? lastMessage = _sentinel,
    Object? lastMessageTime = _sentinel,
    int? unreadCount,
  }) {
    return Conversation(
      id: id ?? this.id,
      title: title ?? this.title,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl == _sentinel ? this.avatarUrl : avatarUrl as String?,
      characterImage: characterImage == _sentinel
          ? this.characterImage
          : characterImage as String?,
      chatBackgroundImage: chatBackgroundImage == _sentinel
          ? this.chatBackgroundImage
          : chatBackgroundImage as String?,
      chatBackgroundMaskOpacity: chatBackgroundMaskOpacity == _sentinel
          ? this.chatBackgroundMaskOpacity
          : chatBackgroundMaskOpacity as double?,
      chatBackgroundBlurSigma: chatBackgroundBlurSigma == _sentinel
          ? this.chatBackgroundBlurSigma
          : chatBackgroundBlurSigma as double?,
      blurredBackground: blurredBackground == _sentinel
          ? this.blurredBackground
          : blurredBackground as String?,
      selfAddress:
          selfAddress == _sentinel ? this.selfAddress : selfAddress as String?,
      addressUser:
          addressUser == _sentinel ? this.addressUser : addressUser as String?,
      voiceFile: voiceFile == _sentinel ? this.voiceFile : voiceFile as String?,
      description:
          description == _sentinel ? this.description : description as String?,
      personaPrompt: personaPrompt ?? this.personaPrompt,
      messages: messages ?? this.messages,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      defaultProvider: defaultProvider == _sentinel
          ? this.defaultProvider
          : defaultProvider as String?,
      sessionProvider: sessionProvider == _sentinel
          ? this.sessionProvider
          : sessionProvider as String?,
      isPinned: isPinned ?? this.isPinned,
      isFavorite: isFavorite ?? this.isFavorite,
      isMuted: isMuted ?? this.isMuted,
      notificationSound: notificationSound ?? this.notificationSound,
      enabledPlugins: enabledPlugins == _sentinel
          ? this.enabledPlugins
          : enabledPlugins as List<String>?,
      recipeId: recipeId == _sentinel ? this.recipeId : recipeId as String?,
      thinkingLevels: thinkingLevels ?? this.thinkingLevels,
      contextStartMessageId: contextStartMessageId == _sentinel
          ? this.contextStartMessageId
          : contextStartMessageId as String?,
      lastMessage:
          lastMessage == _sentinel ? this.lastMessage : lastMessage as String?,
      lastMessageTime: lastMessageTime == _sentinel
          ? this.lastMessageTime
          : lastMessageTime as DateTime?,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}
