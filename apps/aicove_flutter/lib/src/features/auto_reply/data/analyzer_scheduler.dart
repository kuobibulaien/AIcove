/// 主动回复调度器
///
/// 职责：
/// - 按会话维度维护 5 分钟静默观察
/// - 维护 `active / silent / dormant` 会话主动状态
/// - 在沉默期结束后只唤醒一次 analyzer
/// - 负责把 analyzer 决策落到会话状态与触发器实体
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/agent_api.dart';
import '../../../core/app_logger.dart';
import '../../chat/conversation_providers.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/services/chat_history_store.dart';
import '../../settings/app_settings.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_controller.dart';
import 'auto_reply_trigger_storage.dart';
import 'context_analyzer.dart';
import 'conversation_proactive_state.dart';
import 'conversation_proactive_state_storage.dart';
import 'proactive_message_pregenerator.dart';

class AnalyzerScheduler {
  static const String _triggerPluginId = 'trigger';

  AnalyzerScheduler(this._ref) {
    _initFuture = _initialize();
  }

  final Ref _ref;

  late final ConversationProactiveStateStorage _storage;
  late Future<void> _initFuture;
  final Map<String, ConversationProactiveState> _states =
      <String, ConversationProactiveState>{};
  final Map<String, Timer> _analysisTimers = <String, Timer>{};
  final Map<String, Timer> _silentTimers = <String, Timer>{};
  final Set<String> _runningAnalysisConversationIds = <String>{};
  final AutoReplyTriggerStorage _historyStorage = AutoReplyTriggerStorage();
  Timer? _backgroundAnalysisTimer;
  DateTime? _lastBackgroundAnalysisAt;

  static const Duration _defaultDelay = Duration(minutes: 5);
  static const Duration _immediateDelay = Duration(seconds: 1);
  static const Duration _backgroundAnalysisDelay = Duration(seconds: 10);
  static const Duration _backgroundAnalysisCooldown = Duration(minutes: 5);

  Future<void> _appendHistoryLog({
    required AutoReplyTriggerLogCategory category,
    required String event,
    required String message,
    String? triggerId,
    String? title,
    String? conversationId,
    TriggerSource? source,
    bool? success,
    AutoReplyTriggerLogLevel level = AutoReplyTriggerLogLevel.info,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    await _historyStorage.appendLog(
      AutoReplyTriggerLog(
        id: 'scheduler_${DateTime.now().microsecondsSinceEpoch}',
        category: category,
        event: event,
        message: message,
        occurredAt: DateTime.now(),
        triggerId: triggerId,
        title: title,
        conversationId: conversationId,
        source: source,
        success: success,
        level: level,
        metadata: metadata,
      ),
    );
  }

  Future<void> _initialize() async {
    _storage = ConversationProactiveStateStorage();
    await refreshFromStorage();
  }

  Future<void> refreshFromStorage() async {
    final loaded = await _storage.loadStates();
    _states
      ..clear()
      ..addAll(loaded);
    _restoreTimers();
  }

  Future<void> handleUserMessageActivity({
    required String conversationId,
    required String? messageId,
    required DateTime occurredAt,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) return;

    await _initFuture;
    final conversation =
        _ref.read(resolvedConversationByIdProvider(normalizedConversationId));
    if (conversation != null &&
        !_isSupervisorEnabledForConversation(conversation)) {
      await _clearConversationAutoTriggers(
        normalizedConversationId,
        reason: 'disabled_by_conversation_plugin',
      );
      _cancelTimers(normalizedConversationId);
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.wakeup,
        event: 'skip_by_trigger_plugin_disabled',
        message: '跳过主动关怀观察：当前联系人已关闭主动关怀插件',
        conversationId: normalizedConversationId,
        level: AutoReplyTriggerLogLevel.warning,
      );
      return;
    }
    await _clearConversationAutoTriggers(
      normalizedConversationId,
      reason: 'cleared_by_new_user_message',
    );
    _cancelTimers(normalizedConversationId);

    final current = _states[normalizedConversationId] ??
        ConversationProactiveState(
          conversationId: normalizedConversationId,
        );
    final next = current.markUserMessage(
      messageId: messageId,
      occurredAt: occurredAt,
    );
    await _setState(next);
    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.wakeup,
      event: 'reset_by_user_message',
      message: '用户新消息已重置主动回复观察期',
      conversationId: normalizedConversationId,
      metadata: {
        'messageId': messageId,
        'occurredAt': occurredAt.toIso8601String(),
      },
    );
    _scheduleAnalysisTimer(
      conversationId: normalizedConversationId,
      delay: _defaultDelay,
      reason: '5分钟无新消息',
    );
  }

  Future<void> onAutoTriggerCreated(AutoReplyTrigger trigger) async {
    if (trigger.source != TriggerSource.aiScheduler) return;
    await _initFuture;

    final conversationId = trigger.conversationId.trim();
    if (conversationId.isEmpty) return;
    _silentTimers.remove(conversationId)?.cancel();

    final current = _states[conversationId] ??
        ConversationProactiveState(conversationId: conversationId);
    final next = current.copyWith(
      mode: ConversationProactiveMode.active,
      silenceUntil: null,
      pendingAutoTriggerId: trigger.id,
    );
    await _setState(next);
  }

  Future<void> onAutoTriggerCleared({
    required String conversationId,
    required String triggerId,
  }) async {
    final normalizedConversationId = conversationId.trim();
    final normalizedTriggerId = triggerId.trim();
    if (normalizedConversationId.isEmpty || normalizedTriggerId.isEmpty) {
      return;
    }

    await _initFuture;
    final current = _states[normalizedConversationId];
    if (current == null) return;
    final next =
        current.clearPendingAutoTrigger(triggerId: normalizedTriggerId);
    await _setState(next);
  }

  Future<void> onAutoTriggerSendCompleted({
    required AutoReplyTrigger trigger,
    required bool success,
    required bool retryable,
    required DateTime occurredAt,
  }) async {
    if (trigger.source != TriggerSource.aiScheduler) return;
    await _initFuture;

    final conversationId = trigger.conversationId.trim();
    if (conversationId.isEmpty) return;

    if (!success) {
      if (retryable) {
        final current = _states[conversationId] ??
            ConversationProactiveState(conversationId: conversationId);
        await _setState(current.withPendingAutoTrigger(trigger.id));
        return;
      }

      final current = _states[conversationId];
      if (current == null) return;
      await _setState(current.clearPendingAutoTrigger(triggerId: trigger.id));
      return;
    }

    _cancelTimers(conversationId);
    final current = _states[conversationId] ??
        ConversationProactiveState(conversationId: conversationId);
    final next = current
        .clearPendingAutoTrigger(triggerId: trigger.id)
        .afterSuccessfulAutoTriggerSend(occurredAt: occurredAt);
    await _setState(next);
    _scheduleForState(next);
  }

  void scheduleAnalysis({
    String? conversationId,
    Duration delay = _defaultDelay,
    String reason = '5分钟无新消息',
  }) {
    final resolvedConversationId = conversationId?.trim() ??
        _ref.read(activeConversationIdProvider)?.trim();
    if (resolvedConversationId == null || resolvedConversationId.isEmpty) {
      return;
    }
    unawaited(_scheduleAnalysisInternal(
      conversationId: resolvedConversationId,
      delay: delay,
      reason: reason,
    ));
  }

  Future<void> _scheduleAnalysisInternal({
    required String conversationId,
    required Duration delay,
    required String reason,
  }) async {
    await _initFuture;
    _scheduleAnalysisTimer(
      conversationId: conversationId,
      delay: delay,
      reason: reason,
    );
  }

  void onAppBackground() {
    final now = DateTime.now();
    _log(
      'analyzer:background_keep_schedule',
      {
        'analysisTimers': _analysisTimers.length,
        'silentTimers': _silentTimers.length,
      },
      level: 'DEBUG',
    );

    _scheduleBackgroundAnalysis(now);
    unawaited(_syncHeartbeat(now));
  }

  Future<void> onAppResumed() async {
    _backgroundAnalysisTimer?.cancel();
    _backgroundAnalysisTimer = null;
    await refreshFromStorage();
  }

  void _scheduleBackgroundAnalysis(DateTime now) {
    final conversationId = _ref.read(activeConversationIdProvider)?.trim();
    if (conversationId == null || conversationId.isEmpty) {
      return;
    }

    final lastRunAt = _lastBackgroundAnalysisAt;
    if (lastRunAt != null &&
        now.difference(lastRunAt) < _backgroundAnalysisCooldown) {
      return;
    }

    _backgroundAnalysisTimer?.cancel();
    _backgroundAnalysisTimer = Timer(_backgroundAnalysisDelay, () {
      _backgroundAnalysisTimer = null;
      _lastBackgroundAnalysisAt = DateTime.now();
      unawaited(_runAnalysis(
        conversationId: conversationId,
        reason: 'app_background',
      ));
    });

    unawaited(
      _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.wakeup,
        event: 'background_analysis_scheduled',
        message: '已安排后台主动回复分析',
        conversationId: conversationId,
        metadata: {
          'delayMs': _backgroundAnalysisDelay.inMilliseconds,
        },
      ),
    );
  }

  Future<void> _runAnalysis({
    required String conversationId,
    required String reason,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) return;

    await _initFuture;
    if (!_runningAnalysisConversationIds.add(normalizedConversationId)) {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_skipped_in_flight',
        message: '跳过分析：当前会话已有主动回复分析正在运行',
        conversationId: normalizedConversationId,
        metadata: {
          'reason': reason,
        },
      );
      _log(
        'analyzer:skip_in_flight',
        {
          'conversationId': normalizedConversationId,
          'reason': reason,
        },
        level: 'DEBUG',
      );
      return;
    }

    try {
      await _runAnalysisUnlocked(
        conversationId: normalizedConversationId,
        reason: reason,
      );
    } finally {
      _runningAnalysisConversationIds.remove(normalizedConversationId);
    }
  }

  Future<void> _runAnalysisUnlocked({
    required String conversationId,
    required String reason,
  }) async {
    await _initFuture;

    final state = _states[conversationId] ??
        ConversationProactiveState(conversationId: conversationId);
    if (state.mode == ConversationProactiveMode.dormant) {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_skipped_dormant',
        message: '跳过分析：当前会话处于 dormant',
        conversationId: conversationId,
      );
      _log('analyzer:skip_dormant', {'conversationId': conversationId},
          level: 'DEBUG');
      return;
    }
    final conversation = _ref.read(resolvedConversationByIdProvider(
      conversationId,
    ));
    if (conversation == null) {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_skipped_missing_conversation',
        message: '跳过分析：找不到对应会话',
        conversationId: conversationId,
        level: AutoReplyTriggerLogLevel.warning,
      );
      _log('analyzer:skip_missing_conversation',
          {'conversationId': conversationId},
          level: 'WARN');
      return;
    }
    if (!_isSupervisorEnabledForConversation(conversation)) {
      await _clearConversationAutoTriggers(
        conversationId,
        reason: 'disabled_by_conversation_plugin',
      );
      _cancelTimers(conversationId);
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_skipped_trigger_plugin_disabled',
        message: '跳过分析：当前联系人已关闭主动关怀插件',
        conversationId: conversationId,
        level: AutoReplyTriggerLogLevel.warning,
      );
      _log(
        'analyzer:skip_trigger_plugin_disabled',
        {'conversationId': conversationId},
        level: 'WARN',
      );
      return;
    }
    if (state.hasPendingAutoTrigger) {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_skipped_pending_trigger',
        message: '跳过分析：当前已有待发送的自动触发器',
        conversationId: conversationId,
      );
      _log('analyzer:skip_pending_trigger', {'conversationId': conversationId},
          level: 'DEBUG');
      return;
    }
    if (state.mode == ConversationProactiveMode.silent &&
        state.silenceUntil != null &&
        state.silenceUntil!.isAfter(DateTime.now())) {
      _scheduleSilentTimer(
        conversationId: conversationId,
        wakeAt: state.silenceUntil!,
      );
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_skipped_silent',
        message: '跳过分析：当前仍处于 silent 沉默期',
        conversationId: conversationId,
        metadata: {
          'silenceUntil': state.silenceUntil!.toIso8601String(),
        },
      );
      return;
    }

    var effectiveState = state;
    if (effectiveState.mode == ConversationProactiveMode.silent) {
      effectiveState = effectiveState.copyWith(
        mode: ConversationProactiveMode.active,
        silenceUntil: null,
      );
      await _setState(effectiveState);
    }

    try {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_started',
        message: '开始执行主动回复分析',
        conversationId: conversationId,
        metadata: {
          'reason': reason,
          'mode': effectiveState.mode.name,
          'unrepliedCount': effectiveState.unrepliedCount,
        },
      );
      final decision = await _ref.read(contextAnalyzerProvider).analyze(
            conversation,
            proactiveState: effectiveState,
          );
      if (decision == null) {
        await _appendHistoryLog(
          category: AutoReplyTriggerLogCategory.analyzer,
          event: 'analysis_no_decision',
          message: '分析完成：本轮没有生成新的触发决策',
          conversationId: conversationId,
          metadata: {
            'reason': reason,
          },
        );
        _log('analyzer:no_decision',
            {'conversationId': conversationId, 'reason': reason},
            level: 'DEBUG');
        return;
      }

      await _applyDecision(
        conversation: conversation,
        currentState: effectiveState,
        decision: decision,
      );
    } catch (e) {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_failed',
        message: '主动回复分析失败',
        conversationId: conversationId,
        level: AutoReplyTriggerLogLevel.error,
        metadata: {
          'reason': reason,
          'error': e.toString(),
        },
      );
      _log(
        'analyzer:error',
        {
          'conversationId': conversationId,
          'reason': reason,
          'error': e.toString(),
        },
        level: 'ERROR',
      );
    }
  }

  Future<void> _applyDecision({
    required Conversation conversation,
    required ConversationProactiveState currentState,
    required ContextAnalysisDecision decision,
  }) async {
    final conversationId = conversation.id;
    final controller = _ref.read(autoReplyTriggersProvider.notifier);

    final createdTriggerId = decision.createdTriggerId?.trim();
    if (createdTriggerId != null && createdTriggerId.isNotEmpty) {
      final nextState = currentState.copyWith(
        mode: ConversationProactiveMode.active,
        silenceUntil: null,
        pendingAutoTriggerId: createdTriggerId,
      );
      await _setState(nextState);
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'trigger_created_by_tool',
        message: '分析完成：后台 Agent 已通过工具创建自动触发器',
        conversationId: conversationId,
        triggerId: createdTriggerId,
      );
      return;
    }

    final triggerPlan = decision.triggerPlan;
    if (triggerPlan == null) {
      final nextState = _applySessionPatch(
        currentState: currentState,
        patch: decision.sessionPatch,
      );
      await _setState(nextState);
      if (decision.sessionPatch != null) {
        await _appendHistoryLog(
          category: AutoReplyTriggerLogCategory.analyzer,
          event: 'session_patch_applied',
          message: '分析完成：已更新会话主动回复状态',
          conversationId: conversationId,
          metadata: {
            'mode': decision.sessionPatch!.mode.name,
            'silenceMinutes': decision.sessionPatch!.silenceDuration?.inMinutes,
            'reason': decision.sessionPatch!.reason,
          },
        );
      }
      _scheduleForState(nextState);
      return;
    }

    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.analyzer,
      event: 'trigger_plan_selected',
      message: '分析完成：已生成新的自动触发计划「${triggerPlan.title}」',
      conversationId: conversationId,
      metadata: {
        'kind': triggerPlan.kind.name,
        'delayMinutes': triggerPlan.delayMinutes,
        'allowNight': triggerPlan.allowNight,
        'priority': triggerPlan.priority.name,
      },
    );

    await _clearConversationAutoTriggers(
      conversationId,
      reason: 'replaced_by_analyzer',
    );

    final lastUserMessage = await _ref
        .read(chatHistoryStoreProvider)
        .getLastUserMessage(conversationId);
    final cachedContent =
        await _ref.read(proactiveMessagePregeneratorProvider).generate(
              conversation: conversation,
              contextMessages: decision.contextMessages,
              systemReminder: triggerPlan.systemReminder,
            );

    final existingTrigger = _findActiveAiTriggerForConversation(conversationId);
    if (existingTrigger != null) {
      await _setState(currentState.withPendingAutoTrigger(existingTrigger.id));
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'trigger_plan_skipped_existing_pending',
        message: '跳过创建主动回复触发器：当前会话已有待发送触发器',
        conversationId: conversationId,
        triggerId: existingTrigger.id,
        title: existingTrigger.title,
        source: existingTrigger.source,
      );
      return;
    }

    final createdTrigger = await controller.createTrigger(
      title: triggerPlan.title,
      type: AutoReplyTriggerType.delay,
      nextFireAt: DateTime.now().add(
        Duration(minutes: triggerPlan.delayMinutes),
      ),
      allowNight: triggerPlan.allowNight,
      requireExact: false,
      delayMinutes: triggerPlan.delayMinutes,
      prompt: triggerPlan.systemReminder,
      priority: triggerPlan.priority,
      source: TriggerSource.aiScheduler,
      conversationId: conversationId,
      contextLastUserMessageId: lastUserMessage?.id,
      contextLastUserMessageAt: lastUserMessage?.createdAt,
      cachedContent: cachedContent,
      preparedAt: cachedContent == null ? null : DateTime.now(),
    );
    // 后台 WorkManager 任务由 createTrigger 内部统一注册，这里不再重复注册

    final nextState = currentState.copyWith(
      mode: ConversationProactiveMode.active,
      silenceUntil: null,
      pendingAutoTriggerId: createdTrigger.id,
    );
    await _setState(nextState);
  }

  AutoReplyTrigger? _findActiveAiTriggerForConversation(String conversationId) {
    final currentTriggers =
        _ref.read(autoReplyTriggersProvider).valueOrNull ?? const [];
    for (final trigger in currentTriggers) {
      if (trigger.conversationId != conversationId) continue;
      if (trigger.source != TriggerSource.aiScheduler) continue;
      if (trigger.isActive || trigger.status == AutoReplyTriggerStatus.paused) {
        return trigger;
      }
    }
    return null;
  }

  ConversationProactiveState _applySessionPatch({
    required ConversationProactiveState currentState,
    required ContextAnalysisSessionPatch? patch,
  }) {
    if (patch == null) return currentState;
    return currentState.applySessionPatch(
      mode: patch.mode,
      silenceDuration: patch.silenceDuration,
      now: DateTime.now(),
    );
  }

  Future<void> _clearConversationAutoTriggers(
    String conversationId, {
    String? reason,
  }) async {
    final currentTriggers =
        _ref.read(autoReplyTriggersProvider).valueOrNull ?? const [];
    final controller = _ref.read(autoReplyTriggersProvider.notifier);
    for (final trigger in currentTriggers) {
      if (trigger.conversationId != conversationId) continue;
      if (trigger.source != TriggerSource.aiScheduler) continue;
      if (!trigger.isActive &&
          trigger.status != AutoReplyTriggerStatus.paused) {
        continue;
      }
      await controller.deleteTrigger(
        trigger.id,
        reason: reason,
      );
    }
  }

  void _restoreTimers() {
    for (final timer in _analysisTimers.values) {
      timer.cancel();
    }
    for (final timer in _silentTimers.values) {
      timer.cancel();
    }
    _analysisTimers.clear();
    _silentTimers.clear();

    final now = DateTime.now();
    for (final state in _states.values) {
      final conversation = _ref.read(
        resolvedConversationByIdProvider(state.conversationId),
      );
      if (conversation != null &&
          !_isSupervisorEnabledForConversation(conversation)) {
        continue;
      }
      if (state.mode == ConversationProactiveMode.dormant) {
        continue;
      }
      if (state.hasPendingAutoTrigger) {
        continue;
      }
      if (state.mode == ConversationProactiveMode.silent &&
          state.silenceUntil != null) {
        _scheduleSilentTimer(
          conversationId: state.conversationId,
          wakeAt: state.silenceUntil!,
        );
        continue;
      }
      if (state.mode == ConversationProactiveMode.active &&
          state.lastUserAt != null) {
        final elapsed = now.difference(state.lastUserAt!);
        final delay =
            elapsed < _defaultDelay ? _defaultDelay - elapsed : _immediateDelay;
        final reason =
            elapsed < _defaultDelay ? '5分钟无新消息(恢复)' : '5分钟无新消息(恢复补跑)';
        _scheduleAnalysisTimer(
          conversationId: state.conversationId,
          delay: delay,
          reason: reason,
        );
      }
    }
  }

  void _scheduleForState(ConversationProactiveState state) {
    final conversationId = state.conversationId;
    final conversation =
        _ref.read(resolvedConversationByIdProvider(conversationId));
    if (conversation != null &&
        !_isSupervisorEnabledForConversation(conversation)) {
      _cancelTimers(conversationId);
      return;
    }
    if (state.mode == ConversationProactiveMode.dormant) {
      _cancelTimers(conversationId);
      return;
    }
    if (state.hasPendingAutoTrigger) {
      _analysisTimers.remove(conversationId)?.cancel();
      _silentTimers.remove(conversationId)?.cancel();
      return;
    }
    if (state.mode == ConversationProactiveMode.silent &&
        state.silenceUntil != null) {
      _analysisTimers.remove(conversationId)?.cancel();
      _scheduleSilentTimer(
        conversationId: conversationId,
        wakeAt: state.silenceUntil!,
      );
      return;
    }
  }

  void _scheduleAnalysisTimer({
    required String conversationId,
    required Duration delay,
    required String reason,
  }) {
    _analysisTimers.remove(conversationId)?.cancel();
    _analysisTimers[conversationId] = Timer(delay, () {
      _analysisTimers.remove(conversationId);
      unawaited(_runAnalysis(
        conversationId: conversationId,
        reason: reason,
      ));
    });

    _log(
      'analyzer:scheduled',
      {
        'conversationId': conversationId,
        'delayMs': delay.inMilliseconds,
        'reason': reason,
      },
      level: 'DEBUG',
    );
    unawaited(
      _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.wakeup,
        event: 'analysis_scheduled',
        message: '已安排默认唤醒：$reason',
        conversationId: conversationId,
        metadata: {
          'delayMs': delay.inMilliseconds,
          'reason': reason,
        },
      ),
    );
  }

  void _scheduleSilentTimer({
    required String conversationId,
    required DateTime wakeAt,
  }) {
    _silentTimers.remove(conversationId)?.cancel();
    final now = DateTime.now();
    final delay =
        wakeAt.isAfter(now) ? wakeAt.difference(now) : _immediateDelay;
    _silentTimers[conversationId] = Timer(delay, () {
      _silentTimers.remove(conversationId);
      unawaited(_runAnalysis(
        conversationId: conversationId,
        reason: 'silent_wakeup',
      ));
    });

    _log(
      'analyzer:silent_scheduled',
      {
        'conversationId': conversationId,
        'delayMs': delay.inMilliseconds,
      },
      level: 'DEBUG',
    );
    unawaited(
      _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.wakeup,
        event: 'silent_wakeup_scheduled',
        message: '已安排 silent 沉默期唤醒',
        conversationId: conversationId,
        metadata: {
          'wakeAt': wakeAt.toIso8601String(),
          'delayMs': delay.inMilliseconds,
        },
      ),
    );
  }

  void _cancelTimers(String conversationId) {
    _analysisTimers.remove(conversationId)?.cancel();
    _silentTimers.remove(conversationId)?.cancel();
  }

  bool _isSupervisorEnabledForConversation(Conversation conversation) {
    return conversation.allowsPlugin(_triggerPluginId);
  }

  Future<void> _setState(ConversationProactiveState state) async {
    _states[state.conversationId] = state;
    await _storage.saveStates(_states);
  }

  Future<void> _syncHeartbeat(DateTime timestamp) async {
    try {
      final settings = await _ref.read(appSettingsProvider.future);
      if (settings.backendApiKey.isEmpty) return;

      final agent = AgentApiClient();
      await agent.syncTriggerHeartbeat(
        timestamp,
        token: settings.backendApiKey,
      );
      _log(
        'cloud:heartbeat_sent',
        {'timestamp': timestamp.toIso8601String()},
        level: 'DEBUG',
      );
    } catch (e) {
      _log('cloud:heartbeat_failed', {'error': e.toString()}, level: 'WARN');
    }
  }

  void cancel() {
    _backgroundAnalysisTimer?.cancel();
    _backgroundAnalysisTimer = null;
    for (final timer in _analysisTimers.values) {
      timer.cancel();
    }
    for (final timer in _silentTimers.values) {
      timer.cancel();
    }
    _analysisTimers.clear();
    _silentTimers.clear();
  }

  void _log(String name, Map<String, Object?> data, {String level = 'INFO'}) {
    final metadata = <String, dynamic>{};
    data.forEach((k, v) {
      if (v != null) metadata[k] = v;
    });

    switch (level.toUpperCase()) {
      case 'DEBUG':
        AppLogger.debug('AnalyzerScheduler', name, metadata: metadata);
        break;
      case 'WARN':
        AppLogger.warning('AnalyzerScheduler', name, metadata: metadata);
        break;
      case 'ERROR':
        AppLogger.error('AnalyzerScheduler', name, metadata: metadata);
        break;
      default:
        AppLogger.info('AnalyzerScheduler', name, metadata: metadata);
    }
  }
}

final analyzerSchedulerProvider = Provider<AnalyzerScheduler>((ref) {
  final scheduler = AnalyzerScheduler(ref);
  ref.onDispose(scheduler.cancel);
  return scheduler;
});
