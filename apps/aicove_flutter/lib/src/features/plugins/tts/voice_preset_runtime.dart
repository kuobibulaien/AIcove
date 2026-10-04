import 'tts_config.dart';

/// Explicitly configured provider/model pair supplied by the application.
/// The adapter is a protocol hint, never an account identity.
class VoicePresetTarget {
  const VoicePresetTarget({
    required this.providerId,
    required this.modelId,
    required this.adapterId,
    this.providerName = '',
    this.supportsReferenceAudio = false,
  });

  final String providerId;
  final String modelId;
  final String adapterId;
  final String providerName;
  final bool supportsReferenceAudio;
}

enum VoicePresetProblem {
  missingOwner,
  unboundRole,
  presetMissing,
  duplicatePreset,
  needsConfiguration,
  targetUnavailable,
  ambiguousTarget,
  invalidParameters,
  missingVoice,
  voiceNotReady,
}

class VoicePresetResolutionException implements Exception {
  const VoicePresetResolutionException(this.code, this.message);
  final VoicePresetProblem code;
  final String message;
  @override
  String toString() => message;
}

/// A request-scoped snapshot. Never store this config back as plugin settings.
class ResolvedVoicePreset {
  const ResolvedVoicePreset({
    required this.ownerId,
    required this.presetId,
    required this.target,
    required this.config,
  });

  final String ownerId;
  final String presetId;
  final VoicePresetTarget target;
  final TtsConfig config;
}

abstract interface class VoicePresetRuntimePort {
  ResolvedVoicePreset resolve({
    required String ownerId,
    required String? presetId,
    String? defaultPresetId,
    required TtsConfig config,
    required List<VoicePresetTarget> targets,
  });
}

/// Pure resolution shared by role speech and preset preview. No network, file
/// writes, current-page lookup or global-default fallback happens here.
class VoicePresetRuntime implements VoicePresetRuntimePort {
  const VoicePresetRuntime();

  @override
  ResolvedVoicePreset resolve({
    required String ownerId,
    required String? presetId,
    String? defaultPresetId,
    required TtsConfig config,
    required List<VoicePresetTarget> targets,
  }) {
    if (ownerId.trim().isEmpty) {
      throw const VoicePresetResolutionException(
        VoicePresetProblem.missingOwner,
        '无法确定发声角色',
      );
    }
    // ADR 0008: the application may supply an explicit default *preset ref*.
    // Never obtain it from legacy scattered global synthesis parameters.
    final effectiveId = presetId == null || presetId.trim().isEmpty
        ? defaultPresetId
        : presetId;
    if (effectiveId == null || effectiveId.trim().isEmpty) {
      throw const VoicePresetResolutionException(
        VoicePresetProblem.unboundRole,
        '请先绑定音色预设或设置默认预设',
      );
    }
    final matches = config.voicePresets
        .where((p) => p.id == effectiveId)
        .toList();
    if (matches.isEmpty) {
      throw const VoicePresetResolutionException(
        VoicePresetProblem.presetMissing,
        '角色绑定的音色预设已不存在，请重新选择',
      );
    }
    if (matches.length != 1) {
      throw const VoicePresetResolutionException(
        VoicePresetProblem.duplicatePreset,
        '音色预设标识重复，请先整理预设',
      );
    }
    final preset = matches.single;
    final synthesis = preset.synthesis;
    if (synthesis == null) {
      throw const VoicePresetResolutionException(
        VoicePresetProblem.needsConfiguration,
        '请完善此音色预设的渠道和模型',
      );
    }
    if (!synthesis.hasValidParameters) {
      throw const VoicePresetResolutionException(
        VoicePresetProblem.invalidParameters,
        '请检查预设的渠道、模型、语速、分段长度和语音频率',
      );
    }
    final matchingTargets = targets
        .where(
          (t) =>
              t.providerId == synthesis.providerId &&
              t.modelId == synthesis.modelId,
        )
        .toList();
    if (matchingTargets.isEmpty) {
      throw const VoicePresetResolutionException(
        VoicePresetProblem.targetUnavailable,
        '此预设的渠道或模型不可用，请检查供应商配置',
      );
    }
    if (matchingTargets.length != 1) {
      throw const VoicePresetResolutionException(
        VoicePresetProblem.ambiguousTarget,
        '此预设对应多个渠道配置，请先整理供应商配置',
      );
    }
    final target = matchingTargets.single;
    final voiceId = synthesis.voiceId?.trim();
    final hasVoice = voiceId != null && voiceId.isNotEmpty;
    final hasReference =
        (preset.localAudioPath?.trim().isNotEmpty ?? false) ||
        (preset.promptAudioUrl?.trim().isNotEmpty ?? false);
    if (!hasVoice && !(hasReference && target.supportsReferenceAudio)) {
      throw const VoicePresetResolutionException(
        VoicePresetProblem.missingVoice,
        '请填写音色 ID，或为支持参考音频的模型添加文件',
      );
    }
    // Do not call legacy resolveBinding: it permits matching another account
    // by adapter. Known pending/rejected states must not become usable here.
    for (final binding in preset.bindings) {
      if (binding.providerId == target.providerId &&
          binding.modelId == target.modelId &&
          binding.remoteVoiceId.trim() == voiceId &&
          binding.status != null &&
          binding.status!.isNotEmpty &&
          binding.status != 'OK') {
        throw const VoicePresetResolutionException(
          VoicePresetProblem.voiceNotReady,
          '此音色尚未就绪，请检查审核状态',
        );
      }
    }
    final snapshot = VoicePreset(
      id: preset.id,
      name: preset.name,
      sourceType: hasVoice ? VoiceSourceType.preset : preset.sourceType,
      providerType: preset.providerType,
      synthesis: synthesis,
      promptAudioUrl: preset.promptAudioUrl,
      localAudioPath: preset.localAudioPath,
      promptText: preset.promptText,
      emoText: preset.emoText,
      useEmoText: preset.useEmoText,
      source: preset.source,
      isBuiltIn: preset.isBuiltIn,
      bindings: [
        if (hasVoice)
          VoiceChannelBinding(
            providerId: target.providerId,
            providerName: target.providerName,
            adapterId: target.adapterId,
            modelId: target.modelId,
            remoteVoiceId: voiceId,
            status: 'OK',
          ),
      ],
    );
    return ResolvedVoicePreset(
      ownerId: ownerId,
      presetId: preset.id,
      target: target,
      config: TtsConfig(
        enabled: config.enabled,
        selectedProviderId: target.providerId,
        selectedModelId: target.modelId,
        model: target.modelId,
        voice: hasVoice ? voiceId : null,
        voicePresets: List<VoicePreset>.unmodifiable([snapshot]),
        selectedVoicePresetId: snapshot.id,
        speed: synthesis.speed,
        maxCharsPerChunk: synthesis.maxCharsPerChunk,
        voiceFrequency: synthesis.voiceFrequency,
        // <tts> 标签说明全局一份，请求时由插件提示词覆盖。
        systemPromptTemplate: config.systemPromptTemplate,
      ),
    );
  }
}
