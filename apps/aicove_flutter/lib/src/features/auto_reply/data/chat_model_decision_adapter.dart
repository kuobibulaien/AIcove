import 'dart:convert';

import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../../core/prompts/prompt_template_renderer.dart';
import '../domain/proactive_decision.dart';

/// Sends one prompt to a chat model and returns its raw reply text.
typedef ChatModelDecisionRunner = Future<String> Function(String prompt);

/// A chat model answers the decision questions as one line of JSON.
class ChatModelDecisionAdapter implements ProactiveDecisionPort {
  ChatModelDecisionAdapter({
    required this.assistantName,
    required ChatModelDecisionRunner run,
  }) : _run = run;

  final String assistantName;
  final ChatModelDecisionRunner _run;

  @override
  String get kind => 'chat_model';

  /// The full prompt for [state] and [questions].
  String buildPrompt({
    required String state,
    required List<ProactiveQuestion> questions,
  }) {
    return PromptTemplateRenderer.renderTrimmed(
      PromptBuiltinDefaults.requireTemplate(
        'auto_reply.decision.chat_fallback',
      ),
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
                    : null);
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
