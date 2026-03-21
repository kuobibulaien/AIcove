/// 聊天消息列表组件
///
/// 从 chat_page.dart 提取，负责显示消息列表和时间分隔器。
///
/// 更新记录：
/// - 2025-12-31: 从 chat_page.dart 提取
/// - 2026-01-28: 添加消息分段显示功能（纯前端展示）
library;

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/chat/chat_actions.dart';
import '../../../../features/chat/application/chat_message_list_queries.dart';
import '../../../../features/chat/conversation_timeline_providers.dart'
    show kConversationInitialVisibleCount;
import '../../../../features/chat/infrastructure/chat_message_list_snapshot_codec.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../../features/chat/presentation/widgets/message_action_sheet.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../ui/shared/widgets/media/moe_image_preview.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/models/message_block.dart';
import 'animated_message_item.dart';
import 'chat_message_list_display_cache.dart';
import 'chat_message_list_items.dart';
import 'chat_message_list_media_save.dart';
import 'chat_viewport_controller.dart';

const double _kMessageItemVerticalPadding = 2.0;
const String _kPersistentViewportSnapshotSignature = 'viewport_boot_v2';
const Duration _kHistoryLoadingOverlayMinDuration = Duration(milliseconds: 260);
const Duration _kTransientHandoffHoldDuration = Duration(milliseconds: 220);
const double _kHistoryPagingTopFrictionBase = 0.05;
const int _kPersistentSnapshotTurnCount = kConversationInitialVisibleCount;
const double _kJumpToBottomVisibilityThreshold = 120.0;
const double _kJumpToBottomButtonSize = 44.0;

typedef PersistentSnapshotWindow = ChatMessageListPersistentSnapshotWindow;
typedef LoadPersistentSnapshotOlderPage = LoadChatMessageListOlderPage;

class _TimelineSplitBoundary {
  const _TimelineSplitBoundary({
    required this.messageId,
    required this.createdAt,
  });

  final String messageId;
  final DateTime createdAt;
}

enum _ChatListSectionPlacement {
  history,
  active,
}

class _ChatListSections {
  const _ChatListSections({
    required this.historyItems,
    required this.activeItems,
  });

  final List<ChatMessageListItem> historyItems;
  final List<ChatMessageListItem> activeItems;

  int get itemCount => historyItems.length + activeItems.length;
}

@visibleForTesting
Future<PersistentSnapshotWindow> resolvePersistentSnapshotWindow({
  required List<Message> currentMessages,
  required bool hasMoreMessages,
  required LoadPersistentSnapshotOlderPage loadOlderPage,
  int targetTurnCount = _kPersistentSnapshotTurnCount,
}) {
  return resolveChatMessageListPersistentSnapshotWindow(
    currentMessages: currentMessages,
    hasMoreMessages: hasMoreMessages,
    loadOlderPage: loadOlderPage,
    targetTurnCount: targetTurnCount,
  );
}

class _ChatHistoryPagingScrollPhysics extends BouncingScrollPhysics {
  const _ChatHistoryPagingScrollPhysics({
    super.parent,
    this.topOverscrollFrictionBase = _kHistoryPagingTopFrictionBase,
  });

  final double topOverscrollFrictionBase;

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(
        mass: 0.45,
        stiffness: 220.0,
        ratio: 1.18,
      );

  @override
  _ChatHistoryPagingScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return _ChatHistoryPagingScrollPhysics(
      parent: buildParent(ancestor),
      topOverscrollFrictionBase: topOverscrollFrictionBase,
    );
  }

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    assert(offset != 0.0);
    assert(position.minScrollExtent <= position.maxScrollExtent);

    if (!position.outOfRange) {
      return offset;
    }

    final overscrollPastStart = math.max(
      position.minScrollExtent - position.pixels,
      0.0,
    );
    final overscrollPastEnd = math.max(
      position.pixels - position.maxScrollExtent,
      0.0,
    );
    final overscrollPast = math.max(overscrollPastStart, overscrollPastEnd);
    final easing = (overscrollPastStart > 0.0 && offset < 0.0) ||
        (overscrollPastEnd > 0.0 && offset > 0.0);
    final overscrollFraction = position.viewportDimension == 0
        ? 0.0
        : ((easing
                    ? math.max(overscrollPast - offset.abs(), 0.0)
                    : overscrollPast) /
                position.viewportDimension)
            .clamp(0.0, 1.0)
            .toDouble();

    final friction = overscrollPastEnd > 0.0
        ? _topFrictionFactor(overscrollFraction)
        : frictionFactor(overscrollFraction);
    final direction = offset.sign;

    if (easing && decelerationRate == ScrollDecelerationRate.fast) {
      return direction * offset.abs();
    }

    return direction *
        _applyCustomFriction(overscrollPast, offset.abs(), friction);
  }

  double _topFrictionFactor(double overscrollFraction) {
    return topOverscrollFrictionBase *
        math.pow(1 - overscrollFraction, 2).toDouble();
  }

  static double _applyCustomFriction(
    double extentOutside,
    double absDelta,
    double gamma,
  ) {
    var total = 0.0;
    if (extentOutside > 0) {
      final deltaToLimit = extentOutside / gamma;
      if (absDelta < deltaToLimit) {
        return absDelta * gamma;
      }
      total += extentOutside;
      absDelta -= deltaToLimit;
    }
    return total + absDelta;
  }
}

class _ChatMessageListScrollBehavior extends ScrollBehavior {
  const _ChatMessageListScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const AlwaysScrollableScrollPhysics();
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

/// 消息列表组件
class ChatMessageList extends ConsumerStatefulWidget {
  final List<Message> messages;
  final List<Message> transientMessages;
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

  /// 统一管理聊天视窗控制权的控制器。
  final ChatViewportController viewportController;

  /// 首进聊天页时允许只用持久快照渲染首屏，先不读取数据库消息窗口。
  final bool allowPersistentViewportBoot;

  /// 持久快照不可用时通知上层切回真实数据库时间线。
  final VoidCallback? onPersistentViewportBootMiss;

  /// 持久快照恢复后把“是否还有更早历史”回传给上层。
  final ValueChanged<bool>? onPersistentViewportHasMoreResolved;

  /// 持久快照恢复后把“当前缓存窗口轮次数”回传给上层。
  final ValueChanged<int>? onPersistentViewportVisibleCountResolved;

  /// 当前会话摘要，用于校验持久快照是否仍然匹配当前会话。
  final String? expectedLastMessagePreview;
  final DateTime? expectedLastMessageTime;

  @visibleForTesting
  final ValueChanged<int>? onDebugListItemCountChanged;

  @visibleForTesting
  final ValueChanged<String>? onDebugAutoScrollRequested;

  const ChatMessageList({
    super.key,
    required this.messages,
    this.transientMessages = const <Message>[],
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
    required this.viewportController,
    this.allowPersistentViewportBoot = false,
    this.onPersistentViewportBootMiss,
    this.onPersistentViewportHasMoreResolved,
    this.onPersistentViewportVisibleCountResolved,
    this.expectedLastMessagePreview,
    this.expectedLastMessageTime,
    this.onDebugListItemCountChanged,
    this.onDebugAutoScrollRequested,
  });

  @override
  ConsumerState<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends ConsumerState<ChatMessageList> {
  final Set<String> _pendingAnimationIds = <String>{};
  final Map<String, GlobalKey> _bubbleAnchorKeys = <String, GlobalKey>{};
  final GlobalKey _listViewportKey =
      GlobalKey(debugLabel: 'chat_message_list_viewport');
  final Key _centerKey = const ValueKey<String>('chat_message_list_center');
  DateTime? _latestAnimatedAt;
  List<ChatMessageListItem> _cachedListItems = [];
  _TimelineSplitBoundary? _detachedSplitBoundary;

  /// 缓存的消息格式化配置（用于检测配置变化）
  MessageFormatConfig? _cachedFormatConfig;

  /// 缓存的聊天图片列表（画廊模式左右滑动切换）
  List<ImagePreviewItem> _cachedChatImages = [];
  List<Message> _bootSnapshotMessages = const [];

  /// 用于监听滚动位置，触发分页加载
  late final ScrollController _scrollController;

  /// 防止重复触发加载
  bool _isLoadingTriggered = false;

  /// 标记是否由代码触发滚动，避免把程序滚动误判为用户手势
  bool _isProgrammaticScroll = false;

  int _handledViewportScrollRequestSerial = 0;
  bool _lastViewportShouldFollowLatest = true;

  /// 首次进入会话时，确保列表定位到最新消息
  bool _didInitialBottomPosition = false;
  double _manualDetachedDistanceToBottom = 0;

  bool _hasHydratedInitialListItems = false;
  int _hydrationGeneration = 0;
  int _persistentSnapshotPersistGeneration = 0;
  bool _showHistoryLoadingOverlay = false;
  DateTime? _historyLoadingOverlayShownAt;
  Timer? _historyLoadingOverlayHideTimer;
  Set<String> _pendingTransientHandoffIds = <String>{};
  Timer? _transientHandoffHoldTimer;

  List<Message> get _stableMessages {
    if (widget.messages.isNotEmpty) {
      return widget.messages;
    }
    if (_bootSnapshotMessages.isNotEmpty) {
      return _bootSnapshotMessages;
    }
    return const <Message>[];
  }

  List<Message> get _currentTimelineMessages => _mergeTimelineMessages(
        _stableMessages,
        widget.transientMessages,
      );

  bool get _hasTransientTimelineContent => widget.transientMessages.isNotEmpty;

  bool get _hasTimelineContent => _currentTimelineMessages.isNotEmpty;

  bool get _autoScrollEnabled => widget.viewportController.shouldFollowLatest;

  void _bindViewportController(ChatViewportController controller) {
    _handledViewportScrollRequestSerial =
        controller.scrollToBottomRequestSerial;
    _lastViewportShouldFollowLatest = controller.shouldFollowLatest;
    controller.addListener(_handleViewportControllerChanged);
  }

  void _unbindViewportController(ChatViewportController controller) {
    controller.removeListener(_handleViewportControllerChanged);
  }

  void _handleViewportControllerChanged() {
    if (!mounted) return;
    final nextSerial = widget.viewportController.scrollToBottomRequestSerial;
    final shouldRequestScroll =
        nextSerial != _handledViewportScrollRequestSerial;
    final shouldFollowLatest = widget.viewportController.shouldFollowLatest;
    final followLatestChanged =
        _lastViewportShouldFollowLatest != shouldFollowLatest;
    _handledViewportScrollRequestSerial = nextSerial;
    _lastViewportShouldFollowLatest = shouldFollowLatest;
    if (shouldRequestScroll) {
      _requestScrollToBottom('viewportController');
    }
    if (followLatestChanged) {
      if (shouldFollowLatest) {
        _clearDetachedSplitBoundary();
        _resetManualDetachedDistanceToBottom();
      } else {
        _captureDetachedSplitBoundary();
        setState(() {});
      }
    }
  }

  List<Message> _mergeTimelineMessages(
    List<Message> stableMessages,
    List<Message> transientMessages,
  ) {
    if (stableMessages.isEmpty && transientMessages.isEmpty) {
      return const <Message>[];
    }
    final merged = <String, Message>{
      for (final message in transientMessages) message.id: message,
      for (final message in stableMessages) message.id: message,
    };
    final timeline = merged.values.toList(growable: false)
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        return a.id.compareTo(b.id);
      });
    return timeline;
  }

  @override
  void initState() {
    super.initState();
    _bindViewportController(widget.viewportController);
    _showHistoryLoadingOverlay = widget.isLoadingMore && widget.hasMoreMessages;
    if (_showHistoryLoadingOverlay) {
      _historyLoadingOverlayShownAt = DateTime.now();
    }
    if (_currentTimelineMessages.isNotEmpty) {
      _latestAnimatedAt = _currentTimelineMessages.last.createdAt;
    }
    _hydrateInitialListItems();

    // 滚动控制只保留“用户手势优先 + 软跟随”语义，不再做像素补偿。
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    if (_autoScrollEnabled && _hasTimelineContent) {
      _requestScrollToBottom('initState');
    }
  }

  @override
  void dispose() {
    _unbindViewportController(widget.viewportController);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _historyLoadingOverlayHideTimer?.cancel();
    _transientHandoffHoldTimer?.cancel();
    super.dispose();
  }

  void _hydrateInitialListItems([MessageFormatConfig? config]) {
    final effectiveConfig =
        config ?? _cachedFormatConfig ?? const MessageFormatConfig();
    final sourceMessages = _stableMessages;
    final windowSignature = _buildWindowSignature(
      sourceMessages,
      contextStartMessageId: widget.contextStartMessageId,
    );
    final formatSignature = _buildFormatSignature(effectiveConfig);
    final cached = ChatMessageListDisplayCache.read(
      conversationId: widget.conversationId,
      windowSignature: windowSignature,
      formatSignature: formatSignature,
    );
    if (cached != null) {
      _applyDisplayCacheEntry(cached, effectiveConfig);
      return;
    }

    if (sourceMessages.isEmpty && widget.allowPersistentViewportBoot) {
      _hydrateViewportBootSnapshot(effectiveConfig, formatSignature);
      return;
    }

    if (!_shouldRestorePersistentSnapshot()) {
      _updateListItems(effectiveConfig);
      return;
    }

    final generation = ++_hydrationGeneration;
    ChatMessageListDisplayCache.readPersistent(
      conversationId: widget.conversationId,
      windowSignature: _kPersistentViewportSnapshotSignature,
      formatSignature: formatSignature,
    ).then((snapshot) {
      if (!mounted || generation != _hydrationGeneration) {
        return;
      }

      final restored = snapshot == null
          ? null
          : deserializeChatMessageListSnapshot(
              snapshot.listItems,
              liveMessages: sourceMessages,
            );
      if (restored != null &&
          chatMessageListSnapshotMatchesTimelineTail(
            restored,
            sourceMessages,
          )) {
        final restoredEntry = ChatMessageListDisplayCacheEntry(
          windowSignature: windowSignature,
          formatSignature: formatSignature,
          listItems: restored.items.cast<Object>(),
          chatImages: collectChatMessageListImages(restored.messages),
        );
        setState(() {
          _bootSnapshotMessages = const [];
          _applyDisplayCacheEntry(restoredEntry, effectiveConfig);
        });
        _dispatchPersistentViewportResolution(restored);
        return;
      }

      if (!mounted || generation != _hydrationGeneration) {
        return;
      }

      setState(() {
        _updateListItems(effectiveConfig);
      });
    });
  }

  void _hydrateViewportBootSnapshot(
    MessageFormatConfig effectiveConfig,
    String formatSignature,
  ) {
    final inMemoryBootSnapshot = ChatMessageListDisplayCache.read(
      conversationId: widget.conversationId,
      windowSignature: _kPersistentViewportSnapshotSignature,
      formatSignature: formatSignature,
    );
    final inMemoryRawItems = inMemoryBootSnapshot == null
        ? null
        : normalizeChatMessageListSnapshotRawItems(
            inMemoryBootSnapshot.listItems,
          );
    final restoredFromMemory = inMemoryRawItems == null
        ? null
        : deserializeChatMessageListSnapshot(
            inMemoryRawItems,
            liveMessages: _stableMessages,
          );
    if (restoredFromMemory != null &&
        chatMessageListSnapshotMatchesExpected(
          restoredFromMemory,
          expectedLastMessagePreview: widget.expectedLastMessagePreview,
          expectedLastMessageTime: widget.expectedLastMessageTime,
        )) {
      _applyViewportBootSnapshot(
        restoredFromMemory,
        effectiveConfig,
        formatSignature,
      );
      return;
    }
    if (restoredFromMemory == null && inMemoryBootSnapshot != null) {
      _dispatchPersistentViewportBootMiss();
      return;
    }

    final generation = ++_hydrationGeneration;
    ChatMessageListDisplayCache.readPersistent(
      conversationId: widget.conversationId,
      windowSignature: _kPersistentViewportSnapshotSignature,
      formatSignature: formatSignature,
    ).then((snapshot) {
      if (!mounted || generation != _hydrationGeneration) {
        return;
      }

      final restored = snapshot == null
          ? null
          : deserializeChatMessageListSnapshot(
              snapshot.listItems,
              liveMessages: _stableMessages,
            );
      if (restored == null ||
          !chatMessageListSnapshotMatchesExpected(
            restored,
            expectedLastMessagePreview: widget.expectedLastMessagePreview,
            expectedLastMessageTime: widget.expectedLastMessageTime,
          )) {
        _dispatchPersistentViewportBootMiss();
        return;
      }

      setState(() {
        _applyViewportBootSnapshot(
          restored,
          effectiveConfig,
          formatSignature,
        );
      });
    });
  }

  void _applyViewportBootSnapshot(
    ChatMessageListSnapshotData restored,
    MessageFormatConfig effectiveConfig,
    String formatSignature,
  ) {
    final windowSignature = _buildWindowSignature(
      restored.messages,
      contextStartMessageId: widget.contextStartMessageId,
    );
    final restoredEntry = ChatMessageListDisplayCacheEntry(
      windowSignature: windowSignature,
      formatSignature: formatSignature,
      listItems: restored.items.cast<Object>(),
      chatImages: collectChatMessageListImages(restored.messages),
    );
    _bootSnapshotMessages = restored.messages;
    _latestAnimatedAt = restored.messages.isNotEmpty
        ? restored.messages.last.createdAt
        : _latestAnimatedAt;
    _applyDisplayCacheEntry(restoredEntry, effectiveConfig);
    _dispatchPersistentViewportResolution(restored);
  }

  void _dispatchPersistentViewportResolution(
      ChatMessageListSnapshotData restored) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onPersistentViewportVisibleCountResolved
          ?.call(restored.visibleTurnCount);
      widget.onPersistentViewportHasMoreResolved
          ?.call(restored.hasMoreMessages);
    });
  }

  void _dispatchPersistentViewportBootMiss() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onPersistentViewportBootMiss?.call();
    });
  }

  void _applyDisplayCacheEntry(
    ChatMessageListDisplayCacheEntry cached,
    MessageFormatConfig config,
  ) {
    _cachedFormatConfig = config;
    _cachedListItems = cached.listItems.cast<ChatMessageListItem>();
    _cachedChatImages = List<ImagePreviewItem>.from(cached.chatImages);
    _hasHydratedInitialListItems = true;
    _cleanupBubbleAnchorKeys();
  }

  bool _shouldRestorePersistentSnapshot() {
    final sourceMessages = _stableMessages;
    return sourceMessages.isNotEmpty &&
        countChatMessageListConversationTurns(sourceMessages) <=
            kConversationInitialVisibleCount &&
        !_hasTransientTimelineContent;
  }

  /// 滚动监听：当接近列表顶部（历史消息方向）时触发加载更多
  void _onScroll() {
    // 反转列表：maxScrollExtent 是历史消息方向的顶部
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    final currentScroll = position.pixels;

    // 距离顶部 200 像素时触发加载
    const threshold = 200.0;

    if (currentScroll >= position.maxScrollExtent - threshold &&
        position.maxScrollExtent > threshold &&
        !_isLoadingTriggered &&
        !widget.isLoadingMore &&
        widget.hasMoreMessages &&
        widget.onLoadMore != null) {
      _lockAutoScrollForHistoryPaging('historyPagingThresholdReached');
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
      _jumpToOffset(position.minScrollExtent);
    });
  }

  void _debugAutoScroll(String message) {
    assert(() {
      debugPrint('[ChatMessageList:auto-scroll] $message');
      return true;
    }());
  }

  void _requestScrollToBottom(String reason) {
    _debugAutoScroll('request:$reason');
    widget.onDebugAutoScrollRequested?.call(reason);
    _scheduleScrollToBottom();
  }

  void _captureDetachedSplitBoundary() {
    if (_detachedSplitBoundary != null || _currentTimelineMessages.isEmpty) {
      return;
    }
    final tail = _currentTimelineMessages.last;
    setState(() {
      _detachedSplitBoundary = _TimelineSplitBoundary(
        messageId: tail.id,
        createdAt: tail.createdAt,
      );
    });
  }

  void _clearDetachedSplitBoundary() {
    if (_detachedSplitBoundary == null) {
      return;
    }
    setState(() {
      _detachedSplitBoundary = null;
    });
  }

  String _listItemStableKey(ChatMessageListItem item) {
    if (item is ChatMessageItem) {
      return 'message:${item.message.id}';
    }
    if (item is ChatChunkedMessageItem) {
      return 'chunk:${item.originalMessage.id}:${item.chunkIndex}';
    }
    if (item is ChatTimeDividerItem) {
      return 'time:${item.time.millisecondsSinceEpoch}';
    }
    return 'topic:${widget.contextStartMessageId ?? 'default'}';
  }

  int? _findChildIndexForKey(
    Key key,
    List<ChatMessageListItem> items, {
    required bool reverseForViewport,
  }) {
    if (key is! ValueKey<String>) return null;
    final targetKey = key.value;
    for (var index = 0; index < items.length; index++) {
      final item =
          reverseForViewport ? items[items.length - 1 - index] : items[index];
      if (_listItemStableKey(item) == targetKey) {
        return index;
      }
    }
    return null;
  }

  String? _messageIdForListItem(ChatMessageListItem item) {
    if (item is ChatMessageItem) {
      return item.message.id;
    }
    if (item is ChatChunkedMessageItem) {
      return item.originalMessage.id;
    }
    return null;
  }

  int? _resolveActiveBoundaryIndex(List<Message> timelineMessages) {
    if (timelineMessages.isEmpty) return null;
    if (_detachedSplitBoundary == null) {
      return timelineMessages.length - 1;
    }
    final boundary = _detachedSplitBoundary!;
    final exactIndex = timelineMessages.indexWhere(
      (message) => message.id == boundary.messageId,
    );
    if (exactIndex >= 0) {
      return exactIndex;
    }
    final fallbackIndex = timelineMessages.indexWhere(
      (message) => !message.createdAt.isBefore(boundary.createdAt),
    );
    if (fallbackIndex >= 0) {
      return fallbackIndex;
    }
    return timelineMessages.length - 1;
  }

  _ChatListSections _splitListItems(
    List<ChatMessageListItem> items,
    List<Message> timelineMessages,
  ) {
    if (items.isEmpty) {
      return const _ChatListSections(
        historyItems: <ChatMessageListItem>[],
        activeItems: <ChatMessageListItem>[],
      );
    }

    final boundaryIndex = _resolveActiveBoundaryIndex(timelineMessages);
    if (boundaryIndex == null) {
      return const _ChatListSections(
        historyItems: <ChatMessageListItem>[],
        activeItems: <ChatMessageListItem>[],
      );
    }

    final activeIds = timelineMessages
        .skip(boundaryIndex)
        .map((message) => message.id)
        .toSet();
    if (activeIds.isEmpty) {
      return _ChatListSections(
        historyItems: items,
        activeItems: const <ChatMessageListItem>[],
      );
    }
    if (activeIds.length == timelineMessages.length) {
      return _ChatListSections(
        historyItems: const <ChatMessageListItem>[],
        activeItems: items,
      );
    }

    final historyItems = <ChatMessageListItem>[];
    final activeItems = <ChatMessageListItem>[];
    final pendingItems = <ChatMessageListItem>[];
    _ChatListSectionPlacement? lastPlacement;

    for (final item in items) {
      final messageId = _messageIdForListItem(item);
      if (messageId == null) {
        pendingItems.add(item);
        continue;
      }
      final placement = activeIds.contains(messageId)
          ? _ChatListSectionPlacement.active
          : _ChatListSectionPlacement.history;
      final target = placement == _ChatListSectionPlacement.active
          ? activeItems
          : historyItems;
      if (pendingItems.isNotEmpty) {
        target.addAll(pendingItems);
        pendingItems.clear();
      }
      target.add(item);
      lastPlacement = placement;
    }

    if (pendingItems.isNotEmpty) {
      final target = lastPlacement == _ChatListSectionPlacement.active
          ? activeItems
          : historyItems;
      target.addAll(pendingItems);
    }

    return _ChatListSections(
      historyItems: historyItems,
      activeItems: activeItems,
    );
  }

  bool get _historyPagingLockActive =>
      widget.isLoadingMore || _isLoadingTriggered;

  void _lockAutoScrollForHistoryPaging(String reason) {
    if (!_autoScrollEnabled) return;
    _debugAutoScroll('lock:$reason');
    _captureDetachedSplitBoundary();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.viewportController.onHistoryPagingStarted();
    });
  }

  void _ensureInitialBottomPosition() {
    if (_didInitialBottomPosition) return;
    if (!_autoScrollEnabled || !_hasTimelineContent) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _didInitialBottomPosition) return;
      if (!_autoScrollEnabled || !_hasTimelineContent) return;
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!position.hasContentDimensions) return;
      _jumpToOffset(position.minScrollExtent);
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
    return position.pixels - position.minScrollExtent;
  }

  bool _shouldShowJumpToBottomButton() {
    if (!widget.viewportController.isDetached || !_hasTimelineContent) {
      return false;
    }
    return _manualDetachedDistanceToBottom >= _kJumpToBottomVisibilityThreshold;
  }

  void _updateManualDetachedDistanceToBottom() {
    if (!_scrollController.hasClients || _isProgrammaticScroll) {
      return;
    }
    final nextDistance = _distanceToBottom();
    if (!nextDistance.isFinite ||
        (nextDistance - _manualDetachedDistanceToBottom).abs() <= 0.5) {
      return;
    }
    setState(() {
      _manualDetachedDistanceToBottom = nextDistance;
    });
  }

  void _resetManualDetachedDistanceToBottom() {
    if (_manualDetachedDistanceToBottom.abs() <= 0.5) {
      return;
    }
    setState(() {
      _manualDetachedDistanceToBottom = 0;
    });
  }

  void _lockAutoScrollForUserInterruption(String reason) {
    _isProgrammaticScroll = false;
    if (!_autoScrollEnabled) return;
    _debugAutoScroll('lock:$reason');
    _captureDetachedSplitBoundary();
    widget.viewportController.onUserGesture();
  }

  void _syncHistoryLoadingOverlay() {
    final shouldShow = widget.isLoadingMore && widget.hasMoreMessages;
    _historyLoadingOverlayHideTimer?.cancel();
    _historyLoadingOverlayHideTimer = null;

    if (shouldShow) {
      _showHistoryLoadingOverlay = true;
      _historyLoadingOverlayShownAt = DateTime.now();
      return;
    }

    if (!_showHistoryLoadingOverlay) {
      _historyLoadingOverlayShownAt = null;
      return;
    }

    final shownAt = _historyLoadingOverlayShownAt;
    final remaining = shownAt == null
        ? Duration.zero
        : _kHistoryLoadingOverlayMinDuration -
            DateTime.now().difference(shownAt);
    if (remaining <= Duration.zero) {
      _showHistoryLoadingOverlay = false;
      _historyLoadingOverlayShownAt = null;
      return;
    }

    _historyLoadingOverlayHideTimer = Timer(remaining, () {
      if (!mounted) return;
      setState(() {
        _showHistoryLoadingOverlay = false;
        _historyLoadingOverlayShownAt = null;
        _historyLoadingOverlayHideTimer = null;
      });
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    // 触摸拖拽开始：用户明确接管滚动，切静止态
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _lockAutoScrollForUserInterruption('userDragStart');
      _updateManualDetachedDistanceToBottom();
      return false;
    }

    // 若首个拖拽开始通知被程序滚动抢掉，后续拖拽更新/触边拖拽仍应能接管列表。
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _lockAutoScrollForUserInterruption('userDragUpdate');
      _updateManualDetachedDistanceToBottom();
      return false;
    }

    if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      _lockAutoScrollForUserInterruption('userDragOverscroll');
      _updateManualDetachedDistanceToBottom();
      return false;
    }

    // 非触摸接管（鼠标滚轮 / 触控板 / 惯性阶段）也应切静止态
    if (notification is UserScrollNotification) {
      if (notification.direction != ScrollDirection.idle) {
        _lockAutoScrollForUserInterruption('userScrollDirectionChanged');
        _updateManualDetachedDistanceToBottom();
      }
      return false;
    }

    if (notification is ScrollEndNotification && !_isProgrammaticScroll) {
      _updateManualDetachedDistanceToBottom();
      return false;
    }

    if (_isProgrammaticScroll) return false;

    return false;
  }

  void _updateListItems([MessageFormatConfig? config]) {
    final effectiveConfig =
        config ?? _cachedFormatConfig ?? const MessageFormatConfig();
    final stableMessages = _stableMessages;
    final timelineMessages = _currentTimelineMessages;
    final windowSignature = _buildWindowSignature(
      stableMessages,
      contextStartMessageId: widget.contextStartMessageId,
    );
    final formatSignature = _buildFormatSignature(effectiveConfig);
    if (!_hasTransientTimelineContent) {
      final cached = ChatMessageListDisplayCache.read(
        conversationId: widget.conversationId,
        windowSignature: windowSignature,
        formatSignature: formatSignature,
      );
      if (cached != null) {
        _applyDisplayCacheEntry(cached, effectiveConfig);
        return;
      }
    }

    _cachedFormatConfig = effectiveConfig;
    _cachedListItems = buildChatMessageListItems(
      messages: timelineMessages,
      config: effectiveConfig,
      contextStartMessageId: widget.contextStartMessageId,
    );
    _cachedChatImages = collectChatMessageListImages(timelineMessages);
    _hasHydratedInitialListItems = true;
    if (!_hasTransientTimelineContent) {
      ChatMessageListDisplayCache.write(
        conversationId: widget.conversationId,
        windowSignature: windowSignature,
        formatSignature: formatSignature,
        listItems: _cachedListItems.cast<Object>(),
        chatImages: _cachedChatImages,
      );
    }
    if (widget.messages.isNotEmpty && !_hasTransientTimelineContent) {
      unawaited(_persistRecentMessagesSnapshot(effectiveConfig));
    }
    _cleanupBubbleAnchorKeys();
  }

  String _buildWindowSignature(
    List<Message> messages, {
    String? contextStartMessageId,
  }) {
    if (messages.isEmpty) return 'empty';
    final buffer = StringBuffer()
      ..write(messages.length)
      ..write('|context=')
      ..write(contextStartMessageId ?? '');
    for (final message in messages) {
      final blocks = message.blocks;
      buffer
        ..write('|')
        ..write(message.id)
        ..write('@')
        ..write(message.createdAt.millisecondsSinceEpoch)
        ..write('#')
        ..write(message.status ?? 'sent')
        ..write('#')
        ..write(message.role)
        ..write('#')
        ..write(message.content)
        ..write('#')
        ..write(blocks?.length ?? 0);
      if (blocks != null && blocks.isNotEmpty) {
        for (final block in blocks) {
          buffer
            ..write(':')
            ..write(block.runtimeType)
            ..write('=')
            ..write(block.id);
        }
      }
    }
    return buffer.toString();
  }

  Future<void> _persistRecentMessagesSnapshot(
      MessageFormatConfig effectiveConfig) async {
    final persistGeneration = ++_persistentSnapshotPersistGeneration;
    final snapshotWindow = await resolveChatMessageListPersistentSnapshotWindow(
      currentMessages: List<Message>.from(widget.messages, growable: false),
      hasMoreMessages: widget.hasMoreMessages,
      targetTurnCount: _kPersistentSnapshotTurnCount,
      loadOlderPage: ({
        required DateTime beforeCreatedAt,
        required String beforeId,
        required int limit,
      }) {
        return ref.read(chatMessageListQueriesProvider).loadMessagesBefore(
              conversationId: widget.conversationId,
              beforeCreatedAt: beforeCreatedAt,
              beforeId: beforeId,
              limit: limit,
            );
      },
    );
    if (!mounted || persistGeneration != _persistentSnapshotPersistGeneration) {
      return;
    }

    final recentMessages = snapshotWindow.messages;
    if (recentMessages.isEmpty) {
      return;
    }

    final listItems = buildChatMessageListItems(
      messages: recentMessages,
      config: effectiveConfig,
      contextStartMessageId: widget.contextStartMessageId,
    );
    final serializedSnapshot = serializeChatMessageListSnapshot(
      listItems: listItems,
      sourceMessages: recentMessages,
      visibleTurnCount: countChatMessageListConversationTurns(widget.messages),
      hasMoreMessages: snapshotWindow.hasMoreMessages,
    );
    ChatMessageListDisplayCache.write(
      conversationId: widget.conversationId,
      windowSignature: _kPersistentViewportSnapshotSignature,
      formatSignature: _buildFormatSignature(effectiveConfig),
      listItems: serializedSnapshot.cast<Object>(),
      chatImages: const <ImagePreviewItem>[],
    );
    await ChatMessageListDisplayCache.writePersistent(
      conversationId: widget.conversationId,
      windowSignature: _kPersistentViewportSnapshotSignature,
      formatSignature: _buildFormatSignature(effectiveConfig),
      listItems: serializedSnapshot,
    );
  }

  String _buildFormatSignature(MessageFormatConfig config) {
    final activePunctuations = config.effectiveChunkPunctuations.join(',');
    final filterPunctuations = config.filterPunctuations.join(',');
    return [
      config.enableChunking,
      config.filterPunctuation,
      activePunctuations,
      filterPunctuations,
      config.minSegmentLength,
      config.protectQuotes,
    ].join('|');
  }

  GlobalKey _bubbleAnchorKeyFor(String messageId) {
    return _bubbleAnchorKeys.putIfAbsent(
      messageId,
      () => GlobalKey(debugLabel: 'bubble_$messageId'),
    );
  }

  String _chunkBubbleAnchorId(String messageId, int chunkIndex) =>
      '${messageId}_chunk_anchor_$chunkIndex';

  void _cleanupBubbleAnchorKeys() {
    final aliveIds = <String>{};
    for (final item in _cachedListItems) {
      if (item is ChatMessageItem) {
        aliveIds.add(item.message.id);
      } else if (item is ChatChunkedMessageItem) {
        aliveIds.add(
          _chunkBubbleAnchorId(item.originalMessage.id, item.chunkIndex),
        );
      }
    }
    _bubbleAnchorKeys.removeWhere((id, _) => !aliveIds.contains(id));
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncHistoryLoadingOverlay();

    final overlayHeightChanged =
        (widget.bottomOverlayHeight - oldWidget.bottomOverlayHeight).abs() >
            0.5;
    if (!identical(oldWidget.viewportController, widget.viewportController)) {
      _unbindViewportController(oldWidget.viewportController);
      _bindViewportController(widget.viewportController);
    }

    final historyPagingLocked = _historyPagingLockActive;
    if (historyPagingLocked) {
      _lockAutoScrollForHistoryPaging('historyPagingActive');
    }

    // 会话切换：重置状态并更新列表项
    if (oldWidget.conversationId != widget.conversationId) {
      _pendingAnimationIds.clear();
      _latestAnimatedAt = _currentTimelineMessages.isNotEmpty
          ? _currentTimelineMessages.last.createdAt
          : null;
      _didInitialBottomPosition = false;
      _hydrationGeneration += 1;
      _bootSnapshotMessages = const [];
      _cachedFormatConfig = null;
      _cachedListItems = [];
      _cachedChatImages = [];
      _detachedSplitBoundary = null;
      _hasHydratedInitialListItems = false;
      _showHistoryLoadingOverlay =
          widget.isLoadingMore && widget.hasMoreMessages;
      _historyLoadingOverlayShownAt =
          _showHistoryLoadingOverlay ? DateTime.now() : null;
      _hydrateInitialListItems();
      if (_autoScrollEnabled) {
        _requestScrollToBottom('conversationChanged');
      }
      return;
    }

    final messagesChanged = widget.messages != oldWidget.messages;
    final transientMessagesChanged =
        widget.transientMessages != oldWidget.transientMessages;
    if (_pendingTransientHandoffIds.isNotEmpty &&
        _stableMessagesContainAllIds(
          widget.messages,
          _pendingTransientHandoffIds,
        )) {
      _clearPendingTransientHandoffHold();
    }
    final bootSnapshotBeforeUpdate = _bootSnapshotMessages;
    final holdListForTransientEmptyWindow =
        _shouldHoldListForTransientEmptyWindow(
      oldWidget,
      messagesChanged: messagesChanged,
    );
    final holdListForTransientHandoffWindow =
        _shouldHoldListForTransientHandoffWindow(
      oldWidget,
      transientMessagesChanged: transientMessagesChanged,
    );
    var suppressTailChangedForBootHandoff = false;
    final timelineOverlayChanged = transientMessagesChanged;

    // 缓存优化：仅当消息列表引用变化时才重构列表项
    // 避免键盘弹出/收起导致 MediaQuery 变化进而触发全量重建 (Layout Thrashing)
    if (messagesChanged) {
      if (widget.messages.isNotEmpty && bootSnapshotBeforeUpdate.isNotEmpty) {
        final bootTail = bootSnapshotBeforeUpdate.last;
        final liveTail = widget.messages.last;
        final equivalentTail =
            _isTailMessageEquivalentForHandoff(bootTail, liveTail);
        suppressTailChangedForBootHandoff =
            oldWidget.messages.isEmpty && equivalentTail;
        _bootSnapshotMessages = const [];
      }
      if (!suppressTailChangedForBootHandoff &&
          oldWidget.messages.isEmpty &&
          widget.messages.isNotEmpty) {
        final displayedTail = _lastDisplayedMessageFromCachedItems();
        if (displayedTail != null &&
            _isTailMessageEquivalentForHandoff(
              displayedTail,
              widget.messages.last,
            )) {
          suppressTailChangedForBootHandoff = true;
        }
      }
    }

    if (holdListForTransientEmptyWindow) {
      _debugAutoScroll('hold:transientEmptyWindow');
      return;
    }
    if (holdListForTransientHandoffWindow) {
      _debugAutoScroll('hold:transientHandoffWindow');
      return;
    }

    final tailChanged =
        _didTailMessageChange(oldWidget) && !suppressTailChangedForBootHandoff;

    if (messagesChanged) {
      _updateListItems(_cachedFormatConfig);
    } else if (timelineOverlayChanged) {
      _updateListItems(_cachedFormatConfig);
    }

    final sourceMessages = _currentTimelineMessages;
    if (sourceMessages.isEmpty) {
      _detachedSplitBoundary = null;
      _pendingAnimationIds.clear();
      _latestAnimatedAt = null;
      if (timelineOverlayChanged && _autoScrollEnabled) {
        _requestScrollToBottom('emptyTimelineTransientChanged');
      }
      return;
    }

    final threshold = _latestAnimatedAt;
    final List<Message> newMessages;
    if (threshold == null) {
      newMessages = List<Message>.from(sourceMessages);
    } else {
      newMessages =
          sourceMessages.where((m) => m.createdAt.isAfter(threshold)).toList();
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

    String? autoScrollReason;
    if (tailChanged && _autoScrollEnabled) {
      autoScrollReason = 'tailChanged';
    } else if (timelineOverlayChanged && _autoScrollEnabled) {
      autoScrollReason = 'transientTimelineChanged';
    } else if (overlayHeightChanged && _autoScrollEnabled) {
      autoScrollReason = 'overlayHeightChanged';
    }

    if (autoScrollReason != null) {
      if (historyPagingLocked) {
        _debugAutoScroll('blocked:$autoScrollReason by historyPagingLock');
        return;
      }
      _requestScrollToBottom(autoScrollReason);
      return;
    }
  }

  bool _shouldHoldListForTransientEmptyWindow(
    ChatMessageList oldWidget, {
    required bool messagesChanged,
  }) {
    if (!messagesChanged) return false;
    if (widget.messages.isNotEmpty || oldWidget.messages.isEmpty) return false;
    if (_cachedListItems.isEmpty) return false;

    final pagingLikelyInFlight =
        widget.isLoadingMore || oldWidget.isLoadingMore || _isLoadingTriggered;
    if (pagingLikelyInFlight) return true;

    // 兜底：流式窗口切换短抖时，若仍声明有更多历史，优先保留当前阅读视图，避免闪空。
    return widget.hasMoreMessages || oldWidget.hasMoreMessages;
  }

  bool _shouldHoldListForTransientHandoffWindow(
    ChatMessageList oldWidget, {
    required bool transientMessagesChanged,
  }) {
    if (_pendingTransientHandoffIds.isNotEmpty) {
      return !_stableMessagesContainAllIds(
        widget.messages,
        _pendingTransientHandoffIds,
      );
    }
    if (!transientMessagesChanged) return false;
    if (oldWidget.transientMessages.isEmpty ||
        widget.transientMessages.isNotEmpty) {
      return false;
    }
    if (_cachedListItems.isEmpty) return false;

    final handoffIds = oldWidget.transientMessages
        .map((message) => message.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (handoffIds.isEmpty) return false;
    if (_stableMessagesContainAllIds(widget.messages, handoffIds)) {
      return false;
    }
    _pendingTransientHandoffIds = handoffIds;
    _transientHandoffHoldTimer?.cancel();
    _transientHandoffHoldTimer = Timer(_kTransientHandoffHoldDuration, () {
      if (!mounted || _pendingTransientHandoffIds.isEmpty) return;
      setState(() {
        _clearPendingTransientHandoffHold();
        _updateListItems(_cachedFormatConfig);
      });
    });
    return true;
  }

  bool _stableMessagesContainAllIds(
    List<Message> messages,
    Set<String> ids,
  ) {
    if (ids.isEmpty) return true;
    final stableIds = messages.map((message) => message.id).toSet();
    for (final id in ids) {
      if (!stableIds.contains(id)) return false;
    }
    return true;
  }

  void _clearPendingTransientHandoffHold() {
    _transientHandoffHoldTimer?.cancel();
    _transientHandoffHoldTimer = null;
    _pendingTransientHandoffIds = <String>{};
  }

  Message? _lastDisplayedMessageFromCachedItems() {
    for (var index = _cachedListItems.length - 1; index >= 0; index--) {
      final item = _cachedListItems[index];
      if (item is ChatMessageItem) {
        return item.message;
      }
      if (item is ChatChunkedMessageItem) {
        return item.originalMessage;
      }
    }
    return null;
  }

  bool _didTailMessageChange(ChatMessageList oldWidget) {
    final previousMessages = _mergeTimelineMessages(
      oldWidget.messages,
      oldWidget.transientMessages,
    );
    final currentMessages = _currentTimelineMessages;
    if (previousMessages.isEmpty || currentMessages.isEmpty) {
      return previousMessages.isNotEmpty != currentMessages.isNotEmpty;
    }

    final previousTail = previousMessages.last;
    final currentTail = currentMessages.last;
    return !_isTailMessageEquivalent(previousTail, currentTail);
  }

  bool _isTailMessageEquivalent(Message previousTail, Message currentTail) {
    if (previousTail.id != currentTail.id ||
        previousTail.createdAt != currentTail.createdAt ||
        previousTail.role != currentTail.role ||
        previousTail.status != currentTail.status ||
        previousTail.content != currentTail.content) {
      return false;
    }

    final previousBlocks = previousTail.blocks ?? const <MessageBlock>[];
    final currentBlocks = currentTail.blocks ?? const <MessageBlock>[];
    return previousBlocks.length == currentBlocks.length;
  }

  bool _isTailMessageEquivalentForHandoff(
    Message previousTail,
    Message currentTail,
  ) {
    return previousTail.id == currentTail.id &&
        previousTail.createdAt == currentTail.createdAt &&
        previousTail.role == currentTail.role &&
        previousTail.status == currentTail.status &&
        previousTail.content == currentTail.content;
  }

  SliverChildBuilderDelegate _buildSectionDelegate(
    BuildContext context,
    List<ChatMessageListItem> items,
    ChatActions actions, {
    required bool reverseForViewport,
  }) {
    return SliverChildBuilderDelegate(
      (context, index) {
        final item =
            reverseForViewport ? items[items.length - 1 - index] : items[index];
        return _buildListItemWidget(
          context,
          item,
          actions,
        );
      },
      childCount: items.length,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      findChildIndexCallback: (key) => _findChildIndexForKey(
        key,
        items,
        reverseForViewport: reverseForViewport,
      ),
    );
  }

  Widget _buildListItemWidget(
    BuildContext context,
    ChatMessageListItem item,
    ChatActions actions,
  ) {
    final itemKey = ValueKey<String>(_listItemStableKey(item));

    if (item is ChatTimeDividerItem) {
      return KeyedSubtree(
        key: itemKey,
        child: _buildTimeDivider(context, item.time),
      );
    }
    if (item is ChatNewTopicDividerItem) {
      return KeyedSubtree(
        key: itemKey,
        child: _buildNewTopicDivider(context),
      );
    }
    if (item is ChatChunkedMessageItem) {
      final message = item.originalMessage;
      final isMe = message.role == 'user';
      final chunkBubbleId = _chunkBubbleAnchorId(message.id, item.chunkIndex);
      final chunkMessage = Message(
        id: '${message.id}_chunk_${item.chunkIndex}',
        role: message.role,
        content: item.chunkText,
        createdAt: message.createdAt,
        status: message.status,
      );
      final bubbleWidget = Padding(
        padding:
            const EdgeInsets.symmetric(vertical: _kMessageItemVerticalPadding),
        child: MessageBubble(
          isMe: isMe,
          message: chunkMessage,
          avatarUrl: isMe ? null : widget.avatarUrl,
          displayName: isMe ? null : widget.displayName,
          bubbleAnchorKey: _bubbleAnchorKeyFor(chunkBubbleId),
          showCorner: item.showCorner,
          showName: false,
          showAvatar: item.showAvatar,
          chatImages: _cachedChatImages,
          onRetry: null,
          onLongPress: (bubbleKey) =>
              _handleMessageLongPress(context, message, isMe, bubbleKey),
          onMediaLongPress: (mediaKey, block) =>
              _handleMediaLongPress(context, message, isMe, mediaKey, block),
        ),
      );

      final shouldAnimate =
          item.chunkIndex == 0 && _pendingAnimationIds.contains(message.id);
      if (shouldAnimate) {
        _pendingAnimationIds.remove(message.id);
        return AnimatedMessageItem(
          key: itemKey,
          child: bubbleWidget,
        );
      }
      return KeyedSubtree(
        key: itemKey,
        child: bubbleWidget,
      );
    }
    if (item is ChatMessageItem) {
      final message = item.message;
      final isMe = message.role == 'user';
      final bubbleWidget = Padding(
        padding:
            const EdgeInsets.symmetric(vertical: _kMessageItemVerticalPadding),
        child: MessageBubble(
          isMe: isMe,
          message: message,
          avatarUrl: isMe ? null : widget.avatarUrl,
          displayName: isMe ? null : widget.displayName,
          bubbleAnchorKey: _bubbleAnchorKeyFor(message.id),
          showCorner: item.showCorner,
          showName: false,
          showAvatar: item.showAvatar,
          chatImages: _cachedChatImages,
          onRetry: (isMe && message.status == 'failed')
              ? () => actions.recallFailedMessage(message.id)
              : null,
          onLongPress: (bubbleKey) =>
              _handleMessageLongPress(context, message, isMe, bubbleKey),
          onMediaLongPress: (mediaKey, block) =>
              _handleMediaLongPress(context, message, isMe, mediaKey, block),
        ),
      );

      final shouldAnimate = _pendingAnimationIds.contains(message.id);
      if (shouldAnimate) {
        _pendingAnimationIds.remove(message.id);
        return AnimatedMessageItem(
          key: itemKey,
          child: bubbleWidget,
        );
      }
      return KeyedSubtree(
        key: itemKey,
        child: bubbleWidget,
      );
    }

    return KeyedSubtree(
      key: itemKey,
      child: const SizedBox.shrink(),
    );
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
    if (_hasHydratedInitialListItems && _cachedFormatConfig != formatConfig) {
      _updateListItems(formatConfig);
    }

    final listItems = _cachedListItems;
    final listSections = _splitListItems(listItems, _currentTimelineMessages);
    final showHistoryLoadingOverlay = _showHistoryLoadingOverlay;
    final showJumpToBottomButton = _shouldShowJumpToBottomButton();
    final jumpToBottomBottomOffset = (widget.bottomOverlayHeight > 0
            ? widget.bottomOverlayHeight
            : safeBottom) +
        14;
    final itemCount = listSections.itemCount;
    final activeDelegate = _buildSectionDelegate(
      context,
      listSections.activeItems,
      actions,
      reverseForViewport: false,
    );
    final historyDelegate = _buildSectionDelegate(
      context,
      listSections.historyItems,
      actions,
      reverseForViewport: true,
    );
    _ensureInitialBottomPosition();
    if (widget.onDebugListItemCountChanged != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onDebugListItemCountChanged?.call(itemCount);
      });
    }

    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: ScrollConfiguration(
            behavior: const _ChatMessageListScrollBehavior(),
            child: CustomScrollView(
              key: _listViewportKey,
              controller: _scrollController,
              reverse: true,
              center: _centerKey,
              physics: const _ChatHistoryPagingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              cacheExtent: 500,
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.only(
                    left: 4,
                    right: 4,
                    bottom: listBottomPadding,
                  ),
                  sliver: SliverList(delegate: activeDelegate),
                ),
                SliverToBoxAdapter(
                  key: _centerKey,
                  child: const SizedBox.shrink(),
                ),
                SliverPadding(
                  padding: const EdgeInsets.only(
                    left: 4,
                    right: 4,
                    top: 10,
                  ),
                  sliver: SliverList(delegate: historyDelegate),
                ),
              ],
            ),
          ),
        ),
        if (showHistoryLoadingOverlay)
          Positioned(
            left: 0,
            right: 0,
            top: 12,
            child: IgnorePointer(
              child: KeyedSubtree(
                key: const ValueKey<String>('history_loading_overlay'),
                child: _buildLoadingIndicator(context),
              ),
            ),
          ),
        if (showJumpToBottomButton)
          Positioned(
            right: 14,
            bottom: jumpToBottomBottomOffset,
            child: _buildJumpToBottomButton(context),
          ),
      ],
    );
  }

  Widget _buildJumpToBottomButton(BuildContext context) {
    final colors = context.moeColors;

    return Tooltip(
      message: '回到底部',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const ValueKey<String>('chat_jump_to_latest_badge'),
          onTap: widget.viewportController.onJumpToLatest,
          customBorder: const CircleBorder(),
          child: Container(
            width: _kJumpToBottomButtonSize,
            height: _kJumpToBottomButtonSize,
            decoration: MoeG2Decoration(
              radius: MoeSmoothRadii.lg,
              color: colors.surface.withValues(alpha: 0.96),
              border: Border.all(color: colors.borderLight),
              boxShadow: MoeShadows.soft,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 24,
              color: colors.accentColor,
            ),
          ),
        ),
      ),
    );
  }

  /// 构建加载中指示器（用于分页加载时在顶部显示）
  Widget _buildLoadingIndicator(BuildContext context) {
    final colors = context.moeColors;
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.2),
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
            await saveChatMessageListMediaBlock(context, block);
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
}
