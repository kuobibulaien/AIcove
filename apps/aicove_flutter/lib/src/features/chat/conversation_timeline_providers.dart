import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/message.dart';
import 'services/chat_history_store.dart';
import 'conversation_providers.dart';

class StreamingBubbleState {
  const StreamingBubbleState({
    this.visible = false,
    this.text = '',
    this.status = StreamingBubbleStatus.hidden,
  });

  final bool visible;
  final String text;
  final StreamingBubbleStatus status;

  StreamingBubbleState copyWith({
    bool? visible,
    String? text,
    StreamingBubbleStatus? status,
  }) {
    return StreamingBubbleState(
      visible: visible ?? this.visible,
      text: text ?? this.text,
      status: status ?? this.status,
    );
  }

  static const hidden = StreamingBubbleState();
}

enum StreamingBubbleStatus {
  hidden,
  thinking,
  streaming,
  fallback,
}

final conversationVisibleCountProvider =
    StateProvider.family<int, String>((ref, conversationId) => 30);

final conversationMessageWindowProvider =
    StreamProvider.family<ConversationMessageWindow, String>(
  (ref, conversationId) {
    final limit = ref.watch(conversationVisibleCountProvider(conversationId));
    return ref.watch(chatHistoryStoreProvider).watchWindow(
          conversationId: conversationId,
          limit: limit,
        );
  },
);

final conversationMessagesProvider =
    Provider.family<AsyncValue<List<Message>>, String>((ref, conversationId) {
  return ref.watch(conversationMessageWindowProvider(conversationId)).whenData(
        (window) => window.messages,
      );
});

final conversationHasMoreProvider =
    Provider.family<bool, String>((ref, conversationId) {
  return ref
      .watch(conversationMessageWindowProvider(conversationId))
      .maybeWhen(
        data: (window) => window.hasMore,
        orElse: () => true,
      );
});

final activeConversationMessagesProvider = Provider<AsyncValue<List<Message>>>(
  (ref) {
    final convId = ref.watch(activeConversationIdProvider);
    if (convId == null || convId.trim().isEmpty) {
      return const AsyncValue.data(<Message>[]);
    }
    return ref.watch(conversationMessagesProvider(convId));
  },
);

final activeConversationHasMoreProvider = Provider<bool>((ref) {
  final convId = ref.watch(activeConversationIdProvider);
  if (convId == null || convId.trim().isEmpty) {
    return false;
  }
  return ref.watch(conversationHasMoreProvider(convId));
});

final streamingBubbleProvider =
    StateProvider.family<StreamingBubbleState, String>(
  (ref, conversationId) => StreamingBubbleState.hidden,
);

final activeStreamingBubbleProvider = Provider<StreamingBubbleState>((ref) {
  final convId = ref.watch(activeConversationIdProvider);
  if (convId == null || convId.trim().isEmpty) {
    return StreamingBubbleState.hidden;
  }
  return ref.watch(streamingBubbleProvider(convId));
});
