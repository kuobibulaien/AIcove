import 'types.dart';

sealed class KernelEvent {
  const KernelEvent(this.round);

  /// 1-based round index; 0 for run-level events.
  final int round;
}

class RoundStarted extends KernelEvent {
  const RoundStarted(super.round);
}

class TextDelta extends KernelEvent {
  const TextDelta(super.round, this.delta);
  final String delta;
}

class TextReset extends KernelEvent {
  const TextReset(super.round);
}

/// Incremental tool-call snapshot from a streaming response, including partial
/// arguments, so transport previews can render before the call completes.
class ToolCallsObserved extends KernelEvent {
  const ToolCallsObserved(super.round, this.snapshot);
  final List<KernelToolCall> snapshot;
}

class ToolCallsDetected extends KernelEvent {
  const ToolCallsDetected(super.round, this.calls);
  final ResolvedToolCalls calls;
}

class ToolBatchFinished extends KernelEvent {
  const ToolBatchFinished(super.round, this.calls, this.results);
  final List<KernelToolCall> calls;
  final List<KernelToolResult> results;
}

class RoundCompleted extends KernelEvent {
  const RoundCompleted(super.round, {required this.hadTools, this.verdict});
  final bool hadTools;
  final TurnVerdict? verdict;
}

class OverflowRecovered extends KernelEvent {
  const OverflowRecovered(super.round);
}

class RunFinished extends KernelEvent {
  const RunFinished(super.round, this.result);
  final AgentLoopResult result;
}

class RunFailed extends KernelEvent {
  const RunFailed(super.round, {required this.stage, required this.error});

  /// Name of the stage that threw, e.g. `modelPort`.
  final String stage;
  final Object error;
}

/// Observers are awaited in order, so trace writes keep their timing.
typedef KernelObserver = Future<void> Function(KernelEvent event);
