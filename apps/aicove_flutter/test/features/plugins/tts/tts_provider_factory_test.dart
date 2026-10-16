import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/plugins/tts/providers/tts_provider_factory.dart';

void main() {
  group('TtsProviderFactory.resolve', () {
    test('aliyun cosyvoice 显式 requestFormat 命中', () {
      final resolution = TtsProviderFactory.resolve(
        apiUrl: 'https://example.invalid/v1',
        requestFormat: 'aliyun_cosyvoice',
      );

      expect(resolution.voiceProvider?.providerId, 'aliyun_cosyvoice');
      expect(resolution.requestFormat, 'aliyun_cosyvoice');
      expect(resolution.matchedBy, 'requestFormat');
    });

    test('aliyun 通用格式交给 Qwen 音色管理', () {
      final resolution = TtsProviderFactory.resolve(requestFormat: 'aliyun');

      expect(resolution.voiceProvider?.providerId, 'aliyun_qwen');
      expect(resolution.requestFormat, 'aliyun');
    });

    test('只按 requestFormat 路由，不再按地址或渠道 id 猜厂商', () {
      final resolution = TtsProviderFactory.resolve(
        providerId: 'minimax',
        apiUrl: 'https://api.minimaxi.com/v1',
        requestFormat: 'openai_tts',
      );

      expect(resolution.voiceProvider, isNull);
      expect(resolution.requestFormat, 'openai_tts');
    });

    test('旧别名规整成注册表里的格式', () {
      expect(
        TtsProviderFactory.resolve(
          requestFormat: 'siliconflow_indextts',
        ).requestFormat,
        'openai_tts',
      );
      expect(
        TtsProviderFactory.resolve(requestFormat: 'fishaudio').requestFormat,
        'fish_audio',
      );
      expect(
        TtsProviderFactory.resolve(
          requestFormat: 'minimax_tts',
        ).voiceProvider?.providerId,
        'minimax',
      );
      expect(TtsProviderFactory.resolve().requestFormat, 'openai_tts');
    });
  });
}
