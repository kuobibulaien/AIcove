import 'dart:io';
import 'dart:typed_data';

import 'package:aicove_flutter/src/features/voice_call/data/sherpa_local_speech_recognizer.dart';
import 'package:aicove_flutter/src/features/voice_call/domain/speech_recognizer_port.dart';
import 'package:flutter_test/flutter_test.dart';

/// 需要真实模型与原生库，默认跳过。运行方式见
/// `docs/04_功能模块规范/语音通话/README.md`「本地识别」。
final _models = Platform.environment['AICOVE_SHERPA_MODELS'];
final _native = Platform.environment['AICOVE_SHERPA_NATIVE'];
final _clip = Platform.environment['AICOVE_SHERPA_CLIP'];

void main() {
  test(
    'recognizes a spoken sentence and reports speech start first',
    () async {
      final wav = File(_clip!).readAsBytesSync();
      final pcm = Uint8List.sublistView(wav, _wavDataOffset(wav));
      final recognizer = SherpaLocalSpeechRecognizer(
        models: SherpaLocalModelFiles.inDirectory(_models!),
        nativeLibDir: _native,
      );
      final events = <SpeechRecognitionEvent>[];
      recognizer.events.listen(events.add);
      await recognizer.start();

      const frame = 3200; // 100 ms
      for (var off = 0; off < pcm.length; off += frame) {
        recognizer.addAudio(
          Uint8List.sublistView(pcm, off, (off + frame).clamp(0, pcm.length)),
        );
      }
      recognizer.addAudio(Uint8List(32000)); // 1 s silence
      await recognizer.stop();
      await recognizer.dispose();

      expect(events.first, isA<SpeechStarted>());
      final text = events.whereType<SpeechFinal>().map((e) => e.text).join();
      expect(text, contains('面试'));
      expect(text, contains('紧张'));
      expect(events.whereType<SpeechFinal>(), hasLength(1));
      // 每段先报结束再给定稿文字。
      final ended = events.indexWhere((e) => e is SpeechEnded);
      expect(ended, greaterThan(0));
      expect(events[ended + 1], isA<SpeechFinal>());
    },
    // flutter test 中无法按包名解析原生库，需显式给出 sherpa_onnx_<平台>/<平台> 目录。
    skip: _models == null || _clip == null || _native == null
        ? '设置 AICOVE_SHERPA_MODELS / AICOVE_SHERPA_NATIVE / AICOVE_SHERPA_CLIP 后运行'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
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
