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

import '../conversation_state/domain/mvu_content.dart';
import '../plugins/tts/voice_request.dart';

import 'dart:async';
import 'package:aicove_agent_kernel/aicove_agent_kernel.dart' show KernelCancellation, KernelCancelledException;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auto_reply/data/analyzer_scheduler.dart';
import 'data/enhanced_dialogue_service.dart';
import 'application/active_stream_projection.dart';
import 'application/chat_ports.dart';
import 'application/chat_forward_messages.dart';
import 'application/chat_edit.dart';
import 'application/chat_send_use_case.dart';
import 'application/chat_turn_command.dart';
import 'application/conversation_model.dart';
import 'id_gen.dart' show genId;
import 'chat_layer_providers.dart';
import 'services/chat_frontend_message_projection_service.dart';
import 'services/chat_history_store.dart';
import 'services/chat_message_projection_codec.dart';
import 'application/regenerate_guidance.dart';
import 'services/chat_media_regeneration.dart';
import 'services/chat_types.dart'
    show
        ApiConfig,
        ApiRunStatus,
        ReplyRound,
        joinRoundReasonings,
        ApiCallResult,
        AssistantMessageBuildResult,
        isProviderRefreshTimingError;
import 'services/chat_tts_handler.dart';
import 'domain/message.dart';
import 'domain/chat_display_policy.dart';
import 'domain/conversation.dart';
import 'domain/role_agent_mode.dart';
import 'domain/quoted_reply.dart';
import 'domain/tool_call_label.dart';
import '../../core/api/providers/provider_adapter.dart'
    show ToolCall, ToolResult;
import '../settings/app_settings.dart';
import 'conversation_providers.dart';
import 'services/conversation_short_window_store.dart'
    show conversationTimelineCacheProvider;
import 'chat_providers.dart';
import '../../core/app_logger.dart';
import '../../core/models/message_block.dart';
import '../../core/models/block_status.dart';
import '../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../core/services/android_keep_alive_manager.dart';
import '../../core/services/attachment_picker_service.dart';
import '../../core/utils/mime_utils.dart';
import '../../core/utils/message_formatter.dart';
import '../observability/trace_models.dart';
import '../observability/frontend_diagnostics_port.dart';
import '../observability/frontend_diagnostics_provider.dart';
import '../observability/trace_store.dart';
import '../content_tags/domain/content_tag_scanner.dart';
import '../content_tags/domain/content_tag_spec.dart';
import '../content_tags/domain/tag_presentation.dart';
import '../agent_context/domain/preset_tag_mapping.dart'
    show builtinPresetTagMapping;
import '../agent_context/providers/preset_recipe_provider.dart'
    show tagPresentationForRecipeProvider;
import '../plugins/image/image_plugin.dart' show ImagePlugin;
import '../plugins/domain/plugin.dart' show PluginEvent;
import '../plugins/plugin_content_tags.dart';
import '../stickers/sticker_library.dart';
import '../stickers/sticker_registry.dart';
import '../stickers/sticker_tag.dart';
import '../dialogue_options/domain/dialogue_options.dart';
import '../context/domain/context_summary.dart' show ContextCompactionException;

// 重新导出公共类型，保持向后兼容
export 'chat_providers.dart';
export 'services/chat_types.dart';
export 'services/chat_send_service.dart'
    show ChatSendService, ApiCallResult, ApiConfig;
export 'services/chat_tts_handler.dart' show ChatTtsHandler;
part 'chat_actions_stream_placeholder.dart';
part 'chat_actions_stream_placeholder_parser.dart';
part 'chat_actions_action_ops.dart';
part 'chat_actions_tool_progress.dart';
part 'chat_actions_stream_delivery.dart';
part 'chat_actions_turn_runner.dart';
part 'chat_actions_media_send.dart';
part 'chat_actions_failover.dart';
part 'chat_actions_queued_input.dart';

class ChatActions {
  static const Duration _kProviderRefreshRetryDelay =
      Duration(milliseconds: 120);
  static const int _kProviderRefreshMaxRetries = 1;

  ChatActions(this._ref);

  /// 把 [text] 排进正在运行的 Agent 会话（[steer] 为插话，否则做完再发）；
  /// 没有运行或不是 Agent 模式时返回 false，调用方按普通发送处理。
  /// 规则见 [ChatActionsQueuedInput]。
  bool queueWhileRunning(String text, {required bool steer, String? convId}) =>
      _queueWhileRunning(text, steer: steer, convId: convId);

  /// 取走未发出的和排队中的全部输入（按先后顺序），用于放回输入框。
  List<String> takeQueuedInputs(String convId) => _takeQueuedInputs(convId);

  FrontendDiagnosticsPort get _diagnostics =>
      _ref.read(frontendDiagnosticsProvider);

  final Ref _ref;

  Future<void> regenerateMedia({
    required String conversationId,
    required String messageId,
    required String blockId,
    String? customPrompt,
  }) =>
      _ref.read(chatMediaRegenerationProvider).regenerate(
          conversationId: conversationId,
          messageId: messageId,
          blockId: blockId,
          customPrompt: customPrompt);

  Future<void> selectImageVersion({
    required String conversationId,
    required String messageId,
    required String blockId,
    required int versionIndex,
  }) =>
      _ref.read(chatHistoryStoreProvider).selectImageVersion(
          conversationId: conversationId,
          messageId: messageId,
          blockId: blockId,
          versionIndex: versionIndex);

  final _forwardSubmissions = <String>{};

  Future<void> forwardMessages({
    required String conversationId,
    required String sourceTitle,
    required List<Message> messages,
    required String note,
  }) async {
    final target = _ref.read(resolvedConversationByIdProvider(conversationId));
    if (target == null) throw StateError('联系人已不存在');
    final message = buildForwardedChatMessage(
      sourceTitle: sourceTitle, messages: messages, note: note,
    );
    if (_activeGenerations.containsKey(conversationId) ||
        !_forwardSubmissions.add(conversationId)) {
      throw StateError('该联系人正在回复，请稍后再分享');
    }
    final accepted = Completer<void>();
    unawaited(() async {
      try {
        await _sendText(message.content,
          targetConversation: target,
          preparedMessage: message,
          onUserCommitted: (_) => accepted.complete(),
        );
        if (!accepted.isCompleted) accepted.completeError(StateError('分享未受理'));
      } catch (error, stack) {
        if (!accepted.isCompleted) {
          accepted.completeError(error, stack);
        } else {
          try {
            await _historyPort.markMessageStatus(
              conversationId: conversationId, messageId: message.id, status: 'failed',
            );
          } catch (_) {
            // Keep the accepted record; never resubmit after a reply failure.
          }
          _setConversationError(conversationId, '回复失败，可重试已分享的聊天记录');
        }
      } finally {
        _forwardSubmissions.remove(conversationId);
        final generation = _activeGenerations[conversationId];
        if (generation?.userMsgId == message.id) {
          await _finishGeneration(conversationId, generation!.id);
        }
      }
    }());
    return accepted.future;
  }

  ChatSendPort get _sendPort => _ref.read(chatSendPortProvider);
  ChatSendUseCase get _sendUseCase => _ref.read(chatSendUseCaseProvider);
  ChatTtsHandler get _ttsHandler => _ref.read(chatTtsHandlerProvider);
  ChatHistoryPort get _historyPort => _ref.read(chatHistoryPortProvider);
  final EnhancedDialogueService _enhancedDialogueService =
      const EnhancedDialogueService();
  int _generationSerial = 0;
  final Map<String, _GenerationTask> _activeGenerations = {};

  Future<void> recoverInterruptedUserMessages(String conversationId) {
    return _historyPort.recoverInterruptedUserMessages(
      conversationId,
      isActiveSend: (messageId) {
        final task = _activeGenerations[conversationId];
        // Regeneration registers its task before resolving the source user.
        return task != null &&
            (task.userMsgId == null || task.userMsgId == messageId);
      },
    );
  }

  final Map<String, Future<void> Function()> _generationInterruptCleanups = {};
  final Map<int, Future<AndroidGenerationKeepAliveLease?>>
      _generationKeepAliveLeases = {};

  Future<TraceContext?> _startTurnTrace({
    required String convId,
    required String turnId,
    required String entry,
    Map<String, dynamic>? meta,
  }) async {
    try {
      final context = await TraceStore.instance.startTurn(
        sessionId: convId,
        turnId: turnId,
        source: 'ChatActions',
        meta: <String, dynamic>{
          'entry': entry,
          ...?meta,
        },
      );
      _diagnostics.linkTurn(
          conversationId: convId, turnId: turnId, traceId: context.traceId);
      return context;
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
    return _historyPort.loadRawMessages(convId);
  }

  void _recordTurnTrace(
    TraceContext? context,
    TraceStage stage, {
    TraceEventStatus status = TraceEventStatus.success,
    int roundIndex = 0,
    Map<String, dynamic>? meta,
    Map<String, dynamic>? payloadRef,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (context == null) return;
    final frontendStage = switch (stage) {
      TraceStage.messageDelivered => FrontendStage.messageDelivered,
      TraceStage.turnCompleted => FrontendStage.turnCompleted,
      TraceStage.turnFailed => FrontendStage.turnFailed,
      _ => null,
    };
    final diagnosticContext = _diagnostics.forTurn(context.turnId);
    if (frontendStage != null &&
        diagnosticContext?.traceId == context.traceId) {
      _diagnostics.record(diagnosticContext, frontendStage,
          once: true, error: error, stackTrace: stackTrace);
    }
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

  /// 每次执行独占一份活动记录，key 是本地执行序号，不使用协议调用 id。
  final Map<String, Map<int, String>> _runningTools = {};
  int _toolActivitySerial = 0;

  void Function() _startToolActivity(
    String convId,
    int? runId,
    Map<int, String> calls,
    ToolCall call,
  ) {
    bool isCurrent() => identical(_runningTools[convId], calls) &&
        (runId == null || _isGenerationCurrent(convId, runId));
    if (!isCurrent()) return () {};
    final sequence = ++_toolActivitySerial;
    calls[sequence] = toolCallLabel(call.name, call.arguments);
    _publishToolActivity(convId, calls.values.last);
    return () {
      if (!isCurrent()) return;
      calls.remove(sequence);
      _publishToolActivity(convId, calls.isEmpty ? null : calls.values.last);
    };
  }

  void _clearToolActivity(String convId, {Map<int, String>? expected}) {
    if (expected != null && !identical(_runningTools[convId], expected)) return;
    _runningTools.remove(convId);
    _publishToolActivity(convId, null);
  }

  void _publishToolActivity(String convId, String? label) {
    _runIgnoringProviderRefreshTiming('set_tool_activity', () {
      _ref.read(conversationToolActivityProvider(convId).notifier).state = label;
    });
  }

  void _setConversationStatus(String convId, ChatStatus status) {
    _runIgnoringProviderRefreshTiming('set_conversation_status', () {
      setConversationMainChatStatus(_ref, convId, status);
    });
  }

  void _setConversationError(String convId, String? error) {
    if (error != null) _activeGenerations[convId]?.failed = true;
    _runIgnoringProviderRefreshTiming('set_conversation_error', () {
      _ref.read(conversationErrorProvider(convId).notifier).state = error;
    });
  }

  void _setConversationRetryStatus(String convId, ModelRetryStatus? status) {
    _runIgnoringProviderRefreshTiming('set_conversation_retry_status', () {
      final notifier = _ref.read(conversationRetryStatusProvider(convId).notifier);
      if (status == null && notifier.state == null) return;
      notifier.state = status;
    });
  }

  /// 任务在第一个 await 之前登记，排队输入交接时不会出现无人占用的空档。
  int _startGeneration({
    required String convId,
    String? userMsgId,
    _QueuedSend? queued,
  }) {
    final runId = ++_generationSerial;
    _clearToolActivity(convId);
    final task = _activeGenerations[convId] = _GenerationTask(
      id: runId,
      convId: convId,
      userMsgId: userMsgId,
      queued: queued,
    );
    _applyQueuedSteer(convId, task);
    _setConversationSending(convId, true);
    _setConversationStatus(convId, ChatStatus.thinking);
    _setConversationError(convId, null);
    final leaseFuture = AndroidKeepAliveManager.acquireGenerationLease();
    _generationKeepAliveLeases[runId] = leaseFuture;
    // 落库期间保活可能先失败；立即观察错误，由等待点统一记录并处理。
    unawaited(leaseFuture.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    return runId;
  }

  Future<void> _awaitGenerationKeepAlive(String convId, int runId) async {
    final leaseFuture = _generationKeepAliveLeases[runId];
    if (leaseFuture == null) return;
    try {
      await leaseFuture;
    } catch (e) {
      _generationKeepAliveLeases.remove(runId);
      AppLogger.warning(
        'ChatActions',
        '生成保活启动失败，继续以前台模式执行',
        metadata: {
          'convId': convId,
          'runId': runId,
          'error': e.toString(),
        },
      );
    }
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

  Future<void> _finishGeneration(
    String convId,
    int runId,
  ) async {
    if (_isGenerationCurrent(convId, runId)) {
      _clearToolActivity(convId);
      _setConversationRetryStatus(convId, null);
    }
    await _releaseGenerationKeepAlive(runId, convId: convId);
    if (!_isGenerationCurrent(convId, runId)) return;
    // 成功时已交接（settled，这里什么都不做）；失败时保住全部已完成步骤。
    await _keepToolProgress(_activeGenerations[convId]!, ApiRunStatus.failed);
    if (!_isGenerationCurrent(convId, runId)) return;
    final task = _activeGenerations.remove(convId)!;
    _generationInterruptCleanups.remove(convId);
    // 交接给下一条排队输入时保持发送中，中间不暴露空闲。
    if (_settleQueuedInputs(convId, task, deliver: !task.failed)) return;
    _setConversationSending(convId, false);
    _ref.read(conversationIdleEventsProvider).add(convId);
    _setConversationStatus(convId, ChatStatus.idle);
  }

  Future<void> _releaseGenerationKeepAlive(
    int runId, {
    required String convId,
  }) async {
    final leaseFuture = _generationKeepAliveLeases.remove(runId);
    if (leaseFuture == null) return;
    try {
      final lease = await leaseFuture;
      await lease?.release();
    } catch (e) {
      AppLogger.warning(
        'ChatActions',
        '生成保活释放失败',
        metadata: {
          'convId': convId,
          'runId': runId,
          'error': e.toString(),
        },
      );
    }
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

    _diagnostics.record(
        _diagnostics.forTurn(task.userMsgId), FrontendStage.turnCancelled,
        once: true);
    task.cancellation.cancel();
    _clearToolActivity(targetConvId);
    _activeGenerations.remove(targetConvId);
    final cleanup = _generationInterruptCleanups.remove(targetConvId);
    _settleQueuedInputs(targetConvId, task, deliver: false);
    _setConversationSending(targetConvId, false);
    _setConversationStatus(targetConvId, ChatStatus.idle);
    _setConversationError(targetConvId, null);
    _setConversationRetryStatus(targetConvId, null);
    _ref.read(modelFailoverPromptProvider.notifier).dismiss(
          targetConvId,
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

    // 已完成的工具步骤留在聊天里并标成已中断；清理先跑，半截正文不能等它。
    await _keepToolProgress(task, ApiRunStatus.cancelled);
    await _releaseGenerationKeepAlive(task.id, convId: targetConvId);
    await _restoreFrontendMessagesFromHistory(targetConvId);
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

  final Set<String> _editSubmissions = {};

  /// 只等待本地分支提交，模型响应在既有发送链继续；失败不冒充受理成功。
  Future<void> submitEditedMessage(
    ChatEditDraft draft, {
    required String text,
    SelectedAttachment? attachment,
  }) async {
    final owner = draft.conversationId;
    if (_ref.read(activeConversationProvider)?.id != owner ||
        _ref.read(conversationSendingProvider(owner)) ||
        !_editSubmissions.add(owner)) {
      throw StateError('会话已切换或正在发送，编辑草稿已保留');
    }
    if (text.trim().isEmpty && attachment == null) {
      _editSubmissions.remove(owner);
      throw StateError('请输入消息内容');
    }
    _setConversationSending(owner, true);
    final accepted = Completer<void>();
    Message? committed;
    var submissionReleased = false;
    void releaseSubmission() {
      if (submissionReleased) return;
      submissionReleased = true;
      _editSubmissions.remove(owner);
    }
    void onCommitted(Message message) {
      committed = message;
      releaseSubmission();
      if (!accepted.isCompleted) accepted.complete();
    }

    unawaited(() async {
      try {
        if (attachment == null) {
          await _sendText(text, edit: draft, onUserCommitted: onCommitted);
        } else if (attachment.type == AttachmentType.image) {
          await _sendImage(attachment.path,
              text: text, edit: draft, onUserCommitted: onCommitted);
        } else {
          await _sendFile(attachment.path,
              text: text, edit: draft, onUserCommitted: onCommitted);
        }
        if (!accepted.isCompleted) {
          accepted.completeError(StateError('发送未受理，编辑草稿已保留'));
        }
      } catch (error, stack) {
        if (!accepted.isCompleted) {
          accepted.completeError(error, stack);
        } else if (committed != null) {
          // 覆盖模型准备阶段（尚未进入旧发送try/finally）的异常。
          try {
            await _historyPort.markMessageStatus(
                conversationId: owner,
                messageId: committed!.id,
                status: 'failed');
            _setConversationError(owner, '回复失败，可重试已提交的消息');
          } catch (_) {/* 保留已提交原文，不重新提交旧草稿。 */}
        }
      } finally {
        final generation = _activeGenerations[owner];
        if (committed != null && generation?.userMsgId == committed!.id) {
          await _finishGeneration(owner, generation!.id);
        } else if (generation == null) {
          _setConversationSending(owner, false);
        }
        releaseSubmission();
      }
    }());
    return accepted.future;
  }

  /// 暂存输入框文字；确认前不写历史、不触发模型。
  void stageComposerText(String text, {String? convId}) {
    final id = (convId ?? _ref.read(activeConversationProvider)?.id)?.trim();
    final normalized = text.trim();
    if (id == null || id.isEmpty || normalized.isEmpty) return;
    final quoted = _ref.read(quotedMessageProvider);
    final composed = quoted == null
        ? normalized
        : QuotedReply.compose(quotedContent: quoted.content, text: normalized);
    _appendStagedMessage(id,
        _sendPort.createUserMessage(text: composed, imagePath: null));
    if (quoted != null) _ref.read(quotedMessageProvider.notifier).state = null;
  }

  void stageWithImage(String imagePath, {String? text, String? convId}) {
    final id = (convId ?? _ref.read(activeConversationProvider)?.id)?.trim();
    if (id == null || id.isEmpty || imagePath.trim().isEmpty) return;
    final normalized = text?.trim() ?? '';
    final quoted = _ref.read(quotedMessageProvider);
    final composed = quoted == null
        ? normalized
        : QuotedReply.compose(quotedContent: quoted.content, text: normalized);
    _appendStagedMessage(id, _sendPort.createUserMessage(
      text: composed.isEmpty ? null : composed,
      imagePath: imagePath,
    ));
    if (quoted != null) _ref.read(quotedMessageProvider.notifier).state = null;
  }

  Future<void> stageWithFile(String filePath,
      {String? text, String? convId}) async {
    final id = (convId ?? _ref.read(activeConversationProvider)?.id)?.trim();
    if (id == null || id.isEmpty || filePath.trim().isEmpty) return;
    final resetEpoch = _ref.read(stagedMessagesResetEpochProvider(id));
    final normalized = text?.trim() ?? '';
    final quoted = _ref.read(quotedMessageProvider);
    final composed = quoted == null
        ? normalized
        : QuotedReply.compose(quotedContent: quoted.content, text: normalized);
    final message = await _sendPort.createUserFileMessage(
      filePath: filePath,
      text: composed.isEmpty ? null : composed,
    );
    if (_ref.read(stagedMessagesResetEpochProvider(id)) != resetEpoch) return;
    final convExists = _ref.read(resolvedConversationByIdProvider(id)) != null ||
        _ref.read(activeConversationProvider)?.id == id;
    if (!convExists) return;
    if (quoted != null && _ref.read(quotedMessageProvider)?.id == quoted.id) {
      _ref.read(quotedMessageProvider.notifier).state = null;
    }
    _appendStagedMessage(id, message);
  }

  void stageSticker(Sticker sticker, {String? convId}) {
    final id = (convId ?? _ref.read(activeConversationProvider)?.id)?.trim();
    if (id == null || id.isEmpty) return;
    final userMsg = buildUserStickerMessage(sticker);
    unawaited(StickerLibrary.markUsedIfLoaded(sticker.id));
    _appendStagedMessage(id, userMsg);
  }

  void _appendStagedMessage(String convId, Message message) {
    final staged = _ref.read(stagedUserMessagesProvider(convId).notifier);
    var stagedMsg = message.copyWith(status: 'staged');
    // 数据库存储精度为毫秒，避免同毫秒内暂存的消息在落库后重新排序。
    if (staged.state.isNotEmpty &&
        stagedMsg.createdAt.millisecondsSinceEpoch <=
            staged.state.last.createdAt.millisecondsSinceEpoch) {
      stagedMsg = stagedMsg.copyWith(createdAt:
          staged.state.last.createdAt.add(const Duration(milliseconds: 1)));
    }
    staged.state = [...staged.state, stagedMsg];
  }

  Set<String> _removeStagedMessages(
    String convId,
    Set<String> ids, {
    bool clearQuotedIfRemoved = true,
  }) {
    final staged = _ref.read(stagedUserMessagesProvider(convId).notifier);
    final removed = staged.state
        .where((message) => ids.contains(message.id))
        .map((message) => message.id)
        .toSet();
    if (removed.isEmpty) return removed;
    staged.state = [
      for (final message in staged.state)
        if (!removed.contains(message.id)) message,
    ];
    if (clearQuotedIfRemoved) {
      final quoted = _ref.read(quotedMessageProvider);
      if (quoted != null && removed.contains(quoted.id)) {
        _ref.read(quotedMessageProvider.notifier).state = null;
      }
    }
    return removed;
  }

  /// 只等待这批消息落库；AI 回复继续走既有发送链。
  /// 已落库部分不会因后续失败退回暂存，未落库部分可再次确认。
  Future<bool> confirmStagedMessages({String? convId}) async {
    final id = (convId ?? _ref.read(activeConversationProvider)?.id)?.trim();
    if (id == null || id.isEmpty) return false;
    final conv = _ref.read(resolvedConversationByIdProvider(id)) ??
        _ref.read(activeConversationProvider);
    if (conv == null || conv.id != id ||
        _activeGenerations.containsKey(id) ||
        _ref.read(conversationSendingProvider(id))) {
      return false;
    }
    final staged = List<Message>.of(_ref.read(stagedUserMessagesProvider(id)));
    if (staged.isEmpty) return false;
    final last = staged.last;
    final batchHasImage = staged.any((message) => message.images.isNotEmpty);
    final committed = <String>{};
    final accepted = Completer<bool>();
    // 在第一个 await 前占用本会话，重复确认及清空/删除沿用现有生成生命周期。
    final generationRunId =
        _startGeneration(convId: id, userMsgId: last.id);
    unawaited(() async {
      int? runId;
      var lastCommitted = false;
      bool stillStaged(Message message) => _ref
          .read(stagedUserMessagesProvider(id))
          .any((item) => item.id == message.id);
      void onCommitted(Message message) {
        lastCommitted = true;
        committed.add(message.id);
        _removeStagedMessages(id, committed, clearQuotedIfRemoved: false);
        if (!accepted.isCompleted) accepted.complete(true);
      }
      try {
        runId = generationRunId;
        for (final message in staged.take(staged.length - 1)) {
          if (!_isGenerationCurrent(id, runId)) return;
          if (!stillStaged(message)) continue;
          final emoji = message.blocks?.whereType<EmojiBlock>().firstOrNull;
          await _sendPort.addUserMessage(
            convId: id,
            userMsg: message.copyWith(status: 'sent'),
            displayText: emoji != null
                ? formatEmojiBlockContextText(emoji)
                : message.displayText,
          );
          committed.add(message.id);
          _removeStagedMessages(id, committed, clearQuotedIfRemoved: false);
          await _notifyUserMessageActivity(id, message);
        }
        if (!_isGenerationCurrent(id, runId) || !stillStaged(last)) return;
        final lastSending = last.copyWith(status: 'sending');
        final image = lastSending.images.firstOrNull;
        final file = lastSending.blocks?.whereType<FileBlock>().firstOrNull;
        final emoji = lastSending.blocks?.whereType<EmojiBlock>().firstOrNull;
        if (image != null) {
          await _sendImage(image.localPath ?? '',
            text: lastSending.content,
            targetConversation: conv,
            preparedMessage: lastSending,
            preparedRunId: runId,
            onUserCommitted: onCommitted,
          );
        } else if (file != null) {
          await _sendFile(file.filePath,
            text: lastSending.content,
            targetConversation: conv,
            preparedMessage: lastSending,
            preparedRunId: runId,
            batchHasImage: batchHasImage,
            onUserCommitted: onCommitted,
          );
        } else {
          await _sendText(
            emoji != null ? formatEmojiBlockContextText(emoji) : lastSending.content,
            targetConversation: conv,
            preparedMessage: lastSending,
            preparedRunId: runId,
            batchHasImage: batchHasImage,
            onUserCommitted: onCommitted,
          );
        }
      } catch (error, stack) {
        if (lastCommitted && runId != null && _isGenerationCurrent(id, runId)) {
          try {
            await _sendPort.markUserMessageFailed(convId: id, userMsgId: last.id);
          } catch (_) {
            // 原文已经受理，不因回复准备失败重新提交。
          }
        }
        if (runId != null && _isGenerationCurrent(id, runId)) {
          _setConversationError(id, error.toString());
        }
        if (!accepted.isCompleted) {
          accepted.completeError(error, stack);
        } else {
          AppLogger.warning('ChatActions', '批量消息已提交，回复失败',
              metadata: {'convId': id, 'error': error.toString()});
        }
      } finally {
        _removeStagedMessages(id, committed, clearQuotedIfRemoved: false);
        try {
          if (runId != null) await _finishGeneration(id, runId);
        } finally {
          if (!accepted.isCompleted) accepted.complete(false);
        }
      }
    }());
    return accepted.future;
  }

  /// 发送文本消息（支持自动轮询多个默认聊天模型），保留原有公开签名。
  Future<void> send(String text) => _sendText(text);

  Future<void> sendComposerText(String text) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty) return;

    final quoted = _ref.read(quotedMessageProvider);
    if (quoted == null) {
      await send(normalizedText);
      return;
    }

    _ref.read(quotedMessageProvider.notifier).state = null;
    await send(
      QuotedReply.compose(quotedContent: quoted.content, text: normalizedText),
    );
  }

  /// 发送图片消息（可附带文字说明，支持图片识别模型 + 轮询）
  Future<void> sendWithImage(String imagePath, {String? text}) =>
      _sendImage(imagePath, text: text);

  /// 发送文件 / 音频 / 视频附件消息（第一版统一复用 FileBlock）。
  Future<void> sendWithFile(String filePath, {String? text}) =>
      _sendFile(filePath, text: text);

  /// 发送表情包消息（走流式文本回合，消息体携带 EmojiBlock）。
  Future<void> sendSticker(Sticker sticker) async {
    final userMsg = buildUserStickerMessage(sticker);
    unawaited(StickerLibrary.markUsedIfLoaded(sticker.id));
    final emojiBlock = userMsg.blocks!.whereType<EmojiBlock>().first;
    await _sendText(
      formatEmojiBlockContextText(emojiBlock),
      preparedMessage: userMsg,
    );
  }

  /// 应用切后台时调用
  /// 委托给 AnalyzerScheduler 处理后台分析逻辑
  void onAppBackground() {
    _ref.read(analyzerSchedulerProvider).onAppBackground();
  }
}

/// 构建用户发送的表情包消息。
Message buildUserStickerMessage(Sticker sticker) {
  final msgId = genId('msg');
  final tag = sticker.tags
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .join('、');
  final desc = sticker.description.trim();
  return Message.fromBlocks(
    id: msgId,
    role: 'user',
    blocks: [
      EmojiBlock(
        messageId: msgId,
        emojiId: sticker.id,
        path: sticker.path,
        matchedTag: tag.isEmpty ? null : tag,
        originalText: desc.isEmpty ? null : desc,
      ),
    ],
    createdAt: DateTime.now(),
    status: 'sending',
  );
}

class _GenerationTask {
  final int id;
  final String convId;
  final String? userMsgId;

  final KernelCancellation cancellation;
  final toolProgress = _ToolProgress();

  /// 本次运行出错结束（已向界面报错），排队的输入不再自动发出。
  bool failed = false;

  bool Function({bool enabled})? _yield;
  bool _yieldRequested = false;

  /// 每次模型尝试（含换模型重试）都会交来新运行的让出句柄，已请求的让出照样生效。
  void bindYield(bool Function({bool enabled}) yieldAtBoundary) {
    _yield = yieldAtBoundary;
    if (_yieldRequested) yieldAtBoundary();
  }

  /// 有插话时让当前运行在这批工具结算后结束；插话被撤回时取消。
  void setYield(bool enabled) {
    _yieldRequested = enabled;
    _yield?.call(enabled: enabled);
  }

  /// 这次运行发送的是排队输入时，记着它走到哪一步（见 [_QueuedSend]）。
  final _QueuedSend? queued;

  _GenerationTask({
    KernelCancellation? cancellation,
    required this.id,
    required this.convId,
    required this.userMsgId,
    this.queued,
  }) : cancellation = cancellation ?? KernelCancellation();
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
