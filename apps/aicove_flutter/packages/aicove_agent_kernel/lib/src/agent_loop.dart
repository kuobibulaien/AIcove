import 'cancellation.dart';
import 'dart:convert';
import 'events.dart';
import 'stages.dart';
import 'types.dart';

KernelMessage _defaultSteeringMessage(String text) => {
  'role': 'user',
  'content': text,
};

/// One run of the agent loop. Single use: create a new instance per run.
///
/// Round order: steering → ① prepare → ② request (one overflow recovery)
/// → ③ unpack → ④ resolve → ⑤ pre-tool → ⑦ batch → ⑨ record → ⑧ stop.
/// Request rendering belongs to the next prepare, not to transcript commits.
class AgentLoop {
  AgentLoop({
    required this.stages,
    this.onTranscript,
    List<KernelObserver> observers = const [],
    KernelMessage Function(String text) steeringMessage =
        _defaultSteeringMessage,
  }) : _observers = List.unmodifiable(observers),
       _steeringMessage = steeringMessage;

  final StagePipeline stages;
  final Future<void> Function(List<KernelMessage>)? onTranscript;
  final List<KernelObserver> _observers;
  final KernelMessage Function(String text) _steeringMessage;

  final List<String> _steering = [];
  bool _started = false;
  bool _closed = false;

  /// Queues a user instruction for the start of the next round. Returns false
  /// once the run has ended.
  bool steer(String text) {
    if (_closed) return false;
    _steering.add(text);
    return true;
  }

  /// Cancellation is re-checked after every stage and observer that can
  /// suspend, so no later stage starts once the run is cancelled.
  Future<AgentLoopResult> run(
    List<KernelMessage> messages, {
    KernelCancellation? cancellation,
  }) async {
    if (_started) throw StateError('AgentLoop is single use');
    _started = true;
    final cancel = cancellation ?? KernelCancellation();
    var running = List<KernelMessage>.of(messages);
    final allCalls = <KernelToolCall>[];
    final allResults = <KernelToolResult>[];
    AssistantTurn? lastTurn;
    var round = 0;
    var stage = 'loop';
    AssistantTurn? pendingTurn;
    ResolvedToolCalls? pendingCalls;
    TurnContext? pendingContext;
    int? pendingStart;
    List<KernelToolResult>? pendingResults;

    Future<AgentLoopResult> finish(
      LoopStatus status, [
      KernelStopReason? reason,
    ]) async {
      _closed = true;
      if (status == LoopStatus.cancelled && pendingTurn != null) {
        final calls = pendingCalls!;
        final results =
            pendingResults ??
            [
              for (final call in calls.calls)
                KernelToolResult(
                  callId: call.id,
                  name: call.name,
                  isError: true,
                  content: '未执行：任务已取消',
                ),
            ];
        if (pendingResults == null) {
          allCalls.addAll(calls.calls);
          allResults.addAll(results);
        }
        running = [
          ...running.take(pendingStart!),
          ...await stages.encoder.encode(
            pendingTurn!,
            calls,
            results,
            pendingContext!,
          ),
        ];
      }
      await onTranscript?.call(List.unmodifiable(running));
      final result = AgentLoopResult(
        status: status,
        rounds: round,
        runningMessages: running,
        toolCalls: allCalls,
        toolResults: allResults,
        lastTurn: lastTurn,
        stopReason: reason,
      );
      await _emit(RunFinished(round, result));
      return result;
    }

    try {
      // Like Pi, the loop runs until the model stops calling tools.
      for (round = 1; ; round++) {
        cancel.throwIfCancelled();
        final ctx = TurnContext(
          round: round,
          cancellation: cancel,
          emit: _emit,
        );
        if (_steering.isNotEmpty) {
          running = [...running, ..._steering.map(_steeringMessage)];
          _steering.clear();
        }
        await _emitRound(RoundStarted(round), cancel);
        cancel.throwIfCancelled();

        stage = 'preparer';
        var prepared = await stages.preparer.prepare(
          running,
          PrepareMode.initial,
          ctx,
        );
        running = prepared.running;

        AssistantTurn raw;
        for (var recovery = 0; ; recovery++) {
          cancel.throwIfCancelled();
          try {
            stage = 'modelPort';
            raw = await stages.model.send(prepared, ctx);
            break;
          } on KernelContextOverflow {
            if (cancel.isCancelled) throw const KernelCancelledException();
            if (recovery >= 1 || !stages.preparer.canRecoverOverflow) rethrow;
            stage = 'preparer';
            prepared = await stages.preparer.prepare(
              running,
              PrepareMode.recovery,
              ctx,
            );
            running = prepared.running;
            cancel.throwIfCancelled();
            await _emitRound(OverflowRecovered(round), cancel);
            cancel.throwIfCancelled();
          }
        }
        // A response that arrives after cancellation is discarded.
        cancel.throwIfCancelled();

        stage = 'unpacker';
        final turn = await stages.unpacker.unpack(raw, ctx);
        lastTurn = turn;
        cancel.throwIfCancelled();
        stage = 'resolver';
        final calls = stages.resolver.resolve(turn, ctx);
        final turnStart = running.length;
        // Record the assistant before any side effect. The adapter replaces
        // this canonical snapshot with its lossless provider form after tools.
        running = [
          ...running,
          {
            'role': 'assistant',
            'content': turn.text,
            if (calls.calls.isNotEmpty)
              'tool_calls': [
                for (final call in calls.calls)
                  {
                    'id': call.id,
                    'type': 'function',
                    'function': {
                      'name': call.name,
                      'arguments': jsonEncode(call.arguments),
                    },
                  },
              ],
          },
        ];
        if (!calls.isEmpty) {
          pendingTurn = turn;
          pendingCalls = calls;
          pendingContext = ctx;
          pendingStart = turnStart;
          pendingResults = null;
        }
        await onTranscript?.call(List.unmodifiable(running));
        stage = 'preTool';
        await stages.preTool.beforeTools(turn, calls, ctx);
        cancel.throwIfCancelled();

        if (calls.isEmpty) {
          final recorded = await stages.encoder.encode(
            turn,
            calls,
            const [],
            ctx,
          );
          running = [...running.take(turnStart), ...recorded];
          await onTranscript?.call(List.unmodifiable(running));
          await _emitRound(RoundCompleted(round, hadTools: false), cancel);
          cancel.throwIfCancelled();
          if (_steering.isNotEmpty) {
            continue;
          }
          return finish(
            LoopStatus.completed,
            turn.finishReason == FinishReason.length
                ? KernelStopReason.length
                : null,
          );
        }
        if (turn.finishReason case final finishReason?
            when finishReason == FinishReason.stop ||
                finishReason == FinishReason.length) {
          await _emitRound(
            FinishReasonMismatch(
              round,
              finishReason: finishReason,
              toolCalls: calls.calls.length,
            ),
            cancel,
          );
          cancel.throwIfCancelled();
        }
        await _emitRound(ToolCallsDetected(round, calls), cancel);
        cancel.throwIfCancelled();

        stage = 'tools';
        final results = turn.finishReason == FinishReason.length
            ? [
                for (final call in calls.calls)
                  KernelToolResult(
                    callId: call.id,
                    name: call.name,
                    isError: true,
                    content: '输出达到长度上限被截断，这次调用没有执行，参数可能不完整。请重新完整调用。',
                  ),
              ]
            : await _runBatch(calls.calls, ctx);
        allCalls.addAll(calls.calls);
        allResults.addAll(results);
        pendingResults = results;
        stage = 'encoder';
        final recorded = await stages.encoder.encode(turn, calls, results, ctx);
        running = [...running.take(turnStart), ...recorded];
        pendingTurn = null;
        pendingCalls = null;
        pendingResults = null;
        await onTranscript?.call(List.unmodifiable(running));
        cancel.throwIfCancelled();
        await _emitRound(
          ToolBatchFinished(round, calls.calls, results),
          cancel,
        );
        cancel.throwIfCancelled();

        stage = 'postTool';
        final verdict = await stages.postTool.afterTools(
          turn,
          calls,
          results,
          ctx,
        );
        cancel.throwIfCancelled();
        await _emitRound(
          RoundCompleted(round, hadTools: true, verdict: verdict),
          cancel,
        );
        cancel.throwIfCancelled();
        final termination = results
            .map((r) => r.terminationReason)
            .whereType<KernelStopReason>()
            .firstOrNull;
        if (termination != null) return finish(LoopStatus.stopped, termination);
        if (!verdict.shouldContinue) {
          return finish(LoopStatus.stopped, verdict.reason);
        }
      }
    } on KernelCancelledException {
      return finish(LoopStatus.cancelled);
    } catch (error) {
      if (cancel.isCancelled) return finish(LoopStatus.cancelled);
      _closed = true;
      await _emit(RunFailed(round, stage: stage, error: error));
      rethrow;
    } finally {
      _closed = true;
    }
  }

  Future<List<KernelToolResult>> _runBatch(
    List<KernelToolCall> calls,
    TurnContext ctx,
  ) async {
    final tools = stages.tools;
    KernelToolResult skipped(KernelToolCall call, String reason) =>
        KernelToolResult(
          callId: call.id,
          name: call.name,
          isError: true,
          content: reason,
        );
    Future<KernelToolResult> execute(KernelToolCall call) async {
      if (ctx.cancellation.isCancelled) return skipped(call, '未执行：任务已取消');
      try {
        return await tools.executeOne(call, ctx);
      } on KernelCancelledException {
        ctx.cancellation.cancel();
        return skipped(call, '工具已取消；已发生的外部操作不会撤销');
      }
    }

    if (tools.modeFor(calls, ctx) == BatchMode.parallel)
      return Future.wait(calls.map(execute));
    final results = <KernelToolResult>[];
    for (final call in calls) {
      final termination = results
          .map((r) => r.terminationReason)
          .whereType<KernelStopReason>()
          .firstOrNull;
      results.add(
        termination == null
            ? await execute(call)
            : skipped(call, '未执行：任务已在等待用户回答'),
      );
    }
    return results;
  }

  /// Emits a non-terminal loop event, stopping between observers once the
  /// run is cancelled. Terminal events ([RunFinished], [RunFailed]) and
  /// events emitted by stages through [TurnContext.emit] (e.g. a gate's
  /// final `cancelled` decision) always reach every observer.
  Future<void> _emitRound(KernelEvent event, KernelCancellation cancel) async {
    for (final observer in _observers) {
      cancel.throwIfCancelled();
      await observer(event);
    }
  }

  Future<void> _emit(KernelEvent event) async {
    for (final observer in _observers) {
      await observer(event);
    }
  }
}
