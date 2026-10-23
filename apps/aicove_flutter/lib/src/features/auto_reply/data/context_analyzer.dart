import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';
import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../../core/prompts/prompt_template_renderer.dart';
import '../../agent_context/domain/agent_runtime_contracts.dart';
import '../../background_agent/background_agent_service.dart';
import '../../background_agent/domain/background_agent_definition.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/domain/message.dart';
import '../../chat/services/chat_history_store.dart';
import '../../settings/app_settings.dart';
import '../domain/proactive_decision.dart';
import 'auto_reply_trigger.dart';
import 'auto_reply_trigger_storage.dart';
import 'chat_model_decision_adapter.dart';
import 'conversation_proactive_state.dart';
import 'proactive_call.dart';
import 'proactive_planner.dart';

final contextAnalyzerProvider = Provider((ref) => ContextAnalyzer(ref));

/// Resolves the decision port for the configured judgment model; tests
/// override it to stay offline.
final proactiveDecisionPortResolverProvider =
    Provider<ProactiveDecisionPortResolver>(
      (ref) =>
          (settings, conversation) =>
              _defaultDecisionPort(ref, settings, conversation),
    );

typedef ProactiveDecisionPortResolver =
    ProactiveDecisionPort Function(AppSettings settings, Conversation conv);

/// Step ③ of plan 12: asks whether, how and when to reach out. Every
/// decision is an enumerable question answered through
/// [ProactiveDecisionPort]; the reply itself is written separately.
class ContextAnalyzer {
  ContextAnalyzer(this._ref, {ProactivePlanner? planner})
    : _planner = planner ?? ProactivePlanner();

  /// Recent canonical messages shown to the decider.
  static const int contextWindow = 10;

  /// How long a silent decision keeps the analyzer asleep; a new user
  /// message wakes it earlier.
  static const Duration silenceAfterStaySilent = Duration(hours: 8);

  static const int _transcriptLineMaxChars = 300;

  final Ref _ref;
  final ProactivePlanner _planner;
  final AutoReplyTriggerStorage _historyStorage = AutoReplyTriggerStorage();

  Future<ContextAnalysisDecision?> analyze(
    Conversation conversation, {
    required ConversationProactiveState proactiveState,
  }) async {
    final recent = await _ref
        .read(chatHistoryStoreProvider)
        .loadCanonicalContextMessages(conversation.id, limit: contextWindow);
    if (recent.isEmpty) return null;

    final settings = await _ref.read(appSettingsProvider.future);
    final port = _ref.read(proactiveDecisionPortResolverProvider)(
      settings,
      conversation,
    );
    final pendingTriggers = await _loadPendingTriggers(conversation.id);
    final now = DateTime.now();
    final callBlocked = await _proactiveCallBlocker(conversation);
    final allowCall = callBlocked == null;
    final state = buildDecisionState(
      assistantName: conversation.title,
      proactiveState: proactiveState,
      recent: recent,
      pendingTriggers: pendingTriggers,
      now: now,
      callWelcomePersona: allowCall ? callWelcomePersonaOf(conversation) : null,
    );
    final questions = ProactiveDecisionQuestions.reachOut(
      hasPendingTriggers: pendingTriggers.isNotEmpty,
    );

    await _appendHistoryLog(
      event: 'decision_started',
      message: '开始判断要不要主动联系',
      conversationId: conversation.id,
      metadata: {'decider': port.kind, 'recentMessageCount': recent.length},
    );

    Map<String, ProactiveAnswer> answers;
    try {
      answers = await port.answer(state: state, questions: questions);
    } on FormatException catch (e) {
      // An unreadable fallback answer counts as "stay quiet" (plan §6.4).
      await _appendHistoryLog(
        event: 'decision_unreadable',
        message: '判断结果无法解析，本轮按不打扰处理',
        conversationId: conversation.id,
        level: AutoReplyTriggerLogLevel.warning,
        success: false,
        metadata: {'decider': port.kind, 'error': e.message},
      );
      return _silentDecision(recent, 'decision_unreadable');
    }

    final answerSummary = <String, Object?>{
      for (final entry in answers.entries)
        entry.key: entry.value.choice ?? entry.value.yes,
    };
    final silence = ProactivePlanner.silenceReason(answers);
    if (silence != null) {
      await _appendHistoryLog(
        event: 'decision_silent',
        message: '判断完成：这次先不打扰',
        conversationId: conversation.id,
        success: true,
        metadata: {
          'decider': port.kind,
          'reason': silence.name,
          'answers': answerSummary,
        },
      );
      return _silentDecision(recent, silence.name);
    }

    final settingsForQuiet = settings.autoReplySettings;
    final plan = _planner.plan(
      answers: answers,
      now: now,
      quietHours: QuietHours.parse(
        enabled: settingsForQuiet.quietHoursEnabled,
        start: settingsForQuiet.quietHoursStart,
        end: settingsForQuiet.quietHoursEnd,
      ),
    );
    final lastUserAt = proactiveState.lastUserAt ?? _lastUserAt(recent);
    final reminder = buildReachOutReminder(
      kind: plan.kind,
      fireAt: plan.fireAt,
      lastUserAt: lastUserAt,
    );

    await _appendHistoryLog(
      event: 'decision_reach_out',
      message: '判断完成：准备主动联系',
      conversationId: conversation.id,
      success: true,
      metadata: {
        'decider': port.kind,
        'answers': answerSummary,
        'slot': plan.slot.label,
        'fireAt': plan.fireAt.toIso8601String(),
        'priority': plan.priority.name,
        'callBlocked': callBlocked,
      },
    );

    return ContextAnalysisDecision(
      contextMessages: recent,
      triggerPlan: ContextAnalysisTriggerPlan(
        kind: plan.kind,
        title: defaultTitleFor(plan.kind),
        fireAt: plan.fireAt,
        allowNight: plan.allowNight,
        priority: plan.priority,
        systemReminder: reminder,
        allowCall: allowCall,
      ),
    );
  }

  /// The facts the decider sees (prompt node `auto_reply.decision.state`).
  static String buildDecisionState({
    required String assistantName,
    required ConversationProactiveState proactiveState,
    required List<Message> recent,
    required List<AutoReplyTrigger> pendingTriggers,
    required DateTime now,
    String? callWelcomePersona,
  }) {
    final lastUserAt = proactiveState.lastUserAt ?? _lastUserAt(recent);
    final facts = PromptTemplateRenderer.renderTrimmed(
      PromptBuiltinDefaults.requireTemplate('auto_reply.decision.state'),
      <String, Object?>{
        'assistant_name': assistantName,
        'now': ProactiveTimeText.clock(now),
        'last_user_ago': ProactiveTimeText.ago(lastUserAt, now, never: '很久以前'),
        'unreplied_count': proactiveState.unrepliedCount,
        'last_proactive_ago': ProactiveTimeText.ago(
          proactiveState.lastProactiveAt,
          now,
        ),
        'trigger_list': _formatTriggers(pendingTriggers),
        'transcript': _formatTranscript(recent, assistantName),
      },
    );
    if (callWelcomePersona == null) return facts;
    final welcome = PromptTemplateRenderer.renderTrimmed(
      PromptBuiltinDefaults.requireTemplate('auto_reply.decision.call_welcome'),
      <String, Object?>{
        'assistant_name': assistantName,
        'current_role_persona': callWelcomePersona,
      },
    );
    return '$facts\n\n$welcome';
  }

  /// A failing check only means no call this round.
  Future<String?> _proactiveCallBlocker(Conversation conversation) async {
    try {
      return await _ref.read(proactiveCallGateProvider)(conversation);
    } catch (e) {
      return '来电条件检查失败：$e';
    }
  }

  /// The persona excerpt shown with the call welcome (plan 12, §4.8).
  static const int callWelcomePersonaMaxChars = 300;

  static String callWelcomePersonaOf(Conversation conversation) {
    final persona = conversation.personaPrompt.trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    if (persona.isEmpty) return '（没有写人设）';
    return persona.length <= callWelcomePersonaMaxChars
        ? persona
        : '${persona.substring(0, callWelcomePersonaMaxChars)}…';
  }

  /// The reminder the chat model reads when writing the reply ahead of time
  /// (prompt node `auto_reply.reach_out.reminder`).
  static String buildReachOutReminder({
    required ProactiveReachOutKind kind,
    required DateTime fireAt,
    required DateTime? lastUserAt,
  }) {
    return PromptTemplateRenderer.renderTrimmed(
      PromptBuiltinDefaults.requireTemplate('auto_reply.reach_out.reminder'),
      <String, Object?>{
        'fire_time': ProactiveTimeText.clock(fireAt),
        'gap': lastUserAt == null
            ? '一段时间'
            : ProactiveTimeText.duration(fireAt.difference(lastUserAt)),
        'kind_hint': kindHintFor(kind),
      },
    );
  }

  static String kindHintFor(ProactiveReachOutKind kind) {
    switch (kind) {
      case ProactiveReachOutKind.continueChat:
        return '，接着刚才没聊完的说';
      case ProactiveReachOutKind.checkIn:
        return '，问问对方之前说要去做的事怎么样了';
      case ProactiveReachOutKind.newTopic:
        return '，聊点新的，或者就是打个招呼';
      case ProactiveReachOutKind.staySilent:
        return '';
    }
  }

  static String defaultTitleFor(ProactiveReachOutKind kind) {
    switch (kind) {
      case ProactiveReachOutKind.continueChat:
        return '接着刚才的话题';
      case ProactiveReachOutKind.checkIn:
        return '回头问问近况';
      case ProactiveReachOutKind.newTopic:
        return '晚些时候打个招呼';
      case ProactiveReachOutKind.staySilent:
        return '';
    }
  }

  ContextAnalysisDecision _silentDecision(List<Message> recent, String reason) {
    return ContextAnalysisDecision(
      contextMessages: recent,
      sessionPatch: ContextAnalysisSessionPatch(
        mode: ConversationProactiveMode.silent,
        silenceDuration: silenceAfterStaySilent,
        reason: reason,
      ),
    );
  }

  Future<List<AutoReplyTrigger>> _loadPendingTriggers(
    String conversationId,
  ) async {
    try {
      final triggers = await _historyStorage.loadTriggers();
      final pending =
          triggers
              .where(
                (trigger) =>
                    trigger.conversationId == conversationId &&
                    (trigger.isActive ||
                        trigger.status == AutoReplyTriggerStatus.paused),
              )
              .toList()
            ..sort((a, b) => a.nextFireAt.compareTo(b.nextFireAt));
      return pending.take(8).toList(growable: false);
    } catch (e) {
      AppLogger.warning(
        'ContextAnalyzer',
        '加载当前会话触发器失败',
        metadata: {'conversationId': conversationId, 'error': e.toString()},
      );
      return const <AutoReplyTrigger>[];
    }
  }

  static String _formatTriggers(List<AutoReplyTrigger> triggers) {
    if (triggers.isEmpty) return '没有';
    return triggers
        .map(
          (trigger) =>
              '- ${ProactiveTimeText.clock(trigger.nextFireAt)}：${trigger.title}',
        )
        .join('\n');
  }

  static String _formatTranscript(List<Message> recent, String assistantName) {
    return recent
        .where(
          (message) => message.role == 'user' || message.role == 'assistant',
        )
        .map((message) {
          final time = message.createdAt;
          final stamp =
              '${time.month.toString().padLeft(2, '0')}-'
              '${time.day.toString().padLeft(2, '0')} '
              '${time.hour.toString().padLeft(2, '0')}:'
              '${time.minute.toString().padLeft(2, '0')}';
          final speaker = message.role == 'user' ? '用户' : assistantName;
          var text = message.displayText.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (text.length > _transcriptLineMaxChars) {
            text = '${text.substring(0, _transcriptLineMaxChars)}…';
          }
          return '[$stamp] $speaker：$text';
        })
        .join('\n');
  }

  static DateTime? _lastUserAt(List<Message> recent) {
    for (final message in recent.reversed) {
      if (message.role == 'user') return message.createdAt;
    }
    return null;
  }

  Future<void> _appendHistoryLog({
    required String event,
    required String message,
    required String conversationId,
    bool? success,
    AutoReplyTriggerLogLevel level = AutoReplyTriggerLogLevel.info,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) async {
    await _historyStorage.appendLog(
      AutoReplyTriggerLog(
        id: 'context_analyzer_${DateTime.now().microsecondsSinceEpoch}',
        category: AutoReplyTriggerLogCategory.agent,
        event: event,
        message: message,
        occurredAt: DateTime.now(),
        conversationId: conversationId,
        success: success,
        level: level,
        metadata: metadata,
      ),
    );
  }
}

/// The chat model chosen as the judgment model (or the default chat model)
/// answers the questions. A decision model can later plug in here.
ProactiveDecisionPort _defaultDecisionPort(
  Ref ref,
  AppSettings settings,
  Conversation conversation,
) {
  final modelRef = resolveJudgmentModelRef(settings);
  return ChatModelDecisionAdapter(
    assistantName: conversation.title,
    run: (prompt) async {
      final result = await ref
          .read(backgroundAgentServiceProvider)
          .run(
            definition: BackgroundAgentDefinition(
              id: 'auto_reply_decision',
              name: '主动回复判断',
              objectivePrompt: '你只做判断，只回一行 JSON。',
              contextProfile: ContextProfile.background(
                const ConversationWindowSpec(
                  lastMessages: 1,
                  includeAssistant: false,
                ),
              ),
              modelRef: modelRef,
              temperature: 0.2,
            ),
            conversationId: conversation.id,
            contextMessages: <Message>[
              Message.text(
                id: 'auto_reply_decision_${DateTime.now().microsecondsSinceEpoch}',
                role: 'user',
                content: prompt,
                createdAt: DateTime.now(),
              ),
            ],
          );
      return result.text;
    },
  );
}

/// The judgment model: the analyzer setting, else the default chat model.
String resolveJudgmentModelRef(AppSettings settings) {
  final autoReplySettings = settings.autoReplySettings;
  final model = autoReplySettings.analyzerModel?.trim();
  if (model == null || model.isEmpty) return settings.defaultModelName;
  final provider = autoReplySettings.analyzerProvider?.trim();
  if (provider != null && provider.isNotEmpty && !model.contains(':')) {
    return settings.buildModelRef(provider, model);
  }
  return model;
}

class ContextAnalysisDecision {
  const ContextAnalysisDecision({
    required this.contextMessages,
    this.sessionPatch,
    this.triggerPlan,
  });

  final List<Message> contextMessages;

  final ContextAnalysisSessionPatch? sessionPatch;
  final ContextAnalysisTriggerPlan? triggerPlan;
}

class ContextAnalysisSessionPatch {
  const ContextAnalysisSessionPatch({
    required this.mode,
    this.silenceDuration,
    this.reason,
  });

  final ConversationProactiveMode mode;
  final Duration? silenceDuration;
  final String? reason;
}

class ContextAnalysisTriggerPlan {
  const ContextAnalysisTriggerPlan({
    required this.kind,
    required this.title,
    required this.fireAt,
    required this.allowNight,
    required this.priority,
    required this.systemReminder,
    this.allowCall = false,
  });

  final ProactiveReachOutKind kind;
  final String title;
  final DateTime fireAt;
  final bool allowNight;
  final AutoReplyTriggerPriority priority;

  /// The rendered `auto_reply.reach_out.reminder`; stored on the trigger so a
  /// live regeneration at fire time reads the same hint.
  final String systemReminder;

  /// Whether the reply may be written as a call (plan 12, §4.8).
  final bool allowCall;
}
