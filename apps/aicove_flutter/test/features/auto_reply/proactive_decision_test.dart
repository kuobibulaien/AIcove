// Plan 12 B1: decisions are enumerable questions a chat model answers as
// JSON; code turns the answers into a kind, a fire time and a priority.
import 'dart:math';

import 'package:aicove_flutter/src/features/auto_reply/data/auto_reply_trigger.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/chat_model_decision_adapter.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/context_analyzer.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/conversation_proactive_state.dart';
import 'package:aicove_flutter/src/features/auto_reply/data/proactive_planner.dart';
import 'package:aicove_flutter/src/features/auto_reply/domain/proactive_decision.dart';
import 'package:aicove_flutter/src/features/chat/domain/message.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, ProactiveAnswer> _answers({
  String kind = 'check_in',
  String timing = 'in_hours',
  bool reminder = false,
  bool nightOk = false,
  bool? covered,
}) => <String, ProactiveAnswer>{
  'kind': ProactiveAnswer.choice(kind),
  'timing': ProactiveAnswer.choice(timing),
  'reminder_requested': ProactiveAnswer.yesNo(reminder),
  'night_ok': ProactiveAnswer.yesNo(nightOk),
  if (covered != null) 'already_covered': ProactiveAnswer.yesNo(covered),
};

const _noQuiet = QuietHours.disabled();
final _quiet = QuietHours.parse(enabled: true, start: '22:00', end: '08:00');

void main() {
  group('ProactivePlanner.silenceReason', () {
    test('stay_silent, a missing kind and a covered goal all stay quiet', () {
      expect(
        ProactivePlanner.silenceReason(_answers(kind: 'stay_silent')),
        ProactiveSilenceReason.staySilent,
      );
      expect(
        ProactivePlanner.silenceReason(_answers(covered: true)),
        ProactiveSilenceReason.alreadyCovered,
      );
      expect(
        ProactivePlanner.silenceReason(const <String, ProactiveAnswer>{}),
        ProactiveSilenceReason.unsure,
      );
    });

    test('a confident reach-out passes', () {
      expect(ProactivePlanner.silenceReason(_answers(covered: false)), isNull);
    });
  });

  group('ProactivePlanner.plan', () {
    final planner = ProactivePlanner(random: Random(7));
    final now = DateTime(2026, 10, 13, 14, 0);

    test('a slot the kind does not allow falls back to its default', () {
      final plan = planner.plan(
        answers: _answers(kind: 'continue_chat', timing: 'next_morning'),
        now: now,
        quietHours: _noQuiet,
      );
      expect(plan.slot, ProactiveTimeSlot.inMinutes);
      final minutes = plan.fireAt.difference(now).inMinutes;
      expect(minutes, inInclusiveRange(3, 8));
    });

    test('an allowed slot is kept and lands inside its range', () {
      final plan = planner.plan(
        answers: _answers(timing: 'in_half_hour'),
        now: now,
        quietHours: _noQuiet,
      );
      expect(plan.slot, ProactiveTimeSlot.inHalfHour);
      expect(plan.fireAt.difference(now).inMinutes, inInclusiveRange(25, 40));
    });

    test('next windows roll to tomorrow once today has started', () {
      final morning = planner.fireTimeFor(
        ProactiveTimeSlot.nextMorning,
        DateTime(2026, 10, 13, 8, 0),
      );
      expect(morning.day, 14);
      expect(morning.hour * 60 + morning.minute, inInclusiveRange(450, 570));
      final evening = planner.fireTimeFor(
        ProactiveTimeSlot.nextEvening,
        DateTime(2026, 10, 13, 9, 0),
      );
      expect(evening.day, 13);
      expect(evening.hour, inInclusiveRange(18, 20));
    });

    test('quiet hours push the time to their end unless night is ok', () {
      final late = DateTime(2026, 10, 13, 21, 50);
      final pushed = planner.plan(
        answers: _answers(timing: 'in_hours'),
        now: late,
        quietHours: _quiet,
      );
      expect(
        pushed.fireAt.isAfter(DateTime(2026, 10, 14, 8, 0)) ||
            pushed.fireAt == DateTime(2026, 10, 14, 8, 0),
        isTrue,
      );
      expect(pushed.fireAt.isBefore(DateTime(2026, 10, 14, 9, 1)), isTrue);
      expect(pushed.allowNight, isFalse);

      final kept = planner.plan(
        answers: _answers(timing: 'in_hours', nightOk: true),
        now: late,
        quietHours: _quiet,
      );
      expect(kept.allowNight, isTrue);
      expect(kept.fireAt.isBefore(DateTime(2026, 10, 14, 0, 0)), isTrue);
    });

    test('an explicit reminder request is high priority', () {
      expect(
        planner
            .plan(
              answers: _answers(reminder: true),
              now: now,
              quietHours: _noQuiet,
            )
            .priority,
        AutoReplyTriggerPriority.high,
      );
      expect(
        planner
            .plan(
              answers: _answers(kind: 'new_topic', timing: 'next_noon'),
              now: now,
              quietHours: _noQuiet,
            )
            .priority,
        AutoReplyTriggerPriority.low,
      );
    });
  });

  group('ChatModelDecisionAdapter', () {
    final questions = ProactiveDecisionQuestions.reachOut(
      hasPendingTriggers: true,
    );

    test('renders every question and the JSON shape into the prompt', () async {
      String? prompt;
      final adapter = ChatModelDecisionAdapter(
        assistantName: '理',
        run: (value) async {
          prompt = value;
          return '```json\n{"kind": "new_topic", "timing": "next_noon", '
              '"reminder_requested": false, "night_ok": "false", '
              '"already_covered": false}\n```';
        },
      );

      final answers = await adapter.answer(
        state: 'STATE',
        questions: questions,
      );

      expect(prompt, contains('「理」'));
      expect(prompt, contains('STATE'));
      expect(prompt, contains('already_covered'));
      expect(prompt, contains('- check_in：'));
      expect(prompt, contains('"kind": "..."'));
      expect(answers['kind']!.choice, 'new_topic');
      expect(answers['night_ok']!.yes, isFalse);
    });

    test('an unknown option or missing key is a FormatException', () {
      expect(
        () => ChatModelDecisionAdapter.parseReply(
          '{"kind": "call_now", "timing": "in_hours"}',
          questions,
        ),
        throwsFormatException,
      );
      expect(
        () => ChatModelDecisionAdapter.parseReply('好的，我觉得不该打扰', questions),
        throwsFormatException,
      );
    });
  });

  group('prompts', () {
    test('the decision state lists facts and a timestamped transcript', () {
      final now = DateTime(2026, 10, 13, 21, 30);
      final state = ContextAnalyzer.buildDecisionState(
        assistantName: '理',
        proactiveState: ConversationProactiveState(
          conversationId: 'c',
          lastUserAt: now.subtract(const Duration(minutes: 12)),
          unrepliedCount: 0,
        ),
        recent: <Message>[
          Message.text(
            id: 'a',
            role: 'user',
            content: '我去洗个澡',
            createdAt: DateTime(2026, 10, 13, 21, 18),
          ),
          Message.text(
            id: 'b',
            role: 'assistant',
            content: '好～',
            createdAt: DateTime(2026, 10, 13, 21, 18),
          ),
        ],
        pendingTriggers: const <AutoReplyTrigger>[],
        now: now,
      );

      expect(state, contains('10月13日 周二 晚上 21:30'));
      expect(state, contains('几分钟前'));
      expect(state, contains('还没有过'));
      expect(state, contains('[10-13 21:18] 用户：我去洗个澡'));
      expect(state, contains('[10-13 21:18] 理：好～'));
      expect(state, isNot(contains('{')));
    });

    test('the reach-out reminder names the fire time, gap and kind', () {
      final reminder = ContextAnalyzer.buildReachOutReminder(
        kind: ProactiveReachOutKind.checkIn,
        fireAt: DateTime(2026, 10, 14, 8, 20),
        lastUserAt: DateTime(2026, 10, 13, 23, 0),
      );

      expect(reminder, contains('10月14日 周三 早上 08:20'));
      expect(reminder, contains('9 个小时'));
      expect(reminder, contains('问问对方之前说要去做的事'));
      expect(reminder, isNot(contains('{')));
    });
  });
}
