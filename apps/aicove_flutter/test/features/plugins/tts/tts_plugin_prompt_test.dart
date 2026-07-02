import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_plugin.dart';

void main() {
  group('TtsPlugin tag prompt', () {
    test('启用且配置完整时生成 <tts> 标签说明', () {
      final plugin = TtsPlugin(
        TtsConfig(
          enabled: true,
          maxCharsPerChunk: 36,
          voiceFrequency: 55,
        ),
        requestUrl: 'https://tts.example.com/v1',
        selectedModel: 'tts-model',
      );

      final prompt = plugin.buildTagSemanticsPrompt();

      expect(prompt, isNotNull);
      expect(prompt, contains('<tts>文本</tts>'));
      expect(prompt, contains('不要超过 36 个字'));
      expect(prompt, contains('建议在关键句子或回复的重要部分使用语音'));
    });

    test('MiniMax 渠道追加语音增强说明', () {
      final plugin = TtsPlugin(
        TtsConfig(
          enabled: true,
        ),
        requestUrl: 'https://api.minimax.chat/v1',
        requestFormat: 'minimax_tts',
        selectedModel: 'speech-01',
      );

      final prompt = plugin.buildTagSemanticsPrompt();

      expect(prompt, isNotNull);
      expect(prompt, contains('MiniMax 语音增强'));
      expect(prompt, contains('<#0.5#>'));
    });

    test('自定义模板会进入运行时标签说明', () {
      final plugin = TtsPlugin(
        TtsConfig(
          enabled: true,
          maxCharsPerChunk: 18,
          systemPromptTemplate:
              '请只在重要句子使用 <tts></tts>，单段不超过 {max_chars_per_chunk} 个字。\n{minimax_guide}',
        ),
        requestUrl: 'https://tts.example.com/v1',
        selectedModel: 'tts-model',
      );

      final prompt = plugin.buildTagSemanticsPrompt();

      expect(prompt, isNotNull);
      expect(prompt, contains('只在重要句子使用 <tts></tts>'));
      expect(prompt, contains('不超过 18 个字'));
      expect(prompt, isNot(contains('MiniMax 语音增强')));
    });

    test('未启用时不生成标签说明', () {
      final plugin = TtsPlugin(
        TtsConfig(
          enabled: false,
        ),
        requestUrl: 'https://tts.example.com/v1',
        selectedModel: 'tts-model',
      );

      expect(plugin.buildTagSemanticsPrompt(), isNull);
    });
  });
}
