import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/message.dart';
import 'services/conversation_short_window_store.dart';
import 'services/chat_history_store.dart';

const int kConversationInitialVisibleCount = 20;
const int kConversationVisiblePageSize = 20;

class ConversationTransientTimelineState {
  const ConversationTransientTimelineState({
    this.messages = const <Message>[],
  });

  final List<Message> messages;

  bool get isEmpty => messages.isEmpty;
  bool get isNotEmpty => messages.isNotEmpty;

  ConversationTransientTimelineState copyWith({
    List<Message>? messages,
  }) {
    return ConversationTransientTimelineState(
      messages: messages ?? this.messages,
    );
  }

  static const empty = ConversationTransientTimelineState();
}

class ConversationTransientTimelineController
    extends StateNotifier<ConversationTransientTimelineState> {
  ConversationTransientTimelineController()
      : super(ConversationTransientTimelineState.empty);

  void setMessages(List<Message> messages) {
    state = ConversationTransientTimelineState(
      messages: _normalizeMessages(messages),
    );
  }

  void upsertMessage(Message message) {
    final next = <Message>[
      for (final item in state.messages)
        if (item.id != message.id) item,
      message,
    ];
    state = ConversationTransientTimelineState(
      messages: _normalizeMessages(next),
    );
  }

  void removeMessage(String messageId) {
    if (messageId.trim().isEmpty) return;
    final next = state.messages
        .where((message) => message.id != messageId)
        .toList(growable: false);
    if (next.length == state.messages.length) return;
    state = ConversationTransientTimelineState(messages: next);
  }

  void clear() {
    if (state.isEmpty) return;
    state = ConversationTransientTimelineState.empty;
  }

  List<Message> _normalizeMessages(List<Message> messages) {
    if (messages.isEmpty) return const <Message>[];
    final deduped = <String, Message>{};
    for (final message in messages) {
      deduped[message.id] = message;
    }
    final normalized = deduped.values.toList(growable: false)
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });
    return normalized;
  }
}

final conversationVisibleCountProvider = StateProvider.family<int, String>(
  (ref, conversationId) => kConversationInitialVisibleCount,
);

final conversationMessageWindowProvider =
    StreamProvider.autoDispose.family<ConversationMessageWindow, String>(
  (ref, conversationId) {
    final limit = ref.watch(conversationVisibleCountProvider(conversationId));
    return ref
        .watch(conversationShortWindowStoreProvider)
        .watchWindow(
          conversationId: conversationId,
          limit: limit,
        )
        .map(
          (window) => ConversationMessageWindow(
            messages: window.messages,
            hasMore: window.hasMoreMessages,
          ),
        );
  },
);

final conversationMessagesProvider = Provider.autoDispose
    .family<AsyncValue<List<Message>>, String>((ref, conversationId) {
  return ref.watch(conversationMessageWindowProvider(conversationId)).whenData(
        (window) => window.messages,
      );
});

final conversationHasMoreProvider =
    Provider.autoDispose.family<bool, String>((ref, conversationId) {
  return ref.watch(conversationMessageWindowProvider(conversationId)).maybeWhen(
        data: (window) => window.hasMore,
        orElse: () => true,
      );
});

final conversationTransientTimelineProvider = StateNotifierProvider.family<
    ConversationTransientTimelineController,
    ConversationTransientTimelineState,
    String>(
  (ref, conversationId) => ConversationTransientTimelineController(),
);

final conversationTransientMessagesProvider =
    Provider.family<List<Message>, String>((ref, conversationId) {
  return ref
      .watch(conversationTransientTimelineProvider(conversationId))
      .messages;
});
