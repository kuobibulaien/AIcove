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
import 'id_gen.dart' show genId;
import 'services/chat_send_service.dart';
import 'services/chat_types.dart'
    show ApiCallResult, AssistantMessageBuildResult;
import 'services/chat_tts_handler.dart';
import 'domain/conversation.dart';
import 'domain/message.dart';
import '../settings/app_settings.dart';
import 'conversation_providers.dart';
import 'conversation_timeline_providers.dart';
import 'chat_providers.dart';
import '../../core/app_logger.dart';
import '../../core/database/database_provider.dart';
import '../../core/models/message_block.dart';
import '../../core/models/block_status.dart';
import '../../core/services/attachment_picker_service.dart';
import '../../core/utils/message_formatter.dart';
import '../observability/trace_models.dart';
import '../observability/trace_store.dart';
import 'services/chat_history_store.dart';

// 重新导出公共类型，保持向后兼容
export 'chat_providers.dart';
export 'services/chat_types.dart';
export 'services/chat_send_service.dart'
    show ChatSendService, ApiCallResult, ApiConfig, SendRequest;
export 'services/chat_tts_handler.dart' show ChatTtsHandler;

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

class ChatActions {
  static const Duration _kProviderRefreshRetryDelay =
      Duration(milliseconds: 120);
  static const int _kProviderRefreshMaxRetries = 1;

  ChatActions(this._ref);

  final Ref _ref;
  ChatSendService get _sendService => _ref.read(chatSendServiceProvider);
  ChatTtsHandler get _ttsHandler => _ref.read(chatTtsHandlerProvider);
  ChatHistoryStore get _historyStore => _ref.read(chatHistoryStoreProvider);
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
    return _historyStore.loadAllMessages(convId);
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
      if (!_isProviderRefreshTimingError(e)) {
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

    await _historyStore.markMessageStatus(
      conversationId: task.convId,
      messageId: userMsgId,
      status: 'sent',
    );
  }

  bool _isProviderRefreshTimingError(Object error) {
    final message = error.toString();
    return message.contains(
          'Cannot use ref functions after the dependency of a provider changed but before the provider rebuilt',
        ) ||
        message.contains('!_didChangeDependency');
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
        final shouldRetry = _isProviderRefreshTimingError(e) &&
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
    final userMsg = _sendService.createUserMessage(text: text, imagePath: null);
    final traceContext = await _startTurnTrace(
      convId: convId,
      turnId: userMsg.id,
      entry: 'send_text',
      meta: {'inputLength': text.length},
    );
    final runId = _startGeneration(convId: convId, userMsgId: userMsg.id);
    await _sendService.addUserMessage(
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
      final settings = await _ref.read(appSettingsProvider.future);
      if (!_isGenerationCurrent(convId, runId)) return;
      final history = await _sendService.prepareHistoryFromStore(
        conv: conv,
        userMsg: userMsg,
        limit: settings.historyMessageLimit,
      );
      streamDelivery = _StreamPlaceholderDelivery(
        _ref,
        convId: convId,
        userMsgId: userMsg.id,
        formatConfig: settings.messageFormatConfig,
        enableTtsPlaceholders: settings.ttsEnabled,
        segmentDelay: Duration(
          milliseconds: (settings.streamSegmentDelaySeconds * 1000).round(),
        ),
      );
      await streamDelivery.start();

      // 构建轮询模型列表：defaultChatModels > defaultModelName
      final modelsToTry = settings.defaultChatModels.isNotEmpty
          ? settings.defaultChatModels
          : [settings.defaultModelName];

      final (result, usedSettings) = await _executeWithFailover(
        convId: convId,
        modelsToTry: modelsToTry,
        buildConfig: (model) => _sendService.prepareApiConfig(
          conv: conv,
          history: history,
          userText: text,
          trace: trace,
          overrideModel: model,
          traceContext: traceContext,
        ),
        execute: (config) => _sendService.executeApiCall(
          config: config,
          sessionId: convId,
          userText: text,
          turnId: userMsg.id,
          trace: trace,
          onToolExecuting: (toolName) => _updateStatusForTool(convId, toolName),
          enableStreaming: true,
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
        ),
        settings: settings,
      );
      if (!_isGenerationCurrent(convId, runId)) return;

      _setConversationStatus(convId, ChatStatus.processingResponse);
      final buildResult = _sendService.buildAssistantMessages(
          apiResult: result, settings: usedSettings);
      if (!_isGenerationCurrent(convId, runId)) return;

      final streamFinalText = _resolveFinalStreamText(
        result,
        buildResult,
      );
      final shouldCommitStream =
          streamDelivery.canFinalizeWith(finalText: streamFinalText);

      if (shouldCommitStream) {
        await streamDelivery.finalize(
          finalText: streamFinalText,
        );
        final streamCommit = await streamDelivery.commitFinalTimeline(
            finalText: streamFinalText);
        await _ttsHandler.deliverSegmentedMessages(
          convId: convId,
          userMsgId: userMsg.id,
          buildResult: buildResult,
          replyText: result.replyText,
          pluginEvents: result.pluginEvents,
          ttsEnabled: usedSettings.ttsEnabled,
          appendAfterStreamText: true,
          streamTextMessageIds: streamCommit.textMessageIds,
          streamPendingTtsMessages: streamCommit.pendingTtsMessages,
          trace: trace,
        );
        streamCommitted = true;
      } else {
        await streamDelivery.removePlaceholders();
        // 统一的消息交付入口：自动处理 TTS 分段发送
        await _ttsHandler.deliverSegmentedMessages(
          convId: convId,
          userMsgId: userMsg.id,
          buildResult: buildResult,
          replyText: result.replyText,
          pluginEvents: result.pluginEvents,
          ttsEnabled: usedSettings.ttsEnabled,
          trace: trace,
        );
      }
      if (!_isGenerationCurrent(convId, runId)) return;
      _recordTurnTrace(
        traceContext,
        TraceStage.messageDelivered,
        meta: {
          'assistantMessageCount': buildResult.messages.length,
          'streamCommitted': shouldCommitStream,
        },
      );
      turnSucceeded = true;

      trace.end(additionalMessage: '完成');
      _recordTurnTrace(traceContext, TraceStage.turnCompleted);
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
      await _sendService.markUserMessageFailed(
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
    final userMsg = _sendService.createUserMessage(
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
    await _sendService.addUserMessage(
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
          final settings = await _ref.read(appSettingsProvider.future);
          if (!_isGenerationCurrent(convId, runId)) return;
          final history = await _sendService.prepareHistoryFromStore(
            conv: conv,
            userMsg: userMsg,
            limit: settings.historyMessageLimit,
          );
          final apiText = hasText ? userText : '[image]';

          final modelsToTry = _sendService.buildImageSendModelRefs(settings);

          final (result, usedSettings) = await _executeWithFailover(
            convId: convId,
            modelsToTry: modelsToTry,
            buildConfig: (model) => _sendService.prepareApiConfig(
              conv: conv,
              history: history,
              userText: apiText,
              overrideModel: model,
              traceContext: traceContext,
            ),
            execute: (config) => _sendService.executeApiCall(
              config: config,
              sessionId: convId,
              userText: apiText,
              turnId: userMsg.id,
              onToolExecuting: (toolName) =>
                  _updateStatusForTool(convId, toolName),
            ),
            settings: settings,
          );
          if (!_isGenerationCurrent(convId, runId)) return;

          _setConversationStatus(convId, ChatStatus.processingResponse);
          final buildResult = _sendService.buildAssistantMessages(
              apiResult: result, settings: usedSettings);
          if (!_isGenerationCurrent(convId, runId)) return;

          await _ttsHandler.deliverSegmentedMessages(
            convId: convId,
            userMsgId: userMsg.id,
            buildResult: buildResult,
            replyText: result.replyText,
            pluginEvents: result.pluginEvents,
            ttsEnabled: usedSettings.ttsEnabled,
          );
          if (!_isGenerationCurrent(convId, runId)) return;
          _recordTurnTrace(
            traceContext,
            TraceStage.messageDelivered,
            meta: {'assistantMessageCount': buildResult.messages.length},
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
      await _sendService.markUserMessageFailed(
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

    final userMsg =
        await _sendService.createUserFileMessage(filePath: filePath);
    final traceContext = await _startTurnTrace(
      convId: convId,
      turnId: userMsg.id,
      entry: 'send_file',
    );
    final runId = _startGeneration(convId: convId, userMsgId: userMsg.id);
    await _sendService.addUserMessage(
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
          final settings = await _ref.read(appSettingsProvider.future);
          if (!_isGenerationCurrent(convId, runId)) return;
          final history = await _sendService.prepareHistoryFromStore(
            conv: conv,
            userMsg: userMsg,
            limit: settings.historyMessageLimit,
          );
          final config = await _sendService.prepareApiConfig(
              conv: conv,
              history: history,
              userText: '[file]',
              traceContext: traceContext);
          if (!_isGenerationCurrent(convId, runId)) return;
          final result = await _sendService.executeApiCall(
              config: config,
              sessionId: convId,
              userText: '[file]',
              turnId: userMsg.id,
              onToolExecuting: (toolName) =>
                  _updateStatusForTool(convId, toolName));
          if (!_isGenerationCurrent(convId, runId)) return;
          _setConversationStatus(convId, ChatStatus.processingResponse);
          final buildResult = _sendService.buildAssistantMessages(
              apiResult: result, settings: settings);
          if (!_isGenerationCurrent(convId, runId)) return;

          await _ttsHandler.deliverSegmentedMessages(
            convId: convId,
            userMsgId: userMsg.id,
            buildResult: buildResult,
            replyText: result.replyText,
            pluginEvents: result.pluginEvents,
            ttsEnabled: settings.ttsEnabled,
          );
          if (!_isGenerationCurrent(convId, runId)) return;
          _recordTurnTrace(
            traceContext,
            TraceStage.messageDelivered,
            meta: {'assistantMessageCount': buildResult.messages.length},
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
      await _sendService.markUserMessageFailed(
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
  Future<ProactiveSendResult> sendProactiveTrigger(
      AutoReplyTrigger trigger) async {
    final settings = await _ref.read(appSettingsProvider.future);
    if (!settings.autoReplySettings.enabled) {
      AppLogger.info(
          'ChatActions', 'Skip proactive trigger: auto-reply disabled',
          metadata: {
            'triggerId': trigger.id,
          });
      return const ProactiveSendResult.skipped('auto_reply_disabled');
    }

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
      if (trigger.hasCachedContent) {
        final cachedReply = trigger.cachedContent!.trim();
        if (cachedReply.isNotEmpty) {
          final cachedResult = ApiCallResult(
            replyText: cachedReply,
            processedText: cachedReply,
            pluginEvents: const [],
            toolResults: const [],
          );
          final buildResult = _sendService.buildAssistantMessages(
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
      final snapshotHistory = _buildSnapshotHistory(trigger.contextSnapshot);
      final history = snapshotHistory.isNotEmpty
          ? snapshotHistory
          : await _loadConversationMessages(targetConvId);
      final config = await _sendService.prepareApiConfig(
        conv: conv,
        history: history,
        userText: proactiveInput,
        conversationId: targetConvId,
        traceContext: traceContext,
      );
      final result = await _sendService.executeApiCall(
        config: config,
        sessionId: targetConvId,
        userText: proactiveInput,
        turnId: 'trigger_${trigger.id}',
      );
      final buildResult = _sendService.buildAssistantMessages(
          apiResult: result, settings: settings);

      // 触发器没有 userMsgId，使用空字符串
      await _ttsHandler.deliverSegmentedMessages(
        convId: targetConvId,
        userMsgId: '', // 触发器发送没有对应的用户消息
        buildResult: buildResult,
        replyText: result.replyText,
        pluginEvents: result.pluginEvents,
        ttsEnabled: settings.ttsEnabled,
      );
      _recordTurnTrace(
        traceContext,
        TraceStage.messageDelivered,
        meta: {'assistantMessageCount': buildResult.messages.length},
      );
      _recordTurnTrace(traceContext, TraceStage.turnCompleted);

      AppLogger.info('ChatActions', '触发器发送成功', metadata: {
        'triggerId': trigger.id,
        'title': trigger.title,
      });
      return const ProactiveSendResult.success();
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

    await _historyStore.markMessageStatus(
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
          final settings = await _ref.read(appSettingsProvider.future);
          if (!_isGenerationCurrent(convId, runId)) return;
          final msgIndex = messages.indexWhere((m) => m.id == messageId);
          final rawHistory =
              msgIndex > 0 ? messages.sublist(0, msgIndex + 1) : messages;
          final history = rawHistory
              .where((m) => m.status != 'failed' || m.id == messageId)
              .toList();

          streamDelivery = _StreamPlaceholderDelivery(
            _ref,
            convId: convId,
            userMsgId: messageId,
            formatConfig: settings.messageFormatConfig,
            enableTtsPlaceholders: settings.ttsEnabled,
            segmentDelay: Duration(
              milliseconds: (settings.streamSegmentDelaySeconds * 1000).round(),
            ),
          );
          await streamDelivery!.start();

          final config = await _sendService.prepareApiConfig(
              conv: conv,
              history: history,
              userText: failedMsg.displayText,
              traceContext: traceContext);
          if (!_isGenerationCurrent(convId, runId)) return;
          final result = await _sendService.executeApiCall(
            config: config,
            sessionId: convId,
            userText: failedMsg.displayText,
            turnId: messageId,
            onToolExecuting: (toolName) =>
                _updateStatusForTool(convId, toolName),
            enableStreaming: true,
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
          if (!_isGenerationCurrent(convId, runId)) return;
          _setConversationStatus(convId, ChatStatus.processingResponse);
          final buildResult = _sendService.buildAssistantMessages(
              apiResult: result, settings: settings);
          if (!_isGenerationCurrent(convId, runId)) return;

          await _historyStore.markMessageStatus(
            conversationId: convId,
            messageId: messageId,
            status: 'sent',
          );
          if (!_isGenerationCurrent(convId, runId)) return;

          final streamFinalText = _resolveFinalStreamText(result, buildResult);
          final shouldCommitStream =
              streamDelivery!.canFinalizeWith(finalText: streamFinalText);

          if (shouldCommitStream) {
            await streamDelivery!.finalize(finalText: streamFinalText);
            final streamCommit = await streamDelivery!.commitFinalTimeline(
              finalText: streamFinalText,
            );
            await _ttsHandler.deliverSegmentedMessages(
              convId: convId,
              userMsgId: messageId,
              buildResult: buildResult,
              replyText: result.replyText,
              pluginEvents: result.pluginEvents,
              ttsEnabled: settings.ttsEnabled,
              appendAfterStreamText: true,
              streamTextMessageIds: streamCommit.textMessageIds,
              streamPendingTtsMessages: streamCommit.pendingTtsMessages,
            );
            streamCommitted = true;
          } else {
            await streamDelivery!.removePlaceholders();
            await _ttsHandler.deliverSegmentedMessages(
              convId: convId,
              userMsgId: messageId,
              buildResult: buildResult,
              replyText: result.replyText,
              pluginEvents: result.pluginEvents,
              ttsEnabled: settings.ttsEnabled,
            );
          }
          if (!_isGenerationCurrent(convId, runId)) return;
          _recordTurnTrace(
            traceContext,
            TraceStage.messageDelivered,
            meta: {
              'assistantMessageCount': buildResult.messages.length,
              'streamCommitted': shouldCommitStream,
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
      await _historyStore.markMessageStatus(
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

  /// 增强重新生成（使用增强上下文拼接）
  Future<void> regenerateWithEnhancement(String aiMessageId) async {
    await _regenerateInternal(aiMessageId, useEnhancement: true);
  }

  Future<void> _regenerateInternal(
    String aiMessageId, {
    required bool useEnhancement,
  }) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return;
    final convId = conv.id;
    final messages = await _loadConversationMessages(convId);

    // 找到要重新生成的AI消息索引
    final msgIndex = messages.indexWhere((m) => m.id == aiMessageId);
    if (msgIndex < 0) return;

    // 找到该AI消息对应的用户消息（通常是前一条）
    int userMsgIndex = msgIndex - 1;
    while (userMsgIndex >= 0 && messages[userMsgIndex].role != 'user') {
      userMsgIndex--;
    }
    if (userMsgIndex < 0) return;

    final userMsg = messages[userMsgIndex];
    final userText = userMsg.displayText;
    final traceContext = await _startTurnTrace(
      convId: convId,
      turnId: userMsg.id,
      entry: useEnhancement ? 'regenerate_enhanced' : 'regenerate',
      meta: {'targetAiMessageId': aiMessageId},
    );

    final runId = _startGeneration(convId: convId, userMsgId: userMsg.id);

    // 收集被移除的消息 ID，用于数据库软删除
    await _historyStore.truncateAfterMessage(
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
          final settings = await _ref.read(appSettingsProvider.future);
          if (!_isGenerationCurrent(convId, runId)) return;
          final updatedConv = _ref.read(activeConversationProvider)!;
          final bool canUseEnhancement =
              useEnhancement && settings.enhancedDialogueSettings.enabled;

          late final List<Message> history;
          late final String sessionId;
          late final Conversation requestConv;
          if (canUseEnhancement) {
            final persistedMessages =
                await _sendService.loadConversationMessagesFromStore(
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
            history = enhancedContext.history;
            sessionId = enhancedContext.sessionId;
            requestConv = enhancedContext.conversation;
          } else {
            history = await _sendService.prepareHistoryFromStore(
              conv: updatedConv,
              userMsg: userMsg,
              limit: settings.historyMessageLimit,
            );
            sessionId = convId;
            requestConv = updatedConv;
          }

          streamDelivery = _StreamPlaceholderDelivery(
            _ref,
            convId: convId,
            userMsgId: userMsg.id,
            formatConfig: settings.messageFormatConfig,
            enableTtsPlaceholders: settings.ttsEnabled,
            segmentDelay: Duration(
              milliseconds: (settings.streamSegmentDelaySeconds * 1000).round(),
            ),
          );
          await streamDelivery!.start();

          final config = await _sendService.prepareApiConfig(
            conv: requestConv,
            history: history,
            userText: userText,
            traceContext: traceContext,
          );
          if (!_isGenerationCurrent(convId, runId)) return;
          final rawResult = await _sendService.executeApiCall(
            config: config,
            sessionId: sessionId,
            userText: userText,
            turnId: userMsg.id,
            onToolExecuting: (toolName) =>
                _updateStatusForTool(convId, toolName),
            enableStreaming: true,
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
          if (!_isGenerationCurrent(convId, runId)) return;

          final result = (() {
            if (!canUseEnhancement) return rawResult;
            final enhancedText = _enhancedDialogueService.extractEnhancedText(
              processedText: rawResult.processedText,
              rawReplyText: rawResult.replyText,
            );
            return ApiCallResult(
              replyText: enhancedText,
              processedText: enhancedText,
              pluginEvents: rawResult.pluginEvents,
              pluginContents: rawResult.pluginContents,
              toolResults: rawResult.toolResults,
              toolAudioResults: rawResult.toolAudioResults,
              toolCalls: rawResult.toolCalls,
              rawToolResults: rawResult.rawToolResults,
            );
          })();

          _setConversationStatus(convId, ChatStatus.processingResponse);
          final buildResult = _sendService.buildAssistantMessages(
              apiResult: result, settings: settings);
          if (!_isGenerationCurrent(convId, runId)) return;

          final streamFinalText = _resolveFinalStreamText(result, buildResult);
          final shouldCommitStream =
              streamDelivery!.canFinalizeWith(finalText: streamFinalText);

          if (shouldCommitStream) {
            await streamDelivery!.finalize(finalText: streamFinalText);
            final streamCommit = await streamDelivery!.commitFinalTimeline(
              finalText: streamFinalText,
            );
            await _ttsHandler.deliverSegmentedMessages(
              convId: convId,
              userMsgId: userMsg.id,
              buildResult: buildResult,
              replyText: result.replyText,
              pluginEvents: result.pluginEvents,
              ttsEnabled: settings.ttsEnabled,
              appendAfterStreamText: true,
              streamTextMessageIds: streamCommit.textMessageIds,
              streamPendingTtsMessages: streamCommit.pendingTtsMessages,
            );
            streamCommitted = true;
          } else {
            await streamDelivery!.removePlaceholders();
            await _ttsHandler.deliverSegmentedMessages(
              convId: convId,
              userMsgId: userMsg.id,
              buildResult: buildResult,
              replyText: result.replyText,
              pluginEvents: result.pluginEvents,
              ttsEnabled: settings.ttsEnabled,
            );
          }
          if (!_isGenerationCurrent(convId, runId)) return;
          _recordTurnTrace(
            traceContext,
            TraceStage.messageDelivered,
            meta: {
              'assistantMessageCount': buildResult.messages.length,
              'streamCommitted': shouldCommitStream,
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

    await _historyStore.softDeleteMessages(
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

    await _historyStore.truncateFromMessage(
      conversationId: convId,
      fromMessageId: messageId,
    );

    return text;
  }

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
    for (var i = 0; i < modelsToTry.length; i++) {
      final model = modelsToTry[i];
      try {
        final config = await buildConfig(model);
        final result = await execute(config);
        // 成功，清除轮询通知
        _setConversationFailoverInfo(convId, null);
        return (result, settings);
      } catch (e) {
        lastError = e;
        AppLogger.warning('ChatActions', '模型 $model 调用失败，尝试下一个', metadata: {
          'failedModel': model,
          'attempt': i + 1,
          'total': modelsToTry.length,
          'error': e.toString(),
        });

        // 还有下一个模型可以尝试
        if (i < modelsToTry.length - 1) {
          final nextModel = modelsToTry[i + 1];
          final displayName = settings.getModelDisplayName(nextModel);
          _setConversationFailoverInfo(convId, displayName);
        }
      }
    }

    // 所有模型都失败了，抛出最后一个错误
    throw lastError!;
  }

  /// 在数据库中软删除指定的消息（及其内容块）
  Future<void> _softDeleteMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final msgRepo = _ref.read(messageRepositoryProvider);
    final blockRepo = _ref.read(messageBlockRepositoryProvider);
    final now = DateTime.now().millisecondsSinceEpoch;
    final purgeAt = now + 30 * 24 * 60 * 60 * 1000; // 30天后物理清除

    final blocks = await blockRepo.getByMessages(messageIds);
    for (final block in blocks) {
      await blockRepo.softDelete(block.id, now);
    }

    for (final id in messageIds) {
      await msgRepo.softDelete(id, now, purgeAt);
    }
  }
}

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
    await _ref.read(chatHistoryStoreProvider).appendAssistantMessages(
          conversationId: convId,
          userMessageId: userMsgId.trim(),
          messages: committedMessages,
          lastMessagePreview: committedMessages.last.displayText,
        );
    await removePlaceholders();
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
    await _setTransientMessages(const <Message>[]);
    _currentTimelineMessages.clear();
    _rawStreamText.clear();
    _finalizedRawText = null;
    _receivedDelta = false;
    _fallbackTriggered = false;
    _timelineBaseMs = null;
    _timelineTick = 0;
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
    final sourceRaw = finalize
        ? (_finalizedRawText ?? _rawStreamText.toString())
        : _rawStreamText.toString();
    final messages = _materializeTimeline(
      _buildTimelineDescriptors(sourceRaw, finalize: finalize),
    );
    _currentTimelineMessages
      ..clear()
      ..addAll(messages);
    await _setTransientMessages(messages);
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

  Future<void> _setTransientMessages(List<Message> messages) {
    return _enqueue(() async {
      _ref
          .read(conversationTransientTimelineProvider(convId).notifier)
          .setMessages(messages);
    });
  }

  List<String> snapshotPlaceholderIds() => <String>[
        for (final message in _currentTimelineMessages) message.id,
      ];
}

class _LegacyStreamPlaceholderDelivery {
  _LegacyStreamPlaceholderDelivery(
    this._ref, {
    required this.convId,
    required this.userMsgId,
    required this.formatConfig,
    this.segmentDelay = Duration.zero,
  });

  static const String _kGeneratingText = '生成中...';
  static const Duration _kFlushInterval = Duration(milliseconds: 180);

  final Ref _ref;
  final String convId;
  final String userMsgId;
  final MessageFormatConfig formatConfig;
  final Duration segmentDelay;

  final List<Message> _sealedMessages = <Message>[];
  final List<String> _sealedChunks = <String>[];
  final List<String> _pendingSealedChunks = <String>[];
  final StringBuffer _activeChunkText = StringBuffer();
  final StringBuffer _rawStreamText = StringBuffer();

  Message? _activeMessage;
  String _lastVisibleText = '';
  int? _timelineBaseMs;
  int _timelineTick = 0;
  Future<void> _queue = Future<void>.value();
  Timer? _flushTimer;
  Timer? _segmentDelayTimer;
  bool _dirty = false;
  bool _disposed = false;
  bool _receivedDelta = false;
  bool _fallbackTriggered = false;

  Future<void> start() async {
    if (_disposed) return;
    await _applyState(finalize: false);
  }

  void onDelta(String delta) {
    if (_disposed) return;
    final value = delta;
    if (value.isEmpty) return;
    _rawStreamText.write(value);
    final visibleText = _sanitizeStreamDisplayText(_rawStreamText.toString());
    if (_lastVisibleText.isNotEmpty &&
        !visibleText.startsWith(_lastVisibleText)) {
      _setFromVisibleText(visibleText);
    } else {
      final visibleDelta = visibleText.substring(_lastVisibleText.length);
      if (formatConfig.enableChunking) {
        _activeChunkText.write(visibleDelta);
        _sealCompletedChunks();
      } else {
        _activeChunkText
          ..clear()
          ..write(visibleText);
      }
    }
    _lastVisibleText = visibleText;
    _receivedDelta = true;
    _dirty = true;
    _scheduleFlush();
  }

  void onStreamReset() {
    if (_disposed) return;
    _resetStreamState();
    _dirty = true;
    _scheduleFlush(forceNow: true);
  }

  void onToolCallObserved() {
    if (_disposed) return;
    // 工具调用后保留已流出的文本，避免“先显示再整段撤回”的闪烁体验。
  }

  void onStreamingFallback() {
    if (_disposed) return;
    // 多轮工具链中，后续轮次可能流式失败并回退非流式。
    // 若本轮之前已经收到过 delta，仍应保留已流出文本，避免“全部缩回重发”。
    if (_receivedDelta) return;
    _fallbackTriggered = true;
  }

  bool canFinalizeWith(
    AssistantMessageBuildResult buildResult, {
    required String finalText,
  }) {
    final effectiveFinalText = _resolveEffectiveFinalText(finalText);
    return !_disposed &&
        _receivedDelta &&
        !_fallbackTriggered &&
        buildResult.messages.isNotEmpty &&
        effectiveFinalText.trim().isNotEmpty;
  }

  Future<void> finalize({required String finalText}) async {
    if (_disposed) return;
    final effectiveFinalText = _resolveEffectiveFinalText(finalText);
    if (effectiveFinalText.trim().isEmpty) return;
    _fallbackTriggered = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_hasSegmentDelay && formatConfig.enableChunking) {
      await _finalizeWithoutReplay(effectiveFinalText);
      return;
    }
    _setFromFinalText(effectiveFinalText);
    _dirty = false;
    await _applyState(finalize: true);
  }

  Future<List<String>> commitFinalTextAsMessages({
    required String finalText,
  }) async {
    if (_disposed) return const <String>[];
    final effectiveFinalText = _resolveEffectiveFinalText(finalText);
    if (_sanitizeStreamDisplayText(effectiveFinalText).trim().isEmpty) {
      await removePlaceholders();
      return const <String>[];
    }
    if (_sealedMessages.isEmpty) {
      _setFromFinalText(effectiveFinalText);
      await _applyState(finalize: true);
    }
    final committedMessages =
        List<Message>.from(_sealedMessages, growable: false);
    if (committedMessages.isEmpty) {
      await removePlaceholders();
      return const <String>[];
    }
    if (userMsgId.trim().isNotEmpty) {
      await _ref.read(chatHistoryStoreProvider).appendAssistantMessages(
            conversationId: convId,
            userMessageId: userMsgId,
            messages: committedMessages,
            lastMessagePreview: committedMessages.last.displayText,
          );
    } else {
      await _ref.read(chatHistoryStoreProvider).appendAssistantMessages(
            conversationId: convId,
            userMessageId: '',
            messages: committedMessages,
            lastMessagePreview: committedMessages.last.displayText,
          );
    }
    await removePlaceholders();
    return committedMessages
        .map((message) => message.id)
        .toList(growable: false);
  }

  String _resolveEffectiveFinalText(String finalText) {
    final candidate = finalText.trim();
    if (candidate.isNotEmpty) {
      return finalText;
    }
    final streamed = _rawStreamText.toString();
    if (streamed.trim().isNotEmpty) {
      return streamed;
    }
    return finalText;
  }

  Future<void> removePlaceholders() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirty = false;
    await _setTransientMessages(const <Message>[]);
    _resetTextBuffers();
    _receivedDelta = false;
    _fallbackTriggered = false;
  }

  void dispose() {
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _segmentDelayTimer?.cancel();
    _segmentDelayTimer = null;
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
    // _applyState 内部已经串行入队，这里再包一层 _enqueue 会造成队列自等待死锁。
    unawaited(_applyState(finalize: false));
  }

  Future<void> _applyState({required bool finalize}) async {
    if (_disposed) return;
    await _setTransientMessages(_buildTimelineMessages(finalize: finalize));
  }

  List<Message> _buildTimelineMessages({required bool finalize}) {
    final sealedTexts = <String>[
      for (final chunk in _sealedChunks)
        if (chunk.trim().isNotEmpty) chunk.trim(),
    ];
    final activeText = _activeChunkText.toString().trim();
    final targetTexts = <String>[
      ...sealedTexts,
      if (finalize && activeText.isNotEmpty) activeText,
    ];

    final nextSealedMessages = <Message>[];
    for (var i = 0; i < targetTexts.length; i++) {
      final text = targetTexts[i];
      Message? baseMessage;
      if (i < _sealedMessages.length) {
        baseMessage = _sealedMessages[i];
      } else if (i == _sealedMessages.length && _activeMessage != null) {
        baseMessage = _activeMessage;
        _activeMessage = null;
      }
      nextSealedMessages.add(
        baseMessage == null
            ? _createTextMessage(
                text: text,
                status: 'sent',
                blockStatus: BlockStatus.success,
              )
            : _rebuildTextMessage(
                baseMessage,
                text: text,
                status: 'sent',
                blockStatus: BlockStatus.success,
              ),
      );
    }

    _sealedMessages
      ..clear()
      ..addAll(nextSealedMessages);

    if (finalize) {
      _activeMessage = null;
      return List<Message>.from(_sealedMessages, growable: false);
    }

    final shouldShowPlaceholder = _fallbackTriggered ||
        _receivedDelta ||
        _sealedMessages.isNotEmpty ||
        activeText.isNotEmpty;
    if (!shouldShowPlaceholder) {
      _activeMessage = null;
      return List<Message>.from(_sealedMessages, growable: false);
    }

    final placeholderText = activeText.isEmpty ? _kGeneratingText : activeText;
    final placeholderBlockStatus =
        !formatConfig.enableChunking && activeText.isNotEmpty
            ? BlockStatus.success
            : BlockStatus.streaming;
    _activeMessage = _activeMessage == null
        ? _createTextMessage(
            text: placeholderText,
            status: 'sending',
            blockStatus: placeholderBlockStatus,
          )
        : _rebuildTextMessage(
            _activeMessage!,
            text: placeholderText,
            status: 'sending',
            blockStatus: placeholderBlockStatus,
          );

    return <Message>[
      ..._sealedMessages,
      _activeMessage!,
    ];
  }

  Message _createTextMessage({
    required String text,
    required String status,
    required BlockStatus blockStatus,
  }) {
    final messageId = genId('msg');
    return Message.fromBlocks(
      id: messageId,
      role: 'assistant',
      blocks: [
        TextBlock(
          messageId: messageId,
          content: text,
          status: blockStatus,
        ),
      ],
      createdAt: _allocateCreatedAt(),
      status: status,
    );
  }

  Message _rebuildTextMessage(
    Message baseMessage, {
    required String text,
    required String status,
    required BlockStatus blockStatus,
  }) {
    return Message.fromBlocks(
      id: baseMessage.id,
      role: baseMessage.role,
      blocks: [
        TextBlock(
          messageId: baseMessage.id,
          content: text,
          status: blockStatus,
        ),
      ],
      createdAt: baseMessage.createdAt,
      status: status,
    );
  }

  DateTime _allocateCreatedAt() {
    final baseMs = _timelineBaseMs ??= DateTime.now().millisecondsSinceEpoch;
    final createdAt =
        DateTime.fromMillisecondsSinceEpoch(baseMs + (_timelineTick * 100));
    _timelineTick += 1;
    return createdAt;
  }

  void _sealCompletedChunks() {
    if (!formatConfig.enableChunking) return;
    final active = _activeChunkText.toString();
    if (active.trim().isEmpty) return;

    final chunks = MessageFormatter.formatAndChunkText(active, formatConfig);
    if (chunks.isEmpty) return;
    if (chunks.length == 1) {
      if (streamTextEndsWithChunkBoundary(chunks.first, formatConfig)) {
        _enqueueSealedChunk(chunks.first);
        _activeChunkText.clear();
      }
      return;
    }

    final completed = chunks.sublist(0, chunks.length - 1);
    for (final chunk in completed) {
      _enqueueSealedChunk(chunk);
    }
    _activeChunkText
      ..clear()
      ..write(chunks.last);
    if (streamTextEndsWithChunkBoundary(chunks.last, formatConfig)) {
      _enqueueSealedChunk(chunks.last);
      _activeChunkText.clear();
    }
  }

  void _setFromFinalText(String finalText) {
    final visibleText = _sanitizeStreamDisplayText(finalText);
    _resetChunkBuffers();
    _lastVisibleText = visibleText;
    _rawStreamText
      ..clear()
      ..write(finalText);

    if (!formatConfig.enableChunking) {
      _activeChunkText.write(visibleText);
      return;
    }

    final chunks =
        MessageFormatter.formatAndChunkText(visibleText, formatConfig);
    if (chunks.isEmpty) {
      _activeChunkText.write(visibleText);
      return;
    }
    if (chunks.length == 1) {
      _activeChunkText.write(chunks.first);
      return;
    }

    _sealedChunks.addAll(chunks.sublist(0, chunks.length - 1));
    _activeChunkText.write(chunks.last);
  }

  void _setFromVisibleText(String visibleText) {
    _resetChunkBuffers();
    _lastVisibleText = visibleText;

    if (!formatConfig.enableChunking) {
      _activeChunkText.write(visibleText);
      return;
    }

    final chunks =
        MessageFormatter.formatAndChunkText(visibleText, formatConfig);
    if (chunks.isEmpty) {
      _activeChunkText.write(visibleText);
      return;
    }
    if (chunks.length == 1) {
      final first = chunks.first;
      if (streamTextEndsWithChunkBoundary(first, formatConfig)) {
        _sealedChunks.add(first);
      } else {
        _activeChunkText.write(first);
      }
      return;
    }

    final completed = chunks.sublist(0, chunks.length - 1);
    _sealedChunks.addAll(completed);
    final last = chunks.last;
    if (streamTextEndsWithChunkBoundary(last, formatConfig)) {
      _sealedChunks.add(last);
    } else {
      _activeChunkText.write(last);
    }
  }

  Future<void> _finalizeWithoutReplay(String finalText) async {
    // 完成阶段直接对齐最终文本，避免“已流出分段先撤回再重播”。
    _setFromFinalText(finalText);
    _dirty = false;
    await _applyState(finalize: true);
  }

  void _resetStreamState() {
    _fallbackTriggered = false;
    _receivedDelta = false;
    _resetTextBuffers();
  }

  void _resetTextBuffers() {
    _resetChunkBuffers();
    _segmentDelayTimer?.cancel();
    _segmentDelayTimer = null;
    _sealedMessages.clear();
    _activeMessage = null;
    _lastVisibleText = '';
    _timelineBaseMs = null;
    _timelineTick = 0;
    _rawStreamText.clear();
  }

  void _resetChunkBuffers() {
    _sealedChunks.clear();
    _pendingSealedChunks.clear();
    _activeChunkText.clear();
  }

  bool get _hasSegmentDelay => segmentDelay.inMilliseconds > 0;

  void _enqueueSealedChunk(String chunk) {
    final value = chunk.trim();
    if (value.isEmpty) return;
    if (!_hasSegmentDelay) {
      _sealedChunks.add(value);
      return;
    }
    _pendingSealedChunks.add(value);
    _scheduleSegmentDelayDrain();
  }

  void _scheduleSegmentDelayDrain() {
    if (_disposed || !_hasSegmentDelay || _pendingSealedChunks.isEmpty) return;
    if (_segmentDelayTimer != null) return;
    _segmentDelayTimer = Timer(segmentDelay, _drainOnePendingChunk);
  }

  void _drainOnePendingChunk() {
    _segmentDelayTimer = null;
    if (_disposed || _pendingSealedChunks.isEmpty) return;
    final chunk = _pendingSealedChunks.removeAt(0);
    _sealedChunks.add(chunk);
    _dirty = true;
    _scheduleFlush(forceNow: true);
    if (_pendingSealedChunks.isNotEmpty) {
      _scheduleSegmentDelayDrain();
    }
  }

  Future<void> _enqueue(Future<void> Function() task) {
    _queue = _queue.catchError((_) {}).then((_) async {
      if (_disposed) return;
      await task();
    });
    return _queue;
  }

  String _sanitizeStreamDisplayText(String rawText) {
    if (rawText.isEmpty) return rawText;
    var result = rawText.replaceAll(
      RegExp(r'<tts>.*?</tts>', caseSensitive: false, dotAll: true),
      '',
    );
    final openTagIndex =
        result.lastIndexOf(RegExp(r'<tts>', caseSensitive: false));
    if (openTagIndex >= 0) {
      final closeTagIndex =
          result.indexOf(RegExp(r'</tts>', caseSensitive: false), openTagIndex);
      if (closeTagIndex < 0) {
        result = result.substring(0, openTagIndex);
      }
    }
    result = _stripHiddenImageTagsForDisplay(result);
    final lastLt = result.lastIndexOf('<');
    final lastGt = result.lastIndexOf('>');
    if (lastLt > lastGt) {
      result = result.substring(0, lastLt);
    }
    return result;
  }

  Future<void> _setTransientMessages(List<Message> messages) {
    return _enqueue(() async {
      _ref
          .read(conversationTransientTimelineProvider(convId).notifier)
          .setMessages(messages);
    });
  }

  List<String> snapshotPlaceholderIds() => <String>[
        for (final message in _sealedMessages) message.id,
        if (_activeMessage != null) _activeMessage!.id,
      ];
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
