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
import 'chat_providers.dart';
import '../../core/app_logger.dart';
import '../../core/database/database_provider.dart';
import '../../core/models/message_block.dart';
import '../../core/models/block_status.dart';
import '../../core/services/attachment_picker_service.dart';
import '../../core/utils/message_formatter.dart';

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
  ChatActions(this._ref);

  final Ref _ref;
  ChatSendService get _sendService => _ref.read(chatSendServiceProvider);
  ChatTtsHandler get _ttsHandler => _ref.read(chatTtsHandlerProvider);
  final EnhancedDialogueService _enhancedDialogueService =
      const EnhancedDialogueService();
  int _generationSerial = 0;
  final Map<String, _GenerationTask> _activeGenerations = {};

  void _setConversationSending(String convId, bool isSending) {
    _ref.read(conversationSendingProvider(convId).notifier).state = isSending;
  }

  void _setConversationStatus(String convId, ChatStatus status) {
    _ref.read(chatStatusProvider.notifier).state = status;
  }

  void _setConversationError(String convId, String? error) {
    _ref.read(errorProvider.notifier).state = error;
  }

  void _setConversationFailoverInfo(String convId, String? modelName) {
    _ref.read(modelFailoverInfoProvider.notifier).state = modelName;
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

  bool _isGenerationCurrent(String convId, int runId) =>
      _activeGenerations[convId]?.id == runId;

  void _finishGeneration(
    String convId,
    int runId, {
    bool clearFailoverInfo = false,
    bool scheduleAnalysis = false,
  }) {
    if (!_isGenerationCurrent(convId, runId)) return;
    _activeGenerations.remove(convId);
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

    await _ref.read(conversationsProvider.notifier).updateOne(
          task.convId,
          (c) => c.copyWith(
            messages: c.messages
                .map((m) => (m.id == userMsgId && m.status == 'sending')
                    ? m.copyWith(status: 'sent')
                    : m)
                .toList(),
          ),
        );
  }

  /// 中断当前正在生成的消息（软中断：后续结果会被丢弃，不再落库到会话）。
  /// 默认中断当前激活会话；也可显式传入 [convId]。
  Future<bool> interruptCurrentGeneration({String? convId}) async {
    final targetConvId = convId ?? _ref.read(activeConversationProvider)?.id;
    if (targetConvId == null || targetConvId.trim().isEmpty) return false;
    final task = _activeGenerations[targetConvId];
    if (task == null) return false;

    _activeGenerations.remove(targetConvId);
    _setConversationSending(targetConvId, false);
    _setConversationStatus(targetConvId, ChatStatus.idle);
    _setConversationError(targetConvId, null);
    _setConversationFailoverInfo(targetConvId, null);

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
    final runId = _startGeneration(convId: convId, userMsgId: userMsg.id);
    await _sendService.addUserMessage(
        convId: convId, userMsg: userMsg, displayText: text);
    if (!_isGenerationCurrent(convId, runId)) return;

    _StreamPlaceholderDelivery? streamDelivery;
    var streamCommitted = false;
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
      final shouldCommitStream = streamDelivery.canFinalizeWith(
        buildResult,
        finalText: streamFinalText,
      );

      if (shouldCommitStream) {
        await streamDelivery.finalize(
          finalText: streamFinalText,
        );
        final streamTextMessageIds = streamDelivery.snapshotPlaceholderIds();
        await _ttsHandler.deliverSegmentedMessages(
          convId: convId,
          userMsgId: userMsg.id,
          buildResult: buildResult,
          replyText: result.replyText,
          pluginEvents: result.pluginEvents,
          ttsEnabled: usedSettings.ttsEnabled,
          appendAfterStreamText: true,
          streamTextMessageIds: streamTextMessageIds,
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

      trace.end(additionalMessage: '完成');
    } catch (e) {
      await streamDelivery?.removePlaceholders();
      if (!_isGenerationCurrent(convId, runId)) return;
      trace.error('失败', metadata: {'error': e.toString()});
      trace.end(additionalMessage: '失败');
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
    }
  }

  String _resolveFinalStreamText(
    ApiCallResult apiResult,
    AssistantMessageBuildResult buildResult,
  ) {
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
    final runId = _startGeneration(convId: convId, userMsgId: userMsg.id);
    final displayText = hasText ? userText : '[图片]';
    await _sendService.addUserMessage(
        convId: convId, userMsg: userMsg, displayText: displayText);
    if (!_isGenerationCurrent(convId, runId)) return;

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      if (!_isGenerationCurrent(convId, runId)) return;
      final history = await _sendService.prepareHistoryFromStore(
        conv: conv,
        userMsg: userMsg,
        limit: settings.historyMessageLimit,
      );
      final apiText = hasText ? userText : '[image]';

      // 若聊天模型链中已含视觉能力，则不插入视觉辅助模型；
      // 仅当聊天模型链全部无视觉能力时，才把视觉辅助模型置于首位。
      final modelsToTry = _sendService.buildImageSendModelRefs(settings);

      final (result, usedSettings) = await _executeWithFailover(
        convId: convId,
        modelsToTry: modelsToTry,
        buildConfig: (model) => _sendService.prepareApiConfig(
          conv: conv,
          history: history,
          userText: apiText,
          overrideModel: model,
        ),
        execute: (config) => _sendService.executeApiCall(
          config: config,
          sessionId: convId,
          userText: apiText,
          turnId: userMsg.id,
          onToolExecuting: (toolName) => _updateStatusForTool(convId, toolName),
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
    } catch (e) {
      if (!_isGenerationCurrent(convId, runId)) return;
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
    }
  }

  /// 发送文件消息（目前按"文本文件附件"发送，供 AI 阅读）
  Future<void> sendWithFile(String filePath) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null || filePath.trim().isEmpty) return;
    final convId = conv.id;

    final userMsg =
        await _sendService.createUserFileMessage(filePath: filePath);
    final runId = _startGeneration(convId: convId, userMsgId: userMsg.id);
    await _sendService.addUserMessage(
        convId: convId, userMsg: userMsg, displayText: '[文件]');
    if (!_isGenerationCurrent(convId, runId)) return;

    try {
      final settings = await _ref.read(appSettingsProvider.future);
      if (!_isGenerationCurrent(convId, runId)) return;
      final history = await _sendService.prepareHistoryFromStore(
        conv: conv,
        userMsg: userMsg,
        limit: settings.historyMessageLimit,
      );
      final config = await _sendService.prepareApiConfig(
          conv: conv, history: history, userText: '[file]');
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
    } catch (e) {
      if (!_isGenerationCurrent(convId, runId)) return;
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
      final history =
          snapshotHistory.isNotEmpty ? snapshotHistory : conv.messages;
      final config = await _sendService.prepareApiConfig(
        conv: conv,
        history: history,
        userText: proactiveInput,
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

      AppLogger.info('ChatActions', '触发器发送成功', metadata: {
        'triggerId': trigger.id,
        'title': trigger.title,
      });
      return const ProactiveSendResult.success();
    } catch (e) {
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

    final failedMsg = conv.messages.firstWhere(
      (m) => m.id == messageId && m.status == 'failed',
      orElse: () => throw Exception('消息不存在或状态不正确'),
    );

    final runId = _startGeneration(convId: convId, userMsgId: messageId);

    await _ref.read(conversationsProvider.notifier).updateOne(
        convId,
        (c) => c.copyWith(
              messages: c.messages
                  .map((m) =>
                      m.id == messageId ? m.copyWith(status: 'sending') : m)
                  .toList(),
            ));
    if (!_isGenerationCurrent(convId, runId)) return;

    _StreamPlaceholderDelivery? streamDelivery;
    var streamCommitted = false;
    try {
      final settings = await _ref.read(appSettingsProvider.future);
      if (!_isGenerationCurrent(convId, runId)) return;
      final msgIndex = conv.messages.indexWhere((m) => m.id == messageId);
      // 取重试消息及之前的历史，并过滤掉其他失败消息
      final rawHistory =
          msgIndex > 0 ? conv.messages.sublist(0, msgIndex + 1) : conv.messages;
      final history = rawHistory
          .where((m) => m.status != 'failed' || m.id == messageId)
          .toList();

      // 创建流式占位交付器
      streamDelivery = _StreamPlaceholderDelivery(
        _ref,
        convId: convId,
        userMsgId: messageId,
        formatConfig: settings.messageFormatConfig,
        segmentDelay: Duration(
          milliseconds: (settings.streamSegmentDelaySeconds * 1000).round(),
        ),
      );
      await streamDelivery.start();

      final config = await _sendService.prepareApiConfig(
          conv: conv, history: history, userText: failedMsg.displayText);
      if (!_isGenerationCurrent(convId, runId)) return;
      final result = await _sendService.executeApiCall(
        config: config,
        sessionId: convId,
        userText: failedMsg.displayText,
        turnId: messageId,
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
      );
      if (!_isGenerationCurrent(convId, runId)) return;
      _setConversationStatus(convId, ChatStatus.processingResponse);
      final buildResult = _sendService.buildAssistantMessages(
          apiResult: result, settings: settings);
      if (!_isGenerationCurrent(convId, runId)) return;

      // 先标记原消息为成功
      await _ref.read(conversationsProvider.notifier).updateOne(
          convId,
          (c) => c.copyWith(
                messages: c.messages
                    .map((m) =>
                        m.id == messageId ? m.copyWith(status: 'sent') : m)
                    .toList(),
              ));
      if (!_isGenerationCurrent(convId, runId)) return;

      // 处理流式占位提交
      final streamFinalText = _resolveFinalStreamText(result, buildResult);
      final shouldCommitStream = streamDelivery.canFinalizeWith(
        buildResult,
        finalText: streamFinalText,
      );

      if (shouldCommitStream) {
        await streamDelivery.finalize(finalText: streamFinalText);
        final streamTextMessageIds = streamDelivery.snapshotPlaceholderIds();
        await _ttsHandler.deliverSegmentedMessages(
          convId: convId,
          userMsgId: messageId,
          buildResult: buildResult,
          replyText: result.replyText,
          pluginEvents: result.pluginEvents,
          ttsEnabled: settings.ttsEnabled,
          appendAfterStreamText: true,
          streamTextMessageIds: streamTextMessageIds,
        );
        streamCommitted = true;
      } else {
        await streamDelivery.removePlaceholders();
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
    } catch (e) {
      if (!_isGenerationCurrent(convId, runId)) return;
      await _ref.read(conversationsProvider.notifier).updateOne(
          convId,
          (c) => c.copyWith(
                messages: c.messages
                    .map((m) =>
                        m.id == messageId ? m.copyWith(status: 'failed') : m)
                    .toList(),
              ));
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

    // 找到要重新生成的AI消息索引
    final msgIndex = conv.messages.indexWhere((m) => m.id == aiMessageId);
    if (msgIndex < 0) return;

    // 找到该AI消息对应的用户消息（通常是前一条）
    int userMsgIndex = msgIndex - 1;
    while (userMsgIndex >= 0 && conv.messages[userMsgIndex].role != 'user') {
      userMsgIndex--;
    }
    if (userMsgIndex < 0) return;

    final userMsg = conv.messages[userMsgIndex];
    final userText = userMsg.displayText;

    final runId = _startGeneration(convId: convId, userMsgId: userMsg.id);

    // 收集被移除的消息 ID，用于数据库软删除
    final removedMessages = conv.messages.sublist(userMsgIndex + 1);

    // 删除AI消息及其后的所有消息，保留到用户消息
    await _ref.read(conversationsProvider.notifier).updateOne(
        convId,
        (c) => c.copyWith(
              messages: c.messages.sublist(0, userMsgIndex + 1),
            ));
    if (!_isGenerationCurrent(convId, runId)) return;

    // 在数据库中软删除被移除的消息
    await _softDeleteMessages(removedMessages.map((m) => m.id).toList());
    if (!_isGenerationCurrent(convId, runId)) return;

    _StreamPlaceholderDelivery? streamDelivery;
    var streamCommitted = false;
    try {
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
        final persistedConv = updatedConv.copyWith(messages: persistedMessages);
        final enhancedContext = _enhancedDialogueService.buildContext(
          conversation: persistedConv,
          targetUserMessage: userMsg,
          enhancerSystemPrompt: settings.enhancedDialogueSettings.systemPrompt,
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

      // 创建流式占位交付器
      streamDelivery = _StreamPlaceholderDelivery(
        _ref,
        convId: convId,
        userMsgId: userMsg.id,
        formatConfig: settings.messageFormatConfig,
        segmentDelay: Duration(
          milliseconds: (settings.streamSegmentDelaySeconds * 1000).round(),
        ),
      );
      await streamDelivery.start();

      final config = await _sendService.prepareApiConfig(
        conv: requestConv,
        history: history,
        userText: userText,
      );
      if (!_isGenerationCurrent(convId, runId)) return;
      final rawResult = await _sendService.executeApiCall(
        config: config,
        sessionId: sessionId,
        userText: userText,
        turnId: userMsg.id,
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

      // 处理流式占位提交
      final streamFinalText = _resolveFinalStreamText(result, buildResult);
      final shouldCommitStream = streamDelivery.canFinalizeWith(
        buildResult,
        finalText: streamFinalText,
      );

      if (shouldCommitStream) {
        await streamDelivery.finalize(finalText: streamFinalText);
        final streamTextMessageIds = streamDelivery.snapshotPlaceholderIds();
        await _ttsHandler.deliverSegmentedMessages(
          convId: convId,
          userMsgId: userMsg.id,
          buildResult: buildResult,
          replyText: result.replyText,
          pluginEvents: result.pluginEvents,
          ttsEnabled: settings.ttsEnabled,
          appendAfterStreamText: true,
          streamTextMessageIds: streamTextMessageIds,
        );
        streamCommitted = true;
      } else {
        await streamDelivery.removePlaceholders();
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
    } catch (e) {
      if (!_isGenerationCurrent(convId, runId)) return;
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

    final idx = conv.messages.indexWhere(
      (m) => m.id == messageId && m.status == 'failed',
    );
    if (idx < 0) return;
    final failedMsg = conv.messages[idx];

    // 将失败消息文本填入输入框
    final text = _extractEditableTextForRecall(failedMsg);
    if (text.isNotEmpty) {
      _ref.read(editingTextProvider.notifier).state = text;
    }
    _ref.read(recalledAttachmentProvider.notifier).state =
        _extractAttachmentForRecall(failedMsg);

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

    final idx = conv.messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;

    await _ref.read(conversationsProvider.notifier).updateOne(convId, (c) {
      final newMessages = c.messages.where((m) => m.id != messageId).toList();
      final lastMsg = newMessages.isNotEmpty ? newMessages.last : null;
      return c.copyWith(
        messages: newMessages,
        lastMessage: lastMsg?.displayText,
        lastMessageTime: lastMsg?.createdAt,
        contextStartMessageId: c.contextStartMessageId == messageId
            ? null
            : c.contextStartMessageId,
        updatedAt: DateTime.now(),
      );
    });

    // 如果当前引用的是被删除消息，一并清空引用态
    final quoted = _ref.read(quotedMessageProvider);
    if (quoted?.id == messageId) {
      _ref.read(quotedMessageProvider.notifier).state = null;
    }

    await _softDeleteMessages([messageId]);
  }

  /// 编辑消息：删除指定消息及其后的所有消息，返回被删除消息的文本用于填充输入框
  Future<String?> editMessage(String messageId) async {
    final conv = _ref.read(activeConversationProvider);
    if (conv == null) return null;
    final convId = conv.id;

    final msgIndex = conv.messages.indexWhere((m) => m.id == messageId);
    if (msgIndex < 0) return null;

    final msg = conv.messages[msgIndex];
    final text = msg.displayText;

    // 删除该消息及其后的所有消息
    final removedMessages = conv.messages.sublist(msgIndex);
    await _ref.read(conversationsProvider.notifier).updateOne(convId, (c) {
      final newMessages = c.messages.sublist(0, msgIndex);
      final lastMsg = newMessages.isNotEmpty ? newMessages.last : null;
      return c.copyWith(
        messages: newMessages,
        lastMessage: lastMsg?.displayText ?? '',
        lastMessageTime: lastMsg?.createdAt ?? c.createdAt,
      );
    });

    // 在数据库中软删除被移除的消息
    await _softDeleteMessages(removedMessages.map((m) => m.id).toList());

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

class _StreamPlaceholderDelivery {
  _StreamPlaceholderDelivery(
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

  final List<String> _activePlaceholderIds = <String>[];
  final Set<String> _allPlaceholderIds = <String>{};
  final List<String> _sealedChunks = <String>[];
  final List<String> _pendingSealedChunks = <String>[];
  final StringBuffer _activeChunkText = StringBuffer();
  final StringBuffer _rawStreamText = StringBuffer();

  Future<void> _queue = Future<void>.value();
  Timer? _flushTimer;
  Timer? _segmentDelayTimer;
  bool _dirty = false;
  bool _disposed = false;
  bool _receivedDelta = false;
  bool _fallbackTriggered = false;

  Future<void> start() async {
    if (_disposed || _activePlaceholderIds.isNotEmpty) return;
    final id = genId('msg');
    _activePlaceholderIds.add(id);
    _allPlaceholderIds.add(id);
    await _applyState(finalize: false);
  }

  void onDelta(String delta) {
    if (_disposed) return;
    final value = delta;
    if (value.isEmpty) return;
    _rawStreamText.write(value);
    if (formatConfig.enableChunking) {
      _activeChunkText.write(value);
      _sealCompletedChunks();
    } else {
      _activeChunkText
        ..clear()
        ..write(_rawStreamText.toString());
    }
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
    if (_allPlaceholderIds.isEmpty) return;
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirty = false;
    await _enqueue(() async {
      await _ref.read(conversationsProvider.notifier).updateOne(
        convId,
        (c) {
          final remaining = [
            for (final m in c.messages)
              if (!_allPlaceholderIds.contains(m.id)) m,
          ];
          final last = remaining.isNotEmpty ? remaining.last : null;
          return c.copyWith(
            messages: remaining,
            updatedAt: DateTime.now(),
            lastMessage: last?.displayText,
            lastMessageTime: last?.createdAt,
          );
        },
        persist: false,
      );
    });
    _activePlaceholderIds.clear();
    _allPlaceholderIds.clear();
    _resetTextBuffers();
    _receivedDelta = false;
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
    if (_disposed || _activePlaceholderIds.isEmpty) return;
    final chunks = _buildChunks(finalize: finalize);
    _ensurePlaceholderCount(chunks.length);
    final snapshotIds = List<String>.from(_activePlaceholderIds);
    await _enqueue(() async {
      await _ref.read(conversationsProvider.notifier).updateOne(
        convId,
        (c) {
          final existingById = <String, Message>{
            for (final m in c.messages) m.id: m,
          };
          final kept = <Message>[
            for (final m in c.messages)
              if (!_allPlaceholderIds.contains(m.id))
                if (m.id == userMsgId && finalize && m.status == 'sending')
                  m.copyWith(status: 'sent')
                else
                  m,
          ];
          final now = DateTime.now();
          final placeholders = <Message>[];
          for (var i = 0; i < snapshotIds.length; i++) {
            final id = snapshotIds[i];
            final rawChunk = chunks[i];
            final content =
                rawChunk.trim().isEmpty ? _kGeneratingText : rawChunk;
            final isLast = i == snapshotIds.length - 1;
            final status = finalize ? 'sent' : (isLast ? 'sending' : 'sent');
            final showRawTextWhileStreaming = !finalize &&
                !formatConfig.enableChunking &&
                _receivedDelta &&
                content != _kGeneratingText;
            final blockStatus = finalize
                ? BlockStatus.success
                : (showRawTextWhileStreaming
                    ? BlockStatus.success
                    : (isLast ? BlockStatus.streaming : BlockStatus.success));
            final createdAt = existingById[id]?.createdAt ?? now;
            placeholders.add(
              Message.fromBlocks(
                id: id,
                role: 'assistant',
                blocks: [
                  TextBlock(
                    messageId: id,
                    content: content,
                    status: blockStatus,
                  ),
                ],
                createdAt: createdAt,
                status: status,
              ),
            );
          }

          final preview = placeholders.isNotEmpty
              ? placeholders.last.displayText
              : c.lastMessage;

          return c.copyWith(
            messages: [...kept, ...placeholders],
            updatedAt: now,
            lastMessage: preview,
            lastMessageTime: now,
          );
        },
        persist: finalize,
      );
    });
  }

  List<String> _buildChunks({required bool finalize}) {
    if (!formatConfig.enableChunking) {
      final rawText = _rawStreamText.toString();
      if (rawText.trim().isEmpty) {
        return <String>[_kGeneratingText];
      }
      return <String>[rawText];
    }

    final chunks = <String>[
      ..._sealedChunks,
    ];
    final active = _activeChunkText.toString();
    if (active.trim().isNotEmpty) {
      chunks.add(active);
    } else if (!finalize && chunks.isNotEmpty) {
      // 当前段已封口，立即展示下一条“生成中...”占位，形成分段式逐条发送体验。
      chunks.add(_kGeneratingText);
    }
    if (chunks.isEmpty) {
      return <String>[_kGeneratingText];
    }
    return chunks;
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
    _resetTextBuffers();
    _rawStreamText.write(finalText);

    if (!formatConfig.enableChunking) {
      _activeChunkText.write(finalText);
      return;
    }

    final chunks = MessageFormatter.formatAndChunkText(finalText, formatConfig);
    if (chunks.isEmpty) {
      _activeChunkText.write(finalText);
      return;
    }
    if (chunks.length == 1) {
      _activeChunkText.write(chunks.first);
      return;
    }

    _sealedChunks.addAll(chunks.sublist(0, chunks.length - 1));
    _activeChunkText.write(chunks.last);
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
    _segmentDelayTimer?.cancel();
    _segmentDelayTimer = null;
    _sealedChunks.clear();
    _pendingSealedChunks.clear();
    _activeChunkText.clear();
    _rawStreamText.clear();
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

  void _ensurePlaceholderCount(int targetCount) {
    var target = targetCount;
    if (target <= 0) target = 1;
    while (_activePlaceholderIds.length < target) {
      final id = genId('msg');
      _activePlaceholderIds.add(id);
      _allPlaceholderIds.add(id);
    }
    if (_activePlaceholderIds.length > target) {
      _activePlaceholderIds.removeRange(target, _activePlaceholderIds.length);
    }
  }

  Future<void> _enqueue(Future<void> Function() task) {
    _queue = _queue.catchError((_) {}).then((_) async {
      if (_disposed) return;
      await task();
    });
    return _queue;
  }

  List<String> snapshotPlaceholderIds() =>
      List<String>.unmodifiable(_activePlaceholderIds);
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
