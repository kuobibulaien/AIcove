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
    expect(h.encoder.calls, 1);
  });

  test(
    'tool rounds run serially and feed continuation to next request',
    () async {
      final h = Harness(
        steps: [
          callTools(['a', 'b']),
          reply('done'),
        ],
      );
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
    },
  );

  test(
    'parallel batch starts all tools before any completes, keeps order',
    () async {
      final gateA = Completer<String>();
      final gateB = Completer<String>();
      final tools = FakeTools(
        mode: BatchMode.parallel,
        handlers: {'a': () => gateA.future, 'b': () => gateB.future},
      );
      final h = Harness(
        steps: [
          callTools(['a', 'b']),
          reply('done'),
        ],
        tools: tools,
      );
      final run = h.run();
      await pumpEventQueue();
      expect(tools.log, ['start:a', 'start:b']);
      gateB.complete('B');
      gateA.complete('A');
      final result = await run;
      expect(result.toolResults.map((r) => r.content), ['A', 'B']);
    },
  );

  group('finish reason (batch 2 plan §3.8)', () {
    Future<List<KernelEvent>> runWith(FinishReason? reason) async {
      final h = Harness(
        steps: [
          callTools(['a']).copyWith(finishReason: reason),
          reply('done'),
        ],
      );
      final result = await h.run();
      expect(result.toolResults, hasLength(1));
      expect(h.tools.log.isEmpty, reason == FinishReason.length);
      expect(result.toolResults.single.isError, reason == FinishReason.length);
      return h.events;
    }

    for (final reason in [FinishReason.stop, FinishReason.length]) {
      test(
        '$reason with tool calls is reported before the calls run',
        () async {
          final events = await runWith(reason);
          final index = events.indexWhere((e) => e is FinishReasonMismatch);
          expect(index, isNonNegative);
          final mismatch = events[index] as FinishReasonMismatch;
          expect(mismatch.finishReason, reason);
          expect(mismatch.toolCalls, 1);
          expect(events[index + 1], isA<ToolCallsDetected>());
        },
      );
    }

    for (final reason in [FinishReason.toolCalls, FinishReason.unknown, null]) {
      test('$reason with tool calls is not reported', () async {
        expect(
          (await runWith(reason)).whereType<FinishReasonMismatch>(),
          isEmpty,
        );
      });
    }

    test('stop without tool calls is not reported', () async {
      final h = Harness(
        steps: [reply('hello').copyWith(finishReason: FinishReason.stop)],
      );
      await h.run();
      expect(h.events.whereType<FinishReasonMismatch>(), isEmpty);
    });
  });

  test('has no round cap: runs until the model stops calling tools', () async {
    final h = Harness(
      steps: [
        for (var i = 0; i < 32; i++) callTools(['a']),
        reply('done'),
      ],
    );
    final result = await h.run();

    expect(result.status, LoopStatus.completed);
    expect(result.lastTurn!.text, 'done');
    expect(h.model.requests, hasLength(33));
    expect(h.encoder.calls, 33);
  });

  test('post-tool stop records the final batch before ending', () async {
    final h = Harness(
      steps: [
        callTools(['draw_image']),
      ],
      post: FakePost(const TurnVerdict.stop(KernelStopReason.policy)),
    );
    final result = await h.run();

    expect(result.status, LoopStatus.stopped);
    expect(result.stopReason, KernelStopReason.policy);
    expect(h.encoder.calls, 1);
  });

  group('overflow recovery', () {
    test('recovers once via recovery mode without re-running tools', () async {
      final h = Harness(
        steps: [
          callTools(['a']),
          const KernelContextOverflow('too long'),
          reply('done'),
        ],
      );
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
      final h = Harness(
        steps: [
          const KernelContextOverflow('1'),
          const KernelContextOverflow('2'),
        ],
      );
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

    test(
      'other errors are rethrown unchanged with the failing stage',
      () async {
        final h = Harness(steps: [StateError('boom')]);
        await expectLater(h.run(), throwsA(isA<StateError>()));
        final failed = h.events.whereType<RunFailed>().single;
        expect(failed.stage, 'modelPort');
        expect(h.preparer.modes, [PrepareMode.initial]);
      },
    );
  });

  group('cancellation', () {
    test('before the request: model is never called', () async {
      final cancel = KernelCancellation()..cancel();
      final h = Harness(steps: [reply('x')]);
      final result = await h.run(cancellation: cancel);
      expect(result.status, LoopStatus.cancelled);
      expect(h.model.requests, isEmpty);
    });

    test(
      'during the request: no overflow recovery, result cancelled',
      () async {
        final cancel = KernelCancellation();
        final h = Harness(
          steps: [
            (TurnContext ctx) async {
              await ctx.cancellation.whenCancelled;
              throw const KernelContextOverflow('aborted request');
            },
          ],
        );
        final run = h.run(cancellation: cancel);
        await pumpEventQueue();
        cancel.cancel();
        final result = await run;
        expect(result.status, LoopStatus.cancelled);
        expect(h.preparer.modes, [PrepareMode.initial]);
        expect(h.events.whereType<RunFailed>(), isEmpty);
      },
    );

    test('a response arriving after cancellation is discarded', () async {
      final cancel = KernelCancellation();
      final gate = Completer<void>();
      final h = Harness(
        steps: [
          blockedOn(gate, callTools(['a'])),
        ],
      );
      final run = h.run(cancellation: cancel);
      await pumpEventQueue();
      cancel.cancel();
      gate.complete();
      final result = await run;
      expect(result.status, LoopStatus.cancelled);
      expect(h.tools.log, isEmpty);
    });

    test('during a tool: settled result recorded, no next round', () async {
      final cancel = KernelCancellation();
      final toolGate = Completer<String>();
      final tools = FakeTools(handlers: {'a': () => toolGate.future});
      final h = Harness(
        steps: [
          callTools(['a']),
          reply('never'),
        ],
        tools: tools,
      );
      final run = h.run(cancellation: cancel);
      await pumpEventQueue();
      cancel.cancel();
      toolGate.complete('late');
      final result = await run;
      expect(result.status, LoopStatus.cancelled);
      expect(result.toolResults, hasLength(1));
      expect(h.encoder.calls, 1);
      expect(h.model.requests, hasLength(1));
    });

    test(
      'during the tool-detection observer: a parallel batch never starts',
      () async {
        final cancel = KernelCancellation();
        final h = Harness(
          steps: [
            callTools(['a', 'b']),
            reply('never'),
          ],
          tools: FakeTools(mode: BatchMode.parallel),
          onEvent: (e) {
            if (e is ToolCallsDetected) cancel.cancel();
          },
        );
        final result = await h.run(cancellation: cancel);
        expect(result.status, LoopStatus.cancelled);
        expect(h.tools.log, isEmpty);
        expect(h.events.whereType<ToolBatchFinished>(), isEmpty);
      },
    );

    test(
      'during an async unpack: a final reply is not reported as completed',
      () async {
        final cancel = KernelCancellation();
        final h = Harness(
          steps: [reply('done')],
          unpacker: HookUnpacker((_) => cancel.cancel()),
        );
        final result = await h.run(cancellation: cancel);
        expect(result.status, LoopStatus.cancelled);
        expect(h.events.whereType<RoundCompleted>(), isEmpty);
      },
    );

    test(
      'during the final no-tool round observer: cancelled, not completed',
      () async {
        final cancel = KernelCancellation();
        final h = Harness(
          steps: [reply('done')],
          onEvent: (e) {
            if (e is RoundCompleted) cancel.cancel();
          },
        );
        final result = await h.run(cancellation: cancel);
        expect(result.status, LoopStatus.cancelled);
      },
    );

    test('during a post-tool stop: cancelled, not stopped', () async {
      final cancel = KernelCancellation();
      final h = Harness(
        steps: [
          callTools(['a']),
        ],
        post: FakePost(const TurnVerdict.stop(KernelStopReason.policy)),
        onEvent: (e) {
          if (e is RoundCompleted) cancel.cancel();
        },
      );
      final result = await h.run(cancellation: cancel);
      expect(result.status, LoopStatus.cancelled);
      expect(h.encoder.calls, 1);
    });

    group('no stage starts after cancellation', () {
      test('round-start observer: preparer never runs', () async {
        final cancel = KernelCancellation();
        final h = Harness(
          steps: [reply('x')],
          onEvent: (e) {
            if (e is RoundStarted) cancel.cancel();
          },
        );
        expect(
          (await h.run(cancellation: cancel)).status,
          LoopStatus.cancelled,
        );
        expect(h.preparer.modes, isEmpty);
        expect(h.model.requests, isEmpty);
      });

      test('an observer cancelling stops later observers of the same event, '
          'but the run end still reaches everyone', () async {
        final cancel = KernelCancellation();
        final second = <Type>[];
        final h = Harness(steps: [reply('x')]);
        final loop = AgentLoop(
          stages: StagePipeline(
            preparer: h.preparer,
            model: h.model,
            tools: h.tools,
            encoder: h.encoder,
          ),
          observers: [
            (e) async {
              if (e is RoundStarted) cancel.cancel();
            },
            (e) async => second.add(e.runtimeType),
          ],
        );
        final result = await loop.run(const [], cancellation: cancel);
        expect(result.status, LoopStatus.cancelled);
        expect(second, [RunFinished]);
      });

      test('overflow recovery: no recovery event after cancellation', () async {
        final cancel = KernelCancellation();
        final h = Harness(
          steps: [const KernelContextOverflow('too long'), reply('never')],
        );
        h.preparer.onRecovery = cancel.cancel;
        final result = await h.run(cancellation: cancel);
        expect(result.status, LoopStatus.cancelled);
        expect(h.events.whereType<OverflowRecovered>(), isEmpty);
        expect(h.model.requests, hasLength(1));
      });

      test('unpack: pre-tool never runs', () async {
        final cancel = KernelCancellation();
        final h = Harness(
          steps: [
            callTools(['a']),
          ],
          unpacker: HookUnpacker((_) => cancel.cancel()),
        );
        expect(
          (await h.run(cancellation: cancel)).status,
          LoopStatus.cancelled,
        );
        expect(h.preTool.calls, 0);
      });

      test('tool-batch observer: post-tool never runs', () async {
        final cancel = KernelCancellation();
        final h = Harness(
          steps: [
            callTools(['a']),
          ],
          onEvent: (e) {
            if (e is ToolBatchFinished) cancel.cancel();
          },
        );
        expect(
          (await h.run(cancellation: cancel)).status,
          LoopStatus.cancelled,
        );
        expect(h.post.calls, 0);
      });

      test('post-tool: the round is not reported complete', () async {
        final cancel = KernelCancellation();
        final h = Harness(
          steps: [
            callTools(['a']),
            reply('never'),
          ],
          post: FakePost(const TurnVerdict.proceed(), cancel.cancel),
        );
        expect(
          (await h.run(cancellation: cancel)).status,
          LoopStatus.cancelled,
        );
        expect(h.events.whereType<RoundCompleted>(), isEmpty);
        expect(h.encoder.calls, 1);
      });

      test('encoder: completed records survive cancellation', () async {
        final cancel = KernelCancellation();
        final h = Harness(
          steps: [
            callTools(['a']),
            reply('never'),
          ],
          onEncode: cancel.cancel,
        );
        final result = await h.run(cancellation: cancel);
        expect(result.status, LoopStatus.cancelled);
        expect(result.runningMessages, hasLength(3));
        expect(h.model.requests, hasLength(1));
      });
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

  test(
    'steering is injected in order at the next round, rejected after end',
    () async {
      late Harness h;
      h = Harness(
        steps: [
          (TurnContext ctx) async {
            h.loop.steer('first');
            h.loop.steer('second');
            return callTools(['a']);
          },
          reply('done'),
        ],
      );
      await h.run();

      final second = h.model.requests[1];
      expect(second.skip(second.length - 2).map((m) => m['content']), [
        'first',
        'second',
      ]);
      expect(second.where((m) => m['content'] == 'first'), hasLength(1));
      expect(h.loop.steer('late'), isFalse);
    },
  );

  test('a loop instance runs once', () async {
    final h = Harness(steps: [reply('x')]);
    await h.run();
    expect(h.run, throwsStateError);
  });

  test(
    'steering during a final response creates another model round',
    () async {
      late Harness h;
      h = Harness(
        steps: [
          (TurnContext ctx) async {
            h.loop.steer('new requirement');
            return reply('old answer');
          },
          reply('updated answer'),
        ],
      );
      final result = await h.run();
      expect(result.status, LoopStatus.completed);
      expect(result.lastTurn!.text, 'updated answer');
      expect(h.model.requests.last.last['content'], 'new requirement');
    },
  );

  test('steering after a final reply always gets another round', () async {
    late Harness h;
    h = Harness(
      steps: [
        (TurnContext ctx) async {
          h.loop.steer('remaining work');
          return reply('old answer');
        },
        reply('remaining work done'),
      ],
    );
    final result = await h.run();
    expect(result.status, LoopStatus.completed);
    expect(result.lastTurn!.text, 'remaining work done');
  });

  test(
    'cancellation binding rejects a pending port without waiting for it',
    () async {
      final signal = KernelCancellation();
      final pending = Completer<void>();
      final check = expectLater(
        signal.bind(pending.future),
        throwsA(isA<KernelCancelledException>()),
      );
      signal.cancel();
      await check;
      pending.completeError(StateError('late failure stays observed'));
      await pumpEventQueue();
    },
  );
}
