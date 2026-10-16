import 'dart:typed_data';

import '../../../settings/settings_models.dart';
import '../../domain/speech_recognizer_port.dart';
import 'cloud_speech_recognizer_factory.dart';

/// 供应商「测试模型」里的识别模型测活：真实建连、等服务端就绪、送 1 秒静音再结束。
///
/// 能验证地址、凭证、签名和模型名；静音不会出字，所以不验证识别效果。
class AsrModelProbe {
  static Future<String> run({
    required ProviderAuth provider,
    required String apiKey,
    required String modelId,
  }) async {
    final watch = Stopwatch()..start();
    final recognizer = createCloudSpeechRecognizer(
      provider.copyWith(apiKeys: [apiKey]),
      modelId,
    );
    String? failure;
    final subscription = recognizer.events.listen((event) {
      if (event is SpeechRecognitionFailed) failure ??= event.message;
    });
    try {
      await recognizer.start();
      final ready = watch.elapsedMilliseconds;
      for (var i = 0; i < 10; i++) {
        recognizer.addAudio(Uint8List(speechRecognizerSampleRate ~/ 10 * 2));
      }
      await recognizer.stop();
      if (failure != null) throw StateError(failure!);
      return '连接成功（$ready ms），识别服务已就绪';
    } finally {
      await subscription.cancel();
      await recognizer.dispose();
    }
  }
}
