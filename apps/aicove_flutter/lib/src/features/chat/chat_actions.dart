/// 聊天动作入口（门面类）
///
/// 作为各聊天服务的协调层，提供简洁的公开 API。
/// 实际逻辑已拆分到以下服务：
/// - ChatSendService: 消息发送
/// - ChatTtsHandler: TTS 处理与消息交付
/// - ChatMessageProcessor: 消息处理
/// - AnalyzerScheduler: AI 管家分析调度
///
/// 更新记录：
/// - 2025-12-31: 重构为门面模式，进一步提取 TTS 处理
/// - 2026-01-27: 将 AI 管家分析触发逻辑委托给 AnalyzerScheduler
/// - 2026-01-28: 使用 deliverSegmentedMessages 统一消息交付，移除占位符机制
library;

import 'dart:convert';
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/auto_reply_trigger.dart';
import 'data/analyzer_scheduler.dart';
import 'data/enhanced_dialogue_service.dart';
import 'application/chat_ports.dart';
import 'application/chat_send_use_case.dart';
import 'application/chat_turn_command.dart';
import 'id_gen.dart' show genId;
import 'chat_layer_providers.dart';
import 'services/chat_send_service.dart';
import 'services/chat_types.dart'
    show
        ApiCallResult,
        AssistantMessageBuildResult,
        isProviderRefreshTimingError;
import 'services/chat_tts_handler.dart';
import 'domain/message.dart';
import '../settings/app_settings.dart';
import 'conversation_providers.dart';
import 'services/conversation_short_window_store.dart'
    show conversationShortWindowStoreProvider;
import 'chat_providers.dart';
import '../../core/app_logger.dart';
import '../../core/models/message_block.dart';
import '../../core/models/block_status.dart';
import '../../core/services/attachment_picker_service.dart';
import '../../core/utils/message_formatter.dart';
import '../observability/trace_models.dart';
import '../observability/trace_store.dart';
import '../plugins/domain/plugin.dart' show PluginEvent;

// 重新导出公共类型，保持向后兼容
export 'chat_providers.dart';
export 'services/chat_types.dart';
export 'services/chat_send_service.dart'
    show ChatSendService, ApiCallResult, ApiConfig, SendRequest;
export 'services/chat_tts_handler.dart' show ChatTtsHandler;
part 'chat_actions_stream_placeholder.dart';
part 'chat_actions_action_ops.dart';

class ChatActions {
  static const Duration _kProviderRefreshRetryDelay =
      Duration(milliseconds: 120);
  static const int _kProviderRefreshMaxRetries = 1;

  ChatActions(this._ref);

  final Ref _ref;
  ChatSendPort get _sendPort => _ref.read(chatSendPortProvider);
  ChatSendUseCase get _sendUseCase => _ref.read(chatSendUseCaseProvider);
  ChatTtsHandler get _ttsHandler => _ref.read(chatTtsHandlerProvider);
  ChatHistoryPort get _historyPort => _ref.read(chatHistoryPortProvider);
  final EnhancedDialogueService _enhancedDialogueService =
      const EnhancedDialogueService();
  int _generationSerial = 0;
  final Map<String, _GenerationTask> _activeGenerations = {};
  final Map<String, Future<void> Function()> _generationInterruptCleanups = {};

  Future<TraceContext?> _startTurnTrace({
    required String convId,
    required String turnId,
    required String entry,
    Map<String, dynamic>? meta,
  }) async {
    try {
      return await TraceStore.instance.startTurn(
        sessionId: convId,
        turnId: turnId,
        source: 'ChatActions',
        meta: <String, dynamic>{
          'entry': entry,
          ...?meta,
        },
      );
    } catch (e) {
      AppLogger.warning(
        'ChatActions',
        'start turn trace failed',
        metadata: {'error': e.toString(), 'entry': entry},
      );
      return null;
    }
  }

  Future<List<Message>> _loadConversationMessages(String convId) {
    return _historyPort.loadAllMessages(convId);
  }

  void _recordTurnTrace(
    TraceContext? context,
    TraceStage stage, {
    TraceEventStatus status = TraceEventStatus.success,
    int roundIndex = 0,
    Map<String, dynamic>? meta,
    Map<String, dynamic>? payloadRef,
  }) {
    if (context == null) return;
    unawaited(
      TraceStore.instance.record(
        traceId: context.traceId,
        sessionId: context.sessionId,
        turnId: context.turnId,
        stage: stage,
        status: status,
        source: 'ChatActions',
        roundIndex: roundIndex,
        meta: meta,
        payloadRef: payloadRef,
      ),
    );
  }

  void _setConversationSending(String convId, bool isSending) {
    _runIgnoringProviderRefreshTiming('set_conversation_sending', () {
      _ref.read(conversationSendingProvider(convId).notifier).state = isSending;
    });
  }

  void _setConversationStatus(String convId, ChatStatus status) {
    _runIgnoringProviderRefreshTiming('set_conversation_status', () {
      _ref.read(chatStatusProvider.notifier).state = status;
    });
  }

  void _setConversationError(String convId, String? error) {
    _runIgnoringProviderRefreshTiming('set_conversation_error', () {
      _ref.read(errorProvider.notifier).state = error;
    });
  }

  void _setConversationFailoverInfo(String convId, String? modelName) {
    _runIgnoringProviderRefreshTiming('set_conversation_failover_info', () {
      _ref.read(modelFailoverInfoProvider.notifier).state = modelName;
    });
  }

  Future<ModelFailoverDecision> _requestModelFailoverDecision({
    required String convId,
    required String failedModel,
    required String nextModel,
    required AppSettings settings,
    required Object error,
  }) {
    return _ref.read(modelFailoverPromptProvider.notifier).request(
          conversationId: convId,
          failedModelName: settings.getModelDisplayName(failedModel),
          nextModelName: settings.getModelDisplayName(nextModel),
          errorMessage: error.toString(),
        );
  }

  int _startGeneration({
    required String convId,
    String? userMsgId,
  }) {
    final runId = ++_generationSerial;
    _activeGenerations[convId] = _GenerationTask(
      id: runId,
      convId: convId,
      userMsgId: userMsgId,
    );
    _setConversationSending(convId, true);
    _setConversationStatus(convId, ChatStatus.thinking);
    _setConversationError(convId, null);
    return runId;
  }

  void _setGenerationInterruptCleanup(
    String convId,
    int runId,
    Future<void> Function() cleanup,
  ) {
    if (!_isGenerationCurrent(convId, runId)) return;
    _generationInterruptCleanups[convId] = cleanup;
  }

  bool _isGenerationCurrent(String convId, int runId) =>
      _activeGenerations[convId]?.id == runId;

  void _runIgnoringProviderRefreshTiming(
    String action,
    void Function() callback,
  ) {
    try {
      callback();
    } catch (e) {
      if (!isProviderRefreshTimingError(e)) {
        rethrow;
      }
      AppLogger.info(
        'ChatActions',
        '命中 Provider 刷新窗口，跳过一次瞬时状态更新',
        metadata: {'action': action},
      );
    }
  }

  void _finishGeneration(
    String convId,
    int runId, {
    bool clearFailoverInfo = false,
    bool scheduleAnalysis = false,
  }) {
    if (!_isGenerationCurrent(convId, runId)) return;
    _activeGenerations.remove(convId);
    _generationInterruptCleanups.remove(convId);
    _setConversationSending(convId, false);
    _setConversationStatus(convId, ChatStatus.idle);
    if (clearFailoverInfo) {
      _setConversationFailoverInfo(convId, null);
    }
    if (scheduleAnalysis) {
      _ref.read(analyzerSchedulerProvider).scheduleAnalysis();
    }
  }

  Future<void> _markUserMessageAsSent(_GenerationTask task) async {
    final userMsgId = task.userMsgId;
    if (userMsgId == null || userMsgId.trim().isEmpty) return;

    await _historyPort.markMessageStatus(
      conversationId: task.convId,
      messageId: userMsgId,
      status: 'sent',
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
        .read(conversationShortWindowStoreProvider)
        .loadAllMessages(convId);
    final removeIds = <String>[
      for (final message in allMessages)
        if (message.sourceMessageId == rawMessageId &&
            !keepIds.contains(message.id))
          message.id,
    ];
    if (removeIds.isEmpty) {
      return;
    }
    await _ref.read(conversationShortWindowStoreProvider).replaceMessages(
          conversationId: convId,
          removeMessageIds: removeIds,
        );
  }

  List<Message> _extractStreamCommittedMessages(List<Message> messages) {
    final committed = <Message>[];
    for (final message in messages) {
      final committedMessage = _toStreamCommittedMessage(message);
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

  Future<void> _commitStreamDelivery({
    required _StreamPlaceholderDelivery streamDelivery,
    required String convId,
    required String userMsgId,
    required AssistantMessageBuildResult buildResult,
    required String replyText,
    required List<PluginEvent> pluginEvents,
    required bool ttsEnabled,
    TraceLogger? trace,
  }) async {
    final committedMessages = _extractStreamCommittedMessages(
      buildResult.messages,
    );
    if (committedMessages.isEmpty) {
      throw StateError('流式收尾缺少可提交的文本锚点消息');
    }

    final rawMessage = buildResult.rawMessage;
    if (rawMessage == null) {
      throw StateError('流式收尾缺少原始 assistant 消息');
    }
    final finalTimelineMessages = streamDelivery.buildFinalTimelineMessages(
      committedMessages: committedMessages,
      sourceMessageId: rawMessage.id,
    );
    final pendingStreamTtsMessages =
        streamDelivery.pendingAudioPlaceholderMessages(
      sourceMessageId: rawMessage.id,
    );
    await _historyPort.appendAssistantRawMessage(
      conversationId: convId,
      userMessageId: userMsgId,
      rawMessage: rawMessage,
      projectedMessages: finalTimelineMessages,
      lastMessagePreview: finalTimelineMessages.last.displayText,
      updateShortWindow: false,
    );
    await streamDelivery.commitToMessages(finalMessages: finalTimelineMessages);
    await _cleanupProjectedMessagesForRawSource(
      convId: convId,
      rawMessageId: rawMessage.id,
      keepMessages: finalTimelineMessages,
    );
    await _ttsHandler.deliverSegmentedMessages(
      convId: convId,
      userMsgId: userMsgId,
      buildResult: buildResult,
      replyText: replyText,
      pluginEvents: pluginEvents,
      ttsEnabled: ttsEnabled,
      appendAfterStreamText: true,
      streamTextMessageIds: committedMessages
          .map((message) => message.id)
          .toList(growable: false),
      streamPendingTtsMessages: pendingStreamTtsMessages,
      trace: trace,
    );
  }

  Future<T> _runWithProviderRefreshRetry<T>({
    required String entry,
    required String convId,
    required Future<T> Function() task,
    Future<void> Function(int nextAttempt)? beforeRetry,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await task();
      } catch (e, st) {
        final shouldRetry = isProviderRefreshTimingError(e) &&
            attempt < _kProviderRefreshMaxRetries;
        if (!shouldRetry) {
          Error.throwWithStackTrace(e, st);
        }
        attempt += 1;
        AppLogger.info(
          'ChatActions',
          '命中 Provider 刷新窗口，短延迟后重试',
          metadata: {
            'entry': entry,
            'convId': convId,
            'attempt': attempt,
            'retryDelayMs': _kProviderRefreshRetryDelay.inMilliseconds,
          },
        );
        if (beforeRetry != null) {
          await beforeRetry(attempt);
        }
        await Future<void>.delayed(_kProviderRefreshRetryDelay);
      }
    }
  }

  /// 中断当前正在生成的消息（软中断：后续结果会被丢弃，不再落库到会话）。
  /// 默认中断当前激活会话；也可显式传入 [convId]。
  Future<bool> interruptCurrentGeneration({String? convId}) async {
    final targetConvId = convId ?? _ref.read(activeConversationProvider)?.id;
    if (targetConvId == null || targetConvId.trim().isEmpty) return false;
    final task = _activeGenerations[targetConvId];
    if (task == null) return false;

    _activeGenerations.remove(targetConvId);
    final cleanup = _generationInterruptCleanups.remove(targetConvId);
    _setConversationSending(targetConvId, false);
    _setConversationStatus(targetConvId, ChatStatus.idle);
    _setConversationError(targetConvId, null);
    _setConversationFailoverInfo(targetConvId, null);
    _ref.read(modelFailoverPromptProvider.notifier).dismiss(
          defaultDecision: ModelFailoverDecision.cancel,
        );

    if (cleanup != null) {
      try {
        await cleanup();
      } catch (e) {
        AppLogger.warning(
          'ChatActions',
          'interrupt cleanup failed',
          metadata: {
            'convId': targetConvId,
            'error': e.toString(),
          },
        );
      }
    }

    await _markUserMessageAsSent(task);
    _ref.read(analyzerSchedulerProvider).scheduleAnalysis();
    return true;
  }

  Future<ChatSendTurnResult?> _executeTurnCommand({
    required ChatTurnCommand command,
    required Future<AppSettings> Function() loadSettings,
    List<String> Function(AppSettings settings)? resolveModelsToTry,
    Future<ChatPreparedTurn> Function(AppSettings settings)? prepareTurn,
    required ChatFailoverExecutor executeWithFailover,
    Future<void> Function(AppSettings settings)? prepareStreaming,
    required void Function(String toolName) onToolExecuting,
    void Function()? onProcessingResponse,
    required ChatResultDelivery deliverResult,
    required bool Function() isCurrent,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
  }) {
    return _sendUseCase.executeTurn(
      command: command,
      options: ChatTurnExecutionOptions(
        loadSettings: loadSettings,
        prepareTurn: prepareTurn,
        resolveModelsToTry: resolveModelsToTry,
        executeWithFailover: executeWithFailover,
        prepareStreaming: prepareStreaming,
        onToolExecuting: onToolExecuting,
        onProcessingResponse: onProcessingResponse,
        deliverResult: deliverResult,
        isCurrent: isCurrent,
        onStreamTextDelta: onStreamTextDelta,
        onStreamTextReset: onStreamTextReset,
        onStreamToolCallObserved: onStreamToolCallObserved,
        onStreamingFallback: onStreamingFallback,
      ),
    );
  }

  List<String> _resolvePreferredChatModels(AppSettings settings) {
    return settings.defaultChatModels.isNotEmpty
        ? settings.defaultChatModels
        : <String>[settings.defaultModelName];
  }

  // ===== 公开 API =====

  /// 根据工具名称更新聊天进度状态
  void _updateStatusForTool(String convId, String toolName) {
    switch (toolName) {
      case 'draw_image':
        _setConversationStatus(convId, ChatStatus.generatingImage);
      case 'speak':
        _setConversationStatus(convId, ChatStatus.generatingVoice);
      default:
        _setConversationStatus(convId, ChatStatus.toolCalling);
    }
  }

  /// 发送文本消息（支持自动轮询多个默认聊天模型）
  Future<void> send(String text) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null || text.trim().isEmpty) return;
    final convId = conv.id;

    final trace = AppLogger.startTrace('AI消息发送', source: 'ChatActions');
    final userMsg = _sendPort.createUserMessage(text: text, imagePath: null);
    final traceContext = await _startTurnTrace(
      convId: convId,
      turnId: userMsg.id,
      entry: 'send_text',
      meta: {'inputLength': text.length},
    );
    final runId = _startGeneration(convId: convId, userMsgId: userMsg.id);
    await _sendPort.addUserMessage(
        convId: convId, userMsg: userMsg, displayText: text);
    _recordTurnTrace(
      traceContext,
      TraceStage.userMessagePersisted,
      meta: {'hasImage': false},
    );
    if (!_isGenerationCurrent(convId, runId)) return;

    _StreamPlaceholderDelivery? streamDelivery;
    var streamCommitted = false;
    var turnSucceeded = false;
    _setGenerationInterruptCleanup(convId, runId, () async {
      await streamDelivery?.removePlaceholders();
      streamDelivery?.dispose();
    });
    try {
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
          final turnResult = await _executeTurnCommand(
            command: ChatTurnCommand.streaming(
              conversation: conv,
              userMessage: userMsg,
              sessionId: convId,
              apiText: text,
              traceContext: traceContext,
              trace: trace,
            ),
            loadSettings: () => _ref.read(appSettingsProvider.future),
            resolveModelsToTry: _resolvePreferredChatModels,
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
              final streamFinalText = _resolveFinalStreamText(
                apiResult,
                buildResult,
              );
              final shouldCommitStream =
                  streamDelivery!.canFinalizeWith(finalText: streamFinalText);
              final committedMessages = shouldCommitStream
                  ? _extractStreamCommittedMessages(buildResult.messages)
                  : const <Message>[];

              if (shouldCommitStream && committedMessages.isNotEmpty) {
                await streamDelivery!.finalize(
                  finalText: streamFinalText,
                );
                await _commitStreamDelivery(
                  streamDelivery: streamDelivery!,
                  convId: convId,
                  userMsgId: userMsg.id,
                  buildResult: buildResult,
                  replyText: apiResult.rawReplyText,
                  pluginEvents: apiResult.pluginEvents,
                  ttsEnabled: settings.ttsEnabled,
                  trace: trace,
                );
                streamCommitted = true;
                return;
              }

              if (shouldCommitStream && committedMessages.isEmpty) {
                AppLogger.info(
                  'ChatActions',
                  '流式收尾缺少文本锚点，回退到纯多模态补发链路',
                  metadata: {
                    'convId': convId,
                    'pluginEventCount': apiResult.pluginEvents.length,
                    'rawReplyLength': apiResult.rawReplyText.length,
                  },
                );
              }

              await streamDelivery!.removePlaceholders();
              await _ttsHandler.deliverSegmentedMessages(
                convId: convId,
                userMsgId: userMsg.id,
                buildResult: buildResult,
                replyText: apiResult.rawReplyText,
                pluginEvents: apiResult.pluginEvents,
                ttsEnabled: settings.ttsEnabled,
                trace: trace,
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
          turnSucceeded = true;

          trace.end(additionalMessage: '完成');
          _recordTurnTrace(traceContext, TraceStage.turnCompleted);
        },
      );
    } catch (e) {
      await streamDelivery?.removePlaceholders();
      if (!_isGenerationCurrent(convId, runId)) return;
      trace.error('失败', metadata: {'error': e.toString()});
      trace.end(additionalMessage: '失败');
      _recordTurnTrace(
        traceContext,
        TraceStage.turnFailed,
        status: TraceEventStatus.failed,
        meta: {'error': e.toString()},
      );
      await _sendPort.markUserMessageFailed(
          convId: convId, userMsgId: userMsg.id);
      _setConversationError(convId, e.toString());
    } finally {
      if (!streamCommitted) {
        await streamDelivery?.removePlaceholders();
      }
      streamDelivery?.dispose();
      _finishGeneration(
        convId,
        runId,
        clearFailoverInfo: true,
        scheduleAnalysis: true,
      );
      if (!turnSucceeded) {
        // 失败分支会记录 TURN_FAILED，这里避免重复写 TURN_COMPLETED。
      }
    }
  }

  Future<void> sendComposerText(String text) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty) return;

    final quoted = _ref.read(quotedMessageProvider);
    if (quoted == null) {
      await send(normalizedText);
      return;
    }

    _ref.read(quotedMessageProvider.notifier).state = null;
    await send(_composeQuotedSendText(normalizedText, quoted));
  }

  String _composeQuotedSendText(String text, QuotedMessage quoted) {
    final quotedText = quoted.content.length > 30
        ? '${quoted.content.substring(0, 30)}...'
        : quoted.content;
    return '> Quote: $quotedText\n\n$text';
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

  /// 发送图片消息（可附带文字说明，支持图片识别模型 + 轮询）
  Future<void> sendWithImage(String imagePath, {String? text}) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null || imagePath.trim().isEmpty) return;
    final convId = conv.id;

    final userText = text?.trim();
    final hasText = userText != null && userText.isNotEmpty;
    final userMsg = _sendPort.createUserMessage(
      text: hasText ? userText : null,
      imagePath: imagePath,
    );
    final traceContext = await _startTurnTrace(
      convId: convId,
      turnId: userMsg.id,
      entry: 'send_image',
      meta: {'hasText': hasText},
    );
    final runId = _startGeneration(convId: convId, userMsgId: userMsg.id);
    final displayText = hasText ? userText : '[图片]';
    await _sendPort.addUserMessage(
        convId: convId, userMsg: userMsg, displayText: displayText);
    _recordTurnTrace(
      traceContext,
      TraceStage.userMessagePersisted,
      meta: {'hasImage': true},
    );
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
            resolveModelsToTry: _sendPort.buildImageSendModelRefs,
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
            onProcessingResponse: () =>
                _setConversationStatus(convId, ChatStatus.processingResponse),
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
    } catch (e) {
      if (!_isGenerationCurrent(convId, runId)) return;
      _recordTurnTrace(
        traceContext,
        TraceStage.turnFailed,
        status: TraceEventStatus.failed,
        meta: {'error': e.toString()},
      );
      await _sendPort.markUserMessageFailed(
          convId: convId, userMsgId: userMsg.id);
      _setConversationError(convId, e.toString());
    } finally {
      _finishGeneration(
        convId,
        runId,
        clearFailoverInfo: true,
        scheduleAnalysis: true,
      );
      if (!turnSucceeded) {
        // 已在 catch 记录 TURN_FAILED。
      }
    }
  }

  /// 发送文件消息（目前按"文本文件附件"发送，供 AI 阅读）
  Future<void> sendWithFile(String filePath) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null || filePath.trim().isEmpty) return;
    final convId = conv.id;

    final userMsg = await _sendPort.createUserFileMessage(filePath: filePath);
    final traceContext = await _startTurnTrace(
      convId: convId,
      turnId: userMsg.id,
      entry: 'send_file',
    );
    final runId = _startGeneration(convId: convId, userMsgId: userMsg.id);
    await _sendPort.addUserMessage(
        convId: convId, userMsg: userMsg, displayText: '[文件]');
    _recordTurnTrace(
      traceContext,
      TraceStage.userMessagePersisted,
      meta: {'hasFile': true},
    );
    if (!_isGenerationCurrent(convId, runId)) return;

    var turnSucceeded = false;
    try {
      await _runWithProviderRefreshRetry<void>(
        entry: 'send_file',
        convId: convId,
        task: () async {
          final turnResult = await _executeTurnCommand(
            command: ChatTurnCommand.nonStreaming(
              conversation: conv,
              userMessage: userMsg,
              sessionId: convId,
              apiText: '[file]',
              traceContext: traceContext,
            ),
            loadSettings: () => _ref.read(appSettingsProvider.future),
            resolveModelsToTry: (settings) =>
                settings.defaultChatModels.isNotEmpty
                    ? settings.defaultChatModels
                    : <String>[settings.defaultModelName],
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
            onProcessingResponse: () =>
                _setConversationStatus(convId, ChatStatus.processingResponse),
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
    } catch (e) {
      if (!_isGenerationCurrent(convId, runId)) return;
      _recordTurnTrace(
        traceContext,
        TraceStage.turnFailed,
        status: TraceEventStatus.failed,
        meta: {'error': e.toString()},
      );
      await _sendPort.markUserMessageFailed(
          convId: convId, userMsgId: userMsg.id);
      _setConversationError(convId, e.toString());
    } finally {
      _finishGeneration(
        convId,
        runId,
        clearFailoverInfo: true,
        scheduleAnalysis: true,
      );
      if (!turnSucceeded) {
        // 已在 catch 记录 TURN_FAILED。
      }
    }
  }

  /// 主动触发器发送
  /// 注意：作废检查已在 AutoReplyTriggerController._pollDueTriggers() 中完成
  /// 此方法被调用时，触发器已确认可以触发

  List<Message> _buildSnapshotHistory(String? contextSnapshot) {
    if (contextSnapshot == null || contextSnapshot.trim().isEmpty) {
      return const <Message>[];
    }
    try {
      final decoded = jsonDecode(contextSnapshot);
      if (decoded is! List) return const <Message>[];

      final now = DateTime.now();
      final history = <Message>[];
      for (var i = 0; i < decoded.length; i++) {
        final raw = decoded[i];
        if (raw is! Map) continue;
        final map = Map<String, dynamic>.from(raw.cast<String, dynamic>());
        final role = (map['role'] as String?) ?? 'user';
        final content = _extractSnapshotText(map['content']);
        if (content.trim().isEmpty) continue;
        history.add(Message(
          id: 'snapshot_$i',
          role: role,
          content: content,
          createdAt: now,
          status: 'sent',
        ));
      }
      return history;
    } catch (_) {
      return const <Message>[];
    }
  }

  String _extractSnapshotText(dynamic rawContent) {
    if (rawContent is String) return rawContent;
    if (rawContent is! List) return '';

    final texts = <String>[];
    for (final part in rawContent) {
      if (part is! Map) continue;
      final map = Map<String, dynamic>.from(part.cast<String, dynamic>());
      if (map['type'] != 'text') continue;
      final text = (map['text'] as String?) ?? '';
      if (text.isNotEmpty) {
        texts.add(text);
      }
    }
    return texts.join('\n');
  }

  /// 重发失败的消息

  /// 应用切后台时调用
  /// 委托给 AnalyzerScheduler 处理后台分析逻辑
  void onAppBackground() {
    _ref.read(analyzerSchedulerProvider).onAppBackground();
  }

  // ===== 内部：模型轮询 =====

  /// 按模型列表顺序尝试发送，失败后自动切换下一个模型
  /// 返回 (API调用结果, 使用的设置)
  Future<(ApiCallResult, AppSettings)> _executeWithFailover({
    required String convId,
    required List<String> modelsToTry,
    required Future<ApiConfig> Function(String model) buildConfig,
    required Future<ApiCallResult> Function(ApiConfig config) execute,
    required AppSettings settings,
  }) async {
    // 只有一个模型时，直接调用不做轮询
    if (modelsToTry.length <= 1) {
      final model = modelsToTry.isNotEmpty
          ? modelsToTry.first
          : settings.defaultModelName;
      final config = await buildConfig(model);
      final result = await execute(config);
      return (result, settings);
    }

    Object? lastError;
    var index = 0;
    while (index < modelsToTry.length) {
      final model = modelsToTry[index];
      try {
        final config = await buildConfig(model);
        final result = await execute(config);
        // 成功，清除轮询通知
        _setConversationFailoverInfo(convId, null);
        return (result, settings);
      } catch (e, st) {
        if (isProviderRefreshTimingError(e)) {
          AppLogger.info(
            'ChatActions',
            '模型 $model 在本地组装阶段命中 Provider 刷新窗口，交由外层统一重试',
            metadata: {
              'failedModel': model,
              'attempt': index + 1,
              'total': modelsToTry.length,
            },
          );
          Error.throwWithStackTrace(e, st);
        }
        lastError = e;
        AppLogger.warning('ChatActions', '模型 $model 调用失败，等待用户决定后续动作',
            metadata: {
              'failedModel': model,
              'attempt': index + 1,
              'total': modelsToTry.length,
              'error': e.toString(),
            });

        // 还有下一个模型可以尝试
        if (index < modelsToTry.length - 1) {
          final nextModel = modelsToTry[index + 1];
          final decision = await _requestModelFailoverDecision(
            convId: convId,
            failedModel: model,
            nextModel: nextModel,
            settings: settings,
            error: e,
          );
          if (decision == ModelFailoverDecision.retryCurrent) {
            AppLogger.info('ChatActions', '用户选择重试当前模型', metadata: {
              'model': model,
              'attempt': index + 1,
            });
            continue;
          }
          if (decision == ModelFailoverDecision.cancel) {
            throw StateError('模型切换已取消');
          }
          AppLogger.info('ChatActions', '用户选择尝试下一个模型', metadata: {
            'failedModel': model,
            'nextModel': nextModel,
            'attempt': index + 1,
          });
          index += 1;
          continue;
        }
      }
      index += 1;
    }

    // 所有模型都失败了，抛出最后一个错误
    throw lastError!;
  }
}

class _GenerationTask {
  final int id;
  final String convId;
  final String? userMsgId;

  const _GenerationTask({
    required this.id,
    required this.convId,
    required this.userMsgId,
  });
}

final chatActionsProvider = Provider((ref) => ChatActions(ref));

/// 编辑消息时需要填充到输入框的文本（用于 Composer 监听）
final editingTextProvider = StateProvider<String?>((ref) => null);

/// 失败消息撤回时需要恢复到 Composer 的附件（用于附件预览回填）
final recalledAttachmentProvider =
    StateProvider<SelectedAttachment?>((ref) => null);

/// 引用消息数据
class QuotedMessage {
  final String id;
  final String content;
  final bool isUser;

  const QuotedMessage({
    required this.id,
    required this.content,
    required this.isUser,
  });
}

/// 当前被引用的消息（用于 Composer 显示预览）
final quotedMessageProvider = StateProvider<QuotedMessage?>((ref) => null);
