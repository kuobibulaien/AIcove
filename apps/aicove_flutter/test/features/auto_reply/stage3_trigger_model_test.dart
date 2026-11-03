import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final at = DateTime(2026, 10, 26, 23, 30);
  final trigger = AutoReplyTrigger(
    id: 't',
    title: 't',
    type: AutoReplyTriggerType.delay,
    status: AutoReplyTriggerStatus.pending,
    createdAt: at,
    nextFireAt: at,
    allowNight: false,
    requireExact: false,
    delayMinutes: 0,
    manual: true,
    conversationId: 'c',
    lastFiredAt: at,
    contactId: 'legacy',
    prompt: 'prompt',
    cachedContent: 'cached',
    contextSnapshot: 'snapshot',
    contextLastUserMessageId: 'u',
    contextLastUserMessageAt: at,
    preparedAt: at,
    expireReason: 'old failure',
  );

  test(
    'copyWith can clear every nullable field without losing omitted values',
    () {
      expect(trigger.copyWith().toJson(), trigger.toJson());
      final cleared = trigger.copyWith(
        lastFiredAt: null,
        contactId: null,
        prompt: null,
        cachedContent: null,
        contextSnapshot: null,
        contextLastUserMessageId: null,
        contextLastUserMessageAt: null,
        preparedAt: null,
        expireReason: null,
      );
      final json = cleared.toJson();
      for (final key in [
        'last_fired_at',
        'contact_id',
        'prompt',
        'cached_content',
        'context_snapshot',
        'context_last_user_message_id',
        'context_last_user_message_at',
        'prepared_at',
        'expire_reason',
      ]) {
        expect(json[key], isNull, reason: key);
      }
      expect(cleared.conversationId, 'c');
      expect(cleared.delayMinutes, 0);
    },
  );

  test('shouldFire leaves all quiet-hours policy to the configured gate', () {
    expect(trigger.shouldFire(at), isTrue);
    expect(trigger.shouldFire(at, allowNightOverride: true), isTrue);
    expect(
      trigger.copyWith(status: AutoReplyTriggerStatus.paused).shouldFire(at),
      isFalse,
    );
    expect(
      trigger
          .copyWith(nextFireAt: at.add(const Duration(minutes: 1)))
          .shouldFire(at),
      isFalse,
    );
  });
}
