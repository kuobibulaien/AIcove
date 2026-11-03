import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:aicove_flutter/src/features/plugins/tts/aliyun_qwen_tts_websocket.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_service.dart';

class _RoutingClient implements HttpClient {
  _RoutingClient(this.client, this.endpoint);

  final HttpClient client;
  final Uri endpoint;
  Uri? original;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    original = uri;
    return client.openUrl(method, endpoint);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RealHttp extends HttpOverrides {}

/// A fresh isolate ensures WebSocket's cached client is first created under
/// our override, rather than by Flutter's test transport before the test starts.
Future<Map<String, Object?>> _runScenario({
  required bool delayHandshake,
  String? serviceUrl,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final client = _RealHttp().createHttpClient(null);
  final routing = _RoutingClient(
    client,
    Uri.parse('http://127.0.0.1:${server.port}/realtime'),
  );
  final received = Completer<void>();
  final upgrade = Completer<void>();
  final opened = Completer<WebSocket>();
  final closed = Completer<void>();
  final settled = Completer<void>();
  final guard = Completer<void>();
  final messages = <Map<String, dynamic>>[];
  final clock = Stopwatch()..start();
  final deadline = Timer(const Duration(seconds: 12), guard.complete);
  WebSocket? peer;
  Object? error;
  List<int>? audio;
  String? authorization;
  var closures = 0;
  server.listen((request) async {
    authorization = request.headers.value('authorization');
    received.complete();
    if (delayHandshake) await upgrade.future;
    final ws = peer = await WebSocketTransformer.upgrade(request);
    opened.complete(ws);
    if (!delayHandshake) ws.add(jsonEncode({'type': 'session.created'}));
    ws.listen(
      (data) {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        messages.add(message);
        switch (message['type']) {
          case 'session.update':
            ws.add(jsonEncode({'type': 'session.updated'}));
          case 'session.finish':
            ws.add(
              jsonEncode({
                'type': 'response.audio.delta',
                'delta': base64Encode([1, 2, 3, 4]),
              }),
            );
            ws.add(jsonEncode({'type': 'session.finished'}));
        }
      },
      onDone: () {
        closures++;
        closed.complete();
      },
    );
  });
  final synthesis = HttpOverrides.runZoned(
    () =>
        (serviceUrl == null
                ? AliyunQwenTtsWebSocket(
                    apiKey: 'test-key',
                    model: 'test-model',
                  ).synthesize(text: '你好', voiceId: 'voice')
                : TtsService(
                        config: TtsConfig(
                          voicePresets: [
                            VoicePreset(
                              id: 'voice',
                              name: 'Voice',
                              aliyunVoiceId: 'voice',
                              aliyunTargetModel: 'qwen3-tts-vc-realtime',
                            ),
                          ],
                          selectedVoicePresetId: 'voice',
                        ),
                        apiKey: 'test-key',
                        model: 'qwen3-tts-vc-realtime',
                        requestUrl: serviceUrl,
                        requestFormat: 'aliyun_qwen_tts',
                      )
                      .convert('你好')
                      .then(
                        (result) =>
                            base64Decode(result.audioUrl.split(',').last),
                      ))
            .then<void>(
              (value) {
                audio = value.toList();
                settled.complete();
              },
              onError: (Object value) {
                error = value;
                settled.complete();
              },
            ),
    createHttpClient: (_) => routing,
  );
  try {
    await received.future.timeout(const Duration(seconds: 2));
    await Future.any([settled.future, guard.future]);
    final timedOut = error is TimeoutException;
    final elapsedMs = clock.elapsedMilliseconds;
    final errorBeforeUpgrade = error?.toString();
    final completedBeforeUpgrade = settled.isCompleted;
    if (delayHandshake) {
      upgrade.complete();
      await opened.future.timeout(const Duration(seconds: 2));
      if (!timedOut) {
        // The old implementation is still waiting: close the peer to unwind
        // its synthesis cleanly, without turning cleanup into failure evidence.
        await peer!.close();
      }
    }
    await closed.future.timeout(const Duration(seconds: 2));
    await synthesis;
    return {
      'handshakeStarted': routing.original != null,
      'completedBeforeUpgrade': completedBeforeUpgrade,
      'timedOut': timedOut,
      'elapsedMs': elapsedMs,
      'errorBeforeUpgrade': errorBeforeUpgrade,
      'audio': audio,
      'authorization': authorization,
      'uri': routing.original?.toString(),
      'messages': messages,
      'closures': closures,
    };
  } finally {
    deadline.cancel();
    if (!upgrade.isCompleted) upgrade.complete();
    if (peer != null) await peer!.close();
    client.close(force: true);
    await server.close(force: true);
  }
}

void main() {
  for (final entry in {
    'https://my-proxy.example.com:8443/v1':
        'wss://my-proxy.example.com:8443/api-ws/v1/realtime',
    'http://my-proxy.example.com:8080/v1':
        'ws://my-proxy.example.com:8080/api-ws/v1/realtime',
    'dashscope-intl.aliyuncs.com':
        'wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime',
    'https://[invalid': 'wss://dashscope.aliyuncs.com/api-ws/v1/realtime',
  }.entries) {
    test('TtsService realtime uses ${entry.key} with Auto language', () async {
      final result = await Isolate.run(
        () => _runScenario(delayHandshake: false, serviceUrl: entry.key),
      );
      final uri = Uri.parse(result['uri']! as String);
      // dart:io converts ws(s) to http(s) for the upgrade request.
      final expected = Uri.parse(entry.value);
      expect(uri.scheme, expected.scheme == 'wss' ? 'https' : 'http');
      expect(uri.host, expected.host);
      expect(uri.port, expected.hasPort ? expected.port : 0);
      expect(uri.path, expected.path);
      expect(uri.queryParameters['model'], 'qwen3-tts-vc-realtime');
      expect(
        (result['messages']! as List)[0]['session']['language_type'],
        'Auto',
      );
      expect(result['authorization'], 'Bearer test-key');
      expect(result['audio'], hasLength(48));
    });
  }

  test(
    'successful Aliyun synthesis keeps its handshake and audio protocol',
    () async {
      final result = await Isolate.run(
        () => _runScenario(delayHandshake: false),
      );
      expect(result['handshakeStarted'], isTrue);
      expect(result['audio'], [1, 2, 3, 4]);
      expect(result['authorization'], 'Bearer test-key');
      final uri = Uri.parse(result['uri']! as String);
      expect(uri.host, 'dashscope.aliyuncs.com');
      expect(uri.queryParameters['model'], 'test-model');
      final messages = result['messages']! as List<Map<String, dynamic>>;
      expect(messages.map((message) => message['type']), [
        'session.update',
        'input_text_buffer.append',
        'session.finish',
      ]);
      expect(messages[0]['session']['voice'], 'voice');
      expect(messages[0]['session']['language_type'], 'Auto');
      expect(messages[1]['text'], '你好');
      expect(result['closures'], 1);
    },
  );

  test(
    'Aliyun handshake times out and its late socket closes without input',
    () async {
      final result = await Isolate.run(
        () => _runScenario(delayHandshake: true),
      );
      expect(result['handshakeStarted'], isTrue);
      expect(
        result['timedOut'],
        isTrue,
        reason: 'handshake must stop within 10 seconds: $result',
      );
      expect(result['completedBeforeUpgrade'], isTrue);
      expect(result['elapsedMs'], inInclusiveRange(9000, 11999));
      expect(result['messages'], isEmpty);
      expect(result['closures'], 1);
    },
  );
}
