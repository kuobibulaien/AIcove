import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../domain/speech_recognizer_port.dart';

/// 本地识别所需的模型文件（由用户在应用内下载，ADR0074）。
class SherpaLocalModelFiles {
  const SherpaLocalModelFiles({
    required this.vadModel,
    required this.senseVoiceModel,
    required this.tokens,
  });

  /// 按下载目录的约定布局解析：
  /// `<dir>/silero_vad_v5.onnx` 与 `<dir>/<senseVoiceDirName>/{model.int8.onnx,tokens.txt}`。
  factory SherpaLocalModelFiles.inDirectory(String dir) {
    const sv = senseVoiceDirName;
    return SherpaLocalModelFiles(
      vadModel: '$dir/silero_vad_v5.onnx',
      senseVoiceModel: '$dir/$sv/model.int8.onnx',
      tokens: '$dir/$sv/tokens.txt',
    );
  }

  static const senseVoiceDirName =
      'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09';

  final String vadModel;
  final String senseVoiceModel;
  final String tokens;
}

/// 本地离线识别：Silero VAD 判断一句话何时说完，SenseVoice 识别整句。
///
/// 选型依据见 `docs/04_功能模块规范/语音通话/README.md`：同一批样本错字率约 7%，
/// 0.3 秒静音阈值下单句不误切。识别在后台 isolate 中运行，不阻塞界面。
/// SenseVoice 不出中间结果，因此只发 [SpeechStarted] 与 [SpeechFinal]。
class SherpaLocalSpeechRecognizer implements SpeechRecognizerPort {
  SherpaLocalSpeechRecognizer({
    required this.models,
    this.endOfTurnSilence = 0.3,
    this.numThreads = 2,
    this.nativeLibDir,
  });

  final SherpaLocalModelFiles models;

  /// 说完一句话后需要的静音秒数。
  final double endOfTurnSilence;
  final int numThreads;

  /// 原生库目录；应用内运行时为 null（由插件随包加载），桌面测试时传入。
  final String? nativeLibDir;

  final _events = StreamController<SpeechRecognitionEvent>.broadcast();
  Isolate? _isolate;
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Completer<void>? _flushed;
  Completer<void>? _closed;

  @override
  Stream<SpeechRecognitionEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (_isolate != null) return;
    final fromWorker = ReceivePort();
    _fromWorker = fromWorker;
    final ready = Completer<void>();
    fromWorker.listen((message) {
      switch (message) {
        case SendPort port:
          _toWorker = port;
        case 'ready':
          ready.complete();
        case 'started':
          _events.add(const SpeechStarted());
        case 'ended':
          _events.add(const SpeechEnded());
        case ('final', String text):
          _events.add(SpeechFinal(text));
        case 'flushed':
          _flushed?.complete();
        case 'closed':
          _closed?.complete();
        case ('error', String error):
          if (!ready.isCompleted) {
            // worker 初始化失败后已自行退出，不再等它回 'closed'。
            _toWorker = null;
            ready.completeError(StateError(error));
          } else {
            _events.add(SpeechRecognitionFailed(error));
          }
      }
    });
    _isolate = await Isolate.spawn(
      _workerMain,
      _WorkerConfig(
        replyTo: fromWorker.sendPort,
        models: models,
        endOfTurnSilence: endOfTurnSilence,
        numThreads: numThreads,
        nativeLibDir: nativeLibDir,
      ),
      debugName: 'sherpa_local_asr',
    );
    try {
      await ready.future;
    } catch (_) {
      await dispose();
      rethrow;
    }
  }

  @override
  void addAudio(Uint8List pcm16) {
    _toWorker?.send(TransferableTypedData.fromList([pcm16]));
  }

  @override
  Future<void> stop() async {
    final port = _toWorker;
    if (port == null) return;
    _flushed = Completer<void>();
    port.send('flush');
    await _flushed!.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {},
    );
  }

  @override
  Future<void> dispose() async {
    final port = _toWorker;
    _toWorker = null;
    if (port != null) {
      // 让 worker 自己释放原生对象后退出；超时才强杀。
      _closed = Completer<void>();
      port.send('close');
      await _closed!.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _fromWorker?.close();
    _fromWorker = null;
    if (!_events.isClosed) await _events.close();
  }
}

class _WorkerConfig {
  const _WorkerConfig({
    required this.replyTo,
    required this.models,
    required this.endOfTurnSilence,
    required this.numThreads,
    required this.nativeLibDir,
  });

  final SendPort replyTo;
  final SherpaLocalModelFiles models;
  final double endOfTurnSilence;
  final int numThreads;
  final String? nativeLibDir;
}

const _vadWindow = 512;

/// 句首补回的音频秒数：VAD 判定开口时已错过第一个字的起音。
const _preRollSeconds = 0.25;

void _workerMain(_WorkerConfig config) {
  final reply = config.replyTo;
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);

  // 分步持有原生对象：后一步失败时释放已建好的，避免重复拨号累积泄漏。
  sherpa.OfflineRecognizer? createdRecognizer;
  final sherpa.OfflineRecognizer recognizer;
  final sherpa.VoiceActivityDetector vad;
  try {
    sherpa.initBindings(config.nativeLibDir);
    recognizer = createdRecognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: config.models.senseVoiceModel,
            language: 'zh',
            useInverseTextNormalization: true,
          ),
          tokens: config.models.tokens,
          numThreads: config.numThreads,
          debug: false,
        ),
      ),
    );
    vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: config.models.vadModel,
          minSilenceDuration: config.endOfTurnSilence,
          maxSpeechDuration: 30,
        ),
        sampleRate: speechRecognizerSampleRate,
        debug: false,
      ),
      bufferSizeInSeconds: 60,
    );
  } catch (e) {
    createdRecognizer?.free();
    reply.send(('error', '$e'));
    inbox.close();
    return;
  }

  final history = _SampleHistory(maxSeconds: 40);
  final pending = Float32List(_vadWindow);
  var pendingLength = 0;
  var speaking = false;

  void drainSegments() {
    while (!vad.isEmpty()) {
      final segment = vad.front();
      vad.pop();
      final preRoll = (_preRollSeconds * speechRecognizerSampleRate).round();
      final samples =
          history.slice(
            segment.start - preRoll,
            segment.start + segment.samples.length,
          ) ??
          segment.samples;
      final stream = recognizer.createStream();
      stream.acceptWaveform(
        samples: samples,
        sampleRate: speechRecognizerSampleRate,
      );
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text.trim();
      stream.free();
      if (text.isNotEmpty) reply.send(('final', text));
    }
  }

  void feed(Float32List window) {
    history.add(window);
    vad.acceptWaveform(window);
    final detected = vad.isDetected();
    if (detected && !speaking) reply.send('started');
    // 先报“这段结束”，紧跟着的定稿文字（若识别出字）由 drainSegments 发出。
    if (!detected && speaking) reply.send('ended');
    speaking = detected;
    drainSegments();
  }

  inbox.listen((message) {
    switch (message) {
      case TransferableTypedData data:
        final bytes = ByteData.sublistView(data.materialize().asUint8List());
        for (var i = 0; i + 1 < bytes.lengthInBytes; i += 2) {
          pending[pendingLength++] = bytes.getInt16(i, Endian.little) / 32768;
          if (pendingLength == _vadWindow) {
            feed(Float32List.fromList(pending));
            pendingLength = 0;
          }
        }
      case 'flush':
        vad.flush();
        if (speaking) reply.send('ended');
        drainSegments();
        speaking = false;
        reply.send('flushed');
      case 'close':
        vad.free();
        recognizer.free();
        reply.send('closed');
        inbox.close();
    }
  });
  reply.send('ready');
}

/// 最近若干秒的音频，按绝对采样序号切片，用于给 VAD 片段补句首。
class _SampleHistory {
  _SampleHistory({required int maxSeconds})
    : _capacity = maxSeconds * speechRecognizerSampleRate,
      _buffer = Float32List(maxSeconds * speechRecognizerSampleRate * 2);

  final int _capacity;
  Float32List _buffer;
  int _length = 0;

  /// [_buffer] 第 0 个采样对应的绝对序号。
  int _origin = 0;

  void add(Float32List samples) {
    if (_length + samples.length > _buffer.length) {
      final keep = _capacity.clamp(0, _length);
      final drop = _length - keep;
      _buffer = Float32List(_buffer.length)..setRange(0, keep, _buffer, drop);
      _length = keep;
      _origin += drop;
    }
    _buffer.setRange(_length, _length + samples.length, samples);
    _length += samples.length;
  }

  /// 返回绝对序号 [start, end) 的采样；起点过早时截到可用范围，终点越界返回 null。
  Float32List? slice(int start, int end) {
    final from = (start - _origin).clamp(0, _length);
    final to = end - _origin;
    if (to > _length || to <= from) return null;
    return Float32List.fromList(Float32List.sublistView(_buffer, from, to));
  }
}
