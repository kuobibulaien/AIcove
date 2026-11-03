part of 'chat_actions.dart';

extension ChatActionsMediaSend on ChatActions {
  Future<void> _sendImage(String imagePath,
      {String? text,
      ChatEditDraft? edit,
      Conversation? targetConversation,
      Message? preparedMessage,
      int? preparedRunId,
      void Function(Message)? onUserCommitted}) async {
    final conv = targetConversation ?? _ref.read(activeConversationProvider);
    if (conv == null || imagePath.trim().isEmpty) return;
    final convId = conv.id;

    final userText = text?.trim();
    final hasText = userText != null && userText.isNotEmpty;
    final userMsg = preparedMessage ?? _sendPort.createUserMessage(
      text: hasText ? userText : null,
      imagePath: imagePath,
    );
    final runId = preparedRunId ?? _startGeneration(
      convId: convId,
      userMsgId: userMsg.id,
    );
    final traceContext = await _startTurnTrace(
      convId: convId,
      turnId: userMsg.id,
      entry: 'send_image',
      meta: {'hasText': hasText},
    );
    if (!_isGenerationCurrent(convId, runId)) return;
    final displayText = hasText ? userText : '[图片]';
    await _persistUserMessageForSend(
        convId: convId,
        userMsg: userMsg,
        displayText: displayText,
        runId: runId,
        edit: edit,
        onUserCommitted: onUserCommitted);
    _recordTurnTrace(
      traceContext,
      TraceStage.userMessagePersisted,
      meta: {'hasImage': true},
    );
    await _awaitGenerationKeepAlive(convId, runId);
    await _notifyUserMessageActivity(convId, userMsg);
    if (!_isGenerationCurrent(convId, runId)) return;

    var turnSucceeded = false;
    try {
      await _runWithProviderRefreshRetry<void>(
        entry: 'send_image',
        convId: convId,
        task: () async {
          final apiText = hasText ? userText : '[image]';
          final turnResult = await _executeTurnCommand(
            command: ChatTurnCommand.nonStreaming(
              conversation: conv,
              userMessage: userMsg,
              sessionId: convId,
              apiText: apiText,
              traceContext: traceContext,
            ),
            loadSettings: () => _ref.read(appSettingsProvider.future),
            resolveModelsToTry: (settings) => conversationChatModels(
                  settings,
                  conv,
                  base: _sendPort.buildImageSendModelRefs(settings),
                ),
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
            onToolExecuting: (toolName) =>
                _updateStatusForTool(convId, toolName),
            deliverResult: ({
              required settings,
              required apiResult,
              required buildResult,
            }) =>
                _ttsHandler.deliverSegmentedMessages(
              convId: convId,
              userMsgId: userMsg.id,
              buildResult: buildResult,
              replyText: apiResult.rawReplyText,
              pluginEvents: apiResult.pluginEvents,
              ttsEnabled: settings.ttsEnabled,
              shouldCommit: () => _isGenerationCurrent(convId, runId),
            ),
            isCurrent: () => _isGenerationCurrent(convId, runId),
          );
          if (turnResult == null) return;
          _recordTurnTrace(
            traceContext,
            TraceStage.messageDelivered,
            meta: {
              'assistantMessageCount': turnResult.buildResult.messages.length
            },
          );
          _recordTurnTrace(traceContext, TraceStage.turnCompleted);
          turnSucceeded = true;
        },
      );
    } catch (e, stack) {
      if (!_isGenerationCurrent(convId, runId)) return;
      _recordTurnTrace(
        traceContext,
        TraceStage.turnFailed,
        status: TraceEventStatus.failed,
        error: e,
        stackTrace: stack,
        meta: {'error': e.toString()},
      );
      await _sendPort.markUserMessageFailed(
          convId: convId, userMsgId: userMsg.id);
      _setConversationError(convId, e.toString());
    } finally {
      await _finishGeneration(
        convId,
        runId,
      );
      if (!turnSucceeded) {
        // 已在 catch 记录 TURN_FAILED。
      }
    }
  }

  Future<void> _sendFile(String filePath,
      {String? text,
      ChatEditDraft? edit,
      Conversation? targetConversation,
      Message? preparedMessage,
      int? preparedRunId,
      bool batchHasImage = false,
      void Function(Message)? onUserCommitted}) async {
    final conv = targetConversation ?? _ref.read(activeConversationProvider);
    if (conv == null || filePath.trim().isEmpty) return;
    final convId = conv.id;

    final normalizedText = text?.trim();
    final mimeType = MimeUtils.guessAttachmentMimeType(filePath);
    final isAudio = MimeUtils.isAudioMimeType(mimeType);
    final isVideo = MimeUtils.isVideoMimeType(mimeType);
    final entry = isAudio
        ? 'send_audio'
        : isVideo
            ? 'send_video'
            : 'send_file';
    final placeholder = isAudio
        ? '[音频]'
        : isVideo
            ? '[视频]'
            : '[文件]';
    final apiText = isAudio
        ? '[audio]'
        : isVideo
            ? '[video]'
            : '[file]';

    final userMsg = preparedMessage ?? await _sendPort.createUserFileMessage(
      filePath: filePath,
      text: normalizedText,
    );
    final runId = preparedRunId ?? _startGeneration(
      convId: convId,
      userMsgId: userMsg.id,
    );
    final traceContext = await _startTurnTrace(
      convId: convId,
      turnId: userMsg.id,
      entry: entry,
      meta: {
        'hasText': normalizedText != null && normalizedText.isNotEmpty,
        'mimeType': mimeType,
      },
    );
    if (!_isGenerationCurrent(convId, runId)) return;
    await _persistUserMessageForSend(
      convId: convId,
      userMsg: userMsg,
      runId: runId,
      edit: edit,
      onUserCommitted: onUserCommitted,
      displayText: normalizedText != null && normalizedText.isNotEmpty
          ? normalizedText
          : placeholder,
    );
    _recordTurnTrace(
      traceContext,
      TraceStage.userMessagePersisted,
      meta: {
        'hasFile': !isAudio && !isVideo,
        'hasAudio': isAudio,
        'hasVideo': isVideo,
      },
    );
    await _awaitGenerationKeepAlive(convId, runId);
    await _notifyUserMessageActivity(convId, userMsg);
    if (!_isGenerationCurrent(convId, runId)) return;

    var turnSucceeded = false;
    try {
      await _runWithProviderRefreshRetry<void>(
        entry: entry,
        convId: convId,
        task: () async {
          final turnResult = await _executeTurnCommand(
            command: ChatTurnCommand.nonStreaming(
              conversation: conv,
              userMessage: userMsg,
              sessionId: convId,
              apiText: apiText,
              traceContext: traceContext,
            ),
            loadSettings: () => _ref.read(appSettingsProvider.future),
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
              execute: execute,
              settings: settings,
            ),
            onToolExecuting: (toolName) =>
                _updateStatusForTool(convId, toolName),
            deliverResult: ({
              required settings,
              required apiResult,
              required buildResult,
            }) =>
                _ttsHandler.deliverSegmentedMessages(
              convId: convId,
              userMsgId: userMsg.id,
              buildResult: buildResult,
              replyText: apiResult.rawReplyText,
              pluginEvents: apiResult.pluginEvents,
              ttsEnabled: settings.ttsEnabled,
              shouldCommit: () => _isGenerationCurrent(convId, runId),
            ),
            isCurrent: () => _isGenerationCurrent(convId, runId),
          );
          if (turnResult == null) return;
          _recordTurnTrace(
            traceContext,
            TraceStage.messageDelivered,
            meta: {
              'assistantMessageCount': turnResult.buildResult.messages.length
            },
          );
          _recordTurnTrace(traceContext, TraceStage.turnCompleted);
          turnSucceeded = true;
        },
      );
    } catch (e, stack) {
      if (!_isGenerationCurrent(convId, runId)) return;
      _recordTurnTrace(
        traceContext,
        TraceStage.turnFailed,
        status: TraceEventStatus.failed,
        error: e,
        stackTrace: stack,
        meta: {'error': e.toString()},
      );
      await _sendPort.markUserMessageFailed(
          convId: convId, userMsgId: userMsg.id);
      _setConversationError(convId, e.toString());
    } finally {
      await _finishGeneration(
        convId,
        runId,
      );
      if (!turnSucceeded) {
        // 已在 catch 记录 TURN_FAILED。
      }
    }
  }

}
