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
      _invalidateViewportFollow();
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
        _invalidateViewportFollow();
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
    final interactionSerial = _viewportInteractionSerial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || interactionSerial != _viewportInteractionSerial) return;
      if (!_canFollowLatest) return;
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
    ref.read(frontendDiagnosticsProvider).begin(
          FrontendStage.scrollFollowRequested,
          conversationId: widget.conversationId,
        );
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
    // 保存上次真正画出的分区，而不是用刚变化的 pinLatestTail 重新算。
    // 控制器改变与列表重建不一定同帧；重新算会把用户消息挪到另一个
    // sliver，让下一次结构更新时画面跳动一个气泡的高度。
    final tail = _currentTimelineMessages.last;
    final nextBoundary = _renderedActiveBoundary ??
        _TimelineSplitBoundary(
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
    _entryRenderConvergenceActive = false;
    _invalidateViewportFollow();
    if (!_autoScrollEnabled) return;
    _debugAutoScroll('lock:$reason');
    _captureDetachedSplitBoundary(rebuild: false);
    final interactionSerial = _viewportInteractionSerial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || interactionSerial != _viewportInteractionSerial) return;
      widget.viewportController.onHistoryPagingStarted();
    });
  }

  void _ensureInitialBottomPosition() {
    if (_didInitialBottomPosition) return;
    if (!_canFollowLatest || !_hasTimelineContent) return;
    // 历史首屏在布局期直接对齐真实末尾，不先画在 user/assistant 分界
    // 再靠下一帧 jumpTo 补位。真正新消息的入场动画仍由原跟随策略裁决。
    if (!widget.isInitialLoading && _pendingAnimationIds.isEmpty) {
      _endAnchor.arm();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _didInitialBottomPosition) return;
      if (!_canFollowLatest || !_hasTimelineContent) return;
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (!position.hasContentDimensions) return;
      _jumpToOffset(position.minScrollExtent);
      _didInitialBottomPosition = true;
      _entryRenderConvergenceActive = true;
    });
  }

  void _jumpToOffset(double target) {
    if (_userOwnsViewport || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final clamped = target
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    if ((position.pixels - clamped).abs() <= 0.5 &&
        !(_canFollowLatest && position.isScrollingNotifier.value)) {
      return;
    }
    // 布局修正可能已经对齐 pixels，但旧的回弹仍带着速度。
    // 仅在明确跟随且用户不拥有视口时，同位置 jumpTo 也要停止它。
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
    if (_userOwnsViewport || !_scrollController.hasClients) return;
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
        if (!mounted || scrollSerial != _programmaticScrollSerial) return;
        _endProgrammaticScroll(scrollSerial);
        if (!_canFollowLatest || !_scrollController.hasClients) return;
        if (!allowFollowUp) {
          _endAnchor.arm();
          _scheduleFollowLatestViewportStabilization(targetDistanceToBottom: 0);
          return;
        }
        if (_distanceToBottom() <= 8) {
          return;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              scrollSerial != _programmaticScrollSerial ||
              !_canFollowLatest ||
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
    _invalidateViewportFollow();
    _programmaticScrollSerial += 1;
    _isProgrammaticScroll = true;
    return _programmaticScrollSerial;
  }

  void _endProgrammaticScroll(int scrollSerial) {
    if (!mounted || _programmaticScrollSerial != scrollSerial) {
      return;
    }
    _isProgrammaticScroll = false;
    _syncJumpToBottomVisibility();
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
    final interactionSerial = _viewportInteractionSerial;
    if (!_canFollowLatest ||
        _followLatestStabilizationSerial == interactionSerial) {
      return;
    }
    _followLatestStabilizationSerial = interactionSerial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_followLatestStabilizationSerial == interactionSerial) {
        _followLatestStabilizationSerial = null;
      }
      if (!mounted ||
          interactionSerial != _viewportInteractionSerial ||
          !_canFollowLatest) {
        return;
      }
      if (!_scrollController.hasClients ||
          !_scrollController.position.hasContentDimensions) {
        if (retryFrames > 0) {
          _scheduleFollowLatestViewportStabilization(
            targetDistanceToBottom: targetDistanceToBottom,
            retryFrames: retryFrames - 1,
          );
        }
        return;
      }
      final position = _scrollController.position;
      final distance =
          targetDistanceToBottom.isFinite && targetDistanceToBottom > 0
              ? targetDistanceToBottom
              : 0.0;
      final target = position.minScrollExtent + distance;
      _jumpToOffset(target);
    });
    // 单击释放时可能没有内容更新，也没有下一帧；显式请求一次，避免
    // 合法的恢复跟随回调永久等在 post-frame 队列里。
    WidgetsBinding.instance.ensureVisualUpdate();
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

  /// 把显隐布尔同步进 [_showJumpToBottom]，由 ValueListenableBuilder 局部
  /// 刷新按钮。ValueNotifier 值不变时不通知，重复调用无副作用。
  void _syncJumpToBottomVisibility() {
    _showJumpToBottom.value = _shouldShowJumpToBottomButton();
  }

  /// 更新 detached 距离并刷新「回到底部」按钮显隐。
  ///
  /// [isDragFrame] 为 true 表示这是用户手指拖动的逐帧回调（滑动卡顿主因）：
  /// 此时**只**更新 notifier 局部刷新按钮，绝不 setState 重建整个列表。
  /// 非拖动的低频路径（ScrollEnd、方向切换、流式内容稳定化）保留 setState，
  /// 维持旧有「距离更新顺带触发一次列表稳定化 build」的语义，避免破坏
  /// 依赖该副作用的滚动 / 流式对齐行为（2026-07-13 卡顿优化）。
  void _updateManualDetachedDistanceToBottom({bool isDragFrame = false}) {
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
        _manualDetachedDistanceToBottom = deferredDistance;
        _commitJumpToBottomVisibility(isDragFrame: isDragFrame);
      });
      return;
    }
    _manualDetachedDistanceToBottom = nextDistance;
    _commitJumpToBottomVisibility(isDragFrame: isDragFrame);
  }

  /// 拖动帧只走 notifier 局部刷新（切断卡顿主因）；非拖动的低频路径
  /// 额外触发一次 setState，维持旧的列表稳定化 build 行为。
  void _commitJumpToBottomVisibility({required bool isDragFrame}) {
    _syncJumpToBottomVisibility();
    if (!isDragFrame && mounted) {
      _updateState(() {});
    }
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
    if (!_historyPagingLockActive ||
        _userOwnsViewport ||
        _isProgrammaticScroll) {
      return;
    }
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
    if (_manualDetachedDistanceToBottom.abs() > 0.5) {
      _manualDetachedDistanceToBottom = 0;
    }
    // 无论距离是否已归零，都同步一次显隐：切回 followLatest 时 isDetached
    // 变 false，按钮必须消失（旧实现靠每次 build 重算，新实现改为显式同步）。
    _syncJumpToBottomVisibility();
  }

  void _lockAutoScrollForUserInterruption(String reason) {
    if (_autoScrollEnabled) {
      ref.read(frontendDiagnosticsProvider).record(
          _listDiagnosticContext, FrontendStage.scrollDetached,
          facts: DiagnosticFacts(
              pageInstanceId: _listDiagnosticContext.operationId,
              reason: DiagnosticReason.userGesture,
              state: {
                'followBefore': _autoScrollEnabled,
                if (_scrollController.hasClients &&
                    _scrollController.position.hasPixels)
                  'pixels': _scrollController.position.pixels,
                if (_scrollController.hasClients &&
                    _scrollController.position.hasContentDimensions) ...{
                  'minExtent': _scrollController.position.minScrollExtent,
                  'maxExtent': _scrollController.position.maxScrollExtent,
                }
              }));
    }
    _cancelProgrammaticScrollTracking();
    _entryRenderConvergenceActive = false;
    _invalidateViewportFollow();
    if (!_autoScrollEnabled) return;
    _debugAutoScroll('lock:$reason');
    _captureDetachedSplitBoundary(rebuild: false);
    widget.viewportController.onUserGesture();
  }

  void _invalidateViewportFollow() {
    _viewportInteractionSerial += 1;
    _endAnchor.disarm();
  }

  void _handlePointerDown(PointerDownEvent event) {
    _pressedPointers.add(event.pointer);
    _invalidateViewportFollow();
    _cancelProgrammaticScrollTracking();
    _historyViewportRestoreSerial += 1;
    // Scrollable 自身负责 hold/停止动画；这里取消所有异步自动补位，
    // 不额外 jumpTo，避免把框架刚建立的 hold/drag 活动销毁。
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
      _lockAutoScrollForUserInterruption('userWheel');
    }
  }

  void _handlePointerReleased(PointerEvent event) {
    _pressedPointers.remove(event.pointer);
    if (_userOwnsViewport) return;
    // 单击没有表达“离开底部”，只有真正拖动才进入 detached。
    if (_canFollowLatest) {
      _endAnchor.arm();
      _scheduleFollowLatestViewportStabilization(targetDistanceToBottom: 0);
    }
  }

  void _markUserScrollActive() {
    _isUserScrollActive = true;
  }

  void _markUserScrollEnded() {
    _isUserScrollActive = false;
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

  /// 记录入场动画开始，返回 serial 供完成回调对账（审查 R2）。
  int _markEntranceAnimationStarted() {
    _activeEntranceAnimationSerial = ++_entranceAnimationSerial;
    return _entranceAnimationSerial;
  }

  /// 入场动画结束（完成或被回收）。完成帧自身的布局增长通知仍会在
  /// 帧后 microtask 到达，静默必须存活过它——post-frame 再入 microtask，
  /// 恰好排在该通知之后（通知的 microtask 在布局期入队，先于本回调）。
  void _handleEntranceAnimationFinished(int serial) {
    if (_activeEntranceAnimationSerial != serial) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduleMicrotask(() {
        if (!mounted) return;
        if (_activeEntranceAnimationSerial == serial) {
          _activeEntranceAnimationSerial = null;
        }
      });
    });
  }

  /// 纯渲染层 extent 变化（表情/图片解码长高、字体加载、视口尺寸变化）不产生
  /// didUpdateWidget，follow-latest 的稳定化收不到信号；框架在这类变化后的
  /// 帧后 microtask 合并派发 ScrollMetricsNotification，这里当场重锚——
  /// 挂普通 post-frame 不保证有下一帧（框架不会为其请求新帧），直接
  /// jumpTo 自会请求新帧，也免去 stale callback 的失效机制。
  /// 去重＝latest state wins：读执行时最新 min，距离阈值提供幂等短路；
  /// jumpTo 只改 pixels 不改内容尺寸，不会自激再派发。
  ///
  /// 作用域＝入场收敛窗（v3 裁决）：消息追加与纯渲染层长高在 metrics 层
  /// 完全同构、不可区分，而贴底时新 AI 消息**不**拉底是既有产品裁决
  /// （auto_scroll_guard 守卫锁定）。故本 handler 只在
  /// [_entryRenderConvergenceActive]（初始置底后、首次结构变化/手势/分页前）
  /// 生效——窗内位移定义上只能来自纯渲染层；窗外让位给既有稳定化路径。
  bool _handleScrollMetricsNotification(
      ScrollMetricsNotification notification) {
    // 只认主列表自己的 viewport，防未来嵌套滚动（代码块/媒体控件）误触。
    if (notification.depth != 0) return false;
    if (!mounted) return false;
    if (!_autoScrollEnabled) return false;
    if (!_didInitialBottomPosition) return false;
    if (!_entryRenderConvergenceActive) return false;
    // 入场动画期的 extent 增长是结构性来源（空会话首条消息经 didUpdateWidget
    // 到达时，窗口会开在其入场动画结束之前），以动画完成事实静默让路
    // （审查 R2：不用帧时间戳猜时长）。
    if (_activeEntranceAnimationSerial != null) return false;
    // 历史恢复优先契约：pending 与 lock 都要挡（与 detached 补偿守卫对齐）。
    if (_historyPagingLockActive) return false;
    if (_historyViewportRestorePending) return false;
    if (_isProgrammaticScroll) return false;
    if (_userOwnsViewport) return false;
    if (!_scrollController.hasClients) return false;
    final position = _scrollController.position;
    if (!position.hasContentDimensions) return false;
    if ((position.pixels - position.minScrollExtent).abs() <= 0.5) return false;
    _debugAutoScroll('request:metricsReanchor');
    widget.onDebugAutoScrollRequested?.call('metricsReanchor');
    _jumpToOffset(position.minScrollExtent);
    return false;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      // ScrollStart 也可能来自按住不动时赢得手势竞争，不等于已拖动。
      // 先阻止补位，真正产生方向/位移后再持久进入 detached。
      _markUserScrollActive();
      _invalidateViewportFollow();
      _cancelProgrammaticScrollTracking();
      _updateManualDetachedDistanceToBottom(isDragFrame: true);
      return false;
    }

    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _markUserScrollActive();
      _lockAutoScrollForUserInterruption('userDragUpdate');
      _updateManualDetachedDistanceToBottom(isDragFrame: true);
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
      _updateManualDetachedDistanceToBottom(isDragFrame: true);
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
        _updateManualDetachedDistanceToBottom(isDragFrame: true);
      }
      return false;
    }

    if (notification is ScrollEndNotification && !_isProgrammaticScroll) {
      final wasUserScrollActive = _isUserScrollActive;
      _markUserScrollEnded();
      _updateManualDetachedDistanceToBottom();
      if (_historyPagingLockActive) {
        _stabilizeHistoryPagingViewport();
      } else if (wasUserScrollActive && _canFollowLatest) {
        _endAnchor.arm();
        _scheduleFollowLatestViewportStabilization(targetDistanceToBottom: 0);
      }
      return false;
    }

    if (_isProgrammaticScroll) return false;

    return false;
  }
}
