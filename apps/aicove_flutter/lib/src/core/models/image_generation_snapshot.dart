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
    this.postProcessor,
  });

  final String providerId, modelId, requestProvider, prompt;
  final String? negativePrompt;
  final String? postProcessor;
  // Content before the artist preset was applied. Null means legacy metadata.
  final String? basePrompt, baseNegativePrompt;
  final int width, height, steps;
  final double guidanceScale;
  final Map<String, dynamic> customParameters;

  ImageGenerationSnapshot copyWith({
    String? providerId, String? modelId, String? requestProvider, String? prompt,
    String? negativePrompt, String? basePrompt, String? baseNegativePrompt,
    String? postProcessor, int? width, int? height, int? steps,
    double? guidanceScale, Map<String, dynamic>? customParameters,
  }) => ImageGenerationSnapshot(
    providerId: providerId ?? this.providerId, modelId: modelId ?? this.modelId,
    requestProvider: requestProvider ?? this.requestProvider, prompt: prompt ?? this.prompt,
    negativePrompt: negativePrompt ?? this.negativePrompt, basePrompt: basePrompt ?? this.basePrompt,
    baseNegativePrompt: baseNegativePrompt ?? this.baseNegativePrompt,
    postProcessor: postProcessor ?? this.postProcessor, width: width ?? this.width,
    height: height ?? this.height, steps: steps ?? this.steps,
    guidanceScale: guidanceScale ?? this.guidanceScale,
    customParameters: customParameters ?? this.customParameters,
  );

  @override
  bool operator ==(Object other) => identical(this, other) || other is ImageGenerationSnapshot &&
      providerId == other.providerId && modelId == other.modelId && requestProvider == other.requestProvider &&
      prompt == other.prompt && negativePrompt == other.negativePrompt && basePrompt == other.basePrompt &&
      baseNegativePrompt == other.baseNegativePrompt && postProcessor == other.postProcessor &&
      width == other.width && height == other.height && steps == other.steps && guidanceScale == other.guidanceScale &&
      jsonEncode(customParameters) == jsonEncode(other.customParameters);

  @override
  int get hashCode => Object.hash(providerId, modelId, requestProvider, prompt, negativePrompt,
      basePrompt, baseNegativePrompt, postProcessor, width, height, steps, guidanceScale,
      jsonEncode(customParameters));

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
    'comfyLoraName',
    'comfyLoraStrength',
    'comfySampler',
    'comfyScheduler',
  };

  static ImageGenerationSnapshot? tryRead(Object? value) {
    if (value is! Map || value['version'] != 1) return null;
    try {
      final extra = Map<String, dynamic>.from(
        value['customParameters'] as Map? ?? {},
      );
      if (extra.keys.any((key) => !_parameterKeys.contains(key))) return null;
      if (value['requestProvider'] == 'comfyui') {
        if (ComfyUIWorkflow.hasCustomWorkflow(extra)) {
          final graph = ComfyUIWorkflow.parse(extra['comfyWorkflow']);
          if (_containsCredentialField(graph)) {
            return null;
          }
          extra[ComfyUIWorkflow.workflowKey] = graph;
          ComfyUIWorkflow.validate(extra);
        } else {
          final modelId = value['modelId']?.toString().trim() ?? '';
          if (modelId.isEmpty || modelId == ComfyUIWorkflow.modelId) {
            return null;
          }
          // Missing fields in legacy snapshots mean no LoRA / default strength,
          // never inheritance from the channel at replay time.
          extra[ComfyUIWorkflow.loraNameKey] =
              extra[ComfyUIWorkflow.loraNameKey]?.toString().trim();
          extra[ComfyUIWorkflow.loraStrengthKey] ??= 1.0;
        }
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
        postProcessor: value['postProcessor'] as String?,
        width: value['width'] as int,
        height: value['height'] as int,
        steps: value['steps'] as int,
        guidanceScale: (value['guidanceScale'] as num).toDouble(),
        customParameters: Map.unmodifiable(
          jsonDecode(jsonEncode(extra)) as Map<String, dynamic>,
        ),
      );
      final emptyDeferredPrompt =
          snapshot.prompt.isEmpty && snapshot.basePrompt == '';
      if (snapshot.providerId.isEmpty ||
          snapshot.modelId.isEmpty ||
          snapshot.requestProvider.isEmpty ||
          (snapshot.prompt.trim().isEmpty && !emptyDeferredPrompt) ||
          (snapshot.basePrompt != null &&
              snapshot.basePrompt!.trim().isEmpty &&
              !emptyDeferredPrompt) ||
          snapshot.width < 256 ||
          snapshot.width > 2048 ||
          snapshot.height < 256 ||
          snapshot.height > 2048 ||
          snapshot.steps < 1 ||
          snapshot.steps > 100 ||
          !snapshot.guidanceScale.isFinite ||
          snapshot.guidanceScale < 0 ||
          snapshot.guidanceScale > 20) {
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
    if (postProcessor != null) 'postProcessor': postProcessor,
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
