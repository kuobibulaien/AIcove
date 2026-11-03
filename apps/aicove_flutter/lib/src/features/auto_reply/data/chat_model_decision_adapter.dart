import 'dart:convert';

import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../../core/prompts/prompt_template_renderer.dart';
import '../../settings/settings_models.dart';
import '../domain/proactive_decision.dart';

/// Sends one prompt to a chat model and returns its raw reply text.
typedef ChatModelDecisionRunner = Future<String> Function(String prompt);

/// A chat model answers the decision questions as one line of JSON.
class ChatModelDecisionAdapter implements ProactiveDecisionPort {
  ChatModelDecisionAdapter({
    required this.assistantName,
    required ChatModelDecisionRunner run,
    this.frequency = AutoReplyFrequency.normal,
  }) : _run = run;

  final String assistantName;
  final ChatModelDecisionRunner _run;
  final AutoReplyFrequency frequency;

  @override
  String get kind => 'chat_model';

  /// The full prompt for [state] and [questions].
  String buildPrompt({
    required String state,
    required List<ProactiveQuestion> questions,
  }) {
    final promptId = frequency == AutoReplyFrequency.frequent
        ? 'auto_reply.decision.chat_fallback_frequent'
        : 'auto_reply.decision.chat_fallback';
    return PromptTemplateRenderer.renderTrimmed(
      PromptBuiltinDefaults.requireTemplate(promptId),
      <String, Object?>{
        'assistant_name': assistantName,
        'state': state,
        'questions': ProactiveDecisionQuestions.renderForChatModel(questions),
        'answer_format': ProactiveDecisionQuestions.chatModelAnswerFormat(
          questions,
        ),
      },
    );
  }

  @override
  Future<Map<String, ProactiveAnswer>> answer({
    required String state,
    required List<ProactiveQuestion> questions,
  }) async {
    final reply = await _run(buildPrompt(state: state, questions: questions));
    return parseReply(reply, questions);
  }

  @override
  Future<List<Map<String, ProactiveAnswer>>> answerAll({
    required String state,
    required List<ProactiveQuestion> questions,
  }) async {
    final reply = await _run(buildPrompt(state: state, questions: questions));
    return parseReplyList(reply, questions);
  }

  /// Parses the model's JSON; throws [FormatException] when a question is
  /// missing or invalid so the caller treats the round as silent.
  static Map<String, ProactiveAnswer> parseReply(
    String reply,
    List<ProactiveQuestion> questions,
  ) {
    final decoded = jsonDecode(_extractJsonObject(reply));
    if (decoded is! Map) {
      throw const FormatException('decision reply is not a JSON object');
    }
    if (decoded['triggers'] is List) {
      final list = parseReplyList(reply, questions);
      return list.first;
    }
    return _parseSingleObject(decoded, questions, allowOptionalYesNo: false);
  }

  /// Parses either a single decision object or `{"triggers": [...]}` containing
  /// one or more trigger decisions.
  static List<Map<String, ProactiveAnswer>> parseReplyList(
    String reply,
    List<ProactiveQuestion> questions,
  ) {
    final decoded = jsonDecode(_extractJsonObject(reply));
    if (decoded is! Map) {
      throw const FormatException('decision reply is not a JSON object');
    }
    final rawTriggers = decoded['triggers'];
    if (rawTriggers is List) {
      if (rawTriggers.isEmpty) {
        return <Map<String, ProactiveAnswer>>[
          <String, ProactiveAnswer>{
            'kind': const ProactiveAnswer.choice('stay_silent'),
          },
        ];
      }
      final results = <Map<String, ProactiveAnswer>>[];
      for (final item in rawTriggers) {
        if (item is! Map) {
          throw const FormatException('trigger item is not a JSON object');
        }
        results.add(
          _parseSingleObject(item, questions, allowOptionalYesNo: true),
        );
      }
      return results;
    }
    return <Map<String, ProactiveAnswer>>[
      _parseSingleObject(decoded, questions, allowOptionalYesNo: false),
    ];
  }

  static Map<String, ProactiveAnswer> _parseSingleObject(
    Map<dynamic, dynamic> decoded,
    List<ProactiveQuestion> questions, {
    required bool allowOptionalYesNo,
  }) {
    final answers = <String, ProactiveAnswer>{};
    for (final question in questions) {
      final raw = decoded[question.id];
      switch (question.type) {
        case ProactiveQuestionType.choice:
          final choice = raw is String ? raw.trim() : null;
          if (choice == null || !question.options.containsKey(choice)) {
            throw FormatException('invalid "${question.id}": $raw');
          }
          answers[question.id] = ProactiveAnswer.choice(choice);
        case ProactiveQuestionType.yesNo:
          final yes = raw is bool
              ? raw
              : (raw is String
                    ? bool.tryParse(raw.trim().toLowerCase())
                    : (allowOptionalYesNo && raw == null ? false : null));
          if (yes == null) {
            throw FormatException('invalid "${question.id}": $raw');
          }
          answers[question.id] = ProactiveAnswer.yesNo(yes);
      }
    }
    return answers;
  }

  static String _extractJsonObject(String reply) {
    final start = reply.indexOf('{');
    final end = reply.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('decision reply has no JSON object');
    }
    return reply.substring(start, end + 1);
  }
}
