import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../../core/database/database.dart' as db;
import '../../../core/database/database_provider.dart';
import '../../plugins/memory/memory_plugin.dart';
import '../../plugins/plugin_providers.dart';
import '../../memory/services/memory_service.dart';
import '../conversation_providers.dart';

final chatPageMemoryPluginProvider = Provider<MemoryPlugin?>((ref) {
  final pluginManager = ref.watch(pluginManagerProvider);
  final plugin = pluginManager.getPlugin('memory');
  return plugin is MemoryPlugin ? plugin : null;
});

final chatPageMemoryServiceProvider = Provider<MemoryService?>((ref) {
  return ref.watch(chatPageMemoryPluginProvider)?.service;
});

class ChatPageConversationActions {
  const ChatPageConversationActions(this._ref);

  final Ref _ref;

  Future<void> clearUnread(String conversationId) {
    return _ref.read(conversationsProvider.notifier).clearUnread(
          conversationId,
        );
  }

  Future<void> startNewTopic({
    required String conversationId,
    required String lastMessageId,
  }) async {
    final conversation =
        _ref.read(conversationSnapshotByIdProvider(conversationId));
    final memoryPlugin = _ref.read(chatPageMemoryPluginProvider);
    final memoryService = _ref.read(chatPageMemoryServiceProvider);
    if (conversation != null &&
        memoryService != null &&
        memoryService.config.enabled) {
      try {
        final allMessages = await _ref
            .read(messageRepositoryProvider)
            .getAllByConversationOrdered(
              conversationId,
            );
        final candidateMessageIds = _collectTopicMessageIds(
          allMessages: allMessages,
          contextStartMessageId: conversation.contextStartMessageId,
          lastMessageId: lastMessageId,
        );
        if (candidateMessageIds.isNotEmpty) {
          await memoryService.ingestMessages(
            conversationId: conversationId,
            candidateMessageIds: candidateMessageIds,
            trigger: MemoryIngestTrigger.manual,
          );
        }
      } catch (error) {
        AppLogger.warning(
          'ChatPageConversationActions',
          'Failed to summarize current topic before resetting context',
          metadata: {
            'conversationId': conversationId,
            'lastMessageId': lastMessageId,
            'error': error.toString(),
          },
        );
      }
    }
    await _ref.read(conversationsProvider.notifier).updateOne(
          conversationId,
          (currentConversation) => currentConversation.copyWith(
            contextStartMessageId: lastMessageId,
            updatedAt: DateTime.now(),
          ),
        );
    memoryPlugin?.clearConversationCache(conversationId);
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
  }) {
    return _ref.read(conversationsProvider.notifier).applyContactEdit(
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
    return _ref.read(conversationsProvider.notifier).updateConversationSettings(
          conversationId,
          isPinned: isPinned,
          isFavorite: isFavorite,
          isMuted: isMuted,
          notificationSound: notificationSound,
          enabledPlugins: enabledPlugins,
          clearEnabledPlugins: clearEnabledPlugins,
        );
  }

  Future<void> clearMessages(String conversationId) async {
    await _ref.read(conversationsProvider.notifier).clearMessages(
          conversationId,
        );
    _ref
        .read(chatPageMemoryPluginProvider)
        ?.clearConversationCache(conversationId);
  }

  Future<void> deleteConversation(String conversationId) {
    return _ref.read(conversationsProvider.notifier).deleteConversation(
          conversationId,
        );
  }

  List<String> _collectTopicMessageIds({
    required List<db.Message> allMessages,
    required String? contextStartMessageId,
    required String lastMessageId,
  }) {
    if (allMessages.isEmpty) return const [];

    var startIndex = 0;
    final trimmedContextStartMessageId = contextStartMessageId?.trim() ?? '';
    if (trimmedContextStartMessageId.isNotEmpty) {
      final markerIndex = allMessages.lastIndexWhere(
        (message) => message.id == trimmedContextStartMessageId,
      );
      if (markerIndex >= 0) {
        startIndex = markerIndex + 1;
      }
    }

    final endIndex = allMessages.lastIndexWhere(
      (message) => message.id == lastMessageId,
    );
    if (endIndex < 0 || endIndex < startIndex) {
      return const [];
    }

    return allMessages
        .sublist(startIndex, endIndex + 1)
        .map((message) => message.id)
        .toList(growable: false);
  }
}

final chatPageConversationActionsProvider =
    Provider<ChatPageConversationActions>((ref) {
  return ChatPageConversationActions(ref);
});
