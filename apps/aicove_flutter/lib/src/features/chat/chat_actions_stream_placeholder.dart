part of 'chat_actions.dart';

class _StreamCommitResult {
  const _StreamCommitResult({required this.messages});

  final List<Message> messages;

  List<String> get textMessageIds => <String>[
        for (final message in messages)
          if (_isTextTimelineMessage(message)) message.id,
      ];

  List<Message> get pendingTtsMessages => <Message>[
        for (final message in messages)
          if (_isPendingTtsPlaceholderMessage(message)) message,
      ];
}

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

  factory _StreamDescriptor.pendingAudio(String text) {
    return _StreamDescriptor._(
      kind: _StreamDescriptorKind.pendingAudio,
      content: text,
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

bool _isTextTimelineMessage(Message message) {
  final blocks = message.blocks;
  return blocks != null && blocks.length == 1 && blocks.first is TextBlock;
}

bool _isPendingTtsPlaceholderMessage(Message message) {
  final blocks = message.blocks;
  if (blocks == null || blocks.length != 1) return false;
  final block = blocks.first;
  return block is AudioBlock &&
      (block.url.isEmpty || block.status == BlockStatus.pending);
}

final RegExp _streamHiddenImageTagRegex = RegExp(
  r'<image\b[^>]*>[\s\S]*?</image>',
  caseSensitive: false,
);

String _stripHiddenImageTagsForDisplay(String value) {
  if (value.isEmpty) return value;
  var result = value.replaceAll(_streamHiddenImageTagRegex, '');
  final lower = result.toLowerCase();
  final openIndex = lower.lastIndexOf('<image');
  if (openIndex >= 0 && lower.indexOf('</image>', openIndex) < 0) {
    result = result.substring(0, openIndex);
  }
  return result;
}

class _StreamPlaceholderDelivery {
  _StreamPlaceholderDelivery(
    this._ref, {
    required this.convId,
    required this.userMsgId,
    required this.formatConfig,
    required this.enableTtsPlaceholders,
    this.segmentDelay = Duration.zero,
  });

  static const String kGeneratingText = '生成中...';
  static const Duration _kFlushInterval = Duration(milliseconds: 180);
  static const Duration _kThinkingPlaceholderDelay =
      Duration(milliseconds: 500);

  final Ref _ref;
  final String convId;
  final String userMsgId;
  final MessageFormatConfig formatConfig;
  final bool enableTtsPlaceholders;
  final Duration segmentDelay;

  final StringBuffer _rawStreamText = StringBuffer();
  final List<Message> _currentTimelineMessages = <Message>[];

  int? _timelineBaseMs;
  int _timelineTick = 0;
  Future<void> _queue = Future<void>.value();
  Timer? _flushTimer;
  Timer? _thinkingPlaceholderTimer;
  bool _dirty = false;
  bool _disposed = false;
  bool _receivedDelta = false;
  bool _fallbackTriggered = false;
  bool _thinkingPlaceholderElapsed = false;
  String? _finalizedRawText;

  Future<void> start() async {
    if (_disposed) return;
    _restartThinkingPlaceholderTimer();
  }

  void onDelta(String delta) {
    if (_disposed || delta.isEmpty) return;
    _rawStreamText.write(delta);
    _receivedDelta = true;
    _dirty = true;
    _scheduleFlush();
  }

  void onStreamReset() {
    if (_disposed) return;
    final discardedMessages =
        List<Message>.from(_currentTimelineMessages, growable: false);
    _fallbackTriggered = false;
    _receivedDelta = false;
    _finalizedRawText = null;
    _thinkingPlaceholderElapsed = false;
    _rawStreamText.clear();
    _currentTimelineMessages.clear();
    _timelineBaseMs = null;
    _timelineTick = 0;
    _dirty = true;
    _restartThinkingPlaceholderTimer();
    unawaited(_discardTimelineMessages(discardedMessages));
    _scheduleFlush(forceNow: true);
  }

  void onToolCallObserved() {}

  void onStreamingFallback() {
    if (_disposed || _receivedDelta) return;
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
    _finalizedRawText = _resolveEffectiveFinalText(finalText);
    _fallbackTriggered = false;
    _cancelThinkingPlaceholderTimer();
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirty = false;
    await _applyState(finalize: true);
  }

  Future<_StreamCommitResult> commitFinalTimeline({
    required String finalText,
  }) async {
    if (_disposed) {
      return const _StreamCommitResult(messages: <Message>[]);
    }
    _finalizedRawText = _resolveEffectiveFinalText(finalText);
    if (_currentTimelineMessages.isEmpty) {
      await _applyState(finalize: true);
    }
    final committedMessages =
        List<Message>.from(_currentTimelineMessages, growable: false);
    if (committedMessages.isEmpty) {
      await removePlaceholders();
      return const _StreamCommitResult(messages: <Message>[]);
    }
    return _StreamCommitResult(messages: committedMessages);
  }

  String _resolveEffectiveFinalText(String finalText) {
    final candidate = finalText.trim();
    if (candidate.isNotEmpty) return finalText;
    final streamed = _rawStreamText.toString();
    if (streamed.trim().isNotEmpty) return streamed;
    return finalText;
  }

  Future<void> removePlaceholders() async {
    _cancelThinkingPlaceholderTimer();
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirty = false;
    final discardedMessages =
        List<Message>.from(_currentTimelineMessages, growable: false);
    _currentTimelineMessages.clear();
    _rawStreamText.clear();
    _finalizedRawText = null;
    _receivedDelta = false;
    _fallbackTriggered = false;
    _timelineBaseMs = null;
    _timelineTick = 0;
    await _discardTimelineMessages(discardedMessages);
  }

  void dispose() {
    _disposed = true;
    _cancelThinkingPlaceholderTimer();
    _flushTimer?.cancel();
    _flushTimer = null;
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
      _flushNow();
      return;
    }
    _flushTimer ??= Timer(_kFlushInterval, _flushNow);
  }

  void _flushNow() {
    if (_disposed) return;
    _flushTimer = null;
    if (!_dirty) return;
    _dirty = false;
    unawaited(_applyState(finalize: false));
  }

  Future<void> _applyState({required bool finalize}) async {
    if (_disposed) return;
    final previousMessages =
        List<Message>.from(_currentTimelineMessages, growable: false);
    final sourceRaw = finalize
        ? (_finalizedRawText ?? _rawStreamText.toString())
        : _rawStreamText.toString();
    final messages = _materializeTimeline(
      _buildTimelineDescriptors(sourceRaw, finalize: finalize),
    );
    _currentTimelineMessages
      ..clear()
      ..addAll(messages);
    await _syncTimelineMessages(
      previousMessages: previousMessages,
      nextMessages: messages,
      finalize: finalize,
    );
  }

  List<_StreamDescriptor> _buildTimelineDescriptors(
    String rawText, {
    required bool finalize,
  }) {
    final segments = _extractRawSegments(rawText);
    final descriptors = <_StreamDescriptor>[];
    _StreamDescriptor? activeText;
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      final hasFollowingBoundary = index < segments.length - 1;
      if (segment.kind == _RawStreamSegmentKind.tts && enableTtsPlaceholders) {
        final ttsText = segment.content.trim();
        if (ttsText.isNotEmpty) {
          descriptors.add(_StreamDescriptor.pendingAudio(ttsText));
        }
        continue;
      }
      final described = _describeTextSegment(
        segment.content,
        forceSealTail: finalize || hasFollowingBoundary,
      );
      descriptors.addAll(described.sealed);
      if (!finalize && !formatConfig.enableChunking && !hasFollowingBoundary) {
        activeText = described.active;
      }
    }
    if (finalize) {
      return descriptors;
    }
    if (activeText != null) {
      descriptors.add(activeText);
      return descriptors;
    }
    if (_shouldShowGeneratingPlaceholder(descriptors)) {
      descriptors.add(_StreamDescriptor.generating());
    }
    return descriptors;
  }

  bool _shouldShowGeneratingPlaceholder(List<_StreamDescriptor> descriptors) {
    if (descriptors.isNotEmpty) return true;
    return _thinkingPlaceholderElapsed || _fallbackTriggered;
  }

  List<_RawStreamSegment> _extractRawSegments(String rawText) {
    if (rawText.isEmpty) return const <_RawStreamSegment>[];
    final segments = <_RawStreamSegment>[];
    final lowerRaw = rawText.toLowerCase();
    var cursor = 0;
    parseLoop:
    while (cursor < rawText.length) {
      final ttsOpenIndex = lowerRaw.indexOf('<tts>', cursor);
      final imageOpenIndex = lowerRaw.indexOf('<image', cursor);
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
    final messages = <Message>[];
    for (var index = 0; index < descriptors.length; index++) {
      final descriptor = descriptors[index];
      final previousMessage = index < previous.length &&
              _matchesDescriptor(previous[index], descriptor)
          ? previous[index]
          : null;
      messages.add(
        previousMessage == null
            ? _createMessage(descriptor)
            : _rebuildMessage(previousMessage, descriptor),
      );
    }
    return messages;
  }

  bool _matchesDescriptor(Message message, _StreamDescriptor descriptor) {
    final blocks = message.blocks;
    if (blocks == null || blocks.length != 1) return false;
    return switch (descriptor.kind) {
      _StreamDescriptorKind.text => blocks.first is TextBlock,
      _StreamDescriptorKind.pendingAudio => blocks.first is AudioBlock,
    };
  }

  Message _createMessage(_StreamDescriptor descriptor) {
    final messageId = genId('msg');
    return switch (descriptor.kind) {
      _StreamDescriptorKind.text => Message.fromBlocks(
          id: messageId,
          role: 'assistant',
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

  Message _rebuildMessage(Message baseMessage, _StreamDescriptor descriptor) {
    return switch (descriptor.kind) {
      _StreamDescriptorKind.text => Message.fromBlocks(
          id: baseMessage.id,
          role: baseMessage.role,
          blocks: [
            TextBlock(
              messageId: baseMessage.id,
              content: descriptor.content,
              status: descriptor.textStatus ?? BlockStatus.success,
            ),
          ],
          createdAt: baseMessage.createdAt,
          status: descriptor.messageStatus,
        ),
      _StreamDescriptorKind.pendingAudio => Message.fromBlocks(
          id: baseMessage.id,
          role: baseMessage.role,
          blocks: [
            AudioBlock(
              messageId: baseMessage.id,
              url: '',
              text: descriptor.content,
              status: BlockStatus.pending,
            ),
          ],
          createdAt: baseMessage.createdAt,
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

  Future<void> _enqueue(Future<void> Function() task) {
    _queue = _queue.catchError((_) {}).then((_) async {
      if (_disposed) return;
      await task();
    });
    return _queue;
  }

  Future<void> _syncTimelineMessages({
    required List<Message> previousMessages,
    required List<Message> nextMessages,
    required bool finalize,
  }) {
    return _enqueue(() async {
      final historyPort = _ref.read(chatHistoryPortProvider);
      final nextIds = nextMessages.map((message) => message.id).toSet();
      final removedIds = <String>[
        for (final message in previousMessages)
          if (!nextIds.contains(message.id)) message.id,
      ];
      if (removedIds.isNotEmpty) {
        await historyPort.softDeleteMessages(convId, removedIds);
      }
      if (nextMessages.isEmpty) return;
      await historyPort.appendAssistantMessages(
        conversationId: convId,
        userMessageId: finalize ? userMsgId.trim() : '',
        messages: nextMessages,
        lastMessagePreview: nextMessages.last.displayText,
      );
    });
  }

  Future<void> _discardTimelineMessages(List<Message> messages) {
    final removedIds = <String>[
      for (final message in messages)
        if (message.id.trim().isNotEmpty) message.id,
    ];
    if (removedIds.isEmpty) return Future<void>.value();
    return _enqueue(() async {
      await _ref.read(chatHistoryPortProvider).softDeleteMessages(
            convId,
            removedIds,
          );
    });
  }
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
