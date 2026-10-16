import 'package:aicove_flutter/src/features/chat/data/preset_characters_loader.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('factory voice config holds only the Fish Audio Nahida default', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = TtsPluginConfigNotifier();
    await notifier.ready;
    final config = notifier.state;

    expect(config.voicePresets.map((p) => p.id), [VoicePreset.defaultPresetId]);
    expect(config.defaultVoicePresetId, VoicePreset.defaultPresetId);
    expect(config.presetSchemaVersion, 1);

    final synthesis = config.voicePresets.single.synthesis!;
    expect(synthesis.providerId, 'fish_audio');
    expect(synthesis.voiceId, '0e712bc0015b4cdbacbbc95af9da22b3');

    final snapshot = const VoicePresetRuntime().resolve(
      ownerId: 'preset_nahida',
      presetId: null,
      defaultPresetId: config.defaultVoicePresetId,
      config: config,
      targets: const [
        VoicePresetTarget(
          providerId: 'fish_audio',
          modelId: 's2.1-pro-free',
          adapterId: 'fish_audio',
        ),
      ],
    );
    expect(snapshot.config.voice, '0e712bc0015b4cdbacbbc95af9da22b3');
  });

  test('preset Nahida is bound to the factory voice preset', () async {
    final presets = await PresetCharactersLoader.load();
    final nahida = presets.firstWhere((c) => c.id == 'preset_nahida');
    expect(nahida.voiceFile, VoicePreset.defaultPresetId);
  });
}
