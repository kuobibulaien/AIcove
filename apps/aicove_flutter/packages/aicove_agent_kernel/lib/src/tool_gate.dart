import 'dart:async';

import 'events.dart';
import 'plugin_host.dart';
import 'stages.dart';
import 'types.dart';

enum GateDecision { allow, deny, ask }

class GateVerdict {
  const GateVerdict._(this.decision, this.reason);

  const GateVerdict.allow() : this._(GateDecision.allow, null);

  const GateVerdict.deny(String reason) : this._(GateDecision.deny, reason);

  /// [reason] is shown to the user when asking for approval.
  const GateVerdict.ask(String reason) : this._(GateDecision.ask, reason);

  final GateDecision decision;
  final String? reason;
}

/// Per-agent authorization policy, checked before every tool call. Pure and
/// synchronous so batching can be decided up front.
abstract interface class ToolGate {
  GateVerdict check(KernelToolCall call, ToolEffect effect);
}

/// Lets every call through; the policy of ordinary chat.
class AllowAllGate implements ToolGate {
  const AllowAllGate();

  @override
  GateVerdict check(KernelToolCall call, ToolEffect effect) =>
      const GateVerdict.allow();
}

class ApprovalRequest {
  const ApprovalRequest({
    required this.toolName,
    required this.effect,
    required this.arguments,
    required this.reason,
    required this.withdrawn,
  });

  final String toolName;
  final ToolEffect effect;
  final Map<String, dynamic> arguments;
  final String reason;

  /// Completes once if the executor stops waiting before the port answers
  /// (timeout, cancellation, or a failing port), so the prompt can be closed.
  /// Never completes when the port answers.
  final Future<void> withdrawn;
}

/// Asks the user to approve one call; resolves true only on explicit consent.
/// A late answer after [ApprovalRequest.withdrawn] is ignored.
abstract interface class ApprovalPort {
  Future<bool> request(ApprovalRequest request);
}

/// ⑦ decorator that applies a [ToolGate]. Denied, rejected, timed-out and
/// cancelled approvals become structured error results so the loop goes on.
/// Batches containing a call that needs approval run serially, one prompt at
/// a time.
class GatedToolExecutor implements ToolBatchExecutor {
  GatedToolExecutor(
    this._inner, {
    required ToolGate gate,
    required ToolEffect Function(KernelToolCall call) effectOf,
    ApprovalPort? approvals,
    this.approvalTimeout = const Duration(minutes: 2),
  })  : _gate = gate,
        _effectOf = effectOf,
        _approvals = approvals;

  final ToolBatchExecutor _inner;
  final ToolGate _gate;
  final ToolEffect Function(KernelToolCall call) _effectOf;
  final ApprovalPort? _approvals;
  final Duration approvalTimeout;

  @override
  BatchMode modeFor(List<KernelToolCall> calls, TurnContext ctx) {
    final asks = calls.any(
      (call) => _gate.check(call, _effectOf(call)).decision == GateDecision.ask,
    );
    return asks ? BatchMode.serial : _inner.modeFor(calls, ctx);
  }

  @override
  Future<KernelToolResult> executeOne(
    KernelToolCall call,
    TurnContext ctx,
  ) async {
    final effect = _effectOf(call);
    final verdict = _gate.check(call, effect);
    var outcome = switch (verdict.decision) {
      GateDecision.allow => GateOutcome.allowed,
      GateDecision.deny => GateOutcome.denied,
      GateDecision.ask => await _ask(call, effect, verdict.reason ?? '', ctx),
    };
    if (_runs(outcome) && ctx.cancellation.isCancelled) {
      outcome = GateOutcome.cancelled;
    }
    Future<void> emit(GateOutcome outcome) => ctx.emit(ToolGated(
          ctx.round,
          callId: call.id,
          toolName: call.name,
          effect: effect.name,
          outcome: outcome,
        ));
    await emit(outcome);
    // Cancellation may arrive while the event is being observed; a call that
    // has not started must not start after that. A second event for the same
    // call records it, so the last event always matches the result.
    if (_runs(outcome) && ctx.cancellation.isCancelled) {
      outcome = GateOutcome.cancelled;
      await emit(outcome);
    }
    if (_runs(outcome)) return _inner.executeOne(call, ctx);
    return KernelToolResult(
      callId: call.id,
      name: call.name,
      content: switch (outcome) {
        GateOutcome.denied => '不允许执行：${verdict.reason}',
        GateOutcome.timedOut => '用户未允许：等待确认超时',
        GateOutcome.cancelled => '用户未允许：本次运行已取消',
        _ => '用户未允许：${call.name}',
      },
      isError: true,
    );
  }

  static bool _runs(GateOutcome outcome) =>
      outcome == GateOutcome.allowed || outcome == GateOutcome.approved;

  Future<GateOutcome> _ask(
    KernelToolCall call,
    ToolEffect effect,
    String reason,
    TurnContext ctx,
  ) async {
    final approvals = _approvals;
    if (approvals == null || ctx.cancellation.isCancelled) {
      return ctx.cancellation.isCancelled
          ? GateOutcome.cancelled
          : GateOutcome.rejected;
    }
    final withdrawn = Completer<void>();
    var answered = false;
    try {
      final answer = approvals
          .request(ApprovalRequest(
            toolName: call.name,
            effect: effect,
            arguments: call.arguments,
            reason: reason,
            withdrawn: withdrawn.future,
          ))
          .then((ok) {
            answered = true;
            return ok ? GateOutcome.approved : GateOutcome.rejected;
          })
          .timeout(approvalTimeout, onTimeout: () => GateOutcome.timedOut);
      final cancelled =
          ctx.cancellation.whenCancelled.then((_) => GateOutcome.cancelled);
      return await Future.any([answer, cancelled]);
    } catch (_) {
      return GateOutcome.rejected;
    } finally {
      if (!answered && !withdrawn.isCompleted) withdrawn.complete();
    }
  }
}
