part of 'chat_actions.dart';

extension ChatActionsTurnRunner on ChatActions {
  Future<ChatSendTurnResult?> _executeTurnCommand({
    required ChatTurnCommand command,
    required Future<AppSettings> Function() loadSettings,
    List<String> Function(AppSettings settings)? resolveModelsToTry,
    Future<ChatPreparedTurn> Function(AppSettings settings)? prepareTurn,
    required ChatFailoverExecutor executeWithFailover,
    required void Function(String toolName) onToolExecuting,
    required ChatResultDelivery deliverResult,
    required bool Function() isCurrent,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) {
    final task = _activeGenerations[command.conversation.id];
    return _sendUseCase.executeTurn(
      command: command,
      options: ChatTurnExecutionOptions(
        loadSettings: loadSettings,
        prepareTurn: prepareTurn,
        resolveModelsToTry: resolveModelsToTry,
        executeWithFailover: executeWithFailover,
        onToolExecuting: onToolExecuting,
        deliverResult: ({
          required settings,
          required apiResult,
          required buildResult,
        }) async {
          task?.toolProgress.formalRawId = buildResult.rawMessage?.id;
          try {
            await deliverResult(
              settings: settings,
              apiResult: apiResult,
              buildResult: buildResult,
            );
          } finally {
            // 交接点是正式 raw 落库，与后续分段展示、取消、交付报错无关。
            if (task != null) {
              try {
                if (await _formalRawStored(task)) {
                  await _settleToolProgress(task);
                }
              } catch (e) {
                AppLogger.warning('ChatActions', '工具过程交接失败',
                    metadata: {'convId': task.convId, 'error': e.toString()});
              }
            }
          }
        },
        isCurrent: isCurrent,
        onStreamTextDelta: onStreamTextDelta,
        onStreamTextReset: onStreamTextReset,
        onStreamToolCallObserved: onStreamToolCallObserved,
        onStreamingFallback: onStreamingFallback,
      ),
    );
  }

  Future<void> _notifyUserMessageActivity(
    String conversationId,
    Message userMessage,
  ) {
    return _ref.read(analyzerSchedulerProvider).handleUserMessageActivity(
          conversationId: conversationId,
          messageId: userMessage.id,
          occurredAt: userMessage.createdAt,
        );
  }

  List<String> _resolvePreferredChatModels(
    AppSettings settings,
    Conversation? conv,
  ) {
    return conversationChatModels(settings, conv);
  }

  Future<void> _persistUserMessageForSend(
      {required String convId,
      required Message userMsg,
      required String displayText,
      required int runId,
      ChatEditDraft? edit,
      bool finishOnFailure = true,
      void Function(Message)? onUserCommitted}) async {
    try {
      if (edit == null) {
        await _sendPort.addUserMessage(
            convId: convId, userMsg: userMsg, displayText: displayText);
      } else {
        if (edit.conversationId != convId) throw StateError('编辑会话不匹配');
        await _ref.read(chatEditPortProvider).commitEdit(edit, userMsg);
      }
    } catch (_) {
      // 没有受理这条消息：排队的输入不再接着发。
      if (_isGenerationCurrent(convId, runId)) {
        _activeGenerations[convId]!.failed = true;
      }
      if (finishOnFailure) await _finishGeneration(convId, runId);
      rethrow;
    }
    try {
      final remoteRuns = await ModelRequestLedger.instance.activeRemoteRunsForConversation(convId);
      _ref.read(conversationRemoteRunningNoticeProvider(convId).notifier).state = remoteRuns.isEmpty ? null : '另一台设备（${remoteRuns.first.deviceName}）正在生成回复，已继续在本机发送';
    } catch (error) {
      AppLogger.warning('ModelRequestLedger', '读取模型请求记录失败', metadata: {'error': '$error'});
    }
    onUserCommitted?.call(userMsg);
    if (edit != null) {
      try {
        await _ref
            .read(conversationTimelineCacheProvider)
            .reloadConversationFromRawStore(convId);
      } catch (_) {
        AppLogger.warning('ChatActions', '编辑已落库，时间线刷新失败；重新进入会话可恢复');
      }
    }
  }

  Future<void> _sendText(String text,
      {ChatEditDraft? edit, void Function(Message)? onUserCommitted,
      Conversation? targetConversation, Message? preparedMessage,
      bool batchHasImage = false, int? preparedRunId,
      _QueuedSend? queued}) async {
    final conv = targetConversation ?? _ref.read(activeConversationProvider);
    if (conv == null || text.trim().isEmpty) return;
    final convId = conv.id;

    final userMsg = preparedMessage ?? _sendPort.createUserMessage(text: text, imagePath: null);
    queued?.messageId = userMsg.id;
    // 在第一个 await 前登记任务，排队输入交接时不暴露空闲状态。
    final runId = preparedRunId ?? _startGeneration(
      convId: convId, userMsgId: userMsg.id, queued: queued,
    );
    final generation = _activeGenerations[convId]!;
    TraceContext? traceContext;
    TraceLogger? trace;
    AppSettings? settingsSnapshot;
    _StreamPlaceholderDelivery? streamDelivery;
    var streamCommitted = false;
    var userPersisted = false;
    var persistenceStarted = false;
    void acceptUserMessage(Message message) {
      userPersisted = true;
      queued?.phase = _QueuedPhase.committed;
      onUserCommitted?.call(message);
    }
    try {
      traceContext = await _startTurnTrace(
        convId: convId,
        turnId: userMsg.id,
        entry: 'send_text',
        meta: {'inputLength': text.length},
      );
      trace = AppLogger.startTrace('AI消息发送',
          source: 'ChatActions', traceId: traceContext?.traceId);
      if (!_isGenerationCurrent(convId, runId)) return;
      if (queued != null) {
        // 落库前被停止的排队输入已由停止退回，这里不再落库。
        if (!_isGenerationCurrent(convId, runId)) return;
        queued.phase = _QueuedPhase.persisting;
      }
      persistenceStarted = true;
      await _persistUserMessageForSend(
          convId: convId,
          userMsg: userMsg,
          displayText: text,
          runId: runId,
          edit: edit,
          finishOnFailure: false,
          onUserCommitted: (message) {
            acceptUserMessage(message);
          });
      _recordTurnTrace(
        traceContext,
        TraceStage.userMessagePersisted,
        meta: {'hasImage': false},
      );
      await _awaitGenerationKeepAlive(convId, runId);
      await _notifyUserMessageActivity(convId, userMsg);
      if (!_isGenerationCurrent(convId, runId)) return;

      final initialSettings = await _ref.read(appSettingsProvider.future);
      settingsSnapshot = initialSettings;
      streamDelivery = await _createStreamDelivery(
        convId: convId,
        runId: runId,
        settings: initialSettings,
        traceContext: traceContext,
      );
      await streamDelivery.start();
      _setGenerationInterruptCleanup(convId, runId, () async {
        await _savePartialStream(delivery: streamDelivery, convId: convId, userMsgId: userMsg.id,
          status: ApiRunStatus.cancelled, settings: initialSettings, task: generation);
        await streamDelivery?.removePlaceholders();
        streamDelivery?.dispose();
      });
      await _runWithProviderRefreshRetry<void>(
        entry: 'send_text',
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
          final settings = initialSettings;
          if (streamDelivery == null) {
            streamDelivery = await _createStreamDelivery(
              convId: convId,
              runId: runId,
              settings: settings,
              traceContext: traceContext,
            );
            await streamDelivery!.start();
          }

          final turnResult = await _executeStreamingTurn(
            command: ChatTurnCommand.streaming(
              conversation: conv,
              userMessage: userMsg,
              sessionId: convId,
              apiText: text,
              traceContext: traceContext,
              trace: trace,
            ),
            loadSettings: () async => settings,
            resolveModelsToTry: (settings) => batchHasImage
                ? conversationChatModels(settings, conv,
                    base: _sendPort.buildImageSendModelRefs(settings))
                : _resolvePreferredChatModels(settings, conv),
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
              execute: (config) {
                streamDelivery?.setTransportStreaming(
                  config.presetScript?.hasContentTransport ?? false,
                );
                return execute(config.copyWith(
                  onTransportStreamingChanged: (enabled) =>
                      streamDelivery?.setTransportStreaming(enabled),
                ));
              },
              settings: settings,
            ),
            convId: convId,
            runId: runId,
            userMsgId: userMsg.id,
            streamDelivery: () => streamDelivery,
            onStreamCommitted: () => streamCommitted = true,
          );
          if (turnResult == null) return;
          if (!_isGenerationCurrent(convId, runId)) return;
          for (final message in turnResult.buildResult.messages) {
            _diagnostics.bindMessage(
                message.id, _diagnostics.forTurn(traceContext?.turnId));
          }
          _recordTurnTrace(
            traceContext,
            TraceStage.messageDelivered,
            meta: {
              'assistantMessageCount': turnResult.buildResult.messages.length,
              'streamCommitted': streamCommitted,
            },
          );
          trace?.end(additionalMessage: '完成');
          _recordTurnTrace(traceContext, TraceStage.turnCompleted);
        },
      );
    } catch (e, stack) {
      // addUserMessage may commit raw before a cache/summary refresh fails.
      // Only a durable row counts as acceptance; never mark a nonexistent draft.
      if (!userPersisted && persistenceStarted) {
        var stored = false;
        try {
          stored = await _ref.read(chatHistoryStoreProvider).isRawMessageActive(
            conversationId: convId, messageId: userMsg.id);
        } catch (lookupError) {
          AppLogger.warning('ChatActions', '确认用户消息落库状态失败',
              metadata: {'error': lookupError.toString()});
        }
        if (stored) {
          try {
            acceptUserMessage(userMsg);
          } catch (callbackError) {
            AppLogger.warning('ChatActions', '用户消息已落库，受理回调失败',
                metadata: {'error': callbackError.toString()});
          }
        }
      }
      generation.failed = true;
      if (!userPersisted) rethrow;
      if (!_isGenerationCurrent(convId, runId)) return;
      try {
        if (streamDelivery != null) {
          await _savePartialStream(delivery: streamDelivery, convId: convId,
            userMsgId: userMsg.id, status: ApiRunStatus.failed,
            settings: settingsSnapshot!, task: generation);
        }
      } catch (partialError) {
        AppLogger.warning('ChatActions', '保存半截回复失败',
            metadata: {'error': partialError.toString()});
      }
      if (!_isGenerationCurrent(convId, runId)) return;
      trace?.error('失败', metadata: {'error': e.toString()});
      trace?.end(additionalMessage: '失败');
      _recordTurnTrace(
        traceContext,
        TraceStage.turnFailed,
        status: TraceEventStatus.failed,
        error: e,
        stackTrace: stack,
        meta: {'error': e.toString()},
      );
      _setConversationError(convId, e.toString());
      await _sendPort.markUserMessageFailed(
          convId: convId, userMsgId: userMsg.id);
    } finally {
      try {
        if (!streamCommitted) await streamDelivery?.removePlaceholders();
      } catch (cleanupError) {
        AppLogger.warning('ChatActions', '清理流式占位失败',
            metadata: {'error': cleanupError.toString()});
      } finally {
        try {
          streamDelivery?.dispose();
        } finally {
          await _finishGeneration(convId, runId);
        }
      }
    }
  }

  String _resolveFinalStreamText(
    ApiCallResult apiResult,
    AssistantMessageBuildResult buildResult,
  ) {
    final rawReplyText = apiResult.replyText.trim();
    if (rawReplyText.isNotEmpty) {
      return apiResult.replyText;
    }
    final processedText = apiResult.processedText.trim();
    if (processedText.isNotEmpty) {
      return processedText;
    }
    return _extractAssistantTextForStream(buildResult);
  }

  String _extractAssistantTextForStream(
      AssistantMessageBuildResult buildResult) {
    final parts = <String>[];
    for (final message in buildResult.messages) {
      if (message.role != 'assistant') continue;
      final blocks = message.blocks;
      if (blocks != null && blocks.isNotEmpty) {
        for (final block in blocks.whereType<TextBlock>()) {
          final text = block.content.trim();
          if (text.isNotEmpty) {
            parts.add(text);
          }
        }
        continue;
      }
      final text = message.content.trim();
      if (text.isNotEmpty) {
        parts.add(text);
      }
    }
    return parts.join('\n');
  }

}
