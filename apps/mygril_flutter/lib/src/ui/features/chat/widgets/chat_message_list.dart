/// 聊天消息列表组件
///
/// 从 chat_page.dart 提取，负责显示消息列表和时间分隔器。
///
/// 更新记录：
/// - 2025-12-31: 从 chat_page.dart 提取
/// - 2026-01-28: 添加消息分段显示功能（纯前端展示）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../../features/chat/presentation/widgets/message_action_sheet.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/utils/message_formatter.dart';
import 'animated_message_item.dart';

const double _kMessageItemVerticalPadding = 2.0;

/// 消息列表组件
class ChatMessageList extends ConsumerStatefulWidget {
  final List<Message> messages;
  final String conversationId;
  final String? avatarUrl;
  final String displayName;
  final void Function(Message message)? onEditMessage;
  final void Function(Message message)? onRegenerateMessage;

  /// 分页加载：滑到顶部（历史消息方向）时触发
  final Future<void> Function()? onLoadMore;

  /// 是否正在加载更多
  final bool isLoadingMore;

  /// 是否还有更多历史消息可加载
  final bool hasMoreMessages;

  const ChatMessageList({
    super.key,
    required this.messages,
    required this.conversationId,
    this.avatarUrl,
    required this.displayName,
    this.onEditMessage,
    this.onRegenerateMessage,
    this.onLoadMore,
    this.isLoadingMore = false,
    this.hasMoreMessages = true,
  });

  @override
  ConsumerState<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends ConsumerState<ChatMessageList> {
  final Set<String> _pendingAnimationIds = <String>{};
  DateTime? _latestAnimatedAt;
  List<_ListItem> _cachedListItems = [];

  /// 缓存的消息格式化配置（用于检测配置变化）
  MessageFormatConfig? _cachedFormatConfig;

  /// 用于监听滚动位置，触发分页加载
  late final ScrollController _scrollController;

  /// 防止重复触发加载
  bool _isLoadingTriggered = false;

  @override
  void initState() {
    super.initState();
    if (widget.messages.isNotEmpty) {
      _latestAnimatedAt = widget.messages.last.createdAt;
    }
    _updateListItems();

    // 初始化 ScrollController 并添加监听
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 滚动监听：当接近列表顶部（历史消息方向）时触发加载更多
  void _onScroll() {
    // reverse=true 时，maxScrollExtent 是列表顶部（历史消息方向）
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    final maxScroll = position.maxScrollExtent;
    final currentScroll = position.pixels;

    // 距离顶部 200 像素时触发加载
    const threshold = 200.0;

    if (maxScroll - currentScroll <= threshold &&
        !_isLoadingTriggered &&
        !widget.isLoadingMore &&
        widget.hasMoreMessages &&
        widget.onLoadMore != null) {
      _isLoadingTriggered = true;
      widget.onLoadMore!().then((_) {
        _isLoadingTriggered = false;
      }).catchError((_) {
        _isLoadingTriggered = false;
      });
    }
  }

  void _updateListItems([MessageFormatConfig? config]) {
    _cachedFormatConfig = config;
    _cachedListItems =
        _buildListItemsWithTimeDividers(config).reversed.toList();
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 会话切换：重置状态并更新列表项
    if (oldWidget.conversationId != widget.conversationId) {
      _pendingAnimationIds.clear();
      _latestAnimatedAt =
          widget.messages.isNotEmpty ? widget.messages.last.createdAt : null;
      _updateListItems();
      return;
    }

    // 缓存优化：仅当消息列表引用变化时才重构列表项
    // 避免键盘弹出/收起导致 MediaQuery 变化进而触发全量重建 (Layout Thrashing)
    if (widget.messages != oldWidget.messages) {
      _updateListItems();
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
      newMessages =
          widget.messages.where((m) => m.createdAt.isAfter(threshold)).toList();
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

    // 获取消息格式化配置（用于分段显示）
    final formatConfig = settingsAsync.maybeWhen(
      data: (settings) => settings.messageFormatConfig,
      orElse: () => const MessageFormatConfig(),
    );

    // 检测配置变化，需要重新构建列表项
    if (_cachedFormatConfig != formatConfig) {
      // 使用 addPostFrameCallback 避免在 build 中调用 setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _updateListItems(formatConfig);
          setState(() {});
        }
      });
    }

    // 构建包含时间分隔器的列表项（因为 ListView reverse=true，需要反转列表顺序）
    // 使用缓存的列表项，避免每次 build 重复计算
    final listItems = _cachedListItems;

    // 计算实际 itemCount：如果正在加载更多，顶部多显示一个加载指示器
    final itemCount = listItems.length + (widget.isLoadingMore ? 1 : 0);

    return ListView.builder(
      controller: _scrollController, // 添加 ScrollController 用于分页触发
      reverse: true, // 从底部开始显示，新消息在下方
      // 性能优化：增加缓存范围，减少滚动时的重建
      cacheExtent: 500,
      // 性能优化：禁用自动 keep alive，由我们自己控制
      addAutomaticKeepAlives: false,
      // 性能优化：添加重绘边界，隔离每个消息的重绘
      addRepaintBoundaries: true,
      padding: EdgeInsets.only(
        left: 4,
        right: 4,
        top: 10,
        // 底部留出足够空间给浮动的 Composer（约 70px 高度）
        bottom: MediaQuery.paddingOf(context).bottom + 70,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        // 如果正在加载更多，最后一项显示加载指示器
        if (widget.isLoadingMore && index == listItems.length) {
          return _buildLoadingIndicator();
        }

        final item = listItems[index];

        if (item is _TimeDivider) {
          return _buildTimeDivider(context, item.time);
        } else if (item is _ChunkedMessageItem) {
          // 分段消息：创建一个临时 Message 对象用于显示
          final m = item.originalMessage;
          final isMe = m.role == 'user';
          final chunkMessage = Message(
            id: '${m.id}_chunk_${item.chunkIndex}',
            role: m.role,
            content: item.chunkText,
            createdAt: m.createdAt,
            status: m.status,
          );
          final bubbleWidget = Padding(
            padding: const EdgeInsets.symmetric(
                vertical: _kMessageItemVerticalPadding),
            child: MessageBubble(
              isMe: isMe,
              message: chunkMessage,
              avatarUrl: isMe ? null : widget.avatarUrl,
              displayName: isMe ? null : widget.displayName,
              showCorner: item.showCorner,
              showName: false,
              showAvatar: item.showAvatar,
              onRetry: null, // 分段消息不支持重试
              onLongPress: (bubbleKey) =>
                  _handleMessageLongPress(context, m, isMe, bubbleKey),
            ),
          );

          // 只有第一个分段需要动画
          final shouldAnimate =
              item.chunkIndex == 0 && _pendingAnimationIds.contains(m.id);
          if (shouldAnimate) {
            _pendingAnimationIds.remove(m.id);
            return AnimatedMessageItem(
              key: ValueKey('${m.id}_chunk_${item.chunkIndex}'),
              isMe: isMe,
              child: bubbleWidget,
            );
          }
          return bubbleWidget;
        } else if (item is _MessageItem) {
          final m = item.message;
          final isMe = m.role == 'user';
          final bubbleWidget = Padding(
            padding: const EdgeInsets.symmetric(
                vertical: _kMessageItemVerticalPadding),
            child: MessageBubble(
              isMe: isMe,
              message: m,
              avatarUrl: isMe ? null : widget.avatarUrl,
              displayName: isMe ? null : widget.displayName,
              showCorner: item.showCorner,
              showName: false, // 一对一聊天不显示名称，群聊功能上线后改为 true
              showAvatar: item.showAvatar,
              onRetry: (isMe && m.status == 'failed')
                  ? () => _showRetryDialog(context, m.id, actions)
                  : null,
              onLongPress: (bubbleKey) =>
                  _handleMessageLongPress(context, m, isMe, bubbleKey),
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
  ///
  /// [config] 消息格式化配置，用于分段显示
  List<_ListItem> _buildListItemsWithTimeDividers(
      [MessageFormatConfig? config]) {
    final List<_ListItem> items = [];
    final messages = widget.messages;
    final enableChunking = config?.enableChunking ?? true;

    for (int i = 0; i < messages.length; i++) {
      final currentMessage = messages[i];
      bool hasTimeDivider = false;

      if (i == 0) {
        items.add(_TimeDivider(currentMessage.createdAt));
        hasTimeDivider = true;
      } else {
        final previousMessage = messages[i - 1];
        final timeDiff =
            currentMessage.createdAt.difference(previousMessage.createdAt);

        if (timeDiff.inMinutes >= 20) {
          items.add(_TimeDivider(currentMessage.createdAt));
          hasTimeDivider = true;
        }
      }

      // 计算 showAvatar：本组第一条消息才显示头像
      // 条件：前面没有同发送者的消息（前面是不同发送者、时间分隔器、或是第一条消息）
      bool showAvatar = true;
      if (!hasTimeDivider && i > 0) {
        final previousMessage = messages[i - 1];
        if (previousMessage.role == currentMessage.role) {
          showAvatar = false;
        }
      }

      // 判断是否需要分段显示（仅对 AI 消息的纯文本内容进行分段）
      final isAssistant = currentMessage.role == 'assistant';
      final hasBlocks = currentMessage.blocks?.isNotEmpty ?? false;
      final shouldChunk = enableChunking &&
          isAssistant &&
          !hasBlocks &&
          currentMessage.content.isNotEmpty;

      if (shouldChunk && config != null) {
        // 对 AI 消息进行分段
        final chunks =
            MessageFormatter.formatAndChunkText(currentMessage.content, config);
        if (chunks.length > 1) {
          // 多个分段：每个分段作为独立的列表项
          for (int j = 0; j < chunks.length; j++) {
            bool showCorner = false;
            if (j < chunks.length - 1) {
              showCorner = true;
            } else {
              if (i + 1 < messages.length) {
                final nextMessage = messages[i + 1];
                if (nextMessage.role == currentMessage.role) {
                  final timeDiff = nextMessage.createdAt
                      .difference(currentMessage.createdAt);
                  if (timeDiff.inMinutes < 20) {
                    showCorner = true;
                  }
                }
              }
            }

            items.add(_ChunkedMessageItem(
              originalMessage: currentMessage,
              chunkText: chunks[j],
              chunkIndex: j,
              totalChunks: chunks.length,
              showCorner: showCorner,
              showAvatar: j == 0 && showAvatar, // 只有第一个分段且该消息是组首条才显示头像
            ));
          }
          continue;
        }
      }

      // 普通消息
      bool showCorner = false;
      if (i + 1 < messages.length) {
        final nextMessage = messages[i + 1];
        if (nextMessage.role == currentMessage.role) {
          final timeDiff =
              nextMessage.createdAt.difference(currentMessage.createdAt);
          if (timeDiff.inMinutes < 20) {
            showCorner = true;
          }
        }
      }

      items.add(_MessageItem(currentMessage,
          showCorner: showCorner, showAvatar: showAvatar));
    }

    return items;
  }

  /// 构建加载中指示器（用于分页加载时在顶部显示）
  Widget _buildLoadingIndicator() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  /// 构建时间分隔器Widget
  Widget _buildTimeDivider(BuildContext context, DateTime time) {
    final colors = context.moeColors;
    final timeStr = _formatChatTime(time);

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: MoeG2Decoration(
          radius: 12,
          color: colors.surfaceAlt,
        ),
        child: Text(
          timeStr,
          style: TextStyle(
            color: colors.muted,
            fontSize: 12,
            fontWeight: MoeFontWeights.normal,
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

  /// 处理消息长按事件
  Future<void> _handleMessageLongPress(BuildContext context, Message message,
      bool isMe, GlobalKey bubbleKey) async {
    await showMessageActionMenu(
      context,
      targetKey: bubbleKey,
      isUserMessage: isMe,
      messageText: message.displayText,
      onAction: (action) {
        if (!context.mounted) return;
        switch (action) {
          case MessageAction.copy:
            MoeToast.show(context, '已复制到剪贴板');
            break;
          case MessageAction.edit:
            widget.onEditMessage?.call(message);
            break;
          case MessageAction.regenerate:
            widget.onRegenerateMessage?.call(message);
            break;
          case MessageAction.quote:
            // 设置引用消息
            ref.read(quotedMessageProvider.notifier).state = QuotedMessage(
              id: message.id,
              content: message.displayText,
              isUser: isMe,
            );
            break;
        }
      },
    );
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

  /// 是否显示直角（连续消息组的开头且后面还有同发送者消息）
  final bool showCorner;

  /// 是否显示头像（连续消息组的第一条消息才显示）
  final bool showAvatar;

  _MessageItem(this.message, {this.showCorner = false, this.showAvatar = true});
}

/// 分段消息列表项（用于 UI 分段显示）
class _ChunkedMessageItem extends _ListItem {
  final Message originalMessage;
  final String chunkText;
  final int chunkIndex;
  final int totalChunks;

  /// 是否显示直角
  final bool showCorner;

  /// 是否显示头像（仅第一个分段的第一条才显示）
  final bool showAvatar;

  _ChunkedMessageItem({
    required this.originalMessage,
    required this.chunkText,
    required this.chunkIndex,
    required this.totalChunks,
    this.showCorner = false,
    this.showAvatar = true,
  });
}

/// 时间分隔器列表项
class _TimeDivider extends _ListItem {
  final DateTime time;
  _TimeDivider(this.time);
}
