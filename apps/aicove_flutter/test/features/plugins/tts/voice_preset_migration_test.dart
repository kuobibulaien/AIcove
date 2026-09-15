import 'dart:convert';

import 'package:aicove_flutter/src/features/plugins/tts/tts_config.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_migration.dart';
import 'package:aicove_flutter/src/features/plugins/tts/voice_preset_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const targets = [
    VoicePresetTarget(providerId: 'a', modelId: 'speech', adapterId: 'minimax'),
    VoicePresetTarget(providerId: 'b', modelId: 'speech', adapterId: 'minimax'),
  ];
  const bindingA = VoiceChannelBinding(
      providerId: 'a',
      providerName: 'A',
      modelId: 'speech',
      adapterId: 'minimax',
      remoteVoiceId: 'remote');
  const bindingB = VoiceChannelBinding(
      providerId: 'b',
      providerName: 'B',
      modelId: 'speech',
      adapterId: 'minimax',
      remoteVoiceId: 'remote');
  VoicePreset old(String id, List<VoiceChannelBinding> bindings) =>
      VoicePreset(id: id, name: id, bindings: bindings);

  test(
      'only explicit unique account/model bindings are converted; originals preserved',
      () {
    final source = TtsConfig(
        voicePresets: [
          old('known', [bindingA]),
          old('unbound', []),
          old('multi', [bindingA, bindingB])
        ],
        speed: 1.2,
        maxCharsPerChunk: 80,
        voiceFrequency: 40,
        selectedProviderId: 'a',
        selectedModelId: 'speech');
    final original = jsonEncode(source.toJson());
    final plan = prepareVoicePresetMigration(config: source, targets: targets);
    expect(plan.convertedIds, ['known']);
    expect(plan.pending.map((e) => e.presetId), ['unbound', 'multi']);
    expect(plan.config.voicePresets.first.synthesis!.providerId, 'a');
    expect(plan.config.voicePresets.first.synthesis!.speed, 1.2);
    expect(plan.config.voicePresets.first.synthesis!.maxCharsPerChunk, 80);
    expect(plan.config.voicePresets.first.synthesis!.voiceFrequency, 40);
    expect(plan.config.voicePresets.first.bindings, [bindingA]);
    expect(plan.config.voicePresets.map((p) => p.id),
        ['known', 'unbound', 'multi']);
    expect(plan.backupJson, original);
    expect(jsonEncode(source.toJson()), original);
  });

  test('adapter-only and legacy vendor IDs do not identify an account', () {
    final source = TtsConfig(
        selectedProviderId: 'a',
        selectedModelId: 'speech',
        voicePresets: [
          old('adapter-only', [
            const VoiceChannelBinding(
                providerId: 'minimax',
                providerName: 'MiniMax',
                modelId: 'speech',
                adapterId: 'minimax',
                remoteVoiceId: 'remote')
          ]),
          VoicePreset(
              id: 'legacy',
              name: 'legacy',
              aliyunVoiceId: 'voice',
              aliyunTargetModel: 'speech'),
          old('legacy-kind', [
            const VoiceChannelBinding(
                providerId: 'a',
                providerName: 'A',
                modelId: 'speech',
                remoteVoiceId: 'remote',
                sourceKind: VoiceBindingSourceKind.legacy)
          ])
        ]);
    final plan = prepareVoicePresetMigration(config: source, targets: targets);
    expect(plan.convertedIds, isEmpty);
    expect(plan.pending, hasLength(3));
    expect(plan.config.voicePresets.every((p) => p.synthesis == null), isTrue);
  });

  test(
      'multiple bindings remain ambiguous even when only one target is configured',
      () {
    final plan = prepareVoicePresetMigration(
        config: TtsConfig(voicePresets: [
          old('multi', [bindingA, bindingB])
        ]),
        targets: [targets.first]);
    expect(plan.convertedIds, isEmpty);
    expect(plan.pending.single.reason,
        VoicePresetMigrationReason.ambiguousBindings);
  });

  test('conflicting adapter metadata requires manual review', () {
    final source = TtsConfig(voicePresets: [
      old('conflict', [
        const VoiceChannelBinding(
          providerId: 'a',
          providerName: 'A',
          modelId: 'speech',
          adapterId: 'aliyun_cosyvoice',
          remoteVoiceId: 'remote',
        )
      ]),
    ]);
    final plan = prepareVoicePresetMigration(config: source, targets: targets);
    expect(plan.convertedIds, isEmpty);
    expect(plan.pending.single.reason,
        VoicePresetMigrationReason.targetUnavailable);
  });

  test('migration is idempotent and never overwrites complete settings', () {
    final configured = old('new', [bindingB]).copyWith(
        synthesis: const VoiceSynthesisSettings(
            providerId: 'a', modelId: 'speech', voiceId: 'manual', speed: 0.7));
    final first = prepareVoicePresetMigration(
        config: TtsConfig(voicePresets: [
          old('old', [bindingA]),
          configured
        ]),
        targets: targets);
    final second =
        prepareVoicePresetMigration(config: first.config, targets: targets);
    expect(second.convertedIds, isEmpty);
    expect(second.config.toJson(), first.config.toJson());
    expect(second.config.voicePresets.last.synthesis!.voiceId, 'manual');
  });

  test('duplicate local IDs are preserved but never automatically converted',
      () {
    final source = TtsConfig(voicePresets: [
      old('same', [bindingA]),
      old('same', [bindingB])
    ]);
    final plan = prepareVoicePresetMigration(config: source, targets: targets);
    expect(plan.convertedIds, isEmpty);
    expect(
        plan.pending
            .every((p) => p.reason == VoicePresetMigrationReason.duplicateId),
        isTrue);
    expect(plan.config.voicePresets, hasLength(2));
  });

  test(
      'invalid old parameters require review rather than inventing replacement values',
      () {
    final plan = prepareVoicePresetMigration(
        config: TtsConfig(speed: 5, voicePresets: [
          old('old', [bindingA])
        ]),
        targets: targets);
    expect(plan.convertedIds, isEmpty);
    expect(plan.pending.single.reason,
        VoicePresetMigrationReason.invalidParameters);
  });
}
