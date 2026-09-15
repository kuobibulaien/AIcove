import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const runtime = VoicePresetRuntime();
  const targets = [
    VoicePresetTarget(
        providerId: 'account-a', modelId: 'speech', adapterId: 'minimax'),
    VoicePresetTarget(
        providerId: 'account-b', modelId: 'speech', adapterId: 'minimax'),
    VoicePresetTarget(
        providerId: 'reference',
        modelId: 'index',
        adapterId: 'siliconflow',
        supportsReferenceAudio: true),
  ];
  VoicePreset voice(String id, String provider, String remote,
          {double speed = 1}) =>
      VoicePreset(
        id: id,
        name: id,
        synthesis: VoiceSynthesisSettings(
            providerId: provider,
            modelId: 'speech',
            voiceId: remote,
            speed: speed),
      );
  final a = voice('a', 'account-a', 'same-id', speed: 0.8);
  final b = voice('b', 'account-b', 'same-id', speed: 1.3);
  TtsConfig config() => TtsConfig(
      enabled: true,
      selectedProviderId: 'wrong-global',
      selectedModelId: 'wrong-model',
      voice: 'wrong-voice',
      speed: 2,
      promptAudioUrl: 'https://wrong.example/audio',
      promptText: 'wrong',
      emoText: 'wrong',
      useEmoText: true,
      voicePresets: [a, b]);

  test(
      'two role requests resolve independent providers even with identical remote IDs',
      () {
    final source = config();
    final first = runtime.resolve(
        ownerId: 'role-a', presetId: 'a', config: source, targets: targets);
    final second = runtime.resolve(
        ownerId: 'role-b', presetId: 'b', config: source, targets: targets);
    expect(first.ownerId, 'role-a');
    expect(first.config.selectedProviderId, 'account-a');
    expect(second.config.selectedProviderId, 'account-b');
    expect(first.config.speed, 0.8);
    expect(second.config.speed, 1.3);
    expect(first.config.voice, 'same-id');
    expect(first.config.selectedModelId, 'speech');
    expect(source.selectedProviderId, 'wrong-global');
    expect(first.config.effectivePromptAudioUrl, isNull);
    expect(first.config.effectivePromptText, isNull);
    expect(first.config.effectiveEmoText, isNull);
    expect(first.config.voicePresets, hasLength(1));
  });

  test(
      'missing owner, missing binding and deleted preset never use a global default',
      () {
    for (final input in [('', 'a'), ('role', null), ('role', 'deleted')]) {
      expect(
          () => runtime.resolve(
              ownerId: input.$1,
              presetId: input.$2,
              config: config(),
              targets: targets),
          throwsA(isA<VoicePresetResolutionException>()));
    }
  });

  test('an explicit default preset reference serves only an unbound role', () {
    final fallback = runtime.resolve(
        ownerId: 'role',
        presetId: null,
        defaultPresetId: 'b',
        config: config(),
        targets: targets);
    expect(fallback.presetId, 'b');
    final bound = runtime.resolve(
        ownerId: 'role',
        presetId: 'a',
        defaultPresetId: 'b',
        config: config(),
        targets: targets);
    expect(bound.presetId, 'a');
    expect(
        () => runtime.resolve(
            ownerId: 'role',
            presetId: 'deleted',
            defaultPresetId: 'b',
            config: config(),
            targets: targets),
        throwsA(isA<VoicePresetResolutionException>()
            .having((e) => e.code, 'code', VoicePresetProblem.presetMissing)));
  });

  test('another account with the same adapter cannot satisfy the target', () {
    expect(
        () => runtime.resolve(
            ownerId: 'role',
            presetId: 'a',
            config: config(),
            targets:
                targets.where((t) => t.providerId != 'account-a').toList()),
        throwsA(isA<VoicePresetResolutionException>().having(
            (e) => e.code, 'code', VoicePresetProblem.targetUnavailable)));
  });

  test('unconfigured preset cannot inherit plugin channel', () {
    final source =
        config().copyWith(voicePresets: [VoicePreset(id: 'old', name: 'old')]);
    expect(
        () => runtime.resolve(
            ownerId: 'role', presetId: 'old', config: source, targets: targets),
        throwsA(isA<VoicePresetResolutionException>().having(
            (e) => e.code, 'code', VoicePresetProblem.needsConfiguration)));
  });

  test('reference material only works for a target explicitly supporting it',
      () {
    final reference = VoicePreset(
        id: 'ref',
        name: 'reference',
        promptAudioUrl: 'https://example.test/reference.wav',
        promptText: 'hello',
        synthesis: const VoiceSynthesisSettings(
            providerId: 'reference', modelId: 'index'));
    final resolved = runtime.resolve(
        ownerId: 'role',
        presetId: 'ref',
        config: config().copyWith(voicePresets: [reference]),
        targets: targets);
    expect(resolved.config.effectivePromptAudioUrl, reference.promptAudioUrl);
    final unsupported = reference.copyWith(
        synthesis: const VoiceSynthesisSettings(
            providerId: 'account-a', modelId: 'speech'));
    expect(
        () => runtime.resolve(
            ownerId: 'role',
            presetId: 'ref',
            config: config().copyWith(voicePresets: [unsupported]),
            targets: targets),
        throwsA(isA<VoicePresetResolutionException>()
            .having((e) => e.code, 'code', VoicePresetProblem.missingVoice)));
  });

  test('runtime snapshot removes old cross-channel bindings', () {
    final withOldBindings = a.copyWith(bindings: [
      const VoiceChannelBinding(
          providerId: 'account-b',
          providerName: 'B',
          modelId: 'speech',
          adapterId: 'minimax',
          remoteVoiceId: 'wrong')
    ], aliyunVoiceId: 'legacy');
    final resolved = runtime.resolve(
        ownerId: 'role',
        presetId: 'a',
        config: config().copyWith(voicePresets: [withOldBindings]),
        targets: targets);
    expect(
        resolved.config.selectedVoicePreset!.effectiveBindings, hasLength(1));
    expect(
        resolved
            .config.selectedVoicePreset!.effectiveBindings.single.providerId,
        'account-a');
    expect(
        resolved
            .config.selectedVoicePreset!.effectiveBindings.single.remoteVoiceId,
        'same-id');
  });

  test('duplicate local preset IDs are rejected instead of selecting first',
      () {
    expect(
        () => runtime.resolve(
            ownerId: 'role',
            presetId: 'a',
            config: config().copyWith(voicePresets: [a, a]),
            targets: targets),
        throwsA(isA<VoicePresetResolutionException>().having(
            (e) => e.code, 'code', VoicePresetProblem.duplicatePreset)));
  });

  test('synthesis settings survive json, copyWith and binding updates', () {
    final restored = VoicePreset.fromJson(a.toJson());
    expect(restored.synthesis!.toJson(), a.synthesis!.toJson());
    expect(
        restored.copyWith(name: 'renamed').synthesis!.providerId, 'account-a');
    expect(restored.copyWithBindings([]).synthesis!.providerId, 'account-a');
    expect(restored.copyWith(synthesis: null).synthesis, isNull);
    expect(
        VoicePreset.fromJson({'id': 'old', 'name': 'old'}).synthesis, isNull);
  });

  test('known pending voice cannot bypass its approval state', () {
    final pending = a.copyWith(bindings: [
      const VoiceChannelBinding(
        providerId: 'account-a',
        providerName: 'A',
        modelId: 'speech',
        adapterId: 'minimax',
        remoteVoiceId: 'same-id',
        status: 'DEPLOYING',
      )
    ]);
    expect(
        () => runtime.resolve(
            ownerId: 'role',
            presetId: 'a',
            config: config().copyWith(voicePresets: [pending]),
            targets: targets),
        throwsA(isA<VoicePresetResolutionException>()
            .having((e) => e.code, 'code', VoicePresetProblem.voiceNotReady)));
  });

  test('saved request snapshot cannot be changed by later list edits', () {
    final presets = [a];
    final source = config().copyWith(voicePresets: presets);
    final result = runtime.resolve(
        ownerId: 'role-a', presetId: 'a', config: source, targets: targets);
    presets.clear();
    expect(result.config.selectedVoicePreset!.id, 'a');
    expect(() => result.config.voicePresets.clear(), throwsUnsupportedError);
    expect(() => result.config.selectedVoicePreset!.bindings.clear(),
        throwsUnsupportedError);
  });

  test('ambiguous configured targets fail instead of using the first', () {
    expect(
        () => runtime.resolve(
            ownerId: 'role',
            presetId: 'a',
            config: config(),
            targets: [targets.first, targets.first]),
        throwsA(isA<VoicePresetResolutionException>().having(
            (e) => e.code, 'code', VoicePresetProblem.ambiguousTarget)));
  });

  test('invalid synthesis parameters cannot be used', () {
    for (final settings in [
      const VoiceSynthesisSettings(
          providerId: 'account-a', modelId: 'speech', voiceId: 'id', speed: 0),
      const VoiceSynthesisSettings(
          providerId: 'account-a',
          modelId: 'speech',
          voiceId: 'id',
          maxCharsPerChunk: 0),
      const VoiceSynthesisSettings(
          providerId: 'account-a',
          modelId: 'speech',
          voiceId: 'id',
          voiceFrequency: 101),
      const VoiceSynthesisSettings(
          providerId: 'account-a',
          modelId: 'speech',
          voiceId: 'id',
          speed: double.nan),
    ]) {
      expect(
          () => runtime.resolve(
              ownerId: 'role',
              presetId: 'a',
              config: config()
                  .copyWith(voicePresets: [a.copyWith(synthesis: settings)]),
              targets: targets),
          throwsA(isA<VoicePresetResolutionException>().having(
              (e) => e.code, 'code', VoicePresetProblem.invalidParameters)));
    }
  });
}
