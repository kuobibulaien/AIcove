import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../domain/speech_recognizer_port.dart';

/// 阿里云百炼实时语音识别（Paraformer realtime，WebSocket 双工）。
///
/// 一个会话持续识别多句话，服务端按静音判断每句结束（`sentence_end`）。
/// 实测静音阈值 300 ms 会在句中逗号停顿处误切，默认取 500 ms。
class AliyunRealtimeSpeechRecognizer implements SpeechRecognizerPort {
  AliyunRealtimeSpeechRecognizer({
    required this.apiKey,
    this.model = 'paraformer-realtime-v2',
    this.endOfTurnSilenceMs = 500,
    this.endpoint = defaultEndpoint,
    Future<WebSocket> Function(Uri uri, Map<String, String> headers)? connect,
  }) : _connect =
           connect ??
           ((uri, headers) =>
               WebSocket.connect(uri.toString(), headers: headers));

  static const defaultEndpoint =
      'wss://dashscope.aliyuncs.com/api-ws/v1/inference';

  final String apiKey;
  final String model;
  final int endOfTurnSilenceMs;
  final String endpoint;
  final Future<WebSocket> Function(Uri uri, Map<String, String> headers)
  _connect;

  final _events = StreamController<SpeechRecognitionEvent>.broadcast();
  WebSocket? _socket;
  String? _taskId;
  bool _inUtterance = false;
  bool _stopping = false;
  Completer<void>? _finished;

  @override
  Stream<SpeechRecognitionEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (_socket != null) return;
    final socket = await _connect(Uri.parse(endpoint), {
      'Authorization': 'Bearer $apiKey',
    });
    _socket = socket;
    final random = Random();
    final taskId = List.generate(
      32,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    _taskId = taskId;
    final started = Completer<void>();
    _finished = Completer<void>();
    socket.listen(
      (data) {
        if (data is! String) return;
        final message = jsonDecode(data);
        if (message is! Map) return;
        final header = message['header'];
        final event = header is Map ? header['event'] : null;
        switch (event) {
          case 'task-started':
            if (!started.isCompleted) started.complete();
          case 'result-generated':
            _onResult(message['payload']);
          case 'task-finished':
            _onTaskOver(started);
          case 'task-failed':
            final error = header is Map
                ? '${header['error_code']}: ${header['error_message']}'
                : data;
            if (!started.isCompleted) {
              started.completeError(StateError(error));
            } else {
              _emit(SpeechRecognitionFailed(error));
            }
            _completeFinished();
        }
      },
      onError: (Object e) {
        if (!started.isCompleted) {
          started.completeError(e);
        } else {
          _emit(SpeechRecognitionFailed('$e'));
        }
      },
      onDone: () {
        if (!started.isCompleted) {
          started.completeError(StateError('连接已关闭'));
        }
        _onTaskOver(started);
      },
    );
    socket.add(
      jsonEncode({
        'header': {
          'action': 'run-task',
          'task_id': taskId,
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
          },
          'input': <String, dynamic>{},
        },
      }),
    );
    try {
      await started.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  /// 任务结束或连接关闭。不是我们主动 [stop] 的，就是服务端中途断了，
  /// 通话再也收不到识别结果，必须报失败让通话收尾，不能停在“在听”。
  void _onTaskOver(Completer<void> started) {
    if (started.isCompleted && !_stopping && !_finishedCompleted) {
      _emit(const SpeechRecognitionFailed('识别连接已断开'));
    }
    _completeFinished();
  }

  bool get _finishedCompleted => _finished?.isCompleted ?? true;

  void _emit(SpeechRecognitionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _completeFinished() {
    final finished = _finished;
    if (finished != null && !finished.isCompleted) finished.complete();
  }

  void _onResult(Object? payload) {
    final output = payload is Map ? payload['output'] : null;
    final sentence = output is Map ? output['sentence'] : null;
    if (sentence is! Map) return;
    final text = sentence['text']?.toString().trim() ?? '';
    if (text.isEmpty) return;
    if (!_inUtterance) {
      _inUtterance = true;
      _emit(const SpeechStarted());
    }
    if (sentence['sentence_end'] == true) {
      _inUtterance = false;
      _emit(const SpeechEnded());
      _emit(SpeechFinal(text));
    } else {
      _emit(SpeechPartial(text));
    }
  }

  @override
  void addAudio(Uint8List pcm16) => _socket?.add(pcm16);

  @override
  Future<void> stop() async {
    final socket = _socket;
    final taskId = _taskId;
    if (socket == null || taskId == null) return;
    _stopping = true;
    socket.add(
      jsonEncode({
        'header': {
          'action': 'finish-task',
          'task_id': taskId,
          'streaming': 'duplex',
        },
        'payload': {'input': <String, dynamic>{}},
      }),
    );
    await _finished?.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {},
    );
  }

  @override
  Future<void> dispose() async {
    _stopping = true;
    final socket = _socket;
    _socket = null;
    await socket?.close();
    if (!_events.isClosed) await _events.close();
  }
}
