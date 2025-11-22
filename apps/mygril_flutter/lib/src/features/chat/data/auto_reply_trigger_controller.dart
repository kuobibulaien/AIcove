import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/app_logger.dart';
import '../providers2.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_storage.dart';

final autoReplyTriggerEventProvider =
    StateProvider<AutoReplyTriggerEvent?>((ref) => null);

final autoReplyTriggersProvider = AsyncNotifierProvider<
    AutoReplyTriggerController, List<AutoReplyTrigger>>(
  AutoReplyTriggerController.new,
);

class AutoReplyTriggerController
    extends AsyncNotifier<List<AutoReplyTrigger>> {
  final _uuid = const Uuid();
  Timer? _ticker;
  late AutoReplyTriggerStorage _storage;

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
    final trigger = AutoReplyTrigger(
      id: _uuid.v4(),
      title: (title?.trim().isEmpty ?? true) ? '自定义触发' : title!.trim(),
      type: type,
      status: AutoReplyTriggerStatus.scheduled,
      createdAt: DateTime.now(),
      nextFireAt: nextFireAt,
      allowNight: allowNight,
      requireExact: requireExact,
      delayMinutes: delayMinutes,
      manual: true,
      contactId: contactId,
      prompt: prompt,
      priority: priority,
    );
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final updated = [...current, trigger];
    await _persist(updated);
    AppLogger.info('AutoReplyTrigger', 'Created manual trigger: ${trigger.title} (Priority: ${priority.name})');
    _emitEvent(AutoReplyTriggerEventType.created, trigger);
  }

  Future<void> deleteTrigger(String id) async {
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final target =
        current.where((element) => element.id == id).toList(growable: false);
    if (target.isEmpty) return;
    final updated = current.where((e) => e.id != id).toList();
    await _persist(updated);
    AppLogger.info('AutoReplyTrigger', 'Deleted trigger: $id');
    _emitEvent(AutoReplyTriggerEventType.deleted, target.first);
  }

  Future<void> togglePause(String id) async {
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    final updated = current.map((trigger) {
      if (trigger.id != id) return trigger;
      final nextStatus = trigger.status == AutoReplyTriggerStatus.paused
          ? AutoReplyTriggerStatus.scheduled
          : AutoReplyTriggerStatus.paused;
      return trigger.copyWith(status: nextStatus);
    }).toList();
    await _persist(updated);
    final changed = updated.firstWhere((e) => e.id == id);
    _emitEvent(
      changed.status == AutoReplyTriggerStatus.paused
          ? AutoReplyTriggerEventType.paused
          : AutoReplyTriggerEventType.resumed,
      changed,
    );
  }

  Future<void> fireNow(String id) async {
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
    final now = DateTime.now();
    
    // Check if chat is active
    final activeChatId = ref.read(activeConversationIdProvider);
    final isChatActive = activeChatId != null;
    
    // 触发到期的触发器
    for (final trigger in current) {
      if (trigger.shouldFire(now, allowNightOverride: false)) {
        // Check for Low Priority Drop Rule
        if (trigger.priority == AutoReplyTriggerPriority.low && isChatActive) {
           AppLogger.info('AutoReplyTrigger', 'Dropping low priority trigger because chat is active: ${trigger.title}');
           // Mark as completed without firing
           await _handleTrigger(trigger.id, now, drop: true);
           continue;
        }
        await _handleTrigger(trigger.id, now);
      }
    }
    
    // 清理过期的已完成触发器（保留最近24小时的记录用于查看日志）
    await _cleanupCompletedTriggers(now);
  }

  /// 清理过期的已完成触发器
  /// 保留最近24小时内完成的触发器，删除更早的
  Future<void> _cleanupCompletedTriggers(DateTime now) async {
    final current = state.valueOrNull;
    if (current == null || current.isEmpty) return;
    
    final cutoffTime = now.subtract(const Duration(hours: 24));
    final toDelete = current.where((trigger) {
      return trigger.status == AutoReplyTriggerStatus.completed &&
             trigger.lastFiredAt != null &&
             trigger.lastFiredAt!.isBefore(cutoffTime);
    }).toList();
    
    if (toDelete.isEmpty) return;
    
    final updated = current.where((t) => !toDelete.any((d) => d.id == t.id)).toList();
    await _persist(updated);
    
    // 记录清理日志
    if (toDelete.isNotEmpty) {
      for (final deleted in toDelete) {
        print('[AutoReplyTriggerController] Auto-cleaned completed trigger: ${deleted.title} (fired at: ${deleted.lastFiredAt})');
      }
    }
  }

  Future<void> _handleTrigger(String id, DateTime firedAt, {bool drop = false}) async {
    final current = state.valueOrNull ?? const <AutoReplyTrigger>[];
    if (current.isEmpty) return;
    var changed = false;
    final updated = current.map((trigger) {
      if (trigger.id != id) return trigger;
      changed = true;
      return trigger.copyWith(
        status: AutoReplyTriggerStatus.completed,
        lastFiredAt: firedAt,
      );
    }).toList();
    if (!changed) return;
    await _persist(updated);
    
    if (drop) {
      // If dropped, we don't fire the event or log as success
      // Optionally log as dropped if needed
      return;
    }

    final fired = updated.firstWhere((e) => e.id == id);
    await _storage.appendLog(AutoReplyTriggerLog(
      id: _uuid.v4(),
      triggerId: fired.id,
      title: fired.title,
      firedAt: firedAt,
      success: true,
    ));
    AppLogger.info('AutoReplyTrigger', 'Trigger fired: ${fired.title}');
    _emitEvent(AutoReplyTriggerEventType.fired, fired);
  }

  Future<void> _persist(List<AutoReplyTrigger> triggers) async {
    await _storage.saveTriggers(triggers);
    state = AsyncData(triggers);
  }

  void _emitEvent(AutoReplyTriggerEventType type, AutoReplyTrigger trigger) {
    ref.read(autoReplyTriggerEventProvider.notifier).state = AutoReplyTriggerEvent(
      type: type,
      triggerId: trigger.id,
      title: trigger.title,
      timestamp: DateTime.now(),
    );
  }
}
