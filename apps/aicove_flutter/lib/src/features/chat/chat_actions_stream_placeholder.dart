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

class _RawStreamSegment {
  const _RawStreamSegment(this.kind, this.content);

  final _RawStreamSegmentKind kind;
  final String content;
}

final RegExp _streamHiddenImageTagRegex = RegExp(
  r'<image>([\s\S]*?)</image>',
  caseSensitive: false,
);

String _stripHiddenImageTagsForDisplay(String value) {
  if (value.isEmpty) return value;
  var result = value.replaceAll(_streamHiddenImageTagRegex, '');
  final lower = result.toLowerCase();
  final openIndex = lower.lastIndexOf('<image>');
  if (openIndex >= 0 && lower.indexOf('</image>', openIndex) < 0) {
    result = result.substring(0, openIndex);
  }
  return result;
}

class _StreamPlaceholderDelivery {
  _StreamPlaceholderDelivery(
    this._ref, {
    required this.convId,
    required this.formatConfig,
    required this.enableTtsPlaceholders,
    this.segmentDelay = Duration.zero,
  });

  static const String kGeneratingText = '生成中...';
  static const Duration _kFlushInterval = Duration(milliseconds: 180);
  static const Duration _kThinkingPlaceholderDelay =
      Duration(milliseconds: 450);

  final Ref _ref;
  final String convId;
  final MessageFormatConfig formatConfig;
  final bool enableTtsPlaceholders;
  final Duration segmentDelay;

  final StringBuffer _rawStreamText = StringBuffer();
  final List<Message> _currentTimelineMessages = <Message>[];
  final Map<String, Message> _stablePendingAudioMessages = <String, Message>{};
  final String _pendingRawSourceId = genId('raw_msg');

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
    _fallbackTriggered = false;
    _fallbackObserved = false;
    _receivedDelta = false;
    _finalizedRawText = null;
    _thinkingPlaceholderElapsed = false;
    _rawStreamText.clear();
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
    return _buildTimelineDescriptors(
      effectiveFinalText,
      finalize: true,
    ).isNotEmpty;
  }

  Future<void> finalize({required String finalText}) async {
    if (_disposed) return;
    final effectiveFinalText = _resolveEffectiveFinalText(finalText);
    final writeEpoch = _writeEpoch;
    _finalizedRawText = effectiveFinalText;
    _fallbackTriggered = false;
    await _drainSegmentRevealBacklog(sourceRaw: effectiveFinalText);
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
    _currentTimelineMessages.clear();
    _stablePendingAudioMessages.clear();
    _rawStreamText.clear();
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

    final preservedPending = _pendingAudioPlaceholderMessages(
      sourceMessageId: sourceMessageId,
    );
    if (preservedPending.isEmpty) {
      return normalizedCommitted;
    }

    final merged = <Message>[];
    var committedIndex = 0;
    for (final timelineMessage in _currentTimelineMessages) {
      if (_isPendingAudioPlaceholderMessage(timelineMessage)) {
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

  String _resolveEffectiveFinalText(String finalText) {
    final candidate = finalText.trim();
    if (candidate.isNotEmpty) return finalText;
    final streamed = _rawStreamText.toString();
    if (streamed.trim().isNotEmpty) return streamed;
    return finalText;
  }

  Future<void> removePlaceholders() async {
    _writeEpoch += 1;
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
    _writeEpoch += 1;
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
      if (_disposed || writeEpoch != _writeEpoch) return;
      await _ensureTimelineBaseMs();
      if (_disposed || writeEpoch != _writeEpoch) return;
      final previousMessages =
          List<Message>.from(_currentTimelineMessages, growable: false);
      final sourceRaw = _finalizedRawText ?? _rawStreamText.toString();
      final messages = _materializeTimeline(
        _buildTimelineDescriptors(sourceRaw, finalize: finalize),
      );
      final shouldNotifyTimeline =
          !_streamTimelineMessagesVisuallyEqual(previousMessages, messages);
      _currentTimelineMessages
        ..clear()
        ..addAll(messages);
      if (!shouldNotifyTimeline) return;
      await _ref
          .read(conversationTimelineCacheProvider)
          .replaceMessagesTransient(
            conversationId: convId,
            removeMessageIds: [
              for (final message in previousMessages) message.id,
            ],
            messages: messages,
          );
    });
  }

  List<_StreamDescriptor> _buildTimelineDescriptors(
    String rawText, {
    required bool finalize,
  }) {
    final segments = _extractRawSegments(rawText);
    final orderedDescriptors = <_StreamDescriptor>[];
    final descriptors = <_StreamDescriptor>[];
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
        forceSealTail: finalize || hasFollowingBoundary,
      );
      orderedDescriptors.addAll(described.sealed);
      if (!finalize && !formatConfig.enableChunking && !hasFollowingBoundary) {
        activeText = described.active;
      }
    }
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
    if (rawText.trim().isEmpty) return 0;
    final segments = _extractRawSegments(rawText);
    final orderedDescriptors = <_StreamDescriptor>[];
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
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
        forceSealTail: true,
      );
      orderedDescriptors.addAll(described.sealed);
    }
    return _countSealedTextDescriptorsInOrder(orderedDescriptors);
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
    final lowerRaw = rawText.toLowerCase();
    var cursor = 0;
    parseLoop:
    while (cursor < rawText.length) {
      final ttsOpenIndex = lowerRaw.indexOf('<tts>', cursor);
      final imageOpenIndex = lowerRaw.indexOf('<image>', cursor);
      final openIndex = switch ((ttsOpenIndex, imageOpenIndex)) {
        (>= 0, >= 0) =>
          ttsOpenIndex < imageOpenIndex ? ttsOpenIndex : imageOpenIndex,
        (>= 0, _) => ttsOpenIndex,
        (_, >= 0) => imageOpenIndex,
        _ => -1,
      };
      if (openIndex < 0) {
        final tail = enableTtsPlaceholders
            ? _sanitizeVisibleTextFragment(rawText.substring(cursor))
            : _renderTtsAsPlainText(rawText.substring(cursor));
        if (tail.trim().isNotEmpty) {
          segments.add(_RawStreamSegment(_RawStreamSegmentKind.text, tail));
        }
        break;
      }
      final beforeText = _sanitizeVisibleTextFragment(
        rawText.substring(cursor, openIndex),
      );
      if (beforeText.trim().isNotEmpty) {
        segments.add(_RawStreamSegment(_RawStreamSegmentKind.text, beforeText));
      }
      if (openIndex == ttsOpenIndex) {
        final closeIndex = lowerRaw.indexOf('</tts>', openIndex + 5);
        if (closeIndex < 0) {
          if (enableTtsPlaceholders) {
            segments
                .add(const _RawStreamSegment(_RawStreamSegmentKind.tts, ''));
          }
          break parseLoop;
        }
        final ttsText = rawText.substring(openIndex + 5, closeIndex).trim();
        if (enableTtsPlaceholders) {
          segments.add(_RawStreamSegment(_RawStreamSegmentKind.tts, ttsText));
        } else if (ttsText.isNotEmpty) {
          segments.add(_RawStreamSegment(_RawStreamSegmentKind.text, ttsText));
        }
        cursor = closeIndex + 6;
        continue;
      }
      final openTagEnd = lowerRaw.indexOf('>', openIndex);
      if (openTagEnd < 0) {
        segments.add(const _RawStreamSegment(_RawStreamSegmentKind.image, ''));
        break;
      }
      final closeIndex = lowerRaw.indexOf('</image>', openTagEnd + 1);
      segments.add(const _RawStreamSegment(_RawStreamSegmentKind.image, ''));
      if (closeIndex < 0) {
        break;
      }
      cursor = closeIndex + 8;
    }
    return segments;
  }

  String _renderTtsAsPlainText(String rawText) {
    if (rawText.isEmpty) return rawText;
    var result = rawText.replaceAllMapped(
      RegExp(r'<tts>(.*?)</tts>', caseSensitive: false, dotAll: true),
      (match) => (match.group(1) ?? '').trim(),
    );
    final lower = result.toLowerCase();
    final openIndex = lower.lastIndexOf('<tts>');
    if (openIndex >= 0 && lower.indexOf('</tts>', openIndex) < 0) {
      result = result.substring(0, openIndex);
    }
    return _sanitizeVisibleTextFragment(result);
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
    if (!formatConfig.enableChunking) {
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
    final chunks = MessageFormatter.formatAndChunkText(text, formatConfig)
        .map((chunk) => chunk.trim())
        .where((chunk) => chunk.isNotEmpty)
        .toList(growable: false);
    if (chunks.isEmpty) return const _TextSegmentDescriptors();
    if (forceSealTail) {
      return _TextSegmentDescriptors(
        sealed: <_StreamDescriptor>[
          for (final chunk in chunks)
            _StreamDescriptor.text(
              content: chunk,
              messageStatus: 'sent',
              textStatus: BlockStatus.success,
            ),
        ],
      );
    }
    final sealed = <_StreamDescriptor>[
      for (final chunk in chunks.take(chunks.length - 1))
        _StreamDescriptor.text(
          content: chunk,
          messageStatus: 'sent',
          textStatus: BlockStatus.success,
        ),
    ];
    final lastChunk = chunks.last;
    if (streamTextEndsWithChunkBoundary(lastChunk, formatConfig)) {
      sealed.add(
        _StreamDescriptor.text(
          content: lastChunk,
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

  bool _isPersistableProjectedTimelineMessage(Message message) {
    if (_isPendingAudioPlaceholderMessage(message)) {
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
      _StreamDescriptorKind.pendingAudio => Message.fromBlocks(
          id: baseMessage.id,
          role: baseMessage.role,
          sourceMessageId: _pendingRawSourceId,
          blocks: [
            AudioBlock(
              messageId: baseMessage.id,
              url: '',
              text: descriptor.content,
              status: BlockStatus.pending,
            ),
          ],
          createdAt: effectiveCreatedAt,
          status: descriptor.messageStatus,
        ),
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
      if (_disposed) return;
      await task();
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
