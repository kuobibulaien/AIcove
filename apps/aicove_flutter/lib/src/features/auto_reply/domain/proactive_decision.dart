/// Proactive reply decisions: the questions, the answers and the port that
/// answers them (plan 12, §4.2). Today a chat model answers them as one line
/// of JSON; the port leaves room for a dedicated decision model later.
library;

/// How a question is answered.
enum ProactiveQuestionType {
  /// Yes or no.
  yesNo,

  /// One label out of [ProactiveQuestion.options].
  choice,
}

/// One enumerable question about the conversation facts.
class ProactiveQuestion {
  const ProactiveQuestion.yesNo({required this.id, required this.instruction})
    : type = ProactiveQuestionType.yesNo,
      options = const <String, String>{};

  const ProactiveQuestion.choice({
    required this.id,
    required this.instruction,
    required this.options,
  }) : type = ProactiveQuestionType.choice;

  final String id;
  final ProactiveQuestionType type;
  final String instruction;

  /// Label to what the label means; only for [ProactiveQuestionType.choice].
  final Map<String, String> options;
}

/// One answer. [choice] is set for choice questions, [yes] for yes/no.
class ProactiveAnswer {
  const ProactiveAnswer.choice(this.choice) : yes = null;

  const ProactiveAnswer.yesNo(this.yes) : choice = null;

  final String? choice;
  final bool? yes;
}

/// Answers a batch of questions about one state.
abstract class ProactiveDecisionPort {
  /// Short identifier for logs, e.g. `chat_model`.
  String get kind;

  /// Every question is answered or the call throws; a missing answer must not
  /// silently read as "no".
  Future<Map<String, ProactiveAnswer>> answer({
    required String state,
    required List<ProactiveQuestion> questions,
  });
}

/// What the role should do now.
enum ProactiveReachOutKind {
  staySilent('stay_silent'),
  continueChat('continue_chat'),
  checkIn('check_in'),
  newTopic('new_topic');

  const ProactiveReachOutKind(this.label);
  final String label;

  static ProactiveReachOutKind? fromLabel(String? label) {
    for (final kind in values) {
      if (kind.label == label?.trim()) return kind;
    }
    return null;
  }
}

/// When to reach out; the pipeline maps a slot to a concrete time.
enum ProactiveTimeSlot {
  inMinutes('in_minutes'),
  inHalfHour('in_half_hour'),
  inHours('in_hours'),
  laterToday('later_today'),
  nextMorning('next_morning'),
  nextNoon('next_noon'),
  nextEvening('next_evening');

  const ProactiveTimeSlot(this.label);
  final String label;

  static ProactiveTimeSlot? fromLabel(String? label) {
    for (final slot in values) {
      if (slot.label == label?.trim()) return slot;
    }
    return null;
  }
}

/// The single source of question wording for every answerer.
abstract final class ProactiveDecisionQuestions {
  static const kind = ProactiveQuestion.choice(
    id: 'kind',
    instruction: '角色现在该怎么做？',
    options: <String, String>{
      'stay_silent': '先不打扰。用户说了晚安、明显在忙、想自己待着，或者话已经聊完、没有自然的由头，或者角色已经主动找过、对方还没回。',
      'continue_chat': '话说到一半停住了，用户可能只是走开一下，过几分钟接着聊很自然。',
      'check_in': '用户说过要去做一件事（洗澡、吃饭、开会、出门、睡觉），等这件事差不多结束了，问问怎么样。',
      'new_topic': '这轮已经自然聊完，隔一段时间再找个新话头打招呼。',
    },
  );

  static const timing = ProactiveQuestion.choice(
    id: 'timing',
    instruction: '如果要找用户，什么时候合适？',
    options: <String, String>{
      'in_minutes': '几分钟后',
      'in_half_hour': '半小时左右',
      'in_hours': '一两个小时后',
      'later_today': '今天晚些时候',
      'next_morning': '下一个早上，对方醒了以后',
      'next_noon': '下一个中午',
      'next_evening': '下一个傍晚',
    },
  );

  static const reminderRequested = ProactiveQuestion.yesNo(
    id: 'reminder_requested',
    instruction: '用户有没有明确让角色过一会儿提醒他、叫他？',
  );

  static const nightOk = ProactiveQuestion.yesNo(
    id: 'night_ok',
    instruction: '用户有没有说深夜也可以找他，或者约好的事本来就在深夜？',
  );

  static const alreadyCovered = ProactiveQuestion.yesNo(
    id: 'already_covered',
    instruction: '已经定好的提醒里，有没有一条想做的事和这次一样？',
  );

  /// Questions for step ③; [alreadyCovered] only when triggers exist.
  static List<ProactiveQuestion> reachOut({required bool hasPendingTriggers}) {
    return <ProactiveQuestion>[
      kind,
      timing,
      reminderRequested,
      nightOk,
      if (hasPendingTriggers) alreadyCovered,
    ];
  }

  /// Renders [questions] as numbered text for a chat model.
  static String renderForChatModel(List<ProactiveQuestion> questions) {
    final buffer = StringBuffer();
    for (var i = 0; i < questions.length; i++) {
      final question = questions[i];
      if (i > 0) buffer.writeln();
      buffer.writeln('${i + 1}. ${question.id}：${question.instruction}');
      if (question.type == ProactiveQuestionType.choice) {
        for (final entry in question.options.entries) {
          buffer.writeln('   - ${entry.key}：${entry.value}');
        }
      } else {
        buffer.writeln('   回答 true 或 false。');
      }
    }
    return buffer.toString().trimRight();
  }

  /// The one-line JSON a chat model must reply with.
  static String chatModelAnswerFormat(List<ProactiveQuestion> questions) {
    final fields = questions.map((question) {
      final value = question.type == ProactiveQuestionType.choice
          ? '"..."'
          : 'false';
      return '"${question.id}": $value';
    });
    return '{${fields.join(', ')}}';
  }
}
