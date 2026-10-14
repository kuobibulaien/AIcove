import 'dart:io';
import 'dart:typed_data';

import 'package:aicove_flutter/src/features/voice_call/data/fish_audio_streaming_tts.dart';
import 'package:aicove_flutter/src/features/voice_call/data/msgpack.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按 Fish Audio 实时协议应答的本地假服务：每收到一次 flush 推一块音频，
/// 音频内容是连接序号，用来区分是哪条连接发出的。
class _FakeFish {
  late final HttpServer server;
  final connections = <List<Map>>[];
  final headers = <Map<String, String?>>[];
  final sockets = <WebSocket>[];

  String get url => 'ws://127.0.0.1:${server.port}/v1/tts/live';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      headers.add({
        'authorization': request.headers.value('authorization'),
        'model': request.headers.value('model'),
      });
      final ws = await WebSocketTransformer.upgrade(request);
      final index = connections.length;
      final events = <Map>[];
      connections.add(events);
      sockets.add(ws);
      ws.listen((data) {
        final message = Msgpack.decode(Uint8List.fromList(data as List<int>));
        events.add(message as Map);
        if (message['event'] == 'flush') {
          ws.add(
            Msgpack.encode({
              'event': 'audio',
              'audio': Uint8List.fromList([index, index]),
            }),
          );
        }
      });
    });
  }
}

void main() {
  late _FakeFish fake;

  setUp(() async {
    fake = _FakeFish();
    await fake.start();
  });

  tearDown(() => fake.server.close(force: true));

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test('opens an active and a spare session with the voice preset', () async {
    final tts = FishAudioStreamingTts(
      apiKey: 'k',
      referenceId: 'voice-1',
      model: 's2.1-pro-free',
      endpoint: fake.url,
    );
    await tts.open();
    await settle();

    expect(fake.connections, hasLength(2));
    expect(fake.headers.first, {
      'authorization': 'Bearer k',
      'model': 's2.1-pro-free',
    });
    final start = fake.connections.first.first;
    expect(start['event'], 'start');
    expect(start['request'], {
      'text': '',
      'reference_id': 'voice-1',
      'format': 'pcm',
      'sample_rate': 24000,
      'latency': 'balanced',
    });
    await tts.close();
  });

  test(
    'speak sends text+flush and forwards audio of the active session only',
    () async {
      final tts = FishAudioStreamingTts(
        apiKey: 'k',
        referenceId: 'v',
        endpoint: fake.url,
      );
      final audio = <List<int>>[];
      tts.audio.listen(audio.add);
      await tts.open();
      await settle();

      tts.speak('诶？');
      await settle();
      expect(fake.connections[0].skip(1).map((e) => e['event']), [
        'text',
        'flush',
      ]);
      expect(fake.connections[0][1]['text'], '诶？');
      expect(audio, [
        [0, 0],
      ]);

      // 打断：旧连接关闭，后续文字走备用连接，并补建新的备用连接。
      await tts.interrupt();
      await settle();
      tts.speak('好的。');
      await settle();
      expect(fake.connections[1].last['event'], 'flush');
      expect(audio.last, [1, 1]);
      expect(fake.connections, hasLength(3));

      // 旧连接即使还在推送，也不会混进当前输出。
      fake.sockets[0].add(
        Msgpack.encode({
          'event': 'audio',
          'audio': Uint8List.fromList([9, 9]),
        }),
      );
      await settle();
      expect(audio.where((a) => a[0] == 9), isEmpty);
      await tts.close();
    },
  );

  test(
    'switches to a fresh session after the server drops the active one',
    () async {
      final tts = FishAudioStreamingTts(
        apiKey: 'k',
        referenceId: 'v',
        endpoint: fake.url,
      );
      final audio = <List<int>>[];
      tts.audio.listen(audio.add);
      await tts.open();
      await settle();

      await fake.sockets[0].close(); // 模拟空闲超时
      await settle();
      tts.speak('还在吗？');
      await settle();
      expect(audio, [
        [1, 1],
      ]);
      await tts.close();
    },
  );
}
