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
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/services/android_keep_alive_manager.dart';
import '../../../core/sync/cloud_local_write.dart';
import '../../chat/chat_providers.dart';
import '../../chat/conversation_providers.dart';
import '../../observability/model_request_ledger.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/services/chat_history_store.dart';
import '../../settings/app_settings.dart';
import 'auto_reply_claim_store.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_controller.dart';
import 'auto_reply_trigger_storage.dart';
import 'context_analyzer.dart';
import 'conversation_proactive_state.dart';
import 'conversation_proactive_state_storage.dart';
import 'proactive_message_pregenerator.dart';
import '../domain/proactive_action.dart' show ProactiveDraft;
import 'proactive_owner_device.dart';
import 'proactive_planner.dart';

class AnalyzerScheduler {
  static const String _triggerPluginId = 'trigger';

  AnalyzerScheduler(this._ref) {
    _initFuture = _initialize();
    final idleSubscription = _ref
        .read(conversationIdleEventsProvider)
        .stream
        .listen(
          (conversationId) => unawaited(_onConversationIdle(conversationId)),
        );
    _ref.onDispose(() => unawaited(idleSubscription.cancel()));
  }

  final Ref _ref;

  late final ConversationProactiveStateStorage _storage;
  late Future<void> _initFuture;
  final Map<String, ConversationProactiveState> _states =
      <String, ConversationProactiveState>{};
  final Map<String, Timer> _analysisTimers = <String, Timer>{};
  final Map<String, Timer> _silentTimers = <String, Timer>{};
  final Set<String> _runningAnalysisConversationIds = <String>{};
  final Map<String, Future<void>> _analysisRuns = {};
  final Map<String, int> _analysisGenerations = {};
  final AutoReplyTriggerStorage _historyStorage = AutoReplyTriggerStorage();
  Future<void> _stateWrites = Future<void>.value();
  Future<void> _nativeAlarmQueue = Future<void>.value();
  int _stateRevision = 0;
  int _refreshRevision = 0;
  int _nativeAlarmRevision = 0;
  bool _nativeAlarmEnabled = true;
  bool _disposed = false;
  bool _nativeAlarmsOnly = false;
  bool _nativeAlarmRunning = false;

  static const Duration _defaultDelay = Duration(minutes: 5);
  static const Duration _immediateDelay = Duration(seconds: 1);

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

  Future<void> _onConversationIdle(String conversationId) async {
    await _initFuture;
    final state = _states[conversationId];
    if (state == null ||
        state.mode != ConversationProactiveMode.active ||
        state.hasPendingAutoTrigger ||
        _ref.read(conversationSendingProvider(conversationId))) {
      return;
    }
    final conversation = _ref.read(
      resolvedConversationByIdProvider(conversationId),
    );
    if (conversation == null ||
        !_isSupervisorEnabledForConversation(conversation) ||
        !await _ownsConversation(conversationId)) {
      return;
    }
    scheduleAnalysis(conversationId: conversationId, delay: _defaultDelay);
  }

  Future<void> _initialize() async {
    _storage = ConversationProactiveStateStorage();
    await refreshFromStorage();
  }

  Future<void> refreshFromStorage() async {
    if (_disposed) return;
    final refreshRevision = ++_refreshRevision;
    await _stateWrites;
    final stateRevision = _stateRevision;
    await (await SharedPreferences.getInstance()).reload();
    final loaded = await _storage.loadStates();
    if (_disposed ||
        stateRevision != _stateRevision ||
        refreshRevision != _refreshRevision) {
      return;
    }
    _states
      ..clear()
      ..addAll(loaded);
    _stateRevision++;
    _nativeAlarmEnabled = true;
    await _restoreTimers();
    await _syncNativeAnalyzerAlarm();
  }

  Future<void> onConversationCleared(String conversationId) async {
    _analysisGenerations[conversationId] =
        (_analysisGenerations[conversationId] ?? 0) + 1;
    _cancelTimers(conversationId);
    await _initFuture;
    await cloudLocalWrite(() async {
      _cancelTimers(conversationId);
      await _setState(
        ConversationProactiveState(conversationId: conversationId),
      );
      await _ref.read(autoReplyTriggersProvider.future);
      await _ref
          .read(autoReplyTriggersProvider.notifier)
          .removeTriggersForConversation(
            conversationId,
            onlyAutoScheduled: true,
          );
    });
  }

  Future<void> onConversationDeleted(String conversationId) async {
    _analysisGenerations[conversationId] =
        (_analysisGenerations[conversationId] ?? 0) + 1;
    _cancelTimers(conversationId);
    await _initFuture;
    await cloudLocalWrite(() async {
      _cancelTimers(conversationId);
      _states.remove(conversationId);
      await _persistStates();
      await _syncNativeAnalyzerAlarm();
      await _ref.read(autoReplyTriggersProvider.future);
      await _ref
          .read(autoReplyTriggersProvider.notifier)
          .removeTriggersForConversation(conversationId);
    });
  }

  Future<void> handleUserMessageActivity({
    required String conversationId,
    required String? messageId,
    required DateTime occurredAt,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) return;

    await _initFuture;
    await ProactiveOwnership.claim(normalizedConversationId);
    await _ref.read(autoReplyTriggersProvider.future);
    _ref.read(autoReplyTriggersProvider.notifier).reschedule();
    final conversation = _ref.read(
      resolvedConversationByIdProvider(normalizedConversationId),
    );
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
        message: '跳过主动回复观察：当前联系人已关闭主动回复插件',
        conversationId: normalizedConversationId,
        level: AutoReplyTriggerLogLevel.warning,
      );
      return;
    }
    await _clearConversationAutoTriggers(
      normalizedConversationId,
      reason: 'user_new_message',
    );
    _cancelTimers(normalizedConversationId);

    final current =
        _states[normalizedConversationId] ??
        ConversationProactiveState(conversationId: normalizedConversationId);
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

    final current =
        _states[conversationId] ??
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
    final next = current.clearPendingAutoTrigger(
      triggerId: normalizedTriggerId,
    );
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

    final latestUser = await _ref
        .read(chatHistoryStoreProvider)
        .getLastUserMessage(conversationId);
    final stateBeforeCompletion = _states[conversationId];
    final userReplied =
        latestUser != null &&
        latestUser.id != trigger.contextLastUserMessageId &&
        (trigger.contextLastUserMessageAt == null
            ? latestUser.createdAt.isAfter(trigger.createdAt)
            : !latestUser.createdAt.isBefore(
                trigger.contextLastUserMessageAt!,
              ));
    final activityReplied =
        stateBeforeCompletion?.lastUserAt != null &&
        stateBeforeCompletion!.lastUserMessageId !=
            trigger.contextLastUserMessageId &&
        stateBeforeCompletion.lastUserAt!.isAfter(trigger.createdAt);
    if (userReplied || activityReplied) {
      // Keep a new observation timer and its active state; the old send no
      // longer counts as an unanswered attempt after the user's response.
      if (stateBeforeCompletion != null) {
        await _setState(
          stateBeforeCompletion.clearPendingAutoTrigger(triggerId: trigger.id),
        );
      }
      return;
    }

    if (!success) {
      if (retryable) {
        final current =
            _states[conversationId] ??
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
    final current =
        _states[conversationId] ??
        ConversationProactiveState(conversationId: conversationId);
    final remaining = await _findActiveAiTriggerForConversation(
      conversationId,
      excludeTriggerId: trigger.id,
    );
    if (remaining != null) {
      final next = current.copyWith(
        mode: ConversationProactiveMode.active,
        silenceUntil: null,
        unrepliedCount: current.unrepliedCount + 1,
        lastProactiveAt: occurredAt,
        pendingAutoTriggerId: remaining.id,
      );
      await _setState(next);
      return;
    }
    final next = current
        .clearPendingAutoTrigger(triggerId: trigger.id)
        .afterSuccessfulAutoTriggerSend(occurredAt: occurredAt);
    await _setState(next);
    _scheduleForState(next);
  }

  Future<void> syncConversationActivation(Conversation conversation) async {
    await _initFuture;
    if (!_isSupervisorEnabledForConversation(conversation)) {
      _analysisGenerations[conversation.id] =
          (_analysisGenerations[conversation.id] ?? 0) + 1;
      _cancelTimers(conversation.id);
      await _clearConversationAutoTriggers(
        conversation.id,
        reason: 'disabled_by_conversation_plugin',
      );
      final current = _states[conversation.id];
      if (current != null) {
        await _setState(current.withPendingAutoTrigger(null));
      }
      return;
    }
    final current = _states[conversation.id];
    if (current != null) {
      _scheduleForState(await _reconcilePendingTrigger(current));
    }
  }

  void scheduleAnalysis({
    String? conversationId,
    Duration delay = _defaultDelay,
    String reason = '5分钟无新消息',
  }) {
    final resolvedConversationId =
        conversationId?.trim() ??
        _ref.read(activeConversationIdProvider)?.trim();
    if (resolvedConversationId == null || resolvedConversationId.isEmpty) {
      return;
    }
    unawaited(
      _scheduleAnalysisInternal(
        conversationId: resolvedConversationId,
        delay: delay,
        reason: reason,
      ),
    );
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
    _log('analyzer:background_keep_schedule', {
      'analysisTimers': _analysisTimers.length,
      'silentTimers': _silentTimers.length,
    }, level: 'DEBUG');
    unawaited(_syncNativeAnalyzerAlarm());
  }

  Future<void> onAppResumed() async {
    await _initFuture;
    await _ref.read(autoReplyTriggersProvider.future);
    await _ref.read(autoReplyTriggersProvider.notifier).reloadFromStorage();
    await refreshFromStorage();
  }

  /// The native receiver keeps its wake lease until analysis and drafting end.
  Future<void> onNativeAlarmFired() async {
    _nativeAlarmRunning = true;
    _stopLocalTimers();
    try {
      await _initFuture;
      for (final running in _analysisRuns.values.toList()) {
        await running;
      }
      await (await SharedPreferences.getInstance()).reload();
      await _ref.read(appSettingsProvider.notifier).refresh();
      await refreshFromStorage();
      final settings = (await _ref.read(
        appSettingsProvider.future,
      )).autoReplySettings;
      final ownership = await ProactiveOwnership.load();
      for (final stored in _states.values.toList()) {
        final state = _states[stored.conversationId];
        if (state == null || !ownership.owns(state.conversationId)) continue;
        final due = _analysisDueAt(state);
        if (due == null ||
            due.isAfter(DateTime.now().add(const Duration(seconds: 2)))) {
          continue;
        }
        final conversation = _ref.read(
          resolvedConversationByIdProvider(state.conversationId),
        );
        if (conversation == null ||
            !_isSupervisorEnabledForConversation(conversation)) {
          continue;
        }
        final contact = settings.forContact(state.conversationId);
        final quiet = QuietHours.parse(
          enabled: contact.quietHoursEnabled,
          start: contact.quietHoursStart,
          end: contact.quietHoursEnd,
        );
        if (quiet.contains(DateTime.now())) continue;
        _cancelTimers(state.conversationId);
        await _runAnalysis(
          conversationId: state.conversationId,
          reason: 'native_alarm',
        );
      }
    } finally {
      _nativeAlarmRunning = false;
      if (!_nativeAlarmsOnly && _nativeAlarmEnabled && !_disposed) {
        for (final state in _states.values.toList()) {
          final due = _analysisDueAt(state);
          if (due == null) continue;
          if (state.mode == ConversationProactiveMode.silent) {
            _scheduleSilentTimer(
              conversationId: state.conversationId,
              wakeAt: due,
            );
          } else {
            final remaining = due.difference(DateTime.now());
            _scheduleAnalysisTimer(
              conversationId: state.conversationId,
              delay: remaining > Duration.zero ? remaining : _immediateDelay,
              reason: 'native_alarm_restored',
              observingUntil: due,
            );
          }
        }
      }
      await _syncNativeAnalyzerAlarm();
    }
  }

  /// A short-lived headless engine must leave future work to native alarms.
  void useNativeAlarmsOnly() {
    _nativeAlarmsOnly = true;
    _stopLocalTimers();
  }

  /// Finish persistence and native scheduling before destroying a headless engine.
  Future<void> flushAlarmSchedule() async {
    await _initFuture;
    await _stateWrites;
    await _syncNativeAnalyzerAlarm();
    while (true) {
      final pending = _nativeAlarmQueue;
      await pending;
      if (identical(pending, _nativeAlarmQueue)) return;
    }
  }

  Future<void> _runAnalysis({
    required String conversationId,
    required String reason,
  }) {
    final id = conversationId.trim();
    return _analysisRuns[id] ??=
        _runAnalysisOnce(conversationId: id, reason: reason).whenComplete(() {
          _analysisRuns.remove(id);
        });
  }

  Future<void> _runAnalysisOnce({
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
        metadata: {'reason': reason},
      );
      _log('analyzer:skip_in_flight', {
        'conversationId': normalizedConversationId,
        'reason': reason,
      }, level: 'DEBUG');
      return;
    }

    AutoReplyClaimStore? claims;
    String? claimToken;
    final claimKey = 'analyzer:$normalizedConversationId';
    try {
      claims = AutoReplyClaimStore(_ref.read(databaseProvider));
      claimToken = await claims.tryClaim(
        triggerId: claimKey,
        claimedBy: AutoReplyClaimOwner.foreground,
      );
      if (claimToken == null) return;
      if (_ref.read(conversationSendingProvider(normalizedConversationId))) {
        return;
      }
      final state = _states[normalizedConversationId];
      final contact = (await _ref.read(
        appSettingsProvider.future,
      )).autoReplySettings.forContact(normalizedConversationId);
      final quiet = QuietHours.parse(
        enabled: contact.quietHoursEnabled,
        start: contact.quietHoursStart,
        end: contact.quietHoursEnd,
      );
      final now = DateTime.now();
      if (quiet.contains(now)) {
        final end = quiet.nextEnd(now);
        if (state?.mode == ConversationProactiveMode.silent) {
          _scheduleSilentTimer(
            conversationId: normalizedConversationId,
            wakeAt: end,
          );
        } else if (state?.observingUntil != null) {
          _scheduleAnalysisTimer(
            conversationId: normalizedConversationId,
            delay: end.difference(now),
            reason: 'quiet_hours_end',
            observingUntil: state!.observingUntil,
          );
        }
        return;
      }
      if (state?.observingUntil != null) {
        await _setState(state!.withObservingUntil(null));
      }
      await _runAnalysisUnlocked(
        conversationId: normalizedConversationId,
        reason: reason,
      );
    } finally {
      try {
        if (claimToken != null) await claims!.release(claimKey, claimToken);
      } catch (error) {
        AppLogger.warning(
          'AnalyzerScheduler',
          '释放分析认领失败',
          metadata: {'error': error.toString()},
        );
      } finally {
        _runningAnalysisConversationIds.remove(normalizedConversationId);
        await _syncNativeAnalyzerAlarm();
      }
    }
  }

  Future<void> _runAnalysisUnlocked({
    required String conversationId,
    required String reason,
  }) async {
    await _initFuture;
    final gen = _analysisGenerations[conversationId] ?? 0;

    final state = await _reconcilePendingTrigger(
      _states[conversationId] ??
          ConversationProactiveState(conversationId: conversationId),
    );
    if (state.mode == ConversationProactiveMode.dormant) {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_skipped_dormant',
        message: '跳过分析：当前会话处于 dormant',
        conversationId: conversationId,
      );
      _log('analyzer:skip_dormant', {
        'conversationId': conversationId,
      }, level: 'DEBUG');
      return;
    }
    if (!await _ownsConversation(conversationId)) return;
    final conversation = _ref.read(
      resolvedConversationByIdProvider(conversationId),
    );
    if (conversation == null) {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_skipped_missing_conversation',
        message: '跳过分析：找不到对应会话',
        conversationId: conversationId,
        level: AutoReplyTriggerLogLevel.warning,
      );
      _log('analyzer:skip_missing_conversation', {
        'conversationId': conversationId,
      }, level: 'WARN');
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
        message: '跳过分析：当前联系人已关闭主动回复插件',
        conversationId: conversationId,
        level: AutoReplyTriggerLogLevel.warning,
      );
      _log('analyzer:skip_trigger_plugin_disabled', {
        'conversationId': conversationId,
      }, level: 'WARN');
      return;
    }
    if (state.hasPendingAutoTrigger) {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_skipped_pending_trigger',
        message: '跳过分析：当前已有待发送的自动触发器',
        conversationId: conversationId,
      );
      _log('analyzer:skip_pending_trigger', {
        'conversationId': conversationId,
      }, level: 'DEBUG');
      return;
    }
    if (state.mode == ConversationProactiveMode.silent &&
        state.silenceUntil != null &&
        state.silenceUntil!.isAfter(
          DateTime.now().add(const Duration(seconds: 2)),
        )) {
      _scheduleSilentTimer(
        conversationId: conversationId,
        wakeAt: state.silenceUntil!,
      );
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_skipped_silent',
        message: '跳过分析：当前仍处于 silent 沉默期',
        conversationId: conversationId,
        metadata: {'silenceUntil': state.silenceUntil!.toIso8601String()},
      );
      return;
    }

    final lastUserMsg = await _ref
        .read(chatHistoryStoreProvider)
        .getLastUserMessage(conversationId);
    if (!await _isAnalysisCurrent(conversationId, gen, lastUserMsg?.id)) return;

    var effectiveState = state;
    if (effectiveState.mode == ConversationProactiveMode.silent) {
      effectiveState = effectiveState.copyWith(
        mode: ConversationProactiveMode.active,
        silenceUntil: null,
      );
      await _setState(effectiveState);
    }

    AndroidGenerationKeepAliveLease? keepAliveLease;
    try {
      try {
        keepAliveLease = await AndroidKeepAliveManager.acquireGenerationLease();
      } catch (error) {
        AppLogger.warning(
          'AnalyzerScheduler',
          '启动生成防休眠失败',
          metadata: {'error': error.toString()},
        );
      }
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
      final decision = await _ref
          .read(contextAnalyzerProvider)
          .analyze(conversation, proactiveState: effectiveState);
      if (decision == null) {
        await _appendHistoryLog(
          category: AutoReplyTriggerLogCategory.analyzer,
          event: 'analysis_no_decision',
          message: '分析完成：本轮没有生成新的触发决策',
          conversationId: conversationId,
          metadata: {'reason': reason},
        );
        _log('analyzer:no_decision', {
          'conversationId': conversationId,
          'reason': reason,
        }, level: 'DEBUG');
        return;
      }

      if (!await _isAnalysisCurrent(conversationId, gen, lastUserMsg?.id)) {
        return;
      }
      await _applyDecision(
        conversation: conversation,
        currentState: effectiveState,
        decision: decision,
        generation: gen,
        lastUserMessageId: lastUserMsg?.id,
      );
    } catch (e) {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'analysis_failed',
        message: '主动回复分析失败',
        conversationId: conversationId,
        level: AutoReplyTriggerLogLevel.error,
        metadata: {'reason': reason, 'error': e.toString()},
      );
      _log('analyzer:error', {
        'conversationId': conversationId,
        'reason': reason,
        'error': e.toString(),
      }, level: 'ERROR');
      final latestState = _states[conversationId] ?? effectiveState;
      if ((_analysisGenerations[conversationId] ?? 0) == gen &&
          latestState.mode == ConversationProactiveMode.active &&
          !_analysisTimers.containsKey(conversationId) &&
          await _findActiveAiTriggerForConversation(conversationId) == null &&
          await _ownsConversation(conversationId)) {
        _scheduleAnalysisTimer(
          conversationId: conversationId,
          delay: _defaultDelay,
          reason: 'analysis_retry',
        );
      }
    } finally {
      try {
        await keepAliveLease?.release();
      } catch (error) {
        AppLogger.warning(
          'AnalyzerScheduler',
          '释放生成防休眠失败',
          metadata: {'error': error.toString()},
        );
      }
    }
  }

  Future<bool> _isAnalysisCurrent(
    String conversationId,
    int generation,
    String? lastUserMessageId,
  ) async {
    final conv = await _ref
        .read(conversationRepositoryProvider)
        .getById(conversationId);
    if (conv == null || conv.deletedAt != null) return false;
    final latest = await _ref
        .read(chatHistoryStoreProvider)
        .getLastUserMessage(conversationId);
    return (_analysisGenerations[conversationId] ?? 0) == generation &&
        latest?.id == lastUserMessageId;
  }

  Future<void> _applyDecision({
    required Conversation conversation,
    required ConversationProactiveState currentState,
    required ContextAnalysisDecision decision,
    required int generation,
    required String? lastUserMessageId,
  }) async {
    final conversationId = conversation.id;
    final controller = _ref.read(autoReplyTriggersProvider.notifier);

    final triggerPlans = decision.triggerPlans;
    if (triggerPlans.isEmpty) {
      await cloudLocalWrite(() async {
        if (!await _isAnalysisCurrent(
          conversationId,
          generation,
          lastUserMessageId,
        )) {
          return;
        }
        final nextState = _applySessionPatch(
          currentState: currentState,
          patch: decision.sessionPatch,
        );
        await _setState(nextState);
        if ((_analysisGenerations[conversationId] ?? 0) == generation) {
          _scheduleForState(nextState);
        }
      });
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
      return;
    }

    final firstPlan = triggerPlans.first;
    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.analyzer,
      event: 'trigger_plan_selected',
      message: '分析完成：已生成新的自动触发计划「${firstPlan.title}」',
      conversationId: conversationId,
      metadata: {
        'kind': firstPlan.kind.label,
        'fireAt': firstPlan.fireAt.toIso8601String(),
        'allowNight': firstPlan.allowNight,
        'priority': firstPlan.priority.name,
        'count': triggerPlans.length,
      },
    );

    // The user may have moved to another device while the model answered:
    // its plan must not be replaced by this one.
    if (!await _ownsConversation(conversationId)) return;
    final lastUserMessage = await _ref
        .read(chatHistoryStoreProvider)
        .getLastUserMessage(conversationId);
    // Step ⑤: written for the fire time. An empty draft still schedules the
    // trigger; the reply is then written live at fire time.
    final drafts = <ProactiveDraft?>[];
    for (final plan in triggerPlans) {
      if (!await _ownsConversation(conversationId)) return;
      ProactiveDraft? draft;
      try {
        draft =
            await ModelRunScope(
              purpose: 'proactive_reply',
              conversationId: conversationId,
            ).run(
              () => _ref
                  .read(proactiveMessagePregeneratorProvider)
                  .generate(
                    conversation: conversation,
                    systemReminder: plan.systemReminder,
                    fireAt: plan.fireAt,
                    allowCall: plan.allowCall,
                  ),
            );
      } catch (error) {
        AppLogger.warning(
          'AnalyzerScheduler',
          '预生成失败，保留计划并在触发时实时生成',
          metadata: {
            'conversationId': conversationId,
            'errorType': error.runtimeType.toString(),
          },
        );
      }
      drafts.add(draft);
    }

    // The user may have spoken while the reply was being written.
    final currentLastUserMessage = await _ref
        .read(chatHistoryStoreProvider)
        .getLastUserMessage(conversationId);
    if (currentLastUserMessage?.id != lastUserMessage?.id ||
        !await _isAnalysisCurrent(
          conversationId,
          generation,
          lastUserMessageId,
        )) {
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.analyzer,
        event: 'trigger_plan_skipped_stale_context',
        message: '跳过创建主动回复触发器：生成期间用户发了新消息',
        conversationId: conversationId,
      );
      return;
    }

    // Or while the reply was being written.
    if (!await _ownsConversation(conversationId)) return;

    await cloudLocalWrite(() async {
      if (!await _isAnalysisCurrent(
        conversationId,
        generation,
        lastUserMessageId,
      )) {
        return;
      }
      final existingTrigger = await _findActiveAiTriggerForConversation(
        conversationId,
      );
      if (existingTrigger != null) {
        await _setState(
          currentState.withPendingAutoTrigger(existingTrigger.id),
        );
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

      await _clearConversationAutoTriggers(
        conversationId,
        reason: 'replaced_by_analyzer',
      );

      final createdTriggers = <AutoReplyTrigger>[];
      for (var i = 0; i < triggerPlans.length; i++) {
        final plan = triggerPlans[i];
        final draft = drafts[i];
        final cachedContent = draft?.text;
        final created = await controller.createTrigger(
          title: plan.title,
          type: AutoReplyTriggerType.delay,
          nextFireAt: plan.fireAt,
          allowNight: plan.allowNight,
          requireExact: false,
          delayMinutes: plan.fireAt
              .difference(DateTime.now())
              .inMinutes
              .clamp(1, 100000)
              .toInt(),
          prompt: plan.systemReminder,
          priority: plan.priority,
          source: TriggerSource.aiScheduler,
          conversationId: conversationId,
          contextLastUserMessageId: lastUserMessage?.id,
          contextLastUserMessageAt: lastUserMessage?.createdAt,
          cachedContent: cachedContent,
          // The reply is written for the fire time, so freshness is measured
          // from there: a reply sent on time is fresh however early it was written.
          preparedAt: cachedContent == null ? null : plan.fireAt,
          action: draft?.action ?? ProactiveAction.sendMessage,
        );
        createdTriggers.add(created);
      }
      // 后台 WorkManager 任务由 createTrigger 内部统一注册，这里不再重复注册

      if (!await _isAnalysisCurrent(
        conversationId,
        generation,
        lastUserMessageId,
      )) {
        return;
      }
      final nextState = currentState.copyWith(
        mode: ConversationProactiveMode.active,
        silenceUntil: null,
        pendingAutoTriggerId: createdTriggers.first.id,
      );
      await _setState(nextState);
    });
  }

  Future<AutoReplyTrigger?> _findActiveAiTriggerForConversation(
    String conversationId, {
    String? excludeTriggerId,
  }) async {
    final currentTriggers = await _historyStorage.loadTriggers();
    AutoReplyTrigger? earliest;
    for (final trigger in currentTriggers) {
      if (trigger.conversationId != conversationId) continue;
      if (excludeTriggerId != null && trigger.id == excludeTriggerId) continue;
      if (trigger.source != TriggerSource.aiScheduler) continue;
      if (trigger.isActive || trigger.status == AutoReplyTriggerStatus.paused) {
        if (earliest == null ||
            trigger.nextFireAt.isBefore(earliest.nextFireAt)) {
          earliest = trigger;
        }
      }
    }
    return earliest;
  }

  Future<ConversationProactiveState> _reconcilePendingTrigger(
    ConversationProactiveState current,
  ) async {
    final live = await _findActiveAiTriggerForConversation(
      current.conversationId,
    );
    if (_disposed || !identical(_states[current.conversationId], current)) {
      return _states[current.conversationId] ?? current;
    }
    if (current.pendingAutoTriggerId == live?.id) return current;
    final next = current.withPendingAutoTrigger(live?.id);
    await _setState(next);
    return next;
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
    if (_disposed) return;
    await _ref.read(autoReplyTriggersProvider.future);
    final currentTriggers = await _historyStorage.loadTriggers();
    if (_disposed) return;
    final controller = _ref.read(autoReplyTriggersProvider.notifier);
    for (final trigger in currentTriggers) {
      if (trigger.conversationId != conversationId) continue;
      if (trigger.source != TriggerSource.aiScheduler) continue;
      if (reason == 'user_new_message' &&
          trigger.priority == AutoReplyTriggerPriority.high) {
        continue;
      }
      if (!trigger.isActive &&
          trigger.status != AutoReplyTriggerStatus.paused) {
        continue;
      }
      await controller.deleteTrigger(trigger.id, reason: reason);
    }
  }

  /// Another device answers for this conversation: stop watching it here.
  Future<bool> _ownsConversation(String conversationId) async {
    final ownership = await ProactiveOwnership.load();
    if (ownership.owns(conversationId) &&
        (await ModelRequestLedger.instance.activeRemoteRunsForConversation(
          conversationId,
        )).isEmpty) {
      return true;
    }
    _cancelTimers(conversationId);
    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.analyzer,
      event: 'analysis_skipped_other_device',
      message: '跳过分析：这个会话由用户最后发消息的另一台设备负责主动回复',
      conversationId: conversationId,
    );
    _log('analyzer:skip_other_device', {
      'conversationId': conversationId,
    }, level: 'DEBUG');
    return false;
  }

  Future<void> _restoreTimers() async {
    if (_disposed) return;
    for (final timer in _analysisTimers.values) {
      timer.cancel();
    }
    for (final timer in _silentTimers.values) {
      timer.cancel();
    }
    _analysisTimers.clear();
    _silentTimers.clear();

    final now = DateTime.now();
    for (final stored in _states.values.toList()) {
      if (_disposed) return;
      if (!identical(_states[stored.conversationId], stored)) continue;
      final state = await _reconcilePendingTrigger(stored);
      if (_disposed) return;
      final conversation = _ref.read(
        resolvedConversationByIdProvider(state.conversationId),
      );
      if (conversation != null &&
          !_isSupervisorEnabledForConversation(conversation)) {
        await _clearConversationAutoTriggers(
          state.conversationId,
          reason: 'disabled_by_conversation_plugin',
        );
        await _setState(state.withPendingAutoTrigger(null));
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
          !_ref.read(conversationSendingProvider(state.conversationId)) &&
          await _ownsConversation(state.conversationId) &&
          (state.lastUserAt != null || state.observingUntil != null)) {
        if (_disposed) return;
        if (state.observingUntil != null) {
          final remaining = state.observingUntil!.difference(now);
          _scheduleAnalysisTimer(
            conversationId: state.conversationId,
            delay: remaining > Duration.zero ? remaining : _immediateDelay,
            reason: 'active_observation_restored',
            observingUntil: state.observingUntil,
          );
          continue;
        }
        final elapsed = now.difference(state.lastUserAt!);
        final delay = elapsed < _defaultDelay
            ? _defaultDelay - elapsed
            : _immediateDelay;
        final reason = elapsed < _defaultDelay
            ? '5分钟无新消息(恢复)'
            : '5分钟无新消息(恢复补跑)';
        _scheduleAnalysisTimer(
          conversationId: state.conversationId,
          delay: delay,
          reason: reason,
        );
      }
    }
  }

  void _scheduleForState(ConversationProactiveState state) {
    if (_disposed) return;
    unawaited(_syncNativeAnalyzerAlarm());
    final conversationId = state.conversationId;
    final conversation = _ref.read(
      resolvedConversationByIdProvider(conversationId),
    );
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
    if (state.mode == ConversationProactiveMode.active &&
        state.lastUserAt != null &&
        !_analysisTimers.containsKey(conversationId)) {
      final due = state.observingUntil ?? state.lastUserAt!.add(_defaultDelay);
      final now = DateTime.now();
      _scheduleAnalysisTimer(
        conversationId: conversationId,
        delay: due.isAfter(now) ? due.difference(now) : _immediateDelay,
        reason: 'active_observation',
      );
    }
  }

  void _scheduleAnalysisTimer({
    required String conversationId,
    required Duration delay,
    required String reason,
    DateTime? observingUntil,
  }) {
    if (_disposed) return;
    _nativeAlarmEnabled = true;
    final current =
        _states[conversationId] ??
        ConversationProactiveState(conversationId: conversationId);
    _states[conversationId] = current.withObservingUntil(
      observingUntil ?? DateTime.now().add(delay),
    );
    unawaited(_persistStates());
    unawaited(_syncNativeAnalyzerAlarm());
    _analysisTimers.remove(conversationId)?.cancel();
    if (!_nativeAlarmsOnly && !_nativeAlarmRunning) {
      _analysisTimers[conversationId] = Timer(delay, () {
        _analysisTimers.remove(conversationId);
        unawaited(_runAnalysis(conversationId: conversationId, reason: reason));
      });
    }

    _log('analyzer:scheduled', {
      'conversationId': conversationId,
      'delayMs': delay.inMilliseconds,
      'reason': reason,
    }, level: 'DEBUG');
    unawaited(
      _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.wakeup,
        event: 'analysis_scheduled',
        message: '已安排默认唤醒：$reason',
        conversationId: conversationId,
        metadata: {'delayMs': delay.inMilliseconds, 'reason': reason},
      ),
    );
  }

  void _scheduleSilentTimer({
    required String conversationId,
    required DateTime wakeAt,
  }) {
    if (_disposed) return;
    _nativeAlarmEnabled = true;
    _silentTimers.remove(conversationId)?.cancel();
    final now = DateTime.now();
    final delay = wakeAt.isAfter(now)
        ? wakeAt.difference(now)
        : _immediateDelay;
    if (!_nativeAlarmsOnly && !_nativeAlarmRunning) {
      _silentTimers[conversationId] = Timer(delay, () {
        _silentTimers.remove(conversationId);
        unawaited(
          _runAnalysis(conversationId: conversationId, reason: 'silent_wakeup'),
        );
      });
    }
    unawaited(_syncNativeAnalyzerAlarm());

    _log('analyzer:silent_scheduled', {
      'conversationId': conversationId,
      'delayMs': delay.inMilliseconds,
    }, level: 'DEBUG');
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
    unawaited(_syncNativeAnalyzerAlarm());
  }

  bool _isSupervisorEnabledForConversation(Conversation conversation) {
    return conversation.allowsPlugin(_triggerPluginId);
  }

  Future<void> _setState(ConversationProactiveState state) async {
    if (_disposed) return;
    _states[state.conversationId] = state;
    await _persistStates();
    await _syncNativeAnalyzerAlarm();
  }

  Future<void> _persistStates() {
    _stateRevision++;
    final snapshot = Map<String, ConversationProactiveState>.of(_states);
    final write = _stateWrites.then((_) => _storage.saveStates(snapshot));
    _stateWrites = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        AppLogger.warning(
          'AnalyzerScheduler',
          '保存主动回复状态失败',
          metadata: {'error': error.toString()},
        );
      },
    );
    return write;
  }

  DateTime? _analysisDueAt(ConversationProactiveState state) {
    return switch (state.mode) {
      ConversationProactiveMode.active =>
        state.hasPendingAutoTrigger ? null : state.observingUntil,
      ConversationProactiveMode.silent => state.silenceUntil,
      ConversationProactiveMode.dormant => null,
    };
  }

  /// Serialize native writes and discard obsolete snapshots before invoking
  /// the channel. A slow earlier schedule cannot overwrite a later cancel.
  Future<void> _syncNativeAnalyzerAlarm() {
    if (_disposed) return Future<void>.value();
    final revision = ++_nativeAlarmRevision;
    final sync = _nativeAlarmQueue.then((_) async {
      if (revision != _nativeAlarmRevision) return;
      DateTime? earliest;
      var exact = false;
      if (_nativeAlarmEnabled) {
        final settings = (await _ref.read(
          appSettingsProvider.future,
        )).autoReplySettings;
        final ownership = await ProactiveOwnership.load();
        if (_disposed || revision != _nativeAlarmRevision) return;
        final now = DateTime.now();
        for (final state in _states.values) {
          if (!ownership.owns(state.conversationId) ||
              _runningAnalysisConversationIds.contains(state.conversationId)) {
            continue;
          }
          var due = _analysisDueAt(state);
          if (due == null) continue;
          final conversation = _ref.read(
            resolvedConversationByIdProvider(state.conversationId),
          );
          if (conversation == null ||
              !_isSupervisorEnabledForConversation(conversation)) {
            continue;
          }
          final contact = settings.forContact(state.conversationId);
          final quiet = QuietHours.parse(
            enabled: contact.quietHoursEnabled,
            start: contact.quietHoursStart,
            end: contact.quietHoursEnd,
          );
          if (due.isBefore(now)) due = now;
          if (quiet.contains(due)) due = quiet.nextEnd(due);
          if (earliest == null || due.isBefore(earliest)) {
            earliest = due;
            exact = settings.allowExactAlarm;
          }
        }
      }
      if (revision != _nativeAlarmRevision) return;
      if (earliest == null) {
        await AndroidKeepAliveManager.cancelProactiveAlarm('analyzer');
      } else {
        await AndroidKeepAliveManager.scheduleProactiveAlarm(
          slot: 'analyzer',
          fireAt: earliest,
          exact: exact,
        );
      }
    });
    _nativeAlarmQueue = sync.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        AppLogger.warning(
          'AnalyzerScheduler',
          '同步主动回复分析闹钟失败',
          metadata: {'error': error.toString()},
        );
      },
    );
    return _nativeAlarmQueue;
  }

  void cancel() {
    _nativeAlarmEnabled = false;
    _stopLocalTimers();
    unawaited(_syncNativeAnalyzerAlarm());
  }

  void _stopLocalTimers() {
    for (final timer in _analysisTimers.values) {
      timer.cancel();
    }
    for (final timer in _silentTimers.values) {
      timer.cancel();
    }
    _analysisTimers.clear();
    _silentTimers.clear();
  }

  void _dispose() {
    _disposed = true;
    _nativeAlarmRevision++;
    _stopLocalTimers();
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
  ref.onDispose(scheduler._dispose);
  return scheduler;
});
