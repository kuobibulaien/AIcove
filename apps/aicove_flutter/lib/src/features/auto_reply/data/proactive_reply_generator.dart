import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/converters/database_converters.dart';
import '../../../core/database/database_provider.dart';
import '../../../core/prompts/prompt_builtin_defaults.g.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/services/chat_history_store.dart';
import '../../chat/services/chat_send_service.dart';
import '../../chat/services/chat_types.dart';
import '../../settings/app_settings.dart';
import '../domain/proactive_action.dart';
import 'auto_reply_agent_helpers.dart';
import 'proactive_call.dart';

/// Runs one prepared proactive request; tests replace it to stay offline.
typedef ProactiveReplyExecutor =
    Future<ApiCallResult> Function({
      required ApiConfig config,
      required String sessionId,
      required String? userText,
      required String turnId,
    });

final proactiveReplyExecutorProvider = Provider<ProactiveReplyExecutor>((ref) {
  final service = ref.watch(chatSendServiceProvider);
  return ({
    required config,
    required sessionId,
    required userText,
    required turnId,
  }) => service.executeApiCall(
    config: config,
    sessionId: sessionId,
    userText: userText,
    turnId: turnId,
    maxRounds: 1,
  );
});

final proactiveReplyGeneratorProvider = Provider<ProactiveReplyGenerator>(
  ProactiveReplyGenerator.new,
);

/// The single proactive-reply generation path (ADR0060, batch 2 plan §3.7):
/// the foreground dispatcher and the background WorkManager task both
/// assemble through the chat entry `prepareApiConfig` and only differ in
/// where the reply is delivered.
class ProactiveReplyGenerator {
  ProactiveReplyGenerator(this._ref);

  final Ref _ref;

  /// Recent canonical messages fed to a proactive request.
  static const contextWindow = 10;

  /// Loads the conversation from the database, so callers without UI state
  /// (the background isolate) can generate too.
  Future<Conversation?> loadConversation(String conversationId) async {
    final row = await _ref
        .read(conversationRepositoryProvider)
        .getById(conversationId);
    if (row == null || row.deletedAt != null) return null;
    return ConversationConverter.fromDb(row);
  }

  /// The request a proactive reply sends: the role's normal chat assembly
  /// with the trigger reminder as the last user turn and no native tools.
  /// [requestTime] is the planned fire time when writing ahead of it.
  Future<ApiConfig> prepare({
    required Conversation conversation,
    required String? reminder,
    DateTime? requestTime,
  }) async {
    final history = await _ref
        .read(chatHistoryStoreProvider)
        .loadCanonicalContextMessages(conversation.id, limit: contextWindow);
    if (history.isEmpty) throw StateError('proactive_context_empty');
    final settings = await _ref.read(appSettingsProvider.future);
    final config = await _ref
        .read(chatSendServiceProvider)
        .prepareApiConfig(
          conv: conversation,
          history: history,
          userText: reminder,
          overrideModel: resolveAutoReplyAgentModelRef(settings),
          conversationId: conversation.id,
          requestTime: requestTime,
        );
    return disableNativeToolCallsForAutoReplyGeneration(
      appendAutoReplyReminderAsLastUser(config, reminder),
    );
  }

  /// Generates the reply text; empty when the model returned nothing usable.
  Future<String> generate({
    required Conversation conversation,
    required String? reminder,
    required String turnId,
    DateTime? requestTime,
  }) async {
    final config = await prepare(
      conversation: conversation,
      reminder: reminder,
      requestTime: requestTime,
    );
    final result = await _ref.read(proactiveReplyExecutorProvider)(
      config: config,
      sessionId: conversation.id,
      userText: reminder,
      turnId: turnId,
    );
    return selectCacheableAutoReplyText(result);
  }

  /// Writes ahead for the fire time. With [allowCall] the reminder invites a
  /// call and the request carries the `call_user` tool, whose call is only
  /// recorded (plan 12, §4.8); otherwise this is [generate].
  Future<ProactiveDraft> generateDraft({
    required Conversation conversation,
    required String reminder,
    required String turnId,
    required DateTime requestTime,
    bool allowCall = false,
  }) async {
    if (!allowCall) {
      return ProactiveDraft(
        text: await generate(
          conversation: conversation,
          reminder: reminder,
          turnId: turnId,
          requestTime: requestTime,
        ),
      );
    }
    final withHint =
        '$reminder\n'
        '${PromptBuiltinDefaults.requireTemplate('auto_reply.reach_out.call_hint')}';
    String? openingLine;
    final tool = buildCallUserTool(onCall: (line) => openingLine ??= line);
    final config = (await prepare(
      conversation: conversation,
      reminder: withHint,
      requestTime: requestTime,
    )).copyWith(tools: [tool.toOpenAISchema()], boundTools: [tool]);
    final result = await _ref.read(proactiveReplyExecutorProvider)(
      config: config,
      sessionId: conversation.id,
      userText: withHint,
      turnId: turnId,
    );
    openingLine ??= openingLineFromToolCalls(result.toolCalls);
    if (openingLine != null) {
      return ProactiveDraft(
        text: openingLine!,
        action: ProactiveAction.callUser,
      );
    }
    return ProactiveDraft(text: selectCacheableAutoReplyText(result));
  }
}

/// Generates a proactive reply without any UI: a fresh [ProviderContainer]
/// that only needs the database, settings and presets on disk. Used by the
/// WorkManager isolate; [overrides] let tests supply the database and an
/// offline executor.
Future<String?> generateHeadlessProactiveReply({
  required String conversationId,
  required String? reminder,
  required String turnId,
  List<Override> overrides = const [],
}) async {
  final container = ProviderContainer(overrides: overrides);
  try {
    final generator = container.read(proactiveReplyGeneratorProvider);
    final conversation = await generator.loadConversation(conversationId);
    if (conversation == null) return null;
    final reply = await generator.generate(
      conversation: conversation,
      reminder: reminder,
      turnId: turnId,
    );
    return reply.trim().isEmpty ? null : reply;
  } finally {
    container.dispose();
  }
}
