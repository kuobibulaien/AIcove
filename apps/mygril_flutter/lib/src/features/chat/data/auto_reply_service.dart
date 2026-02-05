import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/app_logger.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_controller.dart';
import '../providers2.dart';

final autoReplyServiceProvider = Provider((ref) => AutoReplyService(ref));

class AutoReplyService {
  final Ref _ref;

  AutoReplyService(this._ref) {
    _listenToEvents();
  }

  void _listenToEvents() {
    _ref.listen<AutoReplyTriggerEvent?>(
      autoReplyTriggerEventProvider,
      (previous, next) {
        if (next != null && next.type == AutoReplyTriggerEventType.fired) {
          _handleFiredEvent(next);
        }
      }
    );
  }

  Future<void> _handleFiredEvent(AutoReplyTriggerEvent event) async {
    AppLogger.info('AutoReplyService', 'Trigger fired', metadata: {
      'title': event.title,
      'id': event.triggerId,
    });

    try {
      // 从 state 中获取真实的触发器数据
      final triggers = _ref.read(autoReplyTriggersProvider).valueOrNull ?? [];
      final trigger = triggers.where((t) => t.id == event.triggerId).firstOrNull;

      if (trigger == null) {
        AppLogger.warning('AutoReplyService', 'Trigger not found in state', metadata: {
          'triggerId': event.triggerId,
        });
        return;
      }

      await _ref.read(chatActionsProvider).sendProactiveTrigger(trigger);

    } catch (e) {
      AppLogger.error('AutoReplyService', 'Failed to process fired trigger', metadata: {
        'error': e.toString(),
      });
    }
  }
}
