import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_runtime.dart';
import 'package:aicove_flutter/src/features/plugins/tts/synthesis/tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/synthesis/minimax_tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/synthesis/openai_compatible_tts_synthesis_adapter.dart';
import 'package:aicove_flutter/src/features/plugins/tts/synthesis/siliconflow_tts_synthesis_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final adapter in <TtsSynthesisAdapter>[
    const MinimaxTtsSynthesisAdapter(),
    const OpenAiCompatibleTtsSynthesisAdapter(),
    const SiliconFlowTtsSynthesisAdapter(),
  ]) {
    test(
        '${adapter.providerId}: real body builder consumes the role snapshot, not global voice',
        () {
      final presets = [
        for (final id in ['a', 'b'])
          VoicePreset(
              id: id,
              name: id,
              synthesis: VoiceSynthesisSettings(
                providerId: 'account-$id',
                modelId: 'model-$id',
                voiceId: 'voice-$id',
                speed: id == 'a' ? 0.8 : 1.2,
              )),
      ];
      final config = TtsConfig(
          voicePresets: presets,
          voice: 'wrong-global',
          model: 'wrong-global',
          selectedVoicePresetId: 'b');
      final targets = [
        for (final id in ['a', 'b'])
          VoicePresetTarget(
              providerId: 'account-$id',
              modelId: 'model-$id',
              adapterId: adapter.providerId)
      ];
      for (final id in ['a', 'b', 'a']) {
        final snapshot = const VoicePresetRuntime().resolve(
            ownerId: 'role-$id',
            presetId: id,
            config: config,
            targets: targets);
        final body = adapter.buildRequestBody(TtsSynthesisContext(
            config: snapshot.config,
            text: 'offline test',
            rawUrl: 'https://example.invalid',
            providerId: snapshot.target.providerId,
            model: snapshot.target.modelId));
        expect(body['model'], 'model-$id');
        if (adapter is MinimaxTtsSynthesisAdapter) {
          expect((body['voice_setting'] as Map)['voice_id'], 'voice-$id');
          expect(
              (body['voice_setting'] as Map)['speed'], id == 'a' ? 0.8 : 1.2);
        } else {
          expect(body['voice'], 'voice-$id');
          expect(body['speed'], id == 'a' ? 0.8 : 1.2);
        }
      }
    });
  }
}
