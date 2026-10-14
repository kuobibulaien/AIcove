import 'dart:typed_data';

import '../../../core/models/message_block.dart' show CallTurn;

export '../../../core/models/message_block.dart'
    show CallTurn, stripSpeechTags;

/// 流式语音合成：边收文字片段边吐音频块（PCM16 单声道，采样率见 [sampleRate]）。
///
/// 一次通话保持一个会话；每轮回复用 [speak] 逐段送入，[interrupt] 丢弃已排队的音频。
abstract interface class StreamingTtsPort {
  int get sampleRate;

  /// 合成出的音频块，跨轮次连续输出。
  Stream<Uint8List> get audio;

  /// 预先建立连接，避免第一句话等握手。
  Future<void> open();

  /// 送入一段可以立即合成的文字。
  void speak(String segment);

  /// 丢弃尚未送达的音频，之后可以继续 [speak]。
  Future<void> interrupt();

  Future<void> close();
}

/// 麦克风采集，输出 16 kHz 单声道 PCM16。
abstract interface class CallAudioInputPort {
  Future<Stream<Uint8List>> start();
  Future<void> stop();
}

/// 流式播放 PCM16 单声道音频。
abstract interface class CallAudioOutputPort {
  Future<void> start(int sampleRate);

  void push(Uint8List pcm16);

  /// 清空尚未播放的音频（打断）。
  void clear();

  /// 本轮 [start]／[clear] 以来实际播出的时长。
  Duration get played;

  /// 已推入但尚未播放的时长。
  Duration get buffered;

  /// 关掉扬声器：立刻无声，但播放进度照常走，轮次判定不受影响。
  bool get silenced;
  set silenced(bool value);

  Future<void> stop();
}

/// 生成角色在通话中的回复文字（流式）。取消订阅即放弃本轮。
abstract interface class CallReplyGeneratorPort {
  Stream<String> streamReply(List<CallTurn> turns);
}
