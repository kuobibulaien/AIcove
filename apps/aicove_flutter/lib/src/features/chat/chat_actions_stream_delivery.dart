part of 'chat_actions.dart';

extension ChatActionsStreamDelivery on ChatActions {
  /// 流式分段配置取会话显示策略（ADR0047）：文档模式强制不分段。
  MessageFormatConfig _streamFormatConfig(String convId, AppSettings settings) {
    final conversation = _ref.read(conversationSnapshotByIdProvider(convId));
    return ChatDisplayPolicy.resolve(
      formatConfig: settings.messageFormatConfig,
      globalStyle: settings.chatDisplayStyle,
      conversationStyle: conversation?.effectiveDisplayStyle,
      chunkOverride: conversation?.chunkOverride ?? ChatChunkOverride.none,
    ).effectiveFormatConfig;
  }

  /// 流式分段用的标签呈现映射（ADR0047），与聊天列表同源（聊天页已在监听，
  /// 通常已有缓存）。生成不能被它卡住：未就绪时最多等 1 秒，失败或超时退回内置常用名。
  Future<TagPresentationMap> _streamTagPresentation(String convId) async {
    final recipeId =
        _ref.read(conversationSnapshotByIdProvider(convId))?.recipeId;
    final provider = tagPresentationForRecipeProvider(recipeId);
    final cached = _ref.read(provider).valueOrNull;
    if (cached != null) return cached;
    try {
      return await _ref
          .read(provider.future)
          .timeout(const Duration(seconds: 1));
    } catch (_) {
      return builtinPresetTagMapping.presentationMap;
    }
  }

  Future<void> _restoreFrontendMessagesFromHistory(String convId) async {
    final timelineCache = _ref.read(conversationTimelineCacheProvider);
    final currentMessages = await timelineCache.loadCachedMessages(convId);
    final persistedMessages = await _ref
        .read(chatHistoryStoreProvider)
        .loadProjectedMessagesFromRawStore(convId);
    await timelineCache.replaceMessages(
      conversationId: convId,
      removeMessageIds: [
        for (final message in currentMessages) message.id,
      ],
      messages: persistedMessages,
    );
  }

  Future<void> _cleanupProjectedMessagesForRawSource({
    required String convId,
    required String rawMessageId,
    required List<Message> keepMessages,
  }) async {
    final keepIds = {
      for (final message in keepMessages)
        if (message.id.trim().isNotEmpty) message.id.trim(),
    };
    final allMessages = await _ref
        .read(conversationTimelineCacheProvider)
        .loadCachedMessages(convId);
    final removeIds = <String>[
      for (final message in allMessages)
        if (message.sourceMessageId == rawMessageId &&
            !keepIds.contains(message.id))
          message.id,
    ];
    if (removeIds.isEmpty) {
      return;
    }
    await _ref.read(conversationTimelineCacheProvider).replaceMessages(
          conversationId: convId,
          removeMessageIds: removeIds,
        );
  }

  static bool _hasOnlyTextOrToolBlocks(Message message) =>
      message.blocks?.every(
        (block) =>
            block is ToolBlock ||
            block is ThinkingBlock ||
            block.runtimeType == TextBlock,
      ) ??
      true;

  static bool _isToolOnlyMessage(Message message) {
    final blocks = message.blocks;
    return blocks != null &&
        blocks.isNotEmpty &&
        blocks.every((block) => block is ToolBlock);
  }

  List<Message> _extractStreamCommittedMessages(
    List<Message> messages, {
    bool keepToolOnly = false,
  }) {
    final committed = <Message>[];
    for (final message in messages) {
      final committedMessage = keepToolOnly && _isToolOnlyMessage(message)
          ? message
          : _toStreamCommittedMessage(message);
      if (committedMessage != null) {
        committed.add(committedMessage);
      }
    }
    return committed;
  }

  Message? _toStreamCommittedMessage(Message message) {
    final blocks = message.blocks;
    if (blocks == null || blocks.isEmpty) {
      return message.content.trim().isEmpty ? null : message;
    }

    final retainedBlocks = <MessageBlock>[
      for (final block in blocks)
        if (block is TextBlock || block is ToolBlock) block,
    ];
    final textBlocks = retainedBlocks.whereType<TextBlock>().toList();
    final hasTextBlock =
        textBlocks.any((block) => block.content.trim().isNotEmpty);
    final contentText = message.content.trim();
    if (!hasTextBlock && contentText.isEmpty) {
      return null;
    }

    if (!hasTextBlock && contentText.isNotEmpty) {
      retainedBlocks.insert(
        0,
        TextBlock(
          messageId: message.id,
          content: message.content,
          status: BlockStatus.success,
        ),
      );
    }

    return message.copyWith(
      content: '',
      blocks: retainedBlocks,
      status: 'sent',
    );
  }

  List<String> _extractProjectedTextMessageIds(
    List<Message> messages, {
    Set<String> excludedMessageIds = const <String>{},
  }) {
    return <String>[
      for (final message in messages)
        if (!excludedMessageIds.contains(message.id) &&
            !_isPendingAudioPlaceholderMessage(message) &&
            _messageContainsVisibleText(message))
          message.id,
    ];
  }

  bool _messageContainsVisibleText(Message message) {
    final blocks = message.blocks;
    if (blocks != null && blocks.isNotEmpty) {
      return blocks.whereType<TextBlock>().any(
            (block) => block.content.trim().isNotEmpty,
          );
    }
    return message.content.trim().isNotEmpty;
  }

  bool _isPendingAudioPlaceholderMessage(Message message) {
    final blocks = message.blocks;
    if (blocks == null || blocks.length != 1) return false;
    final block = blocks.first;
    return block is AudioBlock &&
        (block.url.isEmpty || block.status == BlockStatus.pending) &&
        (block.text?.trim().isNotEmpty ?? false);
  }

  Future<void> _savePartialStream({
    required _StreamPlaceholderDelivery? delivery,
    required String convId,
    required String userMsgId,
    required ApiRunStatus status,
    required FutureOr<AppSettings> settings,
    _GenerationTask? task,
  }) async {
    final streamStart = delivery?.timelineStart;
    final text = delivery?.takePartialText() ?? '';
    await delivery?.removePlaceholders();
    // A committed formal raw already owns both text and tools. The delivery
    // callback can still be awaiting its cache/projection update when stopped.
    if (task != null && await _formalRawStored(task)) {
      await _restoreFrontendMessagesFromHistory(convId);
      return;
    }
    if (text.trim().isEmpty) return;
    final built = _sendPort.buildAssistantMessages(
      apiResult: ApiCallResult(
        status: status,
        replyText: text,
        processedText: text,
        pluginEvents: const [],
        toolResults: const [],
      ),
      settings: await settings,
    );
    var rawMessage = built.rawMessage;
    if (rawMessage == null) return;
    if (streamStart != null && streamStart.isBefore(rawMessage.createdAt)) {
      rawMessage = rawMessage.copyWith(createdAt: streamStart);
    }
    await _historyPort.appendAssistantRawMessage(
      conversationId: convId,
      userMessageId: userMsgId,
      rawMessage: rawMessage,
      projectedMessages: _ref
          .read(chatFrontendMessageProjectionServiceProvider)
          .projectMessage(rawMessage),
      lastMessagePreview: built.lastMessageText,
    );
  }

  Future<void> _commitStreamDelivery({
    required _StreamPlaceholderDelivery streamDelivery,
    required int runId,
    required String convId,
    required String userMsgId,
    required AssistantMessageBuildResult buildResult,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool ttsEnabled,
    TraceLogger? trace,
  }) async {
    if (!_isGenerationCurrent(convId, runId)) return;
    var rawMessage = buildResult.rawMessage;
    if (rawMessage == null) {
      throw StateError('流式收尾缺少原始 assistant 消息');
    }
    // 没有媒体要后补时，收尾直接换成 Raw 的纯投影：与重启重算逐字节一致，
    // 文字不在数据层预切，分段交给列表层。Raw 沿用第一个流式气泡的时间，
    // 位置不变也不重播入场动画。语音／图片等仍要锚定流式分段，走下方旧路径。
    final projectionCommit =
        ChatMessageProjectionCodec.hasProjectionSemantics(
          rawMessage.rawPayload,
        ) &&
        !streamDelivery.hasAudioPlaceholders &&
        !pluginEvents.any(
          (e) => e.type == 'tts_convert' || e.type == 'image_generate',
        ) &&
        buildResult.messages.every(_hasOnlyTextOrToolBlocks);
    final streamStart = streamDelivery.timelineStart;
    if (projectionCommit &&
        streamStart != null &&
        streamStart.isBefore(rawMessage.createdAt)) {
      rawMessage = rawMessage.copyWith(createdAt: streamStart);
      buildResult = AssistantMessageBuildResult(
        rawMessage: rawMessage,
        messages: buildResult.messages,
        lastMessageText: buildResult.lastMessageText,
      );
    }
    // 调过工具的多轮回复：流式气泡把各轮话术连成一段，工具只能补在两头。
    // 收尾改用按轮构建的消息，话术和工具按实际先后排，工具不再走后补。
    final useToolRounds = !streamDelivery.hasAudioPlaceholders &&
        buildResult.messages.any(_isToolOnlyMessage);
    streamDelivery.beginTtsCommit();
    final List<Message> finalTimelineMessages;
    if (projectionCommit) {
      finalTimelineMessages = _ref
          .read(chatFrontendMessageProjectionServiceProvider)
          .projectMessage(rawMessage);
    } else {
      final committedMessages = _extractStreamCommittedMessages(
        buildResult.messages,
        keepToolOnly: useToolRounds,
      );
      finalTimelineMessages = ChatMessageProjectionCodec.applyRunStatus(
        useToolRounds
            ? [
                for (final message in committedMessages)
                  message.copyWith(sourceMessageId: rawMessage.id),
              ]
            : streamDelivery.buildFinalTimelineMessages(
                committedMessages: committedMessages,
                sourceMessageId: rawMessage.id,
              ),
        rawMessage.rawPayload,
      );
    }
    if (finalTimelineMessages.isEmpty) {
      throw StateError('流式收尾缺少可提交的前端时间线消息');
    }
    final pendingStreamTtsMessages = streamDelivery.ttsTimelineMessages(
      sourceMessageId: rawMessage.id,
    );
    final projectedTextMessageIds = _extractProjectedTextMessageIds(
      finalTimelineMessages,
      excludedMessageIds: {
        for (final message in pendingStreamTtsMessages) message.id,
      },
    );
    final finalMessagePreview = stripDialogueOptions(
      stripMvuUpdateBlocks(
        buildResult.lastMessageText.trim().isNotEmpty
            ? buildResult.lastMessageText
            : finalTimelineMessages.last.displayText,
      ),
    );
    await _historyPort.appendAssistantRawMessage(
      conversationId: convId,
      userMessageId: userMsgId,
      rawMessage: rawMessage,
      projectedMessages: finalTimelineMessages,
      lastMessagePreview: finalMessagePreview,
      updateShortWindow: false,
      shouldCommit: () => _isGenerationCurrent(convId, runId),
    );
    if (!_isGenerationCurrent(convId, runId)) return;
    await streamDelivery.commitToMessages(finalMessages: finalTimelineMessages);
    if (!_isGenerationCurrent(convId, runId)) return;
    await _cleanupProjectedMessagesForRawSource(
      convId: convId,
      rawMessageId: rawMessage.id,
      keepMessages: finalTimelineMessages,
    );
    if (!_isGenerationCurrent(convId, runId)) return;
    await _ref.read(chatHistoryStoreProvider).syncRawSupplementsFromTimeline(
      conversationId: convId,
      rawMessageIds: {rawMessage.id},
    );
    // 纯投影已是完整结果；旧后补会把同一气泡里的正文剥掉只留思考。
    if (projectionCommit || !_isGenerationCurrent(convId, runId)) return;
    await _ttsHandler.deliverSegmentedMessages(
      convId: convId,
      userMsgId: userMsgId,
      buildResult: useToolRounds
          ? AssistantMessageBuildResult(
              rawMessage: rawMessage,
              messages: [
                for (final message in buildResult.messages)
                  message.copyWith(
                    blocks: <MessageBlock>[
                      for (final block
                          in message.blocks ?? const <MessageBlock>[])
                        if (block is! ToolBlock) block,
                    ],
                  ),
              ],
              lastMessageText: buildResult.lastMessageText,
            )
          : buildResult,
      replyText: replyText,
      pluginEvents: pluginEvents,
      ttsEnabled: ttsEnabled,
      shouldCommit: () => _isGenerationCurrent(convId, runId),
      appendAfterStreamText: true,
      streamTextMessageIds: projectedTextMessageIds,
      streamPendingTtsMessages: pendingStreamTtsMessages,
      streamTtsResolutionManaged: streamDelivery.hasAudioPlaceholders,
      trace: trace,
    );
  }

  void _scheduleStreamPendingTtsResolution({
    required String convId,
    required Message pendingMessage,
    required _StreamPlaceholderDelivery streamDelivery,
  }) {
    unawaited(() async {
      try {
        Future<void> resolve() => _ttsHandler.resolvePendingStreamMessage(
              convId: convId,
              message: pendingMessage,
              persistResult: false,
              shouldApplyResult: () =>
                  streamDelivery.canAcceptTtsResolution(pendingMessage.id),
              onAudioResolved: (audioUrl, durationSeconds) {
                streamDelivery.updateResolvedAudio(
                  messageId: pendingMessage.id,
                  audioUrl: audioUrl,
                  durationSeconds: durationSeconds,
                );
              },
              onTextFallback: (text) {
                streamDelivery.updateFallbackText(
                  messageId: pendingMessage.id,
                  text: text,
                );
              },
            );
        final request = streamDelivery.voiceRequest;
        if (request == null) {
          await resolve();
        } else {
          await request.run(resolve);
        }
      } catch (e) {
        AppLogger.error(
          'ChatActions',
          '流式 TTS 并发解析失败',
          metadata: {
            'convId': convId,
            'messageId': pendingMessage.id,
            'error': e.toString(),
          },
        );
      }
    }());
  }

  /// Shared placeholder policy; callers retain their original preparation time.
  Future<_StreamPlaceholderDelivery> _createStreamDelivery({
    required String convId,
    required int runId,
    required AppSettings settings,
    TraceContext? traceContext,
    Future<void> Function()? beforeFirstContent,
  }) async {
    late final _StreamPlaceholderDelivery delivery;
    delivery = _StreamPlaceholderDelivery(
      _ref,
      convId: convId,
      generationSeq: runId,
      diagnosticContext: _diagnostics.forTurn(traceContext?.turnId),
      formatConfig: _streamFormatConfig(convId, settings),
      tagPresentation: await _streamTagPresentation(convId),
      enableTtsPlaceholders: settings.ttsEnabled,
      segmentDelay: Duration(
        milliseconds: (settings.streamSegmentDelaySeconds * 1000).round(),
      ),
      beforeFirstContent: beforeFirstContent,
      onPendingAudioAppeared: (pendingMessage) {
        if (!_isGenerationCurrent(convId, runId)) return;
        _scheduleStreamPendingTtsResolution(
          convId: convId,
          pendingMessage: pendingMessage,
          streamDelivery: delivery,
        );
      },
    );
    return delivery;
  }

  /// One streaming handoff for send, retry and regeneration.
  Future<ChatSendTurnResult?> _executeStreamingTurn({
    required ChatTurnCommand command,
    required Future<AppSettings> Function() loadSettings,
    List<String> Function(AppSettings settings)? resolveModelsToTry,
    Future<ChatPreparedTurn> Function(AppSettings settings)? prepareTurn,
    required ChatFailoverExecutor executeWithFailover,
    required String convId,
    required int runId,
    required String userMsgId,
    required _StreamPlaceholderDelivery? Function() streamDelivery,
    required void Function() onStreamCommitted,
    Future<void> Function()? beforeDelivery,
  }) {
    bool isCurrent() => _isGenerationCurrent(convId, runId);
    return _executeTurnCommand(
      command: command,
      loadSettings: loadSettings,
      resolveModelsToTry: resolveModelsToTry,
      prepareTurn: prepareTurn,
      executeWithFailover: executeWithFailover,
      onToolExecuting: (toolName) => _updateStatusForTool(convId, toolName),
      deliverResult: ({
        required settings,
        required apiResult,
        required buildResult,
      }) async {
        if (beforeDelivery != null) {
          await beforeDelivery();
          if (!isCurrent()) return;
        }
        final delivery = streamDelivery()!;
        final finalText = _resolveFinalStreamText(apiResult, buildResult);
        if (delivery.canFinalizeWith(finalText: finalText)) {
          await delivery.finalize(finalText: finalText);
          if (!isCurrent()) return;
          await _commitStreamDelivery(
            streamDelivery: delivery,
            runId: runId,
            convId: convId,
            userMsgId: userMsgId,
            buildResult: buildResult,
            replyText: apiResult.rawReplyText,
            pluginEvents: apiResult.pluginEvents,
            ttsEnabled: settings.ttsEnabled,
            trace: command.trace,
          );
          onStreamCommitted();
          return;
        }
        await delivery.removePlaceholders();
        if (!isCurrent()) return;
        await _ttsHandler.deliverSegmentedMessages(
          convId: convId,
          userMsgId: userMsgId,
          buildResult: buildResult,
          replyText: apiResult.rawReplyText,
          pluginEvents: apiResult.pluginEvents,
          ttsEnabled: settings.ttsEnabled,
          shouldCommit: isCurrent,
          trace: command.trace,
        );
      },
      isCurrent: isCurrent,
      onStreamTextDelta: (delta) {
        if (!isCurrent()) return;
        if (delta.isNotEmpty) _setConversationRetryStatus(convId, null);
        streamDelivery()?.onDelta(delta);
      },
      onStreamTextReset: () {
        if (!isCurrent()) return;
        streamDelivery()?.onStreamReset();
      },
      onStreamToolCallObserved: () {
        if (!isCurrent()) return;
        streamDelivery()?.onToolCallObserved();
      },
      onStreamingFallback: () {
        if (!isCurrent()) return;
        streamDelivery()?.onStreamingFallback();
      },
    );
  }
}
