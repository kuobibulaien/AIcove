import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aicove_flutter/src/features/voice_call/data/aliyun_realtime_speech_recognizer.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/speech_recognizer_port.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按百炼实时识别协议应答的本地假服务。
class _FakeServer {
  late final HttpServer server;
  final requests = <Map<String, dynamic>>[];
  String? authorization;
  var audioBytes = 0;

  /// 收到音频后依次推送的识别结果（text, sentenceEnd）。
  List<(String, bool)> results = const [];
  bool failOnStart = false;

  /// 回 task-started 后立即正常关闭连接，模拟服务端中途断开。
  bool closeAfterStart = false;

  String get url => 'ws://127.0.0.1:${server.port}/api-ws/v1/inference';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      authorization = request.headers.value('authorization');
      final ws = await WebSocketTransformer.upgrade(request);
      var sentResults = false;
      ws.listen((data) {
        if (data is List<int>) {
          audioBytes += data.length;
          if (!sentResults) {
            sentResults = true;
            for (final (text, end) in results) {
              ws.add(
                _event('result-generated', {
                  'output': {
                    'sentence': {'text': text, 'sentence_end': end},
                  },
                }),
              );
            }
          }
          return;
        }
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        requests.add(message);
        final action = (message['header'] as Map)['action'];
        if (action == 'run-task') {
          ws.add(
            failOnStart
                ? jsonEncode({
                    'header': {
                      'event': 'task-failed',
                      'error_code': 'InvalidApiKey',
                      'error_message': 'bad key',
                    },
                  })
                : _event('task-started', {}),
          );
          if (closeAfterStart) ws.close(1000);
        } else if (action == 'finish-task') {
          ws.add(_event('task-finished', {}));
        }
      });
    });
  }

  String _event(String event, Map<String, dynamic> payload) => jsonEncode({
    'header': {'event': event},
    'payload': payload,
  });
}

void main() {
  late _FakeServer fake;

  setUp(() async {
    fake = _FakeServer();
    await fake.start();
  });

  tearDown(() => fake.server.close(force: true));

  test(
    'sends run-task with end-of-turn silence and maps results to events',
    () async {
      fake.results = const [
        ('我今天', false),
        ('我今天下午去面试了', false),
        ('我今天下午去面试了。', true),
        ('好紧张', false),
      ];
      final recognizer = AliyunRealtimeSpeechRecognizer(
        apiKey: 'test-key',
        endpoint: fake.url,
      );
      final events = <SpeechRecognitionEvent>[];
      recognizer.events.listen(events.add);

      await recognizer.start();
      recognizer.addAudio(Uint8List(3200));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await recognizer.stop();
      await recognizer.dispose();

      expect(fake.authorization, 'Bearer test-key');
      final runTask = fake.requests.first;
      expect((runTask['header'] as Map)['streaming'], 'duplex');
      final params = (runTask['payload'] as Map)['parameters'] as Map;
      expect(params['max_sentence_silence'], 500);
      expect(params['sample_rate'], speechRecognizerSampleRate);
      expect(params['format'], 'pcm');
      expect((fake.requests.last['header'] as Map)['action'], 'finish-task');
      expect(fake.audioBytes, 3200);

      expect(events.map((e) => e.runtimeType).toList(), [
        SpeechStarted,
        SpeechPartial,
        SpeechPartial,
        SpeechEnded,
        SpeechFinal,
        SpeechStarted,
        SpeechPartial,
      ]);
      expect((events[4] as SpeechFinal).text, '我今天下午去面试了。');
      // 主动 stop 引起的结束不算失败。
      expect(events.whereType<SpeechRecognitionFailed>(), isEmpty);
    },
  );

  test('start throws when the task fails', () async {
    fake.failOnStart = true;
    final recognizer = AliyunRealtimeSpeechRecognizer(
      apiKey: 'bad',
      endpoint: fake.url,
    );
    await expectLater(recognizer.start(), throwsA(isA<StateError>()));
  });

  test('a connection the server closes mid-call is reported as failure', () async {
    fake.closeAfterStart = true;
    final recognizer = AliyunRealtimeSpeechRecognizer(
      apiKey: 'test-key',
      endpoint: fake.url,
    );
    final events = <SpeechRecognitionEvent>[];
    recognizer.events.listen(events.add);
    await recognizer.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(events.whereType<SpeechRecognitionFailed>(), hasLength(1));
    await recognizer.dispose();
  });
}
