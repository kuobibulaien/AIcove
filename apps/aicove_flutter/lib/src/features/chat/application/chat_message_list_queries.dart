import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/message.dart';
import '../services/chat_history_store.dart';

typedef ChatMessageListPersistentSnapshotWindow = ConversationTurnWindow;
typedef LoadChatMessageListOlderPage = LoadConversationOlderPage;
const int kConversationPersistentSnapshotTurnCount = 5;

class ChatMessageListQueries {
  const ChatMessageListQueries(this._ref);

  final Ref _ref;

  Future<List<Message>> loadMessagesBefore({
    required String conversationId,
    required DateTime beforeCreatedAt,
    required String beforeId,
    required int limit,
  }) {
    return _ref.read(chatHistoryStoreProvider).loadMessagesBefore(
          conversationId: conversationId,
          beforeCreatedAt: beforeCreatedAt,
          beforeId: beforeId,
          limit: limit,
        );
  }
}

Future<ChatMessageListPersistentSnapshotWindow>
    resolveChatMessageListPersistentSnapshotWindow({
  required List<Message> currentMessages,
  required bool hasMoreMessages,
  required LoadChatMessageListOlderPage loadOlderPage,
  int targetTurnCount = kConversationPersistentSnapshotTurnCount,
  int fetchPageSize = kConversationTurnWindowFetchPageSize,
  int maxFetchPages = kConversationTurnWindowMaxFetchPages,
}) {
  return resolveConversationTurnWindow(
    currentMessages: currentMessages,
    hasMoreMessages: hasMoreMessages,
    loadOlderPage: loadOlderPage,
    targetTurnCount: targetTurnCount,
    fetchPageSize: fetchPageSize,
    maxFetchPages: maxFetchPages,
  );
}

int countChatMessageListConversationTurns(List<Message> messages) {
  return countConversationTurns(messages);
}

final chatMessageListQueriesProvider = Provider<ChatMessageListQueries>((ref) {
  return ChatMessageListQueries(ref);
});
