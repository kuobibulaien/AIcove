part of 'chat_actions.dart';

class _StreamPlaceholderDelivery {
  _StreamPlaceholderDelivery(
    this._ref, {
    required this.convId,
    required this.generationSeq,
    required this.formatConfig,
    required this.enableTtsPlaceholders,
    this.tagPresentation = const {},
    this.segmentDelay = Duration.zero,
    this.onPendingAudioAppeared,
    this.beforeFirstContent,
    this.diagnosticContext,
  }) : _diagnostics = _ref.read(frontendDiagnosticsProvider);

  static const String kGeneratingText = '生成中...';
  static const Duration _kFlushInterval = Duration(milliseconds: 180);
  static const Duration _kThinkingPlaceholderDelay =
      Duration(milliseconds: 450);

  final Ref _ref;
  final String convId;

  /// ChatActions 分配的 runId（跨 delivery 实例全局单调），
  /// 活跃流通道 CAS 的主身份（07-20 任务 design v2 §2.1）。
  final int generationSeq;
  final FrontendDiagnosticContext? diagnosticContext;
  final FrontendDiagnosticsPort _diagnostics;
  int _diagnosticProjectionRevision = 0;
  String? _diagnosticCommittedSource;

  void _recordDiagnostic(FrontendStage stage,
      {String? messageId,
      DiagnosticPhase phase = DiagnosticPhase.decision,
      DiagnosticReason? reason,
      Map<String, Object?> state = const {},
      Object? error,
      StackTrace? stack}) {
    _diagnostics.record(diagnosticContext, stage,
        messageId: messageId,
        error: error,
        stackTrace: stack,
        facts: DiagnosticFacts(
            phase: phase,
            reason: reason,
            sourceMessageId: _diagnosticCommittedSource ?? _pendingRawSourceId,
            state: {
              'sourceIsProvisional': _diagnosticCommittedSource == null,
              'generationSeq': generationSeq,
              'writeEpoch': _writeEpoch,
              'projectionRevision': _diagnosticProjectionRevision,
              ...state
            }));
  }

  bool _transportStreaming = false;

  void setTransportStreaming(bool enabled) {
    if (_transportStreaming == enabled) return;
    _transportStreaming = enabled;
    _parsedRawText = null;
    _parsedTimeline = null;
  }

  final MessageFormatConfig formatConfig;

  /// 会话的语义标签呈现映射，本轮生成开始时读取后固定；折叠与选项标签
  /// 在自动分段中整块保护（ADR0047）。
  final TagPresentationMap tagPresentation;
  final bool enableTtsPlaceholders;
  final Duration segmentDelay;
  final void Function(Message pendingMessage)? onPendingAudioAppeared;

  /// 第一段模型内容写入时间线前执行一次；重新生成在这里才撤掉旧回复。
  final Future<void> Function()? beforeFirstContent;
  bool _firstContentPrepared = false;

  void markFirstContentPrepared() {
    _firstContentPrepared = true;
  }

  final Set<String> _scheduledAudioMessageIds = <String>{};
  final Map<String, String> _terminalAudioFallbacks = <String, String>{};
  final Map<String, _StreamTtsResolution> _bufferedTtsResolutions =
      <String, _StreamTtsResolution>{};
  final Map<String, Message> _committedTtsMessages = <String, Message>{};
  _StreamTtsHandoffState _ttsHandoffState = _StreamTtsHandoffState.streaming;
  Future<void> _committedTtsWriteQueue = Future<void>.value();

  /// G2.1 活跃流通道开关；false＝旧全量 transient 路径（默认）。
  late final bool _useActiveStreamChannel =
      _ref.read(streamProjectionPolicyProvider).useActiveStreamChannel;

  bool _partialTextTaken = false;

  /// Freeze once, before persistence yields, so queued reveals cannot advance.
  String takePartialText() {
    if (_partialTextTaken) return '';
    _partialTextTaken = true;
    // Read the applied timeline, not the receive buffer or a queued reveal.
    final visibleMessages =
        _ref
            .read(conversationTimelineCacheProvider)
            .peekWindow(
              conversationId: convId,
              limit: _currentTimelineMessages.length + 1,
            )
            ?.messages ??
        const <Message>[];
    final live = _useActiveStreamChannel
        ? _ref.read(activeStreamProjectionsProvider)[convId]
        : null;
    final text = StringBuffer();
    for (final message in visibleMessages) {
      if (message.sourceMessageId != _pendingRawSourceId ||
          _isGeneratingPlaceholderMessage(message)) {
        continue;
      }
      final blocks = message.blocks?.whereType<TextBlock>();
      if (blocks == null || blocks.isEmpty) continue;
      if (live != null &&
          live.generationSeq == generationSeq &&
          live.writeEpoch == _writeEpoch &&
          live.phase == ActiveStreamPhase.streamingTail &&
          live.tailMessageId == message.id) {
        text.write(live.tailText);
      } else {
        for (final block in blocks) {
          text.write(block.content);
        }
      }
    }
    dispose();
    return text.toString();
  }

  final StringBuffer _rawStreamText = StringBuffer();
  int _lastReadyPendingAudioCount = 0;
  final List<Message> _currentTimelineMessages = <Message>[];
  final Map<String, Message> _stablePendingAudioMessages = <String, Message>{};
  final String _pendingRawSourceId = genId('raw_msg');
  VoiceRequest? voiceRequest;

  int? _timelineBaseMs;
  int _timelineTick = 0;
  Future<void> _queue = Future<void>.value();
  Timer? _flushTimer;
  DateTime? _scheduledFlushAt;
  Timer? _thinkingPlaceholderTimer;
  bool _dirty = false;
  bool _disposed = false;
  bool _receivedDelta = false;
  String _partialTtsClose = '';
  bool _fallbackTriggered = false;
  bool _fallbackObserved = false;
  bool _thinkingPlaceholderElapsed = false;
  String? _finalizedRawText;
  int _visibleSealedTextCount = 0;
  DateTime? _nextSealedRevealAt;
  int _writeEpoch = 0;

  Future<void> start() async {
    if (_disposed) return;
    _restartThinkingPlaceholderTimer();
  }

  void onDelta(String delta) {
    if (_disposed || delta.isEmpty) return;
    voiceRequest ??= VoiceRequest.current;
    _rawStreamText.write(delta);
    _receivedDelta = true;
    _dirty = true;
    var shouldFlushNow = false;
    if (enableTtsPlaceholders && _containsNewTtsClose(delta)) {
      final readyCount = _countReadyPendingAudioDescriptors(
        _rawStreamText.toString(),
      );
      shouldFlushNow = readyCount > _lastReadyPendingAudioCount;
      _lastReadyPendingAudioCount = readyCount;
    }
    _scheduleFlush(forceNow: shouldFlushNow);
  }

  void onStreamReset() {
    if (_disposed) return;
    final discardedMessages =
        List<Message>.from(_currentTimelineMessages, growable: false);
    _writeEpoch += 1;
    // 先使当前代通道失效，再撤壳（design v2 §2.5）。
    _clearActiveStreamProjection();
    _fallbackTriggered = false;
    _fallbackObserved = false;
    _receivedDelta = false;
    _finalizedRawText = null;
    _thinkingPlaceholderElapsed = false;
    _rawStreamText.clear();
    _partialTtsClose = '';
    _lastReadyPendingAudioCount = 0;
    _parsedRawText = null;
    _parsedTimeline = null;
    voiceRequest = null;
    _scheduledAudioMessageIds.clear();
    _terminalAudioFallbacks.clear();
    _bufferedTtsResolutions.clear();
    _ttsHandoffState = _StreamTtsHandoffState.streaming;
    _currentTimelineMessages.clear();
    _stablePendingAudioMessages.clear();
    _timelineBaseMs = null;
    _timelineTick = 0;
    _visibleSealedTextCount = 0;
    _nextSealedRevealAt = null;
    _dirty = true;
    _restartThinkingPlaceholderTimer();
    unawaited(_discardTimelineMessages(discardedMessages));
    _scheduleFlush(forceNow: true);
  }

  void onToolCallObserved() {}

  void onStreamingFallback() {
    if (_disposed) return;
    _fallbackObserved = true;
    if (_receivedDelta) return;
    _fallbackTriggered = true;
  }

  bool get receivedDelta => _receivedDelta;

  bool canFinalizeWith({required String finalText}) {
    if (_disposed || !_receivedDelta || _fallbackTriggered) return false;
    final effectiveFinalText = _resolveEffectiveFinalText(finalText);
    // Eligibility must not advance the reveal cursor or start timers.
    return _countSealedTextDescriptors(effectiveFinalText) > 0;
  }

  Future<void> finalize({required String finalText}) async {
    if (_disposed) return;
    final effectiveFinalText = _resolveEffectiveFinalText(finalText);
    final writeEpoch = _writeEpoch;
    _finalizedRawText = effectiveFinalText;
    _fallbackTriggered = false;
    await _drainSegmentRevealBacklog(sourceRaw: effectiveFinalText);
    if (_disposed || writeEpoch != _writeEpoch) return;
    _cancelThinkingPlaceholderTimer();
    _flushTimer?.cancel();
    _flushTimer = null;
    _scheduledFlushAt = null;
    _dirty = false;
    await _applyState(finalize: true, writeEpoch: writeEpoch);
  }

  Future<void> commitToMessages({
    required List<Message> finalMessages,
  }) async {
    if (_disposed) return;
    final previousMessages =
        List<Message>.from(_currentTimelineMessages, growable: false);
    _writeEpoch += 1;
    _clearActiveStreamProjection();
    _committedTtsMessages
      ..clear()
      ..addEntries(
        finalMessages
            .where(
              (message) => _scheduledAudioMessageIds.contains(message.id),
            )
            .map((message) => MapEntry(message.id, message)),
      );
    _currentTimelineMessages.clear();
    _stablePendingAudioMessages.clear();
    _rawStreamText.clear();
    _partialTtsClose = '';
    _lastReadyPendingAudioCount = 0;
    _parsedRawText = null;
    _parsedTimeline = null;
    _finalizedRawText = null;
    _receivedDelta = false;
    _fallbackTriggered = false;
    _fallbackObserved = false;
    _timelineBaseMs = null;
    _timelineTick = 0;
    _visibleSealedTextCount = 0;
    _nextSealedRevealAt = null;
    await _replaceTimelineMessages(
      previousMessages: previousMessages,
      nextMessages: finalMessages,
    );
    _diagnosticCommittedSource = finalMessages.firstOrNull?.sourceMessageId;
    if (_diagnosticCommittedSource != null) {
      _diagnostics.bindMessage(_diagnosticCommittedSource!, diagnosticContext);
    }
    for (final message in finalMessages) {
      _recordDiagnostic(FrontendStage.projectionCommitted,
          messageId: message.id,
          phase: DiagnosticPhase.end,
          state: {'finalCount': finalMessages.length});
    }
    _ttsHandoffState = _StreamTtsHandoffState.committed;
    final buffered = Map<String, _StreamTtsResolution>.from(
      _bufferedTtsResolutions,
    );
    _bufferedTtsResolutions.clear();
    for (final entry in buffered.entries) {
      await _enqueueCommittedTtsResolution(entry.key, entry.value);
    }
  }

  /// When the first streamed bubble appeared; cleared by [commitToMessages].
  DateTime? get timelineStart => _timelineBaseMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_timelineBaseMs!);

  Future<void> removePlaceholders() async {
    _discardTtsResolutions();
    _writeEpoch += 1;
    _clearActiveStreamProjection();
    _cancelThinkingPlaceholderTimer();
    _flushTimer?.cancel();
    _flushTimer = null;
    _scheduledFlushAt = null;
    _dirty = false;
    final discardedMessages =
        List<Message>.from(_currentTimelineMessages, growable: false);
    _currentTimelineMessages.clear();
    _stablePendingAudioMessages.clear();
    _rawStreamText.clear();
    _partialTtsClose = '';
    _lastReadyPendingAudioCount = 0;
    _parsedRawText = null;
    _parsedTimeline = null;
    _finalizedRawText = null;
    _receivedDelta = false;
    _fallbackTriggered = false;
    _fallbackObserved = false;
    _timelineBaseMs = null;
    _timelineTick = 0;
    _visibleSealedTextCount = 0;
    _nextSealedRevealAt = null;
    await _discardTimelineMessages(discardedMessages);
  }

  void dispose() {
    _disposed = true;
    _parsedRawText = null;
    _parsedTimeline = null;
    if (_ttsHandoffState != _StreamTtsHandoffState.committed) {
      _discardTtsResolutions();
    }
    _writeEpoch += 1;
    _clearActiveStreamProjection();
    _cancelThinkingPlaceholderTimer();
    _flushTimer?.cancel();
    _flushTimer = null;
    _scheduledFlushAt = null;
  }

  void _restartThinkingPlaceholderTimer() {
    _cancelThinkingPlaceholderTimer();
    _thinkingPlaceholderElapsed = false;
    _thinkingPlaceholderTimer = Timer(_kThinkingPlaceholderDelay, () {
      if (_disposed || _thinkingPlaceholderElapsed) return;
      _thinkingPlaceholderElapsed = true;
      _dirty = true;
      _scheduleFlush(forceNow: true);
    });
  }

  void _cancelThinkingPlaceholderTimer() {
    _thinkingPlaceholderTimer?.cancel();
    _thinkingPlaceholderTimer = null;
  }

  void _scheduleFlush({bool forceNow = false}) {
    if (_disposed) return;
    if (forceNow) {
      _flushTimer?.cancel();
      _flushTimer = null;
      _scheduledFlushAt = null;
      _flushNow();
      return;
    }
    final now = DateTime.now();
    var targetAt = now.add(_kFlushInterval);
    final nextRevealAt = _nextSealedRevealAt;
    if (nextRevealAt != null && nextRevealAt.isBefore(targetAt)) {
      targetAt = nextRevealAt;
    }
    final scheduledAt = _scheduledFlushAt;
    if (_flushTimer != null &&
        scheduledAt != null &&
        !targetAt.isBefore(scheduledAt)) {
      return;
    }
    _flushTimer?.cancel();
    _scheduledFlushAt = targetAt;
    final delay = targetAt.difference(now);
    _flushTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      _flushNow,
    );
  }

  void _flushNow() {
    if (_disposed) return;
    _flushTimer = null;
    _scheduledFlushAt = null;
    if (!_dirty) return;
    _dirty = false;
    final writeEpoch = _writeEpoch;
    unawaited(_applyState(finalize: false, writeEpoch: writeEpoch));
  }

  Future<void> _applyState({
    required bool finalize,
    required int writeEpoch,
  }) async {
    await _enqueue(() async {
      if (_disposed || writeEpoch != _writeEpoch) {
        _recordDiagnostic(FrontendStage.projectionSkipped,
            phase: DiagnosticPhase.skip,
            reason: _disposed
                ? DiagnosticReason.disposed
                : DiagnosticReason.staleWriteEpoch,
            state: {'requestedEpoch': writeEpoch});
        return;
      }
      await _ensureTimelineBaseMs();
      if (_receivedDelta && !_firstContentPrepared) {
        try {
          await beforeFirstContent?.call();
          _firstContentPrepared = true;
        } catch (error, stack) {
          // 失败由调用方在交付结果时再次等待并上报。
          _recordDiagnostic(FrontendStage.projectionSkipped,
              phase: DiagnosticPhase.error,
              reason: DiagnosticReason.operationFailed,
              error: error,
              stack: stack);
          return;
        }
      }
      if (_disposed || writeEpoch != _writeEpoch) {
        _recordDiagnostic(FrontendStage.projectionSkipped,
            phase: DiagnosticPhase.skip,
            reason: _disposed
                ? DiagnosticReason.disposed
                : DiagnosticReason.staleWriteEpoch,
            state: {'requestedEpoch': writeEpoch});
        return;
      }
      final previousMessages =
          List<Message>.from(_currentTimelineMessages, growable: false);
      final sourceRaw = _finalizedRawText ?? _rawStreamText.toString();
      final descriptors =
          _buildTimelineDescriptors(sourceRaw, finalize: finalize);
      final messages = _materializeTimeline(descriptors);
      final structuralChange = previousMessages.length != messages.length ||
          messages.indexed
              .any((entry) => previousMessages[entry.$1].id != entry.$2.id);
      if (structuralChange) _diagnosticProjectionRevision++;
      void recordApplied() {
        if (!structuralChange && !finalize) return;
        _recordDiagnostic(FrontendStage.projectionApplied,
            phase: DiagnosticPhase.end,
            reason: DiagnosticReason.structuralChange,
            state: {
              'beforeCount': previousMessages.length,
              'afterCount': messages.length,
              'rawCharacters': sourceRaw.length,
              'finalize': finalize,
              'activeChannel': _useActiveStreamChannel
            });
      }

      if (!_useActiveStreamChannel) {
        // 旧路径：视觉变化即全量替换（policy off，行为与改造前逐字节一致）。
        final shouldNotifyTimeline =
            !_streamTimelineMessagesVisuallyEqual(previousMessages, messages);
        _currentTimelineMessages
          ..clear()
          ..addAll(messages);
        if (!shouldNotifyTimeline) {
          recordApplied();
          return;
        }
        await _ref
            .read(conversationTimelineCacheProvider)
            .replaceMessagesTransient(
              conversationId: convId,
              removeMessageIds: [
                for (final message in previousMessages) message.id,
              ],
              messages: messages,
            );
        recordApplied();
        return;
      }
      // 新路径（design v2 §2.2/2.3/2.5）：结构增量写时间线，活跃尾文本走通道。
      final tail = _locateActiveTail(descriptors, messages);
      // 含语义标签的尾巴在列表里按片段展示，片段只读壳不读通道，所以文本
      // 增长也要写壳，否则展开的折叠段停在它刚出现时的几个字。列表按当时的
      // 标签映射分片，可能与本轮固定的 [tagPresentation] 不同，这里只看有无标签。
      final channelTailId = tail != null &&
              tail.phase == ActiveStreamPhase.streamingTail &&
              !tail.tailText.contains('<')
          ? tail.tailMessageId
          : null;
      _currentTimelineMessages
        ..clear()
        ..addAll(messages);
      final previousById = {
        for (final message in previousMessages) message.id: message,
      };
      final nextIds = {for (final message in messages) message.id};
      final removedIds = [
        for (final message in previousMessages)
          if (!nextIds.contains(message.id)) message.id,
      ];
      final upserts = <Message>[];
      for (final message in messages) {
        final previous = previousById[message.id];
        if (previous == null) {
          upserts.add(message);
          continue;
        }
        final isActiveTailText = message.id == channelTailId;
        if (isActiveTailText) {
          // 活跃尾：仅结构面变化（状态/块形）才升级壳；文本增长只走通道。
          if (!_tailShellVisuallyEqual(previous, message)) {
            upserts.add(message);
          }
        } else if (!_streamTimelineMessageVisuallyEqual(previous, message)) {
          upserts.add(message);
        }
      }
      if (removedIds.isNotEmpty || upserts.isNotEmpty) {
        await _ref
            .read(conversationTimelineCacheProvider)
            .replaceMessagesTransient(
              conversationId: convId,
              removeMessageIds: removedIds,
              messages: upserts,
            );
      }
      if (_disposed || writeEpoch != _writeEpoch) {
        _recordDiagnostic(FrontendStage.projectionSkipped,
            phase: DiagnosticPhase.skip,
            reason: _disposed
                ? DiagnosticReason.disposed
                : DiagnosticReason.staleWriteEpoch,
            state: {
              'requestedEpoch': writeEpoch,
              'timelineAlreadyWritten': true
            });
        return;
      }
      // 先写时间线再 publish（design v2 §2.5 交接顺序）。
      final channel = _ref.read(activeStreamProjectionsProvider.notifier);
      if (tail != null) {
        channel.publish(ActiveStreamProjection(
          conversationId: convId,
          generationSeq: generationSeq,
          writeEpoch: writeEpoch,
          tailMessageId: tail.tailMessageId,
          tailText: tail.tailText,
          phase: tail.phase,
        ));
      } else {
        channel.clear(convId, generationSeq: generationSeq);
      }
      recordApplied();
    });
  }

  /// 清除本代活跃流通道条目（CAS：旧代 clear 不伤新流）。
  void _clearActiveStreamProjection() {
    try {
      if (!_useActiveStreamChannel) return;
      _ref
          .read(activeStreamProjectionsProvider.notifier)
          .clear(convId, generationSeq: generationSeq);
    } on StateError catch (_) {
      // 仅降级 container 已销毁场景（ref 失效）：通道随 container 消亡。
      // 其他异常照常抛出，避免掩盖幽灵通道（审查 S-05）。
    }
  }

  // Keep only the latest parse. Timer-only reveals reuse it without scanning
  // the entire accumulated reply again. Parsing never changes delivery state.
  String? _parsedRawText;
  bool _parsedSealTail = false;
  _TextSegmentDescriptors? _parsedTimeline;

  Future<void> _drainSegmentRevealBacklog({
    required String sourceRaw,
  }) async {
    if (_disposed || segmentDelay <= Duration.zero) return;
    final writeEpoch = _writeEpoch;
    final targetSealedCount = _countSealedTextDescriptors(sourceRaw);
    if (targetSealedCount <= _visibleSealedTextCount) {
      return;
    }
    while (!_disposed &&
        writeEpoch == _writeEpoch &&
        _visibleSealedTextCount < targetSealedCount) {
      final now = DateTime.now();
      final revealAt = _nextSealedRevealAt ?? now.add(segmentDelay);
      _nextSealedRevealAt = revealAt;
      final wait = revealAt.difference(now);
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
      if (_disposed || writeEpoch != _writeEpoch) return;
      _dirty = true;
      await _applyState(finalize: false, writeEpoch: writeEpoch);
    }
  }

  Future<void> _ensureTimelineBaseMs() async {
    if (_timelineBaseMs != null) return;
    final lastPersistedMessage =
        await _ref.read(chatHistoryStoreProvider).loadLastMessage(convId);
    final lastCreatedAt = lastPersistedMessage?.createdAt ?? DateTime.now();
    final now = DateTime.now();
    final baseTime = now.isAfter(lastCreatedAt)
        ? now
        : lastCreatedAt.add(const Duration(milliseconds: 1));
    _timelineBaseMs = baseTime.millisecondsSinceEpoch;
  }

  Future<void> _enqueue(
    Future<void> Function() task, {
    bool allowDisposed = false,
  }) {
    _queue = _queue.catchError((_) {}).then((_) async {
      if (_disposed && !allowDisposed) {
        _recordDiagnostic(FrontendStage.projectionSkipped,
            phase: DiagnosticPhase.skip, reason: DiagnosticReason.disposed);
        return;
      }
      try {
        await task();
      } catch (error, stack) {
        _recordDiagnostic(FrontendStage.projectionSkipped,
            phase: DiagnosticPhase.error,
            reason: DiagnosticReason.operationFailed,
            error: error,
            stack: stack);
        rethrow;
      }
    });
    return _queue;
  }

  Future<void> _replaceTimelineMessages({
    required List<Message> previousMessages,
    required List<Message> nextMessages,
  }) {
    return _enqueue(() async {
      await _ref.read(conversationTimelineCacheProvider).replaceMessages(
            conversationId: convId,
            removeMessageIds: [
              for (final message in previousMessages) message.id,
            ],
            messages: nextMessages,
          );
    });
  }

  Future<void> _discardTimelineMessages(List<Message> messages) {
    if (messages.isEmpty) return Future<void>.value();
    return _enqueue(() async {
      await _ref.read(conversationTimelineCacheProvider).replaceMessages(
        conversationId: convId,
        removeMessageIds: [
          for (final message in messages) message.id,
        ],
      );
    }, allowDisposed: true);
  }

  List<Message> pendingAudioPlaceholderMessages({
    required String sourceMessageId,
  }) {
    return _pendingAudioPlaceholderMessages(sourceMessageId: sourceMessageId);
  }

  List<Message> _pendingAudioPlaceholderMessages({
    required String sourceMessageId,
  }) {
    return <Message>[
      for (final message in _currentTimelineMessages)
        if (_isPendingAudioPlaceholderMessage(message))
          message.copyWith(sourceMessageId: sourceMessageId),
    ];
  }

  bool _isPendingAudioPlaceholderMessage(Message message) {
    final blocks = message.blocks;
    if (blocks == null || blocks.length != 1) return false;
    final block = blocks.first;
    return block is AudioBlock &&
        (block.url.isEmpty || block.status == BlockStatus.pending) &&
        (block.text?.trim().isNotEmpty ?? false);
  }

  void updateResolvedAudio({
    required String messageId,
    required String audioUrl,
    double? durationSeconds,
  }) {
    if (!canAcceptTtsResolution(messageId)) return;
    final resolution = (
      audioUrl: audioUrl,
      durationSeconds: durationSeconds,
      fallbackText: null,
    );
    _recordDiagnostic(FrontendStage.ttsApplyDecision,
        messageId: messageId,
        reason: DiagnosticReason.values.byName(_ttsHandoffState.name),
        state: {
          'bufferedCount': _bufferedTtsResolutions.length,
          'hasAudio': audioUrl.isNotEmpty
        });
    if (_ttsHandoffState == _StreamTtsHandoffState.committing) {
      _bufferedTtsResolutions[messageId] = resolution;
      return;
    }
    if (_ttsHandoffState == _StreamTtsHandoffState.committed) {
      unawaited(_enqueueCommittedTtsResolution(messageId, resolution));
      return;
    }
    _terminalAudioFallbacks.remove(messageId);
    var updated = false;

    for (var i = 0; i < _currentTimelineMessages.length; i++) {
      final msg = _currentTimelineMessages[i];
      if (msg.id == messageId) {
        final blocks = msg.blocks;
        if (blocks != null && blocks.isNotEmpty && blocks.first is AudioBlock) {
          final oldAudio = blocks.first as AudioBlock;
          final newBlock = AudioBlock(
            messageId: msg.id,
            url: audioUrl,
            text: oldAudio.text,
            durationSeconds: durationSeconds ?? oldAudio.durationSeconds,
            status: BlockStatus.success,
          );
          _currentTimelineMessages[i] = Message.fromBlocks(
            id: msg.id,
            role: msg.role,
            sourceMessageId: msg.sourceMessageId,
            blocks: [newBlock],
            createdAt: msg.createdAt,
            status: 'sent',
          );
          updated = true;
        }
      }
    }

    for (final entry in _stablePendingAudioMessages.entries) {
      if (entry.value.id == messageId) {
        final msg = entry.value;
        final blocks = msg.blocks;
        if (blocks != null && blocks.isNotEmpty && blocks.first is AudioBlock) {
          final oldAudio = blocks.first as AudioBlock;
          final newBlock = AudioBlock(
            messageId: msg.id,
            url: audioUrl,
            text: oldAudio.text,
            durationSeconds: durationSeconds ?? oldAudio.durationSeconds,
            status: BlockStatus.success,
          );
          _stablePendingAudioMessages[entry.key] = Message.fromBlocks(
            id: msg.id,
            role: msg.role,
            sourceMessageId: msg.sourceMessageId,
            blocks: [newBlock],
            createdAt: msg.createdAt,
            status: 'sent',
          );
          updated = true;
        }
      }
    }

    if (updated) {
      unawaited(_enqueue(() async {
        if (_disposed) return;
        // 流中 raw 尚未落库，回填只能更新缓存，不能提前写带外键的投影映射。
        await _ref
            .read(conversationTimelineCacheProvider)
            .replaceMessagesTransient(
              conversationId: convId,
              messages: List<Message>.from(_currentTimelineMessages),
            );
        _recordDiagnostic(FrontendStage.ttsApplyDecision,
            messageId: messageId,
            phase: DiagnosticPhase.end,
            reason: DiagnosticReason.streaming,
            state: {'transientApplied': true});
      }));
    }
  }

  void updateFallbackText({
    required String messageId,
    required String text,
  }) {
    if (!canAcceptTtsResolution(messageId)) return;
    final resolution = (
      audioUrl: null,
      durationSeconds: null,
      fallbackText: text,
    );
    _recordDiagnostic(FrontendStage.ttsApplyDecision,
        messageId: messageId,
        reason: DiagnosticReason.values.byName(_ttsHandoffState.name),
        state: {
          'fallbackText': true,
          'bufferedCount': _bufferedTtsResolutions.length
        });
    if (_ttsHandoffState == _StreamTtsHandoffState.committing) {
      _bufferedTtsResolutions[messageId] = resolution;
      return;
    }
    if (_ttsHandoffState == _StreamTtsHandoffState.committed) {
      unawaited(_enqueueCommittedTtsResolution(messageId, resolution));
      return;
    }
    _terminalAudioFallbacks[messageId] = text;
    var updated = false;

    for (var i = 0; i < _currentTimelineMessages.length; i++) {
      final msg = _currentTimelineMessages[i];
      if (msg.id == messageId) {
        _currentTimelineMessages[i] = Message.text(
          id: msg.id,
          role: msg.role,
          sourceMessageId: msg.sourceMessageId,
          content: text,
          createdAt: msg.createdAt,
          status: 'sent',
        );
        updated = true;
      }
    }

    for (final entry in _stablePendingAudioMessages.entries) {
      if (entry.value.id == messageId) {
        final msg = entry.value;
        _stablePendingAudioMessages[entry.key] = Message.text(
          id: msg.id,
          role: msg.role,
          sourceMessageId: msg.sourceMessageId,
          content: text,
          createdAt: msg.createdAt,
          status: 'sent',
        );
        updated = true;
      }
    }

    if (updated) {
      unawaited(_enqueue(() async {
        if (_disposed) return;
        // 失败回退同样属于流中瞬态更新；持久化统一留给 commit。
        await _ref
            .read(conversationTimelineCacheProvider)
            .replaceMessagesTransient(
              conversationId: convId,
              messages: List<Message>.from(_currentTimelineMessages),
            );
        _recordDiagnostic(FrontendStage.ttsApplyDecision,
            messageId: messageId,
            phase: DiagnosticPhase.end,
            reason: DiagnosticReason.streaming,
            state: {'transientApplied': true, 'fallbackText': true});
      }));
    }
  }

  void _discardTtsResolutions() {
    _ttsHandoffState = _StreamTtsHandoffState.discarded;
    _scheduledAudioMessageIds.clear();
    _terminalAudioFallbacks.clear();
    _bufferedTtsResolutions.clear();
    _committedTtsMessages.clear();
  }

  Future<void> _enqueueCommittedTtsResolution(
    String messageId,
    _StreamTtsResolution resolution,
  ) {
    final future = _committedTtsWriteQueue.catchError((_) {}).then((_) async {
      if (!canAcceptTtsResolution(messageId) ||
          _ttsHandoffState != _StreamTtsHandoffState.committed) {
        return;
      }
      final baseMessage = _committedTtsMessages[messageId];
      if (baseMessage == null) {
        _recordDiagnostic(FrontendStage.ttsApplyDecision,
            messageId: messageId,
            phase: DiagnosticPhase.skip,
            reason: DiagnosticReason.unknownMessage);
        return;
      }
      final fallbackText = resolution.fallbackText;
      final nextMessage = fallbackText != null
          ? Message.text(
              id: baseMessage.id,
              role: baseMessage.role,
              sourceMessageId: baseMessage.sourceMessageId,
              content: fallbackText,
              createdAt: baseMessage.createdAt,
              status: 'sent',
            )
          : Message.fromBlocks(
              id: baseMessage.id,
              role: baseMessage.role,
              sourceMessageId: baseMessage.sourceMessageId,
              blocks: [
                AudioBlock(
                  messageId: baseMessage.id,
                  url: resolution.audioUrl ?? '',
                  text: baseMessage.blocks
                      ?.whereType<AudioBlock>()
                      .firstOrNull
                      ?.text,
                  durationSeconds: resolution.durationSeconds,
                  status: BlockStatus.success,
                ),
              ],
              createdAt: baseMessage.createdAt,
              status: 'sent',
            );
      _committedTtsMessages[messageId] = nextMessage;
      try {
        final historyStore = _ref.read(chatHistoryStoreProvider);
        final sourceMessageId = nextMessage.sourceMessageId?.trim() ?? '';
        final sourceIsActive = await historyStore.isRawMessageActive(
          conversationId: convId,
          messageId: sourceMessageId,
        );
        if (!sourceIsActive) {
          _recordDiagnostic(FrontendStage.ttsApplyDecision,
              messageId: messageId,
              phase: DiagnosticPhase.skip,
              reason: DiagnosticReason.rawInactive);
          _retireCommittedTtsMessage(messageId);
          return;
        }
        await historyStore.updateMessage(
          conversationId: convId,
          message: nextMessage,
        );
        _recordDiagnostic(FrontendStage.ttsPersisted,
            messageId: messageId,
            phase: DiagnosticPhase.end,
            reason: DiagnosticReason.persisted,
            state: {'fallbackText': fallbackText != null});
        if (!await historyStore.isRawMessageActive(
          conversationId: convId,
          messageId: sourceMessageId,
        )) {
          _recordDiagnostic(FrontendStage.ttsApplyDecision,
              messageId: messageId,
              phase: DiagnosticPhase.skip,
              reason: DiagnosticReason.rawInactive,
              state: {'afterPersist': true});
          await _ref.read(conversationTimelineCacheProvider).replaceMessages(
            conversationId: convId,
            removeMessageIds: <String>[messageId],
          );
          _retireCommittedTtsMessage(messageId);
        }
      } catch (error, stack) {
        _recordDiagnostic(FrontendStage.ttsFailed,
            messageId: messageId,
            phase: DiagnosticPhase.error,
            reason: DiagnosticReason.persistenceFailed,
            error: error,
            stack: stack);
        AppLogger.error(
          'ChatActions',
          '流式 TTS 收尾回写失败',
          metadata: {
            'convId': convId,
            'messageId': messageId,
            'error': error.toString(),
          },
        );
      }
    });
    _committedTtsWriteQueue = future.catchError((_) {});
    return future;
  }

  void _retireCommittedTtsMessage(String messageId) {
    _scheduledAudioMessageIds.remove(messageId);
    _terminalAudioFallbacks.remove(messageId);
    _bufferedTtsResolutions.remove(messageId);
    _committedTtsMessages.remove(messageId);
  }
}

