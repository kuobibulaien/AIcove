part of 'chat_actions.dart';

enum _StreamDescriptorKind { text, pendingAudio }

class _StreamDescriptor {
  const _StreamDescriptor._({
    required this.kind,
    required this.content,
    required this.messageStatus,
    this.textStatus,
  });

  final _StreamDescriptorKind kind;
  final String content;
  final String messageStatus;
  final BlockStatus? textStatus;

  factory _StreamDescriptor.text({
    required String content,
    required String messageStatus,
    required BlockStatus textStatus,
  }) {
    return _StreamDescriptor._(
      kind: _StreamDescriptorKind.text,
      content: content,
      messageStatus: messageStatus,
      textStatus: textStatus,
    );
  }

  factory _StreamDescriptor.generating() {
    return const _StreamDescriptor._(
      kind: _StreamDescriptorKind.text,
      content: _StreamPlaceholderDelivery.kGeneratingText,
      messageStatus: 'sending',
      textStatus: BlockStatus.streaming,
    );
  }

  factory _StreamDescriptor.pendingAudio({
    required String content,
  }) {
    return _StreamDescriptor._(
      kind: _StreamDescriptorKind.pendingAudio,
      content: content,
      messageStatus: 'sending',
    );
  }
}

class _TextSegmentDescriptors {
  const _TextSegmentDescriptors({
    this.sealed = const <_StreamDescriptor>[],
    this.active,
  });

  final List<_StreamDescriptor> sealed;
  final _StreamDescriptor? active;
}

enum _RawStreamSegmentKind { text, tts, image }

enum _StreamTtsHandoffState { streaming, committing, committed, discarded }

typedef _StreamTtsResolution = ({
  String? audioUrl,
  double? durationSeconds,
  String? fallbackText,
});

class _RawStreamSegment {
  const _RawStreamSegment(this.kind, this.content);

  final _RawStreamSegmentKind kind;
  final String content;
}

String _stripHiddenImageTagsForDisplay(String value) {
  if (value.isEmpty) return value;
  return firstPartyContentTagScanner
      .scan(value)
      // 未闭合的快速模式生图标签同样隐藏，不外泄提示词
      .where((segment) => !ImagePlugin.isInlineImageElement(segment))
      .map((segment) => segment.raw)
      .join();
}

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

  final StringBuffer _rawStreamText = StringBuffer();
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
    final previousRaw = _rawStreamText.toString();
    _rawStreamText.write(delta);
    _receivedDelta = true;
    _dirty = true;
    final shouldFlushNow =
        _countReadyPendingAudioDescriptors(_rawStreamText.toString()) >
            _countReadyPendingAudioDescriptors(previousRaw);
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

  void beginTtsCommit() {
    if (_ttsHandoffState != _StreamTtsHandoffState.streaming) return;
    _ttsHandoffState = _StreamTtsHandoffState.committing;
  }

  List<Message> buildFinalTimelineMessages({
    required List<Message> committedMessages,
    required String sourceMessageId,
  }) {
    final normalizedCommitted = <Message>[
      for (final message in committedMessages)
        message.copyWith(sourceMessageId: sourceMessageId),
    ];
    if (!_fallbackObserved) {
      final timelineProjection = _buildProjectedTimelineMessages(
        sourceMessageId: sourceMessageId,
      );
      if (timelineProjection.isNotEmpty) {
        return timelineProjection;
      }
    }
    if (_currentTimelineMessages.isEmpty) {
      return normalizedCommitted;
    }

    final preservedTts = ttsTimelineMessages(
      sourceMessageId: sourceMessageId,
    );
    if (preservedTts.isEmpty) {
      return normalizedCommitted;
    }

    final merged = <Message>[];
    var committedIndex = 0;
    for (final timelineMessage in _currentTimelineMessages) {
      if (_scheduledAudioMessageIds.contains(timelineMessage.id)) {
        merged.add(
          timelineMessage.copyWith(sourceMessageId: sourceMessageId),
        );
        continue;
      }
      if (committedIndex < normalizedCommitted.length) {
        merged.add(normalizedCommitted[committedIndex++]);
      }
    }
    if (committedIndex < normalizedCommitted.length) {
      merged.addAll(normalizedCommitted.skip(committedIndex));
    }
    return merged;
  }

  List<Message> _buildProjectedTimelineMessages({
    required String sourceMessageId,
  }) {
    if (_currentTimelineMessages.isEmpty) {
      return const <Message>[];
    }
    final projection = <Message>[
      for (final message in _currentTimelineMessages)
        if (_isPersistableProjectedTimelineMessage(message))
          message.copyWith(sourceMessageId: sourceMessageId),
    ];
    return projection;
  }

  List<Message> pendingAudioPlaceholderMessages({
    required String sourceMessageId,
  }) {
    return _pendingAudioPlaceholderMessages(sourceMessageId: sourceMessageId);
  }

  List<Message> ttsTimelineMessages({
    required String sourceMessageId,
  }) {
    return <Message>[
      for (final message in _currentTimelineMessages)
        if (_scheduledAudioMessageIds.contains(message.id))
          message.copyWith(sourceMessageId: sourceMessageId),
    ];
  }

  bool get hasAudioPlaceholders =>
      _currentTimelineMessages.any(
        (message) => _scheduledAudioMessageIds.contains(message.id),
      ) ||
      _committedTtsMessages.isNotEmpty;

  bool canAcceptTtsResolution(String messageId) {
    final accepted = _scheduledAudioMessageIds.contains(messageId) &&
        _ttsHandoffState != _StreamTtsHandoffState.discarded;
    if (!accepted) {
      _recordDiagnostic(FrontendStage.ttsApplyDecision,
          messageId: messageId,
          phase: DiagnosticPhase.skip,
          reason: _ttsHandoffState == _StreamTtsHandoffState.discarded
              ? DiagnosticReason.discarded
              : DiagnosticReason.unknownMessage);
    }
    return accepted;
  }

  String _resolveEffectiveFinalText(String finalText) {
    final candidate = finalText.trim();
    if (candidate.isNotEmpty) return finalText;
    final streamed = _rawStreamText.toString();
    if (streamed.trim().isNotEmpty) return streamed;
    return finalText;
  }

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
        final isActiveTailText = tail != null &&
            tail.phase == ActiveStreamPhase.streamingTail &&
            message.id == tail.tailMessageId;
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

  /// 定位当前物化序列里的活跃尾：非分段模式的增长文本或「生成中」占位。
  ({String tailMessageId, String tailText, ActiveStreamPhase phase})?
      _locateActiveTail(
    List<_StreamDescriptor> descriptors,
    List<Message> messages,
  ) {
    // 注意：生成中占位被钉在序列尾部，活跃文本（若有）在它之前——
    // 活跃文本优先（streamingTail），仅有占位时报 thinking。
    String? thinkingMessageId;
    for (var index = descriptors.length - 1; index >= 0; index--) {
      final descriptor = descriptors[index];
      if (descriptor.kind != _StreamDescriptorKind.text) continue;
      final isGenerating = descriptor.content == kGeneratingText &&
          descriptor.textStatus == BlockStatus.streaming;
      if (isGenerating) {
        thinkingMessageId ??= messages[index].id;
        continue;
      }
      if (descriptor.messageStatus == 'sending') {
        return (
          tailMessageId: messages[index].id,
          tailText: descriptor.content,
          phase: ActiveStreamPhase.streamingTail,
        );
      }
      // 已 seal 的文本段：不再向前找活跃文本（活跃段只会在 seal 段之后）。
      break;
    }
    if (thinkingMessageId != null) {
      return (
        tailMessageId: thinkingMessageId,
        tailText: '',
        phase: ActiveStreamPhase.thinking,
      );
    }
    return null;
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

  _TextSegmentDescriptors _describeTimeline(
    String rawText, {
    required bool sealTail,
  }) {
    if (_parsedRawText == rawText && _parsedSealTail == sealTail) {
      final cached = _parsedTimeline;
      if (cached != null) return cached;
    }
    final segments = _extractRawSegments(rawText);
    final orderedDescriptors = <_StreamDescriptor>[];
    _StreamDescriptor? activeText;

    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      final hasFollowingBoundary = index < segments.length - 1;
      if (segment.kind == _RawStreamSegmentKind.tts && enableTtsPlaceholders) {
        final ttsText = segment.content.trim();
        if (ttsText.isNotEmpty) {
          orderedDescriptors.add(
            _StreamDescriptor.pendingAudio(content: ttsText),
          );
        }
        continue;
      }
      if (segment.kind == _RawStreamSegmentKind.image) {
        continue;
      }
      final described = _describeTextSegment(
        segment.content,
        forceSealTail: sealTail || hasFollowingBoundary,
      );
      orderedDescriptors.addAll(described.sealed);
      if (!sealTail &&
          (!formatConfig.enableChunking || _transportStreaming) &&
          !hasFollowingBoundary) {
        activeText = described.active;
      }
    }
    final result = _TextSegmentDescriptors(
      sealed: orderedDescriptors,
      active: activeText,
    );
    _parsedRawText = rawText;
    _parsedSealTail = sealTail;
    _parsedTimeline = result;
    return result;
  }

  List<_StreamDescriptor> _buildTimelineDescriptors(
    String rawText, {
    required bool finalize,
  }) {
    // A completed input seals its unpunctuated tail, but the reveal cursor
    // still advances one segment at a time until the backlog is drained.
    final parsed = _describeTimeline(
      rawText,
      sealTail: finalize || _finalizedRawText != null,
    );
    final orderedDescriptors = parsed.sealed;
    final activeText = parsed.active;
    final descriptors = <_StreamDescriptor>[];
    if (finalize) {
      _visibleSealedTextCount = _countSealedTextDescriptorsInOrder(
        orderedDescriptors,
      );
      _nextSealedRevealAt = null;
      return <_StreamDescriptor>[
        ...orderedDescriptors,
        if (activeText != null) activeText,
      ];
    }

    final totalSealedCount = _countSealedTextDescriptorsInOrder(
      orderedDescriptors,
    );
    final visibleSealedCount = _resolveVisibleSealedTextCount(totalSealedCount);
    var remainingVisibleSealed = visibleSealedCount;
    var hasHiddenSealed = false;
    for (final descriptor in orderedDescriptors) {
      if (_countsTowardSegmentDelay(descriptor)) {
        if (remainingVisibleSealed <= 0) {
          hasHiddenSealed = true;
          break;
        }
        remainingVisibleSealed -= 1;
      }
      descriptors.add(descriptor);
    }
    if (!hasHiddenSealed && activeText != null) {
      descriptors.add(activeText);
    }

    if (hasHiddenSealed) {
      // 待展示的已完成分段也是未提交的视觉变化。即使模型暂时没有
      // 新 delta，定时 flush 仍须执行，不能因 _dirty=false 直接退出。
      _dirty = true;
      _scheduleFlush();
    }

    final hasBufferedContent =
        orderedDescriptors.isNotEmpty || activeText != null;
    if (_shouldShowGeneratingPlaceholder(
      descriptors,
      hasBufferedContent: hasBufferedContent,
    )) {
      descriptors.add(_StreamDescriptor.generating());
    }
    return descriptors;
  }

  bool _shouldShowGeneratingPlaceholder(
    List<_StreamDescriptor> descriptors, {
    required bool hasBufferedContent,
  }) {
    if (descriptors.isNotEmpty) return true;
    if (hasBufferedContent) return true;
    return _thinkingPlaceholderElapsed || _fallbackTriggered;
  }

  int _resolveVisibleSealedTextCount(int totalSealedCount) {
    if (totalSealedCount <= 0) {
      _visibleSealedTextCount = 0;
      _nextSealedRevealAt = null;
      return 0;
    }
    if (segmentDelay <= Duration.zero) {
      _visibleSealedTextCount = totalSealedCount;
      _nextSealedRevealAt = null;
      return totalSealedCount;
    }

    if (_visibleSealedTextCount > totalSealedCount) {
      _visibleSealedTextCount = totalSealedCount;
    }
    final now = DateTime.now();
    _nextSealedRevealAt ??= now.add(segmentDelay);
    final revealAt = _nextSealedRevealAt;
    if (revealAt != null && !now.isBefore(revealAt)) {
      _visibleSealedTextCount += 1;
      if (_visibleSealedTextCount >= totalSealedCount) {
        _nextSealedRevealAt = null;
      } else {
        _nextSealedRevealAt = now.add(segmentDelay);
      }
    }
    return _visibleSealedTextCount;
  }

  int _countSealedTextDescriptors(String rawText) {
    return _countSealedTextDescriptorsInOrder(
      _describeTimeline(rawText, sealTail: true).sealed,
    );
  }

  int _countReadyPendingAudioDescriptors(String rawText) {
    if (!enableTtsPlaceholders || rawText.trim().isEmpty) return 0;
    var total = 0;
    for (final segment in _extractRawSegments(rawText)) {
      if (segment.kind != _RawStreamSegmentKind.tts) continue;
      if (segment.content.trim().isEmpty) continue;
      total += 1;
    }
    return total;
  }

  int _countSealedTextDescriptorsInOrder(List<_StreamDescriptor> descriptors) {
    var total = 0;
    for (final descriptor in descriptors) {
      if (_countsTowardSegmentDelay(descriptor)) {
        total += 1;
      }
    }
    return total;
  }

  bool _countsTowardSegmentDelay(_StreamDescriptor descriptor) {
    return switch (descriptor.kind) {
      _StreamDescriptorKind.text => true,
      _StreamDescriptorKind.pendingAudio => true,
    };
  }

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

  List<_RawStreamSegment> _extractRawSegments(String rawText) {
    if (rawText.isEmpty) return const <_RawStreamSegment>[];
    final segments = <_RawStreamSegment>[];
    final pendingText = StringBuffer();
    void flushText() {
      final text = _sanitizeVisibleTextFragment(pendingText.toString());
      pendingText.clear();
      if (text.trim().isNotEmpty) {
        segments.add(_RawStreamSegment(_RawStreamSegmentKind.text, text));
      }
    }

    for (final segment in firstPartyContentTagScanner.scan(rawText)) {
      if (segment is ContentTagElement &&
          segment.spec.display == ContentTagDisplay.tts) {
        flushText();
        if (!segment.closed) {
          if (enableTtsPlaceholders) {
            segments
                .add(const _RawStreamSegment(_RawStreamSegmentKind.tts, ''));
          }
          break;
        }
        final ttsText = segment.inner.trim();
        if (enableTtsPlaceholders) {
          segments.add(_RawStreamSegment(_RawStreamSegmentKind.tts, ttsText));
        } else if (ttsText.isNotEmpty) {
          segments.add(_RawStreamSegment(_RawStreamSegmentKind.text, ttsText));
        }
        continue;
      }
      if (ImagePlugin.isInlineImageElement(segment)) {
        flushText();
        segments.add(const _RawStreamSegment(_RawStreamSegmentKind.image, ''));
        if (!(segment as ContentTagElement).closed) break;
        continue;
      }
      pendingText.write(segment.raw);
    }
    flushText();
    return segments;
  }

  String _sanitizeVisibleTextFragment(String value) {
    if (value.isEmpty) return value;
    var result = _stripHiddenImageTagsForDisplay(value);
    result = result.replaceAll(
      RegExp(r'<create_trigger\s[^>]*?/?>', caseSensitive: false),
      '',
    );
    result = result.replaceAll(
      RegExp(
        r'<create_trigger\s[^>]*?>.*?</create_trigger>',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    );
    result = result.replaceAll(
      RegExp(r'<delete_trigger\s[^>]*?/?>', caseSensitive: false),
      '',
    );
    final lastLt = result.lastIndexOf('<');
    final lastGt = result.lastIndexOf('>');
    if (lastLt > lastGt) result = result.substring(0, lastLt);
    return result;
  }

  _TextSegmentDescriptors _describeTextSegment(
    String value, {
    required bool forceSealTail,
  }) {
    final text = _sanitizeVisibleTextFragment(value).trim();
    if (text.isEmpty) return const _TextSegmentDescriptors();
    if (!formatConfig.enableChunking ||
        (_transportStreaming && !forceSealTail)) {
      if (forceSealTail) {
        return _TextSegmentDescriptors(
          sealed: <_StreamDescriptor>[
            _StreamDescriptor.text(
              content: text,
              messageStatus: 'sent',
              textStatus: BlockStatus.success,
            ),
          ],
        );
      }
      return _TextSegmentDescriptors(
        active: _StreamDescriptor.text(
          content: text,
          messageStatus: 'sending',
          textStatus: BlockStatus.success,
        ),
      );
    }
    final chunks = MessageFormatter.formatAndChunk(
      text,
      formatConfig,
      protectedRanges: protectedTagRanges(text, tagPresentation),
    )
        .map((chunk) => MessageChunk(
              chunk.text.trim(),
              openEnded: chunk.openEnded,
            ))
        .where((chunk) => chunk.text.isNotEmpty)
        .toList(growable: false);
    if (chunks.isEmpty) return const _TextSegmentDescriptors();
    if (forceSealTail) {
      return _TextSegmentDescriptors(
        sealed: <_StreamDescriptor>[
          for (final chunk in chunks)
            _StreamDescriptor.text(
              content: chunk.text,
              messageStatus: 'sent',
              textStatus: BlockStatus.success,
            ),
        ],
      );
    }
    final sealed = <_StreamDescriptor>[
      for (final chunk in chunks.take(chunks.length - 1))
        _StreamDescriptor.text(
          content: chunk.text,
          messageStatus: 'sent',
          textStatus: BlockStatus.success,
        ),
    ];
    final lastChunk = chunks.last;
    // 未闭合的组件还会继续增长，不能提前封口。
    if (!lastChunk.openEnded &&
        streamTextEndsWithChunkBoundary(lastChunk.text, formatConfig)) {
      sealed.add(
        _StreamDescriptor.text(
          content: lastChunk.text,
          messageStatus: 'sent',
          textStatus: BlockStatus.success,
        ),
      );
      return _TextSegmentDescriptors(sealed: sealed);
    }
    return _TextSegmentDescriptors(sealed: sealed);
  }

  List<Message> _materializeTimeline(List<_StreamDescriptor> descriptors) {
    final previous =
        List<Message>.from(_currentTimelineMessages, growable: false);
    final usedPreviousIds = <String>{};
    final nextStablePendingAudioMessages = <String, Message>{};
    final pendingAudioOccurrence = <String, int>{};
    final messages = <Message>[];
    // 追踪本帧已 materialize 段的最大 createdAt，用于把生成中占位排到所有真实段之后
    // （保证占位始终是 tail，见「占位钉底」改造：禁 promote 后真实段走 _createMessage 拿递增 tick，
    // 占位走 _rebuildMessage 保留旧时间会早于真实段 → 排序后失尾，故需把占位 createdAt 后移）。
    // 仅追踪真实段（排除生成中占位自身），避免占位跟自己比误触发重新分配导致多一次通知。
    final previousRealMaxCreatedAt = previous
        .where((m) => !_isGeneratingPlaceholderMessage(m))
        .map((m) => m.createdAt)
        .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    var maxMaterializedCreatedAt = previousRealMaxCreatedAt;
    for (var index = 0; index < descriptors.length; index++) {
      final descriptor = descriptors[index];
      Message? previousMessage;
      String? pendingAudioKey;
      if (descriptor.kind == _StreamDescriptorKind.pendingAudio) {
        final normalizedText = descriptor.content.trim();
        final occurrence = pendingAudioOccurrence[normalizedText] ?? 0;
        pendingAudioOccurrence[normalizedText] = occurrence + 1;
        pendingAudioKey = '$normalizedText#$occurrence';
      }
      if (index < previous.length &&
          !usedPreviousIds.contains(previous[index].id) &&
          _matchesDescriptor(previous[index], descriptor)) {
        previousMessage = previous[index];
      } else {
        previousMessage = _findReusablePreviousMessage(
          previous,
          descriptor: descriptor,
          usedPreviousIds: usedPreviousIds,
        );
      }
      previousMessage ??= pendingAudioKey == null
          ? null
          : _stablePendingAudioMessages[pendingAudioKey];
      if (previousMessage != null) {
        usedPreviousIds.add(previousMessage.id);
        if (pendingAudioKey != null) {
          nextStablePendingAudioMessages[pendingAudioKey] = previousMessage;
        }
      }
      final isReused = previousMessage != null;
      // 占位钉底：被复用的生成中占位，若其 createdAt 不晚于已 materialize 段，
      // 重新分配一个晚于 maxMaterializedCreatedAt 的时间，保证它排序后始终在 tail。
      // 条件式分配（仅当确实落后时）避免每帧更新 createdAt 触发反复通知。
      DateTime? placeholderCreatedAtOverride;
      if (isReused &&
          _isGeneratingPlaceholderMessage(previousMessage) &&
          maxMaterializedCreatedAt != null &&
          !previousMessage.createdAt.isAfter(maxMaterializedCreatedAt)) {
        placeholderCreatedAtOverride = _allocateCreatedAt();
      }
      final materialized = previousMessage == null
          ? _createMessage(descriptor)
          : _rebuildMessage(
              previousMessage,
              descriptor,
              createdAt: placeholderCreatedAtOverride,
            );
      if (pendingAudioKey != null) {
        nextStablePendingAudioMessages[pendingAudioKey] = materialized;
      }
      messages.add(materialized);
      // 仅用真实段（非占位）更新 maxMaterializedCreatedAt，避免占位的 override 时间
      // 污染下一帧判定（占位跟自己的 override 时间比会反复重新分配）。
      if (!_isGeneratingPlaceholderMessage(materialized) &&
          (maxMaterializedCreatedAt == null ||
              materialized.createdAt.isAfter(maxMaterializedCreatedAt))) {
        maxMaterializedCreatedAt = materialized.createdAt;
      }
    }
    _stablePendingAudioMessages
      ..clear()
      ..addAll(nextStablePendingAudioMessages);
    for (final message in messages) {
      if (_isPendingAudioPlaceholderMessage(message) &&
          !_scheduledAudioMessageIds.contains(message.id)) {
        _scheduledAudioMessageIds.add(message.id);
        onPendingAudioAppeared?.call(message);
      }
    }
    return messages;
  }

  Message? _findReusablePreviousMessage(
    List<Message> previous, {
    required _StreamDescriptor descriptor,
    required Set<String> usedPreviousIds,
  }) {
    for (final message in previous) {
      if (usedPreviousIds.contains(message.id)) continue;
      if (!_matchesDescriptor(message, descriptor)) continue;
      return message;
    }
    return null;
  }

  bool _matchesDescriptor(Message message, _StreamDescriptor descriptor) {
    final blocks = message.blocks;
    if (blocks == null || blocks.length != 1) return false;
    return switch (descriptor.kind) {
      _StreamDescriptorKind.text => blocks.first is TextBlock &&
          (((blocks.first as TextBlock).content.trim() ==
                  _StreamPlaceholderDelivery.kGeneratingText) ==
              (descriptor.content.trim() ==
                  _StreamPlaceholderDelivery.kGeneratingText)),
      _StreamDescriptorKind.pendingAudio => blocks.first is AudioBlock &&
          ((blocks.first as AudioBlock).text ?? '').trim() ==
              descriptor.content.trim(),
    };
  }

  bool _isGeneratingPlaceholderMessage(Message message) {
    final blocks = message.blocks;
    if (blocks == null || blocks.length != 1) return false;
    final block = blocks.first;
    return block is TextBlock &&
        block.status == BlockStatus.streaming &&
        block.content.trim() == kGeneratingText;
  }

  bool _isAudioTimelineMessage(Message message) {
    final blocks = message.blocks;
    if (blocks == null || blocks.length != 1) return false;
    final block = blocks.first;
    return block is AudioBlock && (block.text?.trim().isNotEmpty ?? false);
  }

  bool _isPersistableProjectedTimelineMessage(Message message) {
    if (_isAudioTimelineMessage(message)) {
      return true;
    }
    final textBlocks =
        message.blocks?.whereType<TextBlock>().toList() ?? const <TextBlock>[];
    if (textBlocks.length != 1) {
      return false;
    }
    final textBlock = textBlocks.single;
    final text = textBlock.content.trim();
    if (text.isEmpty) {
      return false;
    }
    if (text == kGeneratingText && textBlock.status == BlockStatus.streaming) {
      return false;
    }
    return true;
  }

  Message _createMessage(_StreamDescriptor descriptor) {
    final messageId = genId('msg');
    _recordDiagnostic(FrontendStage.segmentCreated,
        messageId: messageId,
        phase: DiagnosticPhase.end,
        state: {
          'segmentIndex': _timelineTick,
          'characters': descriptor.content.length,
          'pendingAudio': descriptor.kind == _StreamDescriptorKind.pendingAudio,
          'segmentDelayMs': segmentDelay.inMilliseconds
        });
    _ref
        .read(frontendDiagnosticsProvider)
        .bindMessage(messageId, diagnosticContext);
    return switch (descriptor.kind) {
      _StreamDescriptorKind.text => Message.fromBlocks(
          id: messageId,
          role: 'assistant',
          sourceMessageId: _pendingRawSourceId,
          blocks: [
            TextBlock(
              messageId: messageId,
              content: descriptor.content,
              status: descriptor.textStatus ?? BlockStatus.success,
            ),
          ],
          createdAt: _allocateCreatedAt(),
          status: descriptor.messageStatus,
        ),
      _StreamDescriptorKind.pendingAudio => Message.fromBlocks(
          id: messageId,
          role: 'assistant',
          sourceMessageId: _pendingRawSourceId,
          blocks: [
            AudioBlock(
              messageId: messageId,
              url: '',
              text: descriptor.content,
              status: BlockStatus.pending,
            ),
          ],
          createdAt: _allocateCreatedAt(),
          status: descriptor.messageStatus,
        ),
    };
  }

  Message _rebuildMessage(
    Message baseMessage,
    _StreamDescriptor descriptor, {
    DateTime? createdAt,
  }) {
    final effectiveCreatedAt = createdAt ?? baseMessage.createdAt;
    return switch (descriptor.kind) {
      _StreamDescriptorKind.text => Message.fromBlocks(
          id: baseMessage.id,
          role: baseMessage.role,
          sourceMessageId: _pendingRawSourceId,
          blocks: [
            TextBlock(
              messageId: baseMessage.id,
              content: descriptor.content,
              status: descriptor.textStatus ?? BlockStatus.success,
            ),
          ],
          createdAt: effectiveCreatedAt,
          status: descriptor.messageStatus,
        ),
      _StreamDescriptorKind.pendingAudio => () {
          final fallbackText = _terminalAudioFallbacks[baseMessage.id];
          if (fallbackText != null) {
            return Message.text(
              id: baseMessage.id,
              role: baseMessage.role,
              sourceMessageId: _pendingRawSourceId,
              content: fallbackText,
              createdAt: effectiveCreatedAt,
              status: 'sent',
            );
          }
          final existingAudio =
              baseMessage.blocks?.whereType<AudioBlock>().firstOrNull;
          final hasResolvedAudio =
              existingAudio != null && existingAudio.url.isNotEmpty;
          return Message.fromBlocks(
            id: baseMessage.id,
            role: baseMessage.role,
            sourceMessageId: _pendingRawSourceId,
            blocks: [
              AudioBlock(
                messageId: baseMessage.id,
                url: hasResolvedAudio ? existingAudio.url : '',
                text: descriptor.content,
                durationSeconds:
                    hasResolvedAudio ? existingAudio.durationSeconds : null,
                status: hasResolvedAudio
                    ? (existingAudio.status == BlockStatus.pending
                        ? BlockStatus.success
                        : existingAudio.status)
                    : BlockStatus.pending,
              ),
            ],
            createdAt: effectiveCreatedAt,
            status: hasResolvedAudio ? 'sent' : descriptor.messageStatus,
          );
        }(),
    };
  }

  DateTime _allocateCreatedAt() {
    final baseMs = _timelineBaseMs ??= DateTime.now().millisecondsSinceEpoch;
    final createdAt =
        DateTime.fromMillisecondsSinceEpoch(baseMs + (_timelineTick * 100));
    _timelineTick += 1;
    return createdAt;
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

  Future<void> _enqueue(Future<void> Function() task) {
    _queue = _queue.catchError((_) {}).then((_) async {
      if (_disposed) {
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
    });
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

bool _streamTimelineMessagesVisuallyEqual(
  List<Message> left,
  List<Message> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (!_streamTimelineMessageVisuallyEqual(left[index], right[index])) {
      return false;
    }
  }
  return true;
}

bool _streamTimelineMessageVisuallyEqual(Message left, Message right) {
  if (left.id != right.id ||
      left.role != right.role ||
      left.sourceMessageId != right.sourceMessageId ||
      left.content != right.content ||
      left.createdAt != right.createdAt ||
      left.status != right.status) {
    return false;
  }

  final leftBlocks = left.blocks ?? const <MessageBlock>[];
  final rightBlocks = right.blocks ?? const <MessageBlock>[];
  if (leftBlocks.length != rightBlocks.length) return false;
  for (var index = 0; index < leftBlocks.length; index++) {
    if (!_streamMessageBlockVisuallyEqual(
        leftBlocks[index], rightBlocks[index])) {
      return false;
    }
  }
  return true;
}

bool _streamMessageBlockVisuallyEqual(MessageBlock left, MessageBlock right) {
  if (left.runtimeType != right.runtimeType ||
      left.messageId != right.messageId ||
      left.type != right.type ||
      left.status != right.status ||
      left.modelId != right.modelId ||
      left.errorMessage != right.errorMessage) {
    return false;
  }
  if (left is TextBlock && right is TextBlock) {
    return left.content == right.content;
  }
  if (left is AudioBlock && right is AudioBlock) {
    return left.url == right.url &&
        left.text == right.text &&
        left.durationSeconds == right.durationSeconds;
  }
  if (left is ImageBlock && right is ImageBlock) {
    return left.url == right.url &&
        left.localPath == right.localPath &&
        left.base64 == right.base64 &&
        left.width == right.width &&
        left.height == right.height &&
        left.prompt == right.prompt;
  }
  if (left is EmojiBlock && right is EmojiBlock) {
    return left.emojiId == right.emojiId &&
        left.path == right.path &&
        left.matchedTag == right.matchedTag &&
        left.originalText == right.originalText;
  }
  if (left is FileBlock && right is FileBlock) {
    return left.fileName == right.fileName &&
        left.fileSize == right.fileSize &&
        left.mimeType == right.mimeType &&
        left.filePath == right.filePath;
  }
  if (left is CodeBlock && right is CodeBlock) {
    return left.content == right.content && left.language == right.language;
  }
  if (left is ThinkingBlock && right is ThinkingBlock) {
    return left.content == right.content && left.durationMs == right.durationMs;
  }
  if (left is ErrorBlock && right is ErrorBlock) {
    return left.message == right.message && left.errorCode == right.errorCode;
  }
  if (left is ToolBlock && right is ToolBlock) {
    return left.toolName == right.toolName &&
        left.toolCallId == right.toolCallId &&
        left.arguments.toString() == right.arguments.toString() &&
        left.result.toString() == right.result.toString();
  }
  return true;
}

bool streamTextEndsWithChunkBoundary(
  String text,
  MessageFormatConfig config,
) {
  if (!config.enableChunking) return false;
  final value = text.trimRight();
  if (value.isEmpty) return false;
  if (value.length < config.minSegmentLength) return false;

  final punctuations = config.chunkPunctuations
      .where((item) => item.isNotEmpty)
      .toList(growable: false)
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final punctuation in punctuations) {
    if (value.endsWith(punctuation)) {
      return true;
    }
  }
  return false;
}

/// 活跃尾「壳面」比较：忽略文本内容增长（文本走通道），
/// 其余任何变化（状态/时间/块形/错误）都视为结构转移。
bool _tailShellVisuallyEqual(Message left, Message right) {
  if (left.id != right.id ||
      left.role != right.role ||
      left.sourceMessageId != right.sourceMessageId ||
      left.createdAt != right.createdAt ||
      left.status != right.status) {
    return false;
  }
  final leftBlocks = left.blocks ?? const <MessageBlock>[];
  final rightBlocks = right.blocks ?? const <MessageBlock>[];
  if (leftBlocks.length != 1 || rightBlocks.length != 1) return false;
  final leftBlock = leftBlocks.single;
  final rightBlock = rightBlocks.single;
  return leftBlock is TextBlock &&
      rightBlock is TextBlock &&
      leftBlock.status == rightBlock.status &&
      leftBlock.modelId == rightBlock.modelId &&
      leftBlock.errorMessage == rightBlock.errorMessage;
}
