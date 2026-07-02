import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/plugins/tts/providers/tts_provider_factory.dart';

void main() {
  group('TtsProviderFactory.resolve', () {
    test('siliconflow 显式 requestFormat 命中', () {
      final resolution = TtsProviderFactory.resolve(
        apiUrl: 'https://example.invalid/v1',
        requestFormat: 'siliconflow_indextts',
      );

      expect(resolution.voiceProvider?.providerId, 'siliconflow');
      expect(resolution.requestFormat, 'siliconflow_indextts');
      expect(resolution.matchedBy, 'requestFormat');
    });

    test('aliyun cosyvoice 显式 requestFormat 命中', () {
      final resolution = TtsProviderFactory.resolve(
        apiUrl: 'https://example.invalid/v1',
        requestFormat: 'aliyun_cosyvoice',
      );

      expect(resolution.voiceProvider?.providerId, 'aliyun_cosyvoice');
      expect(resolution.requestFormat, 'aliyun_cosyvoice');
      expect(resolution.matchedBy, 'requestFormat');
    });

    test('minimax 通过 apiUrl 命中但保留 openai_tts requestFormat', () {
      final resolution = TtsProviderFactory.resolve(
        apiUrl: 'https://api.minimaxi.com/v1',
        requestFormat: 'openai_tts',
      );

      expect(resolution.voiceProvider?.providerId, 'minimax');
      expect(resolution.requestFormat, 'openai_tts');
      expect(resolution.matchedBy, 'apiUrl');
    });
  });
}
