import 'dart:convert';

import 'package:aicove_flutter/src/features/plugins/image/drawing_preset.dart';
import 'package:aicove_flutter/src/features/plugins/image/drawing_preset_provider.dart';
import 'package:aicove_flutter/src/features/plugins/image/image_config.dart';
import 'package:aicove_flutter/src/features/plugins/prompts/plugin_prompts.dart';
import 'package:aicove_flutter/src/features/plugins/sticker/sticker_config.dart';
import 'package:aicove_flutter/src/features/plugins/time_awareness/time_awareness_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_synthesis_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

ImageConfig _drawing(String inline) => const ImageConfig().copyWith(
  fastPromptPresets: [DrawingPromptPreset(name: '辅助提示词', content: inline)],
  selectedFastPromptPresetName: '辅助提示词',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('迁移取默认绘图／音色预设的值，与默认相同的不保存，旧键不动', () async {
    final catalog = DrawingPresetCatalog(
      presets: [
        DrawingPreset(id: 'a', name: '默认', config: _drawing('默认预设的画图说明')),
        DrawingPreset(id: 'b', name: '其它', config: _drawing('其它预设的画图说明')),
      ],
      defaultPresetId: 'a',
      legacyConfig: const ImageConfig(),
    );
    final voice = VoicePreset.defaultPreset.copyWith(
      synthesis: const VoiceSynthesisSettings(
        providerId: 'p',
        modelId: 'm',
        systemPromptTemplate: '默认音色的语音说明',
      ),
    );
    final tts = TtsConfig(
      enabled: true,
      voicePresets: [voice],
      defaultVoicePresetId: voice.id,
      systemPromptTemplate: '旧全局语音说明',
    );
    final values = <String, Object>{
      PreferencesDrawingPresetStore.storageKey: jsonEncode(catalog.toJson()),
      'aicove.plugins.tts.config': jsonEncode(tts.toJson()),
      'aicove.plugins.sticker.config': jsonEncode(
        const StickerConfig().toJson(),
      ),
      'aicove.plugins.time_awareness.config': jsonEncode(
        TimeAwarenessConfig(currentTimePromptTemplate: '现在是{datetime}').toJson(),
      ),
    };
    SharedPreferences.setMockInitialValues(values);

    final prompts = await PreferencesPluginPromptStore().load();

    expect(prompts.of(PluginPromptSlot.image), '默认预设的画图说明');
    expect(prompts.of(PluginPromptSlot.tts), '默认音色的语音说明');
    expect(prompts.of(PluginPromptSlot.currentTime), '现在是{datetime}');
    expect(prompts.isDefault(PluginPromptSlot.sticker), isTrue);
    final prefs = await SharedPreferences.getInstance();
    for (final entry in values.entries) {
      expect(prefs.getString(entry.key), entry.value);
    }
    // 已迁移后不再从旧键读取。
    await prefs.setString(
      'aicove.plugins.time_awareness.config',
      jsonEncode(TimeAwarenessConfig().toJson()),
    );
    expect(
      (await PreferencesPluginPromptStore().load()).of(
        PluginPromptSlot.currentTime,
      ),
      '现在是{datetime}',
    );
  });

  test('没有旧数据时全部为出厂默认；清空或填回默认即恢复默认', () async {
    SharedPreferences.setMockInitialValues({});
    final prompts = await PreferencesPluginPromptStore().load();
    for (final slot in PluginPromptSlot.values) {
      expect(prompts.isDefault(slot), isTrue);
      expect(prompts.of(slot), slot.defaultText);
    }
    final edited = prompts.withText(PluginPromptSlot.sticker, '少发表情包');
    expect(edited.of(PluginPromptSlot.sticker), '少发表情包');
    expect(edited.withText(PluginPromptSlot.sticker, '  ').overrides, isEmpty);
    expect(
      edited
          .withText(
            PluginPromptSlot.sticker,
            StickerConfig.defaultSystemPromptTemplate,
          )
          .overrides,
      isEmpty,
    );
  });
}
