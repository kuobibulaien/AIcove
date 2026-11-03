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

extension _StreamPlaceholderParser on _StreamPlaceholderDelivery {
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
      final isGenerating =
          descriptor.content == _StreamPlaceholderDelivery.kGeneratingText &&
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
    if (beforeFirstContent != null && !_firstContentPrepared) return false;
    if (descriptors.isNotEmpty) return true;
    if (hasBufferedContent) return true;
    if (beforeFirstContent != null && _firstContentPrepared && _receivedDelta) {
      return true;
    }
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
    if (!enableTtsPlaceholders || rawText.isEmpty) return 0;
    var total = 0;
    for (final segment in firstPartyContentTagScanner.scan(rawText)) {
      if (segment is ContentTagElement &&
          segment.spec.display == ContentTagDisplay.tts &&
          segment.closed &&
          segment.inner.trim().isNotEmpty) {
        total += 1;
      }
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
    var result = StickerTag.removeFrom(
      firstPartyContentTagScanner,
      _stripHiddenImageTagsForDisplay(value),
    );
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
    return result.replaceFirst(_partialTagTail, '');
  }

  /// A tag still being streamed at the very end (`<`, `</`, `<tts voice=`).
  /// Only an ASCII name start counts, so kaomoji like `(ง>◡<ง)` and `<3` stay.
  static final RegExp _partialTagTail = RegExp(r'<(?:/?[A-Za-z][^<>]*|/)?$');

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
    DateTime? previousCreatedAt;
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
      if (previousMessage == null && pendingAudioKey != null) {
        final stable = _stablePendingAudioMessages[pendingAudioKey];
        if (stable != null && !usedPreviousIds.contains(stable.id)) {
          previousMessage = stable;
        }
      }
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
      var materialized = previousMessage == null
          ? _createMessage(descriptor)
          : _rebuildMessage(
              previousMessage,
              descriptor,
              createdAt: placeholderCreatedAtOverride,
            );
      // The timeline is sorted by createdAt when persisted/reloaded. Keep
      // descriptor order even when final text inserts segments before speech.
      if (previousCreatedAt != null &&
          !materialized.createdAt.isAfter(previousCreatedAt)) {
        materialized = materialized.copyWith(createdAt: _allocateCreatedAt());
      }
      previousCreatedAt = materialized.createdAt;
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
    // A speech placeholder keeps its identity after falling back to text.
    // Ordinary text inserted during finalization must not steal that ID.
    if (descriptor.kind == _StreamDescriptorKind.text &&
        _scheduledAudioMessageIds.contains(message.id)) {
      return false;
    }
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
        block.content.trim() ==
            _StreamPlaceholderDelivery.kGeneratingText;
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
    if (text == _StreamPlaceholderDelivery.kGeneratingText &&
        textBlock.status == BlockStatus.streaming) {
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
