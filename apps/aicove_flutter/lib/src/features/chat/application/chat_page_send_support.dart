import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/app_settings.dart';
import '../domain/conversation.dart';
import 'chat_page_queries.dart';
import 'conversation_model.dart';

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

  /// 设置已就绪且无需查历史消息时同步返回 [ChatPageVisionCompatibilityDecision]，
  /// 避免纯文本发送为一次必然通过的检查挂起一帧；其余情况仍返回 [Future]。
  FutureOr<ChatPageVisionCompatibilityDecision> resolveVisionCompatibility({
    required Conversation conversation,
    bool currentMessageHasImage = false,
  }) {
    final loadedSettings = _ref.read(appSettingsProvider).valueOrNull;
    if (loadedSettings != null) {
      if (loadedSettings.skipVisionCompatDialog) {
        return const ChatPageVisionCompatibilityDecision.allow();
      }
      final primaryModel =
          conversationPrimaryModel(loadedSettings, conversation);
      if (loadedSettings.hasChatModelCapability(
        primaryModel,
        ChatModelCapability.vision,
      )) {
        return const ChatPageVisionCompatibilityDecision.allow();
      }
    }
    return _resolveVisionCompatibilityAsync(
      conversation: conversation,
      currentMessageHasImage: currentMessageHasImage,
    );
  }

  Future<ChatPageVisionCompatibilityDecision> _resolveVisionCompatibilityAsync({
    required Conversation conversation,
    required bool currentMessageHasImage,
  }) async {
    final settings = await _ref.read(appSettingsProvider.future);

    if (settings.skipVisionCompatDialog) {
      return const ChatPageVisionCompatibilityDecision.allow();
    }

    final primaryModel = conversationPrimaryModel(settings, conversation);
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
