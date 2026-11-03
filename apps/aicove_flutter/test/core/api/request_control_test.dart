import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/media_request_retry.dart';
import 'package:aicove_flutter/src/core/api/request_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _HangingClient extends http.BaseClient {
  final _response = Completer<http.StreamedResponse>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger.then((_) {
          if (!_response.isCompleted) {
            _response.completeError(http.RequestAbortedException(request.url));
          }
        }),
      );
    }
    return _response.future;
  }
}

/// Observes the outcome at once: an abort may land before the test looks.
Future<Object> _startSpeech() {
  final client = _HangingClient();
  return sendMediaRequestWithRetry(
    send: () => client.send(
      RequestControl.request('POST', Uri.parse('https://local.test')),
    ),
    policy: MediaRetryPolicy.tts,
    remaining: () => const Duration(seconds: 30),
  ).then<Object>((response) => response).catchError((Object error) => error);
}

Future<Object> _settledWithin200Ms(Future<Object> speech) =>
    speech.timeout(const Duration(milliseconds: 200), onTimeout: () => 'running');

void main() {
  test('speech started by a stream outlives the completed attempt until stop', () async {
    final turn = KernelCancellation();
    late Future<Object> speech;

    await retryModelRound<void>(
      cancellation: turn,
      send: () async {
        speech = _startSpeech();
      },
    );

    expect(await _settledWithin200Ms(speech), 'running');
    turn.cancel();
    expect(await _settledWithin200Ms(speech), isA<KernelCancelledException>());
  });

  test('speech from an abandoned attempt is aborted before the retry', () async {
    final speeches = <Future<Object>>[];

    await retryModelRound<void>(
      cancellation: KernelCancellation(),
      wait: (_) async {},
      send: () async {
        speeches.add(_startSpeech());
        if (speeches.length == 1) throw const SocketException('lost');
      },
    );

    expect(
      await _settledWithin200Ms(speeches.first),
      isA<KernelCancelledException>(),
    );
    expect(await _settledWithin200Ms(speeches.last), 'running');
  });

  test('timeout retries only once by default and aborts each attempt', () async {
    final signals = <KernelCancellation>[];
    final retries = <int>[];
    final limits = <int>[];
    await expectLater(
      retryModelRound<void>(
        cancellation: KernelCancellation(),
        attemptTimeout: const Duration(milliseconds: 1),
        wait: (_) async {},
        onRetry: (attempt, _) => retries.add(attempt),
        onRetryWithLimit: (_, limit, _) => limits.add(limit),
        send: () {
          if (signals.isNotEmpty) expect(signals.last.isCancelled, isTrue);
          signals.add(RequestControl.cancellation!);
          return Completer<void>().future;
        },
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(signals, hasLength(2));
    expect(signals.every((signal) => signal.isCancelled), isTrue);
    expect(retries, [1]);
    expect(limits, [1]);
  });

  test('HTTP 429 retains three retries and Retry-After', () async {
    var requests = 0;
    final retries = <int>[];
    final limits = <int>[];
    final delays = <Duration>[];
    await expectLater(
      retryModelRound<void>(
        cancellation: KernelCancellation(),
        wait: (delay) async => delays.add(delay),
        onRetry: (attempt, _) => retries.add(attempt),
        onRetryWithLimit: (_, limit, _) => limits.add(limit),
        send: () async {
          requests++;
          throw const ModelHttpException(
            429,
            'rate limited',
            retryAfter: Duration(seconds: 3),
          );
        },
      ),
      throwsA(isA<ModelHttpException>()),
    );
    expect(requests, 4);
    expect(retries, [1, 2, 3]);
    expect(limits, [3, 3, 3]);
    expect(delays, List.filled(3, const Duration(seconds: 3)));
  });

  test('timeout retry cap respects a disabled or larger caller budget', () async {
    for (final budget in [0, 8]) {
      var requests = 0;
      final limits = <int>[];
      await expectLater(
        retryModelRound<void>(
          cancellation: KernelCancellation(),
          maxRetries: budget,
          wait: (_) async {},
          onRetryWithLimit: (_, limit, _) => limits.add(limit),
          send: () async {
            requests++;
            throw TimeoutException('request timed out');
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(requests, budget == 0 ? 1 : 2);
      expect(limits, budget == 0 ? isEmpty : [1]);
    }
  });
}
