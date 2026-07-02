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
      _pendingAnimationIds.clear();
      _latestAnimatedAt = _currentTimelineMessages.isNotEmpty
          ? _currentTimelineMessages.last.createdAt
          : null;
      _didInitialBottomPosition = false;
      _cachedFormatConfig = null;
      _cachedListItems = [];
      _cachedChatImages = [];
      _detachedSplitBoundary = null;
      _pendingDetachedSplitBoundary = null;
      _historyViewportRestorePending = false;
      _invalidateDetachedExtentRestore();
      _holdListForHistoryPagingEmptyTimeline = false;
      _heldTimelineMessagesForLayout = const <Message>[];
      _hasHydratedInitialListItems = false;
      _cancelDeferredStreamingListUpdate();
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
    final contextStartChanged =
        widget.contextStartMessageId != oldWidget.contextStartMessageId;
    final transientMessagesChanged =
        widget.transientMessages != oldWidget.transientMessages;
    final didPrependOlderHistory =
        messagesChanged && _didPrependOlderHistory(oldWidget);
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
      final shouldDeferListUpdate = _shouldDeferStreamingListUpdate(
        oldWidget,
        messagesChanged: messagesChanged,
        transientMessagesChanged: transientMessagesChanged,
        contextStartChanged: contextStartChanged,
        didPrependOlderHistory: didPrependOlderHistory,
      );
      if (shouldDeferListUpdate) {
        _deferStreamingListUpdate(_cachedFormatConfig);
      } else {
        _cancelDeferredStreamingListUpdate();
        _updateListItemsWithDetachedExtentGuard(_cachedFormatConfig);
      }
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
      if (_shouldDeferStreamingListUpdate(
        oldWidget,
        messagesChanged: messagesChanged,
        transientMessagesChanged: transientMessagesChanged,
        contextStartChanged: contextStartChanged,
        didPrependOlderHistory: didPrependOlderHistory,
      )) {
        _deferStreamingListUpdate(_cachedFormatConfig);
      } else {
        _cancelDeferredStreamingListUpdate();
        _updateListItemsWithDetachedExtentGuard(_cachedFormatConfig);
      }
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
      _scheduleFollowLatestViewportStabilization(
        targetDistanceToBottom: 0,
      );
      if (widget.viewportController.shouldPinLatestTail) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _scheduleFollowLatestViewportStabilization(
            targetDistanceToBottom: 0,
            retryFrames: 1,
          );
        });
        Future<void>.delayed(const Duration(milliseconds: 260), () {
          if (!mounted) return;
          _scheduleFollowLatestViewportStabilization(
            targetDistanceToBottom: 0,
            retryFrames: 1,
          );
        });
      }
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
          _pendingAnimationIds.addAll(newMessages.map((m) => m.id));
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
        anchorMessageId: historyHasAnchor ? anchorMessageId : null,
      ),
      activeItems: _decorateItemsWithTopicDivider(
        sections.activeItems,
        anchorMessageId: activeHasAnchor ? anchorMessageId : null,
      ),
    );
  }

  int? _resolveActiveBoundaryIndex(List<Message> timelineMessages) {
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

  bool _shouldStabilizeFollowLatestViewport(
    ChatMessageList oldWidget, {
    required bool messagesChanged,
    required bool transientMessagesChanged,
    required bool didPrependOlderHistory,
  }) {
    if (!_autoScrollEnabled ||
        _historyPagingLockActive ||
        _isProgrammaticScroll) {
      return false;
    }
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

  bool _shouldDeferStreamingListUpdate(
    ChatMessageList oldWidget, {
    required bool messagesChanged,
    required bool transientMessagesChanged,
    required bool contextStartChanged,
    required bool didPrependOlderHistory,
  }) {
    if (!_isUserScrollActive ||
        _isProgrammaticScroll ||
        contextStartChanged ||
        didPrependOlderHistory ||
        (!messagesChanged && !transientMessagesChanged)) {
      return false;
    }
    return _hasStreamingTimelineMessage(
          _mergeTimelineMessages(
            oldWidget.messages,
            oldWidget.transientMessages,
          ),
        ) ||
        _hasStreamingTimelineMessage(_currentTimelineMessages);
  }

  bool _hasStreamingTimelineMessage(List<Message> messages) {
    for (final message in messages) {
      if (message.status == 'sending') return true;
      final blocks = message.blocks;
      if (blocks == null) continue;
      for (final block in blocks) {
        if (block is TextBlock && block.status == BlockStatus.streaming) {
          return true;
        }
        if (block is AudioBlock && block.status == BlockStatus.pending) {
          return true;
        }
        // 图片块尺寸未交付视为「流式中」：避免尾图 width/height 从 null→真实值
        // 的几何阶跃在用户拖拽中同步触发 _updateListItems 造成视口跳变。
        // 收尾尺寸注入帧因此也走 _shouldDeferStreamingListUpdate 的延迟保护，
        // 配合 _scheduleDetachedActiveExtentRestore 在松手 idle 后做像素补偿。
        if (block is ImageBlock && !_imageBlockHasDimensions(block)) {
          return true;
        }
      }
    }
    return false;
  }

  bool _imageBlockHasDimensions(ImageBlock block) {
    final width = block.width;
    final height = block.height;
    return width != null && width > 0 && height != null && height > 0;
  }

  void _deferStreamingListUpdate(MessageFormatConfig? config) {
    _hasDeferredStreamingListUpdate = true;
    _deferredStreamingListUpdateConfig = config;
    _deferredStreamingListUpdateTimer?.cancel();
    _deferredStreamingListUpdateTimer = Timer(
      _kStreamingScrollUpdateDeferDuration,
      _flushDeferredStreamingListUpdate,
    );
  }

  void _cancelDeferredStreamingListUpdate() {
    _deferredStreamingListUpdateTimer?.cancel();
    _deferredStreamingListUpdateTimer = null;
    _hasDeferredStreamingListUpdate = false;
    _deferredStreamingListUpdateConfig = null;
  }

  void _flushDeferredStreamingListUpdate() {
    if (!_hasDeferredStreamingListUpdate || !mounted) {
      _cancelDeferredStreamingListUpdate();
      return;
    }
    if (_isUserScrollActive) {
      _deferredStreamingListUpdateTimer?.cancel();
      _deferredStreamingListUpdateTimer = Timer(
        _kStreamingScrollUpdateDeferDuration,
        _flushDeferredStreamingListUpdate,
      );
      return;
    }
    final config = _deferredStreamingListUpdateConfig;
    _cancelDeferredStreamingListUpdate();
    final schedulerPhase = SchedulerBinding.instance.schedulerPhase;
    if (schedulerPhase == SchedulerPhase.persistentCallbacks ||
        schedulerPhase == SchedulerPhase.transientCallbacks ||
        schedulerPhase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _updateState(() {
          _updateListItemsWithDetachedExtentGuard(config);
        });
      });
      return;
    }
    _updateState(() {
      _updateListItemsWithDetachedExtentGuard(config);
    });
  }

  /// 在 _updateListItems 重建前后安排 detached extent 像素补偿（仅 detached 模式 +
  /// 尾项含未交付/尺寸变化的 ImageBlock 时）。捕获紧贴重建前、补偿挂下一帧。
  /// 守卫由 _scheduleDetachedActiveExtentRestore / _applyDetachedActiveExtentRestore
  /// 二次校验（history>detached、conversation 校验、程序化滚动跳过）。
  void _updateListItemsWithDetachedExtentGuard(MessageFormatConfig? config) {
    final shouldGuard = _shouldGuardDetachedExtentRestore();
    if (!shouldGuard) {
      _updateListItems(config);
      return;
    }
    if (!_scrollController.hasClients) {
      _updateListItems(config);
      return;
    }
    final position = _scrollController.position;
    if (!position.hasContentDimensions) {
      _updateListItems(config);
      return;
    }
    final previousMin = position.minScrollExtent;
    final previousPixels = position.pixels;
    final conversationId = widget.conversationId;
    _updateListItems(config);
    _scheduleDetachedActiveExtentRestore(
      previousMin: previousMin,
      previousPixels: previousPixels,
      conversationId: conversationId,
    );
  }

  /// 是否需要为本次重建挂 detached extent 补偿：
  /// - detached（_autoScrollEnabled==false）；
  /// - 非历史分页/历史补偿进行中（history > detached 优先级）；
  /// - 尾项（old/new）含 ImageBlock 且其尺寸从缺失→有值或数值变化（复用
  ///   _tailHasActionableLayoutChange 的几何判定，避免纯文本/状态切换误触发）。
  bool _shouldGuardDetachedExtentRestore() {
    if (_autoScrollEnabled) return false;
    if (_historyViewportRestorePending ||
        _historyPagingLockActive ||
        _isProgrammaticScroll) {
      return false;
    }
    if (!_scrollController.hasClients) return false;
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return false;
    final currentTail = _currentTimelineMessages.isEmpty
        ? null
        : _currentTimelineMessages.last;
    if (currentTail == null) return false;
    final blocks = currentTail.blocks;
    if (blocks == null) return false;
    var hasImage = false;
    for (final block in blocks) {
      if (block is ImageBlock) {
        hasImage = true;
        break;
      }
    }
    if (!hasImage) return false;
    // 尾项含图即守卫：无论尺寸是否已到位，重建后都按 newMin delta 补偿；
    // delta≤0.5 时 _applyDetachedActiveExtentRestore 自身会短路。
    return true;
  }
}
