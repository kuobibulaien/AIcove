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
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/chat/chat_actions.dart';
import '../../../../features/chat/application/active_stream_projection.dart';
import '../../../../features/chat/application/chat_message_list_queries.dart';
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
import '../../../../core/models/block_status.dart';
import '../../../../core/models/message_block.dart';
import 'animated_message_item.dart';
import 'chat_message_list_display_cache.dart';
import 'chat_message_list_items.dart';
import 'chat_message_list_media_save.dart';
import 'chat_viewport_controller.dart';

part 'chat_message_list_presentation.dart';
part 'chat_message_list_timeline.dart';
part 'chat_message_list_viewport.dart';

const double _kMessageItemVerticalPadding = 2.0;
const Duration _kHistoryLoadingOverlayMinDuration = Duration(milliseconds: 260);
const Duration _kTransientHandoffHoldDuration = Duration(milliseconds: 220);
const Duration _kStreamingScrollUpdateDeferDuration =
    Duration(milliseconds: 220);
const Duration _kAnimatedScrollToBottomMinDuration =
    Duration(milliseconds: 180);
const Duration _kAnimatedScrollToBottomMaxDuration =
    Duration(milliseconds: 320);
const double _kHistoryPagingTopFrictionBase = 0.05;
const double _kJumpToBottomVisibilityThreshold = 120.0;
const double _kJumpToBottomButtonSize = 44.0;

@visibleForTesting
List<Message> mergeChatTimelineMessagesForDisplay(
  List<Message> stableMessages,
  List<Message> transientMessages,
) {
  if (stableMessages.isEmpty && transientMessages.isEmpty) {
    return const <Message>[];
  }

  final deduped = <String, ({int index, Message message})>{};
  var index = 0;
  for (final message in transientMessages) {
    deduped[message.id] = (index: index, message: message);
    index += 1;
  }
  for (final message in stableMessages) {
    deduped[message.id] = (index: index, message: message);
    index += 1;
  }

  final timelineEntries = deduped.values.toList(growable: false)
    ..sort((left, right) {
      final byTime = left.message.createdAt.compareTo(right.message.createdAt);
      if (byTime != 0) return byTime;
      return left.index.compareTo(right.index);
    });
  return <Message>[
    for (final entry in timelineEntries) entry.message,
  ];
}

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

class _ChatListSections {
  const _ChatListSections({
    required this.historyItems,
    required this.activeItems,
  });

  final List<ChatMessageListItem> historyItems;
  final List<ChatMessageListItem> activeItems;

  int get itemCount => historyItems.length + activeItems.length;
}

int _resolveActiveBoundaryGroupStartIndex(
  List<Message> timelineMessages,
  int index,
) {
  if (timelineMessages.isEmpty) return 0;
  var cursor = index.clamp(0, timelineMessages.length - 1);
  final sourceId = timelineMessages[cursor].sourceMessageIdOrSelf;
  while (cursor > 0 &&
      timelineMessages[cursor - 1].sourceMessageIdOrSelf == sourceId) {
    cursor -= 1;
  }
  return cursor;
}

int _resolvePinnedLatestTailActiveBoundaryIndex(
    List<Message> timelineMessages) {
  if (timelineMessages.isEmpty) return 0;

  final tailGroupStart = _resolveActiveBoundaryGroupStartIndex(
    timelineMessages,
    timelineMessages.length - 1,
  );
  if (tailGroupStart <= 0) {
    return tailGroupStart;
  }

  final tailGroupRole = timelineMessages[tailGroupStart].role.trim();
  if (tailGroupRole != 'assistant') {
    return tailGroupStart;
  }

  final previousGroupStart = _resolveActiveBoundaryGroupStartIndex(
    timelineMessages,
    tailGroupStart - 1,
  );
  final previousGroupRole = timelineMessages[previousGroupStart].role.trim();
  if (previousGroupRole == 'user') {
    return previousGroupStart;
  }

  return tailGroupStart;
}

@visibleForTesting
int? resolveChatMessageListActiveBoundaryIndex(
  List<Message> timelineMessages, {
  String? detachedBoundaryMessageId,
  DateTime? detachedBoundaryCreatedAt,
  bool preserveAdjacentUserGroupInFollowLatest = false,
}) {
  if (timelineMessages.isEmpty) return null;

  if (detachedBoundaryMessageId == null ||
      detachedBoundaryMessageId.trim().isEmpty ||
      detachedBoundaryCreatedAt == null) {
    if (preserveAdjacentUserGroupInFollowLatest) {
      return _resolvePinnedLatestTailActiveBoundaryIndex(timelineMessages);
    }
    return _resolveActiveBoundaryGroupStartIndex(
      timelineMessages,
      timelineMessages.length - 1,
    );
  }

  final exactIndex = timelineMessages.indexWhere(
    (message) => message.id == detachedBoundaryMessageId,
  );
  if (exactIndex >= 0) {
    return _resolveActiveBoundaryGroupStartIndex(
      timelineMessages,
      exactIndex,
    );
  }

  final fallbackIndex = timelineMessages.indexWhere(
    (message) => !message.createdAt.isBefore(detachedBoundaryCreatedAt),
  );
  if (fallbackIndex >= 0) {
    return _resolveActiveBoundaryGroupStartIndex(
      timelineMessages,
      fallbackIndex,
    );
  }

  return _resolveActiveBoundaryGroupStartIndex(
    timelineMessages,
    timelineMessages.length - 1,
  );
}

@visibleForTesting
Future<PersistentSnapshotWindow> resolvePersistentSnapshotWindow({
  required List<Message> currentMessages,
  required bool hasMoreMessages,
  required LoadPersistentSnapshotOlderPage loadOlderPage,
  int targetTurnCount = kConversationPersistentSnapshotTurnCount,
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
    this.onDebugListItemCountChanged,
    this.onDebugAutoScrollRequested,
  });

  @override
  ConsumerState<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends ConsumerState<ChatMessageList> {
  final Set<String> _pendingAnimationIds = <String>{};
  final GlobalKey _listViewportKey =
      GlobalKey(debugLabel: 'chat_message_list_viewport');
  final Key _centerKey = const ValueKey<String>('chat_message_list_center');
  DateTime? _latestAnimatedAt;
  List<ChatMessageListItem> _cachedListItems = [];
  _TimelineSplitBoundary? _detachedSplitBoundary;
  _TimelineSplitBoundary? _pendingDetachedSplitBoundary;

  /// 缓存的消息格式化配置（用于检测配置变化）
  MessageFormatConfig? _cachedFormatConfig;

  /// 缓存的聊天图片列表（画廊模式左右滑动切换）
  List<ImagePreviewItem> _cachedChatImages = [];

  /// 用于监听滚动位置，触发分页加载
  late final ScrollController _scrollController;

  /// 防止重复触发加载
  bool _isLoadingTriggered = false;

  /// 标记是否由代码触发滚动，避免把程序滚动误判为用户手势
  bool _isProgrammaticScroll = false;
  int _programmaticScrollSerial = 0;

  int _handledViewportScrollRequestSerial = 0;
  bool _lastViewportShouldFollowLatest = true;

  /// 首次进入会话时，确保列表定位到最新消息
  bool _didInitialBottomPosition = false;
  double _manualDetachedDistanceToBottom = 0;

  /// 「回到底部」按钮显隐，由 ValueListenableBuilder 局部消费。
  ///
  /// 语义与 [_manualDetachedDistanceToBottom] 完全一致（后者仍是唯一距离
  /// 真源，保留初值/去重/更新时机），这里只是把"是否显示"的布尔结果单独
  /// 广播出去，让滚动帧只重建这一个按钮而非整个列表——切断拖动逐帧
  /// setState 重建（滑动卡顿主因，2026-07-13 修复）。
  final ValueNotifier<bool> _showJumpToBottom = ValueNotifier<bool>(false);

  bool _hasHydratedInitialListItems = false;
  bool _showHistoryLoadingOverlay = false;
  DateTime? _historyLoadingOverlayShownAt;
  Timer? _historyLoadingOverlayHideTimer;
  Set<String> _pendingTransientHandoffIds = <String>{};
  Timer? _transientHandoffHoldTimer;
  Timer? _deferredStreamingListUpdateTimer;
  MessageFormatConfig? _deferredStreamingListUpdateConfig;
  int _historyViewportRestoreSerial = 0;
  bool _historyViewportRestorePending = false;
  bool _holdListForHistoryPagingEmptyTimeline = false;
  List<Message> _heldTimelineMessagesForLayout = const <Message>[];
  bool _isUserScrollActive = false;
  bool _hasDeferredStreamingListUpdate = false;

  // —— detached 模式下「尾项 ImageBlock 几何变化」的 extent 像素补偿 ——
  // 用户上滑时 _autoScrollEnabled=false，_shouldStabilizeFollowLatestViewport 首守卫
  // 直接 return false 不补 jumpTo（chat_message_list_timeline.dart:568-571），尾图高度
  // 阶跃（占位→真实尺寸）会让 active sliver（center 前，reverse growth）的 minScrollExtent
  // 突变、pixels 不变 → 内容相对视口跳移。这里记录重建前的 minScrollExtent/pixels，
  // 重建后按 target = previousPixels + (newMin - previousMin) 用 jumpTo 把内容拉回
  // 用户手指所在的逻辑位置。serial 独立于 history/programmatic；history > detached。
  // 见 _scheduleDetachedActiveExtentRestore（chat_message_list_viewport.dart）。
  int _detachedExtentRestoreSerial = 0;
  double? _detachedExtentRestorePreviousMin;
  double? _detachedExtentRestorePreviousPixels;
  String? _detachedExtentRestoreConversationId;

  List<Message> get _stableMessages => widget.messages;

  List<Message> get _currentTimelineMessages => _mergeTimelineMessages(
        _stableMessages,
        widget.transientMessages,
      );

  bool get _hasTransientTimelineContent => widget.transientMessages.isNotEmpty;

  bool get _hasTimelineContent => _currentTimelineMessages.isNotEmpty;

  bool get _autoScrollEnabled => widget.viewportController.shouldFollowLatest;

  void _updateState(VoidCallback fn) {
    setState(fn);
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
    _showJumpToBottom.dispose();
    _historyLoadingOverlayHideTimer?.cancel();
    _transientHandoffHoldTimer?.cancel();
    _deferredStreamingListUpdateTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _handleDidUpdateWidget(oldWidget);
  }

  /// G2.1 活跃流通道开关（应用生命周期常量；off＝严格回滚面）。
  bool get _streamChannelEnabled =>
      ref.read(streamProjectionPolicyProvider).useActiveStreamChannel;

  @override
  Widget build(BuildContext context) {
    final actions = ref.watch(chatActionsProvider);
    // G2.1 活跃流通道窄信号：通道尾文本增长只调度视口稳底，不重建列表
    //（07-20 design v2 §2.7）。policy off 时不建立任何通道监听（B-01：
    // off 必须是严格回滚面）；policy 为应用生命周期常量，条件挂载安全。
    if (_streamChannelEnabled) {
      ref.listen<(String?, int, ActiveStreamPhase)?>(
          activeStreamProjectionsProvider.select((projections) {
        final projection = projections[widget.conversationId];
        return projection == null
            ? null
            : (
                projection.tailMessageId,
                projection.tailText.length,
                projection.phase,
              );
      }), (previous, next) {
        // 仅处理「同一尾、同相位、文本增长」：新壳/换尾属结构事件，
        // 由时间线写入触发的 didUpdateWidget 稳底路径负责（S-04）。
        if (previous == null || next == null) return;
        if (previous.$1 != next.$1 || previous.$3 != next.$3) return;
        if (next.$2 <= previous.$2) return;
        _onActiveStreamTailChanged();
      });
    }
    // 字段级订阅：设置里无关字段变化不再重建整颗消息列表
    final uiScale = ref.watch(appSettingsProvider.select(
      (settings) => (settings.valueOrNull?.uiScaleFactor ?? 1.0)
          .clamp(kMinUiScaleFactor, kMaxUiScaleFactor)
          .toDouble(),
    ));
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom / uiScale;
    final safeBottom = MediaQuery.paddingOf(context).bottom / uiScale;
    final fallbackBottomPadding = safeBottom + 70 + keyboardInset;
    final listBottomPadding = widget.bottomOverlayHeight > 0
        ? widget.bottomOverlayHeight
        : fallbackBottomPadding;

    // 获取消息格式化配置（用于分段显示）
    final formatConfig = ref.watch(appSettingsProvider.select(
      (settings) =>
          settings.valueOrNull?.messageFormatConfig ??
          const MessageFormatConfig(),
    ));

    // 检测配置变化，需要重新构建列表项
    if (_hasHydratedInitialListItems && _cachedFormatConfig != formatConfig) {
      _updateListItems(formatConfig);
    }

    final listItems = _cachedListItems;
    final timelineMessagesForSectioning =
        _holdListForHistoryPagingEmptyTimeline &&
                _currentTimelineMessages.isEmpty &&
                _heldTimelineMessagesForLayout.isNotEmpty
            ? _heldTimelineMessagesForLayout
            : _currentTimelineMessages;
    final listSections = _splitListItems(
      listItems,
      timelineMessagesForSectioning,
    );
    final decoratedListSections = _decorateSectionsWithTopicDivider(
      listSections,
      timelineMessagesForSectioning,
    );
    final showHistoryLoadingOverlay = _showHistoryLoadingOverlay;
    final jumpToBottomBottomOffset = (widget.bottomOverlayHeight > 0
            ? widget.bottomOverlayHeight
            : safeBottom) +
        14;
    final itemCount = decoratedListSections.itemCount;
    final activeDelegate = _buildSectionDelegate(
      context,
      decoratedListSections.activeItems,
      actions,
      reverseForViewport: false,
    );
    final historyDelegate = _buildSectionDelegate(
      context,
      decoratedListSections.historyItems,
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
        ValueListenableBuilder<bool>(
          valueListenable: _showJumpToBottom,
          builder: (context, show, _) {
            if (!show) return const SizedBox.shrink();
            return Positioned(
              right: 14,
              bottom: jumpToBottomBottomOffset,
              child: _buildJumpToBottomButton(context),
            );
          },
        ),
      ],
    );
  }
}
