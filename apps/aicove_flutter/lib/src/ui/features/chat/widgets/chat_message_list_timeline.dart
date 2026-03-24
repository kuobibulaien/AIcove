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
      _historyViewportRestorePending = false;
      _holdListForHistoryPagingEmptyTimeline = false;
      _heldTimelineMessagesForLayout = const <Message>[];
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

    if (messagesChanged) {
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

    return currentTail.createdAt == previousTail.createdAt &&
        (currentTail.id != previousTail.id ||
            currentTail.role != previousTail.role);
  }
}
