/// Pure scheduling rules for proactive replies (plan 12, §4.2–§4.3): turns
/// the decision answers into a kind, a fire time and a priority, and formats
/// times for the prompts. No I/O, so every rule is unit-testable.
library;

import 'dart:math';

import '../domain/proactive_decision.dart';
import 'auto_reply_trigger.dart';

/// Quiet hours as minutes of the day; `start == end` means disabled.
class QuietHours {
  const QuietHours({required this.startMinutes, required this.endMinutes});

  const QuietHours.disabled() : startMinutes = 0, endMinutes = 0;

  /// Parses `HH:mm` settings values, falling back to 22:00–08:00.
  factory QuietHours.parse({
    required bool enabled,
    required String start,
    required String end,
  }) {
    if (!enabled) return const QuietHours.disabled();
    return QuietHours(
      startMinutes: _parseMinutes(start, 22 * 60),
      endMinutes: _parseMinutes(end, 8 * 60),
    );
  }

  final int startMinutes;
  final int endMinutes;

  bool get enabled => startMinutes != endMinutes;

  bool contains(DateTime time) {
    if (!enabled) return false;
    final minutes = time.hour * 60 + time.minute;
    if (startMinutes < endMinutes) {
      return minutes >= startMinutes && minutes < endMinutes;
    }
    return minutes >= startMinutes || minutes < endMinutes;
  }

  /// The first quiet-hours end at or after [time].
  DateTime nextEnd(DateTime time) {
    final todayEnd = DateTime(
      time.year,
      time.month,
      time.day,
    ).add(Duration(minutes: endMinutes));
    return todayEnd.isBefore(time)
        ? todayEnd.add(const Duration(days: 1))
        : todayEnd;
  }

  static int _parseMinutes(String value, int fallback) {
    final parts = value.split(':');
    if (parts.length != 2) return fallback;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return fallback;
    return hour.clamp(0, 23).toInt() * 60 + minute.clamp(0, 59).toInt();
  }
}

/// A decision turned into something the scheduler can create.
class ProactivePlan {
  const ProactivePlan({
    required this.kind,
    required this.slot,
    required this.fireAt,
    required this.allowNight,
    required this.priority,
  });

  final ProactiveReachOutKind kind;
  final ProactiveTimeSlot slot;
  final DateTime fireAt;
  final bool allowNight;
  final AutoReplyTriggerPriority priority;
}

/// Why a decision ended without a plan.
enum ProactiveSilenceReason { staySilent, unsure, alreadyCovered }

class ProactivePlanner {
  ProactivePlanner({Random? random}) : _random = random ?? Random();

  final Random _random;

  static const Map<ProactiveReachOutKind, Set<ProactiveTimeSlot>> allowedSlots =
      <ProactiveReachOutKind, Set<ProactiveTimeSlot>>{
        ProactiveReachOutKind.continueChat: <ProactiveTimeSlot>{
          ProactiveTimeSlot.inMinutes,
        },
        ProactiveReachOutKind.checkIn: <ProactiveTimeSlot>{
          ProactiveTimeSlot.inHalfHour,
          ProactiveTimeSlot.inHours,
          ProactiveTimeSlot.laterToday,
          ProactiveTimeSlot.nextMorning,
        },
        ProactiveReachOutKind.newTopic: <ProactiveTimeSlot>{
          ProactiveTimeSlot.laterToday,
          ProactiveTimeSlot.nextMorning,
          ProactiveTimeSlot.nextNoon,
          ProactiveTimeSlot.nextEvening,
        },
      };

  static const Map<ProactiveReachOutKind, ProactiveTimeSlot> defaultSlot =
      <ProactiveReachOutKind, ProactiveTimeSlot>{
        ProactiveReachOutKind.continueChat: ProactiveTimeSlot.inMinutes,
        ProactiveReachOutKind.checkIn: ProactiveTimeSlot.inHours,
        ProactiveReachOutKind.newTopic: ProactiveTimeSlot.nextMorning,
      };

  /// The silence reason, or null when the answers ask to reach out.
  static ProactiveSilenceReason? silenceReason(
    Map<String, ProactiveAnswer> answers,
  ) {
    final kindAnswer = answers[ProactiveDecisionQuestions.kind.id];
    final kind = ProactiveReachOutKind.fromLabel(kindAnswer?.choice);
    if (kindAnswer == null || kind == null) {
      return ProactiveSilenceReason.unsure;
    }
    if (kind == ProactiveReachOutKind.staySilent) {
      return ProactiveSilenceReason.staySilent;
    }
    final covered = answers[ProactiveDecisionQuestions.alreadyCovered.id];
    if (covered?.yes == true) return ProactiveSilenceReason.alreadyCovered;
    return null;
  }

  /// Builds the plan for answers that passed [silenceReason].
  ProactivePlan plan({
    required Map<String, ProactiveAnswer> answers,
    required DateTime now,
    required QuietHours quietHours,
  }) {
    final kind = ProactiveReachOutKind.fromLabel(
      answers[ProactiveDecisionQuestions.kind.id]?.choice,
    )!;
    final picked = ProactiveTimeSlot.fromLabel(
      answers[ProactiveDecisionQuestions.timing.id]?.choice,
    );
    final slot = picked != null && allowedSlots[kind]!.contains(picked)
        ? picked
        : defaultSlot[kind]!;
    final allowNight = _yes(answers, ProactiveDecisionQuestions.nightOk);
    final reminderRequested = _yes(
      answers,
      ProactiveDecisionQuestions.reminderRequested,
    );
    var fireAt = fireTimeFor(slot, now);
    if (!allowNight && quietHours.contains(fireAt)) {
      fireAt = quietHours
          .nextEnd(fireAt)
          .add(Duration(minutes: _random.nextInt(60)));
    }
    return ProactivePlan(
      kind: kind,
      slot: slot,
      fireAt: fireAt,
      allowNight: allowNight,
      priority: reminderRequested
          ? AutoReplyTriggerPriority.high
          : defaultPriority(kind),
    );
  }

  /// A random time inside [slot] after [now].
  DateTime fireTimeFor(ProactiveTimeSlot slot, DateTime now) {
    switch (slot) {
      case ProactiveTimeSlot.inMinutes:
        return now.add(Duration(minutes: _between(3, 8)));
      case ProactiveTimeSlot.inHalfHour:
        return now.add(Duration(minutes: _between(25, 40)));
      case ProactiveTimeSlot.inHours:
        return now.add(Duration(minutes: _between(60, 120)));
      case ProactiveTimeSlot.laterToday:
        return now.add(Duration(minutes: _between(180, 360)));
      case ProactiveTimeSlot.nextMorning:
        return _nextWindow(now, 7 * 60 + 30, 9 * 60 + 30);
      case ProactiveTimeSlot.nextNoon:
        return _nextWindow(now, 11 * 60 + 30, 13 * 60);
      case ProactiveTimeSlot.nextEvening:
        return _nextWindow(now, 18 * 60, 20 * 60);
    }
  }

  static AutoReplyTriggerPriority defaultPriority(ProactiveReachOutKind kind) {
    return kind == ProactiveReachOutKind.newTopic
        ? AutoReplyTriggerPriority.low
        : AutoReplyTriggerPriority.medium;
  }

  DateTime _nextWindow(DateTime now, int startMinutes, int endMinutes) {
    final midnight = DateTime(now.year, now.month, now.day);
    var start = midnight.add(Duration(minutes: startMinutes));
    if (!start.isAfter(now)) start = start.add(const Duration(days: 1));
    return start.add(Duration(minutes: _between(0, endMinutes - startMinutes)));
  }

  int _between(int min, int max) => min + _random.nextInt(max - min + 1);

  static bool _yes(
    Map<String, ProactiveAnswer> answers,
    ProactiveQuestion question,
  ) => answers[question.id]?.yes == true;
}

/// Prompt-facing time formatting, e.g. `10月12日 周日 晚上 21:30`.
abstract final class ProactiveTimeText {
  static const List<String> _weekdays = <String>[
    '周一',
    '周二',
    '周三',
    '周四',
    '周五',
    '周六',
    '周日',
  ];

  static String clock(DateTime time) {
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    return '${time.month}月${time.day}日 ${_weekdays[time.weekday - 1]} '
        '${dayPeriod(time)} $hh:$mm';
  }

  static String dayPeriod(DateTime time) {
    final hour = time.hour;
    if (hour < 5) return '凌晨';
    if (hour < 9) return '早上';
    if (hour < 12) return '上午';
    if (hour < 14) return '中午';
    if (hour < 18) return '下午';
    if (hour < 23) return '晚上';
    return '深夜';
  }

  /// A rough spoken duration: `几分钟`, `一个多小时`, `5 个小时`, `2 天`.
  static String duration(Duration gap) {
    final minutes = gap.inMinutes;
    if (minutes < 3) return '一两分钟';
    if (minutes < 15) return '几分钟';
    if (minutes < 45) return '半个小时左右';
    if (minutes < 75) return '一个小时左右';
    if (minutes < 120) return '一个多小时';
    final hours = gap.inHours;
    if (hours < 24) return '$hours 个小时';
    final days = gap.inDays;
    return days == 1 ? '一天多' : '$days 天';
  }

  /// `12 分钟前`-style relative text, or [never] when [time] is null.
  static String ago(DateTime? time, DateTime now, {String never = '还没有过'}) {
    if (time == null) return never;
    return '${duration(now.difference(time))}前';
  }
}
