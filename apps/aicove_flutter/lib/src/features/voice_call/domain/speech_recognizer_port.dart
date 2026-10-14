import 'dart:typed_data';

/// 所有识别器统一接收的音频格式：16 kHz 单声道 PCM16 小端。
const int speechRecognizerSampleRate = 16000;

/// 识别器在通话中上报的事件。
sealed class SpeechRecognitionEvent {
  const SpeechRecognitionEvent();
}

/// 用户开始说话，通话据此打断角色（barge-in）。
class SpeechStarted extends SpeechRecognitionEvent {
  const SpeechStarted();
}

/// 一段语音结束。无论识别出没出字都会发，紧跟着的 [SpeechFinal] 才带文字；
/// 通话据此在“开口了但没识别出字”（咳嗽、杂音）时恢复提交计时。
class SpeechEnded extends SpeechRecognitionEvent {
  const SpeechEnded();
}

/// 当前这句话尚未定稿的识别文字。
class SpeechPartial extends SpeechRecognitionEvent {
  const SpeechPartial(this.text);

  final String text;
}

/// 一段话的定稿文字。通话把短停顿切开的几段拼成一轮，见 `VoiceCallSession.userTurnGap`。
class SpeechFinal extends SpeechRecognitionEvent {
  const SpeechFinal(this.text);

  final String text;
}

/// 识别失败，本次会话不再可用。
class SpeechRecognitionFailed extends SpeechRecognitionEvent {
  const SpeechRecognitionFailed(this.message);

  final String message;
}

/// 语音通话的流式语音识别（ADR0074）。
///
/// 本地引擎和云端服务实现同一契约，通话逻辑不依赖具体供应商。
/// 生命周期：[start] 一次，[addAudio] 持续喂音频，[stop] 冲出最后一句，最后 [dispose]。
abstract interface class SpeechRecognizerPort {
  Stream<SpeechRecognitionEvent> get events;

  Future<void> start();

  /// 喂入 [speechRecognizerSampleRate] 单声道 PCM16 小端音频。
  void addAudio(Uint8List pcm16);

  /// 结束会话；有未定稿的话会先发出 [SpeechFinal]。
  Future<void> stop();

  Future<void> dispose();
}
