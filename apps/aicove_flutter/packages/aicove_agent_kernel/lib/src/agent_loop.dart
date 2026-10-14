import 'cancellation.dart';
import 'events.dart';
import 'stages.dart';
import 'types.dart';

KernelMessage _defaultSteeringMessage(String text) =>
    {'role': 'user', 'content': text};

/// One run of the agent loop. Single use: create a new instance per run.
///
/// Round order: steering → ① prepare → ② request (one overflow recovery)
/// → ③ unpack → ④ resolve → ⑤ pre-tool → tools? → ⑦ batch → ⑧ post-tool
/// (all stop decisions) → ⑨ encode only when continuing.
class AgentLoop {
  AgentLoop({
    required this.stages,
    required this.maxRounds,
    List<KernelObserver> observers = const [],
    KernelMessage Function(String text) steeringMessage =
        _defaultSteeringMessage,
  })  : assert(maxRounds >= 1),
        _observers = List.unmodifiable(observers),
        _steeringMessage = steeringMessage;

  final StagePipeline stages;
  final int maxRounds;
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

    Future<AgentLoopResult> finish(LoopStatus status, [String? reason]) async {
      _closed = true;
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
      for (round = 1; round <= maxRounds; round++) {
        cancel.throwIfCancelled();
        final ctx = TurnContext(
          round: round,
          maxRounds: maxRounds,
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
        var prepared =
            await stages.preparer.prepare(running, PrepareMode.initial, ctx);
        running = prepared.running;

        AssistantTurn raw;
        for (var recovery = 0;; recovery++) {
          cancel.throwIfCancelled();
          try {
            stage = 'modelPort';
            raw = await stages.model.send(prepared, ctx);
            break;
          } on KernelContextOverflow {
            if (cancel.isCancelled) throw const KernelCancelledException();
            if (recovery >= 1 || !stages.preparer.canRecoverOverflow) rethrow;
            stage = 'preparer';
            prepared = await stages.preparer
                .prepare(running, PrepareMode.recovery, ctx);
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
        stage = 'preTool';
        await stages.preTool.beforeTools(turn, calls, ctx);
        cancel.throwIfCancelled();

        if (calls.isEmpty) {
          await _emitRound(RoundCompleted(round, hadTools: false), cancel);
          cancel.throwIfCancelled();
          return finish(LoopStatus.completed);
        }
        if (turn.finishReason
            case final finishReason?
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
        final results = await _runBatch(calls.calls, ctx);
        cancel.throwIfCancelled();
        allCalls.addAll(calls.calls);
        allResults.addAll(results);
        await _emitRound(ToolBatchFinished(round, calls.calls, results), cancel);
        cancel.throwIfCancelled();

        stage = 'postTool';
        var verdict =
            await stages.postTool.afterTools(turn, calls, results, ctx);
        cancel.throwIfCancelled();
        if (verdict.shouldContinue && round >= maxRounds) {
          verdict = const TurnVerdict.stop('maxRounds');
        }
        await _emitRound(RoundCompleted(round, hadTools: true, verdict: verdict), cancel);
        cancel.throwIfCancelled();
        if (!verdict.shouldContinue) {
          return finish(LoopStatus.stopped, verdict.reason);
        }

        stage = 'encoder';
        final continuation =
            await stages.encoder.encode(turn, calls, results, ctx);
        // A continuation encoded after cancellation is dropped.
        cancel.throwIfCancelled();
        running = [...running, ...continuation];
      }
      // Unreachable: the post-tool guard stops at maxRounds.
      round = maxRounds;
      return finish(LoopStatus.stopped, 'maxRounds');
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
    ctx.cancellation.throwIfCancelled();
    if (tools.modeFor(calls, ctx) == BatchMode.parallel) {
      return Future.wait([for (final call in calls) tools.executeOne(call, ctx)]);
    }
    final results = <KernelToolResult>[];
    for (final call in calls) {
      ctx.cancellation.throwIfCancelled();
      results.add(await tools.executeOne(call, ctx));
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
