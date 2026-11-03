part of 'chat_message_list.dart';

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

  /// 停在底部时底部内容变矮（生成结束换成更短的最终消息等），视口会越过
  /// 底边；直接收回，不留给弹簧回弹。reverse 列表的底边是 minScrollExtent。
  /// 只认上一刻在底、底边上移而顶边不动的情况，顶边一起变的（历史区
  /// 增删、分区挪动）照旧交给原逻辑；用户拖动或惯性滚动时照常回弹。
  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final pixels = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    final tolerance = Tolerance.defaultTolerance.distance;
    final wasAtBottom =
        (oldPosition.pixels - oldPosition.minScrollExtent).abs() <= tolerance;
    final bottomContentShrank =
        newPosition.minScrollExtent > oldPosition.minScrollExtent + tolerance &&
            (newPosition.maxScrollExtent - oldPosition.maxScrollExtent).abs() <=
                tolerance;
    if (!isScrolling &&
        wasAtBottom &&
        bottomContentShrank &&
        pixels < newPosition.minScrollExtent) {
      return newPosition.minScrollExtent;
    }
    return pixels;
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
