import 'dart:typed_data';

import 'package:aicove_flutter/src/features/voice_call/data/device_call_audio.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:mp_audio_stream/mp_audio_stream.dart';

class _Stream implements AudioStream {
  final pushed = <Float32List>[];
  var released = false;

  @override
  int init({
    int bufferMilliSec = 3000,
    int waitingBufferMilliSec = 100,
    int channels = 1,
    int sampleRate = 44100,
    bool fadeOnExhaust = false,
  }) => 0;
  @override
  void uninit() => released = true;
  @override
  void resume() {}
  @override
  int push(Float32List buf) {
    pushed.add(buf);
    return 0;
  }

  @override
  AudioStreamStat stat() => AudioStreamStat.empty();
  @override
  void resetStat() {}
}

void main() {
  test(
    'turning the speaker off and on re-pushes only the unplayed tail',
    () async {
      final streams = <_Stream>[];
      var now = DateTime(2026, 10, 12);
      final output = StreamCallAudioOutput(
        create: () => (streams..add(_Stream())).last,
        now: () => now,
      );
      await output.start(1000);
      // 1000 个采样 = 1 秒，值全是 0.5。
      final pcm = ByteData(2000);
      for (var i = 0; i < 1000; i++) {
        pcm.setInt16(i * 2, 16384, Endian.little);
      }
      output.push(pcm.buffer.asUint8List());
      now = now.add(const Duration(milliseconds: 400));

      output.silenced = true;
      expect(streams, hasLength(2));
      expect(streams.first.released, isTrue);
      final muted = streams.last.pushed.single;
      expect(muted.length, 600);
      expect(muted.every((v) => v == 0), isTrue);
      // 计时不受影响：已播 400 ms，还剩 600 ms。
      expect(output.played, const Duration(milliseconds: 400));
      expect(output.buffered, const Duration(milliseconds: 600));

      now = now.add(const Duration(milliseconds: 200));
      output.silenced = false;
      final resumed = streams.last.pushed.single;
      expect(resumed.length, 400);
      expect(resumed.every((v) => v == 0.5), isTrue);

      // 关着扬声器时推入的新音频也是无声的。
      output.silenced = true;
      output.push(pcm.buffer.asUint8List());
      expect(streams.last.pushed.last.every((v) => v == 0), isTrue);
    },
  );

  test('played audio is not retained over a long call', () async {
    var now = DateTime(2026, 10, 12);
    final output = StreamCallAudioOutput(create: _Stream.new, now: () => now);
    await output.start(1000);
    final pcm = Uint8List(200); // 100 个采样 = 100 ms
    for (var i = 0; i < 600; i++) {
      output.push(pcm);
      now = now.add(const Duration(milliseconds: 100));
    }
    // 十分钟的音频推完，只留住还没播的一小段。
    expect(output.retainedSamples, lessThanOrEqualTo(200));
    await output.stop();
    expect(output.retainedSamples, 0);
  });

  test('system voice processing is only used on phones', () {
    expect(callVoiceProcessingSupported(TargetPlatform.android), isTrue);
    expect(callVoiceProcessingSupported(TargetPlatform.iOS), isTrue);
    expect(callVoiceProcessingSupported(TargetPlatform.macOS), isFalse);
    expect(callVoiceProcessingSupported(TargetPlatform.windows), isFalse);
  });
}
