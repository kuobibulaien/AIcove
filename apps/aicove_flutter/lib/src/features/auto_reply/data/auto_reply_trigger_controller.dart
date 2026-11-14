import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../../core/app_logger.dart';
import '../../../core/services/android_keep_alive_manager.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/sync/cloud_local_write.dart';
import '../../chat/providers2.dart';
import '../../chat/services/chat_history_store.dart';
import 'auto_reply_claim_store.dart';
import 'analyzer_scheduler.dart';
import 'auto_reply_dispatch_service.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_storage.dart';
import 'background_service.dart';
import 'proactive_owner_device.dart';
import 'proactive_call_ledger.dart';
import 'proactive_planner.dart';
import '../../settings/app_settings.dart';

final autoReplyTriggerEventProvider =
    StateProvider<AutoReplyTriggerEvent?>((ref) => null);

/// 顺序事件总线：保证后台消费方按发生顺序逐个处理触发器事件，
/// 避免单值 StateProvider 在同一帧内被覆盖导致丢事件（AR-034）。
/// `autoReplyTriggerEventProvider` 保留给 UI 做轻量刷新提示。
class AutoReplyTriggerEventBus {
  final StreamController<AutoReplyTriggerEvent> _controller =
      StreamController<AutoReplyTriggerEvent>.broadcast();

  Stream<AutoReplyTriggerEvent> get stream => _controller.stream;

  void emit(AutoReplyTriggerEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  void dispose() {
    _controller.close();
  }
}

final autoReplyTriggerEventBusProvider =
    Provider<AutoReplyTriggerEventBus>((ref) {
  final bus = AutoReplyTriggerEventBus();
  ref.onDispose(bus.dispose);
  return bus;
});

final autoReplyTriggersProvider =
    AsyncNotifierProvider<AutoReplyTriggerController, List<AutoReplyTrigger>>(
  AutoReplyTriggerController.new,
);

class AutoReplyTriggerController extends AsyncNotifier<List<AutoReplyTrigger>> {
  final _uuid = const Uuid();
  Timer? _ticker;
  Future<void>? _activePoll;
  bool _pollAgain = false;
  int _pollFailures = 0;
  bool _disposed = false;
  bool _alarmPoll = false;
  bool _nativeAlarmsOnly = false;
  int _wakeRevision = 0;
  Future<void> _wakeSync = Future<void>.value();
  late AutoReplyTriggerStorage _storage;

  /// Triggers whose send is under way in this process. The trigger stays
  /// active until delivery (2f: fired is marked after delivery); this keeps
  /// the ticker from re-firing it meanwhile. Entries lapse with the claim
  /// lease, so a send that never reported back is retried like a killed
  /// process would be.
  final Map<String, ({DateTime since, String token})> _inFlight = {};

  bool _isInFlight(String id, DateTime now) {
    final entry = _inFlight[id];
    if (entry == null) return false;
    if (now.difference(entry.since) < AutoReplyClaimStore.lease) return true;
    _inFlight.remove(id);
    return false;
  }



  AutoReplyClaimStore get _claimStore =>
      AutoReplyClaimStore(ref.read(databaseProvider));

  @override
  Future<List<AutoReplyTrigger>> build() async {
    _storage = AutoReplyTriggerStorage();
    final triggers = await _storage.loadTriggers();
    ref.listen(appSettingsProvider.select((s) => s.valueOrNull?.autoReplySettings),
        (prev, next) {
      if (prev != next) _scheduleFromStored(state.valueOrNull);
    });
    _scheduleFromStored(triggers);
    ref.onDispose(() {
      _disposed = true;
      _ticker?.cancel();
    });
    return triggers;
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await _storage.loadTriggers());
    _scheduleFromStored(state.valueOrNull);
  }

  /// Picks up a list written by sync. Keeps the current value meanwhile, so
  /// a write in between never starts from an empty list.
  Future<void> reloadFromStorage() => cloudLocalWrite(() async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        state = AsyncData(await _storage.loadTriggers());
        _scheduleFromStored(state.valueOrNull);
      });

  Future<void> removeTriggersForConversation(
    String conversationId, {
    bool onlyAutoScheduled = false,
  }) async {
    final removed = <AutoReplyTrigger>[];
    await _update((stored) => stored.where((trigger) {
          final matches = trigger.conversationId == conversationId &&
              (!onlyAutoScheduled || trigger.source == TriggerSource.aiScheduler);
          if (matches) removed.add(trigger);
          return !matches;
        }).toList());
    for (final trigger in removed) {
      _inFlight.remove(trigger.id);
      await _cancelBackgroundTaskByTriggerId(trigger.id);
      _emitEvent(AutoReplyTriggerEventType.deleted, trigger);
    }
    _scheduleFromStored(state.valueOrNull);
  }

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
    await _storage.appendLog(
      AutoReplyTriggerLog(
        id: _uuid.v4(),
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

  Future<void> createManualTrigger({
    required AutoReplyTriggerType type,
    required DateTime nextFireAt,
    required bool allowNight,
    required bool requireExact,
    int delayMinutes = 30,
    String? title,
    String? contactId,
    String? prompt,
    AutoReplyTriggerPriority priority = AutoReplyTriggerPriority.medium,
  }) async {
    // 获取当前会话的最后一条用户消息（用于作废判断）
    final convId = contactId ?? ref.read(activeConversationIdProvider) ?? '';
    if (convId.isEmpty) {
      AppLogger.warning('AutoReplyTrigger',
          'Skip creating manual trigger: no conversation bound');
      return;
    }
    final lastUserMessage =
        await ref.read(chatHistoryStoreProvider).getLastUserMessage(convId);

    final trigger = AutoReplyTrigger(
      id: _uuid.v4(),
      title: (title?.trim().isEmpty ?? true) ? '自定义触发' : title!.trim(),
      type: type,
      status: AutoReplyTriggerStatus.pending,
      createdAt: DateTime.now(),
      nextFireAt: nextFireAt,
      allowNight: allowNight,
      requireExact: requireExact,
      delayMinutes: delayMinutes,
      manual: true,
      contactId: contactId,
      prompt: prompt,
      priority: priority,
      conversationId: convId,
      source: TriggerSource.userManual,
      contextLastUserMessageId: lastUserMessage?.id,
      contextLastUserMessageAt: lastUserMessage?.createdAt,
    );
    await _update((stored) => [...stored, trigger]);
    await _scheduleBackgroundTaskForTrigger(trigger);
    AppLogger.info('AutoReplyTrigger',
        'Created manual trigger: ${trigger.title} (Priority: ${priority.name})');
    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.trigger,
      event: 'manual_created',
      message: '已创建手动触发器：${trigger.title}',
      triggerId: trigger.id,
      title: trigger.title,
      conversationId: trigger.conversationId,
      source: trigger.source,
      metadata: {
        'priority': priority.name,
        'nextFireAt': trigger.nextFireAt.toIso8601String(),
        'allowNight': trigger.allowNight,
        'requireExact': trigger.requireExact,
      },
    );
    _emitEvent(AutoReplyTriggerEventType.created, trigger);
    _scheduleFromStored(state.valueOrNull);
  }

  /// 创建触发器（新版，支持所有新字段）
  /// 由 TriggerPlugin 和 ContextAnalyzer 调用
  Future<AutoReplyTrigger> createTrigger({
    required String title,
    required AutoReplyTriggerType type,
    required DateTime nextFireAt,
    required bool allowNight,
    required bool requireExact,
    required int delayMinutes,
    required String conversationId,
    String? prompt,
    AutoReplyTriggerPriority priority = AutoReplyTriggerPriority.medium,
    TriggerSource source = TriggerSource.userManual,
    String? contextLastUserMessageId,
    DateTime? contextLastUserMessageAt,
    String? contextSnapshot,
    String? cachedContent,
    DateTime? preparedAt,
    AutoReplyTriggerStatus? status,
    ProactiveAction action = ProactiveAction.sendMessage,
  }) async {
    final normalizedConversationId = conversationId.trim();
    if (normalizedConversationId.isEmpty) {
      throw ArgumentError('conversationId is required');
    }

    final trigger = AutoReplyTrigger(
      id: _uuid.v4(),
      title: title.trim().isEmpty ? '自定义触发' : title.trim(),
      type: type,
      status: status ??
          ((cachedContent?.trim().isNotEmpty ?? false)
              ? AutoReplyTriggerStatus.prepared
              : AutoReplyTriggerStatus.pending),
      createdAt: DateTime.now(),
      nextFireAt: nextFireAt,
      allowNight: allowNight,
      requireExact: requireExact,
      delayMinutes: delayMinutes,
      manual: source == TriggerSource.userManual ||
          source == TriggerSource.userRequest,
      prompt: prompt,
      priority: priority,
      conversationId: normalizedConversationId,
      source: source,
      contextLastUserMessageId: contextLastUserMessageId,
      contextLastUserMessageAt: contextLastUserMessageAt,
      contextSnapshot: contextSnapshot,
      cachedContent:
          cachedContent?.trim().isEmpty ?? true ? null : cachedContent!.trim(),
      preparedAt: preparedAt,
      // A call without its opening line cannot ring; it is written live.
      action: cachedContent?.trim().isEmpty ?? true
          ? ProactiveAction.sendMessage
          : action,
    );

    await _update((stored) => [...stored, trigger]);
    await _scheduleBackgroundTaskForTrigger(trigger);

    AppLogger.info('AutoReplyTrigger', 'Created trigger', metadata: {
      'title': trigger.title,
      'priority': priority.name,
      'source': source.name,
      'conversationId': normalizedConversationId,
    });
    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.trigger,
      event: 'created',
      message: '已创建触发器：${trigger.title}',
      triggerId: trigger.id,
      title: trigger.title,
      conversationId: normalizedConversationId,
      source: source,
      metadata: {
        'priority': priority.name,
        'status': trigger.status.name,
        'type': trigger.type.name,
        'nextFireAt': trigger.nextFireAt.toIso8601String(),
        'hasCachedContent': trigger.hasCachedContent,
      },
    );
    _emitEvent(AutoReplyTriggerEventType.created, trigger);
    _scheduleFromStored(state.valueOrNull);

    return trigger;
  }

  /// 作废触发器
  Future<void> expireTrigger(String triggerId, String reason) async {
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final target = current.where((t) => t.id == triggerId).firstOrNull;
    if (target == null || !target.isActive) return;

    // 以存储里的最新状态为准：期间已送达、暂停或被同步改掉的不再作废。
    var expired = false;
    await _update((stored) => stored.map((t) {
          if (t.id != triggerId || !t.isActive) return t;
          expired = true;
          return t.copyWith(
            status: AutoReplyTriggerStatus.expired,
            expireReason: reason,
            lastFiredAt: DateTime.now(),
          );
        }).toList());
    if (!expired) return;
    await _cancelBackgroundTaskByTriggerId(triggerId);
    AppLogger.info('AutoReplyTrigger', 'Trigger expired', metadata: {
      'id': triggerId,
      'title': target.title,
      'reason': reason,
    });
    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.trigger,
      event: 'expired',
      message: '触发器已作废：${target.title}',
      triggerId: target.id,
      title: target.title,
      conversationId: target.conversationId,
      source: target.source,
      success: false,
      level: AutoReplyTriggerLogLevel.warning,
      metadata: {
        'reason': reason,
      },
    );
    _emitEvent(AutoReplyTriggerEventType.expired, target, reason: reason);
  }

  /// 获取指定会话的待触发列表
  List<AutoReplyTrigger> getPendingTriggers(String conversationId) {
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    return current
        .where((t) => t.conversationId == conversationId && t.isActive)
        .toList()
      ..sort((a, b) => a.nextFireAt.compareTo(b.nextFireAt));
  }

  /// 按 query 搜索触发器（用于 search_reminders 工具）
  List<AutoReplyTrigger> searchTriggers({
    required String query,
    String? conversationId,
    bool includeCompleted = false,
    int limit = 5,
  }) {
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final lowerQuery = query.toLowerCase();

    return current
        .where((t) {
          // 会话过滤
          if (conversationId != null && t.conversationId != conversationId) {
            return false;
          }
          // 状态过滤
          if (!includeCompleted && !t.isActive) {
            return false;
          }
          // 关键词匹配
          return t.title.toLowerCase().contains(lowerQuery) ||
              (t.prompt?.toLowerCase().contains(lowerQuery) ?? false);
        })
        .take(limit)
        .toList();
  }

  AutoReplyTrigger? findTriggerById(String triggerId) {
    final normalizedTriggerId = triggerId.trim();
    if (normalizedTriggerId.isEmpty) return null;
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    return current.where((t) => t.id == normalizedTriggerId).firstOrNull;
  }

  Future<void> deleteTrigger(String id, {String? reason}) async {
    final current = await _storage.loadTriggers();
    final target =
        current.where((element) => element.id == id).toList(growable: false);
    if (target.isEmpty) return;
    await _update((stored) => stored.where((e) => e.id != id).toList());
    await _cancelBackgroundTaskByTriggerId(id);
    AppLogger.info('AutoReplyTrigger', 'Deleted trigger: $id');
    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.trigger,
      event: 'deleted',
      message: reason == null || reason.trim().isEmpty
          ? '已删除触发器：${target.first.title}'
          : '已删除触发器：${target.first.title}',
      triggerId: target.first.id,
      title: target.first.title,
      conversationId: target.first.conversationId,
      source: target.first.source,
      metadata: {
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
    );
    _emitEvent(AutoReplyTriggerEventType.deleted, target.first);
    _scheduleFromStored(state.valueOrNull);
  }

  Future<void> togglePause(String id) async {
    final updated = await _update((stored) => stored.map((trigger) {
          if (trigger.id != id) return trigger;
          final nextStatus = trigger.status == AutoReplyTriggerStatus.paused
              ? AutoReplyTriggerStatus.pending
              : AutoReplyTriggerStatus.paused;
          return trigger.copyWith(status: nextStatus);
        }).toList());
    final changed = updated.where((e) => e.id == id).firstOrNull;
    if (changed == null) return;
    if (changed.status == AutoReplyTriggerStatus.paused) {
      await _cancelBackgroundTaskByTriggerId(changed.id);
    } else {
      await _scheduleBackgroundTaskForTrigger(changed);
    }
    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.trigger,
      event: changed.status == AutoReplyTriggerStatus.paused
          ? 'paused'
          : 'resumed',
      message: changed.status == AutoReplyTriggerStatus.paused
          ? '已暂停触发器：${changed.title}'
          : '已恢复触发器：${changed.title}',
      triggerId: changed.id,
      title: changed.title,
      conversationId: changed.conversationId,
      source: changed.source,
    );
    _emitEvent(
      changed.status == AutoReplyTriggerStatus.paused
          ? AutoReplyTriggerEventType.paused
          : AutoReplyTriggerEventType.resumed,
      changed,
    );
    _scheduleFromStored(state.valueOrNull);
  }

  Future<void> fireNow(String id) async {
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final trigger = current.where((t) => t.id == id).firstOrNull;
    if (trigger == null) return;
    // 用户在本机手动触发：本机接手这个会话的主动回复，送达前的复查才放行。
    await ProactiveOwnership.claim(trigger.conversationId);

    final activeChatId = ref.read(activeConversationIdProvider);
    final expireReason = await _checkShouldExpire(trigger, activeChatId);
    if (expireReason != null) {
      await expireTrigger(id, expireReason);
      return;
    }

    await _handleTrigger(id, DateTime.now());
    unawaited(_pollDueTriggers());
  }

  /// A headless engine only runs work awaited by its native slot consumer.
  /// Local timers would outlive that consumer's accounting and emit events
  /// without a foreground service to finish delivery.
  void useNativeAlarmsOnly() {
    _nativeAlarmsOnly = true;
    _ticker?.cancel();
    _ticker = null;
  }

  void reschedule() => _scheduleFromStored(state.valueOrNull);

  /// Flush pending native writes without cancelling future alarms on dispose.
  Future<void> flushAlarmSchedule() async {
    Future<void> pending;
    do {
      pending = _wakeSync;
      await pending;
    } while (!identical(pending, _wakeSync));
  }

  @visibleForTesting
  Future<void> pollDueTriggersForTest() => _pollDueTriggers();

  /// Native alarms run without AutoReplyService's event consumer. Dispatch and
  /// settle every due send here before allowing the headless engine to close.
  Future<void> pollDueTriggersForAlarm() async {
    _alarmPoll = true;
    try {
      await reloadFromStorage();
      await _pollDueTriggers();
      await flushAlarmSchedule();
    } finally {
      _alarmPoll = false;
    }
  }

  void _scheduleFromStored(List<AutoReplyTrigger>? triggers) {
    if (_disposed) return;
    if (_activePoll != null) {
      _pollAgain = true;
      return;
    }
    final revision = ++_wakeRevision;
    _wakeSync = _wakeSync.then((_) async {
      final ownership = await ProactiveOwnership.load();
      if (_disposed || revision != _wakeRevision) return;
      final now = DateTime.now();
      DateTime? earliest;
      var requiresExact = false;
      for (final trigger in triggers ?? const <AutoReplyTrigger>[]) {
        if (!trigger.isActive || !ownership.owns(trigger.conversationId)) continue;
        final candidate = _isInFlight(trigger.id, now)
            ? _inFlight[trigger.id]!.since.add(AutoReplyClaimStore.lease)
            : trigger.nextFireAt;
        if (earliest == null || candidate.isBefore(earliest)) {
          earliest = candidate;
          requiresExact = trigger.requireExact;
        } else if (candidate.isAtSameMomentAs(earliest)) {
          requiresExact |= trigger.requireExact;
        }
      }
      await _scheduleWakeTimer(earliest, requiresExact: requiresExact);
    }).catchError((Object error, StackTrace stack) {
      AppLogger.warning('AutoReplyTrigger', 'Trigger alarm sync failed',
          metadata: {'error': error.toString()});
    });
  }

  Future<void> _scheduleWakeTimer(DateTime? earliestWakeAt,
      {bool requiresExact = false}) async {
    if (_disposed) return;
    _ticker?.cancel();
    _ticker = null;
    if (!_nativeAlarmsOnly && earliestWakeAt != null) {
      final delay = earliestWakeAt.difference(DateTime.now());
      _ticker = Timer(
        delay < const Duration(seconds: 1) ? const Duration(seconds: 1) : delay,
        () => unawaited(_pollDueTriggers()),
      );
    }
    final settings = await ref.read(appSettingsProvider.future);
    await syncProactiveTriggerAlarm(
      earliestWakeAt,
      exact: settings.autoReplySettings.allowExactAlarm || requiresExact,
    );
  }

  Future<void> _pollDueTriggers() {
    if (_disposed) return Future.value();
    if (_activePoll != null) {
      _pollAgain = true;
      return _activePoll!;
    }
    return _activePoll = _runPollLoop().whenComplete(() => _activePoll = null);
  }

  Future<void> _runPollLoop() async {
    ++_wakeRevision;
    await _wakeSync;
    _ticker?.cancel();
    _ticker = null;
    try {
      do {
        _pollAgain = false;
        await _pollDueTriggersUnlocked();
        _pollFailures = 0;
      } while (_pollAgain && !_disposed);
    } catch (error, stackTrace) {
      AppLogger.warning('AutoReplyTrigger', 'Trigger poll failed',
          metadata: {'error': error.toString(), 'stackTrace': stackTrace.toString()});
      if (!_disposed && (state.valueOrNull?.any((t) => t.isActive) ?? false)) {
        _ticker?.cancel();
        final seconds = 1 << (_pollFailures < 6 ? _pollFailures : 6);
        _pollFailures++;
        final retryDelay = Duration(seconds: seconds);
        if (!_nativeAlarmsOnly) {
          _ticker = Timer(retryDelay, () => unawaited(_pollDueTriggers()));
        }
        // A headless isolate has no surviving Dart timer after completion.
        // Keep a native retry even when settings could not be loaded.
        try {
          await syncProactiveTriggerAlarm(DateTime.now().add(retryDelay),
              exact: false);
        } catch (alarmError) {
          AppLogger.warning('AutoReplyTrigger', 'Trigger retry alarm failed',
              metadata: {'error': alarmError.toString()});
        }
      }
    } finally {
      if (_disposed) _ticker?.cancel();
    }
  }

  Future<void> _pollDueTriggersUnlocked() async {
    final current = state.valueOrNull;
    if (current == null) return;
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(hours: 24));
    if (current.any((t) =>
        (t.status == AutoReplyTriggerStatus.fired ||
            t.status == AutoReplyTriggerStatus.expired) &&
        t.lastFiredAt != null && t.lastFiredAt!.isBefore(cutoff))) {
      await _cleanupCompletedTriggers(now);
    }
    if (!current.any((t) => t.isActive)) {
      await _scheduleWakeTimer(null);
      return;
    }
    final settings = await ref.read(appSettingsProvider.future);
    final autoReplySettings = settings.autoReplySettings;
    final activeChatId = ref.read(activeConversationIdProvider);
    final ownership = await ProactiveOwnership.load();
    DateTime? nextWakeAt;
    var nextWakeRequiresExact = false;
    void wake(AutoReplyTrigger trigger, DateTime candidate) {
      if (nextWakeAt == null || candidate.isBefore(nextWakeAt!)) {
        nextWakeAt = candidate;
        nextWakeRequiresExact = trigger.requireExact;
      } else if (candidate.isAtSameMomentAs(nextWakeAt!)) {
        nextWakeRequiresExact |= trigger.requireExact;
      }
    }
    final dueAt = _alarmPoll ? now.add(const Duration(seconds: 2)) : now;

    for (final trigger in current) {
      if (!trigger.isActive || !ownership.owns(trigger.conversationId)) continue;
      if (_isInFlight(trigger.id, now)) {
        wake(trigger, _inFlight[trigger.id]!.since.add(AutoReplyClaimStore.lease));
        continue;
      }
      if (trigger.nextFireAt.isAfter(dueAt)) {
        wake(trigger, trigger.nextFireAt);
        continue;
      }
      try {
        if (await _settleStartedDelivery(trigger, now)) {
          final claim = await _claimStore.stateOf(trigger.id, now: now);
          if (claim is AutoReplyClaimDelivered && !claim.isStalled(now)) {
            wake(trigger, claim.startedAt.add(AutoReplyClaimStore.lease));
          } else if (claim is AutoReplyClaimHeld) {
            wake(trigger, claim.leaseEndsAt);
          } else if (claim is! AutoReplyClaimDelivered) {
            wake(trigger, now.add(const Duration(minutes: 1)));
          }
          continue;
        }
        final contactSettings = autoReplySettings.forContact(trigger.conversationId);
        final quietHours = QuietHours.parse(
          enabled: contactSettings.quietHoursEnabled,
          start: contactSettings.quietHoursStart,
          end: contactSettings.quietHoursEnd,
        );
        if (quietHours.contains(now) && !trigger.allowNight) {
          wake(trigger, quietHours.nextEnd(now));
          continue;
        }
        if (trigger.shouldFire(dueAt, allowNightOverride: false)) {
          final reason = await _checkShouldExpire(trigger, activeChatId);
          if (reason != null) {
            await _expireUnderClaim(trigger, reason, now);
          } else {
            await _handleTrigger(trigger.id, now);
          }
          if (_isInFlight(trigger.id, DateTime.now())) {
            wake(trigger, _inFlight[trigger.id]!.since.add(AutoReplyClaimStore.lease));
          } else {
            final latest = state.valueOrNull?.where((t) => t.id == trigger.id).firstOrNull;
            if (latest != null && latest.isActive) {
              final claim = await _claimStore.stateOf(trigger.id, now: now);
              if (claim is AutoReplyClaimHeld) {
                wake(trigger, claim.leaseEndsAt);
              } else if (claim is AutoReplyClaimDelivered) {
                wake(trigger, claim.startedAt.add(AutoReplyClaimStore.lease));
              } else {
                wake(trigger, now.add(const Duration(minutes: 1)));
              }
            }
          }
        }
      } catch (error) {
        AppLogger.warning('AutoReplyTrigger', 'Trigger check failed',
            metadata: {'triggerId': trigger.id, 'error': error.toString()});
        wake(trigger, now.add(const Duration(minutes: 1)));
      }
    }
    if (!_disposed) {
      await _scheduleWakeTimer(nextWakeAt,
          requiresExact: nextWakeRequiresExact);
    }
  }

  /// 检查触发器是否应该作废
  /// 返回作废原因字符串，如果不应作废则返回 null
  Future<String?> _checkShouldExpire(
      AutoReplyTrigger trigger, String? activeChatId) async {
    // 1. 获取触发器绑定的会话
    final targetConvId = trigger.conversationId.isNotEmpty
        ? trigger.conversationId
        : activeChatId;

    if (targetConvId == null || targetConvId.isEmpty) {
      return '无目标会话';
    }

    // 2. 获取目标会话
    final conversations = ref.read(conversationsProvider).valueOrNull ?? [];
    final conv = conversations.where((c) => c.id == targetConvId).firstOrNull;
    if (conv == null) {
      return '目标会话不存在';
    }

    // 3. 获取当前会话中最后一条用户消息
    final lastUserMessage = await ref
        .read(chatHistoryStoreProvider)
        .getLastUserMessage(targetConvId);
    final currentLastUserMsgId = lastUserMessage?.id;
    final currentLastUserMsgAt = lastUserMessage?.createdAt;

    // 4. 判断用户是否正在聊天界面
    final isChatActive = activeChatId == targetConvId;

    // 5. 检查是否应该作废
    if (trigger.shouldExpire(
      currentLastUserMessageId: currentLastUserMsgId,
      currentLastUserMessageAt: currentLastUserMsgAt,
      isChatActive: isChatActive,
    )) {
      return trigger.getExpireReason(
        currentLastUserMessageId: currentLastUserMsgId,
        currentLastUserMessageAt: currentLastUserMsgAt,
        isChatActive: isChatActive,
      );
    }

    return null; // 不应作废
  }

  /// 清理过期的已完成触发器
  /// 保留最近24小时内完成的触发器，删除更早的
  Future<void> _cleanupCompletedTriggers(DateTime now) async {
    final current = state.valueOrNull;
    if (current == null || current.isEmpty) return;

    final cutoffTime = now.subtract(const Duration(hours: 24));
    // 同步清理过期的执行权认领记录；仍有效的触发器的认领保留，免得清掉
    // “已开始送达”的记录后又被重新认领、重复发送。
    try {
      await _claimStore.cleanupBefore(
        cutoffTime,
        keepTriggerIds: {
          for (final trigger in current)
            if (trigger.isActive) trigger.id,
        },
      );
    } catch (e) {
      AppLogger.warning('AutoReplyTrigger', 'Claim cleanup failed',
          metadata: {'error': e.toString()});
    }
    final toDelete = current.where((trigger) {
      return (trigger.status == AutoReplyTriggerStatus.fired ||
              trigger.status == AutoReplyTriggerStatus.expired) &&
          trigger.lastFiredAt != null &&
          trigger.lastFiredAt!.isBefore(cutoffTime);
    }).toList();

    if (toDelete.isEmpty) return;

    await _update((stored) =>
        stored.where((t) => !toDelete.any((d) => d.id == t.id)).toList());

    // 记录清理日志
    if (toDelete.isNotEmpty) {
      for (final deleted in toDelete) {
        AppLogger.debug('AutoReplyTrigger',
            'Auto-cleaned trigger: ${deleted.title} (done at: ${deleted.lastFiredAt})');
      }
    }
  }

  Future<bool> _handleTrigger(String id, DateTime firedAt) async {
    final current = await _storage.loadTriggers();
    if (current.isEmpty) return false;
    final latest = current.where((t) => t.id == id).firstOrNull;
    if (latest == null || !latest.isActive || _isInFlight(id, DateTime.now())) {
      return false;
    }

    // 执行权认领：与后台 WorkManager 链路互斥，认领失败说明后台已在执行
    final token = await _claimStore.tryClaim(
      triggerId: id,
      claimedBy: AutoReplyClaimOwner.foreground,
    );
    if (token == null) {
      if (await _settleStartedDelivery(latest, DateTime.now())) return false;
      AppLogger.info('AutoReplyTrigger', 'Fire skipped: claimed elsewhere',
          metadata: {'triggerId': id});
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.trigger,
        event: 'fire_claim_lost',
        message: '前台触发已跳过：执行权已被后台任务认领',
        triggerId: latest.id,
        title: latest.title,
        conversationId: latest.conversationId,
        source: latest.source,
        level: AutoReplyTriggerLogLevel.warning,
      );
      return false;
    }

    // 送达后才标记 fired（completeTriggeredSend）；发送期间保持原状态，
    // 进程中途被杀时触发器仍有效，租约过期后可被前台或后台重新认领。
    _inFlight[id] = (since: DateTime.now(), token: token);
    final fired = latest.copyWith(
      status: AutoReplyTriggerStatus.fired,
      lastFiredAt: firedAt,
    );
    AppLogger.info('AutoReplyTrigger', 'Trigger due, dispatching send',
        metadata: {
          'triggerId': fired.id,
          'title': fired.title,
        });
    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.trigger,
      event: 'fired',
      message: '触发器到点，开始派发：${fired.title}',
      triggerId: fired.id,
      title: fired.title,
      conversationId: fired.conversationId,
      source: fired.source,
      metadata: {
        'firedAt': firedAt.toIso8601String(),
      },
    );
    if (_alarmPoll) {
      AutoReplyDispatchResult result;
      try {
        result = await ref.read(autoReplyDispatchServiceProvider)
            .dispatchTrigger(latest, claimToken: token);
      } catch (error) {
        result = AutoReplyDispatchResult.failed(error.toString());
      }
      await completeTriggeredSend(
        triggerId: id,
        firedAt: firedAt,
        success: result.success,
        retryable: result.retryable,
        reason: result.reason,
        claimToken: token,
      );
      // History/list observers still need delivery feedback; only the bus
      // would hand this send to AutoReplyService a second time.
      _emitEvent(AutoReplyTriggerEventType.fired, fired,
          claimToken: token, broadcast: false);
      await ref.read(analyzerSchedulerProvider).onAutoTriggerSendCompleted(
        trigger: latest,
        success: result.success,
        retryable: result.retryable,
        occurredAt: DateTime.now(),
      );
    } else {
      _emitEvent(AutoReplyTriggerEventType.fired, fired, claimToken: token);
    }
    return true;
  }

  Future<void> completeTriggeredSend({
    required String triggerId,
    required DateTime firedAt,
    required bool success,
    required bool retryable,
    required String reason,
    required String? claimToken,
  }) async {
    try {
      // 只清掉本次发送自己的记录；同一触发器可能已有新的发送在进行。
      if (claimToken != null && _inFlight[triggerId]?.token == claimToken) {
        _inFlight.remove(triggerId);
      }
      // 执行权已被另一方接管，那边负责收尾；生成超过租约后才返回的旧发送
      // （空内容、异常等没经过 beginDelivery 的失败）同样不得改触发器。
      // 先续租：续上了，一个租约内没人能接管，确认与写入之间不会被插队。
      // 续不上而令牌仍是当前认领，说明本次已开始送达，这条认领永不再被接管。
      if (reason == AutoReplyDispatchResult.supersededReason) return;
      if (claimToken == null ||
          !await _holdClaimForCompletion(triggerId, claimToken)) {
        AppLogger.info('AutoReplyTrigger', 'Stale send completion ignored',
            metadata: {'triggerId': triggerId, 'reason': reason});
        return;
      }
      final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
      final target = current.where((t) => t.id == triggerId).firstOrNull;
      if (target == null) {
        if (!success) {
          await _claimStore.release(triggerId, claimToken);
        }
        return;
      }

      final now = DateTime.now();
      List<AutoReplyTrigger> updated = current;

      if (success) {
        updated = await _update((stored) => stored.map((t) {
          if (t.id != triggerId) return t;
          return t.copyWith(
            status: AutoReplyTriggerStatus.fired,
            lastFiredAt: firedAt,
            expireReason: null,
          );
        }).toList());
        await _cancelBackgroundTaskByTriggerId(triggerId);
        await _appendHistoryLog(
          category: AutoReplyTriggerLogCategory.delivery,
          event: 'send_succeeded',
          message: '主动回复发送成功：${target.title}',
          triggerId: target.id,
          title: target.title,
          conversationId: target.conversationId,
          source: target.source,
          success: true,
          metadata: {
            'firedAt': firedAt.toIso8601String(),
            'reason': reason,
          },
        );
      } else if (retryable) {
        final retryAt = now.add(const Duration(minutes: 1));
        var retried = false;
        updated = await _update((stored) => stored.map((t) {
          // 发送期间用户已暂停或作废（以存储为准）：只释放认领，保留用户的决定。
          if (t.id != triggerId || !t.isActive) return t;
          retried = true;
          return t.copyWith(
            status: AutoReplyTriggerStatus.pending,
            nextFireAt: retryAt,
            lastFiredAt: null,
            expireReason: reason,
          );
        }).toList());
        // 释放执行权认领，让重试可以重新认领
        await _claimStore.release(triggerId, claimToken);
        if (!retried) return;
        final retryTrigger = updated.where((t) => t.id == triggerId).firstOrNull;
        if (retryTrigger != null) {
          await _scheduleBackgroundTaskForTrigger(retryTrigger);
        }
        AppLogger.warning(
            'AutoReplyTrigger', 'Trigger send failed, scheduled retry',
            metadata: {
              'triggerId': triggerId,
              'retryAt': retryAt.toIso8601String(),
              'reason': reason,
            });
        await _appendHistoryLog(
          category: AutoReplyTriggerLogCategory.delivery,
          event: 'send_retry_scheduled',
          message: '主动回复发送失败，1 分钟后重试：${target.title}',
          triggerId: target.id,
          title: target.title,
          conversationId: target.conversationId,
          source: target.source,
          success: false,
          level: AutoReplyTriggerLogLevel.warning,
          metadata: {
            'retryAt': retryAt.toIso8601String(),
            'reason': reason,
          },
        );
      } else {
        updated = await _update((stored) => stored.map((t) {
          if (t.id != triggerId) return t;
          return t.copyWith(
            status: AutoReplyTriggerStatus.expired,
            lastFiredAt: now,
            expireReason: reason,
          );
        }).toList());
        await _cancelBackgroundTaskByTriggerId(triggerId);
        final expired = updated.where((t) => t.id == triggerId).firstOrNull;
        if (expired != null) {
          _emitEvent(AutoReplyTriggerEventType.expired, expired, reason: reason);
        }
        AppLogger.info(
            'AutoReplyTrigger', 'Trigger expired after non-retryable send result',
            metadata: {
              'triggerId': triggerId,
              'reason': reason,
            });
        await _appendHistoryLog(
          category: AutoReplyTriggerLogCategory.delivery,
          event: 'send_failed_final',
          message: '主动回复发送失败并作废：${target.title}',
          triggerId: target.id,
          title: target.title,
          conversationId: target.conversationId,
          source: target.source,
          success: false,
          level: AutoReplyTriggerLogLevel.error,
          metadata: {
            'reason': reason,
          },
        );
      }
    } finally {
      _scheduleFromStored(state.valueOrNull);
    }
  }

  /// 自动作废与送达争同一个执行权：先认领，认领到了才作废，认领留着挡住
  /// 之后的 `beginDelivery`；没认领到说明另一方正在生成或已开始送达，本轮
  /// 不作废，已开始送达的按送达记录收尾。
  Future<void> _expireUnderClaim(
    AutoReplyTrigger trigger,
    String reason,
    DateTime now,
  ) async {
    // 已暂停、已发或已作废的不再认领，免得留下无用的认领。
    final latest = (state.valueOrNull ?? const <AutoReplyTrigger>[])
        .where((t) => t.id == trigger.id)
        .firstOrNull;
    if (latest == null || !latest.isActive) return;
    String? token;
    try {
      token = await _claimStore.tryClaim(
        triggerId: trigger.id,
        claimedBy: AutoReplyClaimOwner.foreground,
        now: now,
      );
    } catch (e) {
      AppLogger.warning('AutoReplyTrigger', 'Claim before expiry failed',
          metadata: {'triggerId': trigger.id, 'error': e.toString()});
      return;
    }
    if (token == null) {
      await _settleStartedDelivery(trigger, now);
      return;
    }
    await expireTrigger(trigger.id, reason);
  }

  /// 触发器已开始送达时返回 true：一个租约内对方可能还在写，交给对方收尾；
  /// 超过租约视为进程已被杀，不重试，按记下的消息是否存在补成终态。
  /// 认领状态读不到也返回 true，本轮跳过这条触发器。
  Future<bool> _settleStartedDelivery(
    AutoReplyTrigger trigger,
    DateTime now,
  ) async {
    final AutoReplyClaimState claim;
    try {
      claim = await _claimStore.stateOf(trigger.id, now: now);
    } catch (e) {
      AppLogger.warning('AutoReplyTrigger', 'Claim state read failed',
          metadata: {'triggerId': trigger.id, 'error': e.toString()});
      return true;
    }
    if (claim is! AutoReplyClaimDelivered) return false;
    if (claim.isStalled(now)) {
      await _finalizeInterruptedDelivery(trigger, claim);
    }
    return true;
  }

  Future<bool> _holdClaimForCompletion(String triggerId, String token) async {
    try {
      return await _claimStore.renew(triggerId, token) ||
          await _claimStore.isCurrent(triggerId, token);
    } catch (e) {
      // 读不到就当已被接管：不改状态，租约过期后由下一次认领处理。
      AppLogger.warning('AutoReplyTrigger', 'Claim check failed',
          metadata: {'triggerId': triggerId, 'error': e.toString()});
      return false;
    }
  }

  /// 开始送达后中断的触发器：开始送达时记下的消息（旧记录按后台固定编号）
  /// 已在就算送达，否则记为中断作废（开始写入后不重试，宁缺不重）。
  Future<void> _finalizeInterruptedDelivery(
    AutoReplyTrigger trigger,
    AutoReplyClaimDelivered claim,
  ) async {
    // 只收尾仍未结束的触发器；已发或已作废的不再改写时间和日志。
    final latest = (state.valueOrNull ?? const <AutoReplyTrigger>[])
        .where((t) => t.id == trigger.id)
        .firstOrNull;
    if (latest == null || !latest.isActive) return;
    final delivered = (trigger.action == ProactiveAction.callUser &&
            await ProactiveCallLedger(ref.read(databaseProvider))
                .isConfirmed(trigger.id)) ||
        await ref.read(messageRepositoryProvider).getById(
              claim.messageId ?? backgroundTriggerMessageId(trigger.id),
            ) !=
        null;
    if (delivered) {
      var finalized = false;
      await _update((stored) => stored.map((t) {
        if (t.id != trigger.id || !t.isActive) return t;
        finalized = true;
        return t.copyWith(
          status: AutoReplyTriggerStatus.fired,
          lastFiredAt: claim.startedAt,
          expireReason: null,
        );
      }).toList());
      if (finalized) {
        await ref.read(analyzerSchedulerProvider).onAutoTriggerSendCompleted(
          trigger: trigger,
          success: true,
          retryable: false,
          occurredAt: claim.startedAt,
        );
      }
    } else {
      await expireTrigger(trigger.id, interruptedDeliveryReason);
    }
    await _appendHistoryLog(
      category: AutoReplyTriggerLogCategory.delivery,
      event: 'delivery_interrupted_finalized',
      message: delivered
          ? '上次送达后中断，补记为已送达：${trigger.title}'
          : '上次开始送达后中断，不重试：${trigger.title}',
      triggerId: trigger.id,
      title: trigger.title,
      conversationId: trigger.conversationId,
      source: trigger.source,
      success: delivered,
      level: delivered
          ? AutoReplyTriggerLogLevel.info
          : AutoReplyTriggerLogLevel.warning,
    );
  }

  /// Changes the stored list, not the in-memory copy: reading, changing and
  /// saving run under the sync write lock, so a list applied by sync in
  /// between is never overwritten by a stale copy.
  Future<List<AutoReplyTrigger>> _update(
    List<AutoReplyTrigger> Function(List<AutoReplyTrigger> stored) change,
  ) =>
      cloudLocalWrite(() async {
        final updated = change(await _storage.loadTriggers());
        await _storage.saveTriggers(updated);
        state = AsyncData(updated);
        if (_activePoll == null) _scheduleFromStored(updated);
        return updated;
      });

  Future<void> _scheduleBackgroundTaskForTrigger(
    AutoReplyTrigger trigger,
  ) async {
    if (!trigger.isActive) return;

    try {
      final delay = trigger.nextFireAt.difference(DateTime.now());
      final conversation =
          ref.read(resolvedConversationByIdProvider(trigger.conversationId));

      // 模型配置不随任务快照：后台执行时现读最新设置（见 auto_reply_request_config.dart）
      await BackgroundService.scheduleOneOffTask(
        uniqueName: 'trigger_${trigger.id}',
        requiresNetwork: !trigger.hasCachedContent,
        delay: delay.isNegative ? const Duration(seconds: 1) : delay,
        inputData: {
          'triggerId': trigger.id,
          'prompt': trigger.prompt ?? '',
          'convId': trigger.conversationId,
          'userTitle': conversation?.addressUser ?? 'User',
          'characterName': conversation?.title ?? 'AIcove',
        },
      );
      await _appendHistoryLog(
        category: AutoReplyTriggerLogCategory.background,
        event: 'background_task_scheduled',
        message: '后台主动回复任务已注册：${trigger.title}',
        triggerId: trigger.id,
        title: trigger.title,
        conversationId: trigger.conversationId,
        source: trigger.source,
        metadata: {
          'nextFireAt': trigger.nextFireAt.toIso8601String(),
          'hasCachedContent': trigger.hasCachedContent,
        },
      );
    } catch (e) {
      AppLogger.warning(
        'AutoReplyTrigger',
        'Background task schedule failed',
        metadata: {
          'triggerId': trigger.id,
          'conversationId': trigger.conversationId,
          'error': e.toString(),
        },
      );
      try {
        await _appendHistoryLog(
          category: AutoReplyTriggerLogCategory.background,
          event: 'background_task_schedule_failed',
          message: '后台主动回复任务注册失败，已保留触发器',
          triggerId: trigger.id,
          title: trigger.title,
          conversationId: trigger.conversationId,
          source: trigger.source,
          success: false,
          level: AutoReplyTriggerLogLevel.warning,
          metadata: {
            'error': e.toString(),
          },
        );
      } catch (_) {}
    }
  }

  Future<void> _cancelBackgroundTaskByTriggerId(String triggerId) async {
    if (triggerId.trim().isEmpty) return;
    try {
      await BackgroundService.cancelTaskByTriggerId(triggerId);
    } catch (e) {
      AppLogger.warning(
        'AutoReplyTrigger',
        'Background task cancel failed',
        metadata: {
          'triggerId': triggerId,
          'error': e.toString(),
        },
      );
    }
  }

  void _emitEvent(AutoReplyTriggerEventType type, AutoReplyTrigger trigger,
      {String? reason, String? claimToken, bool broadcast = true}) {
    final event = AutoReplyTriggerEvent(
      type: type,
      triggerId: trigger.id,
      title: trigger.title,
      timestamp: DateTime.now(),
      conversationId: trigger.conversationId,
      source: trigger.source,
      reason: reason,
      claimToken: claimToken,
    );
    if (broadcast) ref.read(autoReplyTriggerEventBusProvider).emit(event);
    ref.read(autoReplyTriggerEventProvider.notifier).state = event;
  }
}

Future<void> _triggerAlarmSync = Future<void>.value();

/// One queue per isolate prevents a slower old schedule from winning over a
/// subsequent cancel/update. WorkManager uses the same slot after settlement.
Future<void> syncProactiveTriggerAlarm(DateTime? fireAt,
    {required bool exact}) {
  final next = _triggerAlarmSync.then((_) => fireAt == null
      ? AndroidKeepAliveManager.cancelProactiveAlarm('trigger')
      : AndroidKeepAliveManager.scheduleProactiveAlarm(
          slot: 'trigger', fireAt: fireAt, exact: exact));
  _triggerAlarmSync = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
  return next;
}
