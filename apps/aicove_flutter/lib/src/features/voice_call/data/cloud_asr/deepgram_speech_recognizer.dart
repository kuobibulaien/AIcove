import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../domain/speech_recognizer_port.dart';
import 'websocket_speech_recognizer.dart';

/// Deepgram 实时识别（`/v1/listen`）。
///
/// 一句话可能分几段 `is_final` 下发，拼起来直到 `speech_final`（静音判停）或
/// `UtteranceEnd`（按词间隔判停，嘈杂环境下的兜底）才算定稿。
class DeepgramSpeechRecognizer extends WebSocketSpeechRecognizer {
  DeepgramSpeechRecognizer({
    required this.apiKey,
    required this.model,
    required this.endpoint,
    this.language,
    this.endOfTurnSilenceMs = 500,
    super.connect,
    super.keepAliveInterval,
  });

  final String apiKey;
  final String model;
  final Uri endpoint;

  /// 为空时用 `zh-CN`。
  final String? language;
  final int endOfTurnSilenceMs;

  final _settled = StringBuffer();

  @override
  String get vendor => 'Deepgram';

  @override
  Future<(Uri, Map<String, String>)> connection() async => (
    endpoint.replace(
      queryParameters: {
        ...endpoint.queryParameters,
        'model': model,
        'language': (language?.trim().isNotEmpty ?? false)
            ? language!.trim()
            : 'zh-CN',
        'encoding': 'linear16',
        'sample_rate': '$speechRecognizerSampleRate',
        'channels': '1',
        'interim_results': 'true',
        'punctuate': 'true',
        'smart_format': 'true',
        'endpointing': '$endOfTurnSilenceMs',
        'utterance_end_ms': '1000',
        'vad_events': 'true',
      },
    ),
    {'Authorization': 'Token $apiKey'},
  );

  /// 鉴权在握手时校验，连上即可送音频。
  @override
  void onOpen(WebSocket socket) => markReady();

  @override
  void onMessage(Object data) {
    if (data is! String) return;
    final message = jsonDecode(data);
    if (message is! Map) return;
    switch (message['type']) {
      case 'SpeechStarted':
        speechStarted();
      case 'Results':
        final channel = message['channel'];
        final alternatives = channel is Map ? channel['alternatives'] : null;
        final first = alternatives is List && alternatives.isNotEmpty
            ? alternatives.first
            : null;
        final text = first is Map ? first['transcript']?.toString() ?? '' : '';
        if (message['is_final'] == true) {
          _settled.write(text);
          if (message['speech_final'] == true) {
            _flush();
          } else {
            partial(_settled.toString());
          }
        } else {
          partial('$_settled$text');
        }
      case 'UtteranceEnd':
        _flush();
      case 'Error':
        fail(
          '${message['err_code'] ?? ''} ${message['err_msg'] ?? message['description'] ?? ''}',
        );
    }
  }

  void _flush() {
    final text = _settled.toString();
    _settled.clear();
    if (text.trim().isNotEmpty) finalText(text);
  }

  @override
  void sendAudio(WebSocket socket, Uint8List pcm16) => socket.add(pcm16);

  @override
  void sendKeepAlive(WebSocket socket) =>
      socket.add(jsonEncode({'type': 'KeepAlive'}));

  /// 服务端发完剩余结果后关连接，由连接关闭收尾。
  @override
  void sendFinish(WebSocket socket) =>
      socket.add(jsonEncode({'type': 'CloseStream'}));
}
