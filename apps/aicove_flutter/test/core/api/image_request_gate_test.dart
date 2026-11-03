import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/image_request_gate.dart';
import 'package:flutter_test/flutter_test.dart';

// Observe the gate itself, not RequestControl.run's early cancellation wrapper.
Future<T> controlled<T>(KernelCancellation signal, Future<T> Function() body) =>
    runZoned(body, zoneValues: {#aicoveRequestCancellation: signal});

Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  for (final limit in [1, 2]) {
    test('limit $limit bounds six tasks and preserves FIFO', () async {
      final gate = ImageRequestGate();
      final release = List.generate(6, (_) => Completer<void>());
      final entered = <int>[];
      var active = 0;
      var peak = 0;
      final tasks = [
        for (var i = 0; i < 6; i++)
          gate.run('channel', limit, () async {
            active++;
            if (active > peak) peak = active;
            entered.add(i);
            await release[i].future;
            active--;
          }),
      ];
      await flush();
      expect(entered, List.generate(limit, (i) => i));
      for (var i = 0; i < 6; i++) {
        expect(entered, List.generate((i + limit).clamp(0, 6), (i) => i));
        release[i].complete();
        await flush();
        expect(active, lessThanOrEqualTo(limit));
      }
      await Future.wait(tasks);
      expect(peak, limit);
      expect(gate.laneCount, 0);
    });
  }

  test('different keys do not block one another', () async {
    final gate = ImageRequestGate();
    final release = Completer<void>();
    final first = gate.run('a', 1, () => release.future);
    expect(await gate.run('b', 1, () async => 'independent'), 'independent');
    release.complete();
    await first;
    expect(gate.laneCount, 0);
  });

  test('already cancelled call creates no lane and never runs body', () async {
    final gate = ImageRequestGate();
    final signal = KernelCancellation()..cancel();
    var ran = false;
    await expectLater(
      controlled(signal, () => gate.run('a', 1, () async => ran = true)),
      throwsA(isA<KernelCancelledException>()),
    );
    expect(ran, false);
    expect(gate.laneCount, 0);
  });

  test(
    'queued cancellation exits immediately and successor still runs',
    () async {
      final gate = ImageRequestGate();
      final release = Completer<void>();
      final first = gate.run('a', 1, () => release.future);
      final signal = KernelCancellation();
      var ran = false;
      final second = controlled(
        signal,
        () => gate.run('a', 1, () async => ran = true),
      );
      final rejected = expectLater(
        second,
        throwsA(isA<KernelCancelledException>()),
      );
      final next = gate.run('a', 1, () async => 'next');
      signal.cancel();
      await rejected;
      expect(release.isCompleted, false);
      expect(ran, false);
      release.complete();
      await first;
      expect(await next, 'next');
      expect(gate.laneCount, 0);
    },
  );

  for (final cancelFirst in [true, false]) {
    test(
      '${cancelFirst ? 'cancel before handoff' : 'handoff before cancel'} releases exactly once',
      () async {
        final gate = ImageRequestGate();
        final signal = KernelCancellation();
        final entered = Completer<void>();
        final release = Completer<void>();
        final first = gate.run('a', 1, () async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        var ran = false;
        final second = controlled(
          signal,
          () => gate.run('a', 1, () async => ran = true),
        );
        final rejected = expectLater(
          second,
          throwsA(isA<KernelCancelledException>()),
        );
        final successorEntered = Completer<void>();
        final releaseSuccessor = Completer<void>();
        final successor = gate.run('a', 1, () async {
          successorEntered.complete();
          await releaseSuccessor.future;
        });
        var tailRan = false;
        final tail = gate.run('a', 1, () async => tailRan = true);
        if (cancelFirst) signal.cancel();
        release.complete();
        await first;
        // The first run has synchronously transferred its slot before finishing.
        // The waiter's cancellation-bound future has not resumed its body yet.
        if (!cancelFirst) signal.cancel();
        await rejected;
        expect(ran, false);
        await successorEntered.future;
        await flush();
        expect(tailRan, false);
        releaseSuccessor.complete();
        await successor;
        await tail;
        expect(await gate.run('a', 1, () async => 'rebuilt'), 'rebuilt');
        expect(gate.laneCount, 0);
      },
    );
  }

  test(
    'cancellation after direct grant but before body releases once',
    () async {
      final gate = ImageRequestGate();
      final signal = KernelCancellation();
      var ran = false;
      final pending = controlled(
        signal,
        () => gate.run('a', 1, () async => ran = true),
      );
      final rejected = expectLater(
        pending,
        throwsA(isA<KernelCancelledException>()),
      );
      signal.cancel();
      await rejected;
      expect(ran, false);
      expect(gate.laneCount, 0);
      expect(await gate.run('a', 1, () async => 1), 1);
    },
  );

  test('running cancellation retains slot until body actually exits', () async {
    final gate = ImageRequestGate();
    final signal = KernelCancellation();
    final entered = Completer<void>();
    final release = Completer<void>();
    final first = controlled(
      signal,
      () => gate.run('a', 1, () async {
        entered.complete();
        await release.future;
      }),
    );
    await entered.future;
    var nextRan = false;
    final next = gate.run('a', 1, () async => nextRan = true);
    signal.cancel();
    await flush();
    expect(nextRan, false);
    expect(gate.laneCount, 1);
    release.complete();
    await first;
    await next;
    expect(nextRan, true);
    expect(gate.laneCount, 0);
  });

  test(
    'synchronous body throw admits successor and removes idle lane',
    () async {
      final gate = ImageRequestGate();
      final first = gate.run<void>('a', 1, () => throw StateError('sync body'));
      final rejected = expectLater(first, throwsStateError);
      var successorRan = false;
      final successor = gate.run('a', 1, () async => successorRan = true);
      await rejected;
      await successor;
      expect(successorRan, true);
      expect(gate.laneCount, 0);
    },
  );

  test('body error releases slot and idle lane can be rebuilt', () async {
    final gate = ImageRequestGate();
    await expectLater(
      gate.run('a', 1, () async => throw StateError('body')),
      throwsStateError,
    );
    expect(gate.laneCount, 0);
    expect(await gate.run('a', 1, () async => 'new lane'), 'new lane');
    expect(gate.laneCount, 0);
  });
}
