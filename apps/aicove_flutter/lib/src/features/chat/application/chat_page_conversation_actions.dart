import '../services/chat_history_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../conversation_providers.dart';

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
