import '../../../core/api/image_providers/image_provider_adapter_factory.dart';
import '../image/drawing_preset.dart';
import '../image/image_config.dart';
import '../tts/tts_config.dart';
import '../tts/tts_request_format.dart';
import '../tts/tts_service.dart';
import 'prompt_pack.dart';

/// Picks the voice pack of a request's preset snapshot (ADR0092). Matching
/// uses only the channel's request format and the model id.
ResolvedPromptPack resolveVoicePrompts(
  PromptPackLibrary library,
  TtsService service,
) {
  final preset = service.config.selectedVoicePreset;
  return library.resolve(
    'tts',
    preset?.synthesis?.prompts ?? const PresetPromptBinding(),
    format: ttsPromptFormat(service.requestFormat),
    model: service.model ?? preset?.synthesis?.modelId ?? '',
  );
}

/// The registry value of a raw voice request format, so aliases match one
/// rule (`fishaudio` → `fish_audio`).
String ttsPromptFormat(String raw) =>
    TtsRequestFormat.fromRaw(raw)?.value ?? raw.trim().toLowerCase();

Map<String, Object?> voicePromptVariables(TtsConfig config) => {
  'max_chars_per_chunk': config.maxCharsPerChunk,
  'voice_frequency': config.voiceFrequency,
};

/// The image request format as the adapter factory names it:
/// `novelai`, `comfyui` or `openai`.
String imagePromptFormat(String provider, Map<String, dynamic> customConfig) =>
    ImageProviderAdapterFactory.resolveProvider(
      provider,
      customConfig: customConfig,
    );

ResolvedPromptPack resolveDrawingPrompts(
  PromptPackLibrary library,
  DrawingPreset preset, {
  required String format,
  required String model,
}) => library.resolve('image', preset.prompts, format: format, model: model);

Map<String, Object?> imagePromptVariables(ImageConfig config) => {
  'default_width': config.defaultWidth,
  'default_height': config.defaultHeight,
  'default_count': config.defaultCount,
  'default_steps': config.defaultSteps,
  'default_guidance_scale': config.defaultGuidanceScale,
};
