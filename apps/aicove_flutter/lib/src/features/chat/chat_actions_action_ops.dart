part of 'chat_actions.dart';

class ProactiveSendResult {
  final bool success;
  final bool retryable;
  final String reason;

  const ProactiveSendResult._({
    required this.success,
    required this.retryable,
    required this.reason,
  });

  const ProactiveSendResult.success()
      : this._(success: true, retryable: false, reason: 'sent');

  const ProactiveSendResult.skipped(String reason)
      : this._(success: false, retryable: false, reason: reason);

  const ProactiveSendResult.failed(String reason, {bool retryable = true})
      : this._(success: false, retryable: retryable, reason: reason);
}

extension ChatActionsActionOps on ChatActions {
  Future<ProactiveSendResult> sendProactiveTrigger(
      AutoReplyTrigger trigger) async {
    // 确定目标会话：优先使用触发器绑定的会话，否则使用当前活跃会话
    final targetConvId = trigger.conversationId.isNotEmpty
        ? trigger.conversationId
        : _ref.read(activeConversationIdProvider);

    if (targetConvId == null || targetConvId.isEmpty) {
      AppLogger.warning('ChatActions', '触发器发送失败：无目标会话',
          metadata: {'triggerId': trigger.id});
      return const ProactiveSendResult.skipped('target_conversation_missing');
    }

    // 获取目标会话
    final conversations = _ref.read(conversationsProvider).valueOrNull ?? [];
    final conv = conversations.where((c) => c.id == targetConvId).firstOrNull;
    if (conv == null) {
      AppLogger.warning('ChatActions', '触发器发送失败：会话不存在',
          metadata: {'convId': targetConvId});
      return const ProactiveSendResult.skipped('target_conversation_not_found');
    }

    final traceContext = await _startTurnTrace(
      convId: targetConvId,
      turnId: 'trigger_${trigger.id}',
      entry: 'proactive_trigger',
      meta: {'triggerId': trigger.id},
    );

    try {
      return await _runWithProviderRefreshRetry<ProactiveSendResult>(
        entry: 'proactive_trigger',
        convId: targetConvId,
        task: () async {
          final settings = await _ref.read(appSettingsProvider.future);
          if (!settings.autoReplySettings.enabled) {
            AppLogger.info(
                'ChatActions', 'Skip proactive trigger: auto-reply disabled',
                metadata: {
                  'triggerId': trigger.id,
                });
            return const ProactiveSendResult.skipped('auto_reply_disabled');
          }

          if (trigger.hasCachedContent) {
            final cachedReply = trigger.cachedContent!.trim();
            if (cachedReply.isNotEmpty) {
              final cachedResult = ApiCallResult(
                rawReplyText: cachedReply,
                replyText: cachedReply,
                processedText: cachedReply,
                pluginEvents: const [],
                toolResults: const [],
              );
              final buildResult = _sendPort.buildAssistantMessages(
                  apiResult: cachedResult, settings: settings);
              await _ttsHandler.deliverSegmentedMessages(
                convId: targetConvId,
                userMsgId: '',
                buildResult: buildResult,
                replyText: cachedReply,
                pluginEvents: const [],
                ttsEnabled: settings.ttsEnabled,
              );
              _recordTurnTrace(
                traceContext,
                TraceStage.messageDelivered,
                meta: {'assistantMessageCount': buildResult.messages.length},
              );
              _recordTurnTrace(traceContext, TraceStage.turnCompleted);
              AppLogger.info('ChatActions', '触发器发送成功（cached）', metadata: {
                'triggerId': trigger.id,
                'title': trigger.title,
              });
              return const ProactiveSendResult.success();
            }
          }

          final proactiveInput = (trigger.prompt?.trim().isNotEmpty ?? false)
              ? trigger.prompt!.trim()
              : trigger.title;
          final syntheticUserMessage = Message(
            id: 'trigger_${trigger.id}',
            role: 'user',
            content: proactiveInput,
            createdAt: DateTime.now(),
          );
          final turnResult = await _executeTurnCommand(
            command: ChatTurnCommand.nonStreaming(
              conversation: conv,
              userMessage: syntheticUserMessage,
              sessionId: targetConvId,
              apiText: proactiveInput,
              traceContext: traceContext,
            ),
            loadSettings: () async => settings,
            prepareTurn: (_) async {
              final snapshotHistory =
                  _buildSnapshotHistory(trigger.contextSnapshot);
              return ChatPreparedTurn(
                requestConversation: conv,
                history: snapshotHistory.isNotEmpty
                    ? snapshotHistory
                    : await _loadConversationMessages(targetConvId),
                sessionId: targetConvId,
              );
            },
            resolveModelsToTry: _resolvePreferredChatModels,
            executeWithFailover: ({
              required modelsToTry,
              required buildConfig,
              required execute,
              required settings,
            }) =>
                _executeWithFailover(
              convId: targetConvId,
              modelsToTry: modelsToTry,
              buildConfig: buildConfig,
              execute: execute,
              settings: settings,
            ),
            onToolExecuting: (toolName) =>
                _updateStatusForTool(targetConvId, toolName),
            deliverResult: ({
              required settings,
              required apiResult,
              required buildResult,
            }) =>
                _ttsHandler.deliverSegmentedMessages(
              convId: targetConvId,
              userMsgId: '',
              buildResult: buildResult,
              replyText: apiResult.rawReplyText,
              pluginEvents: apiResult.pluginEvents,
              ttsEnabled: settings.ttsEnabled,
            ),
            isCurrent: () => true,
          );
          if (turnResult == null) {
            return const ProactiveSendResult.skipped('proactive_cancelled');
          }

          _recordTurnTrace(
            traceContext,
            TraceStage.messageDelivered,
            meta: {
              'assistantMessageCount': turnResult.buildResult.messages.length,
            },
          );
          _recordTurnTrace(traceContext, TraceStage.turnCompleted);

          AppLogger.info('ChatActions', '触发器发送成功', metadata: {
            'triggerId': trigger.id,
            'title': trigger.title,
          });
          return const ProactiveSendResult.success();
        },
      );
    } catch (e) {
      _recordTurnTrace(
        traceContext,
        TraceStage.turnFailed,
        status: TraceEventStatus.failed,
        meta: {'error': e.toString(), 'triggerId': trigger.id},
      );
      AppLogger.error('ChatActions', '触发器发送失败', metadata: {
        'triggerId': trigger.id,
        'error': e.toString(),
      });
      return ProactiveSendResult.failed(e.toString());
    }
  }

  Future<void> retry(String messageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final convId = conv.id;
    final messages = await _loadConversationMessages(convId);

    final failedMsg = messages.firstWhere(
      (m) => m.id == messageId && m.status == 'failed',
      orElse: () => throw Exception('消息不存在或状态不正确'),
    );

    final runId = _startGeneration(convId: convId, userMsgId: messageId);
    final traceContext = await _startTurnTrace(
      convId: convId,
      turnId: messageId,
      entry: 'retry',
    );

    await _historyPort.markMessageStatus(
      conversationId: convId,
      messageId: messageId,
      status: 'sending',
    );
    if (!_isGenerationCurrent(convId, runId)) return;

    _StreamPlaceholderDelivery? streamDelivery;
    var streamCommitted = false;
    _setGenerationInterruptCleanup(convId, runId, () async {
      await streamDelivery?.removePlaceholders();
      streamDelivery?.dispose();
    });
    try {
      await _runWithProviderRefreshRetry<void>(
        entry: 'retry',
        convId: convId,
        beforeRetry: (_) async {
          if (!streamCommitted) {
            await streamDelivery?.removePlaceholders();
          }
          streamDelivery?.dispose();
          streamDelivery = null;
          streamCommitted = false;
        },
        task: () async {
          final turnResult = await _executeTurnCommand(
            command: ChatTurnCommand.streaming(
              conversation: conv,
              userMessage: failedMsg,
              sessionId: convId,
              apiText: failedMsg.displayText,
              traceContext: traceContext,
            ),
            loadSettings: () => _ref.read(appSettingsProvider.future),
            prepareTurn: (settings) async {
              final msgIndex = messages.indexWhere((m) => m.id == messageId);
              final rawHistory =
                  msgIndex > 0 ? messages.sublist(0, msgIndex + 1) : messages;
              final history = rawHistory
                  .where((m) => m.status != 'failed' || m.id == messageId)
                  .toList();
              return ChatPreparedTurn(
                requestConversation: conv,
                history: history,
                sessionId: convId,
                modelsToTry: _resolvePreferredChatModels(settings),
              );
            },
            executeWithFailover: ({
              required modelsToTry,
              required buildConfig,
              required execute,
              required settings,
            }) =>
                _executeWithFailover(
              convId: convId,
              modelsToTry: modelsToTry,
              buildConfig: buildConfig,
              execute: execute,
              settings: settings,
            ),
            prepareStreaming: (settings) async {
              streamDelivery = _StreamPlaceholderDelivery(
                _ref,
                convId: convId,
                formatConfig: settings.messageFormatConfig,
                enableTtsPlaceholders: settings.ttsEnabled,
                segmentDelay: Duration(
                  milliseconds:
                      (settings.streamSegmentDelaySeconds * 1000).round(),
                ),
              );
              await streamDelivery!.start();
            },
            onToolExecuting: (toolName) =>
                _updateStatusForTool(convId, toolName),
            onProcessingResponse: () =>
                _setConversationStatus(convId, ChatStatus.processingResponse),
            deliverResult: ({
              required settings,
              required apiResult,
              required buildResult,
            }) async {
              await _historyPort.markMessageStatus(
                conversationId: convId,
                messageId: messageId,
                status: 'sent',
              );
              if (!_isGenerationCurrent(convId, runId)) return;

              final streamFinalText =
                  _resolveFinalStreamText(apiResult, buildResult);
              final shouldCommitStream =
                  streamDelivery!.canFinalizeWith(finalText: streamFinalText);

              if (shouldCommitStream) {
                await streamDelivery!.finalize(finalText: streamFinalText);
                await _commitStreamDelivery(
                  streamDelivery: streamDelivery!,
                  convId: convId,
                  userMsgId: messageId,
                  buildResult: buildResult,
                  replyText: apiResult.rawReplyText,
                  pluginEvents: apiResult.pluginEvents,
                  ttsEnabled: settings.ttsEnabled,
                );
                streamCommitted = true;
                return;
              }

              await streamDelivery!.removePlaceholders();
              await _ttsHandler.deliverSegmentedMessages(
                convId: convId,
                userMsgId: messageId,
                buildResult: buildResult,
                replyText: apiResult.rawReplyText,
                pluginEvents: apiResult.pluginEvents,
                ttsEnabled: settings.ttsEnabled,
              );
            },
            isCurrent: () => _isGenerationCurrent(convId, runId),
            onStreamTextDelta: (delta) {
              if (!_isGenerationCurrent(convId, runId)) return;
              streamDelivery?.onDelta(delta);
            },
            onStreamTextReset: () {
              if (!_isGenerationCurrent(convId, runId)) return;
              streamDelivery?.onStreamReset();
            },
            onStreamToolCallObserved: () {
              if (!_isGenerationCurrent(convId, runId)) return;
              streamDelivery?.onToolCallObserved();
            },
            onStreamingFallback: () {
              if (!_isGenerationCurrent(convId, runId)) return;
              streamDelivery?.onStreamingFallback();
            },
          );
          if (turnResult == null) return;
          if (!_isGenerationCurrent(convId, runId)) return;
          _recordTurnTrace(
            traceContext,
            TraceStage.messageDelivered,
            meta: {
              'assistantMessageCount': turnResult.buildResult.messages.length,
              'streamCommitted': streamCommitted,
            },
          );
          _recordTurnTrace(traceContext, TraceStage.turnCompleted);
        },
      );
    } catch (e) {
      if (!_isGenerationCurrent(convId, runId)) return;
      _recordTurnTrace(
        traceContext,
        TraceStage.turnFailed,
        status: TraceEventStatus.failed,
        meta: {'error': e.toString()},
      );
      await _historyPort.markMessageStatus(
        conversationId: convId,
        messageId: messageId,
        status: 'failed',
      );
      _setConversationError(convId, e.toString());
    } finally {
      if (!streamCommitted) {
        await streamDelivery?.removePlaceholders();
      }
      streamDelivery?.dispose();
      _finishGeneration(convId, runId);
    }
  }

  /// 重新生成AI回复（删除指定AI消息及其后的所有消息，重新生成）
  Future<void> regenerate(String aiMessageId) async {
    await _regenerateInternal(aiMessageId, useEnhancement: false);
  }

  /// 预检普通文本重新生成是否可改走现有发送链。
  Future<String?> peekTextRegenerate(String aiMessageId) async {
    return _resolveTextRegenerate(
      aiMessageId,
      truncateFromUserMessage: false,
    );
  }

  /// 为普通文本重新生成准备重发文本，并从原用户消息开始截断当前轮次。
  Future<String?> prepareTextRegenerate(String aiMessageId) async {
    return _resolveTextRegenerate(
      aiMessageId,
      truncateFromUserMessage: true,
    );
  }

  /// 增强重新生成（使用增强上下文拼接）
  Future<void> regenerateWithEnhancement(String aiMessageId) async {
    await _regenerateInternal(aiMessageId, useEnhancement: true);
  }

  Future<String?> _resolveTextRegenerate(
    String aiMessageId, {
    required bool truncateFromUserMessage,
  }) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return null;
    final messages = await _loadConversationMessages(conv.id);
    final userMsg = _findRegenerateSourceUserMessage(messages, aiMessageId);
    if (userMsg == null || !_canReuseTextSendForRegenerate(userMsg)) {
      return null;
    }

    final userText = _extractEditableTextForRecall(userMsg);
    if (userText.isEmpty) return null;
    if (truncateFromUserMessage) {
      await _historyPort.truncateFromMessage(
        conversationId: conv.id,
        fromMessageId: userMsg.id,
      );
    }
    return userText;
  }

  Message? _findRegenerateSourceUserMessage(
    List<Message> messages,
    String aiMessageId,
  ) {
    final msgIndex = messages.indexWhere((m) => m.id == aiMessageId);
    if (msgIndex < 0) return null;

    int userMsgIndex = msgIndex - 1;
    while (userMsgIndex >= 0 && messages[userMsgIndex].role != 'user') {
      userMsgIndex--;
    }
    if (userMsgIndex < 0) return null;
    return messages[userMsgIndex];
  }

  bool _canReuseTextSendForRegenerate(Message userMsg) {
    if (userMsg.role != 'user') return false;
    final blocks = userMsg.blocks;
    if (blocks == null || blocks.isEmpty) {
      return _extractEditableTextForRecall(userMsg).isNotEmpty;
    }
    if (blocks.any((block) => block is! TextBlock)) {
      return false;
    }
    return _extractEditableTextForRecall(userMsg).isNotEmpty;
  }

  Future<void> _regenerateInternal(
    String aiMessageId, {
    required bool useEnhancement,
  }) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final convId = conv.id;
    final messages = await _loadConversationMessages(convId);

    final userMsg = _findRegenerateSourceUserMessage(messages, aiMessageId);
    if (userMsg == null) return;
    final userText = userMsg.displayText;
    final traceContext = await _startTurnTrace(
      convId: convId,
      turnId: userMsg.id,
      entry: useEnhancement ? 'regenerate_enhanced' : 'regenerate',
      meta: {'targetAiMessageId': aiMessageId},
    );

    final runId = _startGeneration(convId: convId, userMsgId: userMsg.id);

    // 收集被移除的消息 ID，用于数据库软删除
    await _historyPort.truncateAfterMessage(
      conversationId: convId,
      anchorMessageId: userMsg.id,
    );
    if (!_isGenerationCurrent(convId, runId)) return;

    _StreamPlaceholderDelivery? streamDelivery;
    var streamCommitted = false;
    _setGenerationInterruptCleanup(convId, runId, () async {
      await streamDelivery?.removePlaceholders();
      streamDelivery?.dispose();
    });
    try {
      await _runWithProviderRefreshRetry<void>(
        entry: useEnhancement ? 'regenerate_enhanced' : 'regenerate',
        convId: convId,
        beforeRetry: (_) async {
          if (!streamCommitted) {
            await streamDelivery?.removePlaceholders();
          }
          streamDelivery?.dispose();
          streamDelivery = null;
          streamCommitted = false;
        },
        task: () async {
          final turnResult = await _executeTurnCommand(
            command: ChatTurnCommand.streaming(
              conversation: conv,
              userMessage: userMsg,
              sessionId: convId,
              apiText: userText,
              traceContext: traceContext,
            ),
            loadSettings: () => _ref.read(appSettingsProvider.future),
            prepareTurn: (settings) async {
              final updatedConv = _ref.read(activeConversationProvider)!;
              final canUseEnhancement =
                  useEnhancement && settings.enhancedDialogueSettings.enabled;
              if (!canUseEnhancement) {
                return ChatPreparedTurn(
                  requestConversation: updatedConv,
                  history: await _sendPort.prepareHistoryFromStore(
                    conv: updatedConv,
                    userMsg: userMsg,
                    limit: settings.historyMessageLimit,
                  ),
                  sessionId: convId,
                  modelsToTry: _resolvePreferredChatModels(settings),
                );
              }

              final persistedMessages =
                  await _sendPort.loadConversationMessagesFromStore(
                conv: updatedConv,
                ensureTailMessage: userMsg,
              );
              final persistedConv =
                  updatedConv.copyWith(messages: persistedMessages);
              final enhancedContext = _enhancedDialogueService.buildContext(
                conversation: persistedConv,
                targetUserMessage: userMsg,
                enhancerSystemPrompt:
                    settings.enhancedDialogueSettings.systemPrompt,
                bootstrapUserMessage:
                    settings.enhancedDialogueSettings.bootstrapUserMessage,
                recentRounds: settings.enhancedDialogueSettings.recentRounds,
              );
              return ChatPreparedTurn(
                requestConversation: enhancedContext.conversation,
                history: enhancedContext.history,
                sessionId: enhancedContext.sessionId,
                modelsToTry: _resolvePreferredChatModels(settings),
                transformApiResult: (rawResult) {
                  final enhancedText =
                      _enhancedDialogueService.extractEnhancedText(
                    processedText: rawResult.processedText,
                    rawReplyText: rawResult.replyText,
                  );
                  return ApiCallResult(
                    rawReplyText: enhancedText,
                    replyText: enhancedText,
                    processedText: enhancedText,
                    pluginEvents: rawResult.pluginEvents,
                    pluginContents: rawResult.pluginContents,
                    toolResults: rawResult.toolResults,
                    toolAudioResults: rawResult.toolAudioResults,
                    toolCalls: rawResult.toolCalls,
                    rawToolResults: rawResult.rawToolResults,
                  );
                },
              );
            },
            executeWithFailover: ({
              required modelsToTry,
              required buildConfig,
              required execute,
              required settings,
            }) =>
                _executeWithFailover(
              convId: convId,
              modelsToTry: modelsToTry,
              buildConfig: buildConfig,
              execute: execute,
              settings: settings,
            ),
            prepareStreaming: (settings) async {
              streamDelivery = _StreamPlaceholderDelivery(
                _ref,
                convId: convId,
                formatConfig: settings.messageFormatConfig,
                enableTtsPlaceholders: settings.ttsEnabled,
                segmentDelay: Duration(
                  milliseconds:
                      (settings.streamSegmentDelaySeconds * 1000).round(),
                ),
              );
              await streamDelivery!.start();
            },
            onToolExecuting: (toolName) =>
                _updateStatusForTool(convId, toolName),
            onProcessingResponse: () =>
                _setConversationStatus(convId, ChatStatus.processingResponse),
            deliverResult: ({
              required settings,
              required apiResult,
              required buildResult,
            }) async {
              final streamFinalText =
                  _resolveFinalStreamText(apiResult, buildResult);
              final shouldCommitStream =
                  streamDelivery!.canFinalizeWith(finalText: streamFinalText);

              if (shouldCommitStream) {
                await streamDelivery!.finalize(finalText: streamFinalText);
                await _commitStreamDelivery(
                  streamDelivery: streamDelivery!,
                  convId: convId,
                  userMsgId: userMsg.id,
                  buildResult: buildResult,
                  replyText: apiResult.rawReplyText,
                  pluginEvents: apiResult.pluginEvents,
                  ttsEnabled: settings.ttsEnabled,
                );
                streamCommitted = true;
                return;
              }

              await streamDelivery!.removePlaceholders();
              await _ttsHandler.deliverSegmentedMessages(
                convId: convId,
                userMsgId: userMsg.id,
                buildResult: buildResult,
                replyText: apiResult.rawReplyText,
                pluginEvents: apiResult.pluginEvents,
                ttsEnabled: settings.ttsEnabled,
              );
            },
            isCurrent: () => _isGenerationCurrent(convId, runId),
            onStreamTextDelta: (delta) {
              if (!_isGenerationCurrent(convId, runId)) return;
              streamDelivery?.onDelta(delta);
            },
            onStreamTextReset: () {
              if (!_isGenerationCurrent(convId, runId)) return;
              streamDelivery?.onStreamReset();
            },
            onStreamToolCallObserved: () {
              if (!_isGenerationCurrent(convId, runId)) return;
              streamDelivery?.onToolCallObserved();
            },
            onStreamingFallback: () {
              if (!_isGenerationCurrent(convId, runId)) return;
              streamDelivery?.onStreamingFallback();
            },
          );
          if (turnResult == null) return;
          if (!_isGenerationCurrent(convId, runId)) return;
          _recordTurnTrace(
            traceContext,
            TraceStage.messageDelivered,
            meta: {
              'assistantMessageCount': turnResult.buildResult.messages.length,
              'streamCommitted': streamCommitted,
            },
          );
          _recordTurnTrace(traceContext, TraceStage.turnCompleted);
        },
      );
    } catch (e) {
      if (!_isGenerationCurrent(convId, runId)) return;
      _recordTurnTrace(
        traceContext,
        TraceStage.turnFailed,
        status: TraceEventStatus.failed,
        meta: {'error': e.toString()},
      );
      _setConversationError(convId, e.toString());
    } finally {
      if (!streamCommitted) {
        await streamDelivery?.removePlaceholders();
      }
      streamDelivery?.dispose();
      _finishGeneration(convId, runId, scheduleAnalysis: true);
    }
  }

  /// 撤回失败消息：将失败消息的文本回填到输入框，并从会话中删除该消息
  Future<void> recallFailedMessage(String messageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final editingNotifier = _ref.read(editingTextProvider.notifier);
    final attachmentNotifier = _ref.read(recalledAttachmentProvider.notifier);
    final messages = await _loadConversationMessages(conv.id);

    final idx = messages.indexWhere(
      (m) => m.id == messageId && m.status == 'failed',
    );
    if (idx < 0) return;
    final failedMsg = messages[idx];

    // 将失败消息文本填入输入框
    final text = _extractEditableTextForRecall(failedMsg);
    if (text.isNotEmpty) {
      editingNotifier.state = text;
    }
    attachmentNotifier.state = _extractAttachmentForRecall(failedMsg);

    await deleteMessage(messageId);
  }

  String _extractEditableTextForRecall(Message msg) {
    final blocks = msg.blocks;
    if (blocks != null && blocks.isNotEmpty) {
      final text = blocks
          .whereType<TextBlock>()
          .map((b) => b.content.trim())
          .where((v) => v.isNotEmpty)
          .join('\n\n')
          .trim();
      return text;
    }
    final raw = msg.content.trim();
    if (raw == '[图片]' ||
        raw == '[文件]' ||
        raw == '[语音]' ||
        raw == '[表情]' ||
        raw == '[工具调用]' ||
        raw == '[思考中...]') {
      return '';
    }
    return raw;
  }

  SelectedAttachment? _extractAttachmentForRecall(Message msg) {
    final blocks = msg.blocks;
    if (blocks == null || blocks.isEmpty) return null;

    for (final block in blocks) {
      if (block is ImageBlock) {
        final localPath = block.localPath?.trim();
        if (localPath != null && localPath.isNotEmpty) {
          return SelectedAttachment(
            path: localPath,
            type: AttachmentType.image,
          );
        }
      }
      if (block is FileBlock) {
        final filePath = block.filePath.trim();
        if (filePath.isNotEmpty) {
          return SelectedAttachment(
            path: filePath,
            name: block.fileName,
            sizeBytes: block.fileSize,
            type: AttachmentType.file,
          );
        }
      }
    }
    return null;
  }

  /// 删除单条消息（仅删除本地显示，同时在数据库做软删除）
  Future<void> deleteMessage(String messageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final convId = conv.id;
    final quoted = _ref.read(quotedMessageProvider);
    final quotedNotifier = _ref.read(quotedMessageProvider.notifier);
    final messages = await _loadConversationMessages(convId);

    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;

    // 如果当前引用的是被删除消息，一并清空引用态
    if (quoted?.id == messageId) {
      quotedNotifier.state = null;
    }

    await _historyPort.softDeleteMessages(
      convId,
      [messageId],
      clearContextStartIfDeleted: true,
    );
  }

  /// 编辑消息：删除指定消息及其后的所有消息，返回被删除消息的文本用于填充输入框
  Future<String?> editMessage(String messageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return null;
    final convId = conv.id;
    final attachmentNotifier = _ref.read(recalledAttachmentProvider.notifier);
    final messages = await _loadConversationMessages(convId);

    final msgIndex = messages.indexWhere((m) => m.id == messageId);
    if (msgIndex < 0) return null;

    final msg = messages[msgIndex];
    final text = _extractEditableTextForRecall(msg);
    attachmentNotifier.state = _extractAttachmentForRecall(msg);

    await _historyPort.truncateFromMessage(
      conversationId: convId,
      fromMessageId: messageId,
    );

    return text;
  }
}
