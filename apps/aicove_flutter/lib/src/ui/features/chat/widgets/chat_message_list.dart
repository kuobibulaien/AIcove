/// 聊天消息列表组件
///
/// 从 chat_page.dart 提取，负责显示消息列表和时间分隔器。
///
/// 更新记录：
/// - 2025-12-31: 从 chat_page.dart 提取
/// - 2026-01-28: 添加消息分段显示功能（纯前端展示）
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
import '../../../../features/chat/services/chat_history_store.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../ui/shared/widgets/media/moe_image_preview.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../../core/utils/data_image.dart';
import '../../../../core/models/message_block.dart';
import '../../../../core/models/block_status.dart';
import 'animated_message_item.dart';
import 'chat_message_list_display_cache.dart';

const double _kMessageItemVerticalPadding = 2.0;
const String _kPersistentViewportSnapshotSignature = 'viewport_boot_v2';
const Duration _kHistoryLoadingOverlayMinDuration = Duration(milliseconds: 260);
const Duration _kTransientHandoffHoldDuration = Duration(milliseconds: 220);
const double _kHistoryPagingTopFrictionBase = 0.05;
const int _kPersistentSnapshotTurnCount = kConversationInitialVisibleCount;

typedef PersistentSnapshotWindow = ConversationTurnWindow;
typedef LoadPersistentSnapshotOlderPage = LoadConversationOlderPage;

@visibleForTesting
Future<PersistentSnapshotWindow> resolvePersistentSnapshotWindow({
  required List<Message> currentMessages,
  required bool hasMoreMessages,
  required LoadPersistentSnapshotOlderPage loadOlderPage,
  int targetTurnCount = _kPersistentSnapshotTurnCount,
  int fetchPageSize = kConversationTurnWindowFetchPageSize,
  int maxFetchPages = kConversationTurnWindowMaxFetchPages,
}) async {
  return resolveConversationTurnWindow(
    currentMessages: currentMessages,
    hasMoreMessages: hasMoreMessages,
    loadOlderPage: loadOlderPage,
    targetTurnCount: targetTurnCount,
    fetchPageSize: fetchPageSize,
    maxFetchPages: maxFetchPages,
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
  @Deprecated('请改用 transientMessages，streamingBubbleState 仅保留兼容旧调用')
  final StreamingBubbleState streamingBubbleState;
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

  /// 强制回到底部信号（值变化时代表触发一次强制回底）
  final int forceScrollToBottomSignal;

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
    this.streamingBubbleState = StreamingBubbleState.hidden,
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
    this.forceScrollToBottomSignal = 0,
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
  DateTime? _latestAnimatedAt;
  List<_ListItem> _cachedListItems = [];

  /// 缓存的消息格式化配置（用于检测配置变化）
  MessageFormatConfig? _cachedFormatConfig;

  /// 缓存的聊天图片列表（画廊模式左右滑动切换）
  List<ImagePreviewItem> _cachedChatImages = [];
  List<Message> _bootSnapshotMessages = const [];

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

  List<Message> get _effectiveTransientMessages {
    final legacy = _legacyStreamingBubbleMessage();
    if (legacy == null) {
      return widget.transientMessages;
    }
    return <Message>[
      ...widget.transientMessages,
      legacy,
    ];
  }

  List<Message> get _currentTimelineMessages => _mergeTimelineMessages(
        _stableMessages,
        _effectiveTransientMessages,
      );

  bool get _hasTransientTimelineContent =>
      _effectiveTransientMessages.isNotEmpty;

  bool get _hasTimelineContent => _currentTimelineMessages.isNotEmpty;

  Message? _legacyStreamingBubbleMessage() {
    final state = widget.streamingBubbleState;
    if (!state.visible) return null;
    final anchorTime = _stableMessages.isNotEmpty
        ? _stableMessages.last.createdAt.add(const Duration(milliseconds: 1))
        : DateTime.now();
    final text = state.text.trim();
    final isPlaceholderOnly = state.status == StreamingBubbleStatus.streaming ||
        state.status == StreamingBubbleStatus.thinking;
    return Message.fromBlocks(
      id: '__legacy_streaming__${widget.conversationId}',
      role: 'assistant',
      blocks: <MessageBlock>[
        TextBlock(
          messageId: '__legacy_streaming__${widget.conversationId}',
          content: text.isEmpty ? '生成中...' : text,
          status:
              isPlaceholderOnly ? BlockStatus.streaming : BlockStatus.success,
        ),
      ],
      createdAt: anchorTime,
      status: isPlaceholderOnly ? 'sending' : 'sent',
    );
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
    _autoScrollEnabled = widget.autoScrollToBottomEnabled;
    _showHistoryLoadingOverlay = widget.isLoadingMore && widget.hasMoreMessages;
    if (_showHistoryLoadingOverlay) {
      _historyLoadingOverlayShownAt = DateTime.now();
    }
    if (_currentTimelineMessages.isNotEmpty) {
      _latestAnimatedAt = _currentTimelineMessages.last.createdAt;
    }
    _hydrateInitialListItems();

    // 初始化 ScrollController 并添加监听
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    if (_autoScrollEnabled && _hasTimelineContent) {
      _requestScrollToBottom('initState');
    }
  }

  @override
  void dispose() {
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
          : _deserializePersistentSnapshot(snapshot.listItems);
      if (restored != null &&
          _matchesCurrentTimelineTail(
            restored,
            sourceMessages,
          )) {
        final restoredEntry = ChatMessageListDisplayCacheEntry(
          windowSignature: windowSignature,
          formatSignature: formatSignature,
          listItems: restored.items.cast<Object>(),
          chatImages: _collectChatImages(restored.messages),
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
        : _normalizePersistentSnapshotRawItems(inMemoryBootSnapshot.listItems);
    final restoredFromMemory = inMemoryRawItems == null
        ? null
        : _deserializePersistentSnapshot(inMemoryRawItems);
    if (restoredFromMemory != null &&
        _matchesExpectedSnapshot(restoredFromMemory)) {
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
          : _deserializePersistentSnapshot(snapshot.listItems);
      if (restored == null || !_matchesExpectedSnapshot(restored)) {
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
    _PersistentSnapshotData restored,
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
      chatImages: _collectChatImages(restored.messages),
    );
    _bootSnapshotMessages = restored.messages;
    _latestAnimatedAt = restored.messages.isNotEmpty
        ? restored.messages.last.createdAt
        : _latestAnimatedAt;
    _applyDisplayCacheEntry(restoredEntry, effectiveConfig);
    _dispatchPersistentViewportResolution(restored);
  }

  void _dispatchPersistentViewportResolution(_PersistentSnapshotData restored) {
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
    _cachedListItems = cached.listItems.cast<_ListItem>();
    _cachedChatImages = List<ImagePreviewItem>.from(cached.chatImages);
    _hasHydratedInitialListItems = true;
    _cleanupBubbleAnchorKeys();
  }

  bool _shouldRestorePersistentSnapshot() {
    final sourceMessages = _stableMessages;
    return sourceMessages.isNotEmpty &&
        countConversationTurns(sourceMessages) <=
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

  bool get _historyPagingLockActive =>
      widget.isLoadingMore || _isLoadingTriggered;

  void _lockAutoScrollForHistoryPaging(String reason) {
    if (!_autoScrollEnabled) return;
    _autoScrollEnabled = false;
    _debugAutoScroll('lock:$reason');
    _notifyAutoScrollDisabledDeferred();
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

  bool _isNearBottom([double threshold = 56.0]) {
    return _distanceToBottom() <= threshold;
  }

  void _notifyAutoScrollDisabledDeferred() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onAutoScrollDisabled?.call();
    });
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
    _cachedListItems = _buildListItemsWithTimeDividers(effectiveConfig);
    _cachedChatImages = _collectChatImages(timelineMessages);
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
    final snapshotWindow = await resolvePersistentSnapshotWindow(
      currentMessages: List<Message>.from(widget.messages, growable: false),
      hasMoreMessages: widget.hasMoreMessages,
      loadOlderPage: ({
        required DateTime beforeCreatedAt,
        required String beforeId,
        required int limit,
      }) {
        return ref.read(chatHistoryStoreProvider).loadMessagesBefore(
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

    final listItems = _buildListItemsForMessages(
      recentMessages,
      effectiveConfig,
      contextStartMessageId: widget.contextStartMessageId,
    );
    final serializedSnapshot = _serializeListItems(
      listItems,
      sourceMessages: recentMessages,
      visibleTurnCount: countConversationTurns(widget.messages),
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

  List<Map<String, dynamic>> _serializeListItems(
    List<_ListItem> listItems, {
    required List<Message> sourceMessages,
    required int visibleTurnCount,
    required bool hasMoreMessages,
  }) {
    final lastMessage = sourceMessages.isNotEmpty ? sourceMessages.last : null;
    return [
      <String, dynamic>{
        'type': 'meta',
        'hasMoreMessages': hasMoreMessages,
        'visibleTurnCount': visibleTurnCount,
        'lastMessagePreview': lastMessage?.displayText,
        'lastMessageTime': lastMessage?.createdAt.millisecondsSinceEpoch,
      },
      for (final item in listItems)
        if (item is _TimeDivider)
          <String, dynamic>{
            'type': 'time',
            'time': item.time.millisecondsSinceEpoch,
          }
        else if (item is _NewTopicDivider)
          const <String, dynamic>{
            'type': 'new_topic',
          }
        else if (item is _MessageItem)
          <String, dynamic>{
            'type': 'message',
            'messageId': item.message.id,
            'message': _serializeMessage(item.message),
            'showCorner': item.showCorner,
            'showAvatar': item.showAvatar,
          }
        else if (item is _ChunkedMessageItem)
          <String, dynamic>{
            'type': 'chunk',
            'messageId': item.originalMessage.id,
            'message': _serializeMessage(item.originalMessage),
            'chunkText': item.chunkText,
            'chunkIndex': item.chunkIndex,
            'totalChunks': item.totalChunks,
            'showCorner': item.showCorner,
            'showAvatar': item.showAvatar,
          },
    ];
  }

  _PersistentSnapshotData? _deserializePersistentSnapshot(
    List<Map<String, dynamic>> rawItems,
  ) {
    final messagesById = <String, Message>{
      for (final message in _stableMessages) message.id: message,
    };
    final restored = <_ListItem>[];
    final restoredMessages = <String, Message>{};
    var hasMoreMessages = true;
    var visibleTurnCount = 0;
    String? lastMessagePreview;
    DateTime? lastMessageTime;

    for (final raw in rawItems) {
      final type = raw['type'] as String?;
      switch (type) {
        case 'meta':
          hasMoreMessages = raw['hasMoreMessages'] != false;
          visibleTurnCount = _readInt(raw['visibleTurnCount']) ??
              _readInt(raw['visibleMessageCount']) ??
              0;
          lastMessagePreview = raw['lastMessagePreview'] as String?;
          final rawTime = _readInt(raw['lastMessageTime']);
          if (rawTime != null) {
            lastMessageTime = DateTime.fromMillisecondsSinceEpoch(rawTime);
          }
          break;
        case 'time':
          final timestamp = _readInt(raw['time']);
          if (timestamp == null) {
            return null;
          }
          restored.add(
            _TimeDivider(
              DateTime.fromMillisecondsSinceEpoch(timestamp),
            ),
          );
          break;
        case 'new_topic':
          restored.add(_NewTopicDivider());
          break;
        case 'message':
          final messageId = raw['messageId'] as String?;
          final message = _resolvePersistentMessage(
            raw['message'],
            messageId: messageId,
            liveMessagesById: messagesById,
            restoredMessagesById: restoredMessages,
          );
          if (message == null) {
            return null;
          }
          restored.add(
            _MessageItem(
              message,
              showCorner: raw['showCorner'] == true,
              showAvatar: raw['showAvatar'] != false,
            ),
          );
          break;
        case 'chunk':
          final messageId = raw['messageId'] as String?;
          final message = _resolvePersistentMessage(
            raw['message'],
            messageId: messageId,
            liveMessagesById: messagesById,
            restoredMessagesById: restoredMessages,
          );
          final chunkText = raw['chunkText'] as String?;
          final chunkIndex = _readInt(raw['chunkIndex']);
          final totalChunks = _readInt(raw['totalChunks']);
          if (message == null ||
              chunkText == null ||
              chunkIndex == null ||
              totalChunks == null) {
            return null;
          }
          restored.add(
            _ChunkedMessageItem(
              originalMessage: message,
              chunkText: chunkText,
              chunkIndex: chunkIndex,
              totalChunks: totalChunks,
              showCorner: raw['showCorner'] == true,
              showAvatar: raw['showAvatar'] != false,
            ),
          );
          break;
        default:
          return null;
      }
    }

    final orderedMessages = restoredMessages.values.toList(growable: false)
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) {
          return byTime;
        }
        return a.id.compareTo(b.id);
      });
    return _PersistentSnapshotData(
      items: restored,
      messages: orderedMessages,
      hasMoreMessages: hasMoreMessages,
      visibleTurnCount: visibleTurnCount > 0
          ? visibleTurnCount
          : countConversationTurns(orderedMessages),
      lastMessagePreview: lastMessagePreview,
      lastMessageTime: lastMessageTime,
    );
  }

  List<Map<String, dynamic>>? _normalizePersistentSnapshotRawItems(
    Iterable<Object?> rawItems,
  ) {
    final normalized = <Map<String, dynamic>>[];
    for (final item in rawItems) {
      if (item is! Map) {
        return null;
      }
      normalized.add(Map<String, dynamic>.from(item));
    }
    return List<Map<String, dynamic>>.unmodifiable(normalized);
  }

  Map<String, dynamic> _serializeMessage(Message message) {
    return <String, dynamic>{
      'id': message.id,
      'role': message.role,
      'content': message.content,
      'createdAt': message.createdAt.millisecondsSinceEpoch,
      'status': message.status,
      'blocks': [
        for (final block in message.blocks ?? const <MessageBlock>[])
          block.toJson(),
      ],
    };
  }

  Message? _resolvePersistentMessage(
    Object? rawMessage, {
    required String? messageId,
    required Map<String, Message> liveMessagesById,
    required Map<String, Message> restoredMessagesById,
  }) {
    if (messageId != null) {
      final liveMessage = liveMessagesById[messageId];
      if (liveMessage != null) {
        restoredMessagesById.putIfAbsent(messageId, () => liveMessage);
        return liveMessage;
      }
    }
    if (rawMessage is! Map) {
      return null;
    }
    final restoredMessage =
        _deserializeMessage(Map<String, dynamic>.from(rawMessage));
    if (restoredMessage == null) {
      return null;
    }
    restoredMessagesById.putIfAbsent(restoredMessage.id, () => restoredMessage);
    return restoredMessage;
  }

  Message? _deserializeMessage(Map<String, dynamic> raw) {
    final id = raw['id'] as String?;
    final role = raw['role'] as String?;
    final content = raw['content'] as String?;
    final createdAt = _readInt(raw['createdAt']);
    if (id == null || role == null || content == null || createdAt == null) {
      return null;
    }

    final blocks = <MessageBlock>[];
    final rawBlocks = raw['blocks'];
    if (rawBlocks is List) {
      for (final block in rawBlocks) {
        if (block is! Map) {
          return null;
        }
        try {
          blocks.add(MessageBlock.fromJson(Map<String, dynamic>.from(block)));
        } catch (_) {
          return null;
        }
      }
    }

    return Message(
      id: id,
      role: role,
      content: content,
      blocks: blocks.isEmpty ? null : blocks,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      status: raw['status'] as String?,
    );
  }

  bool _matchesExpectedSnapshot(_PersistentSnapshotData snapshot) {
    final expectedTime = widget.expectedLastMessageTime;
    if (expectedTime != null &&
        snapshot.lastMessageTime != null &&
        expectedTime.millisecondsSinceEpoch !=
            snapshot.lastMessageTime!.millisecondsSinceEpoch) {
      return false;
    }

    final expectedPreview = widget.expectedLastMessagePreview?.trim();
    if (expectedPreview != null &&
        expectedPreview.isNotEmpty &&
        snapshot.lastMessagePreview != null &&
        expectedPreview != snapshot.lastMessagePreview!.trim()) {
      return false;
    }

    return true;
  }

  bool _matchesCurrentTimelineTail(
    _PersistentSnapshotData snapshot,
    List<Message> sourceMessages,
  ) {
    if (sourceMessages.isEmpty) return false;
    final currentTail = sourceMessages.last;
    final snapshotTime = snapshot.lastMessageTime ??
        (snapshot.messages.isNotEmpty
            ? snapshot.messages.last.createdAt
            : null);
    if (snapshotTime != null &&
        snapshotTime.millisecondsSinceEpoch !=
            currentTail.createdAt.millisecondsSinceEpoch) {
      return false;
    }

    final snapshotPreview =
        (snapshot.lastMessagePreview ?? currentTail.displayText).trim();
    return snapshotPreview == currentTail.displayText.trim();
  }

  int? _readInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return null;
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
      if (item is _MessageItem) {
        aliveIds.add(item.message.id);
      } else if (item is _ChunkedMessageItem) {
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

    final resumeAutoScroll = !oldWidget.autoScrollToBottomEnabled &&
        widget.autoScrollToBottomEnabled;
    final forceScrollRequested =
        oldWidget.forceScrollToBottomSignal != widget.forceScrollToBottomSignal;
    final overlayHeightChanged =
        (widget.bottomOverlayHeight - oldWidget.bottomOverlayHeight).abs() >
            0.5;
    var shouldResumeAutoScroll = resumeAutoScroll;
    if (oldWidget.autoScrollToBottomEnabled !=
        widget.autoScrollToBottomEnabled) {
      _autoScrollEnabled = widget.autoScrollToBottomEnabled;
    }
    if (forceScrollRequested) {
      _autoScrollEnabled = true;
      shouldResumeAutoScroll = true;
    }

    final historyPagingLocked =
        _historyPagingLockActive && !forceScrollRequested;
    if (historyPagingLocked) {
      shouldResumeAutoScroll = false;
      _lockAutoScrollForHistoryPaging('historyPagingActive');
    }

    // 点击输入框时：若用户仍在历史中段，不应强制跳底。
    if (resumeAutoScroll && !forceScrollRequested && !_isNearBottom()) {
      _autoScrollEnabled = false;
      shouldResumeAutoScroll = false;
      _notifyAutoScrollDisabledDeferred();
    }

    // 会话切换：重置状态并更新列表项
    if (oldWidget.conversationId != widget.conversationId) {
      _pendingAnimationIds.clear();
      _latestAnimatedAt = _currentTimelineMessages.isNotEmpty
          ? _currentTimelineMessages.last.createdAt
          : null;
      _autoScrollEnabled = widget.autoScrollToBottomEnabled;
      _didInitialBottomPosition = false;
      _hydrationGeneration += 1;
      _bootSnapshotMessages = const [];
      _cachedFormatConfig = null;
      _cachedListItems = [];
      _cachedChatImages = [];
      _hasHydratedInitialListItems = false;
      _showHistoryLoadingOverlay =
          widget.isLoadingMore && widget.hasMoreMessages;
      _historyLoadingOverlayShownAt =
          _showHistoryLoadingOverlay ? DateTime.now() : null;
      _hydrateInitialListItems();
      _requestScrollToBottom('conversationChanged');
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
    final legacyStreamingBubbleChanged = _didStreamingBubbleChange(oldWidget);
    final timelineOverlayChanged =
        transientMessagesChanged || legacyStreamingBubbleChanged;

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
      if (!holdListForTransientEmptyWindow &&
          !holdListForTransientHandoffWindow) {
        _updateListItems(_cachedFormatConfig);
      }
    } else if (timelineOverlayChanged && !holdListForTransientHandoffWindow) {
      _updateListItems(_cachedFormatConfig);
    }

    if (holdListForTransientEmptyWindow) {
      _debugAutoScroll('hold:transientEmptyWindow');
      return;
    }
    if (holdListForTransientHandoffWindow) {
      _debugAutoScroll('hold:transientHandoffWindow');
      return;
    }

    final sourceMessages = _currentTimelineMessages;
    if (sourceMessages.isEmpty) {
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

    final tailChanged =
        _didTailMessageChange(oldWidget) && !suppressTailChangedForBootHandoff;
    String? autoScrollReason;
    if (forceScrollRequested) {
      autoScrollReason = 'forceScrollRequested';
    } else if (shouldResumeAutoScroll) {
      autoScrollReason = 'resumeAutoScroll';
    } else if (tailChanged && _autoScrollEnabled) {
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

  bool _didStreamingBubbleChange(ChatMessageList oldWidget) {
    final previous = oldWidget.streamingBubbleState;
    final current = widget.streamingBubbleState;
    return previous.visible != current.visible ||
        previous.text != current.text ||
        previous.status != current.status;
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
      if (item is _MessageItem) {
        return item.message;
      }
      if (item is _ChunkedMessageItem) {
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

    // 构建包含时间分隔器的列表项，数据顺序保持 oldest -> newest，
    // 仅在 UI 层通过 reverse + 索引映射实现 bottom-up 布局。
    final listItems = _cachedListItems;

    final showHistoryLoadingOverlay = _showHistoryLoadingOverlay;
    final itemCount = listItems.length;
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
            child: ListView.builder(
              controller: _scrollController, // 添加 ScrollController 用于分页触发
              reverse: true, // 反转列表：天然从底部渲染最新消息，无闪跳
              physics: const _ChatHistoryPagingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              // 性能优化：增加缓存范围，减少滚动时的重建
              cacheExtent: 500,
              // 性能优化：禁用自动 keep alive，由我们自己控制
              addAutomaticKeepAlives: false,
              // 性能优化：添加重绘边界，隔离每个消息的重绘
              addRepaintBoundaries: true,
              // reverse:true 不影响 padding 的物理方向，top 仍是屏幕顶部，bottom 仍是屏幕底部。
              padding: EdgeInsets.only(
                left: 4,
                right: 4,
                top: 10,
                bottom: listBottomPadding,
              ),
              itemCount: itemCount,
              itemBuilder: (context, index) {
                final item = listItems[listItems.length - 1 - index];

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
                      bubbleAnchorKey: _bubbleAnchorKeyFor(
                        _chunkBubbleAnchorId(m.id, item.chunkIndex),
                      ),
                      showCorner: item.showCorner,
                      showName: false,
                      showAvatar: item.showAvatar,
                      chatImages: _cachedChatImages,
                      onRetry: null, // 分段消息不支持重试
                      onLongPress: (bubbleKey) =>
                          _handleMessageLongPress(context, m, isMe, bubbleKey),
                      onMediaLongPress: (mediaKey, block) =>
                          _handleMediaLongPress(
                              context, m, isMe, mediaKey, block),
                    ),
                  );

                  // 只有第一个分段需要动画
                  final shouldAnimate = item.chunkIndex == 0 &&
                      _pendingAnimationIds.contains(m.id);
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
                      bubbleAnchorKey: _bubbleAnchorKeyFor(m.id),
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
                          _handleMediaLongPress(
                              context, m, isMe, mediaKey, block),
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
      ],
    );
  }

  /// 构建包含时间分隔器的列表项
  ///
  /// [config] 消息格式化配置，用于分段显示
  List<_ListItem> _buildListItemsWithTimeDividers(
      [MessageFormatConfig? config]) {
    return _buildListItemsForMessages(
      _currentTimelineMessages,
      config,
      contextStartMessageId: widget.contextStartMessageId,
    );
  }

  List<_ListItem> _buildListItemsForMessages(
    List<Message> messages,
    MessageFormatConfig? config, {
    String? contextStartMessageId,
  }) {
    final List<_ListItem> items = [];
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
      final blocks = currentMessage.blocks;
      final hasNonTextBlocks =
          blocks?.any((block) => block is! TextBlock) ?? false;
      final chunkSourceText = (blocks == null || blocks.isEmpty)
          ? currentMessage.content
          : blocks
              .whereType<TextBlock>()
              .map((block) => block.content)
              .join('\n\n');
      final shouldChunk = enableChunking &&
          isAssistant &&
          currentMessage.status != 'sending' &&
          !hasNonTextBlocks &&
          chunkSourceText.trim().isNotEmpty;

      if (shouldChunk && config != null) {
        // 对 AI 消息进行分段
        final chunks =
            MessageFormatter.formatAndChunkText(chunkSourceText, config);
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
          if (contextStartMessageId != null &&
              currentMessage.id == contextStartMessageId) {
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
      if (contextStartMessageId != null &&
          currentMessage.id == contextStartMessageId) {
        items.add(_NewTopicDivider());
      }
    }

    return items;
  }

  /// 从所有消息中收集图片/表情包，构建画廊预览列表
  /// heroTag 与 message_bubble.dart 中保持一致：image_{id} / sticker_{id}
  List<ImagePreviewItem> _collectChatImages([List<Message>? messages]) {
    final result = <ImagePreviewItem>[];
    for (final message in messages ?? _currentTimelineMessages) {
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
      return FileImage(File(path));
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

class _PersistentSnapshotData {
  const _PersistentSnapshotData({
    required this.items,
    required this.messages,
    required this.hasMoreMessages,
    required this.visibleTurnCount,
    this.lastMessagePreview,
    this.lastMessageTime,
  });

  final List<_ListItem> items;
  final List<Message> messages;
  final bool hasMoreMessages;
  final int visibleTurnCount;
  final String? lastMessagePreview;
  final DateTime? lastMessageTime;
}

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
