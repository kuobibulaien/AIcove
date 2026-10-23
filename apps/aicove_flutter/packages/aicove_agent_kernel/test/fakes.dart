import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';

class FakePreparer implements RoundPreparer {
  FakePreparer({this.canRecoverOverflow = true});

  @override
  final bool canRecoverOverflow;
  final List<PrepareMode> modes = [];

  /// Runs inside a recovery prepare, before it returns.
  void Function()? onRecovery;

  @override
  Future<PreparedRound> prepare(
    List<KernelMessage> running,
    PrepareMode mode,
    TurnContext ctx,
  ) async {
    modes.add(mode);
    if (mode == PrepareMode.recovery) onRecovery?.call();
    return PreparedRound(running: running, request: List.of(running));
  }
}

/// Each step is an [AssistantTurn], an [Object] to throw, or a function
/// producing a future for full control.
class ScriptedModel implements ModelPort {
  ScriptedModel(this.steps);

  final List<Object> steps;
  final List<List<KernelMessage>> requests = [];

  @override
  Future<AssistantTurn> send(PreparedRound prepared, TurnContext ctx) async {
    requests.add(prepared.request);
    if (steps.isEmpty) throw StateError('no scripted step');
    final step = steps.removeAt(0);
    if (step is AssistantTurn) return step;
    if (step is Future<AssistantTurn> Function(TurnContext)) return step(ctx);
    throw step;
  }
}

AssistantTurn reply(String text) => AssistantTurn(text: text);

AssistantTurn callTools(List<String> names) => AssistantTurn(
      text: 'calling',
      toolCalls: [
        for (var i = 0; i < names.length; i++)
          KernelToolCall(id: 'c$i-${names[i]}', name: names[i]),
      ],
    );

class FakeTools implements ToolBatchExecutor {
  FakeTools({this.mode = BatchMode.serial, this.handlers = const {}});

  final BatchMode mode;
  final Map<String, Future<String> Function()> handlers;
  final List<String> log = [];

  @override
  BatchMode modeFor(List<KernelToolCall> calls, TurnContext ctx) => mode;

  @override
  Future<KernelToolResult> executeOne(KernelToolCall call, TurnContext ctx) async {
    log.add('start:${call.name}');
    final handler = handlers[call.name];
    final content = handler == null ? 'ok:${call.name}' : await handler();
    log.add('end:${call.name}');
    return KernelToolResult(callId: call.id, name: call.name, content: content);
  }
}

class FakePost implements PostToolDecision {
  FakePost([this.verdict = const TurnVerdict.proceed(), this.onAfter]);

  final TurnVerdict verdict;
  final FutureOr<void> Function()? onAfter;
  int calls = 0;

  @override
  Future<TurnVerdict> afterTools(
    AssistantTurn turn,
    ResolvedToolCalls calls,
    List<KernelToolResult> results,
    TurnContext ctx,
  ) async {
    this.calls++;
    await onAfter?.call();
    return verdict;
  }
}

class FakePreTool implements PreToolDecision {
  int calls = 0;

  @override
  Future<void> beforeTools(
    AssistantTurn turn,
    ResolvedToolCalls calls,
    TurnContext ctx,
  ) async {
    this.calls++;
  }
}

class FakeEncoder implements ContinuationEncoder {
  FakeEncoder([this.onEncode]);

  final FutureOr<void> Function()? onEncode;
  int calls = 0;

  @override
  Future<List<KernelMessage>> encode(
    AssistantTurn turn,
    ResolvedToolCalls resolved,
    List<KernelToolResult> results,
    TurnContext ctx,
  ) async {
    calls++;
    await onEncode?.call();
    return [
      {'role': 'assistant', 'content': turn.text},
      for (final r in results) {'role': 'tool', 'content': r.content},
    ];
  }
}

class Harness {
  Harness({
    required List<Object> steps,
    FakeTools? tools,
    FakePost? post,
    bool canRecover = true,
    this.unpacker = const PassThroughUnpacker(),
    this.onEvent,
    FutureOr<void> Function()? onEncode,
  })  : model = ScriptedModel(steps),
        encoder = FakeEncoder(onEncode),
        tools = tools ?? FakeTools(),
        post = post ?? FakePost(),
        preparer = FakePreparer(canRecoverOverflow: canRecover);
  final ScriptedModel model;
  final FakeTools tools;
  final FakePost post;
  final FakePreparer preparer;
  final ResponseUnpacker unpacker;

  /// Runs inside the observer after the event is recorded.
  final FutureOr<void> Function(KernelEvent event)? onEvent;
  final FakeEncoder encoder;
  final FakePreTool preTool = FakePreTool();
  final List<KernelEvent> events = [];

  late final AgentLoop loop = AgentLoop(
    stages: StagePipeline(
      preparer: preparer,
      model: model,
      unpacker: unpacker,
      preTool: preTool,
      tools: tools,
      postTool: post,
      encoder: encoder,
    ),
    observers: [
      (event) async {
        events.add(event);
        await onEvent?.call(event);
      },
    ],
  );

  Future<AgentLoopResult> run({KernelCancellation? cancellation}) => loop.run(
        [
          {'role': 'user', 'content': 'hi'},
        ],
        cancellation: cancellation,
      );
}

/// A model step that blocks until [gate] completes, then returns [turn].
Future<AssistantTurn> Function(TurnContext) blockedOn(
  Completer<void> gate,
  AssistantTurn turn, {
  void Function()? onEnter,
}) {
  return (ctx) async {
    onEnter?.call();
    await gate.future;
    return turn;
  };
}

/// Unpacker that runs [onUnpack] before passing the turn through.
class HookUnpacker implements ResponseUnpacker {
  HookUnpacker(this.onUnpack);

  final FutureOr<void> Function(TurnContext ctx) onUnpack;

  @override
  Future<AssistantTurn> unpack(AssistantTurn raw, TurnContext ctx) async {
    await onUnpack(ctx);
    return raw;
  }
}
