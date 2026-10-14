import 'dart:async';
import 'dart:typed_data';

import 'package:aicove_flutter/src/features/voice_call/domain/speech_recognizer_port.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/voice_call_ports.dart';

/// 通话引擎与通话页测试共用的假端口。
class FakeRecognizer implements SpeechRecognizerPort {
  final _events = StreamController<SpeechRecognitionEvent>.broadcast();
  final received = <Uint8List>[];

  /// 设置后 [start] 等它完成，用来模拟建连慢。
  Completer<void>? startGate;

  /// 设置后 [stop] 等它完成，用来模拟识别收尾慢。
  Completer<void>? stopGate;

  /// [stop] 冲出的最后一句。
  String? flushText;
  var started = false;
  var disposed = false;

  void emit(SpeechRecognitionEvent event) => _events.add(event);

  @override
  Stream<SpeechRecognitionEvent> get events => _events.stream;
  @override
  Future<void> start() async {
    await startGate?.future;
    started = true;
  }

  @override
  void addAudio(Uint8List pcm16) => received.add(pcm16);
  @override
  Future<void> stop() async {
    await stopGate?.future;
    final text = flushText;
    if (text != null) {
      _events
        ..add(const SpeechEnded())
        ..add(SpeechFinal(text));
    }
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
  }
}

/// 每段文字合成为「每字 100 ms」的静音 PCM。
class FakeTts implements StreamingTtsPort {
  final _audio = StreamController<Uint8List>.broadcast();
  final spoken = <String>[];
  var interrupts = 0;
  var closed = false;

  /// 关掉后 [speak] 不自动出音频，由 [deliver] 手动送达（模拟合成慢）。
  bool autoAudio = true;

  /// 每个字 200 ms 音频，接近真实语速。
  void deliver(String segment) =>
      _audio.add(Uint8List(segment.runes.length * 6400));

  @override
  int get sampleRate => 16000;
  @override
  Stream<Uint8List> get audio => _audio.stream;
  @override
  Future<void> open() async {}
  @override
  void speak(String segment) {
    spoken.add(segment);
    if (autoAudio) deliver(segment);
  }

  @override
  Future<void> interrupt() async => interrupts++;
  @override
  Future<void> close() async {
    closed = true;
    await _audio.close();
  }
}

class FakeInput implements CallAudioInputPort {
  final mic = StreamController<Uint8List>.broadcast();
  var started = false;
  var stopped = false;
  @override
  Future<Stream<Uint8List>> start() async {
    started = true;
    return mic.stream;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    await mic.close();
  }
}

/// 由测试控制播放进度。
class FakeOutput implements CallAudioOutputPort {
  var pushedMs = 0;
  var playedMs = 0;
  var clears = 0;
  var stopped = false;
  @override
  bool silenced = false;

  /// 模拟重建播放设备失败。
  bool failClear = false;

  void playAll() => playedMs = pushedMs;

  @override
  Future<void> start(int sampleRate) async {}
  @override
  void push(Uint8List pcm16) => pushedMs += pcm16.length * 1000 ~/ 32000;
  @override
  void clear() {
    if (failClear) throw StateError('音频输出初始化失败（-1）');
    clears++;
    pushedMs = 0;
    playedMs = 0;
  }

  @override
  Duration get played => Duration(milliseconds: playedMs);
  @override
  Duration get buffered => Duration(milliseconds: pushedMs - playedMs);
  @override
  Future<void> stop() async => stopped = true;
}

class FakeGenerator implements CallReplyGeneratorPort {
  StreamController<String>? current;
  final requests = <List<CallTurn>>[];

  @override
  Stream<String> streamReply(List<CallTurn> turns) {
    requests.add(turns);
    current = StreamController<String>();
    return current!.stream;
  }
}
