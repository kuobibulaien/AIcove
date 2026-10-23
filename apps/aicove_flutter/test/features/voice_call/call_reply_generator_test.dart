import 'dart:io';

import 'package:aicove_flutter/src/features/chat/services/api_runner.dart';
import 'package:aicove_flutter/src/features/chat/services/chat_send_service.dart';
import 'package:aicove_flutter/src/features/observability/trace_models.dart';
import 'package:aicove_flutter/src/features/observability/trace_store.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/voice_call/data/api_runner_call_reply_generator.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/voice_call_ports.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按给定的增量流式输出，最后返回整段回复。
class _Runner implements ApiRunner {
  _Runner(this.deltas, this.full);
  final List<String> deltas;
  final String full;
  Object? seenTraceContext;
  String? seenTurnId;

  @override
  Future<ApiCallResult> executeApiCall({
    required ApiConfig config,
    required String sessionId,
    required String? userText,
    required responseProcessors,
    availableTools,
    String? turnId,
    trace,
    void Function(String toolName)? onToolExecuting,
    bool enableStreaming = false,
    void Function(String delta)? onStreamTextDelta,
    void Function()? onStreamTextReset,
    void Function()? onStreamToolCallObserved,
    void Function()? onStreamingFallback,
    traceContext,
    cancellation,
  }) async {
    seenTraceContext = traceContext;
    seenTurnId = turnId;
    deltas.forEach(onStreamTextDelta!);
    return ApiCallResult(
      replyText: full,
      processedText: full,
      pluginEvents: const [],
      toolResults: const [],
    );
  }
}

void main() {
  Future<String> reply(List<String> deltas, String full) =>
      ApiRunnerCallReplyGenerator(
        runner: _Runner(deltas, full),
        base: ApiConfig(
          settings: mapUiModelsToAppSettings({}),
          modelFullId: 'openai:gpt-4o',
          providerApiBase: 'https://example.invalid',
          customConfig: const {},
          messages: const [],
        ),
        sessionId: 's',
      ).streamReply(const [CallTurn(role: 'user', text: '喂')]).join();

  test('a non-streamed reply still reaches the call', () async {
    expect(await reply(const [], '诶？在呢。'), '诶？在呢。');
  });

  test('a streamed reply is not spoken twice', () async {
    expect(await reply(const ['诶？', '在呢。'], '诶？在呢。'), '诶？在呢。');
  });

  test('a stream cut short is completed from the final reply', () async {
    expect(await reply(const ['诶？'], '诶？在呢。'), '诶？在呢。');
  });

  test('each call turn shows up in the conversation trace log', () async {
    final dir = await Directory.systemTemp.createTemp('voice_call_trace_');
    addTearDown(() => dir.delete(recursive: true));
    final store = TraceStore(rootDirResolver: () async => dir);
    final runner = _Runner(const ['嗯。'], '嗯。');
    await ApiRunnerCallReplyGenerator(
      runner: runner,
      base: ApiConfig(
        settings: mapUiModelsToAppSettings({}),
        modelFullId: 'openai:gpt-4o',
        providerApiBase: 'https://example.invalid',
        customConfig: const {},
        messages: const [],
      ),
      sessionId: 'voice_call_c1',
      traceStore: store,
    ).streamReply(const [CallTurn(role: 'user', text: '喂')]).join();
    await Future<void>.delayed(Duration.zero);

    final trace = runner.seenTraceContext as TraceContext;
    expect(trace.sessionId, 'voice_call_c1');
    expect(trace.turnId, runner.seenTurnId);
    final stages = store.entries.value
        .where((e) => e.traceId == trace.traceId)
        .map((e) => e.stage)
        .toList();
    expect(stages, [
      TraceStage.turnStarted.value,
      TraceStage.turnCompleted.value,
    ]);
  });
}
