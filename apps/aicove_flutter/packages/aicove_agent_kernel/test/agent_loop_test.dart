import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  test('no tool calls ends after one round with ordered events', () async {
    final h = Harness(steps: [reply('hello')]);
    final result = await h.run();

    expect(result.status, LoopStatus.completed);
    expect(result.rounds, 1);
    expect(result.lastTurn!.text, 'hello');
    expect(h.events.map((e) => e.runtimeType), [
      RoundStarted,
      RoundCompleted,
      RunFinished,
    ]);
    expect(h.encoder.calls, 0);
  });

  test('tool rounds run serially and feed continuation to next request',
      () async {
    final h = Harness(steps: [
      callTools(['a', 'b']),
      reply('done'),
    ]);
    final result = await h.run();

    expect(result.status, LoopStatus.completed);
    expect(h.tools.log, ['start:a', 'end:a', 'start:b', 'end:b']);
    expect(result.toolResults.map((r) => r.content), ['ok:a', 'ok:b']);
    final secondRequest = h.model.requests[1];
    expect(secondRequest.map((m) => m['content']), [
      'hi',
      'calling',
      'ok:a',
      'ok:b',
    ]);
  });

  test('parallel batch starts all tools before any completes, keeps order',
      () async {
    final gateA = Completer<String>();
    final gateB = Completer<String>();
    final tools = FakeTools(mode: BatchMode.parallel, handlers: {
      'a': () => gateA.future,
      'b': () => gateB.future,
    });
    final h = Harness(steps: [callTools(['a', 'b']), reply('done')], tools: tools);
    final run = h.run();
    await pumpEventQueue();
    expect(tools.log, ['start:a', 'start:b']);
    gateB.complete('B');
    gateA.complete('A');
    final result = await run;
    expect(result.toolResults.map((r) => r.content), ['A', 'B']);
  });

  test('maxRounds stops without encoding the last round', () async {
    final h = Harness(
      steps: [callTools(['a']), callTools(['a']), reply('never')],
      maxRounds: 2,
    );
    final result = await h.run();

    expect(result.status, LoopStatus.stopped);
    expect(result.stopReason, 'maxRounds');
    expect(h.model.requests, hasLength(2));
    expect(h.encoder.calls, 1);
  });

  test('post-tool stop ends the run and skips the encoder', () async {
    final h = Harness(
      steps: [callTools(['draw_image'])],
      post: FakePost(const TurnVerdict.stop('fast route')),
    );
    final result = await h.run();

    expect(result.status, LoopStatus.stopped);
    expect(result.stopReason, 'fast route');
    expect(h.encoder.calls, 0);
  });

  group('overflow recovery', () {
    test('recovers once via recovery mode without re-running tools', () async {
      final h = Harness(steps: [
        callTools(['a']),
        const KernelContextOverflow('too long'),
        reply('done'),
      ]);
      final result = await h.run();

      expect(result.status, LoopStatus.completed);
      expect(h.preparer.modes, [
        PrepareMode.initial,
        PrepareMode.initial,
        PrepareMode.recovery,
      ]);
      expect(h.tools.log, ['start:a', 'end:a']);
      expect(h.events.whereType<OverflowRecovered>(), hasLength(1));
    });

    test('second overflow in the same round fails', () async {
      final h = Harness(steps: [
        const KernelContextOverflow('1'),
        const KernelContextOverflow('2'),
      ]);
      await expectLater(h.run(), throwsA(isA<KernelContextOverflow>()));
      expect(h.preparer.modes, [PrepareMode.initial, PrepareMode.recovery]);
    });

    test('no recovery when the preparer cannot recover', () async {
      final h = Harness(
        steps: [const KernelContextOverflow('x')],
        canRecover: false,
      );
      await expectLater(h.run(), throwsA(isA<KernelContextOverflow>()));
      expect(h.preparer.modes, [PrepareMode.initial]);
    });

    test('other errors are rethrown unchanged with the failing stage', () async {
      final h = Harness(steps: [StateError('boom')]);
      await expectLater(h.run(), throwsA(isA<StateError>()));
      final failed = h.events.whereType<RunFailed>().single;
      expect(failed.stage, 'modelPort');
      expect(h.preparer.modes, [PrepareMode.initial]);
    });
  });

  group('cancellation', () {
    test('before the request: model is never called', () async {
      final cancel = KernelCancellation()..cancel();
      final h = Harness(steps: [reply('x')]);
      final result = await h.run(cancellation: cancel);
      expect(result.status, LoopStatus.cancelled);
      expect(h.model.requests, isEmpty);
    });

    test('during the request: no overflow recovery, result cancelled',
        () async {
      final cancel = KernelCancellation();
      final h = Harness(steps: [
        (TurnContext ctx) async {
          await ctx.cancellation.whenCancelled;
          throw const KernelContextOverflow('aborted request');
        },
      ]);
      final run = h.run(cancellation: cancel);
      await pumpEventQueue();
      cancel.cancel();
      final result = await run;
      expect(result.status, LoopStatus.cancelled);
      expect(h.preparer.modes, [PrepareMode.initial]);
      expect(h.events.whereType<RunFailed>(), isEmpty);
    });

    test('a response arriving after cancellation is discarded', () async {
      final cancel = KernelCancellation();
      final gate = Completer<void>();
      final h = Harness(steps: [blockedOn(gate, callTools(['a']))]);
      final run = h.run(cancellation: cancel);
      await pumpEventQueue();
      cancel.cancel();
      gate.complete();
      final result = await run;
      expect(result.status, LoopStatus.cancelled);
      expect(h.tools.log, isEmpty);
    });

    test('during a tool: result dropped, no next round', () async {
      final cancel = KernelCancellation();
      final toolGate = Completer<String>();
      final tools = FakeTools(handlers: {'a': () => toolGate.future});
      final h = Harness(steps: [callTools(['a']), reply('never')], tools: tools);
      final run = h.run(cancellation: cancel);
      await pumpEventQueue();
      cancel.cancel();
      toolGate.complete('late');
      final result = await run;
      expect(result.status, LoopStatus.cancelled);
      expect(result.toolResults, isEmpty);
      expect(h.encoder.calls, 0);
      expect(h.model.requests, hasLength(1));
    });

    test('cancelling one run does not affect a concurrent run', () async {
      final cancelA = KernelCancellation();
      final gate = Completer<void>();
      final a = Harness(steps: [blockedOn(gate, reply('a'))]);
      final b = Harness(steps: [blockedOn(gate, reply('b'))]);
      final runA = a.run(cancellation: cancelA);
      final runB = b.run();
      await pumpEventQueue();
      cancelA.cancel();
      gate.complete();
      expect((await runA).status, LoopStatus.cancelled);
      final resultB = await runB;
      expect(resultB.status, LoopStatus.completed);
      expect(resultB.lastTurn!.text, 'b');
    });
  });

  test('steering is injected in order at the next round, rejected after end',
      () async {
    late Harness h;
    h = Harness(steps: [
      (TurnContext ctx) async {
        h.loop.steer('first');
        h.loop.steer('second');
        return callTools(['a']);
      },
      reply('done'),
    ]);
    await h.run();

    final second = h.model.requests[1];
    expect(second.skip(second.length - 2).map((m) => m['content']),
        ['first', 'second']);
    expect(second.where((m) => m['content'] == 'first'), hasLength(1));
    expect(h.loop.steer('late'), isFalse);
  });

  test('a loop instance runs once', () async {
    final h = Harness(steps: [reply('x')]);
    await h.run();
    expect(h.run, throwsStateError);
  });
}
