import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/speech_recognizer_port.dart';
import 'cloud_asr/websocket_speech_recognizer.dart';

/// 阿里云百炼实时语音识别（Fun-ASR／Paraformer realtime，run-task 双工协议）。
///
/// 一个会话持续识别多句话，服务端按静音判断每句结束（`sentence_end`）。
/// 实测静音阈值 300 ms 会在句中逗号停顿处误切，默认取 500 ms。
class AliyunRealtimeSpeechRecognizer extends WebSocketSpeechRecognizer {
  AliyunRealtimeSpeechRecognizer({
    required this.apiKey,
    this.model = 'fun-asr-realtime',
    this.endOfTurnSilenceMs = 500,
    this.endpoint = defaultEndpoint,
    super.connect,
  });

  static const defaultEndpoint =
      'wss://dashscope.aliyuncs.com/api-ws/v1/inference';

  final String apiKey;
  final String model;
  final int endOfTurnSilenceMs;
  final String endpoint;
  final String _taskId = randomHexId();

  @override
  String get vendor => '阿里云';

  @override
  Future<(Uri, Map<String, String>)> connection() async =>
      (Uri.parse(endpoint), {'Authorization': 'Bearer $apiKey'});

  @override
  void onOpen(WebSocket socket) {
    socket.add(
      jsonEncode({
        'header': {
          'action': 'run-task',
          'task_id': _taskId,
          'streaming': 'duplex',
        },
        'payload': {
          'task_group': 'audio',
          'task': 'asr',
          'function': 'recognition',
          'model': model,
          'parameters': {
            'format': 'pcm',
            'sample_rate': speechRecognizerSampleRate,
            'max_sentence_silence': endOfTurnSilenceMs,
            // 静音保活时不被服务端按超时断开。
            'heartbeat': true,
          },
          'input': <String, dynamic>{},
        },
      }),
    );
  }

  @override
  void onMessage(Object data) {
    if (data is! String) return;
    final message = jsonDecode(data);
    if (message is! Map) return;
    final header = message['header'];
    switch (header is Map ? header['event'] : null) {
      case 'task-started':
        markReady();
      case 'result-generated':
        _onResult(message['payload']);
      case 'task-finished':
        markFinished();
      case 'task-failed':
        fail('${header['error_code']}: ${header['error_message']}');
    }
  }

  void _onResult(Object? payload) {
    final output = payload is Map ? payload['output'] : null;
    final sentence = output is Map ? output['sentence'] : null;
    if (sentence is! Map) return;
    final text = sentence['text']?.toString() ?? '';
    if (sentence['sentence_end'] == true) {
      if (text.trim().isNotEmpty) finalText(text);
    } else {
      partial(text);
    }
  }

  @override
  void sendAudio(WebSocket socket, Uint8List pcm16) => socket.add(pcm16);

  @override
  void sendFinish(WebSocket socket) => socket.add(
    jsonEncode({
      'header': {
        'action': 'finish-task',
        'task_id': _taskId,
        'streaming': 'duplex',
      },
      'payload': {'input': <String, dynamic>{}},
    }),
  );
}

/// 阿里云百炼 Qwen3-ASR 实时版（`/api-ws/v1/realtime`，OpenAI 风格事件，服务端 VAD）。
class AliyunQwenRealtimeSpeechRecognizer extends WebSocketSpeechRecognizer {
  AliyunQwenRealtimeSpeechRecognizer({
    required this.apiKey,
    required this.model,
    required this.endpoint,
    this.endOfTurnSilenceMs = 500,
    super.connect,
  });

  final String apiKey;
  final String model;

  /// run-task 地址或 realtime 地址都可以，统一换成 realtime 路径。
  final Uri endpoint;
  final int endOfTurnSilenceMs;

  @override
  String get vendor => '阿里云';

  @override
  Future<(Uri, Map<String, String>)> connection() async => (
    endpoint.replace(
      path: '/api-ws/v1/realtime',
      queryParameters: {'model': model},
    ),
    {'Authorization': 'Bearer $apiKey'},
  );

  @override
  void onOpen(WebSocket socket) {
    socket.add(
      jsonEncode({
        'event_id': randomHexId(16),
        'type': 'session.update',
        'session': {
          'modalities': ['text'],
          'input_audio_format': 'pcm',
          'sample_rate': speechRecognizerSampleRate,
          'turn_detection': {
            'type': 'server_vad',
            'silence_duration_ms': endOfTurnSilenceMs,
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
    switch (event['type']) {
      case 'session.updated':
        markReady();
      case 'input_audio_buffer.speech_started':
        speechStarted();
      case 'conversation.item.input_audio_transcription.text':
        partial('${event['text'] ?? ''}${event['stash'] ?? ''}');
      case 'conversation.item.input_audio_transcription.completed':
        finalText(event['transcript']?.toString() ?? '');
      case 'session.finished':
        markFinished();
      case 'error':
        final error = event['error'];
        fail(error is Map ? '${error['code']}: ${error['message']}' : '$error');
    }
  }

  @override
  void sendAudio(WebSocket socket, Uint8List pcm16) => socket.add(
    jsonEncode({
      'event_id': randomHexId(16),
      'type': 'input_audio_buffer.append',
      'audio': base64Encode(pcm16),
    }),
  );

  @override
  void sendFinish(WebSocket socket) => socket.add(
    jsonEncode({'event_id': randomHexId(16), 'type': 'session.finish'}),
  );
}
