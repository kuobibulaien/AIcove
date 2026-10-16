import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'websocket_speech_recognizer.dart';

/// OpenAI Realtime 转写会话（`/v1/realtime?intent=transcription`，服务端 VAD）。
///
/// Realtime 的 PCM 只收 24 kHz，话筒的 16 kHz 在这里线性插值升采样。
/// `gpt-live-transcribe` 不支持服务端 VAD，暂不能用于通话。
class OpenAiRealtimeSpeechRecognizer extends WebSocketSpeechRecognizer {
  OpenAiRealtimeSpeechRecognizer({
    required this.apiKey,
    required this.model,
    required this.endpoint,
    this.endOfTurnSilenceMs = 500,
    super.connect,
  });

  final String apiKey;
  final String model;
  final Uri endpoint;
  final int endOfTurnSilenceMs;

  final _deltas = <String, StringBuffer>{};

  @override
  String get vendor => 'OpenAI';

  @override
  Future<(Uri, Map<String, String>)> connection() async => (
    endpoint.replace(
      queryParameters: {...endpoint.queryParameters, 'intent': 'transcription'},
    ),
    {'Authorization': 'Bearer $apiKey'},
  );

  @override
  void onOpen(WebSocket socket) {
    socket.add(
      jsonEncode({
        'type': 'session.update',
        'session': {
          'type': 'transcription',
          'audio': {
            'input': {
              'format': {'type': 'audio/pcm', 'rate': 24000},
              'transcription': {'model': model},
              'turn_detection': {
                'type': 'server_vad',
                'silence_duration_ms': endOfTurnSilenceMs,
              },
            },
          },
        },
      }),
    );
  }

  @override
  void onMessage(Object data) {
    if (data is! String) return;
    final event = jsonDecode(data);
    if (event is! Map) return;
    final itemId = event['item_id']?.toString() ?? '';
    switch (event['type']) {
      case 'session.updated' || 'transcription_session.updated':
        markReady();
      case 'input_audio_buffer.speech_started':
        speechStarted();
      case 'conversation.item.input_audio_transcription.delta':
        final buffer = _deltas.putIfAbsent(itemId, StringBuffer.new)
          ..write(event['delta'] ?? '');
        partial(buffer.toString());
      case 'conversation.item.input_audio_transcription.completed':
        _deltas.remove(itemId);
        finalText(event['transcript']?.toString() ?? '');
        if (stopping) markFinished();
      case 'error':
        final error = event['error'];
        fail(error is Map ? '${error['code']}: ${error['message']}' : '$error');
    }
  }

  @override
  void sendAudio(WebSocket socket, Uint8List pcm16) => socket.add(
    jsonEncode({
      'type': 'input_audio_buffer.append',
      'audio': base64Encode(upsample16kTo24k(pcm16)),
    }),
  );

  /// 把没判停的最后一句交出去；缓冲区为空时服务端回错误，没人在说话就直接收尾，否则最多等 2 秒。
  @override
  void sendFinish(WebSocket socket) {
    socket.add(jsonEncode({'type': 'input_audio_buffer.commit'}));
    if (!inUtterance) {
      markFinished();
      return;
    }
    Timer(const Duration(seconds: 2), markFinished);
  }
}

/// 16 kHz → 24 kHz PCM16 小端，线性插值（每 2 个输入样本产出 3 个）。
Uint8List upsample16kTo24k(Uint8List pcm16) {
  final input = ByteData.sublistView(pcm16);
  final count = pcm16.length ~/ 2;
  if (count == 0) return Uint8List(0);
  final outCount = count * 3 ~/ 2;
  final output = ByteData(outCount * 2);
  for (var i = 0; i < outCount; i++) {
    final position = i * 2 / 3;
    final index = position.floor();
    final next = index + 1 < count ? index + 1 : index;
    final fraction = position - index;
    final a = input.getInt16(index * 2, Endian.little);
    final b = input.getInt16(next * 2, Endian.little);
    output.setInt16(i * 2, (a + (b - a) * fraction).round(), Endian.little);
  }
  return output.buffer.asUint8List();
}
