import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/app_logger.dart';
import '../../../core/database/database_provider.dart';
import '../../chat/providers2.dart';
import '../../chat/services/chat_history_store.dart';
import 'auto_reply_claim_store.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_storage.dart';
import 'background_service.dart';
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
  late AutoReplyTriggerStorage _storage;

  AutoReplyClaimStore get _claimStore =>
      AutoReplyClaimStore(ref.read(databaseProvider));

  @override
  Future<List<AutoReplyTrigger>> build() async {
    _storage = AutoReplyTriggerStorage();
    final triggers = await _storage.loadTriggers();
    _startTicker();
    ref.onDispose(() {
      _ticker?.cancel();
    });
    return triggers;
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await _storage.loadTriggers());
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
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final updated = [...current, trigger];
    await _persist(updated);
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
    );

    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final updated = [...current, trigger];
    await _persist(updated);
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

    return trigger;
  }

  /// 作废触发器
  Future<void> expireTrigger(String triggerId, String reason) async {
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final target = current.where((t) => t.id == triggerId).firstOrNull;
    if (target == null || !target.isActive) return;

    final updated = current.map((t) {
      if (t.id != triggerId) return t;
      return t.copyWith(
        status: AutoReplyTriggerStatus.expired,
        expireReason: reason,
        lastFiredAt: DateTime.now(),
      );
    }).toList();

    await _persist(updated);
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
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final target =
        current.where((element) => element.id == id).toList(growable: false);
    if (target.isEmpty) return;
    final updated = current.where((e) => e.id != id).toList();
    await _persist(updated);
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
  }

  Future<void> togglePause(String id) async {
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final updated = current.map((trigger) {
      if (trigger.id != id) return trigger;
      final nextStatus = trigger.status == AutoReplyTriggerStatus.paused
          ? AutoReplyTriggerStatus.pending
          : AutoReplyTriggerStatus.paused;
      return trigger.copyWith(status: nextStatus);
    }).toList();
    await _persist(updated);
    final changed = updated.firstWhere((e) => e.id == id);
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
  }

  Future<void> fireNow(String id) async {
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final trigger = current.where((t) => t.id == id).firstOrNull;
    if (trigger == null) return;

    final activeChatId = ref.read(activeConversationIdProvider);
    final expireReason = await _checkShouldExpire(trigger, activeChatId);
    if (expireReason != null) {
      await expireTrigger(id, expireReason);
      return;
    }

    await _handleTrigger(id, DateTime.now());
  }

  void _startTicker() {
    _ticker ??=
        Timer.periodic(const Duration(seconds: 30), (_) => _pollDueTriggers());
    _pollDueTriggers(); // run immediately once
  }

  Future<void> _pollDueTriggers() async {
    final current = state.valueOrNull;
    if (current == null || current.isEmpty) return;
    final settings = await ref.read(appSettingsProvider.future);
    final autoReplySettings = settings.autoReplySettings;

    final now = DateTime.now();
    final quietHoursActive = autoReplySettings.quietHoursEnabled &&
        _isInQuietHours(now,
            start: autoReplySettings.quietHoursStart,
            end: autoReplySettings.quietHoursEnd);

    final firedTodayCount = current.where((t) {
      if (t.status != AutoReplyTriggerStatus.fired || t.lastFiredAt == null) {
        return false;
      }
      return _isSameDay(t.lastFiredAt!, now);
    }).length;
    if (firedTodayCount >= autoReplySettings.dailyLimit) {
      AppLogger.info('AutoReplyTrigger', 'Skip polling: daily limit reached',
          metadata: {
            'dailyLimit': autoReplySettings.dailyLimit,
            'firedToday': firedTodayCount,
          });
      return;
    }

    final latestFiredAt = current
        .where((t) =>
            t.status == AutoReplyTriggerStatus.fired && t.lastFiredAt != null)
        .map((t) => t.lastFiredAt!)
        .fold<DateTime?>(null, (latest, firedAt) {
      if (latest == null || firedAt.isAfter(latest)) return firedAt;
      return latest;
    });
    if (latestFiredAt != null &&
        now.difference(latestFiredAt).inMinutes <
            autoReplySettings.minIntervalMinutes) {
      return;
    }

    // Check if chat is active
    final activeChatId = ref.read(activeConversationIdProvider);

    // 触发到期的触发器
    for (final trigger in current) {
      if (quietHoursActive && !trigger.allowNight) {
        continue;
      }

      if (trigger.requireExact && !autoReplySettings.allowExactAlarm) {
        continue;
      }

      if (trigger.requireExact &&
          autoReplySettings.allowExactAlarm &&
          now.difference(trigger.nextFireAt) > const Duration(minutes: 2)) {
        await expireTrigger(trigger.id, '错过精确触发窗口');
        continue;
      }

      if (trigger.shouldFire(now, allowNightOverride: false)) {
        // ===== 作废检查（在标记 fired 之前）=====
        final expireCheckResult =
            await _checkShouldExpire(trigger, activeChatId);
        if (expireCheckResult != null) {
          // 应该作废，不触发
          await expireTrigger(trigger.id, expireCheckResult);
          continue;
        }
        // ===== 作废检查结束 =====

        await _handleTrigger(trigger.id, now);
      }
    }

    // 清理过期的已完成触发器（保留最近24小时的记录用于查看日志）
    await _cleanupCompletedTriggers(now);
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isInQuietHours(DateTime now,
      {required String start, required String end}) {
    int parseMinutes(String value, int fallbackHour, int fallbackMinute) {
      final parts = value.split(':');
      if (parts.length != 2) return fallbackHour * 60 + fallbackMinute;
      final hour = int.tryParse(parts[0]);
      final minute = int.tryParse(parts[1]);
      if (hour == null || minute == null) {
        return fallbackHour * 60 + fallbackMinute;
      }
      return hour.clamp(0, 23).toInt() * 60 + minute.clamp(0, 59).toInt();
    }

    final nowMinutes = now.hour * 60 + now.minute;
    final startMinutes = parseMinutes(start, 22, 0);
    final endMinutes = parseMinutes(end, 8, 0);

    if (startMinutes == endMinutes) return false;
    if (startMinutes < endMinutes) {
      return nowMinutes >= startMinutes && nowMinutes < endMinutes;
    }
    return nowMinutes >= startMinutes || nowMinutes < endMinutes;
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
    // 同步清理过期的执行权认领记录
    try {
      await _claimStore.cleanupBefore(cutoffTime);
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

    final updated =
        current.where((t) => !toDelete.any((d) => d.id == t.id)).toList();
    await _persist(updated);

    // 记录清理日志
    if (toDelete.isNotEmpty) {
      for (final deleted in toDelete) {
        AppLogger.debug('AutoReplyTrigger',
            'Auto-cleaned trigger: ${deleted.title} (done at: ${deleted.lastFiredAt})');
      }
    }
  }

  Future<void> _handleTrigger(String id, DateTime firedAt) async {
    final current = await _storage.loadTriggers();
    if (current.isEmpty) return;
    final latest = current.where((t) => t.id == id).firstOrNull;
    if (latest == null || !latest.isActive) {
      return;
    }

    // 执行权认领：与后台 WorkManager 链路互斥，认领失败说明后台已在执行
    final claimed = await _claimStore.tryClaim(
      triggerId: id,
      claimedBy: AutoReplyClaimOwner.foreground,
    );
    if (!claimed) {
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
      return;
    }

    var changed = false;
    final updated = current.map((trigger) {
      if (trigger.id != id) return trigger;
      changed = true;
      return trigger.copyWith(
        status: AutoReplyTriggerStatus.fired,
        lastFiredAt: firedAt,
      );
    }).toList();
    if (!changed) return;
    await _persist(updated);

    final fired = updated.firstWhere((e) => e.id == id);
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
    _emitEvent(AutoReplyTriggerEventType.fired, fired);
  }

  Future<void> completeTriggeredSend({
    required String triggerId,
    required DateTime firedAt,
    required bool success,
    required bool retryable,
    required String reason,
  }) async {
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final target = current.where((t) => t.id == triggerId).firstOrNull;
    if (target == null) return;

    final now = DateTime.now();
    List<AutoReplyTrigger> updated = current;

    if (success) {
      updated = current.map((t) {
        if (t.id != triggerId) return t;
        return t.copyWith(
          status: AutoReplyTriggerStatus.fired,
          lastFiredAt: firedAt,
          expireReason: null,
        );
      }).toList();
      await _persist(updated);
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
      updated = current.map((t) {
        if (t.id != triggerId) return t;
        return t.copyWith(
          status: AutoReplyTriggerStatus.pending,
          nextFireAt: retryAt,
          lastFiredAt: null,
          expireReason: reason,
        );
      }).toList();
      await _persist(updated);
      // 释放执行权认领，让重试可以重新认领
      await _claimStore.release(triggerId);
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
      updated = current.map((t) {
        if (t.id != triggerId) return t;
        return t.copyWith(
          status: AutoReplyTriggerStatus.expired,
          lastFiredAt: now,
          expireReason: reason,
        );
      }).toList();
      await _persist(updated);
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
  }

  Future<void> _persist(List<AutoReplyTrigger> triggers) async {
    await _storage.saveTriggers(triggers);
    state = AsyncData(triggers);
  }

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
      {String? reason}) {
    final event = AutoReplyTriggerEvent(
      type: type,
      triggerId: trigger.id,
      title: trigger.title,
      timestamp: DateTime.now(),
      conversationId: trigger.conversationId,
      source: trigger.source,
      reason: reason,
    );
    ref.read(autoReplyTriggerEventBusProvider).emit(event);
    ref.read(autoReplyTriggerEventProvider.notifier).state = event;
  }
}
