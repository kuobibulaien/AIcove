import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/app_settings.dart';
import '../domain/conversation.dart';
import 'chat_page_queries.dart';

class ChatPageVisionCompatibilityDecision {
  const ChatPageVisionCompatibilityDecision._({
    required this.canSend,
    this.modelDisplayName,
  });

  const ChatPageVisionCompatibilityDecision.allow()
      : this._(canSend: true);

  const ChatPageVisionCompatibilityDecision.requireConfirmation({
    required String modelDisplayName,
  }) : this._(
          canSend: false,
          modelDisplayName: modelDisplayName,
        );

  final bool canSend;
  final String? modelDisplayName;
}

class ChatPageSendSupport {
  const ChatPageSendSupport(this._ref);

  final Ref _ref;

  Future<ChatPageVisionCompatibilityDecision> resolveVisionCompatibility({
    required Conversation conversation,
    bool currentMessageHasImage = false,
  }) async {
    final settings = await _ref.read(appSettingsProvider.future);

    if (settings.skipVisionCompatDialog) {
      return const ChatPageVisionCompatibilityDecision.allow();
    }

    final chatModels = settings.defaultChatModels.isNotEmpty
        ? settings.defaultChatModels
        : <String>[settings.defaultModelName];
    final primaryModel = chatModels.first;
    if (settings.hasChatModelCapability(
      primaryModel,
      ChatModelCapability.vision,
    )) {
      return const ChatPageVisionCompatibilityDecision.allow();
    }

    final historyHasImage = await _ref
        .read(chatPageQueriesProvider)
        .conversationHasImageMessages(conversation.id);
    if (!historyHasImage && !currentMessageHasImage) {
      return const ChatPageVisionCompatibilityDecision.allow();
    }

    return ChatPageVisionCompatibilityDecision.requireConfirmation(
      modelDisplayName: settings.getModelDisplayName(primaryModel),
    );
  }
}

final chatPageSendSupportProvider = Provider<ChatPageSendSupport>((ref) {
  return ChatPageSendSupport(ref);
});
