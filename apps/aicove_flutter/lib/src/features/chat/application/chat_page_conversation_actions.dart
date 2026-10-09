import '../../conversation_state/domain/mvu_content.dart';
import '../services/chat_history_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent_context/domain/preset_tag_mapping.dart';
import '../../agent_context/domain/silly_tavern_character_card.dart';
import '../../agent_context/domain/silly_tavern_preset.dart';
import '../../agent_context/domain/silly_tavern_regex_processor.dart';
import '../../agent_context/providers/preset_recipe_provider.dart';
import '../../settings/app_settings.dart';
import '../conversation_providers.dart';
import '../domain/message.dart';
import '../services/chat_frontend_message_projection_service.dart';
import '../services/chat_message_projection_codec.dart';
import '../services/chat_types.dart';

class ChatPageConversationActions {
  const ChatPageConversationActions(this._ref);

  final Ref _ref;

  Future<void> clearUnread(String conversationId) {
    return _ref
        .read(conversationsProvider.notifier)
        .clearUnread(conversationId);
  }

  Future<void> applyConversationEdits(
    String conversationId, {
    String? displayName,
    String? avatarUrl,
    bool clearAvatarUrl = false,
    String? characterImage,
    bool clearCharacterImage = false,
    String? chatBackgroundImage,
    bool clearChatBackgroundImage = false,
    double? chatBackgroundMaskOpacity,
    bool clearChatBackgroundMaskOpacity = false,
    double? chatBackgroundBlurSigma,
    bool clearChatBackgroundBlurSigma = false,
    String? selfAddress,
    bool clearSelfAddress = false,
    String? addressUser,
    bool clearAddressUser = false,
    String? voiceFile,
    bool clearVoiceFile = false,
    String? description,
    bool clearDescription = false,
    String? personaPrompt,
    List<String>? enabledPlugins,
    bool clearEnabledPlugins = false,
    String? recipeId,
    bool clearRecipeId = false,
  }) {
    return _ref
        .read(conversationsProvider.notifier)
        .applyContactEdit(
          conversationId,
          displayName: displayName,
          avatarUrl: avatarUrl,
          clearAvatarUrl: clearAvatarUrl,
          characterImage: characterImage,
          clearCharacterImage: clearCharacterImage,
          chatBackgroundImage: chatBackgroundImage,
          clearChatBackgroundImage: clearChatBackgroundImage,
          chatBackgroundMaskOpacity: chatBackgroundMaskOpacity,
          clearChatBackgroundMaskOpacity: clearChatBackgroundMaskOpacity,
          chatBackgroundBlurSigma: chatBackgroundBlurSigma,
          clearChatBackgroundBlurSigma: clearChatBackgroundBlurSigma,
          selfAddress: selfAddress,
          clearSelfAddress: clearSelfAddress,
          addressUser: addressUser,
          clearAddressUser: clearAddressUser,
          voiceFile: voiceFile,
          clearVoiceFile: clearVoiceFile,
          description: description,
          clearDescription: clearDescription,
          personaPrompt: personaPrompt,
          enabledPlugins: enabledPlugins,
          clearEnabledPlugins: clearEnabledPlugins,
          recipeId: recipeId,
          clearRecipeId: clearRecipeId,
        );
  }

  Future<void> updateConversationSettings(
    String conversationId, {
    bool? isPinned,
    bool? isFavorite,
    bool? isMuted,
    bool? notificationSound,
    List<String>? enabledPlugins,
    bool clearEnabledPlugins = false,
  }) {
    return _ref
        .read(conversationsProvider.notifier)
        .updateConversationSettings(
          conversationId,
          isPinned: isPinned,
          isFavorite: isFavorite,
          isMuted: isMuted,
          notificationSound: notificationSound,
          enabledPlugins: enabledPlugins,
          clearEnabledPlugins: clearEnabledPlugins,
        );
  }

  Future<void> hideMessages(String conversationId, List<String> messageIds) {
    return _ref
        .read(chatHistoryStoreProvider)
        .hideMessagesInFrontendTimeline(conversationId, messageIds);
  }

  /// 把角色卡开场白写成会话里的第一条角色消息（与酒馆建聊一致，宏在写入时替换）。
  ///
  /// 原文进 raw 消息供请求装配；显示副本按角色最终有效预设的已授权显示正则生成，
  /// 与普通回复同构。消息 ID 按会话固定，失败重试只会覆盖同一条。
  Future<void> appendCharacterGreeting(
    String conversationId, {
    required String greeting,
    required String charName,
    String? recipeId,
  }) async {
    final settings = await _ref.read(appSettingsProvider.future);
    final preset = await _ref
        .read(tavernCompatibilityPortProvider)
        .resolvePreset(recipeId);
    final userName = settings.userName?.trim() ?? '';
    final text = SillyTavernCharacterCard.renderGreeting(
      greeting,
      charName: charName,
      userName: preset?.userNameMacroEnabled != false && userName.isNotEmpty
          ? userName
          : kNeutralUserName,
    );
    final display = preset == null
        ? text
        : (await const SillyTavernRegexProcessor().applyToDisplayText(
            text: text,
            scripts: inferPresetTagMapping(
              preset,
            ).displayScripts(preset.regexScripts),
            authorized: preset.regexAuthorized,
          )).text;
    final rawMessage = Message(
      id: greetingMessageId(conversationId),
      role: 'assistant',
      content: text,
      createdAt: DateTime.now(),
      status: 'sent',
      rawPayload: ChatMessageProjectionCodec.buildRawAssistantPayload(
        apiResult: ApiCallResult(
          rawReplyText: text,
          replyText: display,
          processedText: display,
          pluginEvents: const [],
          toolResults: const [],
        ),
      ),
    );
    await _ref
        .read(chatHistoryStoreProvider)
        .appendAssistantRawMessage(
          conversationId: conversationId,
          userMessageId: '',
          rawMessage: rawMessage,
          projectedMessages: _ref
              .read(chatFrontendMessageProjectionServiceProvider)
              .projectMessage(rawMessage),
          lastMessagePreview: stripMvuUpdateBlocks(display).trim(),
        );
  }

  static String greetingMessageId(String conversationId) =>
      'msg_greeting_$conversationId';

  /// 开场白之前没有用户消息，不能重新生成。
  static bool isCharacterGreeting(Message message) =>
      message.sourceMessageIdOrSelf.startsWith('msg_greeting_');

  Future<void> clearMessages(String conversationId) {
    return _ref
        .read(conversationsProvider.notifier)
        .clearMessages(conversationId);
  }

  Future<void> deleteConversation(String conversationId) {
    return _ref
        .read(conversationsProvider.notifier)
        .deleteConversation(conversationId);
  }
}

final chatPageConversationActionsProvider =
    Provider<ChatPageConversationActions>((ref) {
      return ChatPageConversationActions(ref);
    });
