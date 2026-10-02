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
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/chat/chat_actions.dart';
import '../../../../features/chat/conversation_providers.dart'
    show chatDisplayPolicyProvider;
import '../../../../features/chat/application/active_stream_projection.dart';
import '../../../../features/chat/application/chat_media_regeneration.dart';
import '../../../../features/chat/application/chat_message_list_queries.dart';
import '../../../../features/chat/domain/message.dart';
import '../../../../features/agent_context/domain/preset_tag_mapping.dart';
import '../../../../features/agent_context/providers/preset_recipe_provider.dart';
import '../../../../features/content_tags/domain/tag_presentation.dart';
import '../../../../features/chat/presentation/widgets/message_bubble.dart';
import '../../../../features/chat/presentation/widgets/message_action_sheet.dart';
import '../../../../ui/theme/tokens.dart';
import '../../../../ui/shared/effects/smooth_clip.dart';
import '../../../../ui/shared/widgets/meotalk_dialog.dart';
import '../../../../ui/shared/widgets/moe_floating_surface.dart';
import '../../../../ui/shared/widgets/moe_toast.dart';
import '../../../../ui/shared/widgets/media/moe_image_preview.dart';
import '../../../../core/utils/message_formatter.dart';
import '../../../../features/settings/app_settings.dart';
import '../../../../core/models/block_status.dart';
import '../../../../core/models/message_block.dart';
import 'animated_message_item.dart';
import '../../../../features/dialogue_options/domain/dialogue_options.dart';
import 'dialogue_options_badge.dart';
import 'chat_end_anchored_sliver.dart';
import 'chat_message_list_display_cache.dart';
import 'chat_message_list_items.dart';
import 'chat_message_selection.dart';
import 'chat_selection_region.dart';
import 'chat_message_list_media_save.dart';
import 'chat_viewport_controller.dart';
import 'frontend_message_probe.dart';
import '../../../../features/observability/frontend_diagnostics_port.dart';
import '../../../../features/observability/frontend_diagnostics_provider.dart';

part 'chat_message_list_presentation.dart';
part 'chat_message_list_timeline.dart';
part 'chat_message_list_viewport.dart';

const double _kMessageItemVerticalPadding = 2.0;
const Duration _kHistoryLoadingOverlayMinDuration = Duration(milliseconds: 260);
const Duration _kTransientHandoffHoldDuration = Duration(milliseconds: 220);
const Duration _kAnimatedScrollToBottomMinDuration =
    Duration(milliseconds: 180);
const Duration _kAnimatedScrollToBottomMaxDuration =
    Duration(milliseconds: 320);
const double _kHistoryPagingTopFrictionBase = 0.05;
const double _kJumpToBottomVisibilityThreshold = 120.0;
const double _kJumpToBottomButtonSize = 44.0;

typedef _ChatStreamBubbleKey = ({
  String conversationId,
  String messageId,
});

/// 流式文字始终更新；用户接管时只暂停视口跟随，不冻结内容。
/// 按消息选择，非活跃气泡的输出始终为 null，不参与逐增量重建。
final _chatVisibleStreamProjectionProvider = Provider.autoDispose
    .family<ActiveStreamProjection?, _ChatStreamBubbleKey>((ref, key) {
  return ref.watch(activeStreamProjectionsProvider.select((projections) {
    final projection = projections[key.conversationId];
    return projection?.tailMessageId == key.messageId ? projection : null;
  }));
});

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

  /// 会话绑定的酒馆预设；决定聊天里语义标签的折叠／正文／选项呈现。
  final String? recipeId;

  /// 会话级聊天样式覆盖；null 跟随全局默认（ADR0047）。
  final ChatDisplayStyle? chatDisplayStyle;
  final String? avatarUrl;
  final String displayName;
  final ChatMessageSelection? selection;

  /// Space above the oldest message, inside the scrolling viewport.
  final double topOverlayHeight;
  final double bottomOverlayHeight;
  final void Function(Message message)? onEditMessage;
  final void Function(Message message)? onRegenerateMessage;
  final void Function(Message message)? onEnhanceRegenerateMessage;

  /// 上下文截断点消息ID（此消息之后为新话题）
  final String? contextStartMessageId;

  /// 分页加载：滑到顶部（历史消息方向）时触发
  final Future<void> Function()? onLoadMore;

  /// 首批历史尚未返回。用于区分历史恢复与真正的新消息入场。
  final bool isInitialLoading;

  /// 是否正在加载更多
  final bool isLoadingMore;

  /// 是否还有更多历史消息可加载
  final bool hasMoreMessages;

  /// 统一管理聊天视窗控制权的控制器。
  final ChatViewportController viewportController;

  @visibleForTesting
  final ValueChanged<String>? onDebugItemBuilt;

  @visibleForTesting
  final ValueChanged<int>? onDebugListItemCountChanged;

  @visibleForTesting
  final ValueChanged<String>? onDebugAutoScrollRequested;

  const ChatMessageList({
    super.key,
    required this.messages,
    this.transientMessages = const <Message>[],
    required this.conversationId,
    this.recipeId,
    this.chatDisplayStyle,
    this.avatarUrl,
    required this.displayName,
    this.selection,
    this.topOverlayHeight = 0,
    this.bottomOverlayHeight = 0,
    this.onEditMessage,
    this.onRegenerateMessage,
    this.onEnhanceRegenerateMessage,
    this.contextStartMessageId,
    this.onLoadMore,
    this.isInitialLoading = false,
    this.isLoadingMore = false,
    this.hasMoreMessages = true,
    required this.viewportController,
    this.onDebugListItemCountChanged,
    this.onDebugItemBuilt,
    this.onDebugAutoScrollRequested,
  });

  @override
  ConsumerState<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends ConsumerState<ChatMessageList> {
  final Set<String> _pendingAnimationIds = <String>{};
  // 只记录动画裁决变化，不逐次 build 写盘。这个缓存不参与动画/滚动决策。
  final Map<String, (bool, bool, bool)> _diagnosticAnimationStates = {};
  FrontendDiagnosticContext? _diagnosticViewport;
  FrontendDiagnosticContext get _listDiagnosticContext {
    if (_diagnosticViewport?.conversationId != widget.conversationId) {
      _diagnosticAnimationStates.clear();
      _diagnosticViewport = ref.read(frontendDiagnosticsProvider).child(
          null, FrontendStage.viewportAttached,
          conversationId: widget.conversationId);
    }
    return _diagnosticViewport!;
  }

  final GlobalKey _listViewportKey =
      GlobalKey(debugLabel: 'chat_message_list_viewport');
  final Key _centerKey = const ValueKey<String>('chat_message_list_center');
  DateTime? _latestAnimatedAt;
  List<ChatMessageListItem> _cachedListItems = [];

  /// 长历史入场将分界固定在最后一个显示项，而非整条 raw 回复的开头。
  /// 这样 reverse history sliver 可从末尾惰性布局，不必先排完上百段。
  /// 分界在本次页面生命周期内保持，手势/新消息不会搬动已显示的气泡。
  String? _entrySplitItemKey;
  _TimelineSplitBoundary? _detachedSplitBoundary;
  _TimelineSplitBoundary? _pendingDetachedSplitBoundary;
  _TimelineSplitBoundary? _renderedActiveBoundary;
  bool _renderedPinLatestTail = false;

  /// 缓存的消息格式化配置（用于检测配置变化）
  MessageFormatConfig? _cachedFormatConfig;

  /// 当前会话是否为文档样式（ADR0047），build 时更新，供气泡渲染读取。
  bool _documentStyle = false;

  /// 上次统计“聊天中发现”标签时的列表项，列表重建后才重新统计。
  List<ChatMessageListItem>? _observedItems;

  void _observeUnknownTags(List<ChatMessageListItem> items) {
    if (identical(items, _observedItems)) return;
    _observedItems = items;
    final names = collectUnknownReplyTags(_stableMessages, _tagPresentation);
    if (names.isEmpty) return;
    final key = observedTagsKey(widget.recipeId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(observedUnknownTagsProvider.notifier);
      final known = notifier.state[key] ?? const <String>{};
      if (known.containsAll(names)) return;
      notifier.state = {
        ...notifier.state,
        key: {...known, ...names},
      };
    });
  }

  /// 当前会话预设的语义标签呈现（ADR0046），变化时重建列表项。
  TagPresentationMap _tagPresentation = const {};
  String _tagPresentationSignature = '';

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

  /// 入场收敛窗（07-20-chat-entry-bottom-anchor v3 裁决）：
  /// 初始置底完成后开窗，窗内 ScrollMetricsNotification 位移只可能来自
  /// 纯渲染层长高（表情/图片解码、字体加载、视口尺寸变化），metricsReanchor
  /// 可安全重锚。首次实质性时间线结构变化（有序消息 ID 全序列任一位置
  /// 变化、历史 prepend、规范化后的 contextStart 变化；列表实例变化但
  /// ID 结构等同的刷新不算）、用户手势接管或历史分页锁即一次性关窗——
  /// 结构性变化后的锚定归既有稳定化路径裁决（贴底时新 AI 消息不拉底等
  /// 语义，由 auto_scroll_guard 守卫锁定）。conversationId 切换时随初始
  /// 置底标记一起复位，下次进入重新开窗。
  bool _entryRenderConvergenceActive = false;

  /// 入场动画生命周期静默（审查 R2）：入场动画期间的 extent 增长是
  /// 结构性来源，metricsReanchor 须静默让路。以「最近一次创建的入场动画
  /// 是否已结束」的事实信号为准（AnimatedMessageItem.onFinished），
  /// 不用帧时间戳猜时长——warm-up 帧跳变、timeDilation、长帧都会失真。
  /// serial 对账防旧动画的完成回调清掉新动画的静默。
  int _entranceAnimationSerial = 0;
  int? _activeEntranceAnimationSerial;
  double _manualDetachedDistanceToBottom = 0;

  /// 活跃区 sliver 的布局期贴底修正开关。跟随贴底时，气泡长高的那一帧
  /// 就把 pixels 修正到底部，不再先画一帧错位再由帖后 jumpTo 补位（流式
  /// 增长「一卡一卡」的直接来源）。在原本调度帖后稳底的位置 arm；用户
  /// 手势、历史分页、切到 detached 时 disarm；入场动画进行中延长保持，
  /// 让 SizeTransition 逐帧长高全程贴底。帖后稳底路径保留为兜底。
  late final ChatEndAnchorController _endAnchor = ChatEndAnchorController(
    isHoldActive: () => _activeEntranceAnimationSerial != null,
  );

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
  int _historyViewportRestoreSerial = 0;
  bool _historyViewportRestorePending = false;
  bool _holdListForHistoryPagingEmptyTimeline = false;
  List<Message> _heldTimelineMessagesForLayout = const <Message>[];
  bool _isUserScrollActive = false;
  final Set<int> _pressedPointers = <int>{};
  int _viewportInteractionSerial = 0;
  int? _followLatestStabilizationSerial;

  bool get _userOwnsViewport =>
      _pressedPointers.isNotEmpty || _isUserScrollActive;

  bool get _canFollowLatest =>
      widget.selection?.active != true &&
      _autoScrollEnabled &&
      !_userOwnsViewport &&
      !_isProgrammaticScroll &&
      !_historyPagingLockActive;

  List<Message> get _stableMessages => widget.messages;

  // 合并去重＋排序是 O(n log n)，build/didUpdateWidget 一帧内会多次读取；
  // 按两个输入列表的引用身份缓存，同一对输入只算一次。
  List<Message>? _mergedTimelineStable;
  List<Message>? _mergedTimelineTransient;
  List<Message> _mergedTimeline = const <Message>[];

  List<Message> get _currentTimelineMessages {
    final stable = _stableMessages;
    final transient = widget.transientMessages;
    if (!identical(stable, _mergedTimelineStable) ||
        !identical(transient, _mergedTimelineTransient)) {
      _mergedTimelineStable = stable;
      _mergedTimelineTransient = transient;
      _mergedTimeline = _mergeTimelineMessages(stable, transient);
    }
    return _mergedTimeline;
  }

  bool get _hasTransientTimelineContent => widget.transientMessages.isNotEmpty;

  bool get _hasTimelineContent => _currentTimelineMessages.isNotEmpty;

  bool get _autoScrollEnabled => widget.viewportController.shouldFollowLatest;

  void _updateState(VoidCallback fn) {
    setState(fn);
  }

  @override
  void initState() {
    super.initState();
    widget.selection?.addListener(_onSelectionChanged);
    _bindViewportController(widget.viewportController);
    _showHistoryLoadingOverlay = widget.isLoadingMore && widget.hasMoreMessages;
    if (_showHistoryLoadingOverlay) {
      _historyLoadingOverlayShownAt = DateTime.now();
    }
    if (_currentTimelineMessages.isNotEmpty) {
      _latestAnimatedAt = _currentTimelineMessages.last.createdAt;
    }
    _hydrateInitialListItems(
      ref
          .read(chatDisplayPolicyProvider(widget.chatDisplayStyle))
          .effectiveFormatConfig,
    );
    _prepareTailFirstEntryLayout();

    // 滚动控制只保留“用户手势优先 + 软跟随”语义，不再做像素补偿。
    _scrollController = ScrollController();
    _scrollController.addListener(_onScroll);
    if (_autoScrollEnabled && _hasTimelineContent) {
      _requestScrollToBottom('initState');
    }
    _subscribeActiveStreamTailSignal();
  }

  /// G2.1 活跃流通道窄信号（07-20 design v2 §2.7）：通道尾文本增长只调度
  /// 视口稳底，不重建列表。用 listenManual 显式长驻订阅——本 widget 在纯
  /// delta 期间不 rebuild，build 期 ref.listen 的订阅在该场景下不可靠
  ///（实测首次变化后失联）。policy off 不建立订阅（B-01 严格回滚面）。
  void _subscribeActiveStreamTailSignal() {
    if (!_streamChannelEnabled) return;
    _tailSignalSub?.close();
    _tailSignalSub = ref.listenManual<(String?, int, ActiveStreamPhase)?>(
      activeStreamProjectionsProvider.select((projections) {
        final projection = projections[widget.conversationId];
        return projection == null
            ? null
            : (
                projection.tailMessageId,
                projection.tailText.length,
                projection.phase,
              );
      }),
      (previous, next) {
        // 仅处理「同一尾、同相位、文本增长」：新壳/换尾属结构事件，
        // 由时间线写入触发的 didUpdateWidget 稳底路径负责（S-04）。
        if (previous == null || next == null) return;
        if (previous.$1 != next.$1 || previous.$3 != next.$3) return;
        if (next.$2 <= previous.$2) return;
        _onActiveStreamTailChanged();
      },
    );
  }

  void _onSelectionChanged() {
    if (!mounted) return;
    if (widget.selection?.active == true) {
      widget.viewportController.onUserGesture();
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.selection?.removeListener(_onSelectionChanged);
    _viewportInteractionSerial += 1;
    _tailSignalSub?.close();
    _unbindViewportController(widget.viewportController);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _showJumpToBottom.dispose();
    _historyLoadingOverlayHideTimer?.cancel();
    _transientHandoffHoldTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection) {
      oldWidget.selection?.removeListener(_onSelectionChanged);
      widget.selection?.addListener(_onSelectionChanged);
    }
    if (oldWidget.conversationId != widget.conversationId) {
      _subscribeActiveStreamTailSignal();
    }
    _handleDidUpdateWidget(oldWidget);
  }

  /// G2.1 活跃流通道开关（应用生命周期常量；off＝严格回滚面）。
  bool get _streamChannelEnabled =>
      ref.read(streamProjectionPolicyProvider).useActiveStreamChannel;

  ProviderSubscription<(String?, int, ActiveStreamPhase)?>? _tailSignalSub;

  @override
  Widget build(BuildContext context) {
    final actions = ref.watch(chatActionsProvider);
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

    // 分段配置取会话显示策略（ADR0047）：文档模式强制不分段。
    final formatConfig = ref.watch(
      chatDisplayPolicyProvider(widget.chatDisplayStyle)
          .select((policy) => policy.effectiveFormatConfig),
    );
    _documentStyle = ref.watch(
      chatDisplayPolicyProvider(widget.chatDisplayStyle)
          .select((policy) => policy.style == ChatDisplayStyle.document),
    );

    final tagPresentation = ref
            .watch(tagPresentationForRecipeProvider(widget.recipeId))
            .valueOrNull ??
            builtinPresetTagMapping.presentationMap;
    final tagSignature = _signTagPresentation(tagPresentation);
    final tagsChanged = tagSignature != _tagPresentationSignature;
    if (tagsChanged) {
      _tagPresentation = tagPresentation;
      _tagPresentationSignature = tagSignature;
    }

    // 检测配置变化，需要重新构建列表项
    if (_hasHydratedInitialListItems &&
        (_cachedFormatConfig != formatConfig || tagsChanged)) {
      _updateListItems(formatConfig);
    }

    final listItems = _cachedListItems;
    _observeUnknownTags(listItems);
    final selection = widget.selection;
    if (selection != null) {
      final pruned = selection.updateMessages(
        listItems.map(chatListItemSelectionMessage).whereType<Message>(),
      );
      if (pruned) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(widget.selection, selection)) {
            selection.refresh();
          }
        });
      }
    }
    final timelineMessagesForSectioning =
        _holdListForHistoryPagingEmptyTimeline &&
                _currentTimelineMessages.isEmpty &&
                _heldTimelineMessagesForLayout.isNotEmpty
            ? _heldTimelineMessagesForLayout
            : _currentTimelineMessages;
    final boundaryIndex =
        _resolveActiveBoundaryIndex(timelineMessagesForSectioning);
    final boundaryMessage = boundaryIndex == null
        ? null
        : timelineMessagesForSectioning[boundaryIndex];
    // 发送会先切换 pinLatestTail，消息异步入库前也可能重建旧时间线。
    // 此时 user 组从 history 搬到 active，消息内容未变，didUpdateWidget
    // 不会稳底。必须按实际分区变化在布局期对齐，不能先画错再帖后补位。
    // 仅补首次切换到即时回底的分区变化；消息增删仍由时间线裁决，
    // 手势、分页和“回到底部”的滚动动画仍由原逻辑接管。
    final pinLatestTail = widget.viewportController.shouldPinLatestTail;
    if (_canFollowLatest &&
        !_historyViewportRestorePending &&
        !_renderedPinLatestTail &&
        pinLatestTail &&
        !widget.viewportController.scrollToBottomRequestAnimated &&
        _renderedActiveBoundary != null &&
        boundaryMessage != null &&
        (_renderedActiveBoundary!.messageId != boundaryMessage.id ||
            _renderedActiveBoundary!.createdAt != boundaryMessage.createdAt)) {
      _endAnchor.arm();
    }
    _renderedPinLatestTail = pinLatestTail;
    _renderedActiveBoundary = boundaryMessage == null
        ? null
        : _TimelineSplitBoundary(
            messageId: boundaryMessage.id,
            createdAt: boundaryMessage.createdAt);
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

    final content = Stack(
      children: [
        // ScrollMetricsNotification 不是 ScrollNotification 子类，须独立监听；
        // 覆盖「纯渲染层长高（表情/图片解码、字体、视口尺寸变化）不经
        // didUpdateWidget、follow-latest 稳定化收不到信号」的重锚缺口
        // （07-20-chat-entry-bottom-anchor）。
        NotificationListener<ScrollMetricsNotification>(
          onNotification: _handleScrollMetricsNotification,
          child: NotificationListener<ScrollNotification>(
            onNotification: _handleScrollNotification,
            child: Listener(
              onPointerDown: _handlePointerDown,
              onPointerSignal: _handlePointerSignal,
              onPointerUp: _handlePointerReleased,
              onPointerCancel: _handlePointerReleased,
              child: ScrollConfiguration(
                behavior: const _ChatMessageListScrollBehavior(),
                child: CustomScrollView(
                  key: _listViewportKey,
                  controller: _scrollController,
                  // Preserve the first drag delta while competing with a
                  // bubble's long-press recognizer.
                  dragStartBehavior: DragStartBehavior.down,
                  reverse: true,
                  center: _centerKey,
                  physics: const _ChatHistoryPagingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  cacheExtent: 500,
                  slivers: [
                    ChatEndAnchoredSliver(
                      controller: _endAnchor,
                      sliver: SliverPadding(
                        padding: EdgeInsets.only(
                          left: 4,
                          right: 4,
                          bottom: listBottomPadding,
                        ),
                        sliver: SliverList(delegate: activeDelegate),
                      ),
                    ),
                    SliverToBoxAdapter(
                      key: _centerKey,
                      child: const SizedBox.shrink(),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.only(
                        left: 4,
                        right: 4,
                        top: widget.topOverlayHeight + 10,
                      ),
                      sliver: SliverList(delegate: historyDelegate),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (showHistoryLoadingOverlay)
          Positioned(
            left: 0,
            right: 0,
            top: widget.topOverlayHeight + 12,
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
            if (widget.selection?.active == true) {
              return const SizedBox.shrink();
            }
            return Positioned(
              right: 14,
              bottom: jumpToBottomBottomOffset,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DialogueOptionsBadge(
                    key: ValueKey('dialogue_options_${widget.conversationId}'),
                    conversationId: widget.conversationId,
                    options: latestDialogueOptions(
                      _stableMessages,
                      tags: {
                        ...defaultDialogueOptionTags,
                        for (final entry in _tagPresentation.entries)
                          if (entry.value.presentation ==
                              TagPresentation.options)
                            entry.key,
                      },
                    ),
                    size: _kJumpToBottomButtonSize,
                  ),
                  if (show) ...[
                    const SizedBox(width: 10),
                    _buildJumpToBottomButton(context),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
    return ChatSelectionRegion(
      selection: widget.selection,
      scrollController: _scrollController,
      topInset: widget.topOverlayHeight,
      bottomInset: listBottomPadding,
      child: content,
    );
  }
}

String _signTagPresentation(TagPresentationMap map) =>
    (map.entries.map((e) => '${e.key}=${e.value.presentation.name}:${e.value.title}').toList()
          ..sort())
        .join(',');
