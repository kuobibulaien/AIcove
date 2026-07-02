import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/app_settings.dart';
import '../domain/conversation.dart';
import 'chat_page_queries.dart';

class ChatPageVisionCompatibilityDecision {
  const ChatPageVisionCompatibilityDecision._({
    required this.canSend,
    this.modelDisplayName,
    this.hasVisionModel = false,
  });

  const ChatPageVisionCompatibilityDecision.allow()
      : this._(canSend: true);

  const ChatPageVisionCompatibilityDecision.requireConfirmation({
    required String modelDisplayName,
    required bool hasVisionModel,
  }) : this._(
          canSend: false,
          modelDisplayName: modelDisplayName,
          hasVisionModel: hasVisionModel,
        );

  final bool canSend;
  final String? modelDisplayName;
  final bool hasVisionModel;
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
      hasVisionModel: settings.defaultVisionModel != null &&
          settings.defaultVisionModel!.isNotEmpty,
    );
  }
}

final chatPageSendSupportProvider = Provider<ChatPageSendSupport>((ref) {
  return ChatPageSendSupport(ref);
});
