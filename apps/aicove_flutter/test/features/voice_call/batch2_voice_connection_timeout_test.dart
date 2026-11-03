import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aicove_flutter/src/features/voice_call/data/cloud_asr/websocket_speech_recognizer.dart';
import 'package:aicove_flutter/src/features/voice_call/data/fish_audio_streaming_tts.dart';
import 'package:flutter_test/flutter_test.dart';

/// Keep the HTTP upgrade pending without touching the network.
class _PendingHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      Completer<HttpClientRequest>().future;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LateSocket implements WebSocket {
  var closes = 0;
  @override
  Future<void> close([int? code, String? reason]) async => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Recognizer extends WebSocketSpeechRecognizer {
  @override
  String get vendor => 'test';
  @override
  Future<(Uri, Map<String, String>)> connection() async =>
      (Uri.parse('ws://127.0.0.1/pending'), <String, String>{});
  @override
  void onOpen(WebSocket socket) => markReady();
  @override
  void onMessage(Object data) {}
  @override
  void sendAudio(WebSocket socket, Uint8List pcm16) {}
  @override
  void sendFinish(WebSocket socket) => markFinished();
}

void main() {
  testWidgets('Fish open times out even with a pending custom connector', (
    tester,
  ) async {
    final connections = <Completer<WebSocket>>[];
    final tts = FishAudioStreamingTts(
      apiKey: 'test',
      referenceId: 'test',
      connect: (_, _) {
        final connection = Completer<WebSocket>();
        connections.add(connection);
        return connection.future;
      },
    );
    var finished = false;
    final result = expectLater(tts.open(), throwsA(isA<TimeoutException>()))
      ..then((_) => finished = true);
    try {
      await tester.pump(const Duration(seconds: 9));
      expect(finished, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(finished, isTrue);
    } finally {
      await tts.close();
    }
    await result;
    final sockets = connections.map((_) => _LateSocket()).toList();
    for (var i = 0; i < connections.length; i++) {
      connections[i].complete(sockets[i]);
    }
    await tester.pump();
    expect(sockets.map((socket) => socket.closes), everyElement(1));
  });

  testWidgets('default WebSocket connectors stop waiting after ten seconds', (
    tester,
  ) async {
    await HttpOverrides.runZoned(() async {
      final recognizer = _Recognizer();
      final tts = FishAudioStreamingTts(apiKey: 'test', referenceId: 'test');
      var finished = 0;
      final results = [
        expectLater(recognizer.start(), throwsA(isA<TimeoutException>()))
          ..then((_) => finished++),
        expectLater(tts.open(), throwsA(isA<TimeoutException>()))
          ..then((_) => finished++),
      ];
      try {
        await tester.pump();
        await tester.pump(const Duration(seconds: 9));
        expect(finished, 0);
        await tester.pump(const Duration(seconds: 2));
        expect(finished, 2);
      } finally {
        await recognizer.dispose();
        await tts.close();
      }
      await Future.wait(results);
    }, createHttpClient: (_) => _PendingHttpClient());
  });
}
