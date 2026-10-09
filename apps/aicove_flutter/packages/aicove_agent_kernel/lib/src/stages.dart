import 'cancellation.dart';
import 'events.dart';
import 'types.dart';

/// Per-round context handed to every stage.
class TurnContext {
  TurnContext({
    required this.round,
    required this.maxRounds,
    required this.cancellation,
    required Future<void> Function(KernelEvent event) emit,
  }) : _emit = emit;

  final int round;
  final int maxRounds;
  final KernelCancellation cancellation;
  final Future<void> Function(KernelEvent event) _emit;

  Future<void> emit(KernelEvent event) => _emit(event);

  bool get isLastRound => round >= maxRounds;
}

/// ① Turns running messages into request messages.
///
/// [PrepareMode.initial] runs the full chain; [PrepareMode.recovery] runs only
/// forced compaction and re-render. Both may update the running messages.
abstract interface class RoundPreparer {
  /// Whether overflow recovery is available for this run.
  bool get canRecoverOverflow;

  Future<PreparedRound> prepare(
    List<KernelMessage> running,
    PrepareMode mode,
    TurnContext ctx,
  );
}

/// ② One request attempt: budget check, preset reset, send (with stream
/// fallback). Throws [KernelContextOverflow] for recoverable overflow.
abstract interface class ModelPort {
  Future<AssistantTurn> send(PreparedRound prepared, TurnContext ctx);
}

/// ③ Unpacks a raw response (e.g. preset transport consumption).
abstract interface class ResponseUnpacker {
  Future<AssistantTurn> unpack(AssistantTurn turn, TurnContext ctx);
}

/// ④ Decides which tool calls to execute (native or text fallback).
abstract interface class ToolCallResolver {
  ResolvedToolCalls resolve(AssistantTurn turn, TurnContext ctx);
}

/// ⑤ Decision before tool execution (e.g. stable image review).
abstract interface class PreToolDecision {
  Future<void> beforeTools(
    AssistantTurn turn,
    ResolvedToolCalls calls,
    TurnContext ctx,
  );
}

/// ⑦ Executes one tool call; batching is done by the loop per [modeFor].
abstract interface class ToolBatchExecutor {
  BatchMode modeFor(List<KernelToolCall> calls, TurnContext ctx);

  Future<KernelToolResult> executeOne(KernelToolCall call, TurnContext ctx);
}

/// ⑧ All stop decisions after tool execution. A stop skips ⑨.
abstract interface class PostToolDecision {
  Future<TurnVerdict> afterTools(
    AssistantTurn turn,
    ResolvedToolCalls calls,
    List<KernelToolResult> results,
    TurnContext ctx,
  );
}

/// ⑨ Builds continuation messages appended to running messages. Only called
/// when the run continues.
abstract interface class ContinuationEncoder {
  Future<List<KernelMessage>> encode(
    AssistantTurn turn,
    ResolvedToolCalls calls,
    List<KernelToolResult> results,
    TurnContext ctx,
  );
}

/// Default stages for runs that need no unpacking or pre-tool decision.
class PassThroughUnpacker implements ResponseUnpacker {
  const PassThroughUnpacker();

  @override
  Future<AssistantTurn> unpack(AssistantTurn turn, TurnContext ctx) async =>
      turn;
}

class NativeToolCallResolver implements ToolCallResolver {
  const NativeToolCallResolver();

  @override
  ResolvedToolCalls resolve(AssistantTurn turn, TurnContext ctx) =>
      ResolvedToolCalls(turn.toolCalls);
}

class NoPreToolDecision implements PreToolDecision {
  const NoPreToolDecision();

  @override
  Future<void> beforeTools(
    AssistantTurn turn,
    ResolvedToolCalls calls,
    TurnContext ctx,
  ) async {}
}

class AlwaysContinue implements PostToolDecision {
  const AlwaysContinue();

  @override
  Future<TurnVerdict> afterTools(
    AssistantTurn turn,
    ResolvedToolCalls calls,
    List<KernelToolResult> results,
    TurnContext ctx,
  ) async =>
      const TurnVerdict.proceed();
}

/// The stage set for one run.
class StagePipeline {
  const StagePipeline({
    required this.preparer,
    required this.model,
    required this.tools,
    required this.encoder,
    this.unpacker = const PassThroughUnpacker(),
    this.resolver = const NativeToolCallResolver(),
    this.preTool = const NoPreToolDecision(),
    this.postTool = const AlwaysContinue(),
  });

  final RoundPreparer preparer;
  final ModelPort model;
  final ResponseUnpacker unpacker;
  final ToolCallResolver resolver;
  final PreToolDecision preTool;
  final ToolBatchExecutor tools;
  final PostToolDecision postTool;
  final ContinuationEncoder encoder;
}
