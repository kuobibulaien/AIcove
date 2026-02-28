/// 聊天消息列表组件
///
/// 从 chat_page.dart 提取，负责显示消息列表和时间分隔器。
///
/// 更新记录：
/// - 2025-12-31: 从 chat_page.dart 提取
/// - 2026-01-28: 添加消息分段显示功能（纯前端展示）
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../../features/chat/providers2.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../../features/chat/presentation/widgets/message_action_sheet.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../ui/shared/widgets/media/moe_image_preview.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/models/message_block.dart';
import 'animated_message_item.dart';

const double _kMessageItemVerticalPadding = 2.0;

/// 消息列表组件
class ChatMessageList extends ConsumerStatefulWidget {
  final List<Message> messages;
  final String conversationId;
  final String? avatarUrl;
  final String displayName;
  final double bottomOverlayHeight;
  final void Function(Message message)? onEditMessage;
  final void Function(Message message)? onRegenerateMessage;
  final void Function(Message message)? onEnhanceRegenerateMessage;

  /// 上下文截断点消息ID（此消息之后为新话题）
  final String? contextStartMessageId;

  /// 分页加载：滑到顶部（历史消息方向）时触发
  final Future<void> Function()? onLoadMore;

  /// 是否正在加载更多
  final bool isLoadingMore;

  /// 是否还有更多历史消息可加载
  final bool hasMoreMessages;

  /// 是否启用自动回底（由上层显式控制）
  final bool autoScrollToBottomEnabled;

  /// 当用户手势接管滚动时回调（用于通知上层关闭自动回底）
  final VoidCallback? onAutoScrollDisabled;

  const ChatMessageList({
    super.key,
    required this.messages,
    required this.conversationId,
    this.avatarUrl,
    required this.displayName,
    this.bottomOverlayHeight = 0,
    this.onEditMessage,
    this.onRegenerateMessage,
    this.onEnhanceRegenerateMessage,
    this.contextStartMessageId,
    this.onLoadMore,
    this.isLoadingMore = false,
    this.hasMoreMessages = true,
    this.autoScrollToBottomEnabled = true,
    this.onAutoScrollDisabled,
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

  /// 缓存的聊天图片列表（画廊模式左右滑动切换）
  List<ImagePreviewItem> _cachedChatImages = [];

  /// 用于监听滚动位置，触发分页加载
  late final ScrollController _scrollController;

  /// 防止重复触发加载
  bool _isLoadingTriggered = false;

  /// 是否允许自动回到底部（用户手势滚动后会关闭）
  bool _autoScrollEnabled = true;

  /// 标记是否由代码触发滚动，避免把程序滚动误判为用户手势
  bool _isProgrammaticScroll = false;

  /// 首次进入会话时，确保列表定位到最新消息
  bool _didInitialBottomPosition = false;

  @override
  void initState() {
    super.initState();
    _autoScrollEnabled = widget.autoScrollToBottomEnabled;
    if (widget.messages.isNotEmpty) {
      _latestAnimatedAt = widget.messages.last.createdAt;
    }
    _updateListItems();

    // 初始化 ScrollController 并添加监听
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    if (_autoScrollEnabled && widget.messages.isNotEmpty) {
      _scheduleScrollToBottom();
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 滚动监听：当接近列表顶部（历史消息方向）时触发加载更多
  void _onScroll() {
    // 非反转列表：minScrollExtent(通常为0) 是历史消息方向的顶部
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    final currentScroll = position.pixels;

    // 距离顶部 200 像素时触发加载
    const threshold = 200.0;

    if (currentScroll <= threshold &&
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

  void _scheduleScrollToBottom({int retryFrames = 6}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_autoScrollEnabled) return;
      if (!_scrollController.hasClients) {
        if (retryFrames > 0) {
          _scheduleScrollToBottom(retryFrames: retryFrames - 1);
        }
        return;
      }
      final position = _scrollController.position;
      if (!position.hasContentDimensions) {
        if (retryFrames > 0) {
          _scheduleScrollToBottom(retryFrames: retryFrames - 1);
        }
        return;
      }
      _jumpToOffset(position.maxScrollExtent);
    });
  }

  void _ensureInitialBottomPosition() {
    if (_didInitialBottomPosition) return;
    if (!_autoScrollEnabled || widget.messages.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _didInitialBottomPosition) return;
      if (!_autoScrollEnabled || widget.messages.isEmpty) return;
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!position.hasContentDimensions) return;
      _jumpToOffset(position.maxScrollExtent);
      _didInitialBottomPosition = true;
    });
  }

  void _jumpToOffset(double target) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final clamped = target
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((position.pixels - clamped).abs() <= 0.5) return;

    _isProgrammaticScroll = true;
    _scrollController.jumpTo(clamped);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isProgrammaticScroll = false;
    });
  }

  double _distanceToBottom() {
    if (!_scrollController.hasClients) return double.infinity;
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return double.infinity;
    return position.maxScrollExtent - position.pixels;
  }

  bool _isNearBottom([double threshold = 56.0]) {
    return _distanceToBottom() <= threshold;
  }

  void _shiftViewportByOverlayDelta(double delta) {
    if (delta.abs() <= 0.5) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!position.hasContentDimensions) return;
      _jumpToOffset(position.pixels + delta);
    });
  }

  void _notifyAutoScrollDisabledDeferred() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onAutoScrollDisabled?.call();
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (_isProgrammaticScroll) return false;

    // 触摸拖拽开始：用户明确接管滚动，切静止态
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      if (_autoScrollEnabled) {
        _autoScrollEnabled = false;
        widget.onAutoScrollDisabled?.call();
      }
      return false;
    }

    // 非触摸接管（鼠标滚轮 / 触控板 / 惯性阶段）也应切静止态
    if (notification is UserScrollNotification) {
      if (notification.direction != ScrollDirection.idle &&
          _autoScrollEnabled) {
        _autoScrollEnabled = false;
        widget.onAutoScrollDisabled?.call();
      }
      return false;
    }
    return false;
  }

  void _updateListItems([MessageFormatConfig? config]) {
    _cachedFormatConfig = config;
    _cachedListItems = _buildListItemsWithTimeDividers(config);
    _cachedChatImages = _collectChatImages();
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);

    final resumeAutoScroll = !oldWidget.autoScrollToBottomEnabled &&
        widget.autoScrollToBottomEnabled;
    final overlayHeightDelta =
        widget.bottomOverlayHeight - oldWidget.bottomOverlayHeight;
    final overlayHeightChanged = overlayHeightDelta.abs() > 0.5;
    var shouldResumeAutoScroll = resumeAutoScroll;
    if (oldWidget.autoScrollToBottomEnabled !=
        widget.autoScrollToBottomEnabled) {
      _autoScrollEnabled = widget.autoScrollToBottomEnabled;
    }

    // 点击输入框时：若用户仍在历史中段，不应强制跳底。
    if (resumeAutoScroll && !_isNearBottom()) {
      _autoScrollEnabled = false;
      shouldResumeAutoScroll = false;
      _notifyAutoScrollDisabledDeferred();
    }

    // 会话切换：重置状态并更新列表项
    if (oldWidget.conversationId != widget.conversationId) {
      _pendingAnimationIds.clear();
      _latestAnimatedAt =
          widget.messages.isNotEmpty ? widget.messages.last.createdAt : null;
      _autoScrollEnabled = widget.autoScrollToBottomEnabled;
      _didInitialBottomPosition = false;
      _updateListItems(_cachedFormatConfig);
      _scheduleScrollToBottom();
      return;
    }

    final messagesChanged = widget.messages != oldWidget.messages;

    // 缓存优化：仅当消息列表引用变化时才重构列表项
    // 避免键盘弹出/收起导致 MediaQuery 变化进而触发全量重建 (Layout Thrashing)
    if (messagesChanged) {
      _updateListItems(_cachedFormatConfig);
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

    if (newMessages.isNotEmpty) {
      final newestTime = newMessages
          .map((m) => m.createdAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      _latestAnimatedAt = newestTime;
      if (_autoScrollEnabled) {
        setState(() {
          _pendingAnimationIds.addAll(newMessages.map((m) => m.id));
        });
      } else {
        // 用户在翻看历史时，不做新消息入场动画，避免与手势抢滚动焦点。
        _pendingAnimationIds.removeAll(newMessages.map((m) => m.id));
      }
    }

    if (shouldResumeAutoScroll ||
        (messagesChanged && _autoScrollEnabled) ||
        (overlayHeightChanged && _autoScrollEnabled)) {
      _scheduleScrollToBottom();
      return;
    }

    if (overlayHeightChanged && !_autoScrollEnabled) {
      // 阅读中段时，输入框升高应“顶走”当前窗口，而不是跳到底部。
      _shiftViewportByOverlayDelta(overlayHeightDelta);
    }
  }

  @override
  Widget build(BuildContext context) {
    final actions = ref.watch(chatActionsProvider);
    final settingsAsync = ref.watch(appSettingsProvider);
    final uiScale = settingsAsync
        .maybeWhen(
          data: (settings) => settings.uiScaleFactor
              .clamp(kMinUiScaleFactor, kMaxUiScaleFactor),
          orElse: () => 1.0,
        )
        .toDouble();
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom / uiScale;
    final safeBottom = MediaQuery.paddingOf(context).bottom / uiScale;
    final fallbackBottomPadding = safeBottom + 70 + keyboardInset;
    final listBottomPadding = widget.bottomOverlayHeight > 0
        ? widget.bottomOverlayHeight
        : fallbackBottomPadding;

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

    // 构建包含时间分隔器的列表项（非反转列表，时间顺序与数据一致）
    // 使用缓存的列表项，避免每次 build 重复计算
    final listItems = _cachedListItems;

    // 计算实际 itemCount：如果正在加载更多，顶部多显示一个加载指示器
    final itemCount = listItems.length + (widget.isLoadingMore ? 1 : 0);
    _ensureInitialBottomPosition();

    return NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: ListView.builder(
        controller: _scrollController, // 添加 ScrollController 用于分页触发
        reverse: false, // 非反转列表：上旧下新
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
          // 保证输入框上方始终是消息列表底部：
          // 常态预留 Composer 高度，键盘弹出时再叠加键盘高度。
          bottom: listBottomPadding,
        ),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          // 如果正在加载更多，第一项显示加载指示器（顶部）
          if (widget.isLoadingMore && index == 0) {
            return _buildLoadingIndicator();
          }

          final dataIndex = widget.isLoadingMore ? index - 1 : index;
          final item = listItems[dataIndex];

          if (item is _TimeDivider) {
            return _buildTimeDivider(context, item.time);
          } else if (item is _NewTopicDivider) {
            return _buildNewTopicDivider(context);
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
                chatImages: _cachedChatImages,
                onRetry: null, // 分段消息不支持重试
                onLongPress: (bubbleKey) =>
                    _handleMessageLongPress(context, m, isMe, bubbleKey),
                onMediaLongPress: (mediaKey, block) =>
                    _handleMediaLongPress(context, m, isMe, mediaKey, block),
              ),
            );

            // 只有第一个分段需要动画
            final shouldAnimate =
                item.chunkIndex == 0 && _pendingAnimationIds.contains(m.id);
            if (shouldAnimate) {
              _pendingAnimationIds.remove(m.id);
              return AnimatedMessageItem(
                key: ValueKey('${m.id}_chunk_${item.chunkIndex}'),
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
                chatImages: _cachedChatImages,
                onRetry: (isMe && m.status == 'failed')
                    ? () => actions.recallFailedMessage(m.id)
                    : null,
                onLongPress: (bubbleKey) =>
                    _handleMessageLongPress(context, m, isMe, bubbleKey),
                onMediaLongPress: (mediaKey, block) =>
                    _handleMediaLongPress(context, m, isMe, mediaKey, block),
              ),
            );

            final shouldAnimate = _pendingAnimationIds.contains(m.id);
            if (shouldAnimate) {
              _pendingAnimationIds.remove(m.id);
              return AnimatedMessageItem(
                key: ValueKey(m.id),
                child: bubbleWidget,
              );
            }
            return bubbleWidget;
          }

          return const SizedBox.shrink();
        },
      ),
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
          // 在截断点消息之后插入新话题分隔线（分段消息场景）
          if (widget.contextStartMessageId != null &&
              currentMessage.id == widget.contextStartMessageId) {
            items.add(_NewTopicDivider());
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

      // 在截断点消息之后插入新话题分隔线
      if (widget.contextStartMessageId != null &&
          currentMessage.id == widget.contextStartMessageId) {
        items.add(_NewTopicDivider());
      }
    }

    return items;
  }

  /// 从所有消息中收集图片/表情包，构建画廊预览列表
  /// heroTag 与 message_bubble.dart 中保持一致：image_{id} / sticker_{id}
  List<ImagePreviewItem> _collectChatImages() {
    final result = <ImagePreviewItem>[];
    for (final message in widget.messages) {
      final blocks = message.blocks;
      if (blocks == null) continue;
      for (final block in blocks) {
        final provider = _resolveImageProvider(block);
        if (provider == null) continue;
        final isSticker = block is EmojiBlock;
        final heroTag = isSticker ? 'sticker_${block.id}' : 'image_${block.id}';
        result.add(ImagePreviewItem(provider: provider, heroTag: heroTag));
      }
    }
    return result;
  }

  /// 根据 block 类型解析 ImageProvider（与 message_bubble 保持一致）
  static ImageProvider? _resolveImageProvider(MessageBlock block) {
    if (block is EmojiBlock) {
      final path = block.path.trim().replaceAll('\\', '/');
      if (path.isEmpty) return null;
      final isNetwork =
          path.startsWith('http://') || path.startsWith('https://');
      final isAsset =
          path.startsWith('assets/') || path.startsWith('packages/');
      if (isNetwork) return CachedNetworkImageProvider(path);
      if (isAsset) return AssetImage(path);
      final file = File(path);
      if (file.existsSync()) return FileImage(file);
      return null;
    }
    if (block is ImageBlock) {
      if (block.localPath != null && block.localPath!.isNotEmpty) {
        return FileImage(File(block.localPath!));
      }
      if (block.url != null && block.url!.isNotEmpty) {
        return CachedNetworkImageProvider(block.url!);
      }
      if (block.base64 != null && block.base64!.isNotEmpty) {
        final dataBytes =
            decodeDataImage('data:image/jpeg;base64,${block.base64}');
        if (dataBytes != null) return MemoryImage(dataBytes);
      }
      return null;
    }
    return null;
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

  /// 构建新话题分隔线Widget
  Widget _buildNewTopicDivider(BuildContext context) {
    final colors = context.moeColors;
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Container(
                  height: 0.5, color: colors.muted.withValues(alpha: 0.3)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                '以上为历史话题',
                style: TextStyle(
                  color: colors.muted,
                  fontSize: 11,
                  fontWeight: MoeFontWeights.normal,
                ),
              ),
            ),
            Expanded(
              child: Container(
                  height: 0.5, color: colors.muted.withValues(alpha: 0.3)),
            ),
          ],
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
    final actions = ref.read(chatActionsProvider);
    final enableEnhancedRegenerate = ref
            .read(appSettingsProvider)
            .valueOrNull
            ?.enhancedDialogueSettings
            .enabled ==
        true;
    await showMessageActionMenu(
      context,
      targetKey: bubbleKey,
      isUserMessage: isMe,
      messageText: message.displayText,
      showEnhanceRegenerate: enableEnhancedRegenerate,
      onAction: (action) async {
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
          case MessageAction.enhanceRegenerate:
            widget.onEnhanceRegenerateMessage?.call(message);
            break;
          case MessageAction.quote:
            // 设置引用消息
            ref.read(quotedMessageProvider.notifier).state = QuotedMessage(
              id: message.id,
              content: message.displayText,
              isUser: isMe,
            );
            break;
          case MessageAction.delete:
            if (message.status == 'sending') {
              MoeToast.show(context, '发送中的消息暂不可删除');
              break;
            }
            final ok = await showMeoTalkConfirm(
              context: context,
              title: '删除消息',
              message: '确定删除这条消息吗？',
              hint: '会从当前会话上下文和本地数据库中移除这条消息。',
              confirmText: '删除',
              isDanger: true,
            );
            if (ok == true && context.mounted) {
              await actions.deleteMessage(message.id);
              if (context.mounted) {
                MoeToast.show(context, '已删除消息');
              }
            }
            break;
          case MessageAction.save:
            break; // 文本消息不支持保存
        }
      },
    );
  }

  /// 处理媒体（图片/音频）长按或右键事件
  Future<void> _handleMediaLongPress(BuildContext context, Message message,
      bool isMe, GlobalKey mediaKey, MessageBlock block) async {
    final actions = ref.read(chatActionsProvider);
    final mediaType = block is AudioBlock ? MediaType.audio : MediaType.image;
    await showMediaActionMenu(
      context,
      targetKey: mediaKey,
      mediaType: mediaType,
      allowDelete: true,
      onAction: (action) async {
        if (!context.mounted) return;
        switch (action) {
          case MessageAction.save:
            _saveMediaBlock(context, block);
            break;
          case MessageAction.quote:
            final quoteText = block is ImageBlock
                ? '[图片]'
                : block is AudioBlock
                    ? '[语音]'
                    : '[媒体]';
            ref.read(quotedMessageProvider.notifier).state = QuotedMessage(
              id: message.id,
              content: quoteText,
              isUser: isMe,
            );
            break;
          case MessageAction.delete:
            if (message.status == 'sending') {
              MoeToast.show(context, '发送中的消息暂不可删除');
              break;
            }
            final ok = await showMeoTalkConfirm(
              context: context,
              title: '删除消息',
              message: '确定删除这条消息吗？',
              hint: '会从当前会话上下文和本地数据库中移除这条消息。',
              confirmText: '删除',
              isDanger: true,
            );
            if (ok == true && context.mounted) {
              await actions.deleteMessage(message.id);
              if (context.mounted) {
                MoeToast.show(context, '已删除消息');
              }
            }
            break;
          default:
            break;
        }
      },
    );
  }

  /// 保存媒体文件
  /// - Android 图片：自动保存到系统相册（带权限申请）
  /// - 其他场景：按平台保存（桌面选择路径，移动端使用系统保存面板）
  Future<void> _saveMediaBlock(BuildContext context, MessageBlock block) async {
    try {
      String? sourcePath;
      String defaultFileName;
      final isImage = block is ImageBlock;

      if (isImage) {
        sourcePath = block.localPath;
        // 如果没有本地路径但有 URL，用 URL 的文件名
        if (sourcePath == null || sourcePath.isEmpty) {
          if (block.url != null && block.url!.isNotEmpty) {
            // 网络图片：尝试从缓存目录取
            // CachedNetworkImage 使用 DefaultCacheManager，缓存路径不直接可知
            // 退回到提示用户在预览中长按保存
            if (context.mounted) {
              MoeToast.show(context, '网络图片请在预览中保存');
            }
            return;
          }
          if (block.base64 != null && block.base64!.isNotEmpty) {
            // base64 图片：写入临时文件再保存
            final tempDir = await getTemporaryDirectory();
            final tempFile = File(
                '${tempDir.path}/save_${DateTime.now().millisecondsSinceEpoch}.png');
            final bytes = _decodeBase64Image(block.base64!);
            if (bytes == null) {
              if (context.mounted) MoeToast.show(context, '图片数据无效');
              return;
            }
            await tempFile.writeAsBytes(bytes);
            sourcePath = tempFile.path;
          }
        }
        final ext = sourcePath != null
            ? sourcePath.split('.').last.toLowerCase()
            : 'png';
        defaultFileName = 'image_${DateTime.now().millisecondsSinceEpoch}.$ext';
      } else if (block is AudioBlock) {
        sourcePath = block.url;
        // AudioBlock.url 可能是本地路径
        final ext = sourcePath.split('.').last.toLowerCase();
        defaultFileName = 'audio_${DateTime.now().millisecondsSinceEpoch}.$ext';
      } else {
        return;
      }

      if (sourcePath == null || sourcePath.isEmpty) {
        if (context.mounted) MoeToast.show(context, '文件不存在');
        return;
      }

      final sourceFile = File(sourcePath);
      if (!sourceFile.existsSync()) {
        if (context.mounted) MoeToast.show(context, '文件不存在');
        return;
      }

      if (Platform.isAndroid && isImage) {
        final granted = await _ensureAndroidGalleryPermission();
        if (!context.mounted) return;
        if (!granted) {
          if (context.mounted) MoeToast.show(context, '未授予相册权限，无法保存');
          return;
        }

        final result = await ImageGallerySaverPlus.saveFile(
          sourceFile.path,
          name: defaultFileName,
        );
        if (_isGallerySaveSuccess(result)) {
          if (context.mounted) MoeToast.show(context, '已保存到相册');
        } else {
          if (context.mounted) MoeToast.show(context, '保存到相册失败');
        }
        return;
      }

      if (Platform.isAndroid || Platform.isIOS) {
        final bytes = await sourceFile.readAsBytes();
        final savePath = await FilePicker.platform.saveFile(
          dialogTitle: '保存文件',
          fileName: defaultFileName,
          bytes: bytes,
        );
        if (savePath == null) return;
        if (context.mounted) MoeToast.show(context, '已保存');
        return;
      }

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '保存文件',
        fileName: defaultFileName,
      );
      if (savePath == null) return; // 用户取消
      await sourceFile.copy(savePath);
      if (context.mounted) MoeToast.show(context, '已保存');
    } catch (e) {
      if (context.mounted) MoeToast.show(context, '保存失败: $e');
    }
  }

  Future<bool> _ensureAndroidGalleryPermission() async {
    final hasPermission = await _hasAndroidGalleryPermission();
    if (hasPermission) return true;
    if (!mounted) return false;

    final confirm = await showMeoTalkConfirm(
      context: context,
      title: '需要相册权限',
      message: '保存图片到系统相册需要相册访问权限。',
      hint: '授权后可直接将聊天图片保存到你的相册。',
      cancelText: '取消',
      confirmText: '去授权',
    );
    if (confirm != true) return false;

    final photosStatus = await Permission.photos.request();
    if (photosStatus.isGranted || photosStatus.isLimited) return true;

    final storageStatus = await Permission.storage.request();
    return storageStatus.isGranted;
  }

  Future<bool> _hasAndroidGalleryPermission() async {
    final photosStatus = await Permission.photos.status;
    if (photosStatus.isGranted || photosStatus.isLimited) return true;

    final storageStatus = await Permission.storage.status;
    return storageStatus.isGranted;
  }

  bool _isGallerySaveSuccess(dynamic result) {
    if (result is bool) return result;
    if (result is Map) {
      final success = result['isSuccess'] ?? result['success'];
      if (success is bool) return success;
      if (success is num) return success != 0;
    }
    return false;
  }

  /// 解码 base64 图片数据
  static List<int>? _decodeBase64Image(String base64Str) {
    try {
      return base64Decode(base64Str);
    } catch (_) {
      return null;
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

/// 新话题分隔线列表项
class _NewTopicDivider extends _ListItem {}
