import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final priority in [
    AutoReplyTriggerPriority.medium,
    AutoReplyTriggerPriority.low,
  ]) {
    test('clearing the bound user message expires a $priority trigger', () {
      final trigger = AutoReplyTrigger(
        id: 't',
        title: 'check in',
        type: AutoReplyTriggerType.delay,
        status: AutoReplyTriggerStatus.pending,
        createdAt: DateTime(2026),
        nextFireAt: DateTime(2026, 1, 1, 1),
        allowNight: true,
        requireExact: false,
        delayMinutes: 60,
        manual: false,
        priority: priority,
        conversationId: 'c',
        contextLastUserMessageId: 'user_before_clear',
        contextLastUserMessageAt: DateTime(2026),
      );

      expect(
        trigger.shouldExpire(
          currentLastUserMessageId: null,
          currentLastUserMessageAt: null,
          isChatActive: false,
        ),
        isTrue,
      );
      expect(
        trigger
            .copyWith(manual: true)
            .shouldExpire(
              currentLastUserMessageId: null,
              currentLastUserMessageAt: null,
              isChatActive: false,
            ),
        isFalse,
      );
    });
  }
}
