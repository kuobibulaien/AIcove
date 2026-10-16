import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aicove_flutter/src/features/settings/settings_models.dart';
import 'package:aicove_flutter/src/features/voice_call/data/aliyun_realtime_speech_recognizer.dart';
import 'package:aicove_flutter/src/features/voice_call/data/cloud_asr/cloud_speech_recognizer_factory.dart';
import 'package:aicove_flutter/src/features/voice_call/data/cloud_asr/deepgram_speech_recognizer.dart';
import 'package:aicove_flutter/src/features/voice_call/data/cloud_asr/elevenlabs_speech_recognizer.dart';
import 'package:aicove_flutter/src/features/voice_call/data/cloud_asr/openai_realtime_speech_recognizer.dart';
import 'package:aicove_flutter/src/features/voice_call/data/cloud_asr/tencent_speech_recognizer.dart';
import 'package:aicove_flutter/src/features/voice_call/data/cloud_asr/volcengine_speech_recognizer.dart';
import 'package:aicove_flutter/src/features/voice_call/data/cloud_asr/websocket_speech_recognizer.dart';
import 'package:aicove_flutter/src/features/voice_call/data/cloud_asr/xfyun_speech_recognizer.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/speech_recognizer_port.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// 本地假服务：记下握手地址与请求头，把客户端消息交给 [onMessage] 按各家协议应答。
class _FakeServer {
  late final HttpServer server;
  Uri? uri;
  HttpHeaders? headers;
  final received = <Object>[];
  void Function(WebSocket ws, Object data)? onMessage;
  void Function(WebSocket ws)? onConnect;

  Uri get url => Uri.parse('ws://127.0.0.1:${server.port}/ws');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      uri = request.uri;
      headers = request.headers;
      final ws = await WebSocketTransformer.upgrade(request);
      onConnect?.call(ws);
      ws.listen((data) {
        received.add(data);
        onMessage?.call(ws, data);
      });
    });
  }

  List<Map<String, dynamic>> get jsonMessages => received
      .whereType<String>()
      .map((m) => jsonDecode(m) as Map<String, dynamic>)
      .toList();
}

/// 跑一遍：启动、喂一块音频、等事件、结束；返回事件序列的文字描述。
Future<List<String>> _run(
  WebSocketSpeechRecognizer recognizer, {
  int expectFinals = 1,
}) async {
  final events = <String>[];
  final finals = Completer<void>();
  var count = 0;
  recognizer.events.listen((event) {
    events.add(switch (event) {
      SpeechStarted() => 'start',
      SpeechPartial(:final text) => 'partial:$text',
      SpeechEnded() => 'end',
      SpeechFinal(:final text) => 'final:$text',
      SpeechRecognitionFailed(:final message) => 'failed:$message',
    });
    if (event is SpeechFinal &&
        ++count == expectFinals &&
        !finals.isCompleted) {
      finals.complete();
    }
  });
  await recognizer.start();
  recognizer.addAudio(Uint8List(3200));
  await finals.future.timeout(const Duration(seconds: 5));
  await recognizer.stop();
  await recognizer.dispose();
  return events;
}

void main() {
  late _FakeServer fake;

  setUp(() async {
    fake = _FakeServer();
    await fake.start();
  });

  tearDown(() => fake.server.close(force: true));

  test(
    'aliyun qwen3-asr realtime uses the realtime path and stash previews',
    () async {
      fake.onMessage = (ws, data) {
        final event = jsonDecode(data as String) as Map;
        switch (event['type']) {
          case 'session.update':
            ws.add(jsonEncode({'type': 'session.updated'}));
          case 'input_audio_buffer.append':
            ws.add(
              jsonEncode({
                'type': 'conversation.item.input_audio_transcription.text',
                'text': '今天',
                'stash': '天气',
              }),
            );
            ws.add(
              jsonEncode({
                'type': 'conversation.item.input_audio_transcription.completed',
                'transcript': '今天天气不错。',
              }),
            );
          case 'session.finish':
            ws.add(jsonEncode({'type': 'session.finished'}));
        }
      };
      final events = await _run(
        AliyunQwenRealtimeSpeechRecognizer(
          apiKey: 'k',
          model: 'qwen3-asr-flash-realtime',
          endpoint: fake.url,
        ),
      );
      expect(fake.uri!.path, '/api-ws/v1/realtime');
      expect(fake.uri!.queryParameters['model'], 'qwen3-asr-flash-realtime');
      expect(fake.headers!.value('authorization'), 'Bearer k');
      final update = fake.jsonMessages.first;
      expect(update['session']['turn_detection']['type'], 'server_vad');
      expect(update['session']['sample_rate'], 16000);
      expect(events, ['start', 'partial:今天天气', 'end', 'final:今天天气不错。']);
    },
  );

  test(
    'volcengine sends gzip binary frames and reports definite utterances once',
    () async {
      fake.onMessage = (ws, data) {
        final frame = parseVolcengineFrame(
          Uint8List.fromList(data as List<int>),
        );
        if (frame.type == 0x2 && !frame.isLast) {
          Uint8List response(Map<String, dynamic> json, {int flags = 0x1}) {
            final body = gzip.encode(utf8.encode(jsonEncode(json)));
            return (BytesBuilder()
                  ..add([0x11, 0x90 | flags, 0x11, 0x00])
                  ..add((ByteData(4)..setInt32(0, 2)).buffer.asUint8List())
                  ..add(
                    (ByteData(
                      4,
                    )..setUint32(0, body.length)).buffer.asUint8List(),
                  )
                  ..add(body))
                .toBytes();
          }

          Map<String, dynamic> result(bool definite) => {
            'result': {
              'text': '你好呀',
              'utterances': [
                {'text': '你好呀', 'start_time': 100, 'definite': definite},
              ],
            },
          };
          ws.add(response(result(false)));
          ws.add(response(result(true)));
          ws.add(response(result(true)));
        } else if (frame.isLast) {
          ws.add(
            (BytesBuilder()
                  ..add([0x11, 0x93, 0x10, 0x00])
                  ..add((ByteData(4)..setInt32(0, -3)).buffer.asUint8List())
                  ..add((ByteData(4)..setUint32(0, 0)).buffer.asUint8List()))
                .toBytes(),
          );
        }
      };
      final events = await _run(
        VolcengineSpeechRecognizer(
          apiKey: 'key',
          resourceId: 'volc.seedasr.sauc.duration',
          endpoint: fake.url,
        ),
      );
      expect(fake.headers!.value('x-api-key'), 'key');
      expect(
        fake.headers!.value('x-api-resource-id'),
        'volc.seedasr.sauc.duration',
      );
      final first = parseVolcengineFrame(
        Uint8List.fromList(fake.received.first as List<int>),
      );
      expect(first.type, 0x1);
      final request = jsonDecode(utf8.decode(first.payload)) as Map;
      expect(request['request']['show_utterances'], isTrue);
      expect(request['request']['end_window_size'], 500);
      expect(events, ['start', 'partial:你好呀', 'end', 'final:你好呀']);
    },
  );

  test(
    'volcengine legacy console uses app key and access token headers',
    () async {
      fake.onMessage = (ws, data) {};
      final recognizer = VolcengineSpeechRecognizer(
        apiKey: 'token',
        appId: '123',
        resourceId: 'volc.bigasr.sauc.duration',
        endpoint: fake.url,
      );
      await recognizer.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(fake.headers!.value('x-api-app-key'), '123');
      expect(fake.headers!.value('x-api-access-key'), 'token');
      expect(fake.headers!.value('x-api-key'), isNull);
      await recognizer.dispose();
    },
  );

  test(
    'tencent signs the sorted query with HMAC-SHA1 and maps slice types',
    () async {
      fake.onConnect = (ws) =>
          ws.add(jsonEncode({'code': 0, 'message': 'success'}));
      fake.onMessage = (ws, data) {
        if (data is List<int>) {
          for (final (type, text) in [(0, ''), (1, '我想'), (2, '我想你了。')]) {
            ws.add(
              jsonEncode({
                'code': 0,
                'result': {'slice_type': type, 'voice_text_str': text},
              }),
            );
          }
        } else if (jsonDecode(data as String)['type'] == 'end') {
          ws.add(jsonEncode({'code': 0, 'final': 1}));
        }
      };
      final recognizer = TencentSpeechRecognizer(
        appId: '1259',
        secretId: 'sid',
        secretKey: 'skey',
        engineModelType: '16k_zh',
        endpoint: fake.url,
      );
      final events = await _run(recognizer);
      final query = fake.uri!.queryParameters;
      expect(fake.uri!.path, '/ws/1259');
      expect(query['engine_model_type'], '16k_zh');
      expect(query['voice_format'], '1');
      expect(query['vad_silence_time'], '500');
      final unsigned = Map.of(query)..remove('signature');
      final keys = unsigned.keys.toList()..sort();
      final raw =
          '127.0.0.1:${fake.server.port}/ws/1259?${keys.map((k) => '$k=${unsigned[k]}').join('&')}';
      expect(
        query['signature'],
        base64Encode(
          Hmac(sha1, utf8.encode('skey')).convert(utf8.encode(raw)).bytes,
        ),
      );
      expect(events, ['start', 'partial:我想', 'end', 'final:我想你了。']);
    },
  );

  test('tencent reports a non-zero code as a start failure', () async {
    fake.onConnect = (ws) =>
        ws.add(jsonEncode({'code': 4002, 'message': '鉴权失败'}));
    final recognizer = TencentSpeechRecognizer(
      appId: '1',
      secretId: 's',
      secretKey: 'k',
      engineModelType: '16k_zh',
      endpoint: fake.url,
    );
    await expectLater(
      recognizer.start(),
      throwsA(predicate((e) => '$e'.contains('4002'))),
    );
  });

  test('xfyun signs appid+ts and reads type 0 as final', () async {
    final now = DateTime.fromMillisecondsSinceEpoch(1512041814000);
    fake.onConnect = (ws) =>
        ws.add(jsonEncode({'action': 'started', 'code': '0'}));
    fake.onMessage = (ws, data) {
      if (data is! List<int> ||
          utf8.decode(data, allowMalformed: true).contains('end')) {
        ws.close();
        return;
      }
      Map<String, dynamic> result(String type, List<String> words) => {
        'action': 'result',
        'code': '0',
        'data': jsonEncode({
          'cn': {
            'st': {
              'type': type,
              'rt': [
                {
                  'ws': [
                    for (final w in words)
                      {
                        'cw': [
                          {'w': w},
                        ],
                      },
                  ],
                },
              ],
            },
          },
        }),
      };
      ws.add(jsonEncode(result('1', ['早上'])));
      ws.add(jsonEncode(result('0', ['早上', '好', '。'])));
    };
    final events = await _run(
      XfyunSpeechRecognizer(
        appId: '595f23df',
        apiKey: 'd9f4aa7ea6d94faca62cd88a28fd5234',
        endpoint: fake.url,
        now: () => now,
      ),
    );
    // 讯飞文档示例值。
    expect(fake.uri!.queryParameters['signa'], 'IrrzsJeOFk1NGfJHW6SkHUoN9CU=');
    expect(fake.uri!.queryParameters['ts'], '1512041814');
    expect(events, ['start', 'partial:早上', 'end', 'final:早上好。']);
  });

  test('openai realtime opens a transcription session at 24 kHz', () async {
    fake.onMessage = (ws, data) {
      final event = jsonDecode(data as String) as Map;
      switch (event['type']) {
        case 'session.update':
          ws.add(jsonEncode({'type': 'session.updated'}));
        case 'input_audio_buffer.append':
          ws.add(jsonEncode({'type': 'input_audio_buffer.speech_started'}));
          for (final delta in ['Hel', 'lo']) {
            ws.add(
              jsonEncode({
                'type': 'conversation.item.input_audio_transcription.delta',
                'item_id': 'i1',
                'delta': delta,
              }),
            );
          }
          ws.add(
            jsonEncode({
              'type': 'conversation.item.input_audio_transcription.completed',
              'item_id': 'i1',
              'transcript': 'Hello.',
            }),
          );
      }
    };
    final events = await _run(
      OpenAiRealtimeSpeechRecognizer(
        apiKey: 'sk',
        model: 'gpt-4o-transcribe',
        endpoint: fake.url,
      ),
    );
    expect(fake.uri!.queryParameters['intent'], 'transcription');
    final update = fake.jsonMessages.first['session'] as Map;
    expect(update['type'], 'transcription');
    expect(update['audio']['input']['format']['rate'], 24000);
    expect(
      update['audio']['input']['transcription']['model'],
      'gpt-4o-transcribe',
    );
    final append = fake.jsonMessages[1];
    expect(base64Decode(append['audio'] as String).length, 3200 * 3 ~/ 2);
    expect(events, [
      'start',
      'partial:Hel',
      'partial:Hello',
      'end',
      'final:Hello.',
    ]);
  });

  test('upsampling keeps endpoints and interpolates between samples', () {
    final input = ByteData(4)
      ..setInt16(0, 0, Endian.little)
      ..setInt16(2, 300, Endian.little);
    final out = ByteData.sublistView(
      upsample16kTo24k(input.buffer.asUint8List()),
    );
    expect(out.lengthInBytes, 6);
    expect(
      [for (var i = 0; i < 3; i++) out.getInt16(i * 2, Endian.little)],
      [0, 200, 300],
    );
  });

  test('deepgram joins is_final pieces until speech_final', () async {
    fake.onMessage = (ws, data) {
      if (data is List<int>) {
        Map<String, dynamic> result(
          String text, {
          bool isFinal = false,
          bool speechFinal = false,
        }) => {
          'type': 'Results',
          'is_final': isFinal,
          'speech_final': speechFinal,
          'channel': {
            'alternatives': [
              {'transcript': text},
            ],
          },
        };
        ws.add(jsonEncode({'type': 'SpeechStarted'}));
        ws.add(jsonEncode(result('我')));
        ws.add(jsonEncode(result('我今天', isFinal: true)));
        ws.add(jsonEncode(result('很开心', isFinal: true, speechFinal: true)));
      } else if (jsonDecode(data as String)['type'] == 'CloseStream') {
        ws.close();
      }
    };
    final events = await _run(
      DeepgramSpeechRecognizer(
        apiKey: 'dg',
        model: 'nova-3',
        endpoint: fake.url,
      ),
    );
    expect(fake.headers!.value('authorization'), 'Token dg');
    final query = fake.uri!.queryParameters;
    expect(query['model'], 'nova-3');
    expect(query['language'], 'zh-CN');
    expect(query['encoding'], 'linear16');
    expect(query['endpointing'], '500');
    expect(events, [
      'start',
      'partial:我',
      'partial:我今天',
      'end',
      'final:我今天很开心',
    ]);
  });

  test(
    'silent gaps send keepalives: KeepAlive for deepgram, silence for tencent',
    () async {
      fake.onConnect = (ws) => ws.add(jsonEncode({'code': 0}));
      fake.onMessage = (ws, data) {};
      const interval = Duration(milliseconds: 100);
      final deepgram = DeepgramSpeechRecognizer(
        apiKey: 'dg',
        model: 'nova-3',
        endpoint: fake.url,
        keepAliveInterval: interval,
      );
      await deepgram.start();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(fake.jsonMessages.map((m) => m['type']), contains('KeepAlive'));
      await deepgram.dispose();

      fake.received.clear();
      final tencent = TencentSpeechRecognizer(
        appId: '1',
        secretId: 's',
        secretKey: 'k',
        engineModelType: '16k_zh',
        endpoint: fake.url,
        keepAliveInterval: interval,
      );
      await tencent.start();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final silence = fake.received.whereType<List<int>>().toList();
      expect(silence, isNotEmpty);
      expect(silence.first.every((b) => b == 0), isTrue);
      await tencent.dispose();
    },
  );

  test(
    'elevenlabs waits for session_started and maps committed transcripts',
    () async {
      fake.onConnect = (ws) =>
          ws.add(jsonEncode({'message_type': 'session_started'}));
      fake.onMessage = (ws, data) {
        final message = jsonDecode(data as String) as Map;
        if (message['commit'] == false) {
          ws.add(
            jsonEncode({'message_type': 'partial_transcript', 'text': 'hi'}),
          );
          ws.add(
            jsonEncode({
              'message_type': 'committed_transcript',
              'text': 'hi there',
            }),
          );
        }
      };
      final events = await _run(
        ElevenLabsSpeechRecognizer(
          apiKey: 'xi',
          model: 'scribe_v2_realtime',
          endpoint: fake.url,
        ),
      );
      expect(fake.headers!.value('xi-api-key'), 'xi');
      expect(fake.uri!.queryParameters['commit_strategy'], 'vad');
      expect(fake.uri!.queryParameters['audio_format'], 'pcm_16000');
      expect(events, ['start', 'partial:hi', 'end', 'final:hi there']);
    },
  );

  group('factory', () {
    ProviderAuth provider(
      String format, {
      Map<String, dynamic> extra = const {},
    }) => ProviderAuth(
      id: 'p',
      displayName: '测试渠道',
      apiKeys: const ['key'],
      apiBaseUrl: 'https://example.com/v1',
      customConfig: {'asrRequestFormat': format, ...extra},
    );

    test(
      'routes aliyun models by name and other formats by asrRequestFormat',
      () {
        expect(
          createCloudSpeechRecognizer(
            provider('aliyun_asr'),
            'fun-asr-realtime',
          ),
          isA<AliyunRealtimeSpeechRecognizer>(),
        );
        expect(
          createCloudSpeechRecognizer(
            provider('aliyun_asr'),
            'qwen3-asr-flash-realtime',
          ),
          isA<AliyunQwenRealtimeSpeechRecognizer>(),
        );
        expect(
          createCloudSpeechRecognizer(provider('deepgram'), 'nova-3'),
          isA<DeepgramSpeechRecognizer>(),
        );
        expect(
          createCloudSpeechRecognizer(
            provider(
              'tencent_asr',
              extra: {'asr_app_id': '1', 'asr_secret_id': 's'},
            ),
            '16k_zh',
          ),
          isA<TencentSpeechRecognizer>(),
        );
      },
    );

    test('reports missing credentials and formats in plain words', () {
      expect(
        () => createCloudSpeechRecognizer(provider('tencent_asr'), '16k_zh'),
        throwsA(
          isA<CloudRecognizerConfigError>().having(
            (e) => e.message,
            'message',
            contains('AppID'),
          ),
        ),
      );
      expect(
        () => createCloudSpeechRecognizer(
          const ProviderAuth(id: 'x', apiKeys: ['k'], apiBaseUrl: ''),
          'm',
        ),
        throwsA(isA<CloudRecognizerConfigError>()),
      );
    });
  });
}
