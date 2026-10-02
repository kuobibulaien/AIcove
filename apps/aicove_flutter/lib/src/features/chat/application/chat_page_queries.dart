import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/database.dart' as db;
import '../../../core/database/database_provider.dart';
import '../services/conversation_short_window_store.dart';

class ChatPageMessageSearchItem {
  const ChatPageMessageSearchItem({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
  });

  final String id;
  final String conversationId;
  final String role;
  final String content;
  final DateTime createdAt;
}

class ChatPageQueries {
  ChatPageQueries(this._ref) {
    _ref.onDispose(() => _disposed = true);
  }

  final Ref _ref;
  bool _disposed = false;
  Future<void>? _entryWarmupTask;

  /// 每个应用容器只预读一次、最多三个候选会话，每场仍只读取最近窗口。
  /// 复用正式时间线缓存，不创建第二份消息源；串行读取避免抢占首屏。
  /// 限制的是额外预读量，用户实际打开/翻页的缓存仍沿用原生命周期。
  Future<void> warmEntryMessages(Iterable<String> conversationIds) {
    final existing = _entryWarmupTask;
    if (existing != null) return existing;
    final targets = conversationIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .take(3)
        .toList(growable: false);
    if (_disposed || targets.isEmpty) return Future<void>.value();
    final cache = _ref.read(conversationTimelineCacheProvider);
    return _entryWarmupTask = _warmEntryMessages(cache, targets);
  }

  Future<void> _warmEntryMessages(
    ConversationTimelineCache cache,
    List<String> targets,
  ) async {
    for (final id in targets) {
      // 让出事件循环，不把多个会话的解析连在同一串 microtask 里。
      await Future<void>.delayed(Duration.zero);
      if (_disposed) return;
      if (cache.peekWindow(
            conversationId: id,
            limit: kConversationTimelineSeedMessageCount,
          ) !=
          null) {
        continue;
      }
      try {
        await cache
            .watchWindow(
              conversationId: id,
              limit: kConversationTimelineSeedMessageCount,
            )
            .first;
      } on Object catch (error) {
        // 预读失败不能影响联系人页；实际进入会话仍走正常读取与错误处理。
        debugPrint('[ChatEntry] 预读失败: ${error.runtimeType}');
      }
    }
  }

  /// Frontend-only query: follows the current projected timeline cache.
  ///
  /// This is intentionally different from backend context assembly, which reads
  /// raw database history.
  Future<bool> conversationHasImageMessages(String conversationId) async {
    final history = await _ref
        .read(conversationTimelineCacheProvider)
        .loadCachedMessages(conversationId);
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

  /// 联系人页全局搜索：跨会话按关键词匹配聊天记录。
  Future<List<ChatPageMessageSearchItem>> searchAllMessages(
    String keyword, {
    int limit = 100,
  }) async {
    final rows = await _ref
        .read(messageRepositoryProvider)
        .searchAll(keyword, limit: limit);
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
      conversationId: row.conversationId,
      role: row.role,
      content: row.content,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    );
  }
}

final chatPageQueriesProvider = Provider<ChatPageQueries>((ref) {
  return ChatPageQueries(ref);
});
