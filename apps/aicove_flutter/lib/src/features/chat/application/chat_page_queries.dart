import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart' as db;
import '../../../core/database/database_provider.dart';
import '../services/chat_history_store.dart';

class ChatPageMessageSearchItem {
  const ChatPageMessageSearchItem({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  final String id;
  final String role;
  final String content;
  final DateTime createdAt;
}

class ChatPageQueries {
  const ChatPageQueries(this._ref);

  final Ref _ref;

  Future<bool> conversationHasImageMessages(String conversationId) async {
    final history = await _ref.read(chatHistoryStoreProvider).loadAllMessages(
          conversationId,
        );
    return history.any((message) => message.images.isNotEmpty);
  }

  Future<List<ChatPageMessageSearchItem>> searchConversationMessages({
    required String conversationId,
    String? keyword,
    DateTime? date,
    int limit = 200,
  }) async {
    final normalizedKeyword = keyword?.trim();
    if ((normalizedKeyword == null || normalizedKeyword.isEmpty) &&
        date == null) {
      return const <ChatPageMessageSearchItem>[];
    }

    final range = _buildSearchRange(date);
    final rows =
        await _ref.read(messageRepositoryProvider).searchByConversation(
              conversationId,
              keyword: normalizedKeyword == null || normalizedKeyword.isEmpty
                  ? null
                  : normalizedKeyword,
              startTime: range.startMs,
              endTime: range.endMs,
              limit: limit,
            );
    return rows.map(_mapSearchItem).toList(growable: false);
  }

  static ({int? startMs, int? endMs}) _buildSearchRange(DateTime? date) {
    if (date == null) {
      return (startMs: null, endMs: null);
    }
    final start = DateTime(date.year, date.month, date.day);
    return (
      startMs: start.millisecondsSinceEpoch,
      endMs: start.add(const Duration(days: 1)).millisecondsSinceEpoch,
    );
  }

  static ChatPageMessageSearchItem _mapSearchItem(db.Message row) {
    return ChatPageMessageSearchItem(
      id: row.id,
      role: row.role,
      content: row.content,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    );
  }
}

final chatPageQueriesProvider = Provider<ChatPageQueries>((ref) {
  return ChatPageQueries(ref);
});
