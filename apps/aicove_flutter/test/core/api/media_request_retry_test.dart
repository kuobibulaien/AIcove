import 'dart:async';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/core/api/media_request_retry.dart';
import 'package:aicove_flutter/src/core/api/request_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'media_retry_test_client.dart';

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

void main() {
  Future<void> noWait(Duration _) async {}

  Future<http.Response> run(
    http.Client client,
    MediaRetryPolicy policy, {
    Duration Function()? remaining,
    Future<void> Function(Duration)? wait,
  }) => sendMediaRequestWithRetry(
    send: () => client.send(
      RequestControl.request('POST', Uri.parse('https://local.test')),
    ),
    policy: policy,
    remaining: remaining ?? () => const Duration(seconds: 30),
    wait: wait ?? noWait,
  );

  for (final first in <Object>[502, TimeoutException('first')]) {
    test('readOnly retries $first once then succeeds without a Zone', () async {
      var calls = 0;
      final client = NoRedirectMockClient((_) async {
        if (++calls == 1) {
          if (first is int) return http.Response('first', first);
          throw first;
        }
        return http.Response('ok', 200);
      });
      expect((await run(client, MediaRetryPolicy.readOnly)).body, 'ok');
      expect(calls, 2);
    });
  }

  for (final policy in MediaRetryPolicy.values) {
    test('$policy retries only its allowed HTTP statuses', () async {
      final allowed = switch (policy) {
        MediaRetryPolicy.readOnly => {408, 429, 500, 502, 503, 504},
        MediaRetryPolicy.submission => {429},
        MediaRetryPolicy.tts => {429, 500, 502, 503, 504},
      };
      for (final status in [400, 401, 403, 408, 429, 500, 501, 502, 503, 504]) {
        var calls = 0;
        final client = NoRedirectMockClient(
          (_) async => http.Response('', ++calls == 1 ? status : 200),
        );
        final response = await run(client, policy);
        expect(calls, allowed.contains(status) ? 2 : 1, reason: 'HTTP $status');
        expect(response.statusCode, allowed.contains(status) ? 200 : status);
      }
    });
  }

  for (final policy in [MediaRetryPolicy.readOnly, MediaRetryPolicy.tts]) {
    test('$policy retries only its allowed transport errors', () async {
      for (final error in <Object>[
        const SocketException('offline'),
        const HttpException('broken response'),
        http.ClientException('broken transport'),
        const HandshakeException('tls'),
        TimeoutException('slow'),
        http.RequestAbortedException(),
        const FormatException('decode'),
        const KernelCancelledException(),
      ]) {
        var calls = 0;
        final client = NoRedirectMockClient((_) async {
          if (++calls == 1) throw error;
          return http.Response('ok', 200);
        });
        final retry =
            error is SocketException ||
            error is HttpException ||
            (error is http.ClientException &&
                error is! http.RequestAbortedException) ||
            (policy == MediaRetryPolicy.readOnly &&
                (error is TimeoutException || error is HandshakeException));
        if (retry) {
          expect((await run(client, policy)).statusCode, 200);
        } else {
          await expectLater(run(client, policy), throwsA(same(error)));
        }
        expect(calls, retry ? 2 : 1, reason: error.runtimeType.toString());
      }
    });
  }

  test('send and complete body use one timeout budget', () async {
    final body = StreamController<List<int>>();
    addTearDown(body.close);
    var calls = 0;
    final client = _StreamingClient((_) async {
      calls++;
      return http.StreamedResponse(body.stream, 429);
    });
    final watch = Stopwatch()..start();
    await expectLater(
      run(
        client,
        MediaRetryPolicy.submission,
        remaining: () => const Duration(milliseconds: 50) - watch.elapsed,
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(
      calls,
      1,
      reason: 'partial 429 is not a complete rejection response',
    );
  });

  for (final transportFailure in [false, true]) {
    test(
      'expired backoff preserves last ${transportFailure ? 'transport error' : 'response'}',
      () async {
        var calls = 0;
        var budget = const Duration(seconds: 2);
        const error = SocketException('last');
        final client = NoRedirectMockClient((_) async {
          calls++;
          if (transportFailure) throw error;
          return http.Response('last', 502);
        });
        final pending = run(
          client,
          MediaRetryPolicy.readOnly,
          remaining: () => budget,
          wait: (_) async {
            budget = Duration.zero;
          },
        );
        if (transportFailure) {
          await expectLater(pending, throwsA(same(error)));
        } else {
          expect((await pending).body, 'last');
        }
        expect(calls, 1);
      },
    );
  }

  test('backoff uses max exponential and Retry-After', () async {
    var calls = 0;
    final delays = <Duration>[];
    final client = NoRedirectMockClient(
      (_) async => http.Response(
        '',
        ++calls <= 2 ? 429 : 200,
        headers: {'retry-after': calls == 1 ? '2' : '0'},
      ),
    );
    await run(
      client,
      MediaRetryPolicy.submission,
      wait: (d) async => delays.add(d),
    );
    expect(delays, [const Duration(seconds: 2), const Duration(seconds: 1)]);
  });

  test('submission retries complete 429 and creates a fresh Request', () async {
    final requests = <http.Request>[];
    final client = NoRedirectMockClient((request) async {
      requests.add(request);
      return http.Response(
        'body',
        requests.length == 1 ? 429 : 200,
        headers: {'retry-after': '0'},
      );
    });
    final delays = <Duration>[];
    expect(
      (await run(
        client,
        MediaRetryPolicy.submission,
        wait: (d) async => delays.add(d),
      )).statusCode,
      200,
    );
    expect(requests.length, 2);
    expect(identical(requests[0], requests[1]), isFalse);
    expect(delays, [const Duration(milliseconds: 500)]);
  });

  test('submission does not retry 429 when final URL is unavailable', () async {
    var calls = 0;
    final client = _StreamingClient((request) async {
      calls++;
      return http.StreamedResponse(
        Stream.value([98, 117, 115, 121]),
        429,
        request: request,
        headers: {'retry-after': '0'},
      );
    });
    final response = await run(
      client,
      MediaRetryPolicy.submission,
      wait: (_) async => fail('unknown final URL must not trigger backoff'),
    );
    expect(response.statusCode, 429);
    expect(response.body, 'busy');
    expect(calls, 1);
  });

  for (final first in <Object>[
    500,
    503,
    TimeoutException('timeout'),
    const SocketException('reset'),
    http.ClientException('reset'),
  ]) {
    test('submission never retries $first', () async {
      var calls = 0;
      final client = NoRedirectMockClient((_) async {
        calls++;
        if (first is int) return http.Response('original', first);
        throw first;
      });
      if (first is int) {
        expect(
          (await run(client, MediaRetryPolicy.submission)).statusCode,
          first,
        );
      } else {
        await expectLater(
          run(client, MediaRetryPolicy.submission),
          throwsA(same(first)),
        );
      }
      expect(calls, 1);
    });
  }

  for (final policy in MediaRetryPolicy.values) {
    test(
      '$policy returns final original response when retries exhaust',
      () async {
        var calls = 0;
        final client = NoRedirectMockClient(
          (_) async => http.Response(
            'original-${++calls}',
            429,
            headers: {'x-final': '$calls'},
          ),
        );
        final response = await run(client, policy);
        final expected = switch (policy) {
          MediaRetryPolicy.readOnly => 4,
          MediaRetryPolicy.submission => 3,
          MediaRetryPolicy.tts => 2,
        };
        expect(calls, expected);
        expect(response.body, 'original-$expected');
        expect(response.headers['x-final'], '$expected');
      },
    );
  }

  test(
    'final transport error retains identity and stack instead of earlier response',
    () async {
      const error = SocketException('last');
      final stack = StackTrace.fromString('original transport stack');
      var calls = 0;
      final client = NoRedirectMockClient((_) async {
        if (++calls == 1) return http.Response('earlier', 502);
        Error.throwWithStackTrace(error, stack);
      });
      try {
        await run(client, MediaRetryPolicy.readOnly);
        fail('expected transport failure');
      } catch (caught, caughtStack) {
        expect(caught, same(error));
        expect(caughtStack.toString(), contains('original transport stack'));
      }
      expect(calls, 4);
    },
  );

  test('Retry-After beyond budget returns 429 without waiting', () async {
    var calls = 0;
    final client = NoRedirectMockClient((_) async {
      calls++;
      return http.Response('original', 429, headers: {'retry-after': '60'});
    });
    final response = await run(
      client,
      MediaRetryPolicy.submission,
      remaining: () => const Duration(seconds: 1),
      wait: (_) async => fail('must not wait'),
    );
    expect(response.statusCode, 429);
    expect(calls, 1);
  });

  test('cancellation interrupts backoff and prevents another send', () async {
    final signal = KernelCancellation();
    final waiting = Completer<void>();
    var calls = 0;
    final client = NoRedirectMockClient((_) async {
      calls++;
      return http.Response('busy', 429);
    });
    late Future<http.Response> inner;
    final outer = expectLater(
      RequestControl.run(
        signal,
        () => inner = run(
          client,
          MediaRetryPolicy.submission,
          wait: (_) {
            waiting.complete();
            return Completer<void>().future;
          },
        ),
      ),
      throwsA(isA<KernelCancelledException>()),
    );
    final checked = expectLater(
      inner,
      throwsA(isA<KernelCancelledException>()),
    );
    await waiting.future;
    signal.cancel();
    await checked.timeout(const Duration(seconds: 1));
    await outer;
    expect(calls, 1);
  });

  for (final failure in <Object>[
    TimeoutException('slow'),
    const HandshakeException('certificate'),
    http.RequestAbortedException(),
  ]) {
    test('tts does not retry $failure', () async {
      var calls = 0;
      final client = NoRedirectMockClient((_) async {
        calls++;
        throw failure;
      });
      await expectLater(
        run(client, MediaRetryPolicy.tts),
        throwsA(same(failure)),
      );
      expect(calls, 1);
    });
  }

  for (final redirect in [false, true]) {
    test(
      'real IOClient submission is not replayed after ${redirect ? '303 target connection failure' : 'server disconnects after receiving POST'}',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final client = http.Client();
        addTearDown(() async {
          client.close();
          await server.close(force: true);
        });
        var posts = 0;
        final unavailable = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final unavailablePort = unavailable.port;
        await unavailable.close();
        server.listen((request) async {
          await request.drain<void>();
          posts++;
          if (redirect) {
            request.response.statusCode = 303;
            request.response.headers.set(
              'location',
              'http://127.0.0.1:$unavailablePort/target',
            );
            await request.response.close();
          } else {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.destroy();
          }
        });
        await expectLater(
          sendMediaRequestWithRetry(
            send: () => client.send(
              RequestControl.request(
                'POST',
                Uri.parse('http://127.0.0.1:${server.port}/submit'),
              ),
            ),
            policy: MediaRetryPolicy.submission,
            remaining: () => const Duration(seconds: 2),
            wait: noWait,
          ),
          throwsA(isA<http.ClientException>()),
        );
        expect(posts, 1);
      },
    );
  }

  test(
    'real IOClient submission never replays POST after 303 GET returns 429',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = http.Client();
      addTearDown(() async {
        client.close();
        await server.close(force: true);
      });
      var posts = 0;
      var gets = 0;
      server.listen((request) async {
        await request.drain<void>();
        if (request.uri.path == '/submit') {
          expect(request.method, 'POST');
          posts++;
          request.response.statusCode = 303;
          request.response.headers.set('location', '/result');
        } else {
          expect(request.uri.path, '/result');
          expect(request.method, 'GET');
          gets++;
          request.response.statusCode = 429;
          request.response.headers.set('x-result', 'original');
          request.response.write('result rate limited');
        }
        await request.response.close();
      });
      final response = await sendMediaRequestWithRetry(
        send: () => client.send(
          RequestControl.request(
            'POST',
            Uri.parse('http://127.0.0.1:${server.port}/submit'),
          ),
        ),
        policy: MediaRetryPolicy.submission,
        remaining: () => const Duration(seconds: 3),
        wait: noWait,
      );
      expect(response.statusCode, 429);
      expect(response.body, 'result rate limited');
      expect(response.headers['x-result'], 'original');
      expect(posts, 1);
      expect(gets, 1);
    },
  );

  test(
    'real IOClient retries a direct POST 429 then returns success',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = http.Client();
      addTearDown(() async {
        client.close();
        await server.close(force: true);
      });
      var posts = 0;
      server.listen((request) async {
        expect(request.method, 'POST');
        await request.drain<void>();
        request.response.statusCode = ++posts == 1 ? 429 : 200;
        request.response.write(posts == 1 ? 'busy' : 'ok');
        await request.response.close();
      });
      final response = await sendMediaRequestWithRetry(
        send: () => client.send(
          RequestControl.request(
            'POST',
            Uri.parse('http://127.0.0.1:${server.port}/submit'),
          ),
        ),
        policy: MediaRetryPolicy.submission,
        remaining: () => const Duration(seconds: 3),
        wait: noWait,
      );
      expect(response.statusCode, 200);
      expect(response.body, 'ok');
      expect(posts, 2);
    },
  );
}
