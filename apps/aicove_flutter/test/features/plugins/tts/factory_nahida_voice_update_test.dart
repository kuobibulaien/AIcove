import 'dart:convert';

import 'package:aicove_flutter/src/features/chat/conversation_providers.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/factory_nahida_voice_update.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Roles extends ConversationsNotifier {
  _Roles(this.initial);
  final List<Conversation> initial;

  @override
  Future<List<Conversation>> build() async => initial;

  @override
  Future<void> updateOne(
    String id,
    Conversation Function(Conversation) fn, {
    bool persist = true,
  }) => super.updateOne(id, fn, persist: false);
}

Conversation _role(String id, {String? voiceFile}) => Conversation(
  id: id,
  title: id,
  displayName: id,
  voiceFile: voiceFile,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

final _oldConfig = TtsConfig(
  enabled: true,
  presetSchemaVersion: 1,
  voicePresets: [
    VoicePreset(
      id: 'mine',
      name: 'mine',
      synthesis: const VoiceSynthesisSettings(providerId: 'p', modelId: 'm'),
    ),
  ],
  defaultVoicePresetId: 'mine',
);

Future<ProviderContainer> _container(List<Conversation> roles) async {
  SharedPreferences.setMockInitialValues({
    'aicove.plugins.tts.config': jsonEncode(_oldConfig.toJson()),
  });
  final container = ProviderContainer(
    overrides: [conversationsProvider.overrideWith(() => _Roles(roles))],
  );
  await container.read(ttsPluginConfigProvider.notifier).ready;
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unvoiced Nahida gets the factory Fish voice, default kept', () async {
    final container = await _container([
      _role('preset_nahida'),
      _role('other'),
    ]);
    addTearDown(container.dispose);

    await container.read(factoryNahidaVoiceUpdateProvider).run();

    final roles = container.read(conversationsProvider).value!;
    expect(
      roles.firstWhere((c) => c.id == 'preset_nahida').voiceFile,
      VoicePreset.defaultPresetId,
    );
    expect(roles.firstWhere((c) => c.id == 'other').voiceFile, isNull);
    final config = container.read(ttsPluginConfigProvider);
    expect(config.voicePresets.map((p) => p.id), [
      'mine',
      VoicePreset.defaultPresetId,
    ]);
    expect(config.defaultVoicePresetId, 'mine');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(FactoryNahidaVoiceUpdate.doneKey), isTrue);
  });

  test('Nahida with a chosen voice is left alone', () async {
    final container = await _container([
      _role('preset_nahida', voiceFile: 'mine'),
    ]);
    addTearDown(container.dispose);

    await container.read(factoryNahidaVoiceUpdateProvider).run();

    expect(
      container.read(conversationsProvider).value!.single.voiceFile,
      'mine',
    );
    expect(
      container.read(ttsPluginConfigProvider).voicePresets.map((p) => p.id),
      ['mine'],
    );
  });

  test('runs only once', () async {
    final container = await _container([_role('preset_nahida')]);
    addTearDown(container.dispose);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(FactoryNahidaVoiceUpdate.doneKey, true);

    await container.read(factoryNahidaVoiceUpdateProvider).run();

    expect(
      (await container.read(conversationsProvider.future)).single.voiceFile,
      isNull,
    );
  });
}
