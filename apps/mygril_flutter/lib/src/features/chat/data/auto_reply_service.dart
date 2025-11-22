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
    // We listen to the state of the event provider.
    // Note: listen callback fires immediately with current value if we use fireImmediately: true, 
    // but here we only want changes.
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
    AppLogger.info('AutoReplyService', 'Trigger fired', metadata: {'title': event.title, 'id': event.triggerId});
    
    try {
       final trigger = AutoReplyTrigger(
         id: event.triggerId, 
         title: event.title, 
         type: AutoReplyTriggerType.fixed, 
         status: AutoReplyTriggerStatus.completed, 
         createdAt: DateTime.now(), 
         nextFireAt: DateTime.now(), 
         allowNight: true, 
         requireExact: false, 
         delayMinutes: 0, 
         manual: false
       );

       await _ref.read(chatActionsProvider).sendProactiveTrigger(trigger);

    } catch (e) {
       AppLogger.error('AutoReplyService', 'Failed to process fired trigger', metadata: {'error': e.toString()});
    }
  }
}
