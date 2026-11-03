import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';

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
  final signals = <KernelCancellation?>[];
  final entered = StreamController<void>.broadcast();
  Completer<void>? gate;
  Object? failure;

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
    KernelCancellation? cancellation,
  }) async {
    signals.add(cancellation);
    entered.add(null);
    if (gate != null) {
      if (cancellation == null) {
        await gate!.future;
      } else {
        await cancellation.bind(gate!.future);
      }
    }
    if (failure != null) throw failure!;
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

  ApiRunnerCallReplyGenerator generator(_Runner runner, {TraceStore? store}) =>
      ApiRunnerCallReplyGenerator(
        runner: runner,
        base: ApiConfig(
          settings: mapUiModelsToAppSettings({}),
          modelFullId: 'openai:test',
          providerApiBase: 'https://example.invalid',
          customConfig: const {},
          messages: const [],
        ),
        sessionId: 'cancel_test',
        traceStore: store,
      );

  test('immediate subscription cancellation never starts a request', () async {
    final runner = _Runner([], 'late');
    final subscription = generator(runner).streamReply(const []).listen((_) {});
    await subscription.cancel().timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);
    expect(runner.signals, isEmpty);
  });

  test('cancel before trace completes never starts a request', () async {
    final directory = await Directory.systemTemp.createTemp('call_cancel_');
    addTearDown(() => directory.delete(recursive: true));
    final entered = Completer<void>();
    final release = Completer<Directory>();
    final runner = _Runner([], 'late');
    final store = TraceStore(
      rootDirResolver: () {
        if (!entered.isCompleted) entered.complete();
        return release.future;
      },
    );
    final sub = generator(
      runner,
      store: store,
    ).streamReply(const []).listen((_) {});
    await entered.future;
    await sub.cancel().timeout(const Duration(seconds: 1));
    release.complete(directory);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await store.waitForPendingWrites();
    expect(runner.signals, isEmpty);
    expect(
      store.entries.value.where((e) => e.stage == TraceStage.turnFailed.value),
      isEmpty,
    );
  });

  test(
    'each stream owns its cancellation signal and cancel never waits for runner',
    () async {
      final runner = _Runner([], 'reply')..gate = Completer<void>();
      final gen = generator(runner);
      final firstEntered = runner.entered.stream.first;
      final a = gen.streamReply(const []).listen((_) {});
      await firstEntered;
      final secondEntered = runner.entered.stream.first;
      final bText = gen.streamReply(const []).join();
      await secondEntered;
      try {
        expect(runner.signals, everyElement(isA<KernelCancellation>()));
        expect(identical(runner.signals[0], runner.signals[1]), isFalse);
        await a.cancel().timeout(const Duration(seconds: 1));
        expect(runner.signals[0]!.isCancelled, isTrue);
        expect(runner.signals[1]!.isCancelled, isFalse);
      } finally {
        await a.cancel();
        runner.gate!.complete();
        await bText;
      }
    },
  );

  test(
    'kernel cancellation completes silently but network failures still surface',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'call_cancel_trace_',
      );
      final store = TraceStore(rootDirResolver: () async => directory);
      addTearDown(() async {
        await store.waitForPendingWrites();
        await directory.delete(recursive: true);
      });
      final runner = _Runner([], 'late')..gate = Completer<void>();
      final entered = runner.entered.stream.first;
      final text = generator(runner, store: store).streamReply(const []).join();
      // Observe errors immediately, including the pre-fix null-signal failure.
      final checked = expectLater(text, completion(isEmpty));
      await entered;
      try {
        expect(runner.signals.single, isNotNull);
        runner.signals.single!.cancel();
        await checked.timeout(const Duration(seconds: 1));
      } finally {
        runner.gate!.complete();
      }
      expect(
        store.entries.value.where(
          (e) => e.stage == TraceStage.turnFailed.value,
        ),
        isEmpty,
      );
      final broken = _Runner([], '')..failure = StateError('network');
      await expectLater(
        generator(broken, store: store).streamReply(const []).drain<void>(),
        throwsA(isA<StateError>()),
      );
      expect(
        store.entries.value.where(
          (e) => e.stage == TraceStage.turnFailed.value,
        ),
        hasLength(1),
      );
    },
  );

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
    await store.waitForPendingWrites();

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
