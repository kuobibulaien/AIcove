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
        _captureDetachedSplitBoundary();
        _updateState(() {});
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
    final shortHistoryOverscrolled =
        allowShortHistoryOverscroll && maxScrollExtent <= threshold;

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

  void _captureDetachedSplitBoundary() {
    if (_detachedSplitBoundary != null || _currentTimelineMessages.isEmpty) {
      return;
    }
    final tail = _currentTimelineMessages.last;
    _updateState(() {
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
    _updateState(() {
      _detachedSplitBoundary = null;
    });
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
      _lockAutoScrollForUserInterruption('userDragStart');
      _updateManualDetachedDistanceToBottom();
      _triggerLoadMoreIfNeeded(
        currentScroll: notification.metrics.pixels,
        maxScrollExtent: notification.metrics.maxScrollExtent,
        allowShortHistoryOverscroll: true,
      );
      return false;
    }

    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
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
      return false;
    }

    if (_isProgrammaticScroll) return false;

    return false;
  }
}
