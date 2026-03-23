import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'domain/message.dart';
import 'services/conversation_short_window_store.dart';
import 'services/chat_history_store.dart';

const int kConversationInitialVisibleCount = 20;
const int kConversationVisiblePageSize = 20;

final conversationVisibleCountProvider = StateProvider.family<int, String>(
  (ref, conversationId) => kConversationInitialVisibleCount,
);

/// Official frontend timeline source.
///
/// Chat page UI must consume the short-window snapshot instead of rebuilding a
/// separate database-driven timeline.
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
