import 'package:flutter/scheduler.dart';

typedef ConversationIdReader = String? Function();
typedef ConversationActivator = void Function(String conversationId);
typedef MountedReader = bool Function();
typedef PostFrameScheduler = void Function(FrameCallback callback);

class DeferredConversationActivation {
  DeferredConversationActivation({
    PostFrameScheduler? schedulePostFrame,
  }) : _schedulePostFrame =
            schedulePostFrame ?? SchedulerBinding.instance.addPostFrameCallback;

  final PostFrameScheduler _schedulePostFrame;

  String? _pendingConversationId;

  void schedule({
    required String conversationId,
    required MountedReader isMounted,
    required ConversationIdReader readActiveConversationId,
    required ConversationActivator activateConversation,
  }) {
    if (_pendingConversationId == conversationId) {
      return;
    }

    _pendingConversationId = conversationId;
    _schedulePostFrame((_) {
      if (!isMounted()) {
        return;
      }
      if (_pendingConversationId != conversationId) {
        return;
      }

      _pendingConversationId = null;
      final activeConversationId = readActiveConversationId();
      if (activeConversationId == conversationId) {
        return;
      }
      activateConversation(conversationId);
    });
  }

  void clear() {
    _pendingConversationId = null;
  }
}
