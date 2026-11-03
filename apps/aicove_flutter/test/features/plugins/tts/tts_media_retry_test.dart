import 'dart:async';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

TtsService _service() =>
    TtsService(config: TtsConfig(), requestUrl: 'https://tts.example/v1');

void main() {
  test('HTTP TTS retries 502 once and returns audio', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      return attempts == 1
          ? http.Response('unavailable', 502)
          : http.Response.bytes(
              [1, 2, 3],
              200,
              headers: {'content-type': 'audio/mpeg'},
            );
    });
    final result = await http.runWithClient(
      () => _service().convert('hello'),
      () => client,
    );
    expect(result.success, isTrue);
    expect(result.audioUrl, endsWith('base64,AQID'));
    expect(attempts, 2);
  });

  test('HTTP TTS timeout sends only once', () async {
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      throw TimeoutException('transport timed out');
    });
    await expectLater(
      http.runWithClient(() => _service().convert('hello'), () => client),
      throwsA(isA<TtsException>()),
    );
    expect(attempts, 1);
  });

  test(
    'HTTP TTS second hanging request shares the original timeout deadline',
    () async {
      const timeout = Duration(seconds: 30); // openai_tts convert timeout
      final watch = Stopwatch()..start();
      final budgets = <Duration>[];
      final deadlines = <Duration>[];
      var attempts = 0;
      final client = MockClient((request) async {
        if (++attempts == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return http.Response('unavailable', 502);
        }
        return Completer<http.Response>().future;
      });
      final pending = runZoned(
        () =>
            http.runWithClient(() => _service().convert('hello'), () => client),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (duration > const Duration(seconds: 1)) {
              budgets.add(duration);
              deadlines.add(watch.elapsed + duration);
              // Inspect the real allocated deadline, but fire the second timeout
              // early so this regression test does not wait 30 seconds.
              if (budgets.length == 2) {
                return parent.createTimer(
                  zone,
                  const Duration(milliseconds: 1),
                  callback,
                );
              }
            }
            return parent.createTimer(
              zone,
              duration == const Duration(milliseconds: 500)
                  ? Duration.zero
                  : duration,
              callback,
            );
          },
        ),
      );
      await expectLater(
        pending,
        throwsA(
          isA<TtsException>().having(
            (e) => e.message,
            'message',
            'TTS 请求超时，请稍后重试',
          ),
        ),
      );
      expect(attempts, 2);
      expect(budgets, hasLength(2));
      expect(budgets.first, lessThanOrEqualTo(timeout));
      expect(
        budgets.last,
        lessThan(timeout - const Duration(milliseconds: 20)),
      );
      expect(
        deadlines.last,
        lessThanOrEqualTo(deadlines.first + const Duration(milliseconds: 5)),
      );
      expect(watch.elapsed, lessThanOrEqualTo(timeout));
    },
  );

  test('HTTP TTS convert preserves cancellation exception', () async {
    final signal = KernelCancellation();
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      signal.cancel();
      throw const KernelCancelledException();
    });
    await expectLater(
      http.runWithClient(
        () => runZoned(
          () => _service().convert('hello'),
          zoneValues: {#aicoveRequestCancellation: signal},
        ),
        () => client,
      ),
      throwsA(isA<KernelCancelledException>()),
    );
    expect(attempts, 1);
  });

  test('HTTP TTS cancellation propagates and batch stops', () async {
    final signal = KernelCancellation();
    var attempts = 0;
    final client = MockClient((request) async {
      attempts++;
      signal.cancel();
      throw const KernelCancelledException();
    });
    // A Zone exposes cancellation without RequestControl.run's outer bind,
    // so this specifically checks convertBatch's propagation contract.
    await expectLater(
      http.runWithClient(
        () => runZoned(
          () => _service().convertBatch(['first', 'second']),
          zoneValues: {#aicoveRequestCancellation: signal},
        ),
        () => client,
      ),
      throwsA(isA<KernelCancelledException>()),
    );
    expect(attempts, 1);
  });
}
