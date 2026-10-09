import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_actions.dart' show chatActionsProvider;
import 'domain/message.dart';
import 'services/chat_history_store.dart';
import 'services/conversation_short_window_store.dart';

const int kConversationInitialVisibleCount = 20;
const int kConversationVisiblePageSize = 20;

final conversationVisibleCountProvider =
    StateProvider.autoDispose.family<int, String>(
  (ref, conversationId) => kConversationInitialVisibleCount,
);

/// Official frontend timeline source.
///
/// Chat page UI only reads the frontend timeline cache and never treats the
/// raw database as a second UI-state source.
final conversationMessageWindowProvider =
    StreamProvider.autoDispose.family<ConversationMessageWindow, String>(
  (ref, conversationId) async* {
    final limit = ref.watch(conversationVisibleCountProvider(conversationId));
    final timeline = ref.watch(conversationTimelineCacheProvider);
    final actions = ref.read(chatActionsProvider);
    await actions.recoverInterruptedUserMessages(conversationId);
    yield* timeline
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
