import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart'
    show KernelCancelledException;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_logger.dart';

import '../../../core/database/converters/database_converters.dart';
import '../../../core/database/database_provider.dart';
import '../../chat/domain/conversation.dart';
import '../../chat/services/chat_history_store.dart';
import '../../chat/services/chat_send_service.dart';
import '../../observability/trace_models.dart';
import '../../observability/trace_store.dart';
import '../../settings/app_settings.dart';
import '../../plugins/prompts/plugin_prompts.dart';
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
  }) async {
    // Without a trace the request never shows in the log center's
    // conversation view, only in the raw API log.
    final trace = await _startProactiveTrace(sessionId, turnId);
    try {
      final result = await service.executeApiCall(
        config: config.copyWith(traceContext: trace),
        sessionId: sessionId,
        userText: userText,
        turnId: turnId,
      );
      _recordProactiveTrace(trace, TraceStage.turnCompleted);
      return result;
    } catch (_) {
      _recordProactiveTrace(
        trace,
        TraceStage.turnFailed,
        status: TraceEventStatus.failed,
      );
      rethrow;
    }
  };
});

Future<TraceContext?> _startProactiveTrace(
  String sessionId,
  String turnId,
) async {
  try {
    return await TraceStore.instance.startTurn(
      sessionId: sessionId,
      turnId: turnId,
      source: 'ProactiveReply',
    );
  } catch (_) {
    return null;
  }
}

void _recordProactiveTrace(
  TraceContext? trace,
  TraceStage stage, {
  TraceEventStatus status = TraceEventStatus.success,
}) {
  if (trace == null) return;
  unawaited(() async {
    try {
      await TraceStore.instance.record(
        traceId: trace.traceId,
        sessionId: trace.sessionId,
        turnId: trace.turnId,
        stage: stage,
        status: status,
        source: 'ProactiveReply',
      );
    } catch (_) {
      // The trace is for debugging only; a failed write must not fail the reply.
    }
  }());
}

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
    String? modelRef,
  }) async {
    final history = await _ref
        .read(chatHistoryStoreProvider)
        .loadCanonicalContextMessages(conversation.id, limit: contextWindow);
    if (history.isEmpty && (reminder?.trim().isEmpty ?? true)) {
      throw StateError('proactive_context_empty');
    }
    final settings = await _ref.read(appSettingsProvider.future);
    final config = await _ref
        .read(chatSendServiceProvider)
        .prepareApiConfig(
          conv: conversation,
          history: history,
          userText: reminder,
          overrideModel:
              modelRef ?? resolveAutoReplyAgentModelRef(settings, conversation),
          conversationId: conversation.id,
          requestTime: requestTime,
          forceInlineImageRoute: true,
        );
    final pluginPrompts = await _ref.read(pluginPromptsProvider.future);
    var effectiveReminder = reminder;
    if ((reminder?.trim().isNotEmpty ?? false) &&
        !reminder!.contains('<image>') &&
        config.messages.any(
          (message) =>
              message['role'] == 'system' &&
              (message['content'] ?? '').toString().contains('<image>'),
        )) {
      effectiveReminder =
          '$reminder\n'
          '${pluginPrompts.of(PluginPromptSlot.proactiveImageHint)}';
    }
    return disableNativeToolCallsForAutoReplyGeneration(
      appendAutoReplyReminderAsLastUser(config, effectiveReminder),
    );
  }

  /// Generates the reply text; empty when the model returned nothing usable.
  Future<String> generate({
    required Conversation conversation,
    required String? reminder,
    required String turnId,
    DateTime? requestTime,
  }) async {
    return _withModelFallback(conversation, (modelRef) async {
      final config = await prepare(
        conversation: conversation,
        reminder: reminder,
        requestTime: requestTime,
        modelRef: modelRef,
      );
      final result = await _ref.read(proactiveReplyExecutorProvider)(
        config: config,
        sessionId: conversation.id,
        userText: reminder,
        turnId: turnId,
      );
      return selectCacheableAutoReplyText(result);
    });
  }

  Future<T> _withModelFallback<T>(
    Conversation conversation,
    Future<T> Function(String modelRef) run,
  ) async {
    final settings = await _ref.read(appSettingsProvider.future);
    final candidates = resolveAutoReplyAgentModelCandidates(
      settings,
      conversation,
    );
    for (var index = 0; index < candidates.length; index++) {
      final modelRef = candidates[index];
      try {
        return await run(modelRef);
      } on KernelCancelledException {
        rethrow;
      } catch (error) {
        AppLogger.warning(
          'ProactiveReplyGenerator',
          '主动回复模型请求失败',
          metadata: {
            'conversationId': conversation.id,
            'modelRef': modelRef,
            'error': error.toString(),
          },
        );
        if (index == candidates.length - 1) rethrow;
      }
    }
    throw StateError('proactive_model_candidates_empty');
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
    final pluginPrompts = await _ref.read(pluginPromptsProvider.future);
    final withHint =
        '$reminder\n'
        '${pluginPrompts.of(PluginPromptSlot.proactiveCallHint)}';
    return _withModelFallback(conversation, (modelRef) async {
      String? openingLine;
      bool Function({bool enabled})? yieldAtBoundary;
      final tool = buildCallUserTool(
        description: pluginPrompts.of(PluginPromptSlot.proactiveCallTool),
        onCall: (line) {
          openingLine ??= line;
          yieldAtBoundary?.call();
        },
      );
      final prepared = await prepare(
        conversation: conversation,
        reminder: withHint,
        requestTime: requestTime,
        modelRef: modelRef,
      );
      final config = prepared.copyWith(
        tools: [tool.toOpenAISchema()],
        boundTools: [tool],
        onYieldReady: (yieldHandle) {
          yieldAtBoundary = yieldHandle;
          prepared.onYieldReady?.call(yieldHandle);
        },
      );
      final result = await _ref.read(proactiveReplyExecutorProvider)(
        config: config,
        sessionId: conversation.id,
        userText: withHint,
        turnId: turnId,
      );
      if (openingLine == null &&
          result.toolResults.isEmpty &&
          result.rawToolResults.isEmpty) {
        openingLine = openingLineFromToolCalls(result.toolCalls);
      }
      if (openingLine != null) {
        return ProactiveDraft(
          text: openingLine!,
          action: ProactiveAction.callUser,
        );
      }
      return ProactiveDraft(text: selectCacheableAutoReplyText(result));
    });
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
