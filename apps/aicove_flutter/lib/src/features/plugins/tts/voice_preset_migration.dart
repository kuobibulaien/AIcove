import 'dart:convert';

import 'tts_config.dart';
import 'voice_preset_runtime.dart';

enum VoicePresetMigrationReason {
  duplicateId,
  missingBinding,
  ambiguousBindings,
  targetUnavailable,
  invalidParameters,
}

class PendingVoicePresetMigration {
  const PendingVoicePresetMigration(this.presetId, this.reason);
  final String presetId;
  final VoicePresetMigrationReason reason;
}

/// A dry-run plan. backupJson captures the typed input, not unknown fields in
/// its original storage payload. Before applying, the caller must durably back
/// up the original persisted bytes as well. This phase never changes role
/// bindings or writes preferences/files itself.
class VoicePresetMigrationPlan {
  VoicePresetMigrationPlan({
    required this.backupJson,
    required this.config,
    required List<String> convertedIds,
    required List<PendingVoicePresetMigration> pending,
  }) : convertedIds = List.unmodifiable(convertedIds),
       pending = List.unmodifiable(pending);

  final String backupJson;
  final TtsConfig config;
  final List<String> convertedIds;
  final List<PendingVoicePresetMigration> pending;
}

VoicePresetMigrationPlan prepareVoicePresetMigration({
  required TtsConfig config,
  required List<VoicePresetTarget> targets,
}) {
  final converted = <String>[];
  final pending = <PendingVoicePresetMigration>[];
  final counts = <String, int>{};
  for (final preset in config.voicePresets) {
    counts.update(preset.id, (value) => value + 1, ifAbsent: () => 1);
  }
  final presets = config.voicePresets
      .map((preset) {
        VoicePreset defer(VoicePresetMigrationReason reason) {
          pending.add(PendingVoicePresetMigration(preset.id, reason));
          return preset;
        }

        if (counts[preset.id] != 1) {
          return defer(VoicePresetMigrationReason.duplicateId);
        }
        if (preset.synthesis != null) return preset;
        // Synthesized legacy bindings know the vendor, not the exact configured
        // account. Do not infer from current plugin selection or adapter identity.
        final bindings = preset.bindings;
        if (bindings.isEmpty ||
            bindings.any(
              (b) =>
                  b.sourceKind == VoiceBindingSourceKind.legacy ||
                  b.providerId.trim().isEmpty ||
                  b.modelId == null ||
                  b.modelId!.trim().isEmpty ||
                  b.remoteVoiceId.trim().isEmpty,
            )) {
          return defer(VoicePresetMigrationReason.missingBinding);
        }
        final identities = bindings
            .map((b) => (b.providerId, b.modelId, b.remoteVoiceId.trim()))
            .toSet();
        if (identities.length != 1) {
          return defer(VoicePresetMigrationReason.ambiguousBindings);
        }
        final binding = bindings.first;
        final matchingTargets = targets.where(
          (t) =>
              t.providerId == binding.providerId &&
              t.modelId == binding.modelId,
        );
        if (matchingTargets.length != 1 ||
            bindings.any(
              (b) =>
                  b.adapterId != null &&
                  b.adapterId!.isNotEmpty &&
                  b.adapterId != matchingTargets.single.adapterId,
            )) {
          return defer(VoicePresetMigrationReason.targetUnavailable);
        }
        final synthesis = VoiceSynthesisSettings(
          providerId: binding.providerId,
          modelId: binding.modelId!,
          voiceId: binding.remoteVoiceId.trim(),
          speed: config.speed ?? 1,
          maxCharsPerChunk: config.maxCharsPerChunk,
          voiceFrequency: config.voiceFrequency,
          systemPromptTemplate: config.systemPromptTemplate,
        );
        if (!synthesis.hasValidParameters) {
          return defer(VoicePresetMigrationReason.invalidParameters);
        }
        converted.add(preset.id);
        return preset.copyWith(synthesis: synthesis);
      })
      .toList(growable: false);

  return VoicePresetMigrationPlan(
    backupJson: jsonEncode(config.toJson()),
    config: config.copyWith(voicePresets: List.unmodifiable(presets)),
    convertedIds: converted,
    pending: pending,
  );
}
