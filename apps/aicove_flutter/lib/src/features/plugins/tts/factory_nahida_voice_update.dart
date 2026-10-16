import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/conversation_providers.dart';
import '../plugin_providers.dart';
import 'tts_config.dart';

final factoryNahidaVoiceUpdateProvider = Provider<FactoryNahidaVoiceUpdate>(
  (ref) => FactoryNahidaVoiceUpdate(ref),
);

/// One-time update for existing installs: when the preset Nahida has never
/// been given a voice, add the factory Fish Audio preset and bind it to her.
/// Roles that already have a voice and the global default are left untouched.
class FactoryNahidaVoiceUpdate {
  FactoryNahidaVoiceUpdate(this.ref);
  final Ref ref;

  static const doneKey = 'aicove.plugins.tts.factory_nahida_fish_20261014';
  static const nahidaId = 'preset_nahida';

  Future<void> run() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(doneKey) == true) return;

    final conversations = await ref.read(conversationsProvider.future);
    final nahida = conversations.where((c) => c.id == nahidaId).firstOrNull;
    if (nahida != null && (nahida.voiceFile?.trim().isEmpty ?? true)) {
      final tts = ref.read(ttsPluginConfigProvider.notifier);
      await tts.ready;
      if (!ref
          .read(ttsPluginConfigProvider)
          .voicePresets
          .any((p) => p.id == VoicePreset.defaultPresetId)) {
        await tts.savePreset(VoicePreset.defaultPreset);
      }
      await ref
          .read(conversationsProvider.notifier)
          .updateOne(
            nahidaId,
            (c) => c.copyWith(
              voiceFile: VoicePreset.defaultPresetId,
              updatedAt: DateTime.now(),
            ),
          );
    }
    await prefs.setBool(doneKey, true);
  }
}
