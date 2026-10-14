import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show TargetPlatform, visibleForTesting;
import 'package:mp_audio_stream/mp_audio_stream.dart';
import 'package:record/record.dart';

import '../domain/speech_recognizer_port.dart';
import '../domain/voice_call_ports.dart';

/// 系统语音处理（回声消除、降噪、自动增益）只在手机上开。
///
/// macOS 上 `record` 打开 AVAudioEngine 的语音处理后，输入回调收到的全是零
/// （真人说话也一样，2026-10-12 实测），所以桌面端一律关掉；桌面通话本来就
/// 半双工，不靠回声消除（见 `VoiceCallSession.allowBargeIn`）。
bool callVoiceProcessingSupported(TargetPlatform platform) =>
    platform == TargetPlatform.android || platform == TargetPlatform.iOS;

/// 麦克风采集（`record` 插件），按 [voiceProcessing] 开关系统语音处理。
class RecordCallAudioInput implements CallAudioInputPort {
  RecordCallAudioInput({AudioRecorder? recorder, this.voiceProcessing = true})
    : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  /// 系统回声消除＋降噪＋自动增益，见 [callVoiceProcessingSupported]；手机上
  /// 也可用 `--dart-define=AICOVE_CALL_NO_VOICE_PROCESSING=true` 关掉。
  final bool voiceProcessing;

  @override
  Future<Stream<Uint8List>> start() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('没有麦克风权限');
    }
    return _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: speechRecognizerSampleRate,
        numChannels: 1,
        echoCancel: voiceProcessing,
        noiseSuppress: voiceProcessing,
        autoGain: voiceProcessing,
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _recorder.stop();
    await _recorder.dispose();
  }
}

/// 流式 PCM 播放（`mp_audio_stream`，miniaudio）。
///
/// 插件没有“已播放进度”和“清空缓冲”接口：进度按推入的音频时长和墙钟估算
/// （缓冲耗尽后从下次推入时重新计时）；清空通过重建播放流实现。
/// 合成速度快于实时播放，所以缓冲开到 [bufferSeconds] 秒，避免超出部分被丢弃。
class StreamCallAudioOutput implements CallAudioOutputPort {
  StreamCallAudioOutput({
    AudioStream Function()? create,
    this.bufferSeconds = 60,
    DateTime Function()? now,
  }) : _create = create ?? getAudioStream,
       _now = now ?? DateTime.now;

  final AudioStream Function() _create;
  final int bufferSeconds;
  final DateTime Function() _now;

  AudioStream? _stream;
  int _sampleRate = 24000;
  int _pushedMs = 0;
  DateTime? _playEndAt;

  @override
  Future<void> start(int sampleRate) async {
    _sampleRate = sampleRate;
    _open();
  }

  /// 还没播完的采样（按播放进度淘汰已播部分），用于切换扬声器时重推。
  final List<Float32List> _chunks = [];
  bool _silenced = false;

  @override
  bool get silenced => _silenced;

  /// 当前留住的采样数，测试用来确认已播部分会被淘汰。
  @visibleForTesting
  int get retainedSamples => _chunks.fold(0, (n, c) => n + c.length);

  @override
  set silenced(bool value) {
    if (value == _silenced) return;
    _silenced = value;
    final stream = _stream;
    if (stream == null) return;
    // 插件没有音量接口：重建播放流，把还没播的部分按新状态重新推入，计时不变。
    final left = buffered.inMilliseconds * _sampleRate ~/ 1000;
    final pushedMs = _pushedMs;
    final playEndAt = _playEndAt;
    final tail = _tail(left);
    _open();
    _pushedMs = pushedMs;
    _playEndAt = playEndAt;
    if (tail.isNotEmpty) {
      _chunks.add(tail);
      _stream!.push(_silenced ? Float32List(tail.length) : tail);
    }
  }

  /// 最近推入的 [samples] 个采样。
  Float32List _tail(int samples) {
    final out = Float32List(math.max(0, samples));
    var filled = out.length;
    for (final chunk in _chunks.reversed) {
      if (filled == 0) break;
      final take = math.min(filled, chunk.length);
      out.setRange(filled - take, filled, chunk, chunk.length - take);
      filled -= take;
    }
    return filled == 0 ? out : Float32List.sublistView(out, filled);
  }

  void _open() {
    _stream?.uninit();
    _chunks.clear();
    final stream = _create();
    final code = stream.init(
      bufferMilliSec: bufferSeconds * 1000,
      waitingBufferMilliSec: 60,
      channels: 1,
      sampleRate: _sampleRate,
      fadeOnExhaust: true,
    );
    if (code != 0) throw StateError('音频输出初始化失败（$code）');
    stream.resume();
    _stream = stream;
    _pushedMs = 0;
    _playEndAt = null;
  }

  @override
  void push(Uint8List pcm16) {
    final stream = _stream;
    if (stream == null || pcm16.length < 2) return;
    final data = ByteData.sublistView(pcm16);
    final samples = Float32List(pcm16.length ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768;
    }
    _chunks.add(samples);
    stream.push(_silenced ? Float32List(samples.length) : samples);
    final ms = samples.length * 1000 ~/ _sampleRate;
    final now = _now();
    final end = _playEndAt;
    _playEndAt = (end == null || end.isBefore(now) ? now : end).add(
      Duration(milliseconds: ms),
    );
    _pushedMs += ms;
    _dropPlayed();
  }

  /// 只留住还没播的尾部，长通话里不累积已播音频。
  void _dropPlayed() {
    final keep = buffered.inMilliseconds * _sampleRate ~/ 1000;
    var total = _chunks.fold(0, (n, c) => n + c.length);
    while (_chunks.length > 1 && total - _chunks.first.length >= keep) {
      total -= _chunks.removeAt(0).length;
    }
  }

  @override
  Duration get buffered {
    final end = _playEndAt;
    if (end == null) return Duration.zero;
    final left = end.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  @override
  Duration get played =>
      Duration(milliseconds: math.max(0, _pushedMs - buffered.inMilliseconds));

  @override
  void clear() {
    if (_stream != null) _open();
  }

  @override
  Future<void> stop() async {
    _stream?.uninit();
    _stream = null;
    _chunks.clear();
  }
}
