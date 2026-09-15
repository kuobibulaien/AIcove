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
              final cachedResult = await _ref
                  .read(chatSendServiceProvider)
                  .processAssistantReplyWithPlugins(
                    conv: conv,
                    rawReplyText: cachedReply,
                  );
              final buildResult = _sendPort.buildAssistantMessages(
                apiResult: cachedResult,
                settings: settings,
              );
              await _ttsHandler.deliverSegmentedMessages(
                convId: targetConvId,
                userMsgId: '',
                buildResult: buildResult,
                replyText: cachedResult.rawReplyText,
                pluginEvents: cachedResult.pluginEvents,
                ttsEnabled: settings.ttsEnabled,
              );
              _recordTurnTrace(
                traceContext,
                TraceStage.messageDelivered,
                meta: {
                  'assistantMessageCount': buildResult.messages.length,
                  'pluginEvents': cachedResult.pluginEvents.length,
                },
              );
              _recordTurnTrace(traceContext, TraceStage.turnCompleted);
              AppLogger.info('ChatActions', '触发器发送成功（cached）', metadata: {
                'triggerId': trigger.id,
                'title': trigger.title,
              });
              return const ProactiveSendResult.success();
            }
          }

          final proactiveHistory = await _ref
              .read(chatHistoryStoreProvider)
              .loadCanonicalContextMessages(
                targetConvId,
                limit: 0,
              );
          final modelsToTry = _resolvePreferredChatModels(settings);
          final (apiResult, usedSettings) = await _executeWithFailover(
            convId: targetConvId,
            modelsToTry: modelsToTry,
            buildConfig: (model) async {
              final baseConfig = await _sendPort.prepareApiConfig(
                conv: conv,
                history: proactiveHistory,
                userText: null,
                overrideModel: model,
                conversationId: targetConvId,
                traceContext: traceContext,
              );
              return _injectTriggerReminderIntoApiConfig(baseConfig, trigger);
            },
            execute: (config) => _sendPort.executeApiCall(
              config: config,
              sessionId: targetConvId,
              userText: null,
              turnId: 'trigger_${trigger.id}',
              onToolExecuting: (toolName) =>
                  _updateStatusForTool(targetConvId, toolName),
            ),
            settings: settings,
          );
          final buildResult = _sendPort.buildAssistantMessages(
            apiResult: apiResult,
            settings: usedSettings,
          );
          await _ttsHandler.deliverSegmentedMessages(
            convId: targetConvId,
            userMsgId: '',
            buildResult: buildResult,
            replyText: apiResult.rawReplyText,
            pluginEvents: apiResult.pluginEvents,
            ttsEnabled: usedSettings.ttsEnabled,
          );

          _recordTurnTrace(
            traceContext,
            TraceStage.messageDelivered,
            meta: {
              'assistantMessageCount': buildResult.messages.length,
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
    final failedMsg = await _resolveCanonicalActionMessage(
      convId: convId,
      messageId: messageId,
    );
    if (failedMsg == null || failedMsg.status != 'failed') {
      throw Exception('消息不存在或状态不正确');
    }

    final runId = await _startGeneration(
      convId: convId,
      userMsgId: messageId,
    );
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
      await _restoreFrontendMessagesFromHistory(convId);
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
              final msgIndex = _findFirstMessageIndexByIdOrSource(
                messages,
                messageId,
              );
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
                generationSeq: runId,
                diagnosticContext: _diagnostics.forTurn(traceContext?.turnId),
                formatConfig: settings.messageFormatConfig,
                enableTtsPlaceholders: settings.ttsEnabled,
                segmentDelay: Duration(
                  milliseconds:
                      (settings.streamSegmentDelaySeconds * 1000).round(),
                ),
                onPendingAudioAppeared: (pendingMessage) {
                  if (!_isGenerationCurrent(convId, runId)) return;
                  _scheduleStreamPendingTtsResolution(
                    convId: convId,
                    pendingMessage: pendingMessage,
                    streamDelivery: streamDelivery!,
                  );
                },
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
      await _finishGeneration(convId, runId);
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
    final userMsg = await _findRegenerateSourceUserMessage(
      conv.id,
      messages,
      aiMessageId,
    );
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

  Future<Message?> _findRegenerateSourceUserMessage(
    String convId,
    List<Message> messages,
    String aiMessageId,
  ) async {
    final targetMessage = await _resolveCanonicalActionMessage(
      convId: convId,
      messageId: aiMessageId,
      history: messages,
    );
    if (targetMessage == null) {
      return null;
    }

    final msgIndex = _findFirstMessageIndexByIdOrSource(
      messages,
      targetMessage.id,
    );
    if (msgIndex < 0) return null;

    int userMsgIndex = msgIndex - 1;
    while (userMsgIndex >= 0 && messages[userMsgIndex].role != 'user') {
      userMsgIndex--;
    }
    if (userMsgIndex < 0) return null;
    return _canonicalizeActionMessage(convId, messages[userMsgIndex]);
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
    // 在第一个 await 前占用发送状态，历史读取/保活等待也可取消且不能重入。
    if (_activeGenerations.containsKey(convId) ||
        _ref.read(conversationSendingProvider(convId))) {
      return;
    }
    final operation = _diagnostics.begin(
      FrontendStage.sendRequested,
      conversationId: convId,
    );
    _diagnostics.record(operation, FrontendStage.sendRequested,
        facts: DiagnosticFacts(state: {
          'regenerate': true,
          'enhanced': useEnhancement,
        }));
    final runId = await _startGeneration(convId: convId);
    TraceContext? traceContext;
    _StreamPlaceholderDelivery? streamDelivery;
    var streamCommitted = false;
    try {
      if (!_isGenerationCurrent(convId, runId)) return;
      final readClock = Stopwatch()..start();
      final messages = await _loadConversationMessages(convId);
      final historyReadMs = readClock.elapsedMilliseconds;
      if (!_isGenerationCurrent(convId, runId)) return;
      final userMsg = await _findRegenerateSourceUserMessage(
        convId,
        messages,
        aiMessageId,
      );
      if (!_isGenerationCurrent(convId, runId)) return;
      if (userMsg == null) {
        _diagnostics.record(operation, FrontendStage.turnCancelled,
            facts:
                const DiagnosticFacts(reason: DiagnosticReason.unknownMessage));
        return;
      }
      final lookupMs = readClock.elapsedMilliseconds - historyReadMs;
      final userText = userMsg.displayText;
      _activeGenerations[convId] = _GenerationTask(
        id: runId,
        convId: convId,
        userMsgId: userMsg.id,
      );
      traceContext = await _startTurnTrace(
        convId: convId,
        turnId: userMsg.id,
        entry: useEnhancement ? 'regenerate_enhanced' : 'regenerate',
        meta: {'targetAiMessageId': aiMessageId},
      );
      if (!_isGenerationCurrent(convId, runId)) return;
      _setGenerationInterruptCleanup(convId, runId, () async {
        await streamDelivery?.removePlaceholders();
        streamDelivery?.dispose();
        await _restoreFrontendMessagesFromHistory(convId);
      });
      final truncateClock = Stopwatch()..start();
      await _historyPort.truncateAfterMessage(
        conversationId: convId,
        anchorMessageId: userMsg.id,
      );
      _diagnostics.record(operation, FrontendStage.sendRequested,
          itemCount: messages.length,
          facts: DiagnosticFacts(phase: DiagnosticPhase.end, state: {
            'regenerate': true,
            'enhanced': useEnhancement,
            'historyReadMs': historyReadMs,
            'lookupMs': lookupMs,
            'truncateMs': truncateClock.elapsedMilliseconds,
          }));
      if (!_isGenerationCurrent(convId, runId)) return;
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
              // 活动页面可能已切到另一个联系人，请求始终归属最初的convId。
              final updatedConv =
                  _ref.read(conversationSnapshotByIdProvider(convId)) ?? conv;
              final canUseEnhancement =
                  useEnhancement && settings.enhancedDialogueSettings.enabled;
              if (!canUseEnhancement) {
                return ChatPreparedTurn(
                  requestConversation: updatedConv,
                  history: await _sendPort.prepareHistoryFromStore(
                    conv: updatedConv,
                    userMsg: userMsg,
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
                enhancerSystemPrompt: _resolveEnhancedPrompt(
                  settings.enhancedDialogueSettings.systemPrompt,
                  'enhanced_dialogue.system.default',
                  EnhancedDialogueSettings.defaultSystemPrompt,
                ),
                bootstrapUserMessage: _resolveEnhancedPrompt(
                  settings.enhancedDialogueSettings.bootstrapUserMessage,
                  'enhanced_dialogue.bootstrap_user.default',
                  EnhancedDialogueSettings.defaultBootstrapUserMessage,
                ),
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
                generationSeq: runId,
                diagnosticContext: _diagnostics.forTurn(traceContext?.turnId),
                formatConfig: settings.messageFormatConfig,
                enableTtsPlaceholders: settings.ttsEnabled,
                segmentDelay: Duration(
                  milliseconds:
                      (settings.streamSegmentDelaySeconds * 1000).round(),
                ),
                onPendingAudioAppeared: (pendingMessage) {
                  if (!_isGenerationCurrent(convId, runId)) return;
                  _scheduleStreamPendingTtsResolution(
                    convId: convId,
                    pendingMessage: pendingMessage,
                    streamDelivery: streamDelivery!,
                  );
                },
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
      if (traceContext == null) {
        _diagnostics.record(operation, FrontendStage.turnFailed,
            error: e,
            facts: const DiagnosticFacts(
                phase: DiagnosticPhase.error,
                reason: DiagnosticReason.operationFailed));
      }
      _setConversationError(convId, e.toString());
      try {
        await _restoreFrontendMessagesFromHistory(convId);
      } catch (restoreError, stack) {
        _diagnostics.record(operation, FrontendStage.historyFailed,
            error: restoreError, stackTrace: stack);
      }
    } finally {
      if (!_isGenerationCurrent(convId, runId)) {
        _diagnostics.record(operation, FrontendStage.turnCancelled, once: true);
      }
      // 占位清理出错也不能跳过发送锁和保活释放。
      try {
        if (!streamCommitted) await streamDelivery?.removePlaceholders();
      } finally {
        try {
          streamDelivery?.dispose();
        } finally {
          await _finishGeneration(convId, runId);
        }
      }
    }
  }

  /// 撤回失败消息：将失败消息的文本回填到输入框，并从会话中删除该消息
  Future<void> recallFailedMessage(String messageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final convId = conv.id;
    final editingNotifier = _ref.read(editingTextProvider.notifier);
    final attachmentNotifier = _ref.read(recalledAttachmentProvider.notifier);
    final failedMsg = await _resolveCanonicalActionMessage(
      convId: convId,
      messageId: messageId,
    );
    if (failedMsg == null || failedMsg.status != 'failed') return;

    // 将失败消息文本填入输入框
    final text = _extractEditableTextForRecall(failedMsg);
    if (text.isNotEmpty) {
      editingNotifier.state = text;
    }
    attachmentNotifier.state = _extractAttachmentForRecall(failedMsg);

    await _historyPort.softDeleteMessages(
      convId,
      [failedMsg.id],
      clearContextStartIfDeleted: true,
    );
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

  /// 删除单条消息（仅前端隐藏，不改数据库真相源）
  Future<void> deleteMessage(String messageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final convId = conv.id;
    final quoted = _ref.read(quotedMessageProvider);
    final quotedNotifier = _ref.read(quotedMessageProvider.notifier);
    final actionMessage = await _resolveFrontendActionMessage(
      convId: convId,
      messageId: messageId,
    );
    if (actionMessage == null) return;

    // 如果当前引用的是被删除消息，一并清空引用态
    final deleteId = actionMessage.id;
    final deleteSourceId = actionMessage.sourceMessageId?.trim();
    if (quoted?.id == messageId ||
        quoted?.id == deleteId ||
        (deleteSourceId != null &&
            deleteSourceId.isNotEmpty &&
            quoted?.id == deleteSourceId)) {
      quotedNotifier.state = null;
    }

    await _ref.read(chatHistoryStoreProvider).hideMessagesInFrontendTimeline(
      convId,
      [deleteId],
    );
  }

  /// 准备编辑草稿，不改变历史；只有确认发送后才提交新分支。
  Future<String?> editMessage(String messageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return null;
    final convId = conv.id;
    if (_ref.read(conversationSendingProvider(convId))) {
      throw StateError('当前会话正在生成，请结束后再编辑');
    }
    final historyStore = _ref.read(chatHistoryStoreProvider);
    final frontendMessage = await historyStore.loadFrontendMessageById(
      messageId,
      conversationId: convId,
    );
    if (frontendMessage == null) return null;
    final sourceMessageId = frontendMessage.sourceMessageId?.trim();
    final msg = sourceMessageId != null &&
            sourceMessageId.isNotEmpty &&
            sourceMessageId != frontendMessage.id
        ? await historyStore.loadMessageById(
              sourceMessageId,
              conversationId: convId,
              preferProjection: false,
            ) ??
            frontendMessage
        : frontendMessage;
    final draft =
        await _ref.read(chatEditPortProvider).prepareEdit(convId, msg.id);
    if (_ref.read(activeConversationProvider)?.id != convId ||
        _ref.read(conversationSendingProvider(convId))) {
      throw StateError('会话状态已变化，未进入编辑');
    }
    final original = draft.originalMessage;
    if (original == null) throw StateError('无法恢复原始消息，未进入编辑');
    final text = _extractEditableTextForRecall(original);
    _ref.read(chatEditSeedProvider(convId).notifier).state = ChatEditSeed(
        draft: draft,
        text: text,
        attachment: _extractAttachmentForRecall(original));
    return text;
  }

  int _findFirstMessageIndexByIdOrSource(
    List<Message> messages,
    String messageId,
  ) {
    final normalizedMessageId = messageId.trim();
    if (normalizedMessageId.isEmpty) return -1;
    return messages.indexWhere((message) {
      final sourceMessageId = message.sourceMessageId?.trim();
      return message.id == normalizedMessageId ||
          (sourceMessageId != null && sourceMessageId == normalizedMessageId);
    });
  }

  Future<Message?> _resolveCanonicalActionMessage({
    required String convId,
    required String messageId,
    List<Message>? history,
  }) async {
    final resolvedHistory = history ?? await _loadConversationMessages(convId);
    final resolved = await _resolveFrontendActionMessage(
      convId: convId,
      messageId: messageId,
      history: resolvedHistory,
    );
    if (resolved == null) {
      return null;
    }
    return _canonicalizeActionMessage(
      convId,
      resolved,
      history: resolvedHistory,
    );
  }

  Future<Message?> _resolveFrontendActionMessage({
    required String convId,
    required String messageId,
    List<Message>? history,
  }) async {
    final resolvedHistory = history ?? await _loadConversationMessages(convId);
    final directIndex =
        _findFirstMessageIndexByIdOrSource(resolvedHistory, messageId);
    if (directIndex >= 0) {
      return resolvedHistory[directIndex];
    }
    return _ref.read(chatHistoryStoreProvider).loadFrontendMessageById(
          messageId,
          conversationId: convId,
        );
  }

  Future<Message> _canonicalizeActionMessage(
    String convId,
    Message message, {
    List<Message>? history,
  }) async {
    final sourceMessageId = message.sourceMessageId?.trim();
    if (sourceMessageId == null ||
        sourceMessageId.isEmpty ||
        sourceMessageId == message.id) {
      return message;
    }

    final resolvedHistory = history ?? await _loadConversationMessages(convId);
    final sourceIndex = resolvedHistory.indexWhere(
      (item) => item.id == sourceMessageId,
    );
    if (sourceIndex >= 0) {
      return resolvedHistory[sourceIndex];
    }

    final rawMessage =
        await _ref.read(chatHistoryStoreProvider).loadMessageById(
              sourceMessageId,
              conversationId: convId,
              preferProjection: false,
            );
    return rawMessage ?? message;
  }

  String _resolveEnhancedPrompt(
    String storedPrompt,
    String promptId,
    String builtinDefault,
  ) {
    if (storedPrompt.trim() == builtinDefault.trim()) {
      return PromptBuiltinDefaults.requireTemplate(promptId);
    }
    return storedPrompt;
  }
}
