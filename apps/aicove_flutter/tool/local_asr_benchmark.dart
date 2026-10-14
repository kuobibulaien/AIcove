// Local (sherpa-onnx) ASR benchmark for voice calls: accuracy, compute cost
// and end-of-turn latency on 16 kHz mono WAV clips with reference text.
//
// Usage (from apps/aicove_flutter):
//   tool/flutterw --dart run tool/local_asr_benchmark.dart \
//     --models <dir> --clips <dir> [--silence 0.5]
//     [--gain 0.03] [--sense-voice-only]
//
// --gain scales every clip to simulate a quiet microphone. SenseVoice is
// insensitive to pure digital gain: 3% volume measured 6.2% CER vs 6.8%.
//
// <models> holds the extracted sherpa-onnx model folders and
// silero_vad_v5.onnx. <clips> holds pairs of `name.wav` + `name.txt`.
// Each clip is followed by 2 s of silence, like a live mic after the user
// stops talking. Latency is measured on the audio timeline plus the actual
// decode time, so it is independent of the machine's idle state.

import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const _sampleRate = 16000;
const _chunk = 1600; // 100 ms

Future<void> main(List<String> argv) async {
  String? modelsDir;
  String? clipsDir;
  var silence = 0.5;
  var gain = 1.0;
  var senseVoiceOnly = false;
  for (var i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--models':
        modelsDir = argv[++i];
      case '--clips':
        clipsDir = argv[++i];
      case '--silence':
        silence = double.parse(argv[++i]);
      case '--gain':
        gain = double.parse(argv[++i]);
      case '--sense-voice-only':
        senseVoiceOnly = true;
      default:
        throw ArgumentError('Unknown option ${argv[i]}');
    }
  }
  if (modelsDir == null || clipsDir == null) {
    stderr.writeln('Usage: --models <dir> --clips <dir> [--silence 0.5]');
    exit(64);
  }

  sherpa.initBindings(); // Dart CLI resolves the native library itself.
  final clips = _loadClips(clipsDir, gain);
  stdout.writeln(
    'clips: ${clips.length}, end-of-turn silence: ${silence}s, '
    'gain: $gain\n',
  );

  final engines = <_Engine>[
    if (!senseVoiceOnly) ...[
      _StreamingEngine.smallCtc(modelsDir, silence),
      _StreamingEngine.xAsr(modelsDir, silence),
    ],
    _VadSenseVoiceEngine(modelsDir, silence),
  ];
  for (final engine in engines) {
    stdout.writeln('=== ${engine.name} (load ${engine.loadMs}ms) ===');
    final rows = <_Row>[];
    for (final clip in clips) {
      final row = engine.run(clip);
      rows.add(row);
      stdout.writeln(
        '${clip.name.padRight(14)} cer ${_pct(row.cer)}  '
        'endpoint +${row.endpointMs ?? '-'}ms  '
        'early cuts ${row.earlyCuts}  rtf ${row.rtf.toStringAsFixed(3)}  '
        '"${row.text}"',
      );
    }
    final cer = rows.map((r) => r.cer).reduce((a, b) => a + b) / rows.length;
    final eps = rows.map((r) => r.endpointMs).whereType<int>().toList();
    final avgEp = eps.isEmpty
        ? null
        : eps.reduce((a, b) => a + b) ~/ eps.length;
    final cuts = rows.map((r) => r.earlyCuts).reduce((a, b) => a + b);
    final rtf = rows.map((r) => r.rtf).reduce((a, b) => a + b) / rows.length;
    stdout.writeln(
      '-- avg cer ${_pct(cer)}, avg endpoint +${avgEp}ms, '
      'early cuts $cuts, avg rtf ${rtf.toStringAsFixed(3)}\n',
    );
    engine.free();
  }
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

class _Clip {
  _Clip(this.name, this.samples, this.reference, this.speechEndMs);

  final String name;
  final Float32List samples; // clip + 2 s trailing silence
  final String reference;
  final int speechEndMs;
}

List<_Clip> _loadClips(String dir, double gain) {
  final wavs =
      Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.wav'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final wav in wavs)
      () {
        final bytes = wav.readAsBytesSync();
        final pcm = ByteData.sublistView(bytes, _wavDataOffset(bytes));
        final n = pcm.lengthInBytes ~/ 2;
        final samples = Float32List(n + 2 * _sampleRate);
        var lastLoud = 0;
        for (var i = 0; i < n; i++) {
          final v = pcm.getInt16(i * 2, Endian.little);
          samples[i] = v / 32768 * gain;
          if (v.abs() > 800) lastLoud = i;
        }
        final base = wav.path.substring(0, wav.path.length - 4);
        return _Clip(
          base.split('/').last,
          samples,
          File('$base.txt').readAsStringSync().trim(),
          lastLoud * 1000 ~/ _sampleRate,
        );
      }(),
  ];
}

int _wavDataOffset(Uint8List wav) {
  final d = ByteData.sublistView(wav);
  var pos = 12;
  while (pos + 8 <= wav.length) {
    final id = String.fromCharCodes(wav.sublist(pos, pos + 4));
    final size = d.getUint32(pos + 4, Endian.little);
    if (id == 'data') return pos + 8;
    pos += 8 + size + (size & 1);
  }
  throw const FormatException('WAV data chunk not found');
}

class _Row {
  _Row(this.text, this.cer, this.endpointMs, this.earlyCuts, this.rtf);

  final String text;
  final double cer;

  /// Audio time after speech end when the final result is available,
  /// including decode time.
  final int? endpointMs;

  /// Turn ends detected before the speaker actually finished.
  final int earlyCuts;
  final double rtf;
}

abstract class _Engine {
  String get name;
  int get loadMs;
  _Row run(_Clip clip);
  void free();
}

/// Streaming recognizer with built-in endpointing (rule 2 = trailing
/// silence after some speech).
class _StreamingEngine implements _Engine {
  _StreamingEngine(this.name, sherpa.OnlineModelConfig model, double silence) {
    final w = Stopwatch()..start();
    recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: model,
        rule2MinTrailingSilence: silence,
      ),
    );
    loadMs = w.elapsedMilliseconds;
  }

  factory _StreamingEngine.smallCtc(String dir, double silence) {
    const m = 'sherpa-onnx-streaming-zipformer-small-ctc-zh-int8-2025-04-01';
    return _StreamingEngine(
      'streaming zipformer small ctc (20MB)',
      sherpa.OnlineModelConfig(
        zipformer2Ctc: sherpa.OnlineZipformer2CtcModelConfig(
          model: '$dir/$m/model.int8.onnx',
        ),
        tokens: '$dir/$m/tokens.txt',
        numThreads: 2,
        debug: false,
      ),
      silence,
    );
  }

  factory _StreamingEngine.xAsr(String dir, double silence) {
    const m =
        'sherpa-onnx-x-asr-160ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05';
    return _StreamingEngine(
      'streaming x-asr 160ms transducer punct (127MB)',
      sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: '$dir/$m/encoder.int8.onnx',
          decoder: '$dir/$m/decoder.onnx',
          joiner: '$dir/$m/joiner.int8.onnx',
        ),
        tokens: '$dir/$m/tokens.txt',
        numThreads: 2,
        debug: false,
      ),
      silence,
    );
  }

  @override
  final String name;
  @override
  late final int loadMs;
  late final sherpa.OnlineRecognizer recognizer;

  @override
  _Row run(_Clip clip) {
    final stream = recognizer.createStream();
    final parts = <String>[];
    var compute = 0;
    int? endpointMs;
    var earlyCuts = 0;
    for (var off = 0; off < clip.samples.length; off += _chunk) {
      final end = (off + _chunk).clamp(0, clip.samples.length);
      final w = Stopwatch()..start();
      stream.acceptWaveform(
        samples: Float32List.sublistView(clip.samples, off, end),
        sampleRate: _sampleRate,
      );
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      final endpoint = recognizer.isEndpoint(stream);
      final text = endpoint ? recognizer.getResult(stream).text.trim() : '';
      final cost = w.elapsedMilliseconds;
      compute += cost;
      if (endpoint) {
        recognizer.reset(stream);
        if (text.isEmpty) continue;
        parts.add(text);
        final at = end * 1000 ~/ _sampleRate;
        if (at < clip.speechEndMs) {
          earlyCuts++;
        } else {
          endpointMs ??= at - clip.speechEndMs + cost;
        }
      }
    }
    stream.inputFinished();
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    final tail = recognizer.getResult(stream).text.trim();
    if (tail.isNotEmpty) parts.add(tail);
    stream.free();
    final text = parts.join(' ');
    return _Row(
      text,
      _cer(clip.reference, text),
      endpointMs,
      earlyCuts,
      compute / (clip.samples.length * 1000 / _sampleRate),
    );
  }

  @override
  void free() => recognizer.free();
}

/// Silero VAD cuts utterances; SenseVoice decodes each finished segment.
class _VadSenseVoiceEngine implements _Engine {
  _VadSenseVoiceEngine(String dir, this.silence) {
    const m = 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09';
    final w = Stopwatch()..start();
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: '$dir/$m/model.int8.onnx',
            language: 'zh',
            useInverseTextNormalization: true,
          ),
          tokens: '$dir/$m/tokens.txt',
          numThreads: 2,
          debug: false,
        ),
      ),
    );
    vadConfig = sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: '$dir/silero_vad_v5.onnx',
        minSilenceDuration: silence,
        maxSpeechDuration: 30,
      ),
      debug: false,
    );
    loadMs = w.elapsedMilliseconds;
  }

  final double silence;
  @override
  String get name => 'silero vad + sense-voice (158MB)';
  @override
  late final int loadMs;
  late final sherpa.OfflineRecognizer recognizer;
  late final sherpa.VadModelConfig vadConfig;

  @override
  _Row run(_Clip clip) {
    final vad = sherpa.VoiceActivityDetector(
      config: vadConfig,
      bufferSizeInSeconds: 60,
    );
    const window = 512;
    final parts = <String>[];
    var compute = 0;
    int? endpointMs;
    var earlyCuts = 0;
    for (var off = 0; off + window <= clip.samples.length; off += window) {
      final w = Stopwatch()..start();
      vad.acceptWaveform(
        Float32List.sublistView(clip.samples, off, off + window),
      );
      var cost = w.elapsedMilliseconds;
      while (!vad.isEmpty()) {
        final segment = vad.front();
        vad.pop();
        final d = Stopwatch()..start();
        final stream = recognizer.createStream();
        stream.acceptWaveform(
          samples: segment.samples,
          sampleRate: _sampleRate,
        );
        recognizer.decode(stream);
        final text = recognizer.getResult(stream).text.trim();
        stream.free();
        cost += d.elapsedMilliseconds;
        if (text.isEmpty) continue;
        parts.add(text);
        final at = (off + window) * 1000 ~/ _sampleRate;
        if (at < clip.speechEndMs) {
          earlyCuts++;
        } else {
          endpointMs ??= at - clip.speechEndMs + d.elapsedMilliseconds;
        }
      }
      compute += cost;
    }
    vad.free();
    final text = parts.join(' ');
    return _Row(
      text,
      _cer(clip.reference, text),
      endpointMs,
      earlyCuts,
      compute / (clip.samples.length * 1000 / _sampleRate),
    );
  }

  @override
  void free() => recognizer.free();
}

/// Character error rate, ignoring punctuation, spaces and letter case.
double _cer(String reference, String hypothesis) {
  final strip = RegExp(r'[\s\p{P}\p{S}]', unicode: true);
  final r = reference.toLowerCase().replaceAll(strip, '').runes.toList();
  final h = hypothesis.toLowerCase().replaceAll(strip, '').runes.toList();
  if (r.isEmpty) return h.isEmpty ? 0 : 1;
  var prev = List<int>.generate(h.length + 1, (i) => i);
  for (var i = 1; i <= r.length; i++) {
    final cur = List<int>.filled(h.length + 1, 0)..[0] = i;
    for (var j = 1; j <= h.length; j++) {
      final sub = prev[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1);
      cur[j] = [
        sub,
        prev[j] + 1,
        cur[j - 1] + 1,
      ].reduce((a, b) => a < b ? a : b);
    }
    prev = cur;
  }
  return prev[h.length] / r.length;
}
