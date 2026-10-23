import 'package:flutter_test/flutter_test.dart';

import 'package:aicove_flutter/src/features/plugins/prompts/builtin_prompt_packs.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/prompt_pack.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_plugin.dart';

ResolvedPromptPack _pack(
  String format,
  String model, [
  PresetPromptBinding binding = const PresetPromptBinding(),
]) => PromptPackLibrary(
  builtins: kBuiltinPromptPacks,
).resolve('tts', binding, format: format, model: model);

/// The `<tts>` instructions come only from the request's prompt pack
/// (ADR0092); the plugin no longer guesses the channel from its address.
void main() {
  group('TtsPlugin tag prompt', () {
    test('通用包：基础规则与文本规范，填入每段字数', () {
      final plugin = TtsPlugin(
        TtsConfig(enabled: true, maxCharsPerChunk: 36, voiceFrequency: 55),
        requestUrl: 'https://tts.example.com/v1',
        selectedModel: 'tts-model',
        prompts: _pack('openai_tts', 'tts-model'),
      );

      final prompt = plugin.buildTagSemanticsPrompt();

      expect(prompt, contains('<tts>文本</tts>'));
      expect(prompt, contains('不要超过 36 个字'));
      expect(prompt, contains('建议在关键句子或回复的重要部分使用语音'));
      expect(prompt, contains('严禁包含颜文字'));
      expect(prompt, isNot(contains('MiniMax')));
    });

    test('MiniMax 包带语气词与停顿说明', () {
      final prompt = TtsPlugin(
        TtsConfig(enabled: true),
        requestFormat: 'minimax',
        selectedModel: 'speech-2.8-hd',
        prompts: _pack('minimax', 'speech-2.8-hd'),
      ).buildTagSemanticsPrompt();

      expect(prompt, contains('MiniMax 语音增强'));
      expect(prompt, contains('<#0.5#>'));
    });

    test('Fish Audio S2 包带词级语音控制说明', () {
      final prompt = TtsPlugin(
        TtsConfig(enabled: true),
        requestFormat: 'fish_audio',
        selectedModel: 's2.1-pro-free',
        prompts: _pack('fish_audio', 's2.1-pro-free'),
      ).buildTagSemanticsPrompt();

      expect(prompt, contains('Fish Audio (S2/S2.1) 语音控制'));
      expect(prompt, contains('[窃窃私语]'));
      expect(prompt, contains('[笑着说]'));
      expect(prompt, contains('[长停顿]'));
      expect(prompt, contains('鼓励大量叠用情绪标签'));
      expect(prompt, contains('[高潮的娇喘]'));
      expect(prompt, contains('严禁包含任何颜文字'));
    });

    test('预设专属节跟在包后面', () {
      final prompt = TtsPlugin(
        TtsConfig(enabled: true, maxCharsPerChunk: 18),
        prompts: _pack(
          'openai_tts',
          'tts-model',
          const PresetPromptBinding().upsertSection(
            const PromptSection(
              id: 'own',
              scope: PromptScopes.ttsChat,
              title: '口癖',
              text: '请只在重要句子使用 <tts></tts>',
            ),
          ),
        ),
      ).buildTagSemanticsPrompt()!;

      expect(prompt, contains('不要超过 18 个字'));
      expect(prompt.trim(), endsWith('请只在重要句子使用 <tts></tts>'));
    });

    test('语音频率为 0 时只告诉模型不要用语音', () {
      final prompt = TtsPlugin(
        TtsConfig(enabled: true, voiceFrequency: 0),
        prompts: _pack('fish_audio', 's2.1-pro'),
      ).buildTagSemanticsPrompt();

      expect(prompt, '【重要】用户不希望你使用语音功能，请只用文字回复。');
    });

    test('未启用或没有提示词包时不生成标签说明', () {
      expect(
        TtsPlugin(
          TtsConfig(enabled: false),
          prompts: _pack('openai_tts', 'x'),
        ).buildTagSemanticsPrompt(),
        isNull,
      );
      expect(TtsPlugin(TtsConfig(enabled: true)).buildTagSemanticsPrompt(), isNull);
    });
  });
}
