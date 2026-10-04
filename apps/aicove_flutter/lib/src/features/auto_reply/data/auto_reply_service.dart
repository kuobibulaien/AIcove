import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../../core/services/android_keep_alive_manager.dart';
import '../../chat/conversation_providers.dart';
import '../../sync/providers/lan_sync_provider.dart';
import 'analyzer_scheduler.dart';
import 'auto_reply_dispatch_service.dart';
import 'background_message_reprocessor.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_controller.dart';

final autoReplyServiceProvider = Provider((ref) {
  final service = AutoReplyService(ref);
  ref.onDispose(service.dispose);
  ref.listen<bool>(
    androidGuardNeededProvider,
    (_, inUse) => unawaited(
      AndroidKeepAliveManager.syncGuard(inUse).catchError((Object _) {}),
    ),
    fireImmediately: true,
  );
  return service;
});

/// 是否有联系人启用了主动关怀插件；主动关怀没有全局开关，由角色卡逐个勾选。
final proactiveCareInUseProvider = Provider<bool>((ref) {
  return ref.watch(
    conversationsProvider.select(
      (listAsync) =>
          listAsync.valueOrNull?.any(
            (conversation) => conversation.allowsPlugin('trigger'),
          ) ??
          false,
    ),
  );
});

/// Android 常驻守护：主动关怀在用，或局域网同步已有配对设备时开启。
final androidGuardNeededProvider = Provider<bool>(
  (ref) => ref.watch(proactiveCareInUseProvider) || ref.watch(lanKeepsAliveProvider),
);

/// 串行事件队列：按入队顺序逐个 await 处理，避免并发处理触发器事件
/// 造成状态机写入竞争或乱序（AR-034）。
@visibleForTesting
class SerialEventQueue<T> {
  SerialEventQueue(
    this._handler, {
    void Function(Object error, StackTrace stackTrace)? onError,
  }) : _onError = onError;

  final Future<void> Function(T event) _handler;
  final void Function(Object error, StackTrace stackTrace)? _onError;
  Future<void> _tail = Future<void>.value();

  void add(T event) {
    _tail = _tail.then((_) => _handler(event)).catchError(
      (Object error, StackTrace stackTrace) {
        _onError?.call(error, stackTrace);
      },
    );
  }

  /// 等待当前已入队的事件全部处理完成（测试用）。
  Future<void> drain() => _tail;
}

class AutoReplyService {
  AutoReplyService(this._ref) {
    _ref.read(analyzerSchedulerProvider);
    _eventQueue = SerialEventQueue<AutoReplyTriggerEvent>(
      _handleEvent,
      onError: (error, stackTrace) {
        AppLogger.error(
          'AutoReplyService',
          'Trigger event processing failed',
          metadata: {'error': error.toString()},
        );
      },
    );
    _listenToEvents();
    // 启动时补渲染：后台投递期间积累的多模态消息在前台补跑插件链
    unawaited(_ref
        .read(backgroundMessageReprocessorProvider)
        .reprocessRecentBackgroundMessages());
  }

  final Ref _ref;
  late final SerialEventQueue<AutoReplyTriggerEvent> _eventQueue;
  StreamSubscription<AutoReplyTriggerEvent>? _subscription;

  void _listenToEvents() {
    _subscription = _ref
        .read(autoReplyTriggerEventBusProvider)
        .stream
        .listen(_eventQueue.add);
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _handleEvent(AutoReplyTriggerEvent event) async {
    switch (event.type) {
      case AutoReplyTriggerEventType.created:
      case AutoReplyTriggerEventType.resumed:
        await _handleCreatedOrResumedEvent(event);
        break;
      case AutoReplyTriggerEventType.deleted:
      case AutoReplyTriggerEventType.expired:
      case AutoReplyTriggerEventType.paused:
        await _ref.read(analyzerSchedulerProvider).onAutoTriggerCleared(
              conversationId: event.conversationId,
              triggerId: event.triggerId,
            );
        break;
      case AutoReplyTriggerEventType.fired:
        await _handleFiredEvent(event);
        break;
    }
  }

  Future<void> _handleCreatedOrResumedEvent(AutoReplyTriggerEvent event) async {
    final trigger = _findTrigger(event.triggerId);
    if (trigger == null) {
      return;
    }
    await _ref.read(analyzerSchedulerProvider).onAutoTriggerCreated(trigger);
  }

  Future<void> _handleFiredEvent(AutoReplyTriggerEvent event) async {
    final trigger = _findTrigger(event.triggerId);
    if (trigger == null) {
      AppLogger.warning(
        'AutoReplyService',
        'Trigger not found in state',
        metadata: {'triggerId': event.triggerId},
      );
      return;
    }

    AppLogger.info(
      'AutoReplyService',
      'Trigger fired',
      metadata: {
        'title': trigger.title,
        'id': trigger.id,
        'conversationId': trigger.conversationId,
      },
    );

    try {
      final result =
          await _ref.read(autoReplyDispatchServiceProvider).dispatchTrigger(
                trigger,
              );
      await _ref.read(autoReplyTriggersProvider.notifier).completeTriggeredSend(
            triggerId: trigger.id,
            firedAt: event.timestamp,
            success: result.success,
            retryable: result.retryable,
            reason: result.reason,
          );
      await _ref.read(analyzerSchedulerProvider).onAutoTriggerSendCompleted(
            trigger: trigger,
            success: result.success,
            retryable: result.retryable,
            occurredAt: DateTime.now(),
          );
    } catch (e) {
      AppLogger.error(
        'AutoReplyService',
        'Failed to process fired trigger',
        metadata: {
          'triggerId': trigger.id,
          'error': e.toString(),
        },
      );
    }
  }

  AutoReplyTrigger? _findTrigger(String triggerId) {
    final controller = _ref.read(autoReplyTriggersProvider.notifier);
    final fromController = controller.findTriggerById(triggerId);
    if (fromController != null) {
      return fromController;
    }
    final triggers =
        _ref.read(autoReplyTriggersProvider).valueOrNull ?? const [];
    for (final trigger in triggers) {
      if (trigger.id == triggerId) {
        return trigger;
      }
    }
    return null;
  }
}
