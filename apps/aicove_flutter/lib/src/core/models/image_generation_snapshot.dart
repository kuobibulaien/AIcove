import 'dart:convert';
import '../api/image_providers/comfyui_workflow.dart';

/// Generation inputs only. Provider credentials and endpoints are resolved at
/// request time and must never be persisted with a message.
class ImageGenerationSnapshot {
  const ImageGenerationSnapshot({
    required this.providerId,
    required this.modelId,
    required this.requestProvider,
    required this.prompt,
    required this.negativePrompt,
    required this.width,
    required this.height,
    required this.steps,
    required this.guidanceScale,
    this.customParameters = const {},
    this.basePrompt,
    this.baseNegativePrompt,
  });

  final String providerId, modelId, requestProvider, prompt;
  final String? negativePrompt;
  // Content before the artist preset was applied. Null means legacy metadata.
  final String? basePrompt, baseNegativePrompt;
  final int width, height, steps;
  final double guidanceScale;
  final Map<String, dynamic> customParameters;

  // Only known generation fields can enter message metadata. Unknown provider
  // extensions make a snapshot unavailable rather than silently dropping inputs.
  static const _parameterKeys = {
    'params_version',
    'width',
    'height',
    'n_samples',
    'steps',
    'scale',
    'sampler',
    'seed',
    'negative_prompt',
    'qualityToggle',
    'ucPreset',
    'legacy',
    'legacy_v3_extend',
    'noise_schedule',
    'sm',
    'sm_dyn',
    'dynamic_thresholding',
    'add_original_image',
    'cfg_rescale',
    'prefer_brownian',
    'deliberate_euler_ancestral_bug',
    'autoSmea',
    'use_coords',
    'characterPrompts',
    'v4_prompt',
    'v4_negative_prompt',
    'model',
    'prompt',
    'n',
    'size',
    'response_format',
    'quality',
    'style',
    'background',
    'output_format',
    'output_compression',
    'moderation',
    'comfyWorkflow',
    'comfyBindings',
    'comfyOutputNode',
  };

  static ImageGenerationSnapshot? tryRead(Object? value) {
    if (value is! Map || value['version'] != 1) return null;
    try {
      final extra = Map<String, dynamic>.from(
        value['customParameters'] as Map? ?? {},
      );
      if (extra.keys.any((key) => !_parameterKeys.contains(key))) return null;
      if (value['requestProvider'] == 'comfyui') {
        if (_containsCredentialField(extra['comfyWorkflow'])) {
          return null;
        }
        ComfyUIWorkflow.validate(extra);
      } else if (extra.keys.any((key) => key.startsWith('comfy'))) {
        return null;
      }
      final snapshot = ImageGenerationSnapshot(
        providerId: value['providerId'] as String,
        modelId: value['modelId'] as String,
        requestProvider: value['requestProvider'] as String,
        prompt: value['prompt'] as String,
        negativePrompt: value['negativePrompt'] as String?,
        basePrompt: value['basePrompt'] as String?,
        baseNegativePrompt: value['baseNegativePrompt'] as String?,
        width: value['width'] as int,
        height: value['height'] as int,
        steps: value['steps'] as int,
        guidanceScale: (value['guidanceScale'] as num).toDouble(),
        customParameters: Map.unmodifiable(
          jsonDecode(jsonEncode(extra)) as Map<String, dynamic>,
        ),
      );
      if (snapshot.providerId.isEmpty ||
          snapshot.modelId.isEmpty ||
          snapshot.requestProvider.isEmpty ||
          snapshot.prompt.trim().isEmpty ||
          (snapshot.basePrompt != null &&
              snapshot.basePrompt!.trim().isEmpty) ||
          snapshot.width < 256 ||
          snapshot.width > 2048 ||
          snapshot.height < 256 ||
          snapshot.height > 2048 ||
          snapshot.steps < 1 ||
          snapshot.steps > 100 ||
          !snapshot.guidanceScale.isFinite ||
          snapshot.guidanceScale < 0 ||
          snapshot.guidanceScale > 10) {
        return null;
      }
      return snapshot;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'providerId': providerId,
    'modelId': modelId,
    'requestProvider': requestProvider,
    'prompt': prompt,
    'negativePrompt': negativePrompt,
    if (basePrompt != null) ...{
      'basePrompt': basePrompt,
      'baseNegativePrompt': baseNegativePrompt,
    },
    'width': width,
    'height': height,
    'steps': steps,
    'guidanceScale': guidanceScale,
    'customParameters': jsonDecode(jsonEncode(customParameters)),
  };

  Map<String, dynamic> get singleImageParameters => {
    ...customParameters,
    if (customParameters.containsKey('n')) 'n': 1,
    if (customParameters.containsKey('n_samples')) 'n_samples': 1,
  };

  // Workflows may include remote API nodes. Never copy their credential fields
  // into chat history; such workflows remain usable but without replay metadata.
  static bool _containsCredentialField(Object? value) {
    if (value is List) return value.any(_containsCredentialField);
    if (value is! Map) return false;
    return value.entries.any(
      (entry) =>
          RegExp(
            r'api.?key|token|password|secret|authorization|credential',
            caseSensitive: false,
          ).hasMatch(entry.key.toString()) ||
          _containsCredentialField(entry.value),
    );
  }
}
