import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/speech_recognizer_port.dart';
import 'websocket_speech_recognizer.dart';

/// ElevenLabs Scribe 实时识别（`/v1/speech-to-text/realtime`，服务端 VAD 自动提交）。
class ElevenLabsSpeechRecognizer extends WebSocketSpeechRecognizer {
  ElevenLabsSpeechRecognizer({
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

  @override
  String get vendor => 'ElevenLabs';

  @override
  Future<(Uri, Map<String, String>)> connection() async => (
    endpoint.replace(
      queryParameters: {
        ...endpoint.queryParameters,
        'model_id': model,
        'audio_format': 'pcm_$speechRecognizerSampleRate',
        'commit_strategy': 'vad',
        'vad_silence_threshold_secs': '${endOfTurnSilenceMs / 1000}',
      },
    ),
    {'xi-api-key': apiKey},
  );

  @override
  void onOpen(WebSocket socket) {}

  @override
  void onMessage(Object data) {
    if (data is! String) return;
    final message = jsonDecode(data);
    if (message is! Map) return;
    final type = message['message_type']?.toString() ?? '';
    switch (type) {
      case 'session_started':
        markReady();
      case 'partial_transcript':
        partial(message['text']?.toString() ?? '');
      case 'committed_transcript':
        finalText(message['text']?.toString() ?? '');
        if (stopping) markFinished();
      default:
        if (type.contains('error')) {
          fail('$type: ${message['error'] ?? message['message'] ?? ''}');
        }
    }
  }

  void _chunk(WebSocket socket, Uint8List pcm16, {bool commit = false}) =>
      socket.add(
        jsonEncode({
          'message_type': 'input_audio_chunk',
          'audio_base_64': base64Encode(pcm16),
          'commit': commit,
          'sample_rate': speechRecognizerSampleRate,
        }),
      );

  @override
  void sendAudio(WebSocket socket, Uint8List pcm16) => _chunk(socket, pcm16);

  /// 手动提交最后一句；没人在说话就直接收尾，否则最多等 2 秒。
  @override
  void sendFinish(WebSocket socket) {
    _chunk(socket, Uint8List(0), commit: true);
    if (!inUtterance) {
      markFinished();
      return;
    }
    Timer(const Duration(seconds: 2), markFinished);
  }
}
