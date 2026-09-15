import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aicove_flutter/src/features/settings/app_settings.dart';
import 'package:aicove_flutter/src/features/chat/domain/conversation.dart';
import 'package:aicove_flutter/src/features/plugins/plugin_providers.dart';
import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_application.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_runtime.dart';

class Settings extends AppSettingsNotifier {
  Settings(this.value);
  final AppSettings value;
  @override
  Future<AppSettings> build() async => value;
}

void main() {
  const key = 'aicove.plugins.tts.config';
  VoicePreset preset(String id) => VoicePreset(
    id: id,
    name: id,
    synthesis: VoiceSynthesisSettings(
      providerId: id,
      modelId: 'speech',
      voiceId: 'same-remote-id',
      speed: id == 'a' ? 0.8 : 1.2,
    ),
  );
  final settings = mapUiModelsToAppSettings({}).copyWith(
    providers: [
      for (final id in ['a', 'b'])
        ProviderAuth(
          id: id,
          apiKeys: ['key-$id'],
          apiBaseUrl: 'https://$id.example.invalid/v1',
          models: const ['speech'],
          visibleModels: const ['speech'],
          capabilities: const ['tts'],
          customConfig: const {'requestFormat': 'minimax_tts'},
        ),
    ],
  );
  Conversation role(String id, String? voice) => Conversation(
    id: id,
    title: id,
    displayName: id,
    voiceFile: voice,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  test(
    'role snapshots use separate credentials, default changes do not alter bound roles or earlier requests',
    () async {
      SharedPreferences.setMockInitialValues({
        key: jsonEncode(
          TtsConfig(
            enabled: true,
            presetSchemaVersion: 1,
            defaultVoicePresetId: 'a',
            voicePresets: [preset('a'), preset('b')],
          ).toJson(),
        ),
      });
      final container = ProviderContainer(
        overrides: [appSettingsProvider.overrideWith(() => Settings(settings))],
      );
      addTearDown(container.dispose);
      final port = container.read(voicePresetApplicationProvider);
      final a = await port.forRole(role('role-a', 'a'));
      final b = await port.forRole(role('role-b', 'b'));
      expect(a.error, isNull);
      expect(b.error, isNull);
      expect(a.service!.apiKey, 'key-a');
      expect(b.service!.apiKey, 'key-b');
      expect(a.service!.requestUrl, contains('a.example'));
      expect(b.service!.requestUrl, contains('b.example'));
      await container
          .read(ttsPluginConfigProvider.notifier)
          .setDefaultPreset('b');
      expect(
        (await port.forRole(
          role('unbound', null),
        )).service!.config.selectedVoicePreset!.id,
        'b',
      );
      expect(
        (await port.forRole(role('role-a', 'a'))).service!.apiKey,
        'key-a',
      );
      expect(a.service!.config.speed, 0.8);
      expect(
        (await port.forRole(role('broken', 'deleted'))).error,
        contains('不存在'),
      );
    },
  );

  test(
    'role without tts permission fails closed, preview bypasses role scope',
    () async {
      SharedPreferences.setMockInitialValues({
        key: jsonEncode(
          TtsConfig(
            presetSchemaVersion: 1,
            voicePresets: [preset('a')],
          ).toJson(),
        ),
      });
      final container = ProviderContainer(
        overrides: [appSettingsProvider.overrideWith(() => Settings(settings))],
      );
      addTearDown(container.dispose);
      final port = container.read(voicePresetApplicationProvider);
      final disabledRole = Conversation(
        id: 'role-off',
        title: 'role-off',
        displayName: 'role-off',
        voiceFile: 'a',
        enabledPlugins: const [],
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      expect((await port.forRole(disabledRole)).error, contains('未启用'));
      expect((await port.forRole(role('role', 'a'))).error, isNull);
      expect((await port.preview(preset('a'))).error, isNull);
      expect((await port.preview(preset('missing'))).error, contains('不可用'));
    },
  );

  test(
    'migration backs up exact original bytes including unknown fields before writing',
    () async {
      final raw = jsonEncode({
        ...TtsConfig(
          voicePresets: [
            VoicePreset(
              id: 'old',
              name: 'old',
              bindings: [
                const VoiceChannelBinding(
                  providerId: 'a',
                  providerName: 'A',
                  modelId: 'speech',
                  remoteVoiceId: 'remote',
                ),
              ],
            ),
          ],
          selectedVoicePresetId: 'old',
        ).toJson(),
        'unknownFutureField': {'keep': true},
      });
      SharedPreferences.setMockInitialValues({key: raw});
      final notifier = TtsPluginConfigNotifier();
      addTearDown(notifier.dispose);
      await notifier.migratePresets([
        const VoicePresetTarget(
          providerId: 'a',
          modelId: 'speech',
          adapterId: 'minimax',
        ),
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('aicove.plugins.tts.before_voice_presets_v1'),
        raw,
      );
      expect(notifier.state.defaultVoicePresetId, 'old');
      expect(notifier.state.presetSchemaVersion, 1);
      await notifier.setDefaultPreset(null);
      expect(
        TtsConfig.fromJson(
          jsonDecode(prefs.getString(key)!),
        ).defaultVoicePresetId,
        isNull,
      );
      await notifier.migratePresets([]);
      expect(
        prefs.getString('aicove.plugins.tts.before_voice_presets_v1'),
        raw,
      );
    },
  );

  test('corrupt original configuration is not silently replaced', () async {
    SharedPreferences.setMockInitialValues({key: '{broken json'});
    final notifier = TtsPluginConfigNotifier();
    addTearDown(notifier.dispose);
    await notifier.ready;
    await expectLater(notifier.savePreset(preset('a')), throwsStateError);
    expect(
      (await SharedPreferences.getInstance()).getString(key),
      '{broken json',
    );
  });

  test('late cloud-created voice cannot overwrite an edited preset', () async {
    final original = preset('a');
    SharedPreferences.setMockInitialValues({
      key: jsonEncode(
        TtsConfig(presetSchemaVersion: 1, voicePresets: [original]).toJson(),
      ),
    });
    final notifier = TtsPluginConfigNotifier();
    addTearDown(notifier.dispose);
    final edited = original.copyWith(
      synthesis: const VoiceSynthesisSettings(
        providerId: 'b',
        modelId: 'speech',
        voiceId: 'new',
      ),
    );
    await notifier.savePreset(edited);
    await notifier.saveCreatedVoice(
      original,
      original.copyWith(
        bindings: [
          const VoiceChannelBinding(
            providerId: 'a',
            providerName: 'A',
            modelId: 'speech',
            remoteVoiceId: 'late-id',
          ),
        ],
      ),
    );
    expect(notifier.state.voicePresets.single.synthesis!.providerId, 'b');
    expect(notifier.state.voicePresets.single.synthesis!.voiceId, 'new');
  });

  test(
    'rapid saves and an immediate save during loading do not lose presets',
    () async {
      SharedPreferences.setMockInitialValues({
        key: jsonEncode(
          TtsConfig(
            presetSchemaVersion: 1,
            voicePresets: [preset('old')],
          ).toJson(),
        ),
      });
      final notifier = TtsPluginConfigNotifier();
      addTearDown(notifier.dispose);
      await Future.wait([
        notifier.savePreset(preset('a')),
        notifier.savePreset(preset('b')),
      ]);
      expect(notifier.state.voicePresets.map((p) => p.id), ['old', 'a', 'b']);
      final prefs = await SharedPreferences.getInstance();
      expect(
        TtsConfig.fromJson(
          jsonDecode(prefs.getString(key)!),
        ).voicePresets.map((p) => p.id),
        ['old', 'a', 'b'],
      );
    },
  );
}
