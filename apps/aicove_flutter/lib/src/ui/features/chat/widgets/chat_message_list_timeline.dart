part of 'chat_message_list.dart';

extension _ChatMessageListTimelineX on _ChatMessageListState {
  void _handleDidUpdateWidget(ChatMessageList oldWidget) {
    _syncHistoryLoadingOverlay();

    if (!identical(oldWidget.viewportController, widget.viewportController)) {
      _unbindViewportController(oldWidget.viewportController);
      _bindViewportController(widget.viewportController);
    }

    final historyPagingLocked = _historyPagingLockActive;
    if (historyPagingLocked) {
      _lockAutoScrollForHistoryPaging('historyPagingActive');
    }

    if (oldWidget.conversationId != widget.conversationId) {
      _invalidateViewportFollow();
      _cancelProgrammaticScrollTracking();
      _pressedPointers.clear();
      _isUserScrollActive = false;
      _historyViewportRestoreSerial += 1;
      _renderedActiveBoundary = null;
      _pendingAnimationIds.clear();
      _latestAnimatedAt = _currentTimelineMessages.isNotEmpty
          ? _currentTimelineMessages.last.createdAt
          : null;
      _didInitialBottomPosition = false;
      _entryRenderConvergenceActive = false;
      _activeEntranceAnimationSerial = null;
      _cachedFormatConfig = null;
      _cachedListItems = [];
      _entrySplitItemKey = null;
      _cachedChatImages = [];
      _detachedSplitBoundary = null;
      _pendingDetachedSplitBoundary = null;
      _historyViewportRestorePending = false;
      _holdListForHistoryPagingEmptyTimeline = false;
      _heldTimelineMessagesForLayout = const <Message>[];
      _hasHydratedInitialListItems = false;
      _showHistoryLoadingOverlay =
          widget.isLoadingMore && widget.hasMoreMessages;
      _historyLoadingOverlayShownAt =
          _showHistoryLoadingOverlay ? DateTime.now() : null;
      _hydrateInitialListItems(
        ref.read(appSettingsProvider).valueOrNull?.messageFormatConfig,
      );
      _prepareTailFirstEntryLayout();
      if (_autoScrollEnabled) {
        _requestScrollToBottom('conversationChanged');
      }
      return;
    }

    final messagesChanged = widget.messages != oldWidget.messages;
    final contextStartChanged =
        widget.contextStartMessageId != oldWidget.contextStartMessageId;
    final transientMessagesChanged =
        widget.transientMessages != oldWidget.transientMessages;
    final didPrependOlderHistory =
        messagesChanged && _didPrependOlderHistory(oldWidget);
    // 入场收敛窗关窗判定（v3 裁决＋审查 R1/S2）：实质性＝「有序消息 ID
    // 序列变化」——任一位置 ID 不同（含等长中间替换/重排）、增删、历史
    // prepend、contextStart（规范化后）变化均关窗；列表实例变化但 ID 结构
    // 等同的刷新（DB 回流新实例、同 ID 流式增长）不关窗，否则真机上窗口
    // 会在表情解码完成前被误关，入场重锚失效。O(n) 比较仅在 identity
    // 已变化时执行。
    if (_entryRenderConvergenceActive &&
        (messagesChanged || transientMessagesChanged || contextStartChanged)) {
      final previousTimeline = _mergeTimelineMessages(
        oldWidget.messages,
        oldWidget.transientMessages,
      );
      final nextTimeline = _currentTimelineMessages;
      final materialTimelineChange = didPrependOlderHistory ||
          _normalizedContextStartId(widget.contextStartMessageId) !=
              _normalizedContextStartId(oldWidget.contextStartMessageId) ||
          _timelineIdSequenceChanged(previousTimeline, nextTimeline);
      if (materialTimelineChange) {
        _entryRenderConvergenceActive = false;
      }
    }
    final recoveringFromHeldEmptyTimeline = messagesChanged &&
        oldWidget.messages.isEmpty &&
        widget.messages.isNotEmpty &&
        _holdListForHistoryPagingEmptyTimeline &&
        _heldTimelineMessagesForLayout.isNotEmpty &&
        _historyViewportRestorePending;
    final shouldPreserveHistoryViewport = (didPrependOlderHistory &&
            _shouldPreserveViewportForHistoryPrepend(oldWidget)) ||
        recoveringFromHeldEmptyTimeline;
    final previousPixels = shouldPreserveHistoryViewport
        ? _scrollController.position.pixels
        : null;
    final previousMaxScrollExtent = shouldPreserveHistoryViewport
        ? _scrollController.position.maxScrollExtent
        : null;
    final shouldStabilizeFollowLatestViewport =
        _shouldStabilizeFollowLatestViewport(
      oldWidget,
      messagesChanged: messagesChanged,
      transientMessagesChanged: transientMessagesChanged,
      didPrependOlderHistory: didPrependOlderHistory,
    );
    if (_pendingTransientHandoffIds.isNotEmpty &&
        _stableMessagesContainAllIds(
          widget.messages,
          _pendingTransientHandoffIds,
        )) {
      _clearPendingTransientHandoffHold();
    }
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
    final timelineOverlayChanged = transientMessagesChanged;

    if (holdListForTransientEmptyWindow) {
      final previousTimelineMessages = _mergeTimelineMessages(
        oldWidget.messages,
        oldWidget.transientMessages,
      );
      if (previousTimelineMessages.isNotEmpty) {
        _holdListForHistoryPagingEmptyTimeline = true;
        _heldTimelineMessagesForLayout = previousTimelineMessages;
      }
      _debugAutoScroll('hold:transientEmptyWindow');
      return;
    }
    if (holdListForTransientHandoffWindow) {
      _debugAutoScroll('hold:transientHandoffWindow');
      return;
    }

    if (messagesChanged || contextStartChanged) {
      _updateListItems(_cachedFormatConfig);
      final skipViewportRestoreForHistoryPaging =
          _historyViewportRestorePending;
      if (shouldPreserveHistoryViewport &&
          !skipViewportRestoreForHistoryPaging &&
          previousPixels != null &&
          previousMaxScrollExtent != null) {
        _scheduleHistoryViewportRestore(
          previousPixels: previousPixels,
          previousMaxScrollExtent: previousMaxScrollExtent,
        );
      }
      if (didPrependOlderHistory || recoveringFromHeldEmptyTimeline) {
        _historyViewportRestorePending = false;
      }
    } else if (timelineOverlayChanged) {
      _updateListItems(_cachedFormatConfig);
    }

    if (!didPrependOlderHistory &&
        !widget.isLoadingMore &&
        !_isLoadingTriggered &&
        !widget.hasMoreMessages) {
      _historyViewportRestorePending = false;
    }

    final sourceMessages = _currentTimelineMessages;
    if (sourceMessages.isEmpty) {
      final shouldHoldViewportStateForHistoryPaging =
          _historyViewportRestorePending ||
              widget.isLoadingMore ||
              oldWidget.isLoadingMore ||
              _isLoadingTriggered;
      if (shouldHoldViewportStateForHistoryPaging) {
        final previousTimelineMessages = _mergeTimelineMessages(
          oldWidget.messages,
          oldWidget.transientMessages,
        );
        if (previousTimelineMessages.isNotEmpty) {
          _holdListForHistoryPagingEmptyTimeline = true;
          _heldTimelineMessagesForLayout = previousTimelineMessages;
        }
        _debugAutoScroll('hold:emptyTimelineForHistoryPaging');
        return;
      }
      _holdListForHistoryPagingEmptyTimeline = false;
      _heldTimelineMessagesForLayout = const <Message>[];
      _detachedSplitBoundary = null;
      _pendingDetachedSplitBoundary = null;
      _pendingAnimationIds.clear();
      _latestAnimatedAt = null;
      return;
    }
    _holdListForHistoryPagingEmptyTimeline = false;
    _heldTimelineMessagesForLayout = const <Message>[];

    if (shouldStabilizeFollowLatestViewport) {
      // 布局期同帧贴底为主，只保留合并过且可失效的帧后兜底。
      _endAnchor.arm();
      _scheduleFollowLatestViewportStabilization(
        targetDistanceToBottom: 0,
      );
    } else if (messagesChanged || transientMessagesChanged) {
      // 不跟随的结构变化（贴底时新 AI 消息不拉底等裁决）不得被上一帧
      // 残留的 armed 状态抢成贴底。
      _endAnchor.disarm();
    }

    // 首批历史从异步窗口到达，不是新收到的消息。否则全部气泡从零高
    // 展开，初始贴底会测到尚未展开的尾部，随后又被动画期守卫阻止补位。
    // 只认显式加载边界：已加载的空会话随后收到的新消息仍保留入场动画。
    if (oldWidget.isInitialLoading && !widget.isInitialLoading) {
      _prepareTailFirstEntryLayout();
      _pendingAnimationIds.clear();
      _latestAnimatedAt = sourceMessages.last.createdAt;
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
        _updateState(() {
          // 跟随时免动画的消息不能留下待播资格，否则切到手势后，
          // 下一次分段刷新会给已经显示的旧气泡补播展开动画。
          _pendingAnimationIds.addAll(
              newMessages.where(_shouldAnimatePendingMessage).map((m) => m.id));
        });
      } else {
        _pendingAnimationIds.removeAll(newMessages.map((m) => m.id));
      }
    }

    if (didPrependOlderHistory && historyPagingLocked) {
      _debugAutoScroll('blocked:historyPrepend by historyPagingLock');
    }
  }

  List<Message> _mergeTimelineMessages(
    List<Message> stableMessages,
    List<Message> transientMessages,
  ) {
    return mergeChatTimelineMessagesForDisplay(
      stableMessages,
      transientMessages,
    );
  }

  /// contextStartMessageId 规范化（审查 S2）：与 topic divider 消费语义对齐，
  /// trim 后空串视同 null，避免 null↔''/空白漂移被误判为实质变化。
  String? _normalizedContextStartId(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  /// 有序消息 ID 序列是否变化（审查 R1）：任一位置 ID 不同即为实质性
  /// 结构变化——覆盖增删、prepend、交接换 ID、等长中间替换与重排；
  /// 同 ID 新实例/内容增长不算（那是刷新或流式增长，不关入场收敛窗）。
  bool _timelineIdSequenceChanged(
    List<Message> previous,
    List<Message> next,
  ) {
    if (previous.length != next.length) return true;
    for (var i = 0; i < previous.length; i++) {
      if (previous[i].id != next[i].id) return true;
    }
    return false;
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
    if (item is ChatNewTopicDividerItem) {
      return 'topic:${item.associatedMessageId}';
    }
    return item.runtimeType.toString();
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
    if (item is ChatTimeDividerItem) {
      return item.associatedMessageId;
    }
    if (item is ChatNewTopicDividerItem) {
      return item.associatedMessageId;
    }
    return null;
  }

  String? _resolveTopicDividerAnchorMessageId(List<Message> timelineMessages) {
    final normalizedContextStartMessageId =
        widget.contextStartMessageId?.trim();
    if (normalizedContextStartMessageId == null ||
        normalizedContextStartMessageId.isEmpty) {
      return null;
    }

    String? anchorMessageId;
    for (final message in timelineMessages) {
      if (message.sourceMessageIdOrSelf == normalizedContextStartMessageId) {
        anchorMessageId = message.id;
      }
    }
    return anchorMessageId;
  }

  List<ChatMessageListItem> _decorateItemsWithTopicDivider(
    List<ChatMessageListItem> items, {
    required String? anchorMessageId,
  }) {
    final strippedItems = items
        .where((item) => item is! ChatNewTopicDividerItem)
        .toList(growable: false);
    if (anchorMessageId == null ||
        anchorMessageId.isEmpty ||
        strippedItems.isEmpty) {
      return strippedItems;
    }

    var insertionIndex = -1;
    for (var index = 0; index < strippedItems.length; index++) {
      if (_messageIdForListItem(strippedItems[index]) == anchorMessageId) {
        insertionIndex = index;
      }
    }
    if (insertionIndex < 0) {
      return strippedItems;
    }

    final decoratedItems = List<ChatMessageListItem>.from(strippedItems);
    decoratedItems.insert(
      insertionIndex + 1,
      ChatNewTopicDividerItem(associatedMessageId: anchorMessageId),
    );
    return decoratedItems;
  }

  _ChatListSections _decorateSectionsWithTopicDivider(
    _ChatListSections sections,
    List<Message> timelineMessages,
  ) {
    final anchorMessageId = _resolveTopicDividerAnchorMessageId(
      timelineMessages,
    );
    final activeHasAnchor = anchorMessageId != null &&
        sections.activeItems.any(
          (item) => _messageIdForListItem(item) == anchorMessageId,
        );
    final historyHasAnchor = anchorMessageId != null &&
        sections.historyItems.any(
          (item) => _messageIdForListItem(item) == anchorMessageId,
        );

    return _ChatListSections(
      historyItems: _decorateItemsWithTopicDivider(
        sections.historyItems,
        // 入场分界可落在同一消息的两个显示分段之间，分界线只跟最后一段。
        anchorMessageId:
            historyHasAnchor && !activeHasAnchor ? anchorMessageId : null,
      ),
      activeItems: _decorateItemsWithTopicDivider(
        sections.activeItems,
        anchorMessageId: activeHasAnchor ? anchorMessageId : null,
      ),
    );
  }

  void _prepareTailFirstEntryLayout() {
    final messages = _currentTimelineMessages;
    if (messages.isEmpty ||
        _cachedListItems.isEmpty ||
        messages.any((message) => message.status == 'sending')) {
      return;
    }
    final start = resolveChatMessageListActiveBoundaryIndex(messages);
    if (start == null) return;
    final activeIds = messages.skip(start).map((message) => message.id).toSet();
    final activeCount = _cachedListItems
        .where(
          (item) => activeIds.contains(_messageIdForListItem(item)),
        )
        .length;
    // 小窗口沿用原分区；长回复才需要避免从组头走到组尾的 O(n) 排版。
    if (activeCount > 12) {
      _entrySplitItemKey = _listItemStableKey(_cachedListItems.last);
    }
  }

  int _entrySplitIndex(List<ChatMessageListItem> items) {
    final key = _entrySplitItemKey;
    if (key == null) return -1;
    return items.lastIndexWhere((item) => _listItemStableKey(item) == key);
  }

  int? _resolveActiveBoundaryIndex(List<Message> timelineMessages) {
    final entryIndex = _entrySplitIndex(_cachedListItems);
    if (entryIndex >= 0) {
      final id = _messageIdForListItem(_cachedListItems[entryIndex]);
      final index = timelineMessages.indexWhere((message) => message.id == id);
      if (index >= 0) return index;
    }
    final boundary = _effectiveDetachedSplitBoundary();
    return resolveChatMessageListActiveBoundaryIndex(
      timelineMessages,
      detachedBoundaryMessageId: boundary?.messageId,
      detachedBoundaryCreatedAt: boundary?.createdAt,
      preserveAdjacentUserGroupInFollowLatest:
          widget.viewportController.shouldPinLatestTail,
    );
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

    final entryIndex = _entrySplitIndex(items);
    if (entryIndex >= 0) {
      return _ChatListSections(
        historyItems: items.sublist(0, entryIndex),
        activeItems: items.sublist(entryIndex),
      );
    }
    // 原入场项已被删除/窗口淘汰或分段设置改变，回到正常消息分区。
    _entrySplitItemKey = null;
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

    for (final item in items) {
      final messageId = _messageIdForListItem(item);
      final target = messageId != null && activeIds.contains(messageId)
          ? activeItems
          : historyItems;
      target.add(item);
    }

    return _ChatListSections(
      historyItems: historyItems,
      activeItems: activeItems,
    );
  }

  bool _shouldHoldListForTransientEmptyWindow(
    ChatMessageList oldWidget, {
    required bool messagesChanged,
  }) {
    if (!messagesChanged) return false;
    if (widget.messages.isNotEmpty || oldWidget.messages.isEmpty) return false;
    if (_cachedListItems.isEmpty) return false;

    return _historyViewportRestorePending ||
        widget.isLoadingMore ||
        oldWidget.isLoadingMore ||
        _isLoadingTriggered;
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
      _updateState(() {
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

  bool _shouldPreserveViewportForHistoryPrepend(ChatMessageList oldWidget) {
    if (!_scrollController.hasClients || _isProgrammaticScroll) {
      return false;
    }

    if (!_didPrependOlderHistory(oldWidget)) {
      return false;
    }

    return _historyViewportRestorePending ||
        !_autoScrollEnabled ||
        oldWidget.isLoadingMore ||
        widget.isLoadingMore ||
        _isLoadingTriggered;
  }

  bool _didPrependOlderHistory(ChatMessageList oldWidget) {
    final previousMessages = _mergeTimelineMessages(
      oldWidget.messages,
      oldWidget.transientMessages,
    );
    final currentMessages = _currentTimelineMessages;
    if (previousMessages.isEmpty || currentMessages.isEmpty) {
      return false;
    }
    if (currentMessages.length <= previousMessages.length) {
      return false;
    }
    final previousTail = previousMessages.last;
    final currentTail = currentMessages.last;
    final sameTailMessage = previousTail.id == currentTail.id &&
        previousTail.createdAt == currentTail.createdAt &&
        previousTail.role == currentTail.role;
    if (!sameTailMessage) {
      return false;
    }

    final previousHead = previousMessages.first;
    final currentHead = currentMessages.first;
    final prependedOlderHistory = previousHead.id != currentHead.id ||
        previousHead.createdAt != currentHead.createdAt;
    if (!prependedOlderHistory) {
      return false;
    }
    return true;
  }

  void _clearPendingTransientHandoffHold() {
    _transientHandoffHoldTimer?.cancel();
    _transientHandoffHoldTimer = null;
    _pendingTransientHandoffIds = <String>{};
  }

  /// G2.1 窄信号处理：活跃流通道文本增长导致气泡局部增高时，
  /// 在贴底状态下调度既有视口稳底——守卫条件与 didUpdateWidget 稳底一致，
  /// detached/分页/程序滚动语义不变。
  void _onActiveStreamTailChanged() {
    if (!_canFollowLatest) return;
    if (!_scrollController.hasClients) return;
    if (!_scrollController.position.hasContentDimensions) return;
    // 同帧布局修正已经覆盖真实增长，不再为每个 delta 排队多帧和
    // 260ms jumpTo；这类旧回调会在用户切换控制权后重新抢占视口。
    _endAnchor.arm();
    _scheduleFollowLatestViewportStabilization(targetDistanceToBottom: 0);
  }

  bool _shouldStabilizeFollowLatestViewport(
    ChatMessageList oldWidget, {
    required bool messagesChanged,
    required bool transientMessagesChanged,
    required bool didPrependOlderHistory,
  }) {
    if (!_canFollowLatest) return false;
    if (!_scrollController.hasClients) {
      return false;
    }
    final position = _scrollController.position;
    if (!position.hasContentDimensions) {
      return false;
    }

    final bottomOverlayChanged =
        (widget.bottomOverlayHeight - oldWidget.bottomOverlayHeight).abs() >
            0.5;
    if (bottomOverlayChanged) {
      return true;
    }

    final timelineChanged = messagesChanged || transientMessagesChanged;
    if (!timelineChanged || didPrependOlderHistory) {
      return false;
    }

    final previousMessages = _mergeTimelineMessages(
      oldWidget.messages,
      oldWidget.transientMessages,
    );
    final currentMessages = _currentTimelineMessages;
    if (previousMessages.isEmpty || currentMessages.isEmpty) {
      return false;
    }

    final previousTail = previousMessages.last;
    final currentTail = currentMessages.last;
    final sameTail = previousTail.id == currentTail.id &&
        previousTail.createdAt == currentTail.createdAt &&
        previousTail.role == currentTail.role;
    if (sameTail) {
      final layoutChangeReason =
          _tailHasActionableLayoutChange(previousTail, currentTail);
      if (layoutChangeReason == null) {
        return false;
      }
      return true;
    }

    if (!widget.viewportController.shouldPinLatestTail) {
      return false;
    }

    if (currentMessages.length < previousMessages.length) {
      return false;
    }

    if (currentTail.createdAt.isAfter(previousTail.createdAt)) {
      return true;
    }

    final sameTimeDiffId = currentTail.createdAt == previousTail.createdAt &&
        (currentTail.id != previousTail.id ||
            currentTail.role != previousTail.role);
    return sameTimeDiffId;
  }

  /// 判断两条「同 id/时间/role」的尾消息之间，是否发生了需要重新贴底的布局变化。
  ///
  /// 返回 null 表示只是纯字段填充（如图片 url/localPath/base64 填入），无几何影响，
  /// 可安全跳过程序化 stabilize；返回非空字符串表示发生了布局变化（命中项），需触发稳底。
  ///
  /// codex 审查提醒：必须纳入 message.status、TextBlock status、block 数量/类型，
  /// 否则会误伤「尾消息分段贴底」（assistant sending→sent 才进分段路径）。
  String? _tailHasActionableLayoutChange(Message prev, Message cur) {
    if (prev.status != cur.status) {
      return 'status ${prev.status ?? "null"}→${cur.status ?? "null"}';
    }

    final prevBlocks = prev.blocks;
    final curBlocks = cur.blocks;
    final prevLen = prevBlocks?.length ?? 0;
    final curLen = curBlocks?.length ?? 0;
    if (prevLen != curLen) {
      return 'blocks $prevLen→$curLen';
    }
    if (prevLen == 0) {
      return null;
    }

    for (var i = 0; i < curLen; i++) {
      final pb = prevBlocks![i];
      final cb = curBlocks![i];
      final prevType = pb.runtimeType;
      final curType = cb.runtimeType;
      if (prevType != curType) {
        return 'block[$i] type $prevType→$curType';
      }
      if (pb is TextBlock && cb is TextBlock) {
        if (pb.content != cb.content) {
          return 'block[$i] text content';
        }
        if (pb.status != cb.status) {
          return 'block[$i] text status ${pb.status}→${cb.status}';
        }
      } else if (pb is ImageBlock && cb is ImageBlock) {
        // 仅 width/height 的有无/数值变化算几何跳变；
        // url/localPath/base64 标识字段填充不算（配合主修2 估算尺寸后无几何影响）。
        if (pb.width != cb.width || pb.height != cb.height) {
          return 'block[$i] image size '
              '${pb.width}x${pb.height}→${cb.width}x${cb.height}';
        }
      }
    }
    return null;
  }
}
