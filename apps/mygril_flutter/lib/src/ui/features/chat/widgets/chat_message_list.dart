/// 聊天消息列表组件
/// 
/// 从 chat_page.dart 提取，负责显示消息列表和时间分隔器。
/// 
/// 更新记录：
/// - 2025-12-31: 从 chat_page.dart 提取
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../features/settings/app_settings.dart';
import 'animated_message_item.dart';

/// 消息列表组件
class ChatMessageList extends ConsumerStatefulWidget {
  final List<Message> messages;
  final String conversationId;
  final String? avatarUrl;
  final String displayName;

  const ChatMessageList({
    super.key,
    required this.messages,
    required this.conversationId,
    this.avatarUrl,
    required this.displayName,
  });

  @override
  ConsumerState<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends ConsumerState<ChatMessageList> {
  final Set<String> _pendingAnimationIds = <String>{};
  DateTime? _latestAnimatedAt;
  List<_ListItem> _cachedListItems = [];

  @override
  void initState() {
    super.initState();
    if (widget.messages.isNotEmpty) {
      _latestAnimatedAt = widget.messages.last.createdAt;
    }
    _updateListItems();
  }

  void _updateListItems() {
    _cachedListItems = _buildListItemsWithTimeDividers().reversed.toList();
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 缓存优化：仅当消息列表引用变化或会话变化时才重构列表项
    // 避免键盘弹出/收起导致 MediaQuery 变化进而触发全量重建 (Layout Thrashing)
    if (widget.messages != oldWidget.messages || 
        widget.conversationId != oldWidget.conversationId) {
      _updateListItems();
    }

    if (oldWidget.conversationId != widget.conversationId) {
      _pendingAnimationIds.clear();
      _latestAnimatedAt =
          widget.messages.isNotEmpty ? widget.messages.last.createdAt : null;
      return;
    }

    if (widget.messages.isEmpty) {
      _pendingAnimationIds.clear();
      _latestAnimatedAt = null;
      return;
    }

    final threshold = _latestAnimatedAt;
    final List<Message> newMessages;
    if (threshold == null) {
      newMessages = List<Message>.from(widget.messages);
    } else {
      newMessages = widget.messages
          .where((m) => m.createdAt.isAfter(threshold))
          .toList();
    }

    if (newMessages.isEmpty) {
      return;
    }

    setState(() {
      _pendingAnimationIds.addAll(newMessages.map((m) => m.id));
      final newestTime = newMessages
          .map((m) => m.createdAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      _latestAnimatedAt = newestTime;
    });
  }

  @override
  Widget build(BuildContext context) {
    final actions = ref.watch(chatActionsProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final fontSize = settingsAsync.maybeWhen(
      data: (settings) => settings.messageFontSize,
      orElse: () => 13.0,
    );
    
    // 构建包含时间分隔器的列表项（因为 ListView reverse=true，需要反转列表顺序）
    // 使用缓存的列表项，避免每次 build 重复计算
    final listItems = _cachedListItems;
    
    return ListView.builder(
      reverse: true, // 从底部开始显示，新消息在下方
      padding: EdgeInsets.only(
        left: 4,
        right: 4,
        top: 10,
        bottom: MediaQuery.of(context).padding.bottom + 10,
      ),
      itemCount: listItems.length,
      itemBuilder: (context, index) {
        final item = listItems[index];

        if (item is _TimeDivider) {
          return _buildTimeDivider(context, item.time);
        } else if (item is _MessageItem) {
          final m = item.message;
          final isMe = m.role == 'user';
          final bubbleWidget = Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: MessageBubble(
              isMe: isMe,
              message: m,
              avatarUrl: isMe ? null : widget.avatarUrl,
              displayName: isMe ? null : widget.displayName,
              fontSize: fontSize,
              onRetry: (isMe && m.status == 'failed')
                  ? () => _showRetryDialog(context, m.id, actions)
                  : null,
            ),
          );

          final shouldAnimate = _pendingAnimationIds.contains(m.id);
          if (shouldAnimate) {
            _pendingAnimationIds.remove(m.id);
            return AnimatedMessageItem(
              key: ValueKey(m.id),
              isMe: isMe,
              child: bubbleWidget,
            );
          }
          return bubbleWidget;
        }
        
        return const SizedBox.shrink();
      },
    );
  }

  /// 构建包含时间分隔器的列表项
  List<_ListItem> _buildListItemsWithTimeDividers() {
    final List<_ListItem> items = [];
    final messages = widget.messages;
    
    for (int i = 0; i < messages.length; i++) {
      final currentMessage = messages[i];
      
      if (i == 0) {
        items.add(_TimeDivider(currentMessage.createdAt));
      } else {
        final previousMessage = messages[i - 1];
        final timeDiff = currentMessage.createdAt.difference(previousMessage.createdAt);
        
        if (timeDiff.inMinutes >= 20) {
          items.add(_TimeDivider(currentMessage.createdAt));
        }
      }
      
      items.add(_MessageItem(currentMessage));
    }
    
    return items;
  }

  /// 构建时间分隔器Widget
  Widget _buildTimeDivider(BuildContext context, DateTime time) {
    final colors = context.moeColors;
    final timeStr = _formatChatTime(time);

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          timeStr,
          style: TextStyle(
            color: colors.muted,
            fontSize: 12,
            fontWeight: FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 格式化聊天时间
  String _formatChatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final targetDay = DateTime(time.year, time.month, time.day);

    final dayDiff = today.difference(targetDay).inDays;

    String prefix;
    if (dayDiff <= 0) {
      prefix = '';
    } else if (dayDiff == 1) {
      prefix = '昨天 ';
    } else if (dayDiff == 2) {
      prefix = '前天 ';
    } else {
      const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
      prefix = '${weekdays[time.weekday - 1]} ';
    }

    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');

    return '$prefix$hh:$mm';
  }

  Future<void> _showRetryDialog(
    BuildContext context,
    String messageId,
    ChatActions actions,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重新发送'),
        content: const Text('是否重新发送该消息？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('发送'),
          ),
        ],
      ),
    );

    if (result == true) {
      await actions.retry(messageId);
    }
  }
}

/// 列表项的基类
abstract class _ListItem {}

/// 消息列表项
class _MessageItem extends _ListItem {
  final Message message;
  _MessageItem(this.message);
}

/// 时间分隔器列表项
class _TimeDivider extends _ListItem {
  final DateTime time;
  _TimeDivider(this.time);
}
