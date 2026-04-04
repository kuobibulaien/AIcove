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
const Duration _kAnimatedScrollToBottomMinDuration =
    Duration(milliseconds: 180);
const Duration _kAnimatedScrollToBottomMaxDuration =
    Duration(milliseconds: 320);
const double _kHistoryPagingTopFrictionBase = 0.05;
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
    _historyLoadingOverlayHideTimer?.cancel();
    _transientHandoffHoldTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _handleDidUpdateWidget(oldWidget);
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
    final showJumpToBottomButton = _shouldShowJumpToBottomButton();
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
        if (showJumpToBottomButton)
          Positioned(
            right: 14,
            bottom: jumpToBottomBottomOffset,
            child: _buildJumpToBottomButton(context),
          ),
      ],
    );
  }
}
