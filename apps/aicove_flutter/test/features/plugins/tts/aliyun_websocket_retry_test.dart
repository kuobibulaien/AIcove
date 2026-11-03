import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aicove_agent_kernel/aicove_agent_kernel.dart';
import 'package:aicove_flutter/src/features/plugins/tts/aliyun_qwen_tts_websocket.dart';
import 'package:flutter_test/flutter_test.dart';

class _Socket extends Stream<dynamic> implements WebSocket {
  final events = StreamController<dynamic>();
  final sent = <String>[];
  var closed = false;
  final bool failAfterConnect;
  _Socket({this.failAfterConnect = false});

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = events.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    scheduleMicrotask(
      () => events.add(
        jsonEncode(
          failAfterConnect
              ? {
                  'type': 'error',
                  'error': {'code': 'bad', 'message': 'failed'},
                }
              : {'type': 'session.created'},
        ),
      ),
    );
    return subscription;
  }

  @override
  void add(dynamic data) {
    final type = (jsonDecode(data as String) as Map)['type'] as String;
    sent.add(type);
    if (type == 'session.update') {
      events.add(jsonEncode({'type': 'session.updated'}));
    } else if (type == 'session.finish') {
      events.add(jsonEncode({'type': 'response.audio.delta', 'delta': 'AQID'}));
      events.add(jsonEncode({'type': 'session.finished'}));
    }
  }

  @override
  Future close([int? code, String? reason]) async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('WS TTS retries SocketException once then synthesizes', () async {
    var attempts = 0;
    final socket = _Socket();
    final service = AliyunQwenTtsWebSocket(
      apiKey: 'test',
      model: 'test',
      connect: (url, {headers}) async {
        attempts++;
        if (attempts == 1) throw const SocketException('reset');
        return socket;
      },
    );
    expect(await service.synthesize(text: 'hello', voiceId: 'voice'), [
      1,
      2,
      3,
    ]);
    expect(attempts, 2);
    expect(socket.closed, isTrue);
  });

  test(
    'WS TTS two connection attempts share the original 10-second deadline',
    () async {
      const timeout = Duration(seconds: 10);
      final watch = Stopwatch()..start();
      final budgets = <Duration>[];
      final deadlines = <Duration>[];
      final hanging = Completer<WebSocket>();
      var attempts = 0;
      final service = AliyunQwenTtsWebSocket(
        apiKey: 'test',
        model: 'test',
        connect: (url, {headers}) async {
          if (++attempts == 1) {
            await Future<void>.delayed(const Duration(milliseconds: 40));
            throw const SocketException('reset');
          }
          return hanging.future;
        },
      );
      final pending = runZoned(
        () => service.synthesize(text: 'hello', voiceId: 'voice'),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (duration > const Duration(seconds: 1)) {
              budgets.add(duration);
              deadlines.add(watch.elapsed + duration);
              // Keep the original timeout allocation for the assertion, while
              // firing the hanging attempt's timer early instead of waiting 10s.
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
      await expectLater(pending, throwsA(isA<TimeoutException>()));
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
      final lateSocket = _Socket();
      hanging.complete(lateSocket);
      await Future<void>.delayed(Duration.zero);
      expect(lateSocket.closed, isTrue);
      expect(lateSocket.sent, isEmpty);
    },
  );

  test(
    'WS TTS cancellation during backoff prevents another connection',
    () async {
      final signal = KernelCancellation();
      final waiting = Completer<void>();
      Timer? backoffTimer;
      late void Function() releaseBackoff;
      var attempts = 0;
      final service = AliyunQwenTtsWebSocket(
        apiKey: 'test',
        model: 'test',
        connect: (url, {headers}) async {
          attempts++;
          throw const SocketException('reset');
        },
      );
      final pending = runZoned(
        () => service.synthesize(text: 'hello', voiceId: 'voice'),
        zoneValues: {#aicoveRequestCancellation: signal},
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (duration == const Duration(milliseconds: 500)) {
              releaseBackoff = () => zone.run(callback);
              waiting.complete();
              // Hold backoff until explicitly released, not until wall-clock time.
              return backoffTimer = parent.createTimer(
                zone,
                const Duration(days: 1),
                callback,
              );
            }
            return parent.createTimer(zone, duration, callback);
          },
        ),
      );
      addTearDown(() => backoffTimer?.cancel());
      final expectation = expectLater(
        pending,
        throwsA(isA<KernelCancelledException>()),
      );
      await waiting.future;
      signal.cancel();
      await expectation.timeout(const Duration(seconds: 1));
      backoffTimer!.cancel();
      releaseBackoff();
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1);
    },
  );

  for (final error in [
    const WebSocketException('401'),
    const HandshakeException('certificate'),
    TimeoutException('connect'),
  ]) {
    test('WS TTS does not retry ${error.runtimeType}', () async {
      var attempts = 0;
      final service = AliyunQwenTtsWebSocket(
        apiKey: 'test',
        model: 'test',
        connect: (url, {headers}) async {
          attempts++;
          throw error;
        },
      );
      await expectLater(
        service.synthesize(text: 'hello', voiceId: 'voice'),
        throwsA(same(error)),
      );
      expect(attempts, 1);
    });
  }

  test('WS TTS does not retry after connection succeeds', () async {
    var attempts = 0;
    final socket = _Socket(failAfterConnect: true);
    final service = AliyunQwenTtsWebSocket(
      apiKey: 'test',
      model: 'test',
      connect: (url, {headers}) async {
        attempts++;
        return socket;
      },
    );
    await expectLater(
      service.synthesize(text: 'hello', voiceId: 'voice'),
      throwsA(isA<AliyunTtsWebSocketException>()),
    );
    expect(attempts, 1);
    expect(socket.closed, isTrue);
  });

  test(
    'WS TTS cancellation closes late connection without sending input',
    () async {
      final signal = KernelCancellation();
      final pending = Completer<WebSocket>();
      final socket = _Socket();
      var attempts = 0;
      final service = AliyunQwenTtsWebSocket(
        apiKey: 'test',
        model: 'test',
        connect: (url, {headers}) {
          attempts++;
          return pending.future;
        },
      );
      final synthesis = runZoned(
        () => service.synthesize(text: 'hello', voiceId: 'voice'),
        zoneValues: {#aicoveRequestCancellation: signal},
      );
      final expectation = expectLater(
        synthesis,
        throwsA(isA<KernelCancelledException>()),
      );
      signal.cancel();
      await expectation;
      pending.complete(socket);
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1);
      expect(socket.closed, isTrue);
      expect(socket.sent, isEmpty);
    },
  );
}
