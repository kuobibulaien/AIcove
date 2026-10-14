import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../domain/voice_call_ports.dart';
import 'msgpack.dart';

/// 通话里给模型的 Fish Audio 语气控制说明：方括号标签直接写在台词里，由合成读成
/// 语气而不念出来；字幕和通话记录显示时去掉（[CallTurn.spokenText]）。
const String kFishAudioCallSpeechGuide = '''你的声音由 Fish Audio 合成，可以在台词里用方括号写语气和声音表演，方括号里的内容不会被念出来：
- 情绪与说话方式写在受影响的话前面，比如 [笑着说]、[小声嘀咕]、[委屈巴巴]、[兴奋地抢着说]、[懒洋洋]，按人设和当下情绪自己写，描述要具体、有表演感，不要只写“开心”“难过”这种平淡词。
- 呼吸、笑声、停顿等声音可以穿插在词句之间，比如 [轻笑]、[叹气]、[吸了口气]、[哭腔]、[短停顿]、[噗嗤一声笑出来]。
- 每句话都尽量带上标签，情绪变化处可以叠用，比如“[愣了一下]诶？[忍不住笑]你认真的啊[短停顿]那我可不客气啦”。
- 标签后面必须紧跟要说的话，只用方括号，不要用圆括号或其它符号。''';

typedef WebSocketConnector =
    Future<WebSocket> Function(Uri uri, Map<String, String> headers);

/// Fish Audio 实时合成（WebSocket＋MessagePack），复用角色音色预设里的 reference_id。
///
/// 实测约束（`docs/04_功能模块规范/语音通话/README.md`）：
/// - 空闲约 30 秒会被服务端断开，所以每 [pingInterval] 发一次 WebSocket ping；
/// - 协议没有取消事件，已 flush 的文字仍会继续推送音频，所以打断时关掉当前连接，
///   切到提前建好的备用连接，避免重新握手（约 0.9 秒）。
class FishAudioStreamingTts implements StreamingTtsPort {
  FishAudioStreamingTts({
    required this.apiKey,
    required this.referenceId,
    this.model = 's2.1-pro',
    this.latency = 'balanced',
    this.endpoint = defaultEndpoint,
    this.pingInterval = const Duration(seconds: 20),
    this.sampleRate = 24000,
    WebSocketConnector? connect,
  }) : _connect =
           connect ??
           ((uri, headers) =>
               WebSocket.connect(uri.toString(), headers: headers));

  static const defaultEndpoint = 'wss://api.fish.audio/v1/tts/live';

  final String apiKey;
  final String referenceId;
  final String model;
  final String latency;
  final String endpoint;
  final Duration pingInterval;
  @override
  final int sampleRate;
  final WebSocketConnector _connect;

  final _audio = StreamController<Uint8List>.broadcast();
  _FishConnection? _active;
  _FishConnection? _spare;
  bool _closed = false;

  @override
  Stream<Uint8List> get audio => _audio.stream;

  @override
  Future<void> open() async {
    _active = _newConnection();
    _spare = _newConnection();
    await _active!.ready;
  }

  @override
  void speak(String segment) {
    if (_closed || segment.trim().isEmpty) return;
    var active = _active;
    // 服务端断开了（例如空闲超时），换一条连接再说。
    if (active == null || active.isDead) {
      active = _promoteSpare();
    }
    active.send(segment);
  }

  @override
  Future<void> interrupt() async {
    final old = _active;
    _promoteSpare();
    await old?.close();
  }

  @override
  Future<void> close() async {
    _closed = true;
    final connections = [_active, _spare];
    _active = null;
    _spare = null;
    for (final c in connections) {
      await c?.close();
    }
    await _audio.close();
  }

  _FishConnection _promoteSpare() {
    final spare = _spare;
    final next = spare != null && !spare.isDead ? spare : _newConnection();
    _active = next;
    _spare = _closed ? null : _newConnection();
    return next;
  }

  _FishConnection _newConnection() {
    late final _FishConnection connection;
    connection = _FishConnection(
      connect: () => _connect(Uri.parse(endpoint), {
        'Authorization': 'Bearer $apiKey',
        'model': model,
      }),
      startRequest: {
        'text': '',
        'reference_id': referenceId,
        'format': 'pcm',
        'sample_rate': sampleRate,
        'latency': latency,
      },
      pingInterval: pingInterval,
      // 只转发当前连接的音频；被打断的旧连接即使还在推送也丢掉。
      onAudio: (pcm) {
        if (identical(_active, connection) && !_audio.isClosed) {
          _audio.add(pcm);
        }
      },
    );
    return connection;
  }
}

class _FishConnection {
  _FishConnection({
    required Future<WebSocket> Function() connect,
    required Map<String, Object?> startRequest,
    required Duration pingInterval,
    required void Function(Uint8List pcm) onAudio,
  }) {
    ready = connect().then((socket) {
      if (_closing) {
        unawaited(socket.close());
        throw StateError('closed');
      }
      socket.pingInterval = pingInterval;
      _socket = socket;
      socket.add(Msgpack.encode({'event': 'start', 'request': startRequest}));
      socket.listen(
        (data) {
          if (data is! List<int>) return;
          final message = Msgpack.decode(Uint8List.fromList(data));
          if (message is! Map) return;
          if (message['event'] == 'audio') {
            final audio = message['audio'];
            if (audio is Uint8List && audio.isNotEmpty) onAudio(audio);
          } else if (message['event'] == 'finish') {
            isDead = true;
          }
        },
        onError: (Object _) => isDead = true,
        onDone: () => isDead = true,
      );
      for (final segment in _pending) {
        _sendNow(segment);
      }
      _pending.clear();
    });
    ready.catchError((Object _) {
      isDead = true;
    });
  }

  late final Future<void> ready;
  WebSocket? _socket;
  final _pending = <String>[];
  bool isDead = false;
  bool _closing = false;

  void send(String segment) {
    if (_socket == null) {
      _pending.add(segment);
    } else {
      _sendNow(segment);
    }
  }

  void _sendNow(String segment) {
    _socket!
      ..add(Msgpack.encode({'event': 'text', 'text': segment}))
      ..add(Msgpack.encode({'event': 'flush'}));
  }

  Future<void> close() async {
    _closing = true;
    isDead = true;
    _pending.clear();
    await _socket?.close();
  }
}
