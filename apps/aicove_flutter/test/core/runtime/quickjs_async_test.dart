import 'dart:async';
import 'package:aicove_quickjs/aicove_quickjs.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 400 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  test(
    'async jobs suspend and resume host I/O without changing preset session',
    () async {
      final session = QuickJsAsyncSession();
      final texts = <String>[];
      final result = await session.run(
        'const x = await __aq_host("read", [7]); __aq_text("seen"); return x + 1;',
        onText: texts.add,
        hostCall: (method, args, active) async {
          expect(method, 'read');
          expect(args, [7]);
          expect(active(), isTrue);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 41;
        },
      );
      expect(result, '42');
      expect(texts, ['seen']);
      await expectLater(
        session.run('return 1;', hostCall: (_, _, _) async => null),
        throwsA(isA<QuickJsException>()),
      );
      final old = await QuickJsSession.open();
      try {
        expect(await old.evaluate('1+1'), '2');
      } finally {
        await old.close();
      }
    },
  );
  for (final seconds in [119, 120, 121]) {
    test('script deadline configuration boundary $seconds', () async {
      final future = QuickJsAsyncSession().run(
        'return "ok";',
        timeout: Duration(seconds: seconds),
        hostCall: (_, _, _) async => null,
      );
      expect(await future, 'ok');
    });
  }
  for (final bytes in [
    64 * 1024 * 1024 - 1,
    64 * 1024 * 1024,
    64 * 1024 * 1024 + 1,
  ]) {
    test('heap configuration boundary $bytes', () async {
      final future = QuickJsAsyncSession().run(
        'return "ok";',
        heapBytes: bytes,
        hostCall: (_, _, _) async => null,
      );
      if (bytes <= QuickJsAsyncSession.maxHeapBytes) {
        expect(await future, 'ok');
      } else {
        await expectLater(future, throwsA(isA<QuickJsException>()));
      }
    });
  }
  test('native allocation obeys the actual heap limit', () async {
    await expectLater(
      QuickJsAsyncSession().run(
        'return new ArrayBuffer(65*1024*1024);',
        hostCall: (_, _, _) async => null,
      ),
      throwsA(isA<QuickJsException>()),
    );
  });
  for (final body in [
    'while(true) {}',
    'await new Promise(() => {});',
    'while(true) { await Promise.resolve(); }',
  ]) {
    test(
      'deadline interrupts native execution and pending jobs: $body',
      () async {
        final sw = Stopwatch()..start();
        await expectLater(
          QuickJsAsyncSession().run(
            body,
            timeout: const Duration(milliseconds: 100),
            hostCall: (_, _, _) async => null,
          ),
          throwsA(anyOf(isA<TimeoutException>(), isA<QuickJsException>())),
        );
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      },
    );
  }
  test('parent cancellation interrupts tight native loop', () async {
    var cancelled = false;
    final timer = Timer(
      const Duration(milliseconds: 100),
      () => cancelled = true,
    );
    try {
      await expectLater(
        QuickJsAsyncSession().run(
          'while(true) {}',
          isCancelled: () => cancelled,
          hostCall: (_, _, _) async => null,
        ),
        throwsA(isA<QuickJsException>()),
      );
    } finally {
      timer.cancel();
    }
  });
  for (final count in [3, 4, 5]) {
    test('host concurrency boundary $count queues above four', () async {
      final release = Completer<void>();
      var running = 0, peak = 0, started = 0;
      final future = QuickJsAsyncSession().run(
        'return JSON.stringify(await Promise.all(Array.from({length:$count}, (_,i)=>__aq_host("work",[i]))));',
        hostCall: (_, args, active) async {
          started++;
          running++;
          if (running > peak) peak = running;
          await release.future;
          running--;
          return args.single;
        },
      );
      await _until(() => started == count.clamp(0, 4));
      expect(peak, count.clamp(0, 4));
      release.complete();
      expect(await future, '[${List.generate(count, (i) => i).join(',')}]');
    });
  }
  for (final cancelled in [false, true]) {
    test(
      'timeout/cancel drains in-flight work, drops queued calls and late replies ($cancelled)',
      () async {
        final gate = Completer<void>();
        var started = 0, committed = 0, cancel = false;
        final session = QuickJsAsyncSession();
        final result = session.run(
          'for(let i=0;i<5;i++) __aq_host("write",[]); await new Promise(()=>{});',
          timeout: const Duration(milliseconds: 200),
          isCancelled: () => cancel,
          hostCall: (_, _, active) async {
            started++;
            await gate.future;
            if (active()) committed++;
            return null;
          },
        );
        final assertion = expectLater(
          result,
          throwsA(anyOf(isA<TimeoutException>(), isA<QuickJsException>())),
        );
        await _until(() => started == 4);
        if (cancelled) cancel = true;
        await _until(() => !session.isActive);
        gate.complete();
        await assertion;
        expect(committed, 0);
        expect(started, 4);
      },
    );
  }

  for (final milliseconds in [4999, 5000, 5001]) {
    testWidgets('host convergence deterministic boundary $milliseconds ms', (
      tester,
    ) async {
      final gate = Completer<void>();
      var completed = false, timedOut = false;
      Object? failure;
      // Register completion first, so an exactly-on-deadline reply wins ties.
      final timer = Timer(Duration(milliseconds: milliseconds), gate.complete);
      unawaited(
        QuickJsAsyncSession.converge([gate.future]).then(
          (_) {
            completed = true;
          },
          onError: (Object error) {
            failure = error;
            timedOut = true;
          },
        ),
      );
      await tester.pump(const Duration(milliseconds: 5000));
      expect(completed, milliseconds <= 5000);
      expect(timedOut, milliseconds > 5000);
      if (timedOut) expect(failure, isA<TimeoutException>());
      timer.cancel();
      if (!gate.isCompleted) gate.complete();
      await tester.pump();
    });
  }
  test(
    'non-settling host forces session closed after the single five-second grace',
    () async {
      final gate = Completer<void>();
      final stopwatch = Stopwatch()..start();
      final session = QuickJsAsyncSession();
      Object? failure;
      try {
        await session.run(
          'await __aq_host("stall",[]);',
          timeout: const Duration(milliseconds: 100),
          hostCall: (_, _, active) async {
            await gate.future;
            expect(active(), isFalse);
            return null;
          },
        );
      } catch (error) {
        failure = error;
      }
      expect(failure.toString(), contains('forcibly closed'));
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(seconds: 5)),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 7)));
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.isActive, isFalse);
    },
  );
}
