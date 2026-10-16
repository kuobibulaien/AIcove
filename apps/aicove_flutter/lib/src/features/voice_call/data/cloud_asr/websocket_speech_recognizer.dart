import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../domain/speech_recognizer_port.dart';

typedef WebSocketConnector =
    Future<WebSocket> Function(Uri uri, Map<String, String> headers);

Future<WebSocket> _defaultConnect(Uri uri, Map<String, String> headers) =>
    WebSocket.connect(uri.toString(), headers: headers);

/// 云端流式识别的公共骨架：建连、等服务端就绪、句子状态、保活、收尾与断线判定。
///
/// 各厂商只管协议本身：[connection] 给出地址和请求头，[onOpen] 发开场消息，
/// [onMessage] 解析服务端消息并调用 [markReady]／[partial]／[finalText]／[fail]／[markFinished]，
/// [sendAudio]、[sendFinish]、[sendKeepAlive] 按各自格式发数据。
abstract class WebSocketSpeechRecognizer implements SpeechRecognizerPort {
  WebSocketSpeechRecognizer({
    WebSocketConnector? connect,
    this.keepAliveInterval = const Duration(seconds: 4),
  }) : _connect = connect ?? _defaultConnect;

  final WebSocketConnector _connect;

  /// 通话里角色说话时话筒不送音频；超过这么久没有音频就发一次保活，
  /// 免得服务端按「长时间没收到音频」断开（腾讯 6 秒、Deepgram 10 秒、讯飞 15 秒）。
  final Duration keepAliveInterval;

  /// 日志和错误里显示的厂商名。
  String get vendor;

  /// 建连地址与请求头；签名类鉴权在这里现算。
  Future<(Uri, Map<String, String>)> connection();

  /// 连上后要发的开场消息。服务端没有就绪事件的协议在这里直接 [markReady]。
  void onOpen(WebSocket socket);

  void onMessage(Object data);

  void sendAudio(WebSocket socket, Uint8List pcm16);

  /// 通知服务端音频发完；服务端收尾后调用 [markFinished]（或直接关连接）。
  void sendFinish(WebSocket socket);

  /// 默认发 100 ms 静音；有专门保活消息的协议覆写。
  void sendKeepAlive(WebSocket socket) =>
      sendAudio(socket, Uint8List(speechRecognizerSampleRate ~/ 10 * 2));

  final _events = StreamController<SpeechRecognitionEvent>.broadcast();
  WebSocket? _socket;
  Completer<void>? _ready;
  Completer<void>? _finished;
  Timer? _keepAlive;
  DateTime _lastAudio = DateTime.now();
  bool _inUtterance = false;
  bool _stopping = false;

  WebSocket? get socket => _socket;

  /// 当前有一句话说到一半（已开口、还没定稿）。
  bool get inUtterance => _inUtterance;
  bool get stopping => _stopping;

  @override
  Stream<SpeechRecognitionEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (_socket != null) return;
    final (uri, headers) = await connection();
    final socket = await _connect(uri, headers);
    _socket = socket;
    final ready = _ready = Completer<void>();
    _finished = Completer<void>();
    socket.listen(
      (data) {
        try {
          onMessage(data);
        } catch (e) {
          fail('$vendor 返回了无法解析的消息：$e');
        }
      },
      onError: (Object e) => fail('$e'),
      onDone: () {
        final reason = socket.closeReason;
        if (!ready.isCompleted) {
          ready.completeError(
            StateError(
              '$vendor 连接已关闭${reason == null || reason.isEmpty ? '' : '：$reason'}',
            ),
          );
        } else if (!_stopping && !_isFinished) {
          // 不是我们主动结束的，通话再也收不到识别结果，必须报失败让通话收尾。
          _emit(const SpeechRecognitionFailed('识别连接已断开'));
        }
        markFinished();
      },
    );
    onOpen(socket);
    try {
      await ready.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      await dispose();
      rethrow;
    }
    _lastAudio = DateTime.now();
    _keepAlive = Timer.periodic(keepAliveInterval, (_) {
      final socket = _socket;
      if (socket == null || _stopping) return;
      if (DateTime.now().difference(_lastAudio) >= keepAliveInterval) {
        sendKeepAlive(socket);
      }
    });
  }

  bool get _isFinished => _finished?.isCompleted ?? true;

  void _emit(SpeechRecognitionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// 服务端已就绪，可以发音频。
  void markReady() {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.complete();
  }

  void markFinished() {
    final finished = _finished;
    if (finished != null && !finished.isCompleted) finished.complete();
  }

  /// 服务端报错：开场前算接通失败，开场后通话收到失败事件。
  void fail(String message) {
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(StateError('$vendor：$message'));
    } else if (!_stopping) {
      _emit(SpeechRecognitionFailed('$vendor：$message'));
    }
    markFinished();
  }

  /// 当前句尚未定稿的文字。
  void partial(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (!_inUtterance) {
      _inUtterance = true;
      _emit(const SpeechStarted());
    }
    _emit(SpeechPartial(trimmed));
  }

  /// 一句话定稿。空文字也收掉当前句，让通话知道这段语音没有识别出字。
  void finalText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty && !_inUtterance) return;
    if (!_inUtterance) _emit(const SpeechStarted());
    _inUtterance = false;
    _emit(const SpeechEnded());
    if (trimmed.isNotEmpty) _emit(SpeechFinal(trimmed));
  }

  /// 服务端检测到开口（有的协议在出字前就会说）。
  void speechStarted() {
    if (_inUtterance) return;
    _inUtterance = true;
    _emit(const SpeechStarted());
  }

  @override
  void addAudio(Uint8List pcm16) {
    final socket = _socket;
    if (socket == null || _stopping) return;
    _lastAudio = DateTime.now();
    sendAudio(socket, pcm16);
  }

  @override
  Future<void> stop() async {
    final socket = _socket;
    if (socket == null || _stopping) return;
    _stopping = true;
    _keepAlive?.cancel();
    try {
      sendFinish(socket);
    } catch (_) {
      markFinished();
    }
    await _finished?.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {},
    );
  }

  @override
  Future<void> dispose() async {
    _stopping = true;
    _keepAlive?.cancel();
    final socket = _socket;
    _socket = null;
    await socket?.close();
    if (!_events.isClosed) await _events.close();
  }
}

/// 32 位十六进制随机串，用作任务／请求 id。
String randomHexId([int length = 32]) {
  final random = Random.secure();
  return List.generate(
    length,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
}

/// 带连字符的 UUID v4 形式随机串（火山、腾讯要求）。
String randomUuid() {
  final hex = randomHexId();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}-'
      'a${hex.substring(17, 20)}-${hex.substring(20, 32)}';
}
