part of 'chat_message_list.dart';

extension _ChatMessageListViewportX on _ChatMessageListState {
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
    final schedulerPhase = SchedulerBinding.instance.schedulerPhase;
    if (schedulerPhase == SchedulerPhase.persistentCallbacks ||
        schedulerPhase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _handleViewportControllerChanged();
      });
      return;
    }
    final nextSerial = widget.viewportController.scrollToBottomRequestSerial;
    final shouldRequestScroll =
        nextSerial != _handledViewportScrollRequestSerial;
    final shouldFollowLatest = widget.viewportController.shouldFollowLatest;
    final followLatestChanged =
        _lastViewportShouldFollowLatest != shouldFollowLatest;
    _handledViewportScrollRequestSerial = nextSerial;
    _lastViewportShouldFollowLatest = shouldFollowLatest;
    if (shouldRequestScroll) {
      _requestScrollToBottom(
        'viewportController',
        animated: widget.viewportController.scrollToBottomRequestAnimated,
      );
    }
    if (followLatestChanged) {
      if (shouldFollowLatest) {
        _clearDetachedSplitBoundary();
        _resetManualDetachedDistanceToBottom();
      } else {
        _captureDetachedSplitBoundary(rebuild: false);
      }
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    _triggerLoadMoreIfNeeded(
      currentScroll: position.pixels,
      maxScrollExtent: position.maxScrollExtent,
    );
  }

  void _triggerLoadMoreIfNeeded({
    required double currentScroll,
    required double maxScrollExtent,
    bool allowShortHistoryOverscroll = false,
  }) {
    const threshold = 200.0;
    final reachedHistoryThreshold = maxScrollExtent > threshold &&
        currentScroll >= maxScrollExtent - threshold;
    const shortHistoryBoundaryThreshold = 24.0;
    // 短历史窗口不能只看 maxScrollExtent，否则用户刚开始接管滚动时
    // 会被误判为历史分页；必须接近历史边界或已经真实过冲。
    final distanceToHistoryBoundary = maxScrollExtent - currentScroll;
    final nearShortHistoryBoundary =
        maxScrollExtent > shortHistoryBoundaryThreshold &&
            currentScroll > shortHistoryBoundaryThreshold &&
            distanceToHistoryBoundary <= shortHistoryBoundaryThreshold;
    final meaningfullyOverscrolledPastShortHistory =
        currentScroll >= maxScrollExtent + shortHistoryBoundaryThreshold;
    final shortHistoryOverscrolled = allowShortHistoryOverscroll &&
        maxScrollExtent <= threshold &&
        (nearShortHistoryBoundary || meaningfullyOverscrolledPastShortHistory);

    if (!reachedHistoryThreshold && !shortHistoryOverscrolled) {
      return;
    }
    if (_isLoadingTriggered ||
        widget.isLoadingMore ||
        !widget.hasMoreMessages ||
        widget.onLoadMore == null) {
      return;
    }

    _lockAutoScrollForHistoryPaging(
      shortHistoryOverscrolled
          ? 'historyPagingShortWindowOverscroll'
          : 'historyPagingThresholdReached',
    );
    _historyViewportRestorePending = true;
    _isLoadingTriggered = true;
    _scheduleHistoryPagingStabilization();
    widget.onLoadMore!().then((_) {
      _isLoadingTriggered = false;
    }).catchError((_) {
      _isLoadingTriggered = false;
    });
  }

  void _scheduleScrollToBottom({
    int retryFrames = 6,
    bool animated = false,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_autoScrollEnabled) return;
      if (!_scrollController.hasClients) {
        if (retryFrames > 0) {
          _scheduleScrollToBottom(
            retryFrames: retryFrames - 1,
            animated: animated,
          );
        }
        return;
      }
      final position = _scrollController.position;
      if (!position.hasContentDimensions) {
        if (retryFrames > 0) {
          _scheduleScrollToBottom(
            retryFrames: retryFrames - 1,
            animated: animated,
          );
        }
        return;
      }
      _scrollToOffset(position.minScrollExtent, animated: animated);
    });
  }

  void _debugAutoScroll(String message) {
    assert(() {
      debugPrint('[ChatMessageList:auto-scroll] $message');
      return true;
    }());
  }

  void _requestScrollToBottom(
    String reason, {
    bool animated = false,
  }) {
    _debugAutoScroll('request:$reason');
    widget.onDebugAutoScrollRequested?.call(reason);
    _scheduleScrollToBottom(animated: animated);
  }

  _TimelineSplitBoundary? _effectiveDetachedSplitBoundary() {
    if (_detachedSplitBoundary != null) {
      return _detachedSplitBoundary;
    }
    if (!_autoScrollEnabled) {
      return _pendingDetachedSplitBoundary;
    }
    return null;
  }

  void _captureDetachedSplitBoundary({bool rebuild = true}) {
    if (_currentTimelineMessages.isEmpty) {
      return;
    }
    final tail = _currentTimelineMessages.last;
    final nextBoundary = _TimelineSplitBoundary(
      messageId: tail.id,
      createdAt: tail.createdAt,
    );
    final currentBoundary = _effectiveDetachedSplitBoundary();
    if (currentBoundary != null &&
        currentBoundary.messageId == nextBoundary.messageId &&
        currentBoundary.createdAt == nextBoundary.createdAt) {
      return;
    }
    if (!rebuild) {
      _pendingDetachedSplitBoundary = nextBoundary;
      return;
    }
    _updateState(() {
      _detachedSplitBoundary = nextBoundary;
      _pendingDetachedSplitBoundary = null;
    });
  }

  void _clearDetachedSplitBoundary() {
    if (_detachedSplitBoundary == null &&
        _pendingDetachedSplitBoundary == null) {
      return;
    }
    _updateState(() {
      _detachedSplitBoundary = null;
      _pendingDetachedSplitBoundary = null;
    });
  }

  bool get _historyPagingLockActive =>
      widget.isLoadingMore || _isLoadingTriggered;

  void _lockAutoScrollForHistoryPaging(String reason) {
    if (!_autoScrollEnabled) return;
    _debugAutoScroll('lock:$reason');
    _captureDetachedSplitBoundary(rebuild: false);
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

    final scrollSerial = _beginProgrammaticScroll();
    _scrollController.jumpTo(clamped);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _endProgrammaticScroll(scrollSerial);
    });
  }

  void _scrollToOffset(double target, {required bool animated}) {
    if (animated) {
      _animateToOffset(target);
      return;
    }
    _jumpToOffset(target);
  }

  void _animateToOffset(
    double target, {
    bool allowFollowUp = true,
  }) {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final clamped = target
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final distance = (position.pixels - clamped).abs();
    if (distance <= 0.5) return;
    if (distance <= 24) {
      _jumpToOffset(clamped);
      return;
    }

    final scrollSerial = _beginProgrammaticScroll();
    unawaited(
      _scrollController
          .animateTo(
        clamped,
        duration: _resolveAnimatedScrollDuration(distance),
        curve: Curves.easeOutCubic,
      )
          .whenComplete(() {
        _endProgrammaticScroll(scrollSerial);
        if (!allowFollowUp ||
            !mounted ||
            !_autoScrollEnabled ||
            !_scrollController.hasClients) {
          return;
        }
        if (_distanceToBottom() <= 8) {
          return;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              !_autoScrollEnabled ||
              !_scrollController.hasClients) {
            return;
          }
          if (_distanceToBottom() <= 8) {
            return;
          }
          _animateToOffset(
            _scrollController.position.minScrollExtent,
            allowFollowUp: false,
          );
        });
      }),
    );
  }

  Duration _resolveAnimatedScrollDuration(double distance) {
    final durationMs = (180 + distance * 0.35)
        .clamp(
          _kAnimatedScrollToBottomMinDuration.inMilliseconds.toDouble(),
          _kAnimatedScrollToBottomMaxDuration.inMilliseconds.toDouble(),
        )
        .round();
    return Duration(milliseconds: durationMs);
  }

  int _beginProgrammaticScroll() {
    _programmaticScrollSerial += 1;
    _isProgrammaticScroll = true;
    return _programmaticScrollSerial;
  }

  void _endProgrammaticScroll(int scrollSerial) {
    if (!mounted || _programmaticScrollSerial != scrollSerial) {
      return;
    }
    _isProgrammaticScroll = false;
  }

  void _cancelProgrammaticScrollTracking() {
    _programmaticScrollSerial += 1;
    _isProgrammaticScroll = false;
  }

  void _scheduleHistoryViewportRestore({
    required double previousPixels,
    required double previousMaxScrollExtent,
    int retryFrames = 6,
  }) {
    final requestSerial = ++_historyViewportRestoreSerial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || requestSerial != _historyViewportRestoreSerial) return;
      if (!_scrollController.hasClients) {
        if (retryFrames > 0) {
          _scheduleHistoryViewportRestore(
            previousPixels: previousPixels,
            previousMaxScrollExtent: previousMaxScrollExtent,
            retryFrames: retryFrames - 1,
          );
        }
        return;
      }
      final position = _scrollController.position;
      if (!position.hasContentDimensions) {
        if (retryFrames > 0) {
          _scheduleHistoryViewportRestore(
            previousPixels: previousPixels,
            previousMaxScrollExtent: previousMaxScrollExtent,
            retryFrames: retryFrames - 1,
          );
        }
        return;
      }

      final deltaMaxScrollExtent =
          position.maxScrollExtent - previousMaxScrollExtent;
      if (deltaMaxScrollExtent.abs() <= 0.5) return;

      _jumpToOffset(previousPixels + deltaMaxScrollExtent);
    });
  }

  /// detached 模式下，尾项 ImageBlock 几何变化（占位→真实尺寸）导致 active sliver
  /// （center 前，reverse growth）的 minScrollExtent 突变时，把 pixels 补偿到
  /// `previousPixels + (newMin - previousMin)`，使内容在视口中保持同一逻辑位置。
  ///
  /// 几何依据（codex 第二轮终审已核 Flutter 引擎源码放行）：active sliver 被
  /// SliverPadding(bottom) 包裹，`RenderViewport.updateOutOfBandData` 对
  /// GrowthDirection.reverse 执行 `_minScrollExtent -= scrollExtent`，
  /// `RenderSliverPadding.performLayout` 让 scrollExtent 含 padding；本帧仅尾图
  /// 高度变 Δh 时 `newMin - previousMin = -Δh`，公式精确。
  ///
  /// 守卫（codex 第二轮细则）：history > detached（prepend/restore pending/paging lock
  /// 任一为真则退出）；conversation 切换失效（校验 conversationId）；程序化滚动中不介入；
  /// 改在松手真正 idle 后执行（不在 BallisticScrollActivity 中 jumpTo 截断惯性）；
  /// 记录 clamp 残差便于定位补偿不足。仅 _autoScrollEnabled==false（detached）时调度。
  void _scheduleDetachedActiveExtentRestore({
    required double previousMin,
    required double previousPixels,
    required String conversationId,
  }) {
    final requestSerial = ++_detachedExtentRestoreSerial;
    _detachedExtentRestorePreviousMin = previousMin;
    _detachedExtentRestorePreviousPixels = previousPixels;
    _detachedExtentRestoreConversationId = conversationId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || requestSerial != _detachedExtentRestoreSerial) return;
      _applyDetachedActiveExtentRestore(requestSerial);
    });
  }

  void _applyDetachedActiveExtentRestore(int requestSerial) {
    if (!mounted || requestSerial != _detachedExtentRestoreSerial) return;
    // followLatest 贴底由 _scheduleFollowLatestViewportStabilization 负责。
    if (_autoScrollEnabled) return;
    // history 补偿优先级高于 detached：任一介入则放弃本次 detached 补偿。
    if (_historyViewportRestorePending ||
        _historyPagingLockActive ||
        _isProgrammaticScroll) {
      _debugAutoScroll(
        'detachedExtentRestore skipped (history/programmatic active) '
        'historyPending=$_historyViewportRestorePending '
        'pagingLock=$_historyPagingLockActive '
        'programmatic=$_isProgrammaticScroll',
      );
      return;
    }
    // conversation 切换后旧会话的补偿不得执行。
    if (_detachedExtentRestoreConversationId != widget.conversationId) return;
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return;

    final previousMin = _detachedExtentRestorePreviousMin;
    final previousPixels = _detachedExtentRestorePreviousPixels;
    if (previousMin == null || previousPixels == null) return;

    final newMin = position.minScrollExtent;
    final deltaMin = newMin - previousMin;
    if (deltaMin.abs() <= 0.5) {
      _clearDetachedExtentRestore();
      return;
    }

    final target = previousPixels + deltaMin;
    final clamped = target
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    final residual = (target - clamped).abs();
    _debugAutoScroll(
      'detachedExtentRestore jumpTo '
      'prevPixels=${previousPixels.toStringAsFixed(1)} '
      'prevMin=${previousMin.toStringAsFixed(1)} '
      'newMin=${newMin.toStringAsFixed(1)} '
      'deltaMin=${deltaMin.toStringAsFixed(1)} '
      'target=${target.toStringAsFixed(1)} '
      'clamped=${clamped.toStringAsFixed(1)} '
      'residual=${residual.toStringAsFixed(1)}',
    );

    _clearDetachedExtentRestore();
    _jumpToOffset(clamped);
  }

  void _clearDetachedExtentRestore() {
    _detachedExtentRestorePreviousMin = null;
    _detachedExtentRestorePreviousPixels = null;
    _detachedExtentRestoreConversationId = null;
  }

  /// 使任何待执行的 detached extent restore 失效（conversation 切换等场景调用）。
  void _invalidateDetachedExtentRestore() {
    _detachedExtentRestoreSerial += 1;
    _clearDetachedExtentRestore();
  }

  void _scheduleFollowLatestViewportStabilization({
    required double targetDistanceToBottom,
    int retryFrames = 3,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_autoScrollEnabled || _historyPagingLockActive) {
        return;
      }
      if (!_scrollController.hasClients) {
        if (retryFrames > 0) {
          _scheduleFollowLatestViewportStabilization(
            targetDistanceToBottom: targetDistanceToBottom,
            retryFrames: retryFrames - 1,
          );
        }
        return;
      }
      final position = _scrollController.position;
      if (!position.hasContentDimensions) {
        if (retryFrames > 0) {
          _scheduleFollowLatestViewportStabilization(
            targetDistanceToBottom: targetDistanceToBottom,
            retryFrames: retryFrames - 1,
          );
        }
        return;
      }

      final normalizedTargetDistance =
          targetDistanceToBottom.isFinite && targetDistanceToBottom > 0
              ? targetDistanceToBottom
              : 0.0;
      final targetOffset = position.minScrollExtent + normalizedTargetDistance;
      if ((position.pixels - targetOffset).abs() > 0.5) {
        _jumpToOffset(targetOffset);
      }
      if (retryFrames <= 0) {
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_autoScrollEnabled || _historyPagingLockActive) {
          return;
        }
        if (!_scrollController.hasClients) {
          _scheduleFollowLatestViewportStabilization(
            targetDistanceToBottom: targetDistanceToBottom,
            retryFrames: retryFrames - 1,
          );
          return;
        }
        final nextPosition = _scrollController.position;
        if (!nextPosition.hasContentDimensions) {
          _scheduleFollowLatestViewportStabilization(
            targetDistanceToBottom: targetDistanceToBottom,
            retryFrames: retryFrames - 1,
          );
          return;
        }
        final nextTargetOffset =
            nextPosition.minScrollExtent + normalizedTargetDistance;
        if ((nextPosition.pixels - nextTargetOffset).abs() <= 0.5) {
          return;
        }
        _scheduleFollowLatestViewportStabilization(
          targetDistanceToBottom: targetDistanceToBottom,
          retryFrames: retryFrames - 1,
        );
      });
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
    final schedulerPhase = WidgetsBinding.instance.schedulerPhase;
    if (schedulerPhase == SchedulerPhase.persistentCallbacks ||
        schedulerPhase == SchedulerPhase.transientCallbacks ||
        schedulerPhase == SchedulerPhase.midFrameMicrotasks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !_scrollController.hasClients ||
            _isProgrammaticScroll) {
          return;
        }
        final deferredDistance = _distanceToBottom();
        if (!deferredDistance.isFinite ||
            (deferredDistance - _manualDetachedDistanceToBottom).abs() <= 0.5) {
          return;
        }
        _updateState(() {
          _manualDetachedDistanceToBottom = deferredDistance;
        });
      });
      return;
    }
    _updateState(() {
      _manualDetachedDistanceToBottom = nextDistance;
    });
  }

  void _scheduleHistoryPagingStabilization({int retryFrames = 3}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_historyPagingLockActive) {
        return;
      }
      _stabilizeHistoryPagingViewport(retryFrames: retryFrames);
    });
  }

  void _stabilizeHistoryPagingViewport({int retryFrames = 3}) {
    if (!_scrollController.hasClients) {
      if (retryFrames > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _stabilizeHistoryPagingViewport(retryFrames: retryFrames - 1);
        });
      }
      return;
    }
    final position = _scrollController.position;
    if (!position.hasContentDimensions) {
      if (retryFrames > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _stabilizeHistoryPagingViewport(retryFrames: retryFrames - 1);
        });
      }
      return;
    }

    const maxAllowedDistanceToHistoryBoundary = 24.0;
    final distanceToHistoryBoundary =
        (position.maxScrollExtent - position.pixels).abs();
    if (distanceToHistoryBoundary <= maxAllowedDistanceToHistoryBoundary) {
      return;
    }

    _jumpToOffset(position.maxScrollExtent);
  }

  void _resetManualDetachedDistanceToBottom() {
    if (_manualDetachedDistanceToBottom.abs() <= 0.5) {
      return;
    }
    _updateState(() {
      _manualDetachedDistanceToBottom = 0;
    });
  }

  void _lockAutoScrollForUserInterruption(String reason) {
    _cancelProgrammaticScrollTracking();
    if (!_autoScrollEnabled) return;
    _debugAutoScroll('lock:$reason');
    _captureDetachedSplitBoundary(rebuild: false);
    widget.viewportController.onUserGesture();
  }

  void _markUserScrollActive() {
    _isUserScrollActive = true;
  }

  void _markUserScrollEnded() {
    if (!_isUserScrollActive) return;
    _isUserScrollActive = false;
    if (_hasDeferredStreamingListUpdate) {
      _flushDeferredStreamingListUpdate();
    }
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
      _updateState(() {
        _showHistoryLoadingOverlay = false;
        _historyLoadingOverlayShownAt = null;
        _historyLoadingOverlayHideTimer = null;
      });
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _markUserScrollActive();
      _lockAutoScrollForUserInterruption('userDragStart');
      _updateManualDetachedDistanceToBottom();
      return false;
    }

    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _markUserScrollActive();
      _lockAutoScrollForUserInterruption('userDragUpdate');
      _updateManualDetachedDistanceToBottom();
      _triggerLoadMoreIfNeeded(
        currentScroll: notification.metrics.pixels,
        maxScrollExtent: notification.metrics.maxScrollExtent,
        allowShortHistoryOverscroll: true,
      );
      return false;
    }

    if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      _markUserScrollActive();
      _lockAutoScrollForUserInterruption('userDragOverscroll');
      _updateManualDetachedDistanceToBottom();
      _triggerLoadMoreIfNeeded(
        currentScroll: notification.metrics.pixels,
        maxScrollExtent: notification.metrics.maxScrollExtent,
        allowShortHistoryOverscroll: true,
      );
      return false;
    }

    if (_historyPagingLockActive &&
        ((notification is ScrollUpdateNotification &&
                notification.dragDetails == null) ||
            (notification is OverscrollNotification &&
                notification.dragDetails == null))) {
      _stabilizeHistoryPagingViewport();
      return false;
    }

    if (notification is UserScrollNotification) {
      if (_isProgrammaticScroll) {
        return false;
      }
      if (notification.direction != ScrollDirection.idle) {
        _markUserScrollActive();
        _lockAutoScrollForUserInterruption('userScrollDirectionChanged');
        _updateManualDetachedDistanceToBottom();
      }
      return false;
    }

    if (notification is ScrollEndNotification && !_isProgrammaticScroll) {
      _updateManualDetachedDistanceToBottom();
      if (_historyPagingLockActive) {
        _stabilizeHistoryPagingViewport();
      }
      _markUserScrollEnded();
      return false;
    }

    if (_isProgrammaticScroll) return false;

    return false;
  }
}
